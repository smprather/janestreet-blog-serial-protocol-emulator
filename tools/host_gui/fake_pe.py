"""In-memory PE chip model and fake USB bridge for host-side testing.

The fake implements the framed protocol from ``protocol.py`` and mirrors the
current RTL loader semantics (``rtl/pe_ctrl.v``) so the host can be developed
and tested without a board:

  * LOAD commits payload words from address 0; ``words_written`` and the echo
    log are per load (CS-session semantics);
  * a word queued when ``run`` rises is aborted: it is never committed, never
    counted and never echoed, and the load faults (the A1 run-abort rule,
    transferred from the superseded ``uio[4]`` echo into the framed response);
  * a full 1024-word image commits its final word exactly once -- the
    "final-word echo" is the fourth LOAD response word;
  * LOAD/READ_IMEM/READ_DMEM/DUMP_CORE require ``run=0``; STATUS/READ_CPU are
    non-halting (plan "PE host protocol");
  * target 1 is a deterministic loopback/test target on the same serializer;
    unknown targets answer UNSUPPORTED without a fault.

``FakeBridge`` wraps ``FakePE`` in the newline-JSON USB protocol the session
speaks: request/response objects plus asynchronous ``board.reset``,
``chip.irq``, ``chip.status`` and ``protocol.error`` events.
"""

from __future__ import annotations

import json
from collections import deque
from collections.abc import Callable, Iterable

from tools.host_gui import board
from tools.host_gui import protocol as P

IMEM_WORDS = 1024
DMEM_BYTES = 16

# Fault bits (plan Open Item 4's initial sources: loader, CRC, range, protocol).
FAULT_LOAD = 0x0001
FAULT_CRC = 0x0002
FAULT_RANGE = 0x0004
FAULT_PROTOCOL = 0x0008

# Target capability bits returned by TARGET.
CAP_LOAD = 0x0001
CAP_STATUS = 0x0002
CAP_READ = 0x0004
CAP_IRQ = 0x0008
CAP_HOST = CAP_LOAD | CAP_STATUS | CAP_READ | CAP_IRQ
CAP_LOOPBACK = 0x0010

# Deterministic identification word for the loopback target.
LOOPBACK_ID = 0x10C0

STATE_STOPPED = 0
STATE_RUNNING = 1

# ---- R3 debug control (chip repo R3-DEBUG-CONTROL-CONTRACT.md) -------------
# Reconciled against the IMPLEMENTED RTL on 2026-09-25: pe_ctrl.v's R3 header
# block, its four response builders, and the two wires that define the
# encoding --
#     wire [1:0] dbg_state = dbg_hold_r ? (bp_hit ? 2'd3 : 2'd2)
#                                        : (run ? 2'd1 : 2'd0);
#     wire [1:0] bp_flags  = {bp_hit, bp_en};   // bit0 armed, bit1 hit
# The chip is the source of truth. Where the contract document's vector table
# and the RTL disagree, the RTL wins and the difference is REPORTED to the
# manager, not smoothed over here (see r3_reads.py's DISCREPANCIES).
#
#   state (2 bits, low half of the word; upper bits ZERO)
#   0 STOPPED     the normal boot stop: run=0, no hold, PC held at 0
#   1 RUNNING     the strap is high and no debug hold is asserted
#   2 DEBUG_HOLD  held by the debug controls, PC PRESERVED (single-stepping)
#   3 BP_HIT      held by the breakpoint, PC preserved, the hit latched
# R2's STATUS `state` word carries the SAME encoding, so 0/1 keep their R1/R2
# meaning and only a debug hold can ever enter 2/3.
DEBUG_STOPPED = 0
DEBUG_RUNNING = 1
DEBUG_HOLD = 2
DEBUG_BP_HIT = 3

DEBUG_STATE_NAMES = {
    DEBUG_STOPPED: "STOPPED",
    DEBUG_RUNNING: "RUNNING",
    DEBUG_HOLD: "DEBUG_HOLD",
    DEBUG_BP_HIT: "BP_HIT",
}

# bp_flags bits. bp_addr is the armed address, or 0 when disarmed: a breakpoint
# at address 0 is legal and is distinguished from "disarmed" by bit0, never by
# the address value.
BP_FLAG_ARMED = 0b01
BP_FLAG_HIT = 0b10

# The four debug ops are ready-immediate - answered from registers in the
# request's own CRC cycle, like READ_CPU - so they carry ZERO wait words. Each
# request's payload length is fixed; pe_ctrl.v raises frm_len_bad otherwise,
# which answers a 1-word BAD_FRAME, latches FAULT_PROTOCOL, and has no side
# effect on any debug register.
DEBUG_REQUEST_WORDS = {
    P.OP_DEBUG_STEP: 0,
    P.OP_DEBUG_BP_SET: 1,
    P.OP_DEBUG_BP_CLR: 0,
    P.OP_DEBUG_STATUS: 0,
}

