"""R3 debug-control verification package: golden vectors for the chip side.

`build_package()` derives every vector from the live `FakePE` model through the
shared framework (`vectors.py`), so the artifact cannot drift from the host
contract; the checked-in copy must match a fresh build, and `--check` is the
drift gate.

Reconciled against the IMPLEMENTED chip on 2026-09-25. The contract is frozen
in the chip repo's `reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md` and
transcribed into `rtl/pe_ctrl.v`'s header, and the RTL's four response
builders are what the frames here were generated from. The shape is the R2
package shape, so `tb_pe_ctrl_r3` can consume it the way `tb_pe_ctrl_r2`
consumed R2: per-step request/response bytes, a preloaded `imem.hex`/`dmem.hex`,
and the register + debug state each vector assumes in `model_images[]`.

**25 of 26 steps are chip-confirmed; one deliberately is not.** The chip's
`tb_pe_ctrl_r3_conf` is GREEN and its citations are recorded in
`CHIP_EVIDENCE` (chip repo: `R3-CONFORMANCE-AND-RUN-LOCK.md`,
`tb/tb_pe_ctrl_r3_conf.v`). Chip-confirmation is still a CITATION and never an
assertion: the confirmed set is an explicit list, so a step added later cannot
be confirmed without the chip having run it.

The one exception is `status_full_readback`, left unproven by BOTH sides. Its
expected `insn` is not contract-determined for a free-running core, and the
freeze-snapshot pre-state the conformance TB uses is a state the chip cannot
physically occupy. See `model_boundaries` below. **Nothing here is
hardware-confirmed** -- the real-board run has never been executed.

TWO PLACES THE VECTOR SPEC AND THE RTL DISAGREE
------------------------------------------------
Recorded in `r3_reads.DISCREPANCIES`. The vectors follow the RTL, because the
chip is the thing that has to pass them:

* **Vector 11** expects `pc=0` in the response, but the RTL answers with the PC
  AT THE REQUEST and re-zeroes the core at the same edge, so a following read
  sees 0. The RTL's own comment and the contract's "Known limits" section both
  state the RTL behaviour; only the table row disagrees.
* **Vector 13** expects `insn=imem[4]` while free-running, but pe_cpu fetches
  at `next_pc` while executing, so a free-running readback reports the word at
  the LANDING address. This vector keeps the pre-state the RTL describes and
  its `note` records which fetch mode produced the byte.

TWO OBLIGATIONS HAVE NO FRAMED STEP
-----------------------------------
"the instruction at the breakpoint did not run" and the live-core half of the
hit are model-only: a TB proves the first by checking the PC and the hit latch
across the step, and the second by CLOCKING the core, which is not a framed
op. They are listed in `model_only_obligations` so a testbench reader learns
what the package does not cover instead of assuming it does.
"""

from __future__ import annotations

from pathlib import Path

from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P
from tools.host_gui import r3_reads as R
from tools.host_gui import vectors as V

REPO_ROOT = V.REPO_ROOT
ARTIFACT = REPO_ROOT / "reviews" / "2026-09-25" / "R3-DEBUG-VERIFICATION.json"
README = REPO_ROOT / "reviews" / "2026-09-25" / "R3-DEBUG-VERIFICATION.md"
HEX_DIR = REPO_ROOT / "reviews" / "2026-09-25" / "r3-hex"

# The contract's stepping program, encoded per rtl/pe_cpu.v ([15:12] opcode,
# [11:0] operand):
#     0: LDI A,0x55    1: LDI A,0xAA    2: NOP    3: LDI A,0x0F    4: JMP 2
# Five DISTINCT words, so a mis-stepped vector cannot pass by coincidence, and
# the register effects (a=0x55 then a=0xAA) are observable through DEBUG_STATUS.
PROGRAM = R.PROGRAM

