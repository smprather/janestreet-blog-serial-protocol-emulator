"""Controller session: the host-side state machine over the bridge transport.

Contract source: wiki/plans/host-controller-gui.md Task 6 Step 3 and "Locked
Decisions":

  * states: DISCONNECTED, PREPARED, LOADING, LOADED, RUNNING, STOPPED, FAULTED;
  * only load while stopped; start only after a successful load; stop from any
    running state; dump only while stopped;
  * never reuse request ids after a reconnect (each connect builds a fresh
    transport, whose ids restart at 1);
  * preserve the last status and fault event across a disconnect;
  * the negotiated SCLK cap from ``hello`` is enforced by ``negotiate_sclk``;
    nothing may silently exceed it (plan Global Constraints).

A transport timeout becomes a typed fault, not a fake success. Chip faults are
sticky: a fault event sets FAULTED, and only a successful CLEAR_FAULT returns
the session to a stopped state.
"""

from __future__ import annotations

import enum
import functools
import threading
from collections.abc import Callable
from dataclasses import asdict, dataclass
from typing import Protocol

from tools.host_gui import protocol as P
from tools.host_gui import transport as T


class TransportLike(Protocol):
    """What the session needs from a transport (real or a test double).

    A Protocol instead of the concrete ``SerialTransport`` so the state
    machine is testable with scripted transports, and any future transport
    (USB, socket) only has to satisfy these three calls.
    """

    def request(
        self, op: str, args: dict | None = None, *, timeout_s: float | None = None
    ) -> dict: ...

    def poll_events(self) -> list[dict]: ...

    def close(self) -> None: ...


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


class SessionState(enum.StrEnum):
    DISCONNECTED = "DISCONNECTED"
    PREPARED = "PREPARED"
    LOADING = "LOADING"
    LOADED = "LOADED"
    RUNNING = "RUNNING"
    STOPPED = "STOPPED"
    FAULTED = "FAULTED"
    # R3: the chip's own state encoding, mirrored so the GUI can tell the two
    # debug holds apart -- DEBUG_HOLD is a single step's pause, BP_HIT is a
    # latched breakpoint. They are different because the next action differs
    # (step on, versus step-off/clear-and-release).
    DEBUG_HOLD = "DEBUG_HOLD"
    BP_HIT = "BP_HIT"


class SessionError(Exception):
    """A session operation failed (transport, integrity, or rejection)."""


class SessionStateError(SessionError):
    """The requested operation is illegal in the current state."""


@dataclass(frozen=True)
class LoadResult:
    words_written: int
    faults: int
    echo: int
    target: int = P.TARGET_HOST


@dataclass(frozen=True)
class StatusSnapshot:
    state: int
    run: int
    target: int
    pc: int
    a: int
    x: int
    y: int
    timer: int
    faults: int
    words_written: int


@dataclass(frozen=True)
class CpuSnapshot:
    pc: int
    a: int
    x: int
    y: int
    insn: int
    state: int


@dataclass(frozen=True)
class CoreDump:
    state: int
    run: int
    target: int
    pc: int
    a: int
    x: int
    y: int
    timer: int
    faults: int
    words_written: int


# ---- R3 debug control ------------------------------------------------------
# Reconciled with the IMPLEMENTED pe_ctrl.v contract (2026-09-25). Every shape
# below is the RTL's response layout; tools/host_gui/r3_reads.py is the
# single source of truth and records the two places the contract's vector table
# and the RTL disagree.
#
#   0x21 DEBUG_STEP   -> (OK, state, pc_next, bp_addr, bp_flags)
#   0x22 DEBUG_BP_SET -> (OK, state, pc, bp_addr, bp_flags)
#   0x23 DEBUG_BP_CLR -> (OK, state, pc, bp_addr_before, bp_flags)
#   0x24 DEBUG_STATUS -> (OK, state, pc, bp_addr, bp_flags, run, a, x, y, insn)
DEBUG_STOPPED = 0
DEBUG_RUNNING = 1
DEBUG_HOLD = 2
DEBUG_BP_HIT = 3
DEBUG_STATE_NAMES = {0: "STOPPED", 1: "RUNNING", 2: "DEBUG_HOLD", 3: "BP_HIT"}
BP_FLAG_ARMED = 0b01
BP_FLAG_HIT = 0b10


