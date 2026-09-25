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
HEX_DIR = REPO_ROOT / "reviews" / "2026-09-25" / "r2-hex"
TARGET = P.TARGET_HOST
LOAD_WORDS = (0x0041, 0x1001, 0x4002)

# Chip-native register maxima, from rtl/pe_cpu.v (the ISA is the source of
# truth): pc is 10 bits at IMEM_WORDS=1024, a/x/y are 8, insn is 16.
ISA_PC_MAX = (1 << F.ISA_PC_BITS) - 1
ISA_REG_MAX = (1 << F.ISA_A_BITS) - 1
ISA_INSN_MAX = (1 << F.ISA_INSN_BITS) - 1


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
    pe = _loaded_model(pc=0x123, a=0x45, x=0x78, y=0x9A, timer=7)
    dump = _record(pe, "dump_core_header", P.OP_DUMP_CORE, (), 1)
    status = _record(pe, "status_header", P.OP_STATUS, (), 2)
    vectors.append(_vector(
        "dump_core_header", R.by_name()["dump_core_header"].description,
        "n/a (register header)",
        [dump, status]))

    # 4. READ_CPU is non-halting and carries full-width registers.
    pe = _loaded_model(pc=ISA_PC_MAX, a=ISA_REG_MAX, x=ISA_REG_MAX,
                       y=ISA_REG_MAX, insn=ISA_INSN_MAX, running=True)
    vectors.append(_vector(
        "read_cpu_non_halting", R.by_name()["read_cpu_non_halting"].description,
        "n/a (register header)",
        [_record(pe, "read_cpu_while_running", P.OP_READ_CPU, (), 1,
                 "answers while run=1; pc/a/x/y/insn full width")]))

    # 4b. Full-width debug registers (the anti-truncation vector). Widths are
    # the ISA's: pc 10 bits, a/x/y 8, insn 16 - the "full width" obligation is
    # that R2 exposes every bit the chip has, not that more exist.
    pe = _loaded_model(pc=ISA_PC_MAX, a=ISA_REG_MAX, x=ISA_REG_MAX,
                       y=ISA_REG_MAX, insn=ISA_INSN_MAX)
    vectors.append(_vector(
        "full_width_debug_regs", R.by_name()["full_width_debug_regs"].description,
        "n/a (register header)",
        [_record(pe, "read_cpu_full_width_regs", P.OP_READ_CPU, (), 1,
                 f"pc=0x{ISA_PC_MAX:03X}, a=x=y=0x{ISA_REG_MAX:02X}, "
                 f"insn=0x{ISA_INSN_MAX:04X}")]))

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


def _hex_bytes(raw_hex):
    """$readmemh-ready byte stream: one lowercase two-digit byte per line.

    $readmemh fills an 8-bit array from address 0, so a testbench does
    ``$readmemh("....req.hex", req_mem);`` and clocks ``req_mem`` out. One byte
    per line (rather than packed words) keeps the stream identical to the JSON
    frame's bytes, which the conformance test asserts.
    """
    return "".join(f"{byte:02x}\n" for byte in bytes.fromhex(raw_hex))


def _read_hex(path):
    """Read a $readmemh file back to bytes (whitespace-insensitive)."""
    return bytes.fromhex("".join(path.read_text(encoding="utf-8").split()))


