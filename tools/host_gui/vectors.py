"""The golden-vector package framework shared by every host read/debug phase.

R2 shipped its own generator (`r2_vectors.py`). R3 needs the same machinery --
derive every vector from the live model, ship the model image each vector
assumes, export `$readmemh` files plus a manifest, and gate the whole thing
against drift -- so the machinery lives HERE and each phase module is just a
configuration plus its vector list. Two properties are load-bearing:

* **The artifact cannot drift from the contract.** Every frame is produced by
  driving the live `FakePE` through the shared codec, and `--check` requires
  the checked-in JSON to equal a fresh build.
* **The checked-in R2 artifacts stay byte-identical across this refactor.**
  R2 is chip-confirmed (18/18 byte-exact in `tb_pe_ctrl_r2`) and the chip
  testbench consumes its hex export, so the extraction is not allowed to
  perturb a single byte of it. `r2_vectors --check` is the regression proof,
  and the R2 `Spec` passes `schema=None` so the new schema/phase keys are
  emitted for R3 only. Do not "tidy" R2's output.

Nothing this module produces is evidence about silicon. A package is the gate
the chip must pass; a step is chip-confirmed only when it appears in the
phase's `Spec.evidence` confirmed-step set with a citation, and nothing is
confirmed by assertion.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, field
from pathlib import Path

from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P

REPO_ROOT = Path(__file__).resolve().parents[2]
TARGET = P.TARGET_HOST

# Schema version stamped on packages produced by this framework. R2 predates
# it and is deliberately left unstamped so its confirmed artifacts stay
# byte-identical.
SCHEMA_VERSION = 1

# The fields a per-step chip-evidence citation is built from, in the order the
# R2 citation used. A phase with no confirmed steps never emits a citation.
CITATION_KEYS = ("review", "testbench", "conformance", "date", "scope")

# The default image a phase's hex export preloads (the lowest image id), and
# the words an image gets when the caller names none.
DEFAULT_LOAD_WORDS = (0x0041, 0x1001, 0x4002)


@dataclass(frozen=True)
class Spec:
    """One phase's package configuration (everything not R3-specific)."""

    phase: str
    title: str
    generated_by: str
    notice: str
    artifact: Path
    hex_dir: Path
    source_of_truth: tuple[str, ...]
    rulings: tuple[str, ...]
    evidence: dict
    word_order: str
    readmemh_usage: str
    load_procedure: str
    hex_readme_title: str
    hex_artifact: str
    hex_generated_by: str
    hex_readme_command: str
    hex_readme_intro: str
    labels: tuple[str, str]          # (package, export) CLI status labels
    protocol_extra: dict = field(default_factory=dict)
    load_words: tuple[int, ...] = DEFAULT_LOAD_WORDS
    schema: int | None = None

    @property
    def confirmed_steps(self) -> frozenset[str]:
        return frozenset(self.evidence.get("confirmed_steps", ()))

    def evidence_json(self) -> dict:
        """The evidence block with the confirmed-step set as a sorted list."""
        out = dict(self.evidence)
        out["confirmed_steps"] = sorted(self.confirmed_steps)
        return out

    def evidence_for(self, step_name: str) -> dict | None:
        """Citation for a step, or None when the chip has not confirmed it."""
        if step_name not in self.confirmed_steps:
            return None
        return {key: self.evidence.get(key) for key in CITATION_KEYS}