def _debug_prefix(result: dict, op: str) -> DebugPrefix:
    """Validate the common 5-word debug prefix from a bridge result.

    Built as a `DebugPrefix` rather than a dict so every caller's field access
    is checked against the declared shape, and so a bridge that answers a
    non-integer field fails here as a typed SessionError instead of surfacing
    as an unhandled TypeError in the API layer.
    """
    return DebugPrefix(
        status=_result_int(result, "status", -1),
        state=_result_int(result, "state", 0),
        pc=_result_int(result, "pc", 0),
        bp_addr=_result_int(result, "bp_addr", 0),
        bp_flags=_result_int(result, "bp_flags", 0),
    )


def _require_ok(prefix: DebugPrefix, what: str) -> None:
    """Raise unless the chip answered OK, naming the status it did answer."""
    if prefix.status != P.STATUS_OK:
        raise SessionError(f"{what} failed with status {prefix.status}")


@dataclass(frozen=True)
class DebugPrefix:
    """The (state, pc, bp_addr, bp_flags) prefix every debug op answers with."""

    status: int
    state: int
    pc: int
    bp_addr: int
    bp_flags: int

    @property
    def state_name(self) -> str:
        return DEBUG_STATE_NAMES.get(self.state, f"UNKNOWN({self.state})")

    @property
    def armed(self) -> bool:
        return bool(self.bp_flags & BP_FLAG_ARMED)

    @property
    def hit(self) -> bool:
        return bool(self.bp_flags & BP_FLAG_HIT)


@dataclass(frozen=True)
class StepResult(DebugPrefix):
    """DEBUG_STEP: the prefix, where the next step executes from, and the hit."""

    pc_next: int = 0


@dataclass(frozen=True)
class DebugSnapshot(DebugPrefix):
    """DEBUG_STATUS: the prefix plus the architectural state."""

    run: int = 0
    a: int = 0
    x: int = 0
    y: int = 0
    insn: int = 0


def _require_int(value, what: str) -> int:
    """Strictly require an int, as a typed SessionError.

    `int(value)` is lenient, not safe: it silently truncates 1.5 to 1 and
    accepts "7". A controller must not act on a coerced value it never
    received, and a bad argument is the caller's bug -- reported as a
    SessionError the API maps to 409, not as a bare ValueError.
    """
    if isinstance(value, bool) or not isinstance(value, int):
        raise SessionError(f"{what} must be an integer, got {value!r}")
    return value


def _result_int(result: dict, key: str, default: int = 0) -> int:
    """One integer field from a bridge result, as a typed SessionError.

    A bridge is untrusted input -- fuzz_server attacks exactly this surface --
    so a result field that is not an integer must surface as a SessionError
    the API maps to 409, never as a bare ValueError/TypeError escaping the
    request handler as an unhandled 500.
    """
    return _require_int(result.get(key, default), f"bridge {key}")


def _result_int_list(result: dict, key: str) -> list[int]:
    """A list-of-integers field from a bridge result, as a typed SessionError."""
    values = result.get(key, [])
    if not isinstance(values, (list, tuple)):
        raise SessionError(f"bridge {key} must be a list, got {values!r}")
    return [_require_int(value, f"bridge {key} entry") for value in values]


def _status_fields(result: dict) -> dict[str, int]:
    return {key: _result_int(result, key, 0) for key in STATUS_KEYS}


def _snapshot(result: dict) -> StatusSnapshot:
    return StatusSnapshot(**_status_fields(result))