# Empty on purpose: nothing here is chip-confirmed yet. The map is the claim,
# and a test pins that a confirmed step must cite it.
CHIP_EVIDENCE = {
    # The chip's conformance run is GREEN and its citations are recorded, so
    # these 25 steps are chip-confirmed IN SIMULATION. The list is EXPLICIT
    # rather than derived as "everything except the boundary": confirmation is
    # a citation, never an assertion, and a derived rule would silently
    # confirm any step added later without the chip ever having run it.
    #
    # Note "step_one" names a step in TWO vectors (debug_step_sequence and
    # debug_step_lands_on_bp). Both are confirmed, so the result is right
    # today, but the framework keys evidence by step name; a test pins that
    # the two can never drift apart unnoticed.
    "confirmed_steps": {
        "bp_clr_releases",
        "bp_clr_to_boot_stop",
        "bp_set_address_2",
        "bp_set_bad_crc",
        "bp_set_len_0",
        "bp_set_on_loopback",
        "bp_set_past_imem",
        "read_cpu_shows_a_55",
        "status_after_live_hit",
        "status_is_stable",
        "status_reads_zero",
        "status_reports_the_hit",
        "status_running_again",
        "status_shows_a_aa",
        "status_shows_no_hit",
        "status_shows_not_armed",
        "status_shows_pc_1",
        "step_from_boot_stop",
        "step_lands_on_2",
        "step_not_ready",
        "step_off_the_breakpoint",
        "step_on_loopback",
        "step_one",
        "step_two",
    },
    "review": (
        "chip repo: reviews/2026-09-25/R3-CONFORMANCE-AND-RUN-LOCK.md "
        "(the conformance record and the run lock)"
    ),
    "testbench": "chip repo: tb/tb_pe_ctrl_r3_conf.v",
    "harness": (
        "tb_pe_ctrl_r3_conf loads imem.hex/dmem.hex, applies each "
        "vector's model_images[] state (registers plus bp_addr/bp_en/"
        "bp_hit/debug_hold), drives the step's request_file and "
        "compares the response word for word, CRC included. It also "
        "checks tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt: a divergence "
        "that CHANGES, or any divergence not listed, turns the gate "
        "red -- so a resolved host defect cannot read as 'known'"
    ),
    "conformance": (
        "tb_pe_ctrl_r3_conf GREEN: 26/26 steps byte-exact, and "
        "25 of them with NO divergence after this package's "
        "regeneration"
    ),
    "scope": (
        "Chip-confirmed IN SIMULATION against the implemented R3 "
        "contract. The remaining step (status_full_readback) is a "
        "pinned TB model boundary, deliberately NOT claimed by either "
        "side: insn is not contract-determined for a free-running core, "
        "and the freeze-snapshot pre-state is a state the chip cannot "
        "physically occupy. Chip-side R3.1 hold-semantics polish is in "
        "flight and may change it. NOT hardware-confirmed: the real-"
        "board run (Pico over USB, physical shuttle) has never been "
        "executed."
    ),
    "date": "2026-09-25",
}

MODEL_ONLY_OBLIGATIONS = (
    (
        "hit_is_stop_before",
        (
            "Stop-before is proven across a step (the PC reports the landing "
            "address with the hit latched, and the following step executes the "
            "instruction there), plus by the chip's own formal claim and mutants; "
            "there is no single frame that shows a non-execution."
        ),
    ),
    (
        "live_core_hit_keeps_the_strap (pre-state half)",
        (
            "Reaching a live-core hit requires CLOCKING the core until the landing "
            "address matches, which is not a framed op. Vector 8 therefore ships "
            "the POST-HIT held state as its model image and reads it back with one "
            "DEBUG_STATUS, which is exactly what a TB sets up."
        ),
    ),
)

