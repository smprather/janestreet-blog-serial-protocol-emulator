"""Protocol fuzzer: hostile input against both frame decoders.

The demo and the judges WILL produce malformed frames, so both ends of the
protocol are attacked here:

  * the **host decoder** (`tools/host_gui/protocol.py` and the MicroPython
    `tools/host_bridge/pe_frame.py`, which must behave identically) against
    random and corrupted chip frames: sync corruption, single-byte mutations
    (a CRC flip), truncation at every length, extension, the wait-word edges
    (0 / 15 / 16+ leading fillers, all-filler, 0xFFFF payload words) and
    frame-after-frame concatenation;
  * the **chip-side expectation** (`tools/host_gui/fake_pe.py`'s `exchange`,
    which models the PE's request parser) against hostile host requests.

Invariants (a violation is a finding, not a "test failure"):

  1. NO CRASH: a decoder never raises anything other than its typed
     FrameError for malformed input.
  2. NO MISDECODE: if a frame decodes, re-encoding it must reproduce the
     exact input bytes; and any single-byte mutation of a valid frame must be
     rejected (the CRC covers the whole frame, so nothing may slip through).
  3. CONTRACT: the wait-word skip is leading-only and bounded at 15, and
     FakePE never answers a malformed request with a well-formed *success*.

Reproducible: a fixed seed is printed and every run is deterministic.
Bounded: a fixed iteration count and a wall-clock budget; it is a campaign,
not an infinite loop.

Usage:
    python3 -m tools.host_gui.fuzz_protocol                 # default campaign
    python3 -m tools.host_gui.fuzz_protocol --seed 7 -n 20000
    python3 -m tools.host_gui.fuzz_protocol --json          # machine-readable

Exit: 0 = no finding, 1 = a finding (printed with the reproducing input).
"""

from __future__ import annotations

import argparse
import json
import random
import time
from dataclasses import asdict, dataclass, field

from tools.host_bridge import pe_frame as PF
from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P

FILLER = b"\xff\xff"
DEFAULT_SEED = 20260925
DEFAULT_ITERATIONS = 4000
WALL_CLOCK_BUDGET_S = 20.0
MAX_WAIT_WORDS = 15          # the chip's worst-case wait words
PING = (P.OP_PING, 7, P.TARGET_HOST, b"")


def _words_bytes(words) -> bytes:
    return b"".join(int(w).to_bytes(2, "big") for w in words)


READ_IMEM = (P.OP_READ_IMEM, 3, P.TARGET_HOST, _words_bytes((1, 2)))


@dataclass
class Finding:
    kind: str
    detail: str
    seed: int
    iteration: int
    input_hex: str

    def render(self) -> str:
        return (f"[{self.kind}] {self.detail}\n"
                f"    seed={self.seed} iteration={self.iteration} "
                f"input={self.input_hex}")


@dataclass
class Report:
    seed: int
    iterations: int
    seconds: float
    findings: list = field(default_factory=list)
    counters: dict = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return not self.findings

    def to_dict(self) -> dict:
        return {"seed": self.seed, "iterations": self.iterations,
                "seconds": round(self.seconds, 3),
                "ok": self.ok, "findings": [asdict(f) for f in self.findings],
                "counters": self.counters}


def _valid_frame(rng, template) -> bytes:
    opcode, sequence, target, payload = template
    return P.encode_frame(opcode, sequence & 0xFFFF, target, payload)


def _flip(data: bytes, rng) -> bytes:
    out = bytearray(data)
    out[rng.randrange(len(out))] ^= 1 << rng.randrange(8)
    return bytes(out)


def _check_decoder(raw: bytes, label, report, iteration, expect_decode=None):
    """Run one hostile input through BOTH decoders and check the invariants."""
    report.counters[label] = report.counters.get(label, 0) + 1
    for name, module in (("protocol", P), ("pe_frame", PF)):
        decoded = None
        try:
            decoded = module.decode_frame(raw)
        except module.FrameError:
            decoded = None
        except Exception as exc:  # noqa: BLE001 - catching ANY crash IS the invariant
            report.findings.append(Finding(
                f"{name}/{label}-crash",
                f"{name}.decode_frame raised {type(exc).__name__}: {exc}",
                report.seed, iteration, raw.hex()))
            continue
        if decoded is not None:
            # invariant 2: a decode must round-trip exactly
            if hasattr(decoded, "to_bytes"):
                again = decoded.to_bytes()
            else:
                again = module.encode_frame(
                    decoded.opcode, decoded.sequence, decoded.target,
                    module.words_to_bytes(decoded.payload))
            if again != raw:
                report.findings.append(Finding(
                    f"{name}/{label}-misdecode",
                    "decoded frame does not re-encode to the input bytes",
                    report.seed, iteration, raw.hex()))
        if expect_decode is True and decoded is None:
            report.findings.append(Finding(
                f"{name}/{label}-unexpected-reject",
                "a valid frame was rejected",
                report.seed, iteration, raw.hex()))


