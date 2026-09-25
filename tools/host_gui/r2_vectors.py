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

CHIP_EVIDENCE = {
    "confirmed_steps": {
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
        "bad_read_answers_range",
        "status_shows_sticky_fault",
        "clear_fault_clears_the_bit",
        # Host-side ceiling + zero-count vectors, added after the chip review;
        # the chip re-ran them and they pass byte-exact (conformance now
        # 18/18; the ceiling and count==0->RANGE rules needed no RTL change).
        "read_imem_at_ceiling_15",
        "read_imem_over_ceiling",
        "read_dmem_zero_count",
    },
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
    "pending_steps": (
        "status_reports_the_hold",
        "dump_core_answers_the_same_header",
        "status_reports_the_hit",
        "dump_core_refused_the_strap_is_high",
    ),
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


PACKAGE_NOTICE = (
    "PARTIALLY CHIP-CONFIRMED IN SIMULATION: 18 of the 22 golden steps in "
    "this package - every R2 read-path step - pass byte-exactly (CRC "
    "included) in the chip repo's tb/tb_pe_ctrl_r2.v, with the model image "
    "loaded per vector; see the chip repo's "
    "reviews/2026-09-25/R2-READ-PATH-REVIEW.md, section 'Conformance', which "
    "names every one of them (18/18). NOT CHIP-CONFIRMED: the 4 steps added "
    "2026-09-25 for the R2 readback while the core is HELD at a breakpoint - "
    "status_reports_the_hold, dump_core_answers_the_same_header (state 2, a "
    "step-pause) and status_reports_the_hit, dump_core_refused_the_strap_is_"
    "high (state 3, a live hit). Their expectations come from the frozen "
    "contract semantics, the chip has not re-run tb_pe_ctrl_r2 against them, "
    "and they are a gate, not evidence. NOT HARDWARE-CONFIRMED: the "
    "real-board acceptance run (Pico over USB CDC with a physical shuttle) has "
    "NOT been executed and is not claimed here. The host probes in "
    "r2_reads.py still run against the FakePE model; what the chip confirms is "
    "that the RTL matches these same expectations."
)

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


def main(argv=None) -> int:
    return V.run_cli(SPEC, build_package, argv)


if __name__ == "__main__":
    raise SystemExit(main())