# The numbers below are CHECKED against the flag arithmetic by
# test_the_notice_matches_the_flag_arithmetic, because a notice written by
# hand drifts the moment the arithmetic moves -- and the drift gate cannot
# catch that: the notice and the data are generated from the same source, so a
# fresh build faithfully reproduces the same stale prose. That is the whole
# reason the check is a TEST and not a regeneration.
PACKAGE_NOTICE = (
    "25 of 26 steps are CHIP-CONFIRMED IN SIMULATION: the chip's "
    "tb_pe_ctrl_r3_conf is GREEN, 26/26 steps byte-exact (CRC included), and "
    "25 of them with no divergence. The 26th, status_full_readback, is "
    "deliberately NOT claimed by either side -- its expected insn is not "
    "contract-determined for a free-running core, and the conformance TB's "
    "freeze-snapshot pre-state is a state the chip cannot physically occupy; "
    "chip-side R3.1 hold-semantics polish is in flight and may change it. "
    "Citations are in chip_evidence; confirmation is a citation, never an "
    "assertion, and the confirmed set is an explicit list. NOT "
    "HARDWARE-CONFIRMED: the real-board acceptance run (Pico over USB, "
    "physical shuttle) has never been executed."
)

# The response shapes, spelled out once so the manifest documents the wire
# contract a testbench compares against. Transcribed from pe_ctrl.v.
RESPONSE_LAYOUTS = {
    "0x21 DEBUG_STEP": "(OK, state, pc_next, bp_addr, bp_flags)   request len 0",
    "0x22 DEBUG_BP_SET": "(OK, state, pc, bp_addr, bp_flags)    request len 1 (address)",
    "0x23 DEBUG_BP_CLR": "(OK, state, pc, bp_addr_before, bp_flags)  request len 0",
    "0x24 DEBUG_STATUS": "(OK, state, pc, bp_addr, bp_flags, run, a, x, y, insn)"
    "   request len 0",
    "state": {
        str(F.DEBUG_STOPPED): "STOPPED (boot stop, PC held at 0)",
        str(F.DEBUG_RUNNING): "RUNNING (strap high, no hold)",
        str(F.DEBUG_HOLD): "DEBUG_HOLD (PC preserved)",
        str(F.DEBUG_BP_HIT): "BP_HIT (PC preserved, hit latched)",
    },
    "bp_flags": "bit0 = ARMED, bit1 = HIT latched. bp_addr is the armed "
    "address, or 0 when disarmed; address 0 is a legal breakpoint "
    "and is told apart from 'disarmed' by bit0, never by the "
    "address value.",
    "wait_words": "zero - all four ops are ready-immediate, answered in the "
    "request's own CRC cycle like READ_CPU",
    "refusals": "DEBUG_STEP while free-running is NOT_READY with the full "
    "5-word prefix and the PRE-step state; a wrong payload length "
    "is a 1-word BAD_FRAME; DEBUG_BP_SET past IMEM_WORDS is RANGE "
    "with NO side effect and NO fault.",
    "release": "DEBUG_BP_CLR is the only release: it disarms, clears the hit "
    "and drops the hold - with run=1 the core resumes, with run=0 "
    "the core falls to the boot stop and the PC re-zeroes. "
    "Continuing WITH the breakpoint armed costs step -> clear -> "
    "re-arm.",
}

