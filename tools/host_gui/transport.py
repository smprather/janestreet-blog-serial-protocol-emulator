"""Newline-JSON USB CDC transport for the host controller.

Contract source: wiki/plans/host-controller-gui.md "Host-to-board transport"
and Task 6 Step 2. The bridge speaks one JSON object per line:

    request   {"v": 1, "id": <monotonic int>, "op": <str>, "args": {...}}
    response  {"v": 1, "id": <echoed int>, "ok": <bool>, "result": {...}|null,
               "error": <str>|null}
    event     {"v": 1, "event": <str>, "data": {...}}

Events (USB disconnect, board reset, SPI timeout, PE IRQ, status changes,
protocol faults) are queued while a response is awaited and drained with
``events()``/``poll_events()``.

Dependency discipline: pyserial is optional. The transport accepts any object
with ``readline``/``write``/``flush``/``close`` (a ``LinePort``), so the tests
and the fake-PE loopback never import pyserial; ``open_serial`` lazily imports
it and raises ``MissingDependencyError`` otherwise.

A request that times out is abandoned: its id is remembered so a late response
is discarded rather than delivered to the next request. The transport NEVER
synthesizes a successful result.
"""

from __future__ import annotations

import json
import threading
import time
from collections import deque
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from typing import Protocol

PROTOCOL_VERSION = 1
DEFAULT_BAUDRATE = 115200
DEFAULT_MAX_LINE = 65536


class TransportError(Exception):
    """Base class for transport failures."""


class MissingDependencyError(TransportError):
    """pyserial is required for a real device but is not installed."""


class TransportClosed(TransportError):
    """The serial device went away (USB disconnect)."""


class TransportTimeout(TransportError):
    """No response arrived before the deadline."""


class TransportProtocolError(TransportError):
    """A bridge line violated the newline-JSON contract."""


class BridgeCommandError(TransportError):
    """The bridge answered ``ok=false`` for a request."""

    def __init__(self, op: str, error: str) -> None:
        super().__init__(f"{op}: {error}")
        self.op = op
        self.error = error


class LinePort(Protocol):
    """The subset of pyserial (and the fakes) the transport needs."""

    def readline(self) -> bytes: ...
    def write(self, data: bytes, /) -> object: ...
    def flush(self) -> None: ...
    def close(self) -> None: ...


def open_serial(port: str, baudrate: int = DEFAULT_BAUDRATE) -> LinePort:
    """Open a real CDC device. Raises ``MissingDependencyError`` sans pyserial."""
    try:
        import serial
    except ImportError as exc:  # pragma: no cover - exercised via unittest
        raise MissingDependencyError(
            "pyserial is required to open a serial device; install the "
            "host-gui extra (pip install .[host-gui])") from exc
    return serial.Serial(port, baudrate=baudrate, timeout=0.05)


@dataclass(frozen=True)
class Response:
    id: int
    ok: bool
    result: dict | None
    error: str | None