def write_hex_export(directory=HEX_DIR):
    """Write per-step request/response .hex files plus a manifest."""
    package = build_package()
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    vectors = []
    for vector in package["vectors"]:
        steps = []
        for step in vector["steps"]:
            base = f"{vector['name']}.{step['name']}"
            request_file = f"{base}.req.hex"
            response_file = f"{base}.rsp.hex"
            (directory / request_file).write_text(
                _hex_bytes(step["request_hex"]), encoding="utf-8")
            (directory / response_file).write_text(
                _hex_bytes(step["response_hex"]), encoding="utf-8")
            steps.append({
                "name": step["name"],
                "opcode": step["opcode"],
                "opcode_name": step["opcode_name"],
                "sequence": step["sequence"],
                "request_file": request_file,
                "request_bytes": len(step["request_hex"]) // 2,
                "response_file": response_file,
                "response_bytes": len(step["response_hex"]) // 2,
                "response_hex": step["response_hex"],
                "status": step["status"],
                "response_payload_words": step["response_payload_words"],
                "model_faults": step["model_faults"],
            })
        vectors.append({"name": vector["name"],
                        "obligation": vector["obligation"],
                        "chip_confirmed": vector["chip_confirmed"],
                        "steps": steps})
    manifest = {
        "artifact": "R2 read-path $readmemh export",
        "generated_by": "tools/host_gui/r2_vectors.py (--hex)",
        "source_of_truth": package["source_of_truth"],
        "chip_confirmed": False,
        "notice": package["notice"],
        "word_order": package["protocol"]["word_order"],
        "readmemh_usage": (
            "$readmemh(\"<file>\", mem); with an 8-bit mem[] filled from "
            "address 0; the stream is the frame's bytes in wire order."),
        "vectors": vectors,
    }
    (directory / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    (directory / "README.md").write_text(_hex_readme(manifest), encoding="utf-8")
    return manifest


def check_hex_export(directory=HEX_DIR) -> int:
    """Drift gate: every .hex file must equal the JSON frame it came from."""
    directory = Path(directory)
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file():
        print(f"missing hex export: {manifest_path} (regenerate with --hex)")
        return 1
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    package = {vector["name"]: vector for vector in build_package()["vectors"]}
    for vector in manifest.get("vectors", []):
        source = package.get(vector["name"])
        if source is None:
            print(f"hex manifest names an unknown vector: {vector['name']}")
            return 1
        for index, step in enumerate(vector["steps"]):
            expected = source["steps"][index]
            for key, raw in (("request_file", expected["request_hex"]),
                             ("response_file", expected["response_hex"])):
                path = directory / step[key]
                if not path.is_file():
                    print(f"missing hex file: {path}")
                    return 1
                if _read_hex(path) != bytes.fromhex(raw):
                    print(f"hex file does not match the JSON frame: {path}")
                    return 1
    return 0


def _hex_readme(manifest) -> str:
    rows = ["| vector | step | request | response | status |",
            "|---|---|---|---|---|"]
    for vector in manifest["vectors"]:
        for step in vector["steps"]:
            rows.append(f"| `{vector['name']}` | `{step['name']}` | "
                        f"`{step['request_file']}` ({step['request_bytes']} B) | "
                        f"`{step['response_file']}` ({step['response_bytes']} B) | "
                        f"{step['status']} |")
    return (
        "# R2 read vectors - $readmemh export\n\n"
        "Generated by `python3 -m tools.host_gui.r2_vectors --hex` from the same\n"
        "build as `../R2-READ-VERIFICATION.json`; `--check` proves every file\n"
        "here is byte-identical to the JSON frame, so a testbench can consume\n"
        "these files directly and there is no translation step.\n\n"
        f"**Status: NOT chip-confirmed** - {manifest['notice']}\n\n"
        "## Use\n\n"
        "```verilog\n"
        "logic [7:0] req_mem [0:255];\n"
        "initial $readmemh(\"read_imem_bounded.read_imem_address_1_count_2."
        "req.hex\", req_mem);\n"
        "```\n\n"
        "Each file is one byte per line, so `$readmemh` fills an 8-bit array\n"
        "from address 0 in wire order. `manifest.json` maps every vector/step to\n"
        "its files, expected status, expected response payload words and the\n"
        "sticky fault register after the step.\n\n"
        "## Files\n\n" + "\n".join(rows) + "\n")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate/check the R2 read verification package.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true",
                      help="write the artifact from a fresh build")
    mode.add_argument("--check", action="store_true",
                      help="fail if the checked-in artifact is stale")
    mode.add_argument("--hex", action="store_true",
                      help="write the $readmemh .hex export + manifest")
    args = parser.parse_args(argv)
    if args.write:
        print(f"wrote {write_package()}")
        return 0
    if args.hex:
        manifest = write_hex_export()
        files = sum(len(step["request_file"]) and 2
                    for vector in manifest["vectors"] for step in vector["steps"])
        print(f"wrote {HEX_DIR} ({files} .hex files + manifest.json)")
        return 0
    result = check_package()
    hex_result = check_hex_export()
    print("r2 verification package: up to date" if result == 0
          else "r2 verification package: STALE")
    print("r2 $readmemh export: up to date" if hex_result == 0
          else "r2 $readmemh export: STALE")
    return result or hex_result


if __name__ == "__main__":
    raise SystemExit(main())