class Builder:
    """Builds one phase's package against the live model.

    `image_and_model` registers a declared model image and returns a model
    built from exactly that image, so the data a vector assumes and the frames
    it produces cannot disagree.
    """

    def __init__(self, spec: Spec) -> None:
        self.spec = spec
        self.images: dict[str, dict] = {}

    # ---- model images ------------------------------------------------------
    def image(self, image_id: str, *, imem=None, dmem=None, pc=0, a=0, x=0,
              y=0, insn=0, timer=0, run=0, faults=0, words_written=None,
              selected_target=0, debug=None) -> dict:
        """The exact model image a vector's steps assume, registered by id.

        Ships with the package so a chip testbench can preload the same bytes
        and registers: a sparse {address: byte} map plus a fill default for
        IMEM (1024 words) and DMEM (16 bytes), the architectural
        register/timer state, and -- for a debug phase -- the armed
        breakpoints and debug state. `debug` is omitted entirely when None, so
        a data-path phase's manifest keeps exactly the keys it always had.
        """
        imem_sparse = (dict(imem) if imem is not None
                       else {str(index): word for index, word
                             in enumerate(self.spec.load_words)})
        # Addresses are string keys from the start so the in-memory build and
        # the JSON round-trip compare equal (the drift gate caught exactly
        # that once).
        imem_sparse = {str(address): word for address, word in imem_sparse.items()}
        dmem_sparse = {str(address): byte for address, byte in (dmem or {}).items()}
        if words_written is None:
            words_written = len(imem_sparse)
        image = {
            "id": image_id,
            "imem": {"words": F.IMEM_WORDS, "fill": 0x0000, "sparse": imem_sparse},
            "dmem": {"bytes": F.DMEM_BYTES, "fill": 0x00, "sparse": dmem_sparse},
            "state": {"pc": pc, "a": a, "x": x, "y": y, "insn": insn,
                      "timer": timer, "run": run, "faults": faults,
                      "words_written": words_written,
                      "selected_target": selected_target},
        }
        if debug is not None:
            image["debug"] = _debug_image(debug)
        self.images[image_id] = image
        return image

    def model(self, image: dict) -> F.FakePE:
        """Build a FakePE from a declared image (no LOAD, no poking)."""
        return load_model_from_image(image)

    def image_and_model(self, image_id: str, **kwargs):
        image = self.image(image_id, **kwargs)
        return image, self.model(image)

    # ---- vectors and steps -------------------------------------------------
    def record(self, pe, name: str, opcode: int, payload_words, sequence: int,
               note: str = "", model_image_id: str | None = None) -> dict:
        """Drive one request through the model; capture request + response."""
        request_hex = frame(opcode, sequence, payload_words)
        response_raw = pe.exchange(bytes.fromhex(request_hex))
        assert response_raw is not None, f"no response for {name}"
        decoded = P.decode_frame(response_raw)
        record = {
            "name": name,
            "note": note,
            "opcode": opcode,
            "opcode_name": opcode_name(opcode),
            "sequence": sequence,
            "request_payload_words": list(payload_words),
            "request_hex": request_hex,
            "status": decoded.payload[0],
            "response_payload_words": list(decoded.payload),
            "response_hex": response_raw.hex(),
            "model_faults": pe.faults,
        }
        if model_image_id is not None:
            record["model_image_id"] = model_image_id
        evidence = self.spec.evidence_for(name)
        record["chip_confirmed"] = evidence is not None
        if evidence is not None:
            record["chip_evidence"] = evidence
        return record

    def vector(self, name: str, obligation: str, word_order: str, steps: list,
               image: dict) -> dict:
        return {"name": name, "obligation": obligation,
                "word_order": word_order,
                "chip_confirmed": all(step["chip_confirmed"] for step in steps),
                "model_image_id": image["id"],
                "steps": steps}

    def package(self, vectors: list) -> dict:
        """Assemble the phase's package dict from its vectors."""
        package = {
            "artifact": self.spec.title,
            "generated_by": self.spec.generated_by,
            "source_of_truth": list(self.spec.source_of_truth),
            "chip_confirmed": all(vector["chip_confirmed"] for vector in vectors),
            "chip_evidence": self.spec.evidence_json(),
            "notice": self.spec.notice,
            "rulings_applied": list(self.spec.rulings),
            "protocol": {
                "sync": P.SYNC,
                "version": P.VERSION,
                "header": "{version[3:0], opcode[7:0], target[3:0]}",
                "crc": "CRC-16/CCITT-FALSE",
                "crc_poly": 0x1021,
                "crc_init": 0xFFFF,
                "response_bit": P.RESPONSE_BIT,
                "word_order": self.spec.word_order,
                **self.spec.protocol_extra,
            },
            "memory": {"imem_words": F.IMEM_WORDS, "dmem_bytes": F.DMEM_BYTES},
            "status_codes": {name: getattr(P, name) for name in dir(P)
                             if name.startswith("STATUS_")},
            "model_images": self.images,
            "vectors": vectors,
        }
        if self.spec.schema is not None:
            package["schema"] = self.spec.schema
            package["phase"] = self.spec.phase
        return package