class SerialTransport:
    """Request/response over a line-oriented serial link, with an event queue."""

    def __init__(self, port: LinePort | str, *, timeout_s: float = 1.0,
                 max_line: int = DEFAULT_MAX_LINE, max_events: int = 256,
                 clock=time.monotonic, sleep=time.sleep) -> None:
        if isinstance(port, str):
            port = open_serial(port)
        self._port = port
        self._timeout_s = float(timeout_s)
        self._max_line = int(max_line)
        self._clock = clock
        self._sleep = sleep
        self._events: deque[dict] = deque(maxlen=int(max_events))
        self._next_id = 1
        self._abandoned: set[int] = set()
        self._closed = False
        # The GUI polls STATUS and READ_CPU on timers while user actions
        # (load/start/stop/dump) run, and FastAPI runs sync handlers in a
        # threadpool - so this transport IS used from several threads. Without
        # this lock two requests interleave on the wire and each can read the
        # other's response (or a poller can steal a just-written reply); the
        # fuzz_server campaign reproduced both. One request owns the wire at a
        # time, including its event draining.
        self._wire_lock = threading.Lock()

    def request(self, op: str, args: Mapping[str, object] | None = None,
                *, timeout_s: float | None = None) -> dict:
        """Send one request and return its result dict.

        Raises ``BridgeCommandError`` for ``ok=false``, ``TransportTimeout`` on
        deadline expiry (never returns a result), ``TransportClosed`` on a
        device error and ``TransportProtocolError`` on malformed lines.
        """
        if self._closed:
            raise TransportClosed("transport is closed")
        with self._wire_lock:
            return self._request_locked(op, args, timeout_s=timeout_s)

    def _request_locked(self, op: str, args: Mapping[str, object] | None,
                        *, timeout_s: float | None) -> dict:
        request_id = self._next_id
        self._next_id += 1
        timeout = self._timeout_s if timeout_s is None else float(timeout_s)
        self._write({"v": PROTOCOL_VERSION, "id": request_id, "op": op,
                     "args": dict(args or {})})
        deadline = self._clock() + timeout
        while True:
            if self._clock() >= deadline:
                self._abandoned.add(request_id)
                raise TransportTimeout(
                    f"{op}: no response within {timeout:g}s")
            line = self._readline()
            if not line:
                self._sleep(0.001)
                continue
            message = self._decode(line)
            if "event" in message:
                self._events.append(message)
                continue
            response = self._to_response(message)
            if response.id in self._abandoned:
                continue                      # late reply to a timed-out request
            if response.id != request_id:
                raise TransportProtocolError(
                    f"response id {response.id} does not match request "
                    f"id {request_id}")
            if not response.ok:
                raise BridgeCommandError(op, response.error or "unknown error")
            return dict(response.result or {})

    def poll_events(self) -> list[dict]:
        """Read any immediately-available lines, drain queued events."""
        with self._wire_lock:
            if not self._closed:
                self._read_available()
            out = list(self._events)
            self._events.clear()
        return out

    def events(self) -> Iterator[dict]:
        """Yield queued asynchronous events (drains the queue)."""
        with self._wire_lock:
            if not self._closed:
                self._read_available()
            out = list(self._events)
            self._events.clear()
        yield from out

    def close(self) -> None:
        with self._wire_lock:
            if self._closed:
                return
            self._closed = True
            try:
                self._port.close()
            except OSError:
                pass

    # ---- internals --------------------------------------------------------
    def _write(self, message: dict) -> None:
        data = json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n"
        try:
            self._port.write(data)
            self._port.flush()
        except OSError as exc:
            self._closed = True
            self._queue_disconnect(str(exc))
            raise TransportClosed(f"USB disconnect on write: {exc}") from exc

    def _readline(self) -> bytes:
        try:
            return self._port.readline()
        except OSError as exc:
            self._closed = True
            self._queue_disconnect(str(exc))
            raise TransportClosed(f"USB disconnect on read: {exc}") from exc

    def _queue_disconnect(self, reason: str) -> None:
        self._events.append({"v": PROTOCOL_VERSION, "event": "usb.disconnect",
                             "data": {"reason": reason}})

    def _read_available(self) -> None:
        """Consume lines already waiting on the port into the event queue.

        A response line with no outstanding request is stale; it is dropped
        rather than delivered to a later request.
        """
        while True:
            try:
                line = self._readline()
            except TransportClosed:
                return          # the usb.disconnect event is already queued
            if not line:
                return
            message = self._decode(line)
            if "event" in message:
                self._events.append(message)

    def _decode(self, line: bytes) -> dict:
        if len(line) > self._max_line:
            raise TransportProtocolError(
                f"bridge line of {len(line)} bytes exceeds max_line "
                f"{self._max_line}")
        try:
            message = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise TransportProtocolError(f"malformed bridge line: {exc}") from exc
        if not isinstance(message, dict):
            raise TransportProtocolError(
                f"bridge line is {type(message).__name__}, not an object")
        if message.get("v") != PROTOCOL_VERSION:
            raise TransportProtocolError(
                f"bridge protocol version {message.get('v')!r} is not "
                f"{PROTOCOL_VERSION}")
        return message

    @staticmethod
    def _to_response(message: dict) -> Response:
        request_id = message.get("id")
        ok = message.get("ok")
        if not isinstance(request_id, int) or not isinstance(ok, bool):
            raise TransportProtocolError(
                f"response without an integer id/bool ok: {message!r}")
        return Response(id=request_id, ok=ok, result=message.get("result"),
                        error=message.get("error"))
