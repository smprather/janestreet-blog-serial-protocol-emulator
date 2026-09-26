"""R2 read verification package: the R2 configuration over the shared framework.

The generator machinery -- declare a model image, drive the live model, ship
the image, export `$readmemh` files, and gate the whole artifact against
drift -- lives in `tools/host_gui/vectors.py`, shared with R3. This module is
the R2 configuration (its evidence block, its rulings, its artifact paths) plus
the R2 vector list.

**The checked-in R2 artifacts must stay byte-identical for the 18 steps the
chip has confirmed, and they must stay TRUE.** Those two are different
promises and both are enforced here. The chip's `tb_pe_ctrl_r2.v` consumes
this hex export and passes those 18 steps byte-exactly, so
`python3 -m tools.host_gui.r2_vectors --check` plus the byte fingerprint in
`tests/test_r2_vectors.py` are the regression proof: adding a vector is
allowed, changing a published byte is not. The prose around them is NOT
frozen -- `PACKAGE_NOTICE`, the evidence counts and the rulings state what is
and is not confirmed, so a step added without a chip re-run makes them say so
(the R3 review found a shipped notice claiming the opposite of the flags in
the same file, and the drift gate cannot catch that because both come from
this module).

Who uses it: the chip manager hands this to the protocol worker as the R2
acceptance spec. Each step carries the exact framed request and response bytes
(hex), the request payload words, the response payload words and the status, so
a Verilog testbench can drive the frames and compare the response word for word
without importing anything from Python.

Manager RULINGs encoded here (2026-09-25):
  * an out-of-range READ answers `RANGE` *and* latches sticky `FAULT_RANGE`
    (0x4); `CLEAR_FAULT` with mask 0x4 clears it;
  * READ payload is low-word-first, ascending, matching LOAD's stream - so
    `READ_IMEM(a, n)` returns words `a..a+n-1` in order and `READ_DMEM(a, n)`
    packs bytes `a..a+n-1` big-endian into each word.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P
from tools.host_gui import r2_reads as R
from tools.host_gui import vectors as V

REPO_ROOT = V.REPO_ROOT
ARTIFACT = REPO_ROOT / "reviews" / "2026-09-25" / "R2-READ-VERIFICATION.json"
README = REPO_ROOT / "reviews" / "2026-09-25" / "R2-READ-VERIFICATION.md"
HEX_DIR = REPO_ROOT / "reviews" / "2026-09-25" / "r2-hex"

TARGET = P.TARGET_HOST
LOAD_WORDS = V.DEFAULT_LOAD_WORDS

# The 18 steps the chip has confirmed, as a TUPLE rather than a set literal:
# the flag-flip rewrites this literal, and a tuple gives it one unambiguous
# start and end to anchor on (a set literal has neither). The order is the
# package's own step order, so the published list reads like the run.
CONFIRMED_STEP_NAMES = (
    "read_imem_address_1_count_2",
    "read_dmem_address_0_count_4",
    "dump_core_header",
    "status_header",
    "read_cpu_while_running",
    "read_cpu_full_width_regs",
    "read_imem_not_ready",
    "read_dmem_not_ready",
    "dump_core_not_ready",
    "read_imem_last_word",
    "read_imem_past_end_no_wrap",
    "read_dmem_past_end_no_wrap",
    # the sticky-fault lifecycle trio (chip-confirmed with the rest)
    "bad_read_answers_range",
    "status_shows_sticky_fault",
    "clear_fault_clears_the_bit",
    # Host-side ceiling + zero-count vectors, added after the chip review; the
    # chip re-ran them and they pass byte-exact (conformance 18/18; the ceiling
    # and count==0->RANGE rules needed no RTL change).
    "read_imem_at_ceiling_15",
    "read_imem_over_ceiling",
    "read_dmem_zero_count",
)

# The four held-core steps the chip has NOT re-run. Named here rather than
# derived, so the flip has a target list that cannot silently become empty.
HELD_STEP_NAMES = (
    "status_reports_the_hold",
    "dump_core_answers_the_same_header",
    "status_reports_the_hit",
    "dump_core_refused_the_strap_is_high",
)

# The published bytes of every confirmed step: (request, response). THE FREEZE.
# It lives here, beside the evidence, rather than in the test suite, because the
# flip has to extend it atomically with the flags it is a statement about; the
# test still compares every pair against a FRESH BUILD, which is the invariant
# that matters (the freeze is against the model, not against this file).
CONFIRMED_STEP_BYTES = {
    "read_imem_address_1_count_2": (
        "a55a11300001000200010002b9cd",
        "a55a193000010003000010014002ca95",
    ),
    "read_dmem_address_0_count_4": (
        "a55a1140000100020000000445e0",
        "a55a19400001000300000a0b0c0d7c84",
    ),
    "dump_core_header": (
        "a55a1150000100009b96",
        "a55a19500001000b0000000000000000012300450078009a000700000003e6c0",
    ),
    "status_header": (
        "a55a111000020000d3ae",
        "a55a19100002000b0000000000000000012300450078009a0007000000032139",
    ),
    "read_cpu_while_running": (
        "a55a1120000100008610",
        "a55a192000010007000003ff00ff00ff00ffffff0001d415",
    ),
    "read_cpu_full_width_regs": (
        "a55a1120000100008610",
        "a55a192000010007000003ff00ff00ff00ffffff0000c434",
    ),
    "read_imem_not_ready": (
        "a55a11300001000200000001be9e",
        "a55a1930000100010006dd58",
    ),
    "read_dmem_not_ready": (
        "a55a11400002000200000001cdc7",
        "a55a1940000200010006b7eb",
    ),
    "dump_core_not_ready": (
        "a55a115000030000f5f6",
        "a55a19500003000100062ac1",
    ),
    "read_imem_last_word": (
        "a55a11300001000203ff0001ea21",
        "a55a19300001000200000000e4f4",
    ),
    "read_imem_past_end_no_wrap": (
        "a55a11300002000203ff000202c0",
        "a55a1930000200010003632f",
    ),
    "read_dmem_past_end_no_wrap": (
        "a55a114000030002000f000269f4",
        "a55a19400003000100034d1f",
    ),
    "read_imem_at_ceiling_15": (
        "a55a1130000100020000000f5f50",
        "a55a19300001001000000041100140020000000000000000000000000000000000000000000000001b97",
    ),
    "read_imem_over_ceiling": (
        "a55a11300002000200000010640c",
        "a55a1930000200010003632f",
    ),
    "read_dmem_zero_count": (
        "a55a114000030002000000006587",
        "a55a19400003000100034d1f",
    ),
    "bad_read_answers_range": (
        "a55a11300001000207d000018a27",
        "a55a19300001000100038dfd",
    ),
    "status_shows_sticky_fault": (
        "a55a111000020000d3ae",
        "a55a19100002000b0000000000000000000000000000000000000004000323b2",
    ),
    "clear_fault_clears_the_bit": (
        "a55a11600003000100044dd4",
        "a55a196000030002000000008830",
    ),
}

CHIP_EVIDENCE = {
    "confirmed_steps": set(CONFIRMED_STEP_NAMES),
    "review": "chip repo: reviews/2026-09-25/R2-READ-PATH-REVIEW.md "
    "(section 'Conformance', per-vector table)",
    "testbench": "chip repo: tb/tb_pe_ctrl_r2.v",
    "harness": "chip-side TB loads imem.hex/dmem.hex, applies each vector's "
    "sparse overrides and register state, replays the 3-word LOAD "
    "precondition as a real framed frame, and compares every "
    "response byte (skipping wait words) to the golden stream",
    "conformance": "18/18 of the R2 read-path golden steps PASS, byte-exact "
    "including CRC. The 4 held-core steps below are NOT part of that run: "
    "tb_pe_ctrl_r2 instantiates pe_ctrl without the R3 debug inputs, so it "
    "cannot reach state 2/3 at all. The chip must re-run it against them.",
    "pending_steps": HELD_STEP_NAMES,
    "pending_reason": "These four steps were added on 2026-09-25 because R3's "
    "debug work made the R2 readback reachable in states 2 (DEBUG_HOLD) and 3 "
    "(BP_HIT) while no R2 vector exercised either - a chip right on states "
    "0/1 and wrong on the held ones passed 18/18. They are contract-derived "
    "expectations, NOT evidence: chip_confirmed=false until the chip re-runs "
    "tb_pe_ctrl_r2 with the debug inputs driven and flips them with a "
    "citation.",
    "scope": "This confirms the chip RTL in SIMULATION against the golden "
    "package. The real-board acceptance run (Pico over USB, physical "
    "shuttle) is still unexecuted and is not claimed here.",
    "date": "2026-09-25",
}


HARDWARE_BOUNDARY = (
    "NOT HARDWARE-CONFIRMED: the real-board acceptance run (Pico over USB CDC "
    "with a physical shuttle) has NOT been executed and is not claimed here. "
    "The host probes in r2_reads.py still run against the FakePE model; what "
    "the chip confirms is that the RTL matches these same expectations."
)


def notice_for(*, confirmed: int, pending) -> str:
    """The shipped notice, GENERATED from the flag arithmetic.

    This is the F1 lesson applied structurally. The R3 review found a shipped
    notice claiming the opposite of the flags in the same file, and the drift
    gate STRUCTURALLY cannot catch that: the notice and the flags come from
    this one source, so a fresh build faithfully reproduces whatever stale
    prose sits here. Hand-maintaining a claim that the gate cannot check is
    the defect, so the claim is now an expression of the numbers instead of a
    sentence about them - there is no way to be right about one and wrong
    about the other.
    """
    total = confirmed + len(pending)
    where = ("the chip repo's reviews/2026-09-25/R2-READ-PATH-REVIEW.md, "
             "section 'Conformance'")
    if not pending:
        return (
            f"CHIP-CONFIRMED IN SIMULATION: all {total} golden steps in this "
            f"package pass byte-exactly (CRC included) in the chip repo's "
            f"tb/tb_pe_ctrl_r2.v, with the model image loaded per vector; see "
            f"{where}, which names every step ({confirmed}/{confirmed}). "
            + HARDWARE_BOUNDARY
        )
    named = ", ".join(pending)
    return (
        f"PARTIALLY CHIP-CONFIRMED IN SIMULATION: {confirmed} of the {total} "
        f"golden steps in this package - every R2 read-path step - pass "
        f"byte-exactly (CRC included) in the chip repo's tb/tb_pe_ctrl_r2.v, "
        f"with the model image loaded per vector; see {where}, which names "
        f"every one of them ({confirmed}/{confirmed}). NOT CHIP-CONFIRMED: "
        f"the {len(pending)} steps added 2026-09-25 for the R2 readback while "
        f"the core is HELD at a breakpoint - {named} (state 2, a step-pause, "
        f"and state 3, a live hit). Their expectations come from the frozen "
        f"contract semantics, the chip has not re-run tb_pe_ctrl_r2 against "
        f"them, and they are a gate, not evidence. " + HARDWARE_BOUNDARY
    )


def _notice(evidence: dict) -> str:
    """The notice for an evidence block (the module's own, and a flipped one)."""
    return notice_for(confirmed=len(evidence.get("confirmed_steps", ())),
                      pending=tuple(evidence.get("pending_steps", ())))


PACKAGE_NOTICE = _notice(CHIP_EVIDENCE)

# The R2 package is the FIRST package, so it predates the framework's schema
# stamp: `schema=None` keeps its JSON and manifest keys exactly as they were,
# which is what "byte-identical" means here.
SPEC = V.Spec(
    phase="R2",
    title="R2 read-path verification package",
    generated_by="tools/host_gui/r2_vectors.py (build_package)",
    notice=PACKAGE_NOTICE,
    artifact=ARTIFACT,
    hex_dir=HEX_DIR,
    source_of_truth=(
        "tools/host_gui/r2_reads.py",
        "tools/host_gui/fake_pe.py",
        "tools/host_gui/protocol.py",
    ),
    rulings=(
        (
            "out-of-range READ latches sticky FAULT_RANGE (0x4); "
            "CLEAR_FAULT clears it (manager ruling 2026-09-25)"
        ),
        (
            "READ payload is low-word-first ascending, matching LOAD "
            "(manager ruling 2026-09-25)"
        ),
        (
            "the package ships the MODEL IMAGE (imem/dmem/registers) each "
            "vector assumes, so data-path reads prove data, not just "
            "framing (manager ruling 2026-09-25)"
        ),
        (
            "register widths are the ISA's: pc 10, a/x/y 8, insn 16 "
            "(manager ruling 2026-09-25)"
        ),
        (
            f"chip R2 CONFIRMED: {CHIP_EVIDENCE['conformance'].split('.')[0]} "
            f"({CHIP_EVIDENCE['testbench']})"
        ),
        (
            "the R2 register readback reports the DEBUG state, and the two "
            "halves are distinguishable: the state word is "
            "`dbg_hold ? (bp_hit ? 3 : 2) : (run ? 1 : 0)`, a breakpoint hit "
            "holds the CORE and not the run strap (so state 3 arrives with "
            "run=1), and DUMP_CORE is gated on the raw run strap - so it "
            "answers the full header under a step-pause and NOT_READY under a "
            "live hit (frozen contract semantics, 2026-09-25)"
        ),
    ),
    evidence=CHIP_EVIDENCE,
    word_order="big-endian words on the wire; READ payload low-word-first ascending",
    readmemh_usage=(
        '$readmemh("<file>", mem); with an 8-bit mem[] filled from '
        "address 0; the stream is the frame's bytes in wire order."
    ),
    load_procedure=(
        "1) imem.hex: one 16-bit word per line, ascending address, for "
        "$readmemh into a 16-bit imem[0:1023]. 2) dmem.hex: one byte per "
        "line for $readmemh into an 8-bit dmem[0:15]. 3) preload the "
        "registers from model_images[].state (pc/a/x/y/insn/timer/run/"
        "faults/words_written) for the vector under test. 4) drive the "
        "step's request_file and compare the response against "
        "response_file."
    ),
    hex_readme_title="# R2 read vectors - $readmemh export",
    hex_artifact="R2 read-path $readmemh export",
    hex_generated_by="tools/host_gui/r2_vectors.py (--hex)",
    hex_readme_command="python3 -m tools.host_gui.r2_vectors --hex",
    hex_readme_intro=(
        "from the same\nbuild as `../R2-READ-VERIFICATION.json`; "
        "`--check` proves every file\n"
    ),
    labels=("r2 verification package", "r2 $readmemh export"),
    load_words=LOAD_WORDS,
    schema=None,
)

ISA_PC_MAX = (1 << F.ISA_PC_BITS) - 1
ISA_REG_MAX = (1 << F.ISA_A_BITS) - 1
ISA_INSN_MAX = (1 << F.ISA_INSN_BITS) - 1


# ---- the flag-flip choreography --------------------------------------------
class FlipRefused(RuntimeError):
    """The flip was REFUSED and nothing was changed. Always with a reason."""


def _source_literal(source: str, name: str):
    """Read a module-level literal out of source, without executing it.

    Executing the source would re-run the whole module for a transform that
    only needs three constants, and it would run it on a string that is not
    necessarily the module. So the constants are PARSED.
    """
    for node in ast.parse(source).body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == name:
                return ast.literal_eval(node.value)
    raise FlipRefused(f"no module-level literal named {name} to work from")


def _replace_span(source: str, start: str, end: str, replacement: str,
                  what: str) -> str:
    """Replace the text between two markers, or refuse.

    The lesson from my own F1 fix (r3_vectors, 2026-09-25): a `str.replace`
    whose result is not asserted is a silent no-op that still prints "updated".
    So every span is located, counted, and checked, and a formatting change
    upstream produces a clean refusal with a reason rather than a half-flip.
    """
    first = source.find(start)
    if first < 0:
        raise FlipRefused(f"{what}: the start marker {start!r} is gone")
    if source.find(start, first + 1) >= 0:
        raise FlipRefused(f"{what}: the start marker {start!r} is ambiguous")
    last = source.find(end, first + len(start))
    if last < 0:
        raise FlipRefused(f"{what}: the end marker {end!r} is gone")
    return source[:first + len(start)] + replacement + source[last:]


def _literal_bounds(source: str, name: str) -> tuple[int, int]:
    """The 1-based line of a literal's CLOSING bracket and of its first element.

    Found through the AST rather than by searching for a name, so the
    insertion point survives reformatting and does not hard-code whichever step
    happens to be last today.
    """
    for node in ast.parse(source).body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == name:
                if node.end_lineno is None or node.value.end_lineno is None:
                    raise FlipRefused(
                        f"{name}: the literal has no end position, so there "
                        f"is nowhere to insert; the module may be a stub")
                return node.end_lineno, node.value.end_lineno
    raise FlipRefused(f"no module-level literal named {name} to work from")


def _evidence_is_already_flipped(source: str) -> bool:
    """True when this source's evidence block has an EMPTY pending set.

    Read from the PARSED evidence block, not by searching the text for a
    marker: the flip's own guard contains that marker as a string literal, so a
    text search finds itself and the "already confirmed" check never fires.
    """
    for node in ast.parse(source).body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if not (isinstance(target, ast.Name) and target.id == "CHIP_EVIDENCE"):
                continue
            if not isinstance(node.value, ast.Dict):
                raise FlipRefused("CHIP_EVIDENCE is not a dict literal")
            for key, value in zip(node.value.keys, node.value.values):
                if not (isinstance(key, ast.Constant) and key.value == "pending_steps"):
                    continue
                return isinstance(value, (ast.Tuple, ast.List)) and not value.elts
            raise FlipRefused("the evidence block has no pending_steps key")
    raise FlipRefused("no module-level CHIP_EVIDENCE to work from")


def _append_to_literal(source: str, name: str, body: str, what: str) -> str:
    """Append lines INSIDE a module-level literal, or refuse.

    Separate from `_replace_span` on purpose: appending to a literal and
    rewriting a value are different operations, and using one for both is how
    the first version of this deleted the eighteen names it was supposed to add
    four to. The parse check at the end of the flip is what catches that class
    of mistake, and `test_the_flip_moves_only_the_four_steps` is its guard.

    The indent comes from the literal's FIRST element, not from its closing
    bracket: a top-level tuple's `)` sits in column 0, so taking the indent
    from there would emit entries at column 0 inside it - syntactically fine
    and stylistically wrong, which is the kind of thing nobody notices until a
    reviewer does.
    """
    end, first = _literal_bounds(source, name)
    lines = source.splitlines(keepends=True)
    if not 0 < end <= len(lines) or not 0 < first <= len(lines):
        raise FlipRefused(f"{what}: the literal's bounds are out of range")
    sample = lines[first - 1]
    indent = " " * (len(sample) - len(sample.lstrip()))
    block = "".join(f"{indent}{line}\n"
                    for line in body.rstrip("\n").split("\n") if line.strip())
    return "".join(lines[:end - 1]) + block + "".join(lines[end - 1:])


def flip_held_steps(source: str, *, cite: str = "", date: str = "") -> str:
    """Return this module's source with the four held-core steps CONFIRMED.

    The trigger is the chip's green report and nothing else, so the report has
    to be cited: a flip that could be run on a hunch is a flip that will be.
    It also refuses if any already-published byte has changed, because a flip is
    a statement ABOUT bytes - riding in on a byte edit would confirm steps
    nobody re-ran - and it refuses if the steps are already confirmed, so a
    second run reports the no-op instead of restating the conformance line from
    a count it no longer has anything to add to.

    A pure text transform: no imports, no writes. The CLI applies it to the real
    file; the tests apply it to a copy. The NOTICE is not edited here, because
    it is generated from the flags - editing it by hand is the defect this
    whole mechanism exists to remove.

    `cite` and `date` default to empty so that OMITTING one produces this
    function's typed refusal, naming what is missing, rather than a TypeError
    from Python: for a tool whose only job is to refuse safely, a missing
    argument and an empty argument are the same event.
    """
    if not (cite or "").strip():
        raise FlipRefused(
            "a cite is required: the trigger is the chip's report, so the "
            "report has to be named (chip repo review path)")
    if not (date or "").strip():
        raise FlipRefused(
            "a date is required: a citation without a date rots silently")
    if _evidence_is_already_flipped(source):
        raise FlipRefused(
            "the held-core steps are already confirmed (or the evidence block "
            "was edited by hand) - nothing to flip")

    # The byte freeze, checked against a FRESH build before anything is
    # rewritten. This is the anti-laundering gate.
    pinned = _source_literal(source, "CONFIRMED_STEP_BYTES")
    names = _source_literal(source, "CONFIRMED_STEP_NAMES")
    fresh = {}
    for vector in build_package()["vectors"]:
        for step in vector["steps"]:
            fresh[step["name"]] = (step["request_hex"], step["response_hex"])
    for name in sorted(set(names) | set(pinned)):
        if name not in fresh:
            raise FlipRefused(f"{name}: not a step in the package any more")
        if tuple(pinned.get(name, ())) != fresh[name]:
            raise FlipRefused(
                f"{name}: the pinned byte pair does not match a fresh build, "
                f"so flipping now would confirm a byte edit nobody re-ran")

    count = len(names) + len(HELD_STEP_NAMES)
    out = source
    # 1. the four names join the confirmed tuple
    out = _append_to_literal(
        out, "CONFIRMED_STEP_NAMES",
        "\n# Confirmed by the chip's re-run; see chip_evidence.\n"
        + "\n".join(f'"{name}",' for name in HELD_STEP_NAMES),
        "confirmed-step names")
    # 2. the four byte pairs join the freeze, from the SHIPPED bytes
    out = _append_to_literal(
        out, "CONFIRMED_STEP_BYTES",
        "\n".join(
            f'"{name}": (\n    "{fresh[name][0]}",\n'
            f'    "{fresh[name][1]}",\n),'
            for name in HELD_STEP_NAMES),
        "confirmed-step bytes")
    # 3. the conformance line restates the arithmetic
    out = _replace_span(
        out, "\n    \"conformance\": ", "\n    \"pending_steps\":",
        f' "{count}/{count} golden steps PASS, byte-exact including CRC, in '
        f'the chip repo\'s tb/tb_pe_ctrl_r2.v with the R3 debug inputs driven: '
        f'the R2 read-path steps plus the four held-core steps (state 2 '
        f'step-pause, state 3 live hit). Reported in {cite}, {date}.",',
        "conformance")
    # 4. pending becomes history, with the report that cleared it
    out = _replace_span(
        out, "\n    \"pending_reason\": ", "\n    \"scope\":",
        f' "These four steps were added on 2026-09-25 because R3\'s debug work '
        f'made the R2 readback reachable in states 2 (DEBUG_HOLD) and 3 '
        f'(BP_HIT) while no R2 vector exercised either. The chip has since '
        f're-run tb_pe_ctrl_r2 against them with the debug inputs driven and '
        f'reported them byte-exact ({cite}, {date}), so the pending set is '
        f'empty and the notice is generated from the full count.",',
        "pending reason")
    # 5. pending_steps empties
    out = _replace_span(out, "\n    \"pending_steps\": ",
                        "\n    \"pending_reason\":", " (),", "pending steps")
    # 6. the date
    out = _replace_span(out, "\n    \"date\": ", ",\n}", f' "{date}"', "date")
    # 7. and the result must still be Python: a text transform that can emit
    #    a file nobody can import is not a transform. `ast.parse` rather than
    #    `compile`, because what is being checked is SYNTAX - the flipped file
    #    gets imported normally by the gates, and building a code object here
    #    would add an execution surface for no extra coverage.
    try:
        ast.parse(out)
    except SyntaxError as exc:
        raise FlipRefused(f"the flip produced invalid source: {exc}") from exc
    return out


def build_package() -> dict:
    """Derive the whole R2 verification package from the live model.

    Every vector is generated from a declared model image (memories plus the
    architectural register/timer state), and each step names the image it
    assumes, so a data-path check proves the *data*, not only the framing.
    """
    vectors = []
    b = V.Builder(SPEC)

    def image_and_model(image_id, **kwargs):
        return b.image_and_model(image_id, **kwargs)

    # 1. Bounded IMEM read, low word first ascending.
    image, pe = image_and_model("v01-read_imem_bounded")
    vectors.append(
        b.vector(
            "read_imem_bounded",
            R.by_name()["read_imem_bounded"].description,
            "low-word-first ascending",
            [
                b.record(
                    pe,
                    "read_imem_address_1_count_2",
                    P.OP_READ_IMEM,
                    (1, 2),
                    1,
                    "words 1,2 returned in ascending order",
                    image["id"],
                )
            ],
            image,
        )
    )

    # 2. Bounded DMEM read: bytes packed big-endian per word.
    image, pe = image_and_model(
        "v02-read_dmem_bounded", dmem={0: 0x0A, 1: 0x0B, 2: 0x0C, 3: 0x0D}
    )
    vectors.append(
        b.vector(
            "read_dmem_bounded",
            R.by_name()["read_dmem_bounded"].description,
            "bytes big-endian per word, ascending",
            [
                b.record(
                    pe,
                    "read_dmem_address_0_count_4",
                    P.OP_READ_DMEM,
                    (0, 4),
                    1,
                    "bytes 0..3 -> 0x0A0B, 0x0C0D",
                    image["id"],
                )
            ],
            image,
        )
    )

    # 3. DUMP_CORE header equals the STATUS header while stopped.
    image, pe = image_and_model(
        "v03-dump_core_header", pc=0x123, a=0x45, x=0x78, y=0x9A, timer=7
    )
    vectors.append(
        b.vector(
            "dump_core_header",
            R.by_name()["dump_core_header"].description,
            "n/a (register header)",
            [
                b.record(
                    pe,
                    "dump_core_header",
                    P.OP_DUMP_CORE,
                    (),
                    1,
                    "stable register header while stopped",
                    image["id"],
                ),
                b.record(
                    pe,
                    "status_header",
                    P.OP_STATUS,
                    (),
                    2,
                    "must equal the dump_core header",
                    image["id"],
                ),
            ],
            image,
        )
    )

    # 4. READ_CPU is non-halting and carries full-width registers.
    image, pe = image_and_model(
        "v04-read_cpu_non_halting",
        pc=ISA_PC_MAX,
        a=ISA_REG_MAX,
        x=ISA_REG_MAX,
        y=ISA_REG_MAX,
        insn=ISA_INSN_MAX,
        run=1,
    )
    vectors.append(
        b.vector(
            "read_cpu_non_halting",
            R.by_name()["read_cpu_non_halting"].description,
            "n/a (register header)",
            [
                b.record(
                    pe,
                    "read_cpu_while_running",
                    P.OP_READ_CPU,
                    (),
                    1,
                    "answers while run=1; pc/a/x/y/insn full width",
                    image["id"],
                )
            ],
            image,
        )
    )

    # 4b. Full-width debug registers (the anti-truncation vector). Widths are
    # the ISA's: pc 10 bits, a/x/y 8, insn 16 - the "full width" obligation is
    # that R2 exposes every bit the chip has, not that more exist.
    image, pe = image_and_model(
        "v05-full_width_debug_regs",
        pc=ISA_PC_MAX,
        a=ISA_REG_MAX,
        x=ISA_REG_MAX,
        y=ISA_REG_MAX,
        insn=ISA_INSN_MAX,
    )
    vectors.append(
        b.vector(
            "full_width_debug_regs",
            R.by_name()["full_width_debug_regs"].description,
            "n/a (register header)",
            [
                b.record(
                    pe,
                    "read_cpu_full_width_regs",
                    P.OP_READ_CPU,
                    (),
                    1,
                    f"pc=0x{ISA_PC_MAX:03X}, a=x=y=0x{ISA_REG_MAX:02X}, "
                    f"insn=0x{ISA_INSN_MAX:04X}",
                    image["id"],
                )
            ],
            image,
        )
    )

    # 5. Reads while running are rejected (chip-side, R2).
    image, pe = image_and_model("v06-read_while_running_rejected", run=1)
    vectors.append(
        b.vector(
            "read_while_running_rejected",
            R.by_name()["read_while_running_rejected"].description,
            "n/a (status only)",
            [
                b.record(
                    pe, "read_imem_not_ready", P.OP_READ_IMEM, (0, 1), 1, "", image["id"]
                ),
                b.record(
                    pe, "read_dmem_not_ready", P.OP_READ_DMEM, (0, 1), 2, "", image["id"]
                ),
                b.record(
                    pe, "dump_core_not_ready", P.OP_DUMP_CORE, (), 3, "", image["id"]
                ),
            ],
            image,
        )
    )

    # 6. Range never wraps: past-the-end reads are RANGE, not wrapped data.
    image, pe = image_and_model("v07-range_never_wraps")
    vectors.append(
        b.vector(
            "range_never_wraps",
            R.by_name()["range_never_wraps"].description,
            "n/a (rejected)",
            [
                b.record(
                    pe,
                    "read_imem_last_word",
                    P.OP_READ_IMEM,
                    (1023, 1),
                    1,
                    "the last word is readable",
                    image["id"],
                ),
                b.record(
                    pe,
                    "read_imem_past_end_no_wrap",
                    P.OP_READ_IMEM,
                    (1023, 2),
                    2,
                    "RANGE, never a wrapped read",
                    image["id"],
                ),
                b.record(
                    pe,
                    "read_dmem_past_end_no_wrap",
                    P.OP_READ_DMEM,
                    (15, 2),
                    3,
                    "RANGE, never a wrapped read",
                    image["id"],
                ),
            ],
            image,
        )
    )

    # 6b. Ceiling and zero-count rejection (chip MAX_READ_WORDS=15; the
    # independent chip review found the model used to accept a larger read).
    image, pe = image_and_model("v07b-read_ceiling_and_zero")
    vectors.append(
        b.vector(
            "read_ceiling_and_zero_count",
            "A count over MAX_READ_WORDS=15 (or 0) is RANGE so the host splits; "
            "the model enforces the chip's ceiling (independent chip review).",
            "n/a (rejected)",
            [
                b.record(
                    pe,
                    "read_imem_at_ceiling_15",
                    P.OP_READ_IMEM,
                    (0, 15),
                    1,
                    "15 words is the ceiling and succeeds",
                    image["id"],
                ),
                b.record(
                    pe,
                    "read_imem_over_ceiling",
                    P.OP_READ_IMEM,
                    (0, 16),
                    2,
                    "over the ceiling -> RANGE, host must split",
                    image["id"],
                ),
                b.record(
                    pe,
                    "read_dmem_zero_count",
                    P.OP_READ_DMEM,
                    (0, 0),
                    3,
                    "a zero-byte read is RANGE",
                    image["id"],
                ),
            ],
            image,
        )
    )

    # 7. The sticky-fault lifecycle: bad read -> RANGE + FAULT_RANGE, status
    #    shows the sticky bit, CLEAR_FAULT clears it (manager ruling).
    image, pe = image_and_model("v08-read_range_fault_lifecycle")
    lifecycle = [
        b.record(
            pe,
            "bad_read_answers_range",
            P.OP_READ_IMEM,
            (2000, 1),
            1,
            "out-of-range read: RANGE and latches sticky FAULT_RANGE",
            image["id"],
        ),
        b.record(
            pe,
            "status_shows_sticky_fault",
            P.OP_STATUS,
            (),
            2,
            "the sticky fault bit is visible before any clear",
            image["id"],
        ),
        b.record(
            pe,
            "clear_fault_clears_the_bit",
            P.OP_CLEAR_FAULT,
            (F.FAULT_RANGE,),
            3,
            "CLEAR_FAULT(0x4) returns faults=0",
            image["id"],
        ),
    ]
    vectors.append(
        b.vector(
            "read_range_fault_lifecycle",
            "An out-of-range READ latches sticky FAULT_RANGE and CLEAR_FAULT "
            "clears it (manager ruling).",
            "n/a (status/lifecycle)",
            lifecycle,
            image,
        )
    )

    # 8. The R2 readback while the core is HELD. R3's debug work gave the
    #    chip a second and third way to be stopped, and R2's STATUS carries
    #    the same 2-bit state word - so states 2 (DEBUG_HOLD, a step-pause)
    #    and 3 (BP_HIT, a live hit) are now reachable, and NOTHING in this
    #    package exercised either. A chip right on states 0/1 and wrong on
    #    the held ones passed 18/18. The expectations below are read off the
    #    frozen contract, not wished for:
    #      * state = dbg_hold ? (bp_hit ? 3 : 2) : (run ? 1 : 0) - only a
    #        hold can produce 2/3, and the latched hit is what separates
    #        them;
    #      * the STATUS `run` word is the STRAP, not the state. A breakpoint
    #        hit holds the core, it does not drop the strap, so a live hit
    #        arrives as state 3 WITH run=1;
    #      * DUMP_CORE is gated on the raw `run` strap, so it answers the
    #        full header under a step-pause (strap low) and NOT_READY under
    #        a live hit (strap still high) even though the core is stopped
    #        in both. Gating it on the hold instead would be a different,
    #        and wrong, reading - these steps are what separate the two.
    #
    #    Both pre-states are REACHABLE, not invented: they are the pc/a a
    #    real core has after executing the shipped image (imem 0x0041, 0x1001,
    #    0x4002) - one DEBUG_STEP from the boot stop for the pause, and a
    #    free-running stop on the armed breakpoint for the hit. A
    #    conformance TB preloading a state the core cannot occupy proves
    #    nothing (the chip review's M2 finding).
    #
    #    chip_confirmed=false: the chip's tb_pe_ctrl_r2 instantiates pe_ctrl
    #    without the R3 debug inputs, so it cannot drive these at all yet.
    image, pe = image_and_model(
        "v09-status_while_step_paused",
        pc=1,
        a=0x41,
        run=0,
        debug={"bp_addr": 2, "bp_en": True, "bp_hit": False, "debug_hold": True},
    )
    vectors.append(
        b.vector(
            "status_while_step_paused",
            "STATUS while the core is HELD in state 2 (DEBUG_HOLD, a "
            "step-pause): the state word says so and the run strap is still "
            "low, and DUMP_CORE still answers the identical header - a hold "
            "is not a running core, so nothing the R2 read path refuses is "
            "refused here.",
            "n/a (register header)",
            [
                b.record(
                    pe,
                    "status_reports_the_hold",
                    P.OP_STATUS,
                    (),
                    1,
                    "state=2 (DEBUG_HOLD), run=0, pc=1",
                    image["id"],
                ),
                b.record(
                    pe,
                    "dump_core_answers_the_same_header",
                    P.OP_DUMP_CORE,
                    (),
                    2,
                    "must equal the status header, state=2 included",
                    image["id"],
                ),
            ],
            image,
        )
    )

    image, pe = image_and_model(
        "v10-status_while_bp_hit",
        pc=2,
        a=0x41,
        run=1,
        debug={"bp_addr": 2, "bp_en": True, "bp_hit": True, "debug_hold": True},
    )
    vectors.append(
        b.vector(
            "status_while_bp_hit",
            "STATUS while the core is HELD in state 3 (BP_HIT, a live hit on "
            "an armed breakpoint): the state word says the hit latched, the PC "
            "rests on the breakpoint, and the run strap is STILL HIGH - the "
            "hit holds the core, it does not drop the strap. DUMP_CORE is then "
            "NOT_READY, because its gate is that strap and not the hold.",
            "n/a (status) + n/a (rejected)",
            [
                b.record(
                    pe,
                    "status_reports_the_hit",
                    P.OP_STATUS,
                    (),
                    1,
                    "state=3 (BP_HIT), run=1, pc=2 - the hit did not drop run",
                    image["id"],
                ),
                b.record(
                    pe,
                    "dump_core_refused_the_strap_is_high",
                    P.OP_DUMP_CORE,
                    (),
                    2,
                    "NOT_READY: the gate is run=1, not the debug state",
                    image["id"],
                ),
            ],
            image,
        )
    )

    return b.package(vectors)


# Bound to R2's spec and builder, so callers (and the conformance test) keep
# the zero-argument surface this module has always had.
load_model_from_image = V.load_model_from_image


def write_package(path=None) -> Path:
    return V.write_package(SPEC, build_package(), SPEC.artifact if path is None else path)


def check_package(path=None) -> int:
    return V.check_package(SPEC, build_package, SPEC.artifact if path is None else path)


def write_hex_export(directory=None) -> dict:
    return V.write_hex_export(
        SPEC, build_package(), SPEC.hex_dir if directory is None else directory
    )


def check_hex_export(directory=None) -> int:
    return V.check_hex_export(
        SPEC, build_package, SPEC.hex_dir if directory is None else directory
    )


def confirm_cli(argv: list[str]) -> int:
    """`--confirm-held-steps`: flip the four held steps, with the chip's report.

    Prints what it changed and what a human still owes, and then STOPS: it does
    not regenerate the artifacts, because this process is holding the pre-flip
    module in memory and would write the OLD flags back out. The regeneration
    is a separate command, printed verbatim, so the sequence is explicit
    rather than something the tool half-does.
    """
    import argparse
    import difflib

    parser = argparse.ArgumentParser(
        prog="python3 -m tools.host_gui.r2_vectors --confirm-held-steps",
        description="Confirm the four held-core R2 steps against the chip's "
                    "report. The trigger is the chip's GREEN report, not this "
                    "command.",
    )
    parser.add_argument("--cite", required=False, default="",
                        help="the chip report that cleared them (review path)")
    parser.add_argument("--date", required=False, default="",
                        help="the date of that report, YYYY-MM-DD")
    args = parser.parse_args(argv)

    module_path = Path(__file__).resolve()
    try:
        before = module_path.read_text(encoding="utf-8")
        after = flip_held_steps(before, cite=args.cite, date=args.date)
    except FlipRefused as exc:
        print(f"REFUSED: {exc}")
        return 1
    module_path.write_text(after, encoding="utf-8")
    diff = difflib.unified_diff(before.splitlines(), after.splitlines(),
                                fromfile=str(module_path), tofile=str(module_path),
                                lineterm="", n=1)
    print("".join(line + "\n" for line in diff))
    count = len(CONFIRMED_STEP_NAMES) + len(HELD_STEP_NAMES)
    print("Now regenerate and verify the artifacts (this process held the "
          "pre-flip module, so it must not write them itself):\n"
          "  python3 -m tools.host_gui.r2_vectors --write\n"
          "  python3 -m tools.host_gui.r2_vectors --hex\n"
          "  python3 -m tools.host_gui.r2_vectors --check")
    print(f"\nAnd the prose a human still owes (the notice itself is generated, "
          f"so it is already {count} of {count}):\n"
          "  docs/demo-walkthrough.md  the R2 row: '18 of 22' -> "
          f"'{count} of {count}', and the 4-unconfirmed sentence goes\n"
          "  reviews/2026-09-25/R2-READ-VERIFICATION.md  the Status section\n"
          "  reviews/2026-09-25/R2-HELD-STATUS-BYTES.md  the header claim\n"
          "  tools/host_bridge/acceptance.py  _r2_detail's tag\n"
          "  tools/host_gui/tests/test_docs.py  the walkthrough pin, if it "
          "asserts the old wording\n"
          "  wiki/STATUS.md + HANDOFF.md  the R2 notes\n"
          "  The gates will NAME each one that is stale: test_r2_vectors' "
          "notice guard,\n"
          "  test_docs' walkthrough pins, and the acceptance beat-count/PASS-"
          "count pins.")
    return 0


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--confirm-held-steps" in argv:
        rest = [arg for arg in argv if arg != "--confirm-held-steps"]
        return confirm_cli(rest)
    return V.run_cli(SPEC, build_package, argv)


if __name__ == "__main__":
    raise SystemExit(main())
