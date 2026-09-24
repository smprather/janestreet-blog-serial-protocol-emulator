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
from collections.abc import Callable
from dataclasses import dataclass

from tools.host_gui import protocol as P
from tools.host_gui import transport as T

STATUS_KEYS = ("state", "run", "target", "pc", "a", "x", "y", "timer",
               "faults", "words_written")


class SessionState(enum.StrEnum):
    DISCONNECTED = "DISCONNECTED"
    PREPARED = "PREPARED"
    LOADING = "LOADING"
    LOADED = "LOADED"
    RUNNING = "RUNNING"
    STOPPED = "STOPPED"
    FAULTED = "FAULTED"


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


def _status_fields(result: dict) -> dict[str, int]:
    return {key: int(result.get(key, 0)) for key in STATUS_KEYS}


def _snapshot(result: dict) -> StatusSnapshot:
    return StatusSnapshot(**_status_fields(result))


class ControllerSession:
    """Owns one connected bridge session and the load/run/dump state machine."""

    def __init__(self, transport_factory: Callable[[], T.SerialTransport], *,
                 clock=None) -> None:
        self._transport_factory = transport_factory
        self._transport: T.SerialTransport | None = None
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
    def connect(self) -> None:
        if self.state != SessionState.DISCONNECTED:
            raise SessionStateError(
                f"connect requires DISCONNECTED (state is {self.state})")
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
                f"is not {T.PROTOCOL_VERSION}")
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
        self.process_events()          # consume handshake events (board.reset)

    def disconnect(self) -> None:
        if self._transport is not None:
            self._transport.close()
        self._transport = None
        self.negotiated_sclk_hz = None
        self.state = SessionState.DISCONNECTED

    def negotiate_sclk(self, hz: int) -> int:
        if hz <= 0:
            raise SessionError(f"requested SCLK {hz} Hz is not positive")
        if self.negotiated_sclk_hz is None:
            raise SessionStateError("no negotiated SCLK cap; connect first")
        if hz > self.negotiated_sclk_hz:
            raise SessionError(
                f"requested SCLK {hz} Hz exceeds the negotiated cap "
                f"{self.negotiated_sclk_hz} Hz")
        return int(hz)

    # ---- load / run / stop -------------------------------------------------
    def load(self, image) -> LoadResult:
        self._require_connected()
        if self.state not in (SessionState.PREPARED, SessionState.LOADED,
                              SessionState.STOPPED):
            raise SessionStateError(
                f"load requires a stopped session (state is {self.state})")
        self.state = SessionState.LOADING
        result = self._request("load", {
            "words": [int(word) for word in image.words],
            "sha256": image.sha256,
            "target": P.TARGET_HOST,
        })
        status = int(result.get("status", -1))
        faults = int(result.get("faults", 0))
        words_written = int(result.get("words_written", 0))
        echo = int(result.get("echo", 0))
        target = int(result.get("target", P.TARGET_HOST))
        self._faults = faults
        if faults:
            self.state = SessionState.FAULTED
            return LoadResult(words_written=words_written, faults=faults,
                              echo=echo, target=target)
        if status != P.STATUS_OK:
            self.state = (SessionState.STOPPED if self._loaded
                          else SessionState.PREPARED)
            raise SessionError(f"load failed with status {status}")
        expected_echo = int(image.words[-1]) if image.word_count else 0
        if words_written != image.word_count or echo != expected_echo:
            self._integrity_fault(
                "load response does not match the image: "
                f"{words_written} words (want {image.word_count}), "
                f"echo 0x{echo:04X} (want 0x{expected_echo:04X})")
        self._loaded = True
        self.state = SessionState.LOADED
        return LoadResult(words_written=words_written, faults=faults,
                          echo=echo, target=target)

    def start(self) -> None:
        self._require_connected()
        if not self._loaded:
            raise SessionStateError("start requires a successful load")
        if self.state not in (SessionState.LOADED, SessionState.STOPPED):
            raise SessionStateError(
                f"start requires a loaded, stopped session (state is {self.state})")
        result = self._request("start")
        if not result.get("run"):
            raise SessionError("start response did not report run=1")
        self._run = True
        self._has_run = True
        self.state = SessionState.RUNNING

    def stop(self) -> None:
        self._require_connected()
        if self.state != SessionState.RUNNING:
            raise SessionStateError(
                f"stop requires a running session (state is {self.state})")
        self._request("stop")
        self._run = False
        self.state = SessionState.STOPPED

    def status(self) -> StatusSnapshot:
        self._require_connected()
        snapshot = _snapshot(self._request("status"))
        self.last_status = snapshot
        self._faults = snapshot.faults
        if snapshot.faults:
            self.state = SessionState.FAULTED
            if self.last_fault is None:
                self.last_fault = {"event": "chip.irq",
                                   "data": {"faults": snapshot.faults}}
        elif snapshot.run:
            self._run = True
            self._has_run = True
            self.state = SessionState.RUNNING
        else:
            self._run = False
            if self._loaded:
                self.state = (SessionState.STOPPED if self._has_run
                              else SessionState.LOADED)
            else:
                self.state = SessionState.PREPARED
        return snapshot

    # ---- stopped-only reads ------------------------------------------------
    def dump_core(self) -> CoreDump:
        self._require_stopped_read("dump_core")
        return CoreDump(**_status_fields(self._request("dump_core")))

    def read_imem(self, address: int, count: int) -> tuple[int, ...]:
        self._require_stopped_read("read_imem")
        result = self._request("read_imem",
                               {"address": int(address), "count": int(count)})
        status = int(result.get("status", -1))
        if status != P.STATUS_OK:
            raise SessionError(f"read_imem failed with status {status}")
        return tuple(int(word) for word in result.get("words", []))

    def read_dmem(self, address: int, count: int) -> bytes:
        self._require_stopped_read("read_dmem")
        result = self._request("read_dmem",
                               {"address": int(address), "count": int(count)})
        status = int(result.get("status", -1))
        if status != P.STATUS_OK:
            raise SessionError(f"read_dmem failed with status {status}")
        return bytes(int(byte) for byte in result.get("bytes", []))

    # ---- faults and events -------------------------------------------------
    def clear_fault(self, mask: int = 0xFFFF) -> int:
        self._require_connected()
        result = self._request("clear_fault", {"mask": int(mask)})
        self._faults = int(result.get("faults", 0))
        if self._faults == 0 and self.state == SessionState.FAULTED:
            self.state = (SessionState.STOPPED if self._loaded
                          else SessionState.PREPARED)
        return self._faults

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
                self._faults = int(event.get("data", {}).get("faults",
                                                             self._faults))
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

    def _request(self, op: str, args: dict | None = None,
                 *, timeout_s: float | None = None) -> dict:
        assert self._transport is not None
        try:
            return self._transport.request(op, args, timeout_s=timeout_s)
        except T.TransportTimeout as exc:
            self.last_fault = {"event": "spi.timeout",
                               "data": {"op": op, "error": str(exc)}}
            self.state = SessionState.FAULTED
            raise SessionError(f"{op} timed out: {exc}") from exc
        except T.TransportError as exc:
            raise SessionError(f"{op} failed: {exc}") from exc

    def _integrity_fault(self, message: str) -> None:
        self._faults |= 0x8000
        self.last_fault = {"event": "protocol.error",
                           "data": {"error": message}}
        self.state = SessionState.FAULTED
        raise SessionError(message)