def _serialized(method):
    """Serialize one public session operation against all the others.

    FastAPI runs sync handlers in a threadpool, and the GUI polls STATUS and
    READ_CPU on timers while user actions run, so the session IS used from
    several threads. Without this lock the state machine has check-then-act
    races (a concurrent load/start can land their state writes out of order)
    and the transport sees interleaved requests; ``fuzz_server`` reproduces
    both. An RLock because ``connect`` re-enters through ``process_events``.
    """

    @functools.wraps(method)
    def wrapper(self, *args, **kwargs):
        with self._lock:
            return method(self, *args, **kwargs)

    return wrapper


class ControllerSession:
    """Owns one connected bridge session and the load/run/dump state machine."""

    def __init__(
        self, transport_factory: Callable[[], TransportLike], *, clock=None
    ) -> None:
        self._lock = threading.RLock()
        self._transport_factory = transport_factory
        self._transport: TransportLike | None = None
        self._clock = clock
        self.state = SessionState.DISCONNECTED
        self.session_id = 0
        self.negotiated_sclk_hz: int | None = None
        self.last_status: StatusSnapshot | None = None
        self.last_fault: dict | None = None
        self._loaded = False
        self._has_run = False
        self._run = False
        self._faults = 0

    # ---- connection --------------------------------------------------------
    @_serialized
    def connect(self) -> None:
        if self.state != SessionState.DISCONNECTED:
            raise SessionStateError(
                f"connect requires DISCONNECTED (state is {self.state})"
            )
        transport = self._transport_factory()
        try:
            hello = transport.request("hello")
        except T.TransportError as exc:
            transport.close()
            raise SessionError(f"hello failed: {exc}") from exc
        if hello.get("protocol_version") != T.PROTOCOL_VERSION:
            transport.close()
            raise SessionError(
                f"bridge protocol version {hello.get('protocol_version')!r} "
                f"is not {T.PROTOCOL_VERSION}"
            )
        cap = hello.get("sclk_hz_max")
        if not isinstance(cap, int) or cap <= 0:
            transport.close()
            raise SessionError(f"hello did not report a valid SCLK cap: {cap!r}")
        try:
            transport.request("prepare")
        except T.TransportError as exc:
            transport.close()
            raise SessionError(f"prepare failed: {exc}") from exc
        self._transport = transport
        self.session_id += 1
        self.negotiated_sclk_hz = cap
        self.state = SessionState.PREPARED
        self._loaded = False
        self._has_run = False
        self._run = False
        self._faults = 0
        self.process_events()  # consume handshake events (board.reset)

    @_serialized
    def disconnect(self) -> None:
        if self._transport is not None:
            self._transport.close()
        self._transport = None
        self.negotiated_sclk_hz = None
        self.state = SessionState.DISCONNECTED

    @_serialized
    def negotiate_sclk(self, hz: int) -> int:
        if hz <= 0:
            raise SessionError(f"requested SCLK {hz} Hz is not positive")
        if self.negotiated_sclk_hz is None:
            raise SessionStateError("no negotiated SCLK cap; connect first")
        if hz > self.negotiated_sclk_hz:
            raise SessionError(
                f"requested SCLK {hz} Hz exceeds the negotiated cap "
                f"{self.negotiated_sclk_hz} Hz"
            )
        return _require_int(hz, "requested SCLK")

    # ---- load / run / stop -------------------------------------------------
    def load(self, image) -> LoadResult:
        self._require_connected()
        if self.state not in (
            SessionState.PREPARED,
            SessionState.LOADED,
            SessionState.STOPPED,
        ):
            raise SessionStateError(
                f"load requires a stopped session (state is {self.state})"
            )
        previous = self.state
        self.state = SessionState.LOADING
        try:
            result = self._request(
                "load",
                {
                    "words": [int(word) for word in image.words],
                    "sha256": image.sha256,
                    "target": P.TARGET_HOST,
                },
            )
        except SessionError:
            # A transport/integrity failure mid-load must not leave the
            # session stuck in LOADING, where every later load is refused
            # until a reconnect (fuzz_server: state/stuck-loading). A timeout
            # has already latched the session FAULTED on purpose - keep that
            # sticky state; only a state the failed request left behind is
            # restored.
            if self.state is SessionState.LOADING:
                self.state = previous
            raise
        status = _result_int(result, "status", -1)
        faults = _result_int(result, "faults", 0)
        words_written = _result_int(result, "words_written", 0)
        echo = _result_int(result, "echo", 0)
        target = _result_int(result, "target", P.TARGET_HOST)
        self._faults = faults
        if faults:
            self.state = SessionState.FAULTED
            return LoadResult(
                words_written=words_written, faults=faults, echo=echo, target=target
            )
        if status != P.STATUS_OK:
            self.state = SessionState.STOPPED if self._loaded else SessionState.PREPARED
            raise SessionError(f"load failed with status {status}")
        expected_echo = _require_int(image.words[-1], "image word") \
            if image.word_count else 0
        if words_written != image.word_count or echo != expected_echo:
            self._integrity_fault(
                "load response does not match the image: "
                f"{words_written} words (want {image.word_count}), "
                f"echo 0x{echo:04X} (want 0x{expected_echo:04X})"
            )
        self._loaded = True
        self.state = SessionState.LOADED
        return LoadResult(
            words_written=words_written, faults=faults, echo=echo, target=target
        )

    @_serialized
    def start(self) -> None:
        self._require_connected()
        if not self._loaded:
            raise SessionStateError("start requires a successful load")
        if self.state not in (SessionState.LOADED, SessionState.STOPPED):
            raise SessionStateError(
                f"start requires a loaded, stopped session (state is {self.state})"
            )
        result = self._request("start")
        if not result.get("run"):
            raise SessionError("start response did not report run=1")
        self._run = True
        self._has_run = True
        self.state = SessionState.RUNNING

    @_serialized
    def stop(self) -> None:
        self._require_connected()
        if self.state != SessionState.RUNNING:
            raise SessionStateError(
                f"stop requires a running session (state is {self.state})"
            )
        self._request("stop")
        self._run = False
        self.state = SessionState.STOPPED

    @_serialized
    def status(self) -> StatusSnapshot:
        self._require_connected()
        snapshot = _snapshot(self._request("status"))
        self.last_status = snapshot
        self._faults = snapshot.faults
        if snapshot.faults:
            self.state = SessionState.FAULTED
            if self.last_fault is None:
                self.last_fault = {
                    "event": "chip.irq",
                    "data": {"faults": snapshot.faults},
                }
        elif snapshot.run:
            self._run = True
            self._has_run = True
            self.state = SessionState.RUNNING
        else:
            self._run = False
            if self._loaded:
                self.state = (
                    SessionState.STOPPED if self._has_run else SessionState.LOADED
                )
            else:
                self.state = SessionState.PREPARED
        return snapshot

    # ---- stopped-only reads ------------------------------------------------
    def read_cpu(self) -> CpuSnapshot:
        """READ_CPU is the one *non-halting* read: it answers while run=1.

        It requires a connected session but not a stopped core (plan Task 3 /
        review P16: STATUS and READ_CPU are non-halting).
        """
        self._require_connected()
        result = self._request("read_cpu")
        status = _result_int(result, "status", -1)
        if status != P.STATUS_OK:
            raise SessionError(f"read_cpu failed with status {status}")
        return CpuSnapshot(
            pc=_result_int(result, "pc", 0),
            a=_result_int(result, "a", 0),
            x=_result_int(result, "x", 0),
            y=_result_int(result, "y", 0),
            insn=_result_int(result, "insn", 0),
            state=_result_int(result, "state", 0),
        )

    @_serialized
    def dump_core(self) -> CoreDump:
        self._require_stopped_read("dump_core")
        return CoreDump(**_status_fields(self._request("dump_core")))

    @_serialized
    def read_imem(self, address: int, count: int) -> tuple[int, ...]:
        self._require_stopped_read("read_imem")
        result = self._request(
            "read_imem", {"address": _require_int(address, "address"),
                          "count": _require_int(count, "count")}
        )
        status = _result_int(result, "status", -1)
        if status != P.STATUS_OK:
            raise SessionError(f"read_imem failed with status {status}")
        return tuple(_result_int_list(result, "words"))

    @_serialized
    def read_dmem(self, address: int, count: int) -> bytes:
        self._require_stopped_read("read_dmem")
        result = self._request(
            "read_dmem", {"address": _require_int(address, "address"),
                          "count": _require_int(count, "count")}
        )
        status = _result_int(result, "status", -1)
        if status != P.STATUS_OK:
            raise SessionError(f"read_dmem failed with status {status}")
        return bytes(_result_int_list(result, "bytes"))

    # ---- R3 debug control --------------------------------------------------
    # The chip's contract, not a host convention: a free-running core refuses a
    # step with NOT_READY, the hold is released ONLY by DEBUG_BP_CLR (which
    # also disarms), and with run=0 that release falls to the boot stop with
    # the PC re-zeroed. `release_breakpoint` exists because "continue with the
    # breakpoint still armed" is the recipe the contract spells out --
    # step, then clear, then re-arm -- and a host that hid that would leave
    # the operator stuck on a held core.
    def _debug_state_from(self, prefix: DebugPrefix) -> None:
        """Map the chip's state word onto the session state machine.

        Only the STATE is taken from the prefix. The run strap deliberately is
        NOT inferred from it: a hit can latch with the strap high (a live core
        stopped) or low (a step landed on the breakpoint), and DEBUG_HOLD is
        likewise compatible with both, so the state word cannot say which. The
        strap is known for certain from `start`/`stop` and from DEBUG_STATUS,
        which reports it explicitly; guessing it here would put a wrong value
        into the state machine that the GUI then renders.
        """
        if prefix.state == DEBUG_BP_HIT:
            self.state = SessionState.BP_HIT
        elif prefix.state == DEBUG_HOLD:
            self.state = SessionState.DEBUG_HOLD
        elif prefix.state == DEBUG_RUNNING:
            self.state = SessionState.RUNNING
        elif self.state in (SessionState.DEBUG_HOLD, SessionState.BP_HIT):
            self.state = (SessionState.STOPPED if self._loaded
                          else SessionState.PREPARED)

    @_serialized
    def debug_status(self) -> DebugSnapshot:
        """DEBUG_STATUS: the debug readback, answered while running or held."""
        self._require_connected()
        result = self._request("debug_status")
        prefix = _debug_prefix(result, "debug_status")
        _require_ok(prefix, "debug_status")
        # `asdict`, not `**prefix`: the prefix is a dataclass, and a subclass
        # takes the base fields by name.
        snapshot = DebugSnapshot(
            **asdict(prefix),
            run=_result_int(result, "run", 0),
            a=_result_int(result, "a", 0),
            x=_result_int(result, "x", 0),
            y=_result_int(result, "y", 0),
            insn=_result_int(result, "insn", 0),
        )
        self._debug_state_from(snapshot)
        # DEBUG_STATUS is the one debug op that reports the strap, so it is the
        # authority for it.
        self._run = bool(snapshot.run)
        if not snapshot.run and self.state == SessionState.RUNNING:
            self.state = (SessionState.STOPPED if self._loaded
                          else SessionState.PREPARED)
        return snapshot

    @_serialized
    def debug_step(self) -> StepResult:
        """Execute exactly one instruction; the core stays in a debug hold."""
        self._require_connected()
        if self.state == SessionState.RUNNING:
            raise SessionStateError(
                "a free-running core cannot be stepped; DEBUG_BP_CLR releases "
                "the hold first (and disarms the breakpoint)")
        result = self._request("debug_step")
        prefix = _debug_prefix(result, "debug_step")
        _require_ok(prefix, "debug_step")
        step = StepResult(**asdict(prefix),
                          pc_next=_result_int(result, "pc_next", 0))
        self._debug_state_from(step)
        return step

    @_serialized
    def bp_set(self, address: int) -> DebugPrefix:
        """Arm the one breakpoint. Allowed while running (it stops the core)."""
        self._require_connected()
        result = self._request("bp_set",
                              {"address": _require_int(address, "address")})
        prefix = _debug_prefix(result, "bp_set")
        _require_ok(prefix, "bp_set")
        return prefix

    @_serialized
    def bp_clr(self) -> DebugPrefix:
        """Disarm AND release the hold: the only way off a held core.

        With run=1 the core resumes; with run=0 the core falls to the normal
        boot stop and the PC re-zeroes. The breakpoint is disarmed either way,
        so continuing with it armed means step -> clear -> re-arm.
        """
        self._require_connected()
        result = self._request("bp_clr")
        prefix = _debug_prefix(result, "bp_clr")
        _require_ok(prefix, "bp_clr")
        self._debug_state_from(prefix)
        return prefix

    @_serialized
    def resume_with_breakpoint(self, address: int) -> None:
        """Continue while keeping a breakpoint armed: step, clear, re-arm.

        The contract's recipe, exposed as one call so the GUI cannot leave the
        core held: step off the breakpoint (which clears the hit), clear to
        release, then re-arm while it runs.
        """
        if self.state == SessionState.BP_HIT:
            self.debug_step()
        self.bp_clr()
        self.bp_set(address)

    # ---- faults and events -------------------------------------------------
    @_serialized
    def clear_fault(self, mask: int = 0xFFFF) -> int:
        self._require_connected()
        result = self._request("clear_fault", {"mask": _require_int(mask, "mask")})
        self._faults = _result_int(result, "faults", 0)
        if self._faults == 0 and self.state == SessionState.FAULTED:
            self.state = SessionState.STOPPED if self._loaded else SessionState.PREPARED
        return self._faults

    @_serialized
    def process_events(self) -> list[dict]:
        """Apply queued bridge events to the state machine; return them."""
        if self._transport is None:
            return []
        events = self._transport.poll_events()
        for event in events:
            name = event.get("event")
            if name == "usb.disconnect":
                self._transport = None
                self.negotiated_sclk_hz = None
                self._run = False
                self.state = SessionState.DISCONNECTED
            elif name == "board.reset":
                self._run = False
                self._faults = 0
                self._loaded = False
                self._has_run = False
                self.state = SessionState.PREPARED
            elif name == "chip.irq":
                self._faults = _require_int(
                    event.get("data", {}).get("faults", self._faults),
                    "chip.irq faults")
                self.state = SessionState.FAULTED
                self.last_fault = event
            elif name in ("spi.timeout", "protocol.error"):
                self.last_fault = event
        return events

    # ---- internals ---------------------------------------------------------
    def _require_connected(self) -> None:
        if self._transport is None or self.state == SessionState.DISCONNECTED:
            raise SessionStateError("session is not connected")

    def _require_stopped_read(self, what: str) -> None:
        self._require_connected()
        if self.state in (SessionState.LOADING, SessionState.RUNNING) or self._run:
            raise SessionStateError(f"{what} requires the core stopped")

    def _request(
        self, op: str, args: dict | None = None, *, timeout_s: float | None = None
    ) -> dict:
        assert self._transport is not None
        try:
            return self._transport.request(op, args, timeout_s=timeout_s)
        except T.TransportTimeout as exc:
            self.last_fault = {
                "event": "spi.timeout",
                "data": {"op": op, "error": str(exc)},
            }
            self.state = SessionState.FAULTED
            raise SessionError(f"{op} timed out: {exc}") from exc
        except T.TransportError as exc:
            raise SessionError(f"{op} failed: {exc}") from exc

    def _integrity_fault(self, message: str) -> None:
        self._faults |= 0x8000
        self.last_fault = {"event": "protocol.error", "data": {"error": message}}
        self.state = SessionState.FAULTED
        raise SessionError(message)