SPEC = V.Spec(
    phase="R3",
    title="R3 debug-control verification package",
    generated_by="tools/host_gui/r3_vectors.py (build_package)",
    notice=PACKAGE_NOTICE,
    artifact=ARTIFACT,
    hex_dir=HEX_DIR,
    source_of_truth=(
        "tools/host_gui/r3_reads.py",
        "tools/host_gui/fake_pe.py",
        "tools/host_gui/protocol.py",
    ),
    rulings=(
        (
            "the contract is implemented chip-side; these vectors were reconciled "
            "against rtl/pe_ctrl.v's four response builders, not read off the "
            "prose (2026-09-25)"
        ),
        (
            "state is dbg_hold ? (bp_hit ? 3 : 2) : (run ? 1 : 0), and R2's "
            "STATUS state word carries the SAME encoding"
        ),
        (
            "bp_flags is {bp_hit, bp_en}: bit0 armed, bit1 hit; bp_addr is 0 when "
            "disarmed and address 0 is a legal breakpoint"
        ),
        (
            "a hit compares the LANDING address, so the instruction at the "
            "breakpoint has NOT executed (stop-before)"
        ),
        ("DEBUG_BP_CLR is the only release of the debug hold, and it disarms"),
        (
            "a rejected op has no side effect: wrong length is a 1-word "
            "BAD_FRAME, and a BP_SET past IMEM_WORDS is RANGE with no fault"
        ),
        (
            "25 of 26 steps are chip-confirmed in simulation; the 1 exception is "
            "the pinned TB model boundary, unproven by both sides -- see "
            "chip_evidence.conformance for the chip's own numbers"
        ),
    ),
    evidence=CHIP_EVIDENCE,
    word_order="big-endian words on the wire; the debug payloads are the "
    "fixed shapes above, in opcode order, with no wait words",
    readmemh_usage=(
        '$readmemh("<file>", mem); with an 8-bit mem[] filled from address 0; '
        "the stream is the frame's bytes in wire order."
    ),
    load_procedure=(
        "1) imem.hex: one 16-bit word per line, ascending address, for "
        "$readmemh into a 16-bit imem[0:1023]. 2) dmem.hex: one byte per "
        "line for $readmemh into an 8-bit dmem[0:15]. 3) preload the "
        "registers from model_images[].state (pc/a/x/y/insn/timer/run/"
        "faults/words_written) AND the debug context from "
        "model_images[].debug (bp_addr, bp_en, bp_hit, debug_hold). The state "
        "word is DERIVED by the chip from those, so it is not preloaded. 4) "
        "drive the step's request_file and compare the response word for word; "
        "these ops emit no wait words, so there is nothing to skip."
    ),
    hex_readme_title="# R3 debug vectors - $readmemh export",
    hex_artifact="R3 debug-control $readmemh export",
    hex_generated_by="tools/host_gui/r3_vectors.py (--hex)",
    hex_readme_command="python3 -m tools.host_gui.r3_vectors --hex",
    hex_readme_intro=(
        "from the same\nbuild as `../R3-DEBUG-VERIFICATION.json`; "
        "`--check` proves every file\n"
    ),
    labels=("r3 verification package", "r3 $readmemh export"),
    load_words=PROGRAM,
    schema=V.SCHEMA_VERSION,
    hex_readme_extra_preload=(
        "//    and model_images[].debug: bp_addr, bp_en, bp_hit,\n"
        "//    debug_hold (the state word is DERIVED from these)\n"
    ),
    protocol_extra={
        "debug_opcodes": {
            "0x21": "DEBUG_STEP",
            "0x22": "DEBUG_BP_SET",
            "0x23": "DEBUG_BP_CLR",
            "0x24": "DEBUG_STATUS",
        },
        "debug_contract": RESPONSE_LAYOUTS,
        "breakpoint": "ONE PC breakpoint (not a table), per the contract's stated scope",
    },
)