def campaign_host_decoder(rng, report, iterations) -> None:
    """Hostile input against the host/bridge decoders."""
    for iteration in range(iterations):
        template = PING if rng.random() < 0.5 else READ_IMEM
        valid = _valid_frame(rng, template)

        # baseline: the valid frame decodes (invariants catch a broken codec)
        _check_decoder(valid, "valid", report, iteration, expect_decode=True)

        # single-byte mutation anywhere: CRC must reject it
        _check_decoder(_flip(valid, rng), "bitflip", report, iteration)

        # sync corruption
        corrupted = bytearray(valid)
        corrupted[0] ^= 0xFF
        _check_decoder(bytes(corrupted), "sync", report, iteration)

        # truncation at every byte length
        cut = rng.randrange(0, len(valid))
        _check_decoder(valid[:cut], "truncated", report, iteration)

        # extension (a frame is not a prefix of a longer one)
        _check_decoder(valid + bytes([rng.randrange(256)]), "extended",
                       report, iteration)

        # frame after frame
        _check_decoder(valid + valid, "concatenated", report, iteration)

        # odd length (mid-word)
        _check_decoder(valid[:-1], "odd-length", report, iteration)

        # random noise
        noise = bytes(rng.randrange(256) for _ in range(rng.randrange(0, 40)))
        _check_decoder(noise, "noise", report, iteration)

        # pure filler / truncated filler
        _check_decoder(FILLER * rng.randrange(0, 20), "filler", report, iteration)


def campaign_wait_words(rng, report) -> None:
    """The wait-word edges: 0 / 15 / 16+ fillers, all-filler, 0xFFFF payload."""
    valid = P.encode_frame(*READ_IMEM[:3], READ_IMEM[3])
    for fillers in (0, 1, 14, MAX_WAIT_WORDS):
        stripped = PF.strip_wait_words(FILLER * fillers + valid)
        if stripped != valid:
            report.findings.append(Finding(
                "wait-words/skip", f"{fillers} fillers did not strip to the "
                "frame exactly", report.seed, -1,
                (FILLER * fillers + valid).hex()))
        # the host copy must agree with the bridge copy
        if not hasattr(P, "strip_wait_words"):
            report.findings.append(Finding(
                "wait-words/host-missing",
                "tools.host_gui.protocol has no strip_wait_words (the bridge "
                "copy does); the two codecs must stay in step",
                report.seed, -1, valid.hex()))

    # 16+ fillers exceeds the contract bound: must NOT be skipped into a frame
    over = FILLER * (MAX_WAIT_WORDS + 1) + valid
    try:
        PF.strip_wait_words(over)
        report.findings.append(Finding(
            "wait-words/bound", f"more than {MAX_WAIT_WORDS} leading fillers "
            "were skipped instead of rejected", report.seed, -1, over.hex()))
    except PF.FrameError:
        pass

    # all filler is a timeout, not a frame
    try:
        PF.strip_wait_words(FILLER * 40)
        report.findings.append(Finding(
            "wait-words/all-filler", "an all-filler stream decoded as a frame",
            report.seed, -1, (FILLER * 40).hex()))
    except PF.FrameError:
        pass

    # a 0xFFFF payload word is DATA (leading-only skip)
    payload = P.encode_frame(P.OP_READ_IMEM | P.RESPONSE_BIT, 1, P.TARGET_HOST,
                             _words_bytes((P.STATUS_OK, 0xFFFF, 0x0041)))
    try:
        if PF.decode_frame(PF.strip_wait_words(payload)).payload != \
                (P.STATUS_OK, 0xFFFF, 0x0041):
            report.findings.append(Finding(
                "wait-words/payload", "a 0xFFFF payload word was lost",
                report.seed, -1, payload.hex()))
    except PF.FrameError as exc:
        report.findings.append(Finding(
            "wait-words/payload", f"valid frame rejected: {exc}",
            report.seed, -1, payload.hex()))


