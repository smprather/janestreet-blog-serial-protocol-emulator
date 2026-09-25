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


def _image(image_id, *, imem=None, dmem=None, pc=0, a=0, x=0, y=0, insn=0,
           timer=0, run=0, faults=0, words_written=None,
           selected_target=0):
    """The exact model image a vector's steps assume.

    The data-path vectors only prove framing unless the chip's memories hold
    the same bytes, so the image ships with the package (manager ruling
    2026-09-25): a sparse {address: byte} map plus a fill default for IMEM
    (1024 words) and DMEM (16 bytes), and the architectural register/timer
    state STATUS and DUMP_CORE assume. `load_model_from_image` builds the
    model from exactly this dict, so the image and the frame streams cannot
    drift apart.
    """
    imem_sparse = (dict(imem) if imem is not None
                   else {str(index): word for index, word
                         in enumerate(LOAD_WORDS)})
    # Addresses are string keys from the start so the in-memory build and the
    # JSON round-trip compare equal (the drift gate caught exactly that).
    imem_sparse = {str(address): word for address, word in imem_sparse.items()}
    dmem_sparse = {str(address): byte
                   for address, byte in (dmem or {}).items()}
    if words_written is None:
        words_written = len(imem_sparse)
    return {
        "id": image_id,
        "imem": {"words": F.IMEM_WORDS, "fill": 0x0000, "sparse": imem_sparse},
        "dmem": {"bytes": F.DMEM_BYTES, "fill": 0x00, "sparse": dmem_sparse},
        "state": {"pc": pc, "a": a, "x": x, "y": y, "insn": insn,
                  "timer": timer, "run": run, "faults": faults,
                  "words_written": words_written,
                  "selected_target": selected_target},
    }


def load_model_from_image(image):
    """Build a FakePE from a shipped model image (no LOAD, no poking).

    This is the inverse of what the vector generator did, and the conformance
    test uses it to regenerate every step from the image that ships beside the
    streams and assert byte-identity.
    """
    pe = F.FakePE()
    fill = int(str(image["imem"]["fill"]), 0)
    pe.imem = [fill] * int(image["imem"]["words"])
    for address, word in image["imem"]["sparse"].items():
        pe.imem[int(address)] = int(str(word), 0) & 0xFFFF
    dmem_fill = int(str(image["dmem"]["fill"]), 0) & 0xFF
    pe.dmem = bytearray([dmem_fill]) * int(image["dmem"]["bytes"])
    for address, byte in image["dmem"]["sparse"].items():
        pe.dmem[int(address)] = int(str(byte), 0) & 0xFF
    state = image["state"]
    pe.pc = int(state["pc"]) & F.ISA_PC_MASK
    pe.a = int(state["a"]) & F.ISA_REG_MASK
    pe.x = int(state["x"]) & F.ISA_REG_MASK
    pe.y = int(state["y"]) & F.ISA_REG_MASK
    pe.insn = int(state["insn"]) & F.ISA_INSN_MASK
    pe.timer = int(state["timer"])
    pe.run = bool(state["run"])
    pe.faults = int(state["faults"])
    pe.words_written = int(state["words_written"])
    pe.selected_target = int(state["selected_target"])
    return pe


def write_image_hex(directory=HEX_DIR):
    """Write the full IMEM (1024 words) and DMEM (16 bytes) for $readmemh.

    IMEM is word-addressed in the chip, so `imem.hex` is one 16-bit word per
    line in ascending address order; DMEM is byte-addressed, so `dmem.hex` is
    one byte per line. The files are built from the *default* vector's image
    (the first vector's), which is the one a data-path TB wants to preload.
    """
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    image = build_package()["model_images"]
    default_id = min(image)
    source = image[default_id]
    fill = int(str(source["imem"]["fill"]), 0)
    words = [fill] * int(source["imem"]["words"])
    for address, word in source["imem"]["sparse"].items():
        words[int(address)] = int(str(word), 0) & 0xFFFF
    (directory / "imem.hex").write_text(
        "".join(f"{word:04x}\n" for word in words), encoding="utf-8")
    dmem_fill = int(str(source["dmem"]["fill"]), 0) & 0xFF
    data = bytearray([dmem_fill]) * int(source["dmem"]["bytes"])
    for address, byte in source["dmem"]["sparse"].items():
        data[int(address)] = int(str(byte), 0) & 0xFF
    (directory / "dmem.hex").write_text(
        "".join(f"{byte:02x}\n" for byte in data), encoding="utf-8")
    return {"imem_file": "imem.hex", "dmem_file": "dmem.hex",
            "image_id": default_id}