def build_package() -> dict:
    """Derive the R3 package from the live model, in the R2 package shape.

    Every vector declares the model image it assumes -- memories, registers
    and the debug registers -- so a chip testbench proves the DEBUG-CONTROL
    behaviour and not only the framing. The debug state word is never
    preloaded: it is derived by the chip, so a preloaded copy could contradict
    the registers it is derived from.
    """
    vectors = []
    b = V.Builder(SPEC)

    def image(image_id, *, pc=0, a=0, x=0, y=0, insn=0, run=0, **debug):
        state = {"bp_addr": 0, "bp_en": False, "bp_hit": False, "debug_hold": False}
        state.update(debug)
        built = b.image(image_id, pc=pc, a=a, x=x, y=y, insn=insn, run=run, debug=state)
        return built, b.model(built)

    def rec(pe, img, name, opcode, payload, sequence, note="", **kw):
        """One recorded step: the model drives it, the bytes are captured."""
        return b.record(
            pe, name, opcode, payload, sequence, note=note, model_image_id=img["id"], **kw
        )

    # 1. Arming reads straight back in the common prefix.
    img, pe = image("v01-bp-set-readback")
    vectors.append(
        b.vector(
            "debug_bp_set_readback",
            R.by_name()["bp_set_readback"].description,
            "n/a (5-word prefix)",
            [
                rec(
                    pe,
                    img,
                    "bp_set_address_2",
                    P.OP_DEBUG_BP_SET,
                    (2,),
                    1,
                    "armed at 2 and read back in the prefix: state 0, pc 0, flags 0x01",
                )
            ],
            img,
        )
    )

    # 2. Past the end of IMEM is RANGE, changes nothing, latches no fault.
    img, pe = image("v02-bp-set-out-of-range", bp_addr=3, bp_en=True)
    vectors.append(
        b.vector(
            "debug_bp_set_out_of_range",
            R.by_name()["bp_set_past_imem_is_range_without_a_fault"].description,
            "n/a (rejected)",
            [
                rec(
                    pe,
                    img,
                    "bp_set_past_imem",
                    P.OP_DEBUG_BP_SET,
                    (F.IMEM_WORDS,),
                    1,
                    "1024 is past a 1024-word IMEM: RANGE with bp_addr and flags "
                    "unchanged and NO fault latched (R3 adds no fault class)",
                )
            ],
            img,
        )
    )

    # 3. A wrong payload length is a 1-word BAD_FRAME with no side effect.
    img, pe = image("v03-bp-set-wrong-length")
    vectors.append(
        b.vector(
            "debug_bp_set_wrong_length",
            R.by_name()["wrong_payload_length_is_bad_frame"].description,
            "n/a (rejected)",
            [
                rec(
                    pe,
                    img,
                    "bp_set_len_0",
                    P.OP_DEBUG_BP_SET,
                    (),
                    1,
                    "BP_SET takes exactly one payload word; len 0 is a BAD_FRAME "
                    "carrying a SINGLE status word, and arms nothing",
                )
            ],
            img,
        )
    )

    # 4. One step executes exactly one instruction (LDI A,0x55 at 0).
    img, pe = image("v04-step-executes-one")
    vectors.append(
        b.vector(
            "debug_step_executes_one",
            R.by_name()["step_executes_exactly_one"].description,
            "n/a (5-word prefix)",
            [
                rec(
                    pe,
                    img,
                    "step_from_boot_stop",
                    P.OP_DEBUG_STEP,
                    (),
                    1,
                    "executes imem[0] (LDI A,0x55): state 2, pc_next 1",
                ),
                rec(
                    pe,
                    img,
                    "status_shows_pc_1",
                    P.OP_DEBUG_STATUS,
                    (),
                    2,
                    "the held PC is 1 and the run strap is still low",
                ),
                rec(
                    pe,
                    img,
                    "read_cpu_shows_a_55",
                    P.OP_READ_CPU,
                    (),
                    3,
                    "a=0x55: exactly one instruction retired",
                ),
            ],
            img,
        )
    )

    # 5. Two steps retire two instructions, in order.
    img, pe = image("v05-step-sequence")
    vectors.append(
        b.vector(
            "debug_step_sequence",
            R.by_name()["step_sequence_accumulates"].description,
            "n/a (5-word prefix)",
            [
                rec(pe, img, "step_one", P.OP_DEBUG_STEP, (), 1, "pc_next 1"),
                rec(pe, img, "step_two", P.OP_DEBUG_STEP, (), 2, "pc_next 2"),
                rec(
                    pe,
                    img,
                    "status_shows_a_aa",
                    P.OP_DEBUG_STATUS,
                    (),
                    3,
                    "a=0xAA: the LDI at 1 ran exactly once",
                ),
            ],
            img,
        )
    )

    # 6. A free-running core cannot be stepped.
    img, pe = image("v06-step-while-running", pc=7, run=1)
    vectors.append(
        b.vector(
            "debug_step_while_running",
            R.by_name()["step_while_running_is_not_ready"].description,
            "n/a (5-word prefix)",
            [
                rec(
                    pe,
                    img,
                    "step_not_ready",
                    P.OP_DEBUG_STEP,
                    (),
                    1,
                    "NOT_READY carrying the full 5-word prefix and the PRE-step "
                    "state; the PC does not move and no hold is asserted",
                )
            ],
            img,
        )
    )

    # 7. A step that lands on the armed address reports the hit.
    img, pe = image("v07-step-lands-on-bp", bp_addr=2, bp_en=True)
    vectors.append(
        b.vector(
            "debug_step_lands_on_bp",
            R.by_name()["step_onto_breakpoint_hits"].description,
            "n/a (5-word prefix)",
            [
                rec(
                    pe,
                    img,
                    "step_one",
                    P.OP_DEBUG_STEP,
                    (),
                    1,
                    "0 -> 1, no hit: state 2, flags 0x01",
                ),
                rec(
                    pe,
                    img,
                    "step_lands_on_2",
                    P.OP_DEBUG_STEP,
                    (),
                    2,
                    "landing on the armed address: state 3, pc_next 2, flags 0x03; "
                    "the NOP at 2 has NOT executed (stop-before)",
                ),
                rec(
                    pe,
                    img,
                    "status_reports_the_hit",
                    P.OP_DEBUG_STATUS,
                    (),
                    3,
                    "the hit is latched and the core is not executing",
                ),
            ],
            img,
        )
    )

    # 8. A live core stopped on the breakpoint. The image IS the post-hit held
    #    state, because reaching it takes clocking, not a frame.
    img, pe = image(
        "v08-bp-hit-stops-live-core",
        pc=2,
        run=1,
        bp_addr=2,
        bp_en=True,
        bp_hit=True,
        debug_hold=True,
    )
    vectors.append(
        b.vector(
            "debug_bp_hit_stops_live_core",
            R.by_name()["live_core_hit_keeps_the_strap"].description,
            "n/a (10-word status)",
            [
                rec(
                    pe,
                    img,
                    "status_after_live_hit",
                    P.OP_DEBUG_STATUS,
                    (),
                    1,
                    "state 3, pc 2, flags 0x03, and run STILL 1: the hit holds the "
                    "core without touching the strap",
                ),
                rec(
                    pe,
                    img,
                    "status_is_stable",
                    P.OP_DEBUG_STATUS,
                    (),
                    2,
                    "the held PC is preserved across reads (S2)",
                ),
            ],
            img,
        )
    )

    # 9. Stepping off the breakpoint clears the hit.
    img, pe = image(
        "v09-step-off-bp-clears-hit",
        pc=2,
        run=1,
        bp_addr=2,
        bp_en=True,
        bp_hit=True,
        debug_hold=True,
    )
    vectors.append(
        b.vector(
            "debug_step_off_bp_clears_hit",
            R.by_name()["step_off_breakpoint_clears_hit"].description,
            "n/a (5-word prefix)",
            [
                rec(
                    pe,
                    img,
                    "step_off_the_breakpoint",
                    P.OP_DEBUG_STEP,
                    (),
                    1,
                    "executes the NOP at 2 and lands at 3: state 2, flags 0x01, so "
                    "the hit is cleared (S4)",
                ),
                rec(
                    pe,
                    img,
                    "status_shows_no_hit",
                    P.OP_DEBUG_STATUS,
                    (),
                    2,
                    "armed but not hit",
                ),
            ],
            img,
        )
    )

    # 10. BP_CLR is the only release; with run=1 the core resumes.
    img, pe = image(
        "v10-bp-clr-resumes",
        pc=2,
        run=1,
        bp_addr=2,
        bp_en=True,
        bp_hit=True,
        debug_hold=True,
    )
    vectors.append(
        b.vector(
            "debug_bp_clr_resumes",
            R.by_name()["bp_clr_releases_the_hold"].description,
            "n/a (5-word prefix)",
            [
                rec(
                    pe,
                    img,
                    "bp_clr_releases",
                    P.OP_DEBUG_BP_CLR,
                    (),
                    1,
                    "state 1 (released to the high strap), pc 2 as at the request, "
                    "bp_addr_before 2, flags 0x00",
                ),
                rec(
                    pe,
                    img,
                    "status_running_again",
                    P.OP_DEBUG_STATUS,
                    (),
                    2,
                    "the core is running and disarmed",
                ),
            ],
            img,
        )
    )

    # 11. With run=0 the same clear falls to the boot stop and the PC
    #     re-zeroes. NOTE: the response pc is the PC AT THE REQUEST (the RTL's
    #     behaviour, which the contract's "Known limits" section also states);
    #     the re-zero shows up in the NEXT read. The §3 table row says 0 here --
    #     see r3_reads.DISCREPANCIES.
    img, pe = image("v11-bp-clr-boot-stop", pc=3, bp_en=True, debug_hold=True)
    vectors.append(
        b.vector(
            "debug_bp_clr_while_stopped_is_boot_stop",
            "With run=0, DEBUG_BP_CLR drops the hold to the normal boot stop and "
            "the PC re-zeroes; the response reports the PC at the request.",
            "n/a (5-word prefix)",
            [
                rec(
                    pe,
                    img,
                    "bp_clr_to_boot_stop",
                    P.OP_DEBUG_BP_CLR,
                    (),
                    1,
                    "state 0, pc 3 AS AT THE REQUEST (the re-zero lands at the same "
                    "edge, so the next read shows 0). The §3 table expects 0 here; "
                    "the RTL answers 3 -- see r3_reads.DISCREPANCIES",
                ),
                rec(
                    pe,
                    img,
                    "status_reads_zero",
                    P.OP_DEBUG_STATUS,
                    (),
                    2,
                    "the boot stop now holds the PC at 0",
                ),
            ],
            img,
        )
    )

    # 12. A bad CRC arms nothing. The recorded request IS the corrupt stream.
    img, pe = image("v12-bad-crc-no-side-effect")
    vectors.append(
        b.vector(
            "debug_bad_crc_no_side_effect",
            R.by_name()["bad_frame_leaves_no_trace"].description,
            "n/a (rejected)",
            [
                rec(
                    pe,
                    img,
                    "bp_set_bad_crc",
                    P.OP_DEBUG_BP_SET,
                    (2,),
                    1,
                    "the request_file itself carries a corrupt CRC: BAD_FRAME, and "
                    "nothing is armed",
                    corrupt_crc=True,
                ),
                rec(
                    pe,
                    img,
                    "status_shows_not_armed",
                    P.OP_DEBUG_STATUS,
                    (),
                    2,
                    "flags 0x00: the rejected op left no trace (S5)",
                ),
            ],
            img,
        )
    )

    # 13. The full readback: the prefix plus run/a/x/y/insn. NOTE on insn: the
    #     contract's table says imem[4] while free-running, but pe_cpu fetches
    #     at next_pc while executing, so the RTL reports the word at the
    #     LANDING address. Recorded in r3_reads.DISCREPANCIES; the RTL wins.
    img, pe = image("v13-status-common-prefix", pc=4, run=1, bp_addr=2, bp_en=True)
    vectors.append(
        b.vector(
            "debug_status_common_prefix",
            R.by_name()["debug_status_is_the_full_readback"].description,
            "n/a (10-word status)",
            [
                rec(
                    pe,
                    img,
                    "status_full_readback",
                    P.OP_DEBUG_STATUS,
                    (),
                    1,
                    "the 5-word prefix plus run/a/x/y/insn; insn follows the RTL's "
                    "fetch mode (next_pc while executing), so it is the LANDING "
                    "word, not imem[pc] -- see r3_reads.DISCREPANCIES",
                )
            ],
            img,
        )
    )

    # 14. The debug ops are TARGET_HOST only.
    img, pe = image("v14-unsupported-target")
    vectors.append(
        b.vector(
            "debug_unsupported_target",
            R.by_name()["debug_ops_are_host_target_only"].description,
            "n/a (rejected)",
            [
                rec(
                    pe,
                    img,
                    "step_on_loopback",
                    P.OP_DEBUG_STEP,
                    (),
                    1,
                    "the loopback target does not implement the debug ops",
                    target=P.TARGET_LOOPBACK,
                ),
                rec(
                    pe,
                    img,
                    "bp_set_on_loopback",
                    P.OP_DEBUG_BP_SET,
                    (2,),
                    2,
                    "same for BP_SET",
                    target=P.TARGET_LOOPBACK,
                ),
            ],
            img,
        )
    )

    package = b.package(vectors)
    # A TB MODEL BOUNDARY, recorded so nobody reads the expected insn as
    # proven. For a free-running core `insn` is whatever the fetch pipeline
    # happens to hold, which a STATIC pre-state cannot pin: the manager-ruled
    # landing word is 0xF000, while tb_pe_ctrl_r3_conf's freeze-snapshot model
    # reports 0x0000, because a model that pins pc every cycle collapses the
    # fetch onto the fill word. The chip's conformance doc is explicit that this
    # is "not a disagreement about the contract; not proven here, and not
    # claimed" -- so the expectation stays the ruled landing word and the step
    # stays chip_confirmed=false, rather than bending a contract value to match a
    # testbench artefact.
    package["model_boundaries"] = [
        {
            "vector": "debug_status_common_prefix",
            "step": "status_full_readback",
            "field": "insn",
            "expected": "the manager-ruled LANDING word (0xF000)",
            "chip_reports": "0x0000",
            "why": "a freeze-snapshot TB pins pc every cycle, collapsing the fetch "
            "pipeline onto the fill word; insn is not contract-determined for "
            "a free-running core",
            "chip_confirmed": False,
            "note": "not a contract disagreement and not claimed on either side; "
            "a TB that holds the core (state 2) would make insn "
            "deterministic at imem[pc] and could prove the word",
        }
    ]
    package["model_only_obligations"] = [
        {"name": name, "why": why} for name, why in MODEL_ONLY_OBLIGATIONS
    ]
    package["spec_vs_rtl_discrepancies"] = [
        {"where": where, "resolution": why} for where, why in R.DISCREPANCIES
    ]
    package["reconciliation_required"] = (
        "These vectors were generated from the implemented RTL on 2026-09-25. "
        "Before any step is marked chip_confirmed, the chip's tb_pe_ctrl_r3 "
        "must pass it byte-exactly (CRC included) with the model image "
        "preloaded. Where the chip and this package ever disagree, the CHIP "
        "wins: fix the host model and regenerate, never the reverse."
    )
    return package


def write_package(path: Path | None = None) -> Path:
    return V.write_package(SPEC, build_package(), SPEC.artifact if path is None else path)


def check_package(path: Path | None = None) -> int:
    return V.check_package(SPEC, build_package, SPEC.artifact if path is None else path)


def write_hex_export(directory: Path | None = None) -> dict:
    return V.write_hex_export(
        SPEC, build_package(), SPEC.hex_dir if directory is None else directory
    )


def check_hex_export(directory: Path | None = None) -> int:
    return V.check_hex_export(
        SPEC, build_package, SPEC.hex_dir if directory is None else directory
    )


def main(argv=None) -> int:
    return V.run_cli(SPEC, build_package, argv)


if __name__ == "__main__":
    raise SystemExit(main())
