#!/usr/bin/env python3
"""Run firmware/i2c_xfer.pe against an independent I2C slave model and check the
whole transaction: bytes, ACKs, the read byte, bus grammar, and standard-mode
timing at the pin.

WHY THE EMULATOR DOES THIS AND THE RTL TB DOES IT AGAIN. The emulator is the
fast loop (seconds versus a minute for iverilog) and it is where the firmware's
logic is debugged. The RTL TB is the independent acceptance test on real
hardware. They must agree byte-for-byte, and disagreeing once is a signal, not
an inconvenience ([[STATUS]] gotcha 11).

WHAT "INDEPENDENT" MEANS HERE. The slave model decodes the wire -- START/STOP,
bits on SCL rises, the 9th clock as ACK -- and is never told what the firmware
intends. The checker then asserts on the slave's records AND on the firmware's
own dmem observables, so a firmware bug and a model bug have to coincide to
pass, and a model that silently agreed with a broken firmware would still fail
the timing/grammar checks.

Exit 0 if every phase passes; 1 otherwise.
"""
import argparse
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "tools" / "fw"))
sys.path.insert(0, str(REPO / "tools" / "checks"))
import peemu  # noqa: E402
import i2c_timing  # noqa: E402  (its FLOORS and classify, one source of truth)

ADDR = 0x50
WRITE_ADDR = (ADDR << 1) | 0     # 0xA0
READ_ADDR = (ADDR << 1) | 1      # 0xA1
WRITE_DATA = 0xA5
READ_DATA = 0x5A

MAX_CYCLES = 200_000


def assemble() -> list[int]:
    out = pathlib.Path("/tmp/i2c_xfer_check.hex")
    r = subprocess.run(
        [sys.executable, str(REPO / "tools" / "fw" / "peasm.py"),
         str(REPO / "firmware" / "i2c_xfer.pe"), "-o", str(out)],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"assemble failed:\n{r.stdout}{r.stderr}")
    return [int(tok, 16) for tok in out.read_text().split()]


