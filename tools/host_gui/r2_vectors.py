"""Portable R2 read verification package: golden vectors for the chip side.

`build_package()` derives every vector from the live `FakePE` model and the
shared frame codec, so the artifact cannot drift from the host contract; the
checked-in copy (`reviews/2026-09-25/R2-READ-VERIFICATION.json`) must match a
fresh build, and `--check` is the drift gate.

Who uses it: the chip manager hands this to the protocol worker as the R2
acceptance spec. Each step carries the exact framed request and response bytes
(hex), the request payload words, the response payload words and the status, so
a Verilog testbench can drive the frames and compare the response word for word
without importing anything from Python.

**Nothing here is chip-confirmed.** These vectors are the agreed expectations
for the R2 read path, which is chip-side work under the chip manager's
dispatch. They are the gate the chip must pass, not evidence that it does.

Manager RULINGs encoded here (2026-09-25):
  * an out-of-range READ answers `RANGE` *and* latches sticky `FAULT_RANGE`
    (0x4); `CLEAR_FAULT` with mask 0x4 clears it;
  * READ payload is low-word-first, ascending, matching LOAD's stream - so
    `READ_IMEM(a, n)` returns words `a..a+n-1` in order and `READ_DMEM(a, n)`
    packs bytes `a..a+n-1` big-endian into each word.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P
from tools.host_gui import r2_reads as R

REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACT = REPO_ROOT / "reviews" / "2026-09-25" / "R2-READ-VERIFICATION.json"
README = REPO_ROOT / "reviews" / "2026-09-25" / "R2-READ-VERIFICATION.md"
TARGET = P.TARGET_HOST
LOAD_WORDS = (0x0041, 0x1001, 0x4002)


def _frame(opcode, sequence, payload_words):
    return P.encode_frame(opcode, sequence, TARGET,
                          b"".join(int(w).to_bytes(2, "big")
                                   for w in payload_words)).hex()


def _record(pe, name, opcode, payload_words, sequence, note=""):
    """Drive one request through the model and capture request + response."""
    request_hex = _frame(opcode, sequence, payload_words)
    response_raw = pe.exchange(bytes.fromhex(request_hex))
    assert response_raw is not None, f"no response for {name}"
    frame = P.decode_frame(response_raw)
    return {
        "name": name,
        "note": note,
        "opcode": opcode,
        "opcode_name": _opcode_name(opcode),
        "sequence": sequence,
        "request_payload_words": list(payload_words),
        "request_hex": request_hex,
        "status": frame.payload[0],
        "response_payload_words": list(frame.payload),
        "response_hex": response_raw.hex(),
        "model_faults": pe.faults,
    }


def _opcode_name(opcode):
    for name in dir(P):
        if name.startswith("OP_") and getattr(P, name) == opcode:
            return name
    return f"0x{opcode:02X}"


def _loaded_model(*, pc=0, a=0, x=0, y=0, insn=0, timer=0, dmem=b"",
                  running=False):
    pe = F.FakePE()
    pe.request(P.OP_LOAD, payload_words=LOAD_WORDS)
    pe.pc, pe.a, pe.x, pe.y = pc, a, x, y
    pe.insn, pe.timer = insn, timer
    if dmem:
        pe.dmem[0:len(dmem)] = dmem
    pe.run = running
    return pe


def _vector(name, obligation, word_order, steps):
    return {"name": name, "obligation": obligation, "word_order": word_order,
            "chip_confirmed": False, "steps": steps}


def build_package() -> dict:
    """Derive the whole R2 verification package from the live model."""
    vectors = []

    # 1. Bounded IMEM read, low word first ascending.
    pe = _loaded_model()
    vectors.append(_vector(
        "read_imem_bounded", R.by_name()["read_imem_bounded"].description,
        "low-word-first ascending",
        [_record(pe, "read_imem_address_1_count_2", P.OP_READ_IMEM, (1, 2), 1,
                 "words 1,2 returned in ascending order")]))

    # 2. Bounded DMEM read: bytes packed big-endian per word.
    pe = _loaded_model(dmem=b"\x0a\x0b\x0c\x0d")
    vectors.append(_vector(
        "read_dmem_bounded", R.by_name()["read_dmem_bounded"].description,
        "bytes big-endian per word, ascending",
        [_record(pe, "read_dmem_address_0_count_4", P.OP_READ_DMEM, (0, 4), 1,
                 "bytes 0..3 -> 0x0A0B, 0x0C0D")]))

    # 3. DUMP_CORE header equals the STATUS header while stopped.
    pe = _loaded_model(pc=0x123, a=0x456, x=0x789, y=0xABC, timer=7)
    dump = _record(pe, "dump_core_header", P.OP_DUMP_CORE, (), 1)
    status = _record(pe, "status_header", P.OP_STATUS, (), 2)
    vectors.append(_vector(
        "dump_core_header", R.by_name()["dump_core_header"].description,
        "n/a (register header)",
        [dump, status]))

    # 4. READ_CPU is non-halting and carries full-width registers.
    pe = _loaded_model(pc=0x3FF, a=0x1FFF, x=0x2AA, y=0x155, insn=0xFFFF,
                       running=True)
    vectors.append(_vector(
        "read_cpu_non_halting", R.by_name()["read_cpu_non_halting"].description,
        "n/a (register header)",
        [_record(pe, "read_cpu_while_running", P.OP_READ_CPU, (), 1,
                 "answers while run=1; pc/a/x/y/insn full width")]))

    # 4b. Full-width debug registers (R2 removes the 8-bit truncation).
    pe = _loaded_model(pc=0x3FF, a=0x1FFF, x=0x2AA, y=0x155, insn=0xFFFF)
    vectors.append(_vector(
        "full_width_debug_regs", R.by_name()["full_width_debug_regs"].description,
        "n/a (register header)",
        [_record(pe, "read_cpu_full_width_regs", P.OP_READ_CPU, (), 1,
                 "pc=0x3FF, a=0x1FFF, x=0x2AA, y=0x155, insn=0xFFFF")]))

    # 5. Reads while running are rejected (chip-side, R2).
    pe = _loaded_model(running=True)
    vectors.append(_vector(
        "read_while_running_rejected",
        R.by_name()["read_while_running_rejected"].description,
        "n/a (status only)",
        [_record(pe, "read_imem_not_ready", P.OP_READ_IMEM, (0, 1), 1),
         _record(pe, "read_dmem_not_ready", P.OP_READ_DMEM, (0, 1), 2),
         _record(pe, "dump_core_not_ready", P.OP_DUMP_CORE, (), 3)]))

    # 6. Range never wraps: past-the-end reads are RANGE, not wrapped data.
    pe = _loaded_model()
    vectors.append(_vector(
        "range_never_wraps", R.by_name()["range_never_wraps"].description,
        "n/a (rejected)",
        [_record(pe, "read_imem_last_word", P.OP_READ_IMEM, (1023, 1), 1,
                 "the last word is readable"),
         _record(pe, "read_imem_past_end_no_wrap", P.OP_READ_IMEM, (1023, 2), 2,
                 "RANGE, never a wrapped read"),
         _record(pe, "read_dmem_past_end_no_wrap", P.OP_READ_DMEM, (15, 2), 3,
                 "RANGE, never a wrapped read")]))

    # 7. The sticky-fault lifecycle: bad read -> RANGE + FAULT_RANGE, status
    #    shows the sticky bit, CLEAR_FAULT clears it (manager ruling).
    pe = _loaded_model()
    lifecycle = [
        _record(pe, "bad_read_answers_range", P.OP_READ_IMEM, (2000, 1), 1,
                "out-of-range read: RANGE and latches sticky FAULT_RANGE"),
        _record(pe, "status_shows_sticky_fault", P.OP_STATUS, (), 2,
                "the sticky fault bit is visible before any clear"),
        _record(pe, "clear_fault_clears_the_bit", P.OP_CLEAR_FAULT,
                (F.FAULT_RANGE,), 3, "CLEAR_FAULT(0x4) returns faults=0"),
    ]
    vectors.append(_vector(
        "read_range_fault_lifecycle",
        "An out-of-range READ latches sticky FAULT_RANGE and CLEAR_FAULT "
        "clears it (manager ruling).",
        "n/a (status/lifecycle)",
        lifecycle))

    return {
        "artifact": "R2 read-path verification package",
        "generated_by": "tools/host_gui/r2_vectors.py (build_package)",
        "source_of_truth": ["tools/host_gui/r2_reads.py",
                            "tools/host_gui/fake_pe.py",
                            "tools/host_gui/protocol.py"],
        "chip_confirmed": False,
        "notice": R.NOT_CHIP_CONFIRMED,
        "rulings_applied": [
            ("out-of-range READ latches sticky FAULT_RANGE (0x4); "
             "CLEAR_FAULT clears it (manager ruling 2026-09-25)"),
            ("READ payload is low-word-first ascending, matching LOAD "
             "(manager ruling 2026-09-25)"),
        ],
        "protocol": {
            "sync": P.SYNC,
            "version": P.VERSION,
            "header": "{version[3:0], opcode[7:0], target[3:0]}",
            "crc": "CRC-16/CCITT-FALSE",
            "crc_poly": 0x1021,
            "crc_init": 0xFFFF,
            "response_bit": P.RESPONSE_BIT,
            "word_order": "big-endian words on the wire; READ payload "
                          "low-word-first ascending",
        },
        "memory": {"imem_words": F.IMEM_WORDS, "dmem_bytes": F.DMEM_BYTES},
        "status_codes": {name: getattr(P, name) for name in dir(P)
                         if name.startswith("STATUS_")},
        "vectors": vectors,
    }


def write_package(path: Path = ARTIFACT) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(build_package(), indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")
    return path


def check_package(path: Path = ARTIFACT) -> int:
    """Drift gate: the checked-in artifact must match a fresh build."""
    if not path.is_file():
        print(f"missing artifact: {path}")
        return 1
    if json.loads(path.read_text(encoding="utf-8")) != build_package():
        print(f"artifact is stale: {path} (regenerate with --write)")
        return 1
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate/check the R2 read verification package.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true",
                      help="write the artifact from a fresh build")
    mode.add_argument("--check", action="store_true",
                      help="fail if the checked-in artifact is stale")
    args = parser.parse_args(argv)
    if args.write:
        print(f"wrote {write_package()}")
        return 0
    result = check_package()
    print("r2 verification package: up to date" if result == 0
          else "r2 verification package: STALE")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
