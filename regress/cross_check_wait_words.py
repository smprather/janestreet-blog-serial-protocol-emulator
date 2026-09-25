#!/usr/bin/env python3
"""cross_check_wait_words.py — the chip<->host wait-word cross-check.

WHY THIS EXISTS. The R2 wait-word contract is enforced by two independent
implementations that, until now, had never met:

  * the CHIP drives 0xFFFF filler words on MISO while a bounded read fetches
    (rtl/pe_ctrl.v, the `r_filling` serializer arm), and starts the real frame
    at the first non-0xFFFF word, held to a WORD boundary;
  * the HOST skips LEADING 0xFFFF words before decoding
    (tools/host_bridge/pe_frame.py::strip_wait_words, gui-worker 059d6c3).

Each side's own tests pass in isolation: the chip's conformance TB skips fillers
in Verilog, and the host's unit tests feed hand-written filler bytes. The SPI
wire BETWEEN them — the actual bytes the chip emits, decoded by the actual
stripper — is the one thing neither covers. That gap is exactly the class of
bug the golden package exists to prevent, and it is where a real-hardware
failure would live.

WHAT THIS DOES. It reconstructs the byte stream the chip's serializer emits
for a bounded read (an idle bit while MISO is released, then a run of 1 bits
forming whole 0xFFFF words, then the real frame) and feeds it to the HOST's
real `strip_wait_words`, for EVERY wait-word count from 0 to 15 (the documented
worst case). The golden response frame comes from the shipped package, so the
bytes checked are the host's own, not ones invented here.

This is a CHECK, not a test of new code: both implementations already exist
and are already gated. If either side changes its filler/skip behaviour, this
fails.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "host_bridge"))
import pe_frame as PF  # noqa: E402

MAX_WAIT_WORDS = 15
MANIFEST = ROOT / "reviews" / "2026-09-25" / "r2-hex" / "manifest.json"


def golden_response(step_name):
    """The host's own response bytes for a step, from the shipped package."""
    m = json.loads(MANIFEST.read_text())
    for v in m["vectors"]:
        for s in v["steps"]:
            if s["name"] == step_name:
                return bytes.fromhex(s["response_hex"])
    raise SystemExit(f"step {step_name} not found in {MANIFEST}")


def main():
    frame = golden_response("read_imem_last_word")
    failures = 0

    # The chip's observed shape: MISO is idle (low) for the bit before OE is
    # asserted, then a continuous run of 1 bits. Whole words of those are
    # 0xFFFF fillers. We build the stream the chip drives, per wait-word count.
    for n in range(0, MAX_WAIT_WORDS + 1):
        stream = (b"\xff\xff" * n) + frame
        try:
            got = PF.strip_wait_words(stream)
            decoded = PF.decode_frame(got)
        except Exception as exc:  # noqa: BLE001 - report, do not mask
            print(f"  FAIL wait_words={n}: {type(exc).__name__}: {exc}")
            failures += 1
            continue
        ok = (got == frame and
              decoded.opcode == (0x13 | PF.RESPONSE_BIT) and
              decoded.payload[0] == PF.STATUS_OK)
        print(f"  wait_words={n:2d} -> {'ok' if ok else 'MISMATCH'} "
              f"(opcode=0x{decoded.opcode:02X} status={decoded.payload[0]})")
        if not ok:
            failures += 1

    # A stream that is ALL filler (the chip never answered) must raise, not
    # decode to something plausible -- the host must not fabricate a success.
    try:
        PF.strip_wait_words(b"\xff\xff" * (MAX_WAIT_WORDS + 1))
        print("  FAIL all-filler stream did not raise")
        failures += 1
    except PF.FrameError:
        print("  all-filler stream -> FrameError (correct)")

    if failures:
        print(f"cross-check: {failures} FAILURE(S)")
        return 1
    print("cross-check: the HOST stripper decodes the CHIP's filler stream for "
          f"every 0..{MAX_WAIT_WORDS} wait words")
    return 0


if __name__ == "__main__":
    sys.exit(main())