def _frame(opcode, sequence, payload_words):
    return P.encode_frame(opcode, sequence, TARGET,
                          b"".join(int(w).to_bytes(2, "big")
                                   for w in payload_words)).hex()


def _record(pe, name, opcode, payload_words, sequence, note="",
            model_image_id=None):
    """Drive one request through the model and capture request + response."""
    request_hex = _frame(opcode, sequence, payload_words)
    response_raw = pe.exchange(bytes.fromhex(request_hex))
    assert response_raw is not None, f"no response for {name}"
    frame = P.decode_frame(response_raw)
    record = {
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
    if model_image_id is not None:
        record["model_image_id"] = model_image_id
    return record


def _opcode_name(opcode):
    for name in dir(P):
        if name.startswith("OP_") and getattr(P, name) == opcode:
            return name
    return f"0x{opcode:02X}"


def _loaded_model(*, pc=0, a=0, x=0, y=0, insn=0, timer=0, dmem=b"",
                  running=False):
    """Kept for the probe-style helpers; vectors now go through the image."""
    pe = F.FakePE()
    pe.request(P.OP_LOAD, payload_words=LOAD_WORDS)
    pe.pc, pe.a, pe.x, pe.y = pc, a, x, y
    pe.insn, pe.timer = insn, timer
    if dmem:
        pe.dmem[0:len(dmem)] = dmem
    pe.run = running
    return pe


def _vector(name, obligation, word_order, steps, image):
    return {"name": name, "obligation": obligation, "word_order": word_order,
            "chip_confirmed": False, "model_image_id": image["id"],
            "steps": steps}


def build_package() -> dict:
    """Derive the whole R2 verification package from the live model.

    Every vector is generated from a declared model image (memories plus the
    architectural register/timer state), and each step names the image it
    assumes, so a data-path check proves the *data*, not only the framing.
    """
    vectors = []
    images = {}

    def image_and_model(image_id, **kwargs):
        image = _image(image_id, **kwargs)
        images[image_id] = image
        return image, load_model_from_image(image)

    # 1. Bounded IMEM read, low word first ascending.
    image, pe = image_and_model("v01-read_imem_bounded")
    vectors.append(_vector(
        "read_imem_bounded", R.by_name()["read_imem_bounded"].description,
        "low-word-first ascending",
        [_record(pe, "read_imem_address_1_count_2", P.OP_READ_IMEM, (1, 2), 1,
                 "words 1,2 returned in ascending order", image["id"])],
        image))

    # 2. Bounded DMEM read: bytes packed big-endian per word.
    image, pe = image_and_model("v02-read_dmem_bounded",
                                dmem={0: 0x0A, 1: 0x0B, 2: 0x0C, 3: 0x0D})
    vectors.append(_vector(
        "read_dmem_bounded", R.by_name()["read_dmem_bounded"].description,
        "bytes big-endian per word, ascending",
        [_record(pe, "read_dmem_address_0_count_4", P.OP_READ_DMEM, (0, 4), 1,
                 "bytes 0..3 -> 0x0A0B, 0x0C0D", image["id"])],
        image))

    # 3. DUMP_CORE header equals the STATUS header while stopped.
    image, pe = image_and_model("v03-dump_core_header", pc=0x123, a=0x45,
                                x=0x78, y=0x9A, timer=7)
    vectors.append(_vector(
        "dump_core_header", R.by_name()["dump_core_header"].description,
        "n/a (register header)",
        [_record(pe, "dump_core_header", P.OP_DUMP_CORE, (), 1,
                 "stable register header while stopped", image["id"]),
         _record(pe, "status_header", P.OP_STATUS, (), 2,
                 "must equal the dump_core header", image["id"])],
        image))

    # 4. READ_CPU is non-halting and carries full-width registers.
    image, pe = image_and_model("v04-read_cpu_non_halting", pc=ISA_PC_MAX,
                                a=ISA_REG_MAX, x=ISA_REG_MAX, y=ISA_REG_MAX,
                                insn=ISA_INSN_MAX, run=1)
    vectors.append(_vector(
        "read_cpu_non_halting", R.by_name()["read_cpu_non_halting"].description,
        "n/a (register header)",
        [_record(pe, "read_cpu_while_running", P.OP_READ_CPU, (), 1,
                 "answers while run=1; pc/a/x/y/insn full width", image["id"])],
        image))

    # 4b. Full-width debug registers (the anti-truncation vector). Widths are
    # the ISA's: pc 10 bits, a/x/y 8, insn 16 - the "full width" obligation is
    # that R2 exposes every bit the chip has, not that more exist.
    image, pe = image_and_model("v05-full_width_debug_regs", pc=ISA_PC_MAX,
                                a=ISA_REG_MAX, x=ISA_REG_MAX, y=ISA_REG_MAX,
                                insn=ISA_INSN_MAX)
    vectors.append(_vector(
        "full_width_debug_regs",
        R.by_name()["full_width_debug_regs"].description,
        "n/a (register header)",
        [_record(pe, "read_cpu_full_width_regs", P.OP_READ_CPU, (), 1,
                 f"pc=0x{ISA_PC_MAX:03X}, a=x=y=0x{ISA_REG_MAX:02X}, "
                 f"insn=0x{ISA_INSN_MAX:04X}", image["id"])],
        image))

    # 5. Reads while running are rejected (chip-side, R2).
    image, pe = image_and_model("v06-read_while_running_rejected", run=1)
    vectors.append(_vector(
        "read_while_running_rejected",
        R.by_name()["read_while_running_rejected"].description,
        "n/a (status only)",
        [_record(pe, "read_imem_not_ready", P.OP_READ_IMEM, (0, 1), 1, "",
                 image["id"]),
         _record(pe, "read_dmem_not_ready", P.OP_READ_DMEM, (0, 1), 2, "",
                 image["id"]),
         _record(pe, "dump_core_not_ready", P.OP_DUMP_CORE, (), 3, "",
                 image["id"])],
        image))

    # 6. Range never wraps: past-the-end reads are RANGE, not wrapped data.
    image, pe = image_and_model("v07-range_never_wraps")
    vectors.append(_vector(
        "range_never_wraps", R.by_name()["range_never_wraps"].description,
        "n/a (rejected)",
        [_record(pe, "read_imem_last_word", P.OP_READ_IMEM, (1023, 1), 1,
                 "the last word is readable", image["id"]),
         _record(pe, "read_imem_past_end_no_wrap", P.OP_READ_IMEM, (1023, 2), 2,
                 "RANGE, never a wrapped read", image["id"]),
         _record(pe, "read_dmem_past_end_no_wrap", P.OP_READ_DMEM, (15, 2), 3,
                 "RANGE, never a wrapped read", image["id"])],
        image))

    # 7. The sticky-fault lifecycle: bad read -> RANGE + FAULT_RANGE, status
    #    shows the sticky bit, CLEAR_FAULT clears it (manager ruling).
    image, pe = image_and_model("v08-read_range_fault_lifecycle")
    lifecycle = [
        _record(pe, "bad_read_answers_range", P.OP_READ_IMEM, (2000, 1), 1,
                "out-of-range read: RANGE and latches sticky FAULT_RANGE",
                image["id"]),
        _record(pe, "status_shows_sticky_fault", P.OP_STATUS, (), 2,
                "the sticky fault bit is visible before any clear", image["id"]),
        _record(pe, "clear_fault_clears_the_bit", P.OP_CLEAR_FAULT,
                (F.FAULT_RANGE,), 3, "CLEAR_FAULT(0x4) returns faults=0",
                image["id"]),
    ]
    vectors.append(_vector(
        "read_range_fault_lifecycle",
        "An out-of-range READ latches sticky FAULT_RANGE and CLEAR_FAULT "
        "clears it (manager ruling).",
        "n/a (status/lifecycle)",
        lifecycle,
        image))

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
            ("the package ships the MODEL IMAGE (imem/dmem/registers) each "
             "vector assumes, so data-path reads prove data, not just "
             "framing (manager ruling 2026-09-25)"),
            ("register widths are the ISA's: pc 10, a/x/y 8, insn 16 "
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
        "model_images": images,
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
                "model_image_id": step.get("model_image_id"),
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
                        "model_image_id": vector["model_image_id"],
                        "steps": steps})
    images = write_image_hex(directory)
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
        "load_procedure": (
            "1) imem.hex: one 16-bit word per line, ascending address, for "
            "$readmemh into a 16-bit imem[0:1023]. 2) dmem.hex: one byte per "
            "line for $readmemh into an 8-bit dmem[0:15]. 3) preload the "
            "registers from model_images[].state (pc/a/x/y/insn/timer/run/"
            "faults/words_written) for the vector under test. 4) drive the "
            "step's request_file and compare the response against "
            "response_file."),
        "model_images": package["model_images"],
        "image_files": images,
        "vectors": vectors,
    }
    (directory / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    (directory / "README.md").write_text(_hex_readme(manifest), encoding="utf-8")
    return manifest


def check_hex_export(directory=HEX_DIR) -> int:
    """Drift gate: every .hex file must equal the JSON frame it came from,
    and the full IMEM/DMEM images must equal the shipped model image."""
    directory = Path(directory)
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file():
        print(f"missing hex export: {manifest_path} (regenerate with --hex)")
        return 1
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    package = build_package()
    built = {vector["name"]: vector for vector in package["vectors"]}
    for vector in manifest.get("vectors", []):
        source = built.get(vector["name"])
        if source is None:
            print(f"hex manifest names an unknown vector: {vector['name']}")
            return 1
        if vector.get("model_image_id") not in manifest.get("model_images", {}):
            print(f"hex manifest has no image for {vector['name']}")
            return 1
        for index, step in enumerate(vector["steps"]):
            expected = source["steps"][index]
            if step.get("model_image_id") != expected.get("model_image_id"):
                print(f"step image reference drifted: {vector['name']}")
                return 1
            for key, raw in (("request_file", expected["request_hex"]),
                             ("response_file", expected["response_hex"])):
                path = directory / step[key]
                if not path.is_file():
                    print(f"missing hex file: {path}")
                    return 1
                if _read_hex(path) != bytes.fromhex(raw):
                    print(f"hex file does not match the JSON frame: {path}")
                    return 1
    images = manifest.get("model_images", {})
    if images != package["model_images"]:
        print("hex manifest images do not match a fresh build")
        return 1
    return _check_image_files(directory, images,
                              manifest.get("image_files", {}))


def _check_image_files(directory, images, image_files) -> int:
    """The full imem.hex/dmem.hex must equal the sparse image they came from."""
    imem_file = image_files.get("imem_file")
    dmem_file = image_files.get("dmem_file")
    if not imem_file or not dmem_file:
        print("hex manifest does not name the image files")
        return 1
    source = images[image_files["image_id"]]
    fill = int(str(source["imem"]["fill"]), 0)
    words = [fill] * int(source["imem"]["words"])
    for address, word in source["imem"]["sparse"].items():
        words[int(address)] = int(str(word), 0) & 0xFFFF
    if _read_hex(directory / imem_file) != b"".join(
            word.to_bytes(2, "big") for word in words):
        print(f"{imem_file} does not match the shipped model image")
        return 1
    dmem_fill = int(str(source["dmem"]["fill"]), 0) & 0xFF
    data = bytearray([dmem_fill]) * int(source["dmem"]["bytes"])
    for address, byte in source["dmem"]["sparse"].items():
        data[int(address)] = int(str(byte), 0) & 0xFF
    if _read_hex(directory / dmem_file) != bytes(data):
        print(f"{dmem_file} does not match the shipped model image")
        return 1
    return 0


def _hex_readme(manifest) -> str:
    rows = ["| vector | image | step | request | response | status |",
            "|---|---|---|---|---|---|"]
    for vector in manifest["vectors"]:
        for step in vector["steps"]:
            rows.append(f"| `{vector['name']}` | "
                        f"`{vector.get('model_image_id', '-')}` | "
                        f"`{step['name']}` | "
                        f"`{step['request_file']}` ({step['request_bytes']} B) | "
                        f"`{step['response_file']}` ({step['response_bytes']} B) | "
                        f"{step['status']} |")
    images = manifest.get("image_files", {})
    return (
        "# R2 read vectors - $readmemh export\n\n"
        "Generated by `python3 -m tools.host_gui.r2_vectors --hex` from the same\n"
        "build as `../R2-READ-VERIFICATION.json`; `--check` proves every file\n"
        "here is byte-identical to the JSON frame AND to the shipped model\n"
        "image, so a testbench can consume these files directly and there is\n"
        "no translation step.\n\n"
        f"**Status: NOT chip-confirmed** - {manifest['notice']}\n\n"
        "## Load procedure (Verilog)\n\n"
        "```verilog\n"
        "// 1. the model image: 1024 IMEM words, 16 DMEM bytes\n"
        f"initial begin\n"
        f'  $readmemh("{images.get("imem_file", "imem.hex")}", imem);'
        f'   // logic [15:0] imem [0:1023]\n'
        f'  $readmemh("{images.get("dmem_file", "dmem.hex")}", dmem);'
        f'   // logic [7:0]  dmem [0:15]\n'
        "end\n"
        "// 2. preload the registers for the vector under test from\n"
        "//    model_images[].state in manifest.json:\n"
        "//      pc (10b), a/x/y (8b), insn (16b), timer, run, faults,\n"
        "//      words_written\n"
        "// 3. drive the step's request_file and compare against response_file\n"
        "```\n\n"
        "`imem.hex` is one 16-bit word per line in ascending address order;\n"
        "`dmem.hex` is one byte per line. The per-step request/response files\n"
        "are one byte per line in wire order.\n\n"
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