def _debug_image(debug: dict) -> dict:
    """Normalise a debug image declaration into JSON-stable types."""
    breakpoints = list(debug.get("breakpoints", []))
    out = {
        "breakpoints": [None if value is None
                        else _strict(value, "breakpoint address")
                        for value in breakpoints],
        "debug_state": _strict(debug.get("debug_state", F.DEBUG_STOPPED),
                               "debug_state"),
    }
    for key in ("hit_slot", "hit_address"):
        if key in debug:
            out[key] = (None if debug[key] is None
                        else _strict(debug[key], key))
    return out


def load_model_from_image(image: dict) -> F.FakePE:
    """Build a FakePE from a shipped model image (no LOAD, no poking).

    The inverse of what the generator did: a chip testbench preloads the same
    image and the conformance test regenerates every step from it, so the
    image and the frame streams cannot drift apart.
    """
    pe = F.FakePE()
    fill = _strict(image["imem"]["fill"], "imem fill")
    pe.imem = [fill] * _strict(image["imem"]["words"], "imem words")
    for address, word in image["imem"]["sparse"].items():
        pe.imem[_strict(address, "imem address")] = (
            _strict(word, "imem word") & 0xFFFF)
    dmem_fill = _strict(image["dmem"]["fill"], "dmem fill") & 0xFF
    pe.dmem = bytearray([dmem_fill]) * _strict(image["dmem"]["bytes"],
                                               "dmem bytes")
    for address, byte in image["dmem"]["sparse"].items():
        pe.dmem[_strict(address, "dmem address")] = (
            _strict(byte, "dmem byte") & 0xFF)
    state = image["state"]
    pe.pc = _strict(state["pc"], "pc") & F.ISA_PC_MASK
    pe.a = _strict(state["a"], "a") & F.ISA_REG_MASK
    pe.x = _strict(state["x"], "x") & F.ISA_REG_MASK
    pe.y = _strict(state["y"], "y") & F.ISA_REG_MASK
    pe.insn = _strict(state["insn"], "insn") & F.ISA_INSN_MASK
    pe.timer = _strict(state["timer"], "timer")
    pe.run = bool(state["run"])
    pe.faults = _strict(state["faults"], "faults")
    pe.words_written = _strict(state["words_written"], "words_written")
    pe.selected_target = _strict(state["selected_target"], "selected_target")
    debug = image.get("debug")
    if debug is not None:
        armed = [None if value is None else _strict(value, "breakpoint address")
                 for value in debug.get("breakpoints", [])]
        pe.breakpoints = (armed + [None] * F.MAX_BREAKPOINTS
                          )[:F.MAX_BREAKPOINTS]
        pe.debug_state = _strict(debug.get("debug_state", F.DEBUG_STOPPED),
                                 "debug_state")
        pe.hit_slot = debug.get("hit_slot")
        pe.hit_address = debug.get("hit_address")
    return pe

def frame(opcode: int, sequence: int, payload_words) -> str:
    """One framed request as hex, for the given target."""
    return P.encode_frame(opcode, sequence, TARGET,
                          b"".join(_strict(word, "payload word").to_bytes(2, "big")
                                   for word in payload_words)).hex()


def opcode_name(opcode: int) -> str:
    for name in dir(P):
        if name.startswith("OP_") and getattr(P, name) == opcode:
            return name
    return f"0x{opcode:02X}"