# The ISA (rtl/pe_cpu.v): [15:12] opcode, [11:0] operand. R3's contract is
# stated over real instructions ("a step executes imem[0]", "the LDI at 1
# executed exactly once"), so the model must execute them for the golden
# vectors to mean anything. IN/OUT address a port space the host model does not
# have, so they are no-ops here; the chip TB is what proves IO.
ISA_LDI = 0x0
ISA_OUT = 0x1
ISA_IN = 0x2
ISA_MOV = 0x3
ISA_JMP = 0x4
ISA_JZ = 0x5
ISA_JNZ = 0x6
ISA_ALU = 0x7
ISA_INCX = 0x8
ISA_DECX = 0x9
ISA_SHR = 0xA
ISA_LDS = 0xB
ISA_STS = 0xC
ISA_LDM = 0xD
ISA_STM = 0xE
ISA_NOP = 0xF

STATUS_KEYS = (
    "state",
    "run",
    "target",
    "pc",
    "a",
    "x",
    "y",
    "timer",
    "faults",
    "words_written",
)


class PEFrameError(Exception):
    """The fake PE produced no response (e.g. unframed garbage)."""


class FakeBridgeError(Exception):
    """A bridge request that cannot be dispatched."""


# Chip register widths — the ISA is the source of truth (manager ruling,
# 2026-09-25). These mirror rtl/pe_cpu.v on the chip side and are enforced in
# the model so it can never report a field the hardware could not hold:
#   * a, x, y are `logic [7:0]`                            -> 8 bits
#   * pc is `logic [PCW-1:0]`, PCW = max(8, IAW); the SoC instantiates
#     IMEM_WORDS=1024 so IAW=10 and PCW=10                 -> 10 bits
#     ("full width" means all 10 PC bits, not invented bits)
#   * an instruction word is 16 bits (`imem_rdata`)         -> 16 bits
# The R2 package once encoded a=0x1FFF (13 bits), which no chip can produce;
# test_r2_reads pins these against the RTL text so it cannot recur.
ISA_A_BITS = 8
ISA_X_BITS = 8
ISA_Y_BITS = 8
ISA_PC_BITS = 10
ISA_INSN_BITS = 16
# Bounded reads carry at most MAX_READ_WORDS=15 data words per frame (the chip
# rejects a larger count with RANGE so the host splits; see rtl/pe_ctrl.v
# MAX_READ_WORDS). DMEM packs two bytes per word. The model enforces both so a
# large read cannot be OK in --fake and RANGE on silicon - the divergence the
# independent chip review found.
MAX_READ_WORDS = 15
MAX_READ_DMEM_BYTES = 2 * MAX_READ_WORDS
ISA_PC_MASK = (1 << ISA_PC_BITS) - 1
ISA_REG_MASK = (1 << ISA_A_BITS) - 1
ISA_INSN_MASK = (1 << ISA_INSN_BITS) - 1


def _word(payload: tuple[int, ...], index: int, default: int = 0) -> int:
    """One request payload word, or ``default`` when the frame is short.

    `decode_frame` has already validated every payload word as a 16-bit int,
    so the `int(payload[0]) if payload else 0` this replaces was coercing a
    value that could not be anything else. Naming the defaulting rule once is
    clearer than repeating it at each site, and it is total by construction.
    """
    return payload[index] if index < len(payload) else default


def _payload_bytes(words: Iterable[int]) -> bytes:
    """Pack request payload words big-endian.

    Strict at the boundary, like the bridge's `pe_frame.words_to_bytes`: the
    words are already validated 16-bit ints coming out of a decoded frame, so
    `int()` here could only ever mislead -- it silently truncates 1.5 to 1 and
    accepts "7". A wire encoder must never coerce, so the width is checked
    instead.
    """
    out = bytearray()
    for word in words:
        if isinstance(word, bool) or not isinstance(word, int) or not 0 <= word <= 0xFFFF:
            raise ValueError(f"not a 16-bit payload word: {word!r}")
        out += word.to_bytes(2, "big")
    return bytes(out)