def run_phase(words: list[int], phase: int) -> dict:
    soc = peemu.Soc(words)
    soc.run = True
    soc.imem_rdata = soc.imem[0]
    soc.i2c_cnt = phase
    slave = peemu.I2CSlaveModel(address=ADDR, read_byte=READ_DATA)

    transitions = []
    prev = ((soc.wire_bits() >> 5) & 1, (soc.wire_bits() >> 4) & 1)
    initial = prev
    for _ in range(MAX_CYCLES):
        soc.step()
        slave.poll(soc)
        w = soc.wire_bits()
        cur = ((w >> 5) & 1, (w >> 4) & 1)
        if cur != prev:
            transitions.append((soc.cycles, prev, cur))
        prev = cur
        if soc.dmem[5] == 0xA5:
            break

    return {
        "transitions": transitions, "initial": initial,
        "done": soc.dmem[5] == 0xA5,
        "dmem": list(soc.dmem),
        "address_bytes": list(slave.address_bytes),
        "writes": list(slave.writes), "acks": list(slave.acks),
        "starts": slave.starts, "stops": slave.stops,
        "cycles": soc.cycles,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--phases", type=int, default=60,
                    help="tick phases to sweep (the residual is phase-dependent)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    words = assemble()
    print(f"firmware/i2c_xfer.pe: {len(words)} words, "
          f"{args.phases} phases\n")

    runs = [run_phase(words, p) for p in range(args.phases)]

    ok = True

    # ---- the transaction, from the slave model's independent decode --------
    print("transaction (decoded by the slave model):")
    expect_addr = [WRITE_ADDR, READ_ADDR]
    expect_writes = [WRITE_DATA]
    a0 = runs[0]
    for name, got, want in (
            ("address bytes", a0["address_bytes"], expect_addr),
            ("data writes", a0["writes"], expect_writes),
            ("read ACK/NACK bits", a0["acks"], [1])):
        good = got == want
        ok &= good
        print(f"  {'OK   ' if good else 'FAIL '} {name:<20} "
              f"{[f'0x{v:02X}' for v in got]}  want {[f'0x{v:02X}' for v in want]}")
    for name, got, want in (("STARTs", a0["starts"], 2), ("STOPs", a0["stops"], 1)):
        good = got == want
        ok &= good
        print(f"  {'OK   ' if good else 'FAIL '} {name:<20} {got}  want {want}")

    # The transaction must be identical in EVERY phase, not just phase 0.
    varying = [i for i, r in enumerate(runs)
               if (r["address_bytes"], r["writes"], r["acks"],
                   r["starts"], r["stops"]) !=
                  (a0["address_bytes"], a0["writes"], a0["acks"],
                   a0["starts"], a0["stops"])]
    if varying:
        ok = False
        print(f"  FAIL  transaction varies across phases: {varying[:8]}")
    else:
        print(f"  OK    transaction identical in all {len(runs)} phases")

    # ---- the firmware's own observables ------------------------------------
    print("\nfirmware dmem observables (phase 0; must be constant across phases):")
    slots = {0: "write-addr ACK (0=ACKed)", 1: "write-data ACK (0=ACKed)",
             2: "read-addr ACK (0=ACKed)", 3: "read byte", 4: "NACK sent",
             5: "completion flag"}
    want_slots = {0: 0x00, 1: 0x00, 2: 0x00, 3: READ_DATA, 4: 0x01, 5: 0xA5}
    for slot, name in slots.items():
        vals = sorted({r["dmem"][slot] for r in runs})
        want = want_slots[slot]
        good = vals == [want]
        ok &= good
        shown = [f"0x{v:02X}" for v in vals]
        print(f"  {'OK   ' if good else 'FAIL '} dmem[{slot}] {name:<24} "
              f"{shown}  want 0x{want:02X}")

    # ---- timing, worst case over the swept phases --------------------------
    cls = [i2c_timing.classify(r["transitions"], r["initial"]) for r in runs]
    lows = [x for c in cls for x in c["lows"]]
    highs = [x for c in cls for x in c["highs"]]
    periods = [(h + l) for c in cls for h, l in zip(c["highs"], c["lows"][1:])]
    print("\nstandard-mode timing, worst case over the swept phases:")
    worst = {"tLOW": min(lows), "tHIGH": min(highs), "period": min(periods)}
    for name, floor in i2c_timing.FLOORS.items():
        got = worst[name]
        good = got >= floor
        ok &= good
        print(f"  {'OK   ' if good else 'FAIL '} {name:<7} {got:8.3f} us  "
              f"floor {floor:5.2f}  margin {got - floor:+7.3f}")
    print(f"  bus rate: {1000.0 / max(periods):.2f} .. "
          f"{1000.0 / min(periods):.2f} kHz (standard mode <= 100 kHz)")

    # ---- grammar: the conditions and the SDA-under-SCL-high rule -----------
    print("\nbus grammar:")
    grammar_ok = True
    for p, c in enumerate(cls):
        names = [n for _, n in c["conds"]]
        if names != ["START", "START", "STOP"]:
            print(f"  phase {p}: conditions {names} -- expected "
                  f"['START','START','STOP'] (repeated START, no STOP between)")
            grammar_ok = False
        for cyc, s0, s1, d0, d1 in c["data_edges"]:
            if s0 == 1 or s1 == 1:
                print(f"  phase {p}: SDA moved with SCL high at cycle {cyc} "
                      f"(SCL {s0}->{s1}, SDA {d0}->{d1})")
                grammar_ok = False
    total_conds = sum(len(c["conds"]) for c in cls)
    if total_conds != 3 * len(cls):
        print(f"  VACUOUS: parsed {total_conds} conditions across {len(cls)} "
              f"runs, expected {3 * len(cls)}")
        grammar_ok = False
    if grammar_ok:
        print(f"  OK    all {len(runs)} phases: START, repeated START, STOP, "
              f"no stray data edge under SCL-high")
    ok &= grammar_ok

    if not all(r["done"] for r in runs):
        ok = False
        print("\n  FAIL  the completion flag never appeared in some phase")

    print(f"\nRESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