def _strict(value, what: str) -> int:
    """Normalise a manifest value to an int, or say exactly what was wrong.

    The drift gates read a checked-in artifact that a human can hand-edit, so
    a bad value must produce a diagnostic naming the field -- not
    `int("abc", 0)`'s bare "invalid literal", and never a silent truncation of
    a float. This is the one place the framework converts, so every model-image
    field gets the same strictness.
    """
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise TypeError(f"{what} must be an integer, got {value!r}")
    if isinstance(value, str):
        text = value.strip()
        negative = text.startswith("-")
        digits = text[1:] if negative else text
        if not digits or not all(char in "0123456789abcdefABCDEF"
                                 for char in digits):
            raise ValueError(f"{what} must be an integer, got {value!r}")
        value = int(digits, 16) if digits[:2].lower() == "0x" \
            else int(digits, 10)
        return -value if negative else value
    return value


def _hex_bytes(raw_hex: str) -> str:
    """$readmemh-ready byte stream: one lowercase two-digit byte per line.

    $readmemh fills an 8-bit array from address 0, so a testbench does
    ``$readmemh("....req.hex", req_mem);`` and clocks ``req_mem`` out. One byte
    per line (rather than packed words) keeps the stream identical to the JSON
    frame's bytes, which the conformance test asserts.
    """
    return "".join(f"{byte:02x}\n" for byte in bytes.fromhex(raw_hex))


def _read_hex(path: Path) -> bytes:
    """Read a $readmemh file back to bytes (whitespace-insensitive)."""
    return bytes.fromhex("".join(Path(path).read_text(encoding="utf-8").split()))


def _expand_image(image: dict) -> tuple[list[int], bytearray]:
    fill = _strict(image["imem"]["fill"], "imem fill")
    words = [fill] * _strict(image["imem"]["words"], "imem words")
    for address, word in image["imem"]["sparse"].items():
        words[_strict(address, "imem address")] = _strict(word, "imem word") & 0xFFFF
    dmem_fill = _strict(image["dmem"]["fill"], "dmem fill") & 0xFF
    data = bytearray([dmem_fill]) * _strict(image["dmem"]["bytes"], "dmem bytes")
    for address, byte in image["dmem"]["sparse"].items():
        data[_strict(address, "dmem address")] = _strict(byte, "dmem byte") & 0xFF
    return words, data