class FakePE:
    """The framed-protocol chip model (no USB/JSON layer).

    ``read_fault_policy`` parameterizes one open chip contract question: does
    an out-of-range **read** latch a sticky fault, or answer RANGE with no
    fault? The plan's read step requires RANGE and "do not wrap" but is silent
    on the sticky fault, so the model exposes both ("latch" is the historical
    default, kept so existing tests do not change; "status-only" is the other
    side of the open question). The chip side settles it; see
    ``tools/host_gui/r2_reads.py``.

    Every register the model reports is masked to its ISA width
    (``ISA_*_BITS`` above), so a test that pokes an over-wide value still gets a
    chip-plausible answer instead of a field the silicon could not hold.
    """

    def __init__(self, *, read_fault_policy: str = "latch") -> None:
        if read_fault_policy not in ("latch", "status-only"):
            raise ValueError("read_fault_policy must be 'latch' or 'status-only'")
        self.read_fault_policy = read_fault_policy
        self.imem: list[int] = [0] * IMEM_WORDS
        self.dmem = bytearray(DMEM_BYTES)
        self.run = False
        self.pc = self.a = self.x = self.y = self.insn = self.timer = 0
        self.faults = 0
        self.words_written = 0
        self.committed_words: list[int] = []
        self.selected_target = 0
        # R3 debug control: ONE breakpoint register (the contract is a single
        # PC breakpoint, not a table), the debug hold, and the hit latch.
        # `on_step`, when set, is called after each executed instruction with
        # the landing PC, so a test can observe the stop-before comparison.
        self.bp_addr = 0
        self.bp_en = False
        self.bp_hit = False
        self.debug_hold = False
        self.on_step: Callable[[int], None] | None = None
        # Test stimulus for the run-abort window: simulate `run` rising just
        # before word `abort_after_words` would be committed. One-shot.
        self.abort_after_words: int | None = None

    @property
    def state(self) -> int:
        """The R1/R2/R3 state word: hold ? (hit ? 3 : 2) : (run ? 1 : 0).

        R2 vectors only ever produce 0/1 (nothing sets a hold), so this is
        bit-for-bit the R2 `state`; 2/3 are reachable only through debug
        control, exactly as the contract says.
        """
        if self.debug_hold:
            return DEBUG_BP_HIT if self.bp_hit else DEBUG_HOLD
        return DEBUG_RUNNING if self.run else DEBUG_STOPPED

    @property
    def bp_flags(self) -> int:
        """{bp_hit, bp_en}: bit0 armed, bit1 hit latched."""
        return (BP_FLAG_HIT if self.bp_hit else 0) | (BP_FLAG_ARMED if self.bp_en else 0)

    @property
    def latched_insn(self) -> int:
        """The instruction word READ_CPU reports.

        While a debug hold is asserted the fetch mode is `pc` (pe_cpu:
        `imem_addr = cpu_exec ? next_pc : dbg_hold ? pc : 0`), so the reported
        word is the one AT the held PC -- the landing instruction, which is what
        a debugger wants to see. Otherwise it is the latched register, because
        that is what a conformance-TB snapshot preloads: R2's READ_CPU vectors
        preload `insn` (0xFFFF) and the chip passes them byte-exactly, so the
        register must survive here. Asserting the fetched word unconditionally
        would break the chip-confirmed R2 package, which is why this is scoped
        to the hold.
        """
        if self.debug_hold:
            return self.imem[self.pc & ISA_PC_MASK] & ISA_INSN_MASK
        return self.insn & ISA_INSN_MASK

    @property
    def fetch_address(self) -> int:
        """Where the core fetches, per pe_cpu's three fetch modes.

        next_pc while executing, pc while held (so imem_rdata == imem[pc]),
        zero at the boot stop.
        """
        if not self.debug_hold and self.run:
            return self._next_pc(self.imem[self.pc], self.pc)
        return self.pc & ISA_PC_MASK

    # ---- R3 debug control -------------------------------------------------
    def reset_debug(self) -> None:
        """Disarm the breakpoint and release the hold (a prepare/reset)."""
        self.bp_addr = 0
        self.bp_en = False
        self.bp_hit = False
        self.debug_hold = False

    def set_run(self, active: bool) -> None:
        """Drive the run STRAP. With no hold, dropping run is the boot stop."""
        self.run = bool(active)
        if not self.run and not self.debug_hold:
            self.pc = 0  # the boot stop re-zeroes the PC

    def _next_pc(self, insn: int, pc: int) -> int:
        """The combinational next PC for ``insn`` fetched at ``pc``."""
        opcode, arg = (insn >> 12) & 0xF, insn & 0xFFF
        if opcode == ISA_JMP:
            return arg & ISA_PC_MASK
        if opcode == ISA_JZ and self.a == 0:
            return arg & ISA_PC_MASK
        if opcode == ISA_JNZ and self.a != 0:
            return arg & ISA_PC_MASK
        return (pc + 1) & ISA_PC_MASK

    def _execute_one(self) -> int:
        """Execute exactly ONE instruction at the PC; return the landing PC.

        S1: one PC update and one set of side effects, at most. This is the
        ISA from rtl/pe_cpu.v's header. IN/OUT address a port space the host
        model has no equivalent for, so they only advance the PC.
        """
        pc = self.pc & ISA_PC_MASK
        insn = self.imem[pc] & ISA_INSN_MASK
        self.insn = insn
        opcode, arg = (insn >> 12) & 0xF, insn & 0xFFF
        imm8, addr8 = arg & 0xFF, arg & 0xFF
        if opcode == ISA_LDI:
            self.a = imm8
        elif opcode == ISA_MOV:
            sel = (arg >> 8) & 0x3
            if sel == 0:
                self.y = self.a
            elif sel == 1:
                self.a = self.y
            elif sel == 2:
                self.x = self.a
            elif sel == 3:
                self.a = self.x
        elif opcode == ISA_ALU:
            sub = (arg >> 8) & 0x3
            if sub == 0:
                self.a = (self.a + imm8) & ISA_REG_MASK
            elif sub == 1:
                self.a = (self.a - imm8) & ISA_REG_MASK
            elif sub == 2:
                self.a &= imm8
            else:
                self.a |= imm8
        elif opcode == ISA_INCX:
            self.x = (self.x + 1) & ISA_REG_MASK
        elif opcode == ISA_DECX:
            self.x = (self.x - 1) & ISA_REG_MASK
        elif opcode == ISA_SHR:
            self.a = (self.a >> 1) & ISA_REG_MASK
        elif opcode == ISA_LDS:
            self.a = self.dmem[self.x % DMEM_BYTES]
        elif opcode == ISA_STS:
            self.dmem[self.x % DMEM_BYTES] = self.a
        elif opcode == ISA_LDM:
            self.a = self.dmem[addr8 % DMEM_BYTES]
        elif opcode == ISA_STM:
            self.dmem[addr8 % DMEM_BYTES] = self.a
        # ISA_OUT / ISA_IN / ISA_NOP / ISA_JMP / ISA_JZ / ISA_JNZ carry no
        # register side effect here; a branch lands through _next_pc.
        landing = self._next_pc(insn, pc)
        self.pc = landing
        if self.on_step is not None:
            self.on_step(landing)
        return landing

    def debug_step_once(self) -> tuple[int, int, int]:
        """Model one DEBUG_STEP commit; return (state, pc_next, bp_flags).

        Stop-before (S3): the hit is compared on the LANDING address, so when
        it matches the armed breakpoint the instruction AT that address has NOT
        executed -- which is what lets a debugger inspect it and then step that
        very instruction.
        """
        pc = self.pc & ISA_PC_MASK
        landing = self._next_pc(self.imem[pc], pc)
        # A step is EXACTLY ONE INSTRUCTION, and it RUNS: pe_ctrl pulses
        # `dbg_step_r`, so `cpu_exec` is true and the instruction at the current
        # PC executes. The stop-before property is that the instruction AT THE
        # LANDING ADDRESS has not run -- which is guaranteed by the hold below,
        # not by skipping the execute.
        #
        # This host model used to skip the execute whenever the landing address
        # matched, which suppressed the WRONG instruction: it withheld the step
        # instead of the breakpoint. The chip's conformance run caught it -- a
        # step from 1 to 2 really does retire the LDI A,0xAA at address 1.
        self._execute_one()
        self.debug_hold = True
        self.bp_hit = self.bp_en and landing == self.bp_addr
        return self.state, self.pc, self.bp_flags

    def advance_free_running(self, max_instructions: int = 4096) -> bool:
        """Advance a free-running core until the breakpoint stops it.

        The live-core half of S3: while the core executes and its landing
        address equals an armed breakpoint, the chip holds it at that edge.
        Returns True if it stopped on the breakpoint. A TB reaches the same
        state by clocking the real core; the model needs an explicit driver
        because nothing advances it on its own.
        """
        for _ in range(max_instructions):
            if not self.run or self.debug_hold:
                return self.bp_hit
            pc = self.pc & ISA_PC_MASK
            landing = self._next_pc(self.imem[pc], pc)
            if self.bp_en and landing == self.bp_addr:
                # Stop-before: the instruction at bp_addr has NOT run.
                self.pc = landing
                self.debug_hold = True
                self.bp_hit = True
                return True
            self._execute_one()
        return False

    # ---- framed interface -------------------------------------------------
    def request(
        self,
        opcode: int,
        sequence: int = 0,
        target: int = 0,
        payload_words: Iterable[int] = (),
    ) -> P.Frame:
        """Encode a request, exchange it, decode the response frame."""
        raw = P.encode_frame(opcode, sequence, target, _payload_bytes(payload_words))
        response = self.exchange(raw)
        if response is None:
            raise PEFrameError("frame produced no response")
        return P.decode_frame(response)

    def exchange(self, raw: bytes) -> bytes | None:
        """Consume one raw frame, return a raw response frame (or None)."""
        try:
            frame = P.decode_frame(raw)
        except P.FrameSyncError:
            return None
        except (P.FrameLengthError, P.FrameCRCError, P.FrameVersionError) as exc:
            if isinstance(exc, P.FrameCRCError):
                self.faults |= FAULT_CRC
            else:
                self.faults |= FAULT_PROTOCOL
            opcode, sequence, target = self._salvage(raw)
            return self._response(opcode, sequence, target, (P.STATUS_BAD_FRAME,))
        return self._dispatch(frame)

    # ---- dispatch ---------------------------------------------------------
    def _dispatch(self, frame: P.Frame) -> bytes:
        opcode, sequence, target = frame.opcode, frame.sequence, frame.target
        if opcode & P.RESPONSE_BIT:
            return self._response(
                opcode & ~P.RESPONSE_BIT, sequence, target, (P.STATUS_UNSUPPORTED,)
            )
        if target == P.TARGET_LOOPBACK:
            return self._loopback(opcode, sequence, target)
        if target != P.TARGET_HOST:
            return self._response(opcode, sequence, target, (P.STATUS_UNSUPPORTED,))
        # R3: each debug op carries a FIXED request payload length
        # (pe_ctrl.v raises frm_len_bad otherwise). A wrong length answers a
        # 1-word BAD_FRAME, latches the pre-existing FAULT_PROTOCOL, and
        # reaches no handler - so it has no side effect on any debug register
        # and executes no instruction (S5).
        expected = DEBUG_REQUEST_WORDS.get(opcode)
        if expected is not None and len(frame.payload) != expected:
            self.faults |= FAULT_PROTOCOL
            return self._response(opcode, sequence, target, (P.STATUS_BAD_FRAME,))
        handler = {
            P.OP_PING: self._ping,
            P.OP_LOAD: self._load,
            P.OP_STATUS: self._status,
            P.OP_READ_CPU: self._read_cpu,
            P.OP_READ_IMEM: self._read_imem,
            P.OP_READ_DMEM: self._read_dmem,
            P.OP_DUMP_CORE: self._dump_core,
            P.OP_CLEAR_FAULT: self._clear_fault,
            P.OP_TARGET: self._target,
            P.OP_DEBUG_STEP: self._debug_step,
            P.OP_DEBUG_BP_SET: self._debug_bp_set,
            P.OP_DEBUG_BP_CLR: self._debug_bp_clr,
            P.OP_DEBUG_STATUS: self._debug_status,
        }.get(opcode)
        if handler is None:
            return self._response(opcode, sequence, target, (P.STATUS_UNSUPPORTED,))
        return self._response(opcode, sequence, target, handler(frame.payload))

    def _loopback(self, opcode: int, sequence: int, target: int) -> bytes:
        if opcode == P.OP_PING:
            payload = (P.STATUS_OK, LOOPBACK_ID)
        elif opcode == P.OP_TARGET:
            payload = (P.STATUS_OK, P.TARGET_LOOPBACK, CAP_LOOPBACK)
        else:
            payload = (P.STATUS_UNSUPPORTED,)
        return self._response(opcode, sequence, target, payload)

    def _response(
        self, opcode: int, sequence: int, target: int, payload: tuple[int, ...]
    ) -> bytes:
        return P.encode_frame(
            opcode | P.RESPONSE_BIT, sequence, target, _payload_bytes(payload)
        )

    @staticmethod
    def _salvage(raw: bytes) -> tuple[int, int, int]:
        """Best-effort header recovery for a BAD_FRAME response."""
        if len(raw) < 8:
            return 0, 0, P.TARGET_HOST
        header = int.from_bytes(raw[2:4], "big")
        sequence = int.from_bytes(raw[4:6], "big")
        return (header >> 4) & 0xFF, sequence, header & 0xF

    # ---- opcode handlers ---------------------------------------------------
    def _echo(self) -> int:
        return self.committed_words[-1] if self.committed_words else 0

    def _ping(self, payload: tuple[int, ...] = ()) -> tuple[int, ...]:
        return (P.STATUS_OK,)

    def _load(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        if self.run:
            return (P.STATUS_NOT_READY, self.words_written, self.faults, self._echo())
        self.words_written = 0
        self.committed_words = []
        abort_after = self.abort_after_words
        self.abort_after_words = None
        for index, word in enumerate(payload):
            if index >= IMEM_WORDS:
                self.faults |= FAULT_RANGE
                return (P.STATUS_RANGE, self.words_written, self.faults, self._echo())
            if abort_after is not None and index == abort_after:
                self.run = True
                self.faults |= FAULT_LOAD
                return (P.STATUS_FAULT, self.words_written, self.faults, self._echo())
            self.imem[index] = word
            self.committed_words.append(word)
            self.words_written += 1
        return (P.STATUS_OK, self.words_written, self.faults, self._echo())

    def _regs(self) -> tuple[int, int, int, int, int]:
        """The CPU registers, masked to the ISA widths the chip can hold."""
        return (
            self.pc & ISA_PC_MASK,
            self.a & ISA_REG_MASK,
            self.x & ISA_REG_MASK,
            self.y & ISA_REG_MASK,
            self.insn & ISA_INSN_MASK,
        )

    def _status(self, payload: tuple[int, ...] = ()) -> tuple[int, ...]:
        pc, a, x, y, _insn = self._regs()
        return (
            P.STATUS_OK,
            self.state,
            1 if self.run else 0,
            self.selected_target,
            pc,
            a,
            x,
            y,
            self.timer,
            self.faults,
            self.words_written,
        )

    def _read_cpu(self, payload: tuple[int, ...] = ()) -> tuple[int, ...]:
        # The last payload word is the RUN STRAP, not the debug state. pe_ctrl's
        # OP_RDCPU builder is explicit -- `resp_buf[6] <= {15'b0, run}` -- and so
        # is the R2 header, `(OK, pc, a, x, y, insn, run)`. The R2 package's own
        # READ_CPU vector carries a run value there and the chip passes it 18/18,
        # which settles the shape. This host builder used to put the DEBUG STATE
        # in that slot, which agreed with `run` only when no hold was asserted
        # and silently disagreed the moment one was (state 2 vs run 0).
        pc, a, x, y, _latched = self._regs()
        return (P.STATUS_OK, pc, a, x, y, self.latched_insn,
                1 if self.run else 0)

    def _read_range_fault(self) -> None:
        """Latch FAULT_RANGE on a read range error only under the 'latch' policy."""
        if self.read_fault_policy == "latch":
            self.faults |= FAULT_RANGE

    def _read_imem(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        if self.run:
            return (P.STATUS_NOT_READY,)
        address = _word(payload, 0)
        count = _word(payload, 1)
        if (
            address < 0
            or count < 0
            or address + count > IMEM_WORDS
            or count == 0
            or count > MAX_READ_WORDS
        ):
            self._read_range_fault()
            return (P.STATUS_RANGE,)
        return (P.STATUS_OK, *self.imem[address : address + count])

    def _read_dmem(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        if self.run:
            return (P.STATUS_NOT_READY,)
        address = _word(payload, 0)
        count = _word(payload, 1)
        if (
            address < 0
            or count < 0
            or address + count > DMEM_BYTES
            or count == 0
            or count > MAX_READ_DMEM_BYTES
        ):
            self._read_range_fault()
            return (P.STATUS_RANGE,)
        chunk = bytearray(self.dmem[address : address + count])
        if len(chunk) % 2:
            chunk.append(0)  # zero-pad the last word
        return (
            P.STATUS_OK,
            *(int.from_bytes(chunk[i : i + 2], "big") for i in range(0, len(chunk), 2)),
        )

    def _dump_core(self, payload: tuple[int, ...] = ()) -> tuple[int, ...]:
        if self.run:
            return (P.STATUS_NOT_READY,)
        return self._status()

    def _clear_fault(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        mask = _word(payload, 0)
        self.faults &= ~mask & 0xFFFF
        return (P.STATUS_OK, self.faults)

    def _target(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        requested = _word(payload, 0)
        if requested == P.TARGET_HOST:
            self.selected_target = P.TARGET_HOST
            return (P.STATUS_OK, P.TARGET_HOST, CAP_HOST)
        if requested == P.TARGET_LOOPBACK:
            self.selected_target = P.TARGET_LOOPBACK
            return (P.STATUS_OK, P.TARGET_LOOPBACK, CAP_LOOPBACK)
        return (P.STATUS_UNSUPPORTED,)

    # ---- R3 debug-control handlers (per the IMPLEMENTED pe_ctrl.v) --------
    # Every shape below is transcribed from the RTL's response builders, not
    # from prose. The common 5-word prefix is (OK, state, pc, bp_addr,
    # bp_flags); DEBUG_STATUS appends the architectural state.
    def _debug_prefix(self, status: int) -> tuple[int, ...]:
        """(status, state, pc, bp_addr, bp_flags) - the common debug prefix."""
        return (status, self.state, self.pc, self.bp_addr, self.bp_flags)

    def _debug_step(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        # pe_ctrl: a free-running core cannot be stepped -- NOT_READY with no
        # side effect. The refusal still answers the FULL 5-word prefix, with
        # the PRE-step state, pc and flags (the RTL overrides exactly those
        # three words in the refusal branch), so the host can tell a refusal
        # from a step without a second read.
        if self.run and not self.debug_hold:
            return self._debug_prefix(P.STATUS_NOT_READY)
        # The response reports the state AFTER the step, and pc_next is where
        # the next step will execute from.
        state, pc_next, flags = self.debug_step_once()
        return (P.STATUS_OK, state, pc_next, self.bp_addr, flags)

    def _debug_bp_set(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        address = _word(payload, 0)
        # Rejected ops have NO side effect (S5): past the end of instruction
        # memory is RANGE, the breakpoint is NOT armed and NOT changed, and
        # unlike the bounded READS this latches NO fault -- the R3 contract
        # adds no fault class, and the RTL has no FAULT_RANGE write here.
        if not 0 <= address < IMEM_WORDS:
            return self._debug_prefix(P.STATUS_RANGE)
        # The RTL builds the prefix in the same cycle it latches the new
        # address: state and pc are the values at the REQUEST, while bp_addr
        # and bp_flags report the ARMED breakpoint. Arming clears a stale hit.
        state, pc = self.state, self.pc
        self.bp_addr = address
        self.bp_en = True
        self.bp_hit = False
        return (P.STATUS_OK, state, pc, address, BP_FLAG_ARMED)

    def _debug_bp_clr(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        # Disarm, clear the hit, and RELEASE the hold. The state word is the
        # RELEASED state (RUNNING when the strap is high, STOPPED otherwise)
        # and the pc field is the PC at the request -- with run=0 the core
        # re-zeroes at this same edge, so a following STATUS reads 0.
        released = DEBUG_RUNNING if self.run else DEBUG_STOPPED
        answer = (P.STATUS_OK, released, self.pc, self.bp_addr, 0)
        self.bp_en = False
        self.bp_hit = False
        self.debug_hold = False
        if not self.run:
            self.pc = 0  # the boot stop re-zeroes the PC
        return answer

    def _debug_status(self, payload: tuple[int, ...] = ()) -> tuple[int, ...]:
        # The full readback: the 5-word prefix plus run/a/x/y/insn, the same
        # fields and widths READ_CPU reports. insn is the FETCHED word, so it
        # follows pe_cpu's three fetch modes (next_pc while executing, pc
        # while held, zero at the boot stop) rather than imem[pc] blindly.
        pc, a, x, y, _insn = self._regs()
        return (
            P.STATUS_OK,
            self.state,
            pc,
            self.bp_addr,
            self.bp_flags,
            1 if self.run else 0,
            a,
            x,
            y,
            self.imem[self.fetch_address] & ISA_INSN_MASK,
        )


def _arg_int(args: dict, key: str, default: int = 0) -> int:
    """One integer request argument, as a typed `FakeBridgeError`.

    Bridge arguments arrive as free-form JSON and the fuzzer attacks them, so
    a non-integer must become a typed error the request loop already handles --
    `int()` would instead raise ValueError/TypeError straight out of
    `handle_line`, which catches only `FakeBridgeError`, turning a bad request
    into an unhandled crash instead of an `ok=false` reply. It also stops the
    silent coercions `int()` would otherwise perform (1.5 -> 1, "7" -> 7).
    """
    value = args.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise FakeBridgeError(f"{key} must be an integer, got {value!r}")
    return value


class FakeBridge:
    """Newline-JSON USB bridge over ``FakePE`` (the Pico's role)."""

    def __init__(self) -> None:
        self.pe = FakePE()
        self._known_faults = 0
        self._pending_events: deque[str] = deque()

    # ---- newline-JSON interface -------------------------------------------
    def handle_line(self, line: str) -> list[str]:
        """Consume one request line; return event/response lines in order."""
        try:
            message = json.loads(line)
        except ValueError:
            return [self._event_line("protocol.error", {"error": "malformed JSON"})]
        if (
            not isinstance(message, dict)
            or message.get("v") != 1
            or not isinstance(message.get("id"), int)
            or not isinstance(message.get("op"), str)
        ):
            replies = [self._event_line("protocol.error", {"error": "malformed request"})]
            request_id = message.get("id") if isinstance(message, dict) else None
            if isinstance(request_id, int):
                replies.append(
                    self._response_line(request_id, False, None, "malformed request")
                )
            return replies

        request_id = message["id"]
        op = message["op"]
        args = message.get("args") or {}
        if not isinstance(args, dict):
            return [
                self._event_line("protocol.error", {"error": "args must be an object"}),
                self._response_line(request_id, False, None, "args must be an object"),
            ]
        try:
            result = self._dispatch(op, args)
        except FakeBridgeError as exc:
            self._emit_fault_events()
            return [
                *self._drain_events(),
                self._response_line(request_id, False, None, str(exc)),
            ]
        self._emit_fault_events()
        return [
            *self._drain_events(),
            self._response_line(request_id, True, result, None),
        ]

    # ---- operations --------------------------------------------------------
    def _dispatch(self, op: str, args: dict) -> dict:
        target = _arg_int(args, "target", P.TARGET_HOST)
        if op == "hello":
            return {
                "protocol_version": 1,
                "bridge_version": "fake-1",
                "clock_hz": board.PE_CLOCK_HZ,
                "sclk_hz_max": board.SCLK_GUARD_HZ,
                "pads": dict(board.HOST_SPI_PADS),
            }
        if op == "prepare":
            self.pe.run = False
            self.pe.faults = 0
            self.pe.reset_debug()
            self._event("board.reset", {})
            return {"state": "PREPARED", "run": False}
        if op == "ping":
            frame = self.pe.request(P.OP_PING, target=target)
            return {"status": frame.payload[0]}
        if op == "load":
            self.pe.run = False  # LOAD forces run=0 (plan Task 2)
            words = args.get("words", [])
            if not isinstance(words, list) or not all(
                isinstance(w, int) and 0 <= w <= 0xFFFF for w in words
            ):
                raise FakeBridgeError("load words must be 16-bit integers")
            frame = self.pe.request(P.OP_LOAD, payload_words=words)
            result = {
                "status": frame.payload[0],
                "words_written": frame.payload[1],
                "faults": frame.payload[2],
                "echo": frame.payload[3],
                "target": frame.target,
            }
            self._event("chip.status", dict(result))
            return result
        if op == "start":
            # The run STRAP. Debug control may still hold the core, so the
            # state word - not the strap - is what the session must read back;
            # this result is only the bridge's report of what it commanded.
            self.pe.set_run(True)
            result = {"state": "RUNNING", "run": True}
            self._event("chip.status", dict(result))
            return result
        if op == "stop":
            self.pe.set_run(False)
            result = {"state": "STOPPED", "run": False}
            self._event("chip.status", dict(result))
            return result
        if op == "status":
            return self._status_result(self.pe.request(P.OP_STATUS, target=target))
        if op == "dump_core":
            return self._status_result(self.pe.request(P.OP_DUMP_CORE, target=target))
        if op == "read_cpu":
            values = self.pe.request(P.OP_READ_CPU, target=target).payload
            return {
                "status": values[0],
                "pc": values[1],
                "a": values[2],
                "x": values[3],
                "y": values[4],
                "insn": values[5],
                "state": values[6],
            }
        if op == "read_imem":
            address = _arg_int(args, "address")
            count = _arg_int(args, "count")
            frame = self.pe.request(
                P.OP_READ_IMEM, target=target, payload_words=(address, count)
            )
            ok = frame.payload[0] == P.STATUS_OK
            return {
                "status": frame.payload[0],
                "address": address,
                "words": list(frame.payload[1:]) if ok else [],
            }
        if op == "read_dmem":
            address = _arg_int(args, "address")
            count = _arg_int(args, "count")
            frame = self.pe.request(
                P.OP_READ_DMEM, target=target, payload_words=(address, count)
            )
            ok = frame.payload[0] == P.STATUS_OK
            packed = _payload_bytes(frame.payload[1:]) if ok else b""
            return {
                "status": frame.payload[0],
                "address": address,
                "bytes": list(packed[:count]) if ok else [],
            }
        if op == "clear_fault":
            mask = _arg_int(args, "mask", 0xFFFF)
            frame = self.pe.request(
                P.OP_CLEAR_FAULT, target=target, payload_words=(mask,)
            )
            return {"status": frame.payload[0], "faults": frame.payload[1]}
        if op == "target":
            requested = _arg_int(args, "target", P.TARGET_HOST)
            frame = self.pe.request(P.OP_TARGET, payload_words=(requested,))
            ok = frame.payload[0] == P.STATUS_OK
            return {
                "status": frame.payload[0],
                "target": frame.payload[1] if ok else self.pe.selected_target,
                "capabilities": frame.payload[2] if ok else 0,
            }
        # ---- R3 debug control (per the implemented pe_ctrl.v contract) -----
        if op == "debug_step":
            frame = self.pe.request(P.OP_DEBUG_STEP, target=target)
            p = frame.payload
            if p[0] != P.STATUS_OK:
                return {
                    "status": p[0],
                    "state": p[1],
                    "pc": p[2],
                    "bp_addr": p[3],
                    "bp_flags": p[4],
                }
            return {
                "status": p[0],
                "state": p[1],
                "pc_next": p[2],
                "bp_addr": p[3],
                "bp_flags": p[4],
                "hit": bool(p[4] & BP_FLAG_HIT),
                "debug_state_name": DEBUG_STATE_NAMES.get(p[1], f"UNKNOWN({p[1]})"),
            }
        if op == "bp_set":
            address = _arg_int(args, "address")
            frame = self.pe.request(
                P.OP_DEBUG_BP_SET, target=target, payload_words=(address,)
            )
            p = frame.payload
            return {
                "status": p[0],
                "state": p[1],
                "pc": p[2],
                "bp_addr": p[3],
                "bp_flags": p[4],
                "requested": address,
                "armed": bool(p[4] & BP_FLAG_ARMED),
            }
        if op == "bp_clr":
            frame = self.pe.request(P.OP_DEBUG_BP_CLR, target=target)
            p = frame.payload
            return {
                "status": p[0],
                "state": p[1],
                "pc": p[2],
                "bp_addr_before": p[3],
                "bp_flags": p[4],
            }
        if op == "debug_status":
            p = self.pe.request(P.OP_DEBUG_STATUS, target=target).payload
            return {
                "status": p[0],
                "state": p[1],
                "pc": p[2],
                "bp_addr": p[3],
                "bp_flags": p[4],
                "run": p[5],
                "a": p[6],
                "x": p[7],
                "y": p[8],
                "insn": p[9],
                "armed": bool(p[4] & BP_FLAG_ARMED),
                "hit": bool(p[4] & BP_FLAG_HIT),
                "debug_state_name": DEBUG_STATE_NAMES.get(p[1], f"UNKNOWN({p[1]})"),
            }
        raise FakeBridgeError(f"unknown op {op!r}")

    # ---- helpers -----------------------------------------------------------
    @staticmethod
    def _status_result(frame: P.Frame) -> dict:
        result: dict[str, int] = {
            "status": frame.payload[0] if frame.payload else P.STATUS_BAD_FRAME
        }
        for key, value in zip(STATUS_KEYS, frame.payload[1:]):
            result[key] = value
        return result

    def _event(self, name: str, data: dict) -> None:
        self._pending_events.append(self._event_line(name, data))

    def _emit_fault_events(self) -> None:
        new = self.pe.faults & ~self._known_faults
        if new:
            # Read STATUS before emitting the event (plan Task 2 Step 6). The
            # read does not clear the sticky fault.
            status = self._status_result(self.pe.request(P.OP_STATUS))
            self._event(
                "chip.irq", {"faults": self.pe.faults, "new": new, "status": status}
            )
        self._known_faults = self.pe.faults

    def _drain_events(self) -> list[str]:
        out = list(self._pending_events)
        self._pending_events.clear()
        return out

    @staticmethod
    def _response_line(request_id: int, ok: bool, result, error: str | None) -> str:
        return json.dumps(
            {"v": 1, "id": request_id, "ok": ok, "result": result, "error": error}
        )

    @staticmethod
    def _event_line(name: str, data: dict) -> str:
        return json.dumps({"v": 1, "event": name, "data": data})