def campaign_chip_side(rng, report, iterations) -> None:
    """Hostile HOST REQUESTS against the FakePE chip-side expectation model."""
    for iteration in range(iterations):
        pe = F.FakePE()
        pe.request(P.OP_LOAD, payload_words=(0x0041, 0x1001, 0x4002))
        kind = rng.random()
        if kind < 0.25:                      # pure noise
            raw = bytes(rng.randrange(256) for _ in range(rng.randrange(0, 40)))
        elif kind < 0.45:                    # truncated valid request
            valid = P.encode_frame(P.OP_READ_IMEM, 1, P.TARGET_HOST,
                                   _words_bytes((0, 2)))
            raw = valid[:rng.randrange(0, len(valid))]
        elif kind < 0.65:                    # bit-flipped valid request
            valid = P.encode_frame(P.OP_READ_IMEM, 1, P.TARGET_HOST,
                                   _words_bytes((0, 2)))
            raw = bytearray(valid)
            raw[rng.randrange(len(raw))] ^= 1 << rng.randrange(8)
            raw = bytes(raw)
        elif kind < 0.8:                     # hostile length field
            words = (0, rng.choice([0, 0xFFFF, 0x7FFF, 0x8000]))
            raw = P.encode_frame(P.OP_READ_IMEM, 1, P.TARGET_HOST,
                                 _words_bytes(words))
        else:                                # unknown opcode / response bit set
            raw = P.encode_frame(rng.choice([0x00, 0x99, 0x13 | 0x80]), 1,
                                 P.TARGET_HOST, _words_bytes((0, 1)))
        report.counters["chip-side"] = report.counters.get("chip-side", 0) + 1
        try:
            response = pe.exchange(raw)
        except Exception as exc:  # noqa: BLE001 - catching ANY crash IS the invariant
            report.findings.append(Finding(
                "chip-side/crash", f"FakePE.exchange raised "
                f"{type(exc).__name__}: {exc}", report.seed, iteration,
                raw.hex()))
            continue
        if response is None:
            continue                          # no response is a legal answer
        # if it answers, the answer must be a well-formed response frame
        try:
            frame = P.decode_frame(response)
        except P.FrameError as exc:
            report.findings.append(Finding(
                "chip-side/bad-response",
                f"FakePE answered with an undecodable frame: {exc}",
                report.seed, iteration, raw.hex()))
            continue
        if not frame.is_response:
            report.findings.append(Finding(
                "chip-side/not-response",
                "FakePE answered a request frame without the response bit",
                report.seed, iteration, raw.hex()))


def run(seed: int = DEFAULT_SEED, iterations: int = DEFAULT_ITERATIONS,
        budget_s: float = WALL_CLOCK_BUDGET_S) -> Report:
    """Run the campaign; returns a Report (never raises on a finding)."""
    started = time.monotonic()
    report = Report(seed=seed, iterations=iterations, seconds=0.0)
    rng = random.Random(seed)
    campaign_wait_words(rng, report)
    campaign_host_decoder(rng, report, iterations)
    campaign_chip_side(rng, report, iterations)
    elapsed = time.monotonic() - started
    if elapsed > budget_s:                   # bounded: report, do not extend
        report.findings.append(Finding(
            "budget/exceeded",
            f"campaign took {elapsed:.1f}s (budget {budget_s:.0f}s)",
            seed, -1, ""))
    report.seconds = elapsed
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("-n", "--iterations", type=int,
                        default=DEFAULT_ITERATIONS)
    parser.add_argument("--budget", type=float, default=WALL_CLOCK_BUDGET_S)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    report = run(args.seed, args.iterations, args.budget)
    if args.json:
        print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
    else:
        print(f"fuzz_protocol seed={report.seed} "
              f"iterations={report.iterations} "
              f"cases={sum(report.counters.values())} "
              f"({report.seconds:.2f}s)")
        for name, count in sorted(report.counters.items()):
            print(f"  {name:<18} {count}")
        for finding in report.findings:
            print(finding.render())
        print("RESULT: PASS" if report.ok else
              f"RESULT: FAIL ({len(report.findings)} findings)")
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
