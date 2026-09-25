"""R3 debug-control obligations, reconciled against the IMPLEMENTED chip.

R3 is landed (chip repo, 2026-09-25). The wire contract is frozen in
`reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md` and transcribed into
`rtl/pe_ctrl.v`'s header, and the RTL is what this module was reconciled
against on 2026-09-25. Every obligation here is a host-side probe of the
`FakePE` model; the chip's own testbench (`tb_pe_ctrl_r3`) proves the RTL.

**chip_confirmed stays False on every obligation.** A host probe is evidence
about a model, never about silicon. The chip side has run its own TB and
mutation gate (7 mutants, all caught) and formal proofs for S1-S4 -- that is
the chip's evidence, recorded in the chip repo. Until the chip's TB passes
*these* golden vectors byte-exactly and the citations are added to
`r3_vectors.CHIP_EVIDENCE`, the host's flags do not move.

WHAT THE CONTRACT ACTUALLY SAYS (the shapes a host must implement)
------------------------------------------------------------------
    0x21 DEBUG_STEP   -> (OK, state, pc_next, bp_addr, bp_flags)   len 0
    0x22 DEBUG_BP_SET -> (OK, state, pc, bp_addr, bp_flags)        len 1 (address)
    0x23 DEBUG_BP_CLR -> (OK, state, pc, bp_addr_before, bp_flags) len 0
    0x24 DEBUG_STATUS -> (OK, state, pc, bp_addr, bp_flags, run, a, x, y, insn)
                                                                          len 0

    state: 0 STOPPED (boot stop, PC held at 0) | 1 RUNNING (strap high, no
    hold) | 2 DEBUG_HOLD (held by the debug controls, PC PRESERVED) |
    3 BP_HIT (held by the breakpoint, hit latched). R2's STATUS `state` word
    carries the SAME encoding, so 0/1 keep their R1/R2 meaning.
    bp_flags: bit0 armed, bit1 hit. bp_addr is the armed address or 0 when
    disarmed -- a breakpoint at address 0 is legal and is told apart by bit0.
    All four ops are READY-IMMEDIATE: ZERO wait words.

KEY SEMANTICS, stated once so the probes below are not re-deriving them
---------------------------------------------------------------------
* **Stop-before.** A hit compares the core's LANDING address (`dbg_next_pc`)
  against the armed breakpoint, so the instruction AT the breakpoint address
  has NOT executed. That is what lets a debugger inspect the landing
  instruction and then step that very instruction.
* **BP_CLR is the only release.** It disarms, clears the hit and drops the
  hold: with run=1 the core resumes, with run=0 it falls to the boot stop and
  the PC re-zeroes. Continuing *with* the breakpoint armed therefore costs
  step -> clear -> re-arm.
* **Rejected ops have no side effect.** A bad frame, a wrong payload length,
  or a BP_SET past the end of IMEM changes no debug register and executes no
  instruction.
* **No new fault class, and no wait words.** A sequencing refusal is
  NOT_READY with no fault; a malformed frame is BAD_FRAME (which does latch
  the pre-existing FAULT_PROTOCOL/FAULT_CRC, as any bad frame always has).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P

NOT_CHIP_CONFIRMED = (
    "These probes run against the host FakePE model. The R3 contract is "
    "implemented chip-side, but these probes are host-side evidence about a "
    "MODEL, not about silicon: chip_confirmed stays False until the chip's own "
    "tb_pe_ctrl_r3 passes the golden vectors in r3_vectors byte-exactly (CRC "
    "included) and the citation is recorded."
)

# The contract's stepping program, encoded per rtl/pe_cpu.v ([15:12] opcode,
# [11:0] operand):  0: LDI A,0x55   1: LDI A,0xAA   2: NOP
#                    3: LDI A,0x0F   4: JMP 2
# The words are DISTINCT so a mis-stepped vector cannot pass by coincidence.
PROGRAM = (0x0055, 0x00AA, 0xF000, 0x000F, 0x4002)

# DISCREPANCIES between the contract's §3 vector table and the implemented RTL,
# and the RULING that settled them.
#
# MANAGER RULING 2026-09-25: the vectors STAND. The response pc is the PC at
# the request, and insn is the landing word. The contract's §3 table is being
# corrected chip-side to match the RTL, and
# reviews/2026-09-25/R3-VECTOR-BYTES.md is the conformance reference for
# tb_pe_ctrl_r3. So these rows are no longer a host judgement call pending a
# ruling -- they are ruled, and the wording below says so, because a conformance
# reference's provenance is part of what it asserts.
DISCREPANCIES = (
    (
        "vector 11 (debug_bp_clr_while_stopped_is_boot_stop)",
        (
            "the table's expected response says pc=0, but the RTL answers with the PC "
            "AT THE REQUEST and only re-zeroes the core at the same edge, so a "
            "following DEBUG_STATUS/STATUS reads 0. The RTL's own comment and the "
            "contract's 'Known limits' section both state the RTL behaviour; only the "
            "table row disagrees. RULED 2026-09-25: the vectors stand, and "
            "the table is being corrected chip-side to match the RTL."
        ),
    ),
    (
        "vector 13 (debug_status_common_prefix)",
        (
            "the table expects insn=imem[4] while free-running, but pe_cpu fetches at "
            "next_pc while executing (next_pc / pc while held / 0 at the boot stop), "
            "so a free-running readback reports the word at the LANDING address, not "
            "at pc. A TB that wants insn=imem[pc] must hold the core (state 2) or "
            "preload the pipeline. RULED 2026-09-25: the vectors stand "
            "(insn is the landing word), and the table is being corrected "
            "chip-side."
        ),
    ),
)


@dataclass(frozen=True)
class Obligation:
    """One R3 debug-control obligation and a probe that checks it on a model."""

    name: str
    description: str
    probe: Callable[[F.FakePE], bool]
    chip_confirmed: bool = False


def loaded(
    pe: F.FakePE | None = None, *, pc: int = 0, run: bool = False, words=PROGRAM, **debug
) -> F.FakePE:
    """A model with the contract program loaded and the debug state preloaded.

    `debug` accepts bp_addr/bp_en/bp_hit/debug_hold, which is exactly what a
    chip testbench preloads from `model_images[].debug`.
    """
    model = pe if pe is not None else F.FakePE()
    model.request(P.OP_LOAD, payload_words=words)
    model.pc = pc & F.ISA_PC_MASK
    if "bp_addr" in debug:
        model.bp_addr = debug["bp_addr"] & F.ISA_PC_MASK
    if "bp_en" in debug:
        model.bp_en = bool(debug["bp_en"])
    if "bp_hit" in debug:
        model.bp_hit = bool(debug["bp_hit"])
    if "debug_hold" in debug:
        model.debug_hold = bool(debug["debug_hold"])
    model.run = bool(run)
    if not run and not model.debug_hold:
        model.pc = 0  # the boot stop holds the PC at 0
    return model


# ---- S1: one instruction per step -----------------------------------------
def _step_executes_exactly_one(pe: F.FakePE) -> bool:
    pe = loaded(pe, pc=0)
    payload = pe.request(P.OP_DEBUG_STEP).payload
    # (OK, state=2 DEBUG_HOLD, pc_next, bp_addr, bp_flags)
    return (
        payload[0] == P.STATUS_OK
        and payload[1] == F.DEBUG_HOLD
        and payload[2] == 1
        and pe.a == 0x55
        and pe.pc == 1
    )


def _step_sequence_accumulates(pe: F.FakePE) -> bool:
    pe = loaded(pe, pc=0)
    first = pe.request(P.OP_DEBUG_STEP).payload
    second = pe.request(P.OP_DEBUG_STEP).payload
    status = pe.request(P.OP_DEBUG_STATUS).payload
    return (
        first[2] == 1
        and second[2] == 2
        and status[6] == 0xAA  # a: the LDI at 1 ran exactly once
        and status[2] == 2
    )


def _held_pc_is_stable(pe: F.FakePE) -> bool:
    """S2: while held and not stepping, the PC and the registers are frozen."""
    pe = loaded(pe, pc=0)
    pe.request(P.OP_DEBUG_STEP)
    snapshot = (pe.pc, pe.a, pe.insn)
    for _ in range(5):
        pe.request(P.OP_DEBUG_STATUS)
    return (pe.pc, pe.a, pe.insn) == snapshot and pe.a == 0x55


# ---- S3: a hit stops the core, stop-before, distinguishably -----------------
def _step_onto_breakpoint_hits(pe: F.FakePE) -> bool:
    pe = loaded(pe, pc=0, bp_addr=2, bp_en=True)
    pe.request(P.OP_DEBUG_STEP)  # 0 -> 1, no hit
    payload = pe.request(P.OP_DEBUG_STEP).payload
    status = pe.request(P.OP_DEBUG_STATUS).payload
    # Landing on the armed address: state 3, pc_next 2, flags 0b11.
    return (
        payload[1] == F.DEBUG_BP_HIT
        and payload[2] == 2
        and payload[4] == (F.BP_FLAG_ARMED | F.BP_FLAG_HIT)
        and status[1] == F.DEBUG_BP_HIT
        and status[2] == 2
        and status[4] == 0b11
        and status[5] == 0
    )


def _hit_is_stop_before(pe: F.FakePE) -> bool:
    """The instruction AT the breakpoint has not run (no side effect)."""
    # A stopped core holds the PC at 0 (the boot stop), so a PC of 1 is only
    # reachable by STEPPING, which is also what raises the hold. Reaching the
    # state the way the hardware does keeps the probe meaningful.
    pe = loaded(pe, pc=0)
    pe.request(P.OP_DEBUG_STEP)  # 0 -> 1, now held
    pe.bp_addr, pe.bp_en = 2, True
    payload = pe.request(P.OP_DEBUG_STEP).payload
    # The hit must be observed AT the landing: the next step off the
    # breakpoint clears it, so sampling after that step would prove nothing.
    latched = pe.bp_hit
    # imem[2] is NOP, so the instruction at the breakpoint having NOT run is
    # shown by the PC stopping ON 2 with the hit latched, and by the following
    # step executing 2 and landing at 3.
    pe.request(P.OP_DEBUG_STEP)
    after = pe.request(P.OP_DEBUG_STATUS).payload
    return (
        payload[2] == 2
        and latched
        and payload[4] == (F.BP_FLAG_ARMED | F.BP_FLAG_HIT)
        and after[2] == 3
        and not pe.bp_hit
    )


def _live_core_hit_keeps_the_strap(pe: F.FakePE) -> bool:
    """A free-running core stops on the breakpoint with run still high."""
    pe = loaded(pe, pc=0, run=True, bp_addr=2, bp_en=True)
    stopped = pe.advance_free_running()
    payload = pe.request(P.OP_DEBUG_STATUS).payload
    return (
        stopped
        and payload[1] == F.DEBUG_BP_HIT
        and payload[2] == 2
        and payload[4] == 0b11
        and payload[5] == 1
    )


# ---- S4: a step off the breakpoint clears the hit -------------------------
def _step_off_breakpoint_clears_hit(pe: F.FakePE) -> bool:
    pe = loaded(pe, pc=0, run=True, bp_addr=2, bp_en=True)
    pe.advance_free_running()  # the live core stops on the breakpoint
    if not pe.bp_hit:
        return False
    payload = pe.request(P.OP_DEBUG_STEP).payload
    status = pe.request(P.OP_DEBUG_STATUS).payload
    return (
        payload[1] == F.DEBUG_HOLD
        and payload[2] == 3
        and payload[4] == F.BP_FLAG_ARMED
        and status[4] == 0b01
    )


def _step_lands_again_keeps_the_hit(pe: F.FakePE) -> bool:
    """A step that lands on the armed address again relatches the hit."""
    pe = loaded(pe, pc=0, bp_addr=2, bp_en=True)
    pe.request(P.OP_DEBUG_STEP)  # 0 -> 1
    payload = pe.request(P.OP_DEBUG_STEP).payload  # 1 -> 2, lands on 2
    return payload[1] == F.DEBUG_BP_HIT and payload[4] == 0b11 and pe.bp_hit


# ---- breakpoint arm / disarm ----------------------------------------------
def _bp_set_readback(pe: F.FakePE) -> bool:
    pe = loaded(pe, pc=0)
    payload = pe.request(P.OP_DEBUG_BP_SET, payload_words=(2,)).payload
    return (
        payload[0] == P.STATUS_OK
        and payload[1] == F.DEBUG_STOPPED
        and payload[2] == 0
        and payload[3] == 2
        and payload[4] == F.BP_FLAG_ARMED
    )


def _bp_set_while_running_is_allowed(pe: F.FakePE) -> bool:
    """Arming is allowed while the core runs; the hit then stops it live."""
    pe = loaded(pe, pc=0, run=True)
    armed = pe.request(P.OP_DEBUG_BP_SET, payload_words=(2,)).payload
    stopped = pe.advance_free_running()
    return (
        armed[0] == P.STATUS_OK and armed[1] == F.DEBUG_RUNNING and stopped and pe.bp_hit
    )


def _bp_set_clears_a_stale_hit(pe: F.FakePE) -> bool:
    pe = loaded(pe, pc=0, bp_addr=2, bp_en=True)
    pe.request(P.OP_DEBUG_STEP)
    pe.request(P.OP_DEBUG_STEP)  # land on 2 -> hit
    if not pe.bp_hit:
        return False
    pe.request(P.OP_DEBUG_BP_SET, payload_words=(5,))
    return not pe.bp_hit and pe.bp_addr == 5 and pe.bp_en


def _bp_clr_releases_the_hold(pe: F.FakePE) -> bool:
    """With run=1 the clear resumes the core; with run=0 it is the boot stop."""
    pe = loaded(pe, pc=0, run=True, bp_addr=2, bp_en=True)
    pe.advance_free_running()  # the live core stops on the breakpoint
    payload = pe.request(P.OP_DEBUG_BP_CLR).payload
    resumed = (
        payload[0] == P.STATUS_OK
        and payload[1] == F.DEBUG_RUNNING
        and payload[2] == 2
        and payload[3] == 2
        and payload[4] == 0
        and pe.run
        and not pe.debug_hold
    )
    pe.set_run(False)
    pe.request(P.OP_DEBUG_BP_CLR)
    return resumed and not pe.run and pe.pc == 0


# ---- refusals and rejections (S5, S6) -------------------------------------
def _step_while_running_is_not_ready(pe: F.FakePE) -> bool:
    """A free-running core cannot be stepped: NOT_READY, no side effect.

    The refusal still answers the full 5-word prefix with the PRE-step state.
    """
    pe = loaded(pe, pc=4, run=True, bp_addr=2, bp_en=True)
    payload = pe.request(P.OP_DEBUG_STEP).payload
    return (
        payload[0] == P.STATUS_NOT_READY
        and payload[1] == F.DEBUG_RUNNING
        and payload[2] == 4
        and payload[3] == 2
        and payload[4] == F.BP_FLAG_ARMED
        and not pe.debug_hold
        and pe.pc == 4
        and not pe.bp_hit
    )


def _bp_set_past_imem_is_range_without_a_fault(pe: F.FakePE) -> bool:
    """Past IMEM_WORDS is RANGE, changes nothing, and latches NO fault."""
    pe = loaded(pe, pc=0, bp_addr=3, bp_en=True)
    payload = pe.request(P.OP_DEBUG_BP_SET, payload_words=(F.IMEM_WORDS + 1,))
    payload = payload.payload
    return (
        payload[0] == P.STATUS_RANGE
        and payload[3] == 3
        and payload[4] == F.BP_FLAG_ARMED
        and pe.bp_addr == 3
        and pe.bp_en
        and pe.faults == 0
    )


def _wrong_payload_length_is_bad_frame(pe: F.FakePE) -> bool:
    """A wrong payload length is BAD_FRAME with no side effect (S5)."""
    pe = loaded(pe, pc=0)
    set_no_len = pe.request(P.OP_DEBUG_BP_SET).payload
    step_with_len = pe.request(P.OP_DEBUG_STEP, payload_words=(1,)).payload
    return (
        set_no_len[0] == P.STATUS_BAD_FRAME
        and len(set_no_len) == 1
        and not pe.bp_en
        and step_with_len[0] == P.STATUS_BAD_FRAME
        and len(step_with_len) == 1
        and not pe.debug_hold
        and pe.pc == 0
    )


def _bad_frame_leaves_no_trace(pe: F.FakePE) -> bool:
    """A bad CRC arms nothing (S5), exactly like a bad length."""
    raw = bytearray(P.encode_frame(P.OP_DEBUG_BP_SET, 1, P.TARGET_HOST, b"\x00\x02"))
    raw[-1] ^= 0x01  # corrupt the CRC
    pe = loaded(pe, pc=0)
    response = pe.exchange(bytes(raw))
    if response is None:
        # Not an assert: asserts vanish under `python -O`, and this is the
        # difference between "the chip answered BAD_FRAME" and "the chip said
        # nothing", which is exactly the distinction under test.
        raise AssertionError("a bad frame must still get a BAD_FRAME answer")
    frame = P.decode_frame(response)
    return frame.payload[0] == P.STATUS_BAD_FRAME and not pe.bp_en and pe.pc == 0


def _debug_ops_are_host_target_only(pe: F.FakePE) -> bool:
    """The loopback target answers UNSUPPORTED for every debug op."""
    pe = loaded(pe)
    return all(
        pe.request(
            opcode,
            target=P.TARGET_LOOPBACK,
            payload_words=((2,) if opcode == P.OP_DEBUG_BP_SET else ()),
        ).payload[0]
        == P.STATUS_UNSUPPORTED
        for opcode in P.R3_OPCODES
    )


def _debug_status_is_the_full_readback(pe: F.FakePE) -> bool:
    """The 5-word prefix plus run/a/x/y/insn, non-halting."""
    pe = loaded(pe, pc=1, run=True, bp_addr=2, bp_en=True)
    payload = pe.request(P.OP_DEBUG_STATUS).payload
    return (
        len(payload) == 10
        and payload[0] == P.STATUS_OK
        and payload[1] == F.DEBUG_RUNNING
        and payload[2] == 1
        and payload[3] == 2
        and payload[4] == F.BP_FLAG_ARMED
        and payload[5] == 1
    )


def _breakpoint_at_address_zero_is_armed(pe: F.FakePE) -> bool:
    """Address 0 is a legal breakpoint, told apart from 'disarmed' by bit0."""
    pe = loaded(pe, pc=0)
    payload = pe.request(P.OP_DEBUG_BP_SET, payload_words=(0,)).payload
    status = pe.request(P.OP_DEBUG_STATUS).payload
    return (
        payload[0] == P.STATUS_OK
        and payload[3] == 0
        and payload[4] == F.BP_FLAG_ARMED
        and status[4] == 0b01
    )


def _boot_stop_holds_pc_at_zero(pe: F.FakePE) -> bool:
    """run=0 with no hold is the boot stop: the PC is held at 0."""
    pe = loaded(pe, pc=7, run=True)
    pe.set_run(False)
    payload = pe.request(P.OP_DEBUG_STATUS).payload
    return payload[1] == F.DEBUG_STOPPED and payload[2] == 0


OBLIGATIONS: tuple[Obligation, ...] = (
    Obligation(
        "step_executes_exactly_one",
        "DEBUG_STEP executes exactly one instruction and leaves the "
        "core in DEBUG_HOLD (S1).",
        _step_executes_exactly_one,
    ),
    Obligation(
        "step_sequence_accumulates",
        "Two steps retire two instructions: pc 0->1->2 and the LDI at "
        "1 has run exactly once (a=0xAA).",
        _step_sequence_accumulates,
    ),
    Obligation(
        "held_pc_is_stable",
        "While held and not stepping, the PC and the registers are "
        "frozen across arbitrarily many reads (S2).",
        _held_pc_is_stable,
    ),
    Obligation(
        "step_onto_breakpoint_hits",
        "A step whose landing address is the armed breakpoint reports "
        "state 3, the landing PC, and bp_flags 0b11 (S3).",
        _step_onto_breakpoint_hits,
    ),
    Obligation(
        "hit_is_stop_before",
        "The instruction AT the armed address has NOT executed when the "
        "core stops: the hit compares the LANDING address (S3).",
        _hit_is_stop_before,
    ),
    Obligation(
        "live_core_hit_keeps_the_strap",
        "A free-running core stops on the breakpoint with run still "
        "high, and reports state 3 (S3).",
        _live_core_hit_keeps_the_strap,
    ),
    Obligation(
        "step_off_breakpoint_clears_hit",
        "A step off the breakpoint clears the hit and returns to "
        "DEBUG_HOLD with bp_flags 0b01 (S4).",
        _step_off_breakpoint_clears_hit,
    ),
    Obligation(
        "step_lands_again_keeps_the_hit",
        "A step that lands on the armed address again relatches the hit (S4).",
        _step_lands_again_keeps_the_hit,
    ),
    Obligation(
        "bp_set_readback",
        "DEBUG_BP_SET arms the address and reads it straight back in the 5-word prefix.",
        _bp_set_readback,
    ),
    Obligation(
        "bp_set_while_running_is_allowed",
        "Arming is allowed while the core runs, and the hit then stops the live core.",
        _bp_set_while_running_is_allowed,
    ),
    Obligation(
        "bp_set_clears_a_stale_hit",
        "Arming clears a stale hit and reports the new address.",
        _bp_set_clears_a_stale_hit,
    ),
    Obligation(
        "bp_clr_releases_the_hold",
        "DEBUG_BP_CLR disarms, clears the hit and RELEASES the hold: "
        "run=1 resumes, run=0 falls to the boot stop with PC 0.",
        _bp_clr_releases_the_hold,
    ),
    Obligation(
        "step_while_running_is_not_ready",
        "A free-running core cannot be stepped: NOT_READY with the "
        "full 5-word prefix, the pre-step state, and no side effect.",
        _step_while_running_is_not_ready,
    ),
    Obligation(
        "bp_set_past_imem_is_range_without_a_fault",
        "A breakpoint address past IMEM_WORDS is RANGE, changes "
        "nothing, and latches NO fault (R3 adds no fault class).",
        _bp_set_past_imem_is_range_without_a_fault,
    ),
    Obligation(
        "wrong_payload_length_is_bad_frame",
        "A wrong payload length is a 1-word BAD_FRAME with no side "
        "effect on any debug register (S5).",
        _wrong_payload_length_is_bad_frame,
    ),
    Obligation(
        "bad_frame_leaves_no_trace",
        "A bad CRC arms nothing and executes nothing (S5).",
        _bad_frame_leaves_no_trace,
    ),
    Obligation(
        "debug_ops_are_host_target_only",
        "Every debug op answers UNSUPPORTED on the loopback target.",
        _debug_ops_are_host_target_only,
    ),
    Obligation(
        "debug_status_is_the_full_readback",
        "DEBUG_STATUS is the 5-word prefix plus run/a/x/y/insn, and it "
        "answers while running and while held.",
        _debug_status_is_the_full_readback,
    ),
    Obligation(
        "breakpoint_at_address_zero_is_armed",
        "Address 0 is a legal breakpoint, distinguished from 'disarmed' "
        "by bp_flags bit0 rather than by the address value.",
        _breakpoint_at_address_zero_is_armed,
    ),
    Obligation(
        "boot_stop_holds_pc_at_zero",
        "run=0 with no hold is the boot stop: the PC is held at 0.",
        _boot_stop_holds_pc_at_zero,
    ),
)


def by_name() -> dict[str, Obligation]:
    return {obligation.name: obligation for obligation in OBLIGATIONS}


def run_all_probes(pe: F.FakePE | None = None) -> dict[str, bool]:
    """Run every probe; name -> result.

    Each probe gets its OWN model unless one is supplied. Sharing a single
    model makes the suite order-dependent, because R3 state persists: a probe
    that leaves the run strap high, a breakpoint armed or a debug hold in
    place changes what the NEXT probe observes. Two of these probes failed only
    when run in sequence and passed alone -- exactly that contamination, and
    exactly the kind of green that is not reproducible.
    """
    if pe is not None:
        return {obligation.name: bool(obligation.probe(pe)) for obligation in OBLIGATIONS}
    return {
        obligation.name: bool(obligation.probe(F.FakePE())) for obligation in OBLIGATIONS
    }


def unconfirmed_names() -> list[str]:
    return [o.name for o in OBLIGATIONS if not o.chip_confirmed]