def write_image_hex(spec: Spec, images: dict, directory: Path) -> dict:
    """Write the full IMEM and DMEM images for `$readmemh` (see Spec)."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    default_id = min(images)
    words, data = _expand_image(images[default_id])
    (directory / "imem.hex").write_text(
        "".join(f"{word:04x}\n" for word in words), encoding="utf-8")
    (directory / "dmem.hex").write_text(
        "".join(f"{byte:02x}\n" for byte in data), encoding="utf-8")
    return {"imem_file": "imem.hex", "dmem_file": "dmem.hex",
            "image_id": default_id}


def write_package(spec: Spec, package: dict, path: Path | None = None) -> Path:
    path = Path(path or spec.artifact)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(package, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")
    return path


def check_package(spec: Spec, build, path: Path | None = None) -> int:
    """Drift gate: the checked-in artifact must match a fresh build.

    A corrupt or unreadable artifact is a gate FAILURE with a readable
    reason, not a traceback: a hand-edited or truncated JSON file must not
    crash the gate into an ambiguous exit.
    """
    path = Path(path or spec.artifact)
    if not path.is_file():
        print(f"missing artifact: {path}")
        return 1
    try:
        stored = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"artifact is unreadable or corrupt: {path} ({exc})")
        return 1
    try:
        fresh = build()
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"fresh build failed: {exc}")
        return 1
    if stored != fresh:
        print(f"artifact is stale: {path} (regenerate with --write)")
        return 1
    return 0


def write_hex_export(spec: Spec, package: dict,
                     directory: Path | None = None) -> dict:
    """Write per-step request/response .hex files plus a manifest."""
    directory = Path(directory or spec.hex_dir)
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
                "chip_confirmed": step.get("chip_confirmed", False),
                "chip_evidence": step.get("chip_evidence"),
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
    image_files = write_image_hex(spec, package["model_images"], directory)
    manifest = {
        "artifact": spec.hex_artifact,
        "generated_by": spec.hex_generated_by,
        "source_of_truth": package["source_of_truth"],
        "chip_confirmed": package["chip_confirmed"],
        "chip_evidence": package["chip_evidence"],
        "notice": package["notice"],
        "word_order": package["protocol"]["word_order"],
        "readmemh_usage": spec.readmemh_usage,
        "load_procedure": spec.load_procedure,
        "model_images": package["model_images"],
        "image_files": image_files,
        "vectors": vectors,
    }
    if spec.schema is not None:
        manifest["schema"] = spec.schema
        manifest["phase"] = spec.phase
    (directory / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    (directory / "README.md").write_text(hex_readme(spec, manifest),
                                         encoding="utf-8")
    return manifest


def check_hex_export(spec: Spec, build, directory: Path | None = None) -> int:
    """Drift gate: every .hex file must equal the JSON frame it came from,
    and the full IMEM/DMEM images must equal the shipped model image."""
    directory = Path(directory or spec.hex_dir)
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file():
        print(f"missing hex export: {manifest_path} (regenerate with --hex)")
        return 1
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"hex manifest is unreadable or corrupt: {manifest_path} ({exc})")
        return 1
    try:
        package = build()
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"fresh build failed: {exc}")
        return 1
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


def _check_image_files(directory: Path, images: dict, image_files: dict) -> int:
    """The full imem.hex/dmem.hex must equal the sparse image they came from."""
    imem_file = image_files.get("imem_file")
    dmem_file = image_files.get("dmem_file")
    if not imem_file or not dmem_file:
        print("hex manifest does not name the image files")
        return 1
    words, data = _expand_image(images[image_files["image_id"]])
    if _read_hex(directory / imem_file) != b"".join(
            word.to_bytes(2, "big") for word in words):
        print(f"{imem_file} does not match the shipped model image")
        return 1
    if _read_hex(directory / dmem_file) != bytes(data):
        print(f"{dmem_file} does not match the shipped model image")
        return 1
    return 0


def hex_readme(spec: Spec, manifest: dict) -> str:
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
        f"{spec.hex_readme_title}\n\n"
        f"Generated by `{spec.hex_readme_command}` {spec.hex_readme_intro}\n"
        "here is byte-identical to the JSON frame AND to the shipped model\n"
        "image, so a testbench can consume these files directly and there is\n"
        "no translation step.\n\n"
        f"**Status: NOT chip-confirmed** - {manifest['notice']}\n\n"
        "## Load procedure (Verilog)\n\n"
        "```verilog\n"
        "// 1. the model image: 1024 IMEM words, 16 DMEM bytes\n"
        "initial begin\n"
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


def run_cli(spec: Spec, build, argv=None) -> int:
    """The shared --write/--check/--hex entry point for a phase module."""
    parser = argparse.ArgumentParser(
        description=f"Generate/check the {spec.phase} verification package.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true",
                      help="write the artifact from a fresh build")
    mode.add_argument("--check", action="store_true",
                      help="fail if the checked-in artifact is stale")
    mode.add_argument("--hex", action="store_true",
                      help="write the $readmemh .hex export + manifest")
    args = parser.parse_args(argv)
    if args.write:
        print(f"wrote {write_package(spec, build())}")
        return 0
    if args.hex:
        manifest = write_hex_export(spec, build())
        count = sum(len(vector["steps"]) for vector in manifest["vectors"])
        print(f"wrote {spec.hex_dir} ({count * 2} .hex files + manifest.json)")
        return 0
    result = check_package(spec, build)
    hex_result = check_hex_export(spec, build)
    print(f"{spec.labels[0]}: "
          f"{'up to date' if result == 0 else 'STALE'}")
    print(f"{spec.labels[1]}: "
          f"{'up to date' if hex_result == 0 else 'STALE'}")
    return result or hex_result
