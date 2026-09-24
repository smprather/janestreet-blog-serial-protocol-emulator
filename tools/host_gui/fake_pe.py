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
from collections.abc import Iterable

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

STATUS_KEYS = ("state", "run", "target", "pc", "a", "x", "y", "timer",
               "faults", "words_written")


class PEFrameError(Exception):
    """The fake PE produced no response (e.g. unframed garbage)."""


class FakeBridgeError(Exception):
    """A bridge request that cannot be dispatched."""


def _payload_bytes(words: Iterable[int]) -> bytes:
    return b"".join(int(w).to_bytes(2, "big") for w in words)


class FakePE:
    """The framed-protocol chip model (no USB/JSON layer)."""

    def __init__(self) -> None:
        self.imem: list[int] = [0] * IMEM_WORDS
        self.dmem = bytearray(DMEM_BYTES)
        self.run = False
        self.pc = self.a = self.x = self.y = self.insn = self.timer = 0
        self.faults = 0
        self.words_written = 0
        self.committed_words: list[int] = []
        self.selected_target = 0
        # Test stimulus for the run-abort window: simulate `run` rising just
        # before word `abort_after_words` would be committed. One-shot.
        self.abort_after_words: int | None = None

    @property
    def state(self) -> int:
        return STATE_RUNNING if self.run else STATE_STOPPED

    # ---- framed interface -------------------------------------------------
    def request(self, opcode: int, sequence: int = 0, target: int = 0,
                payload_words: Iterable[int] = ()) -> P.Frame:
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
            return self._response(opcode, sequence, target,
                                  (P.STATUS_BAD_FRAME,))
        return self._dispatch(frame)

    # ---- dispatch ---------------------------------------------------------
    def _dispatch(self, frame: P.Frame) -> bytes:
        opcode, sequence, target = frame.opcode, frame.sequence, frame.target
        if opcode & P.RESPONSE_BIT:
            return self._response(opcode & ~P.RESPONSE_BIT, sequence, target,
                                  (P.STATUS_UNSUPPORTED,))
        if target == P.TARGET_LOOPBACK:
            return self._loopback(opcode, sequence, target)
        if target != P.TARGET_HOST:
            return self._response(opcode, sequence, target, (P.STATUS_UNSUPPORTED,))
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
        }.get(opcode)
        if handler is None:
            return self._response(opcode, sequence, target,
                                  (P.STATUS_UNSUPPORTED,))
        return self._response(opcode, sequence, target, handler(frame.payload))

    def _loopback(self, opcode: int, sequence: int, target: int) -> bytes:
        if opcode == P.OP_PING:
            payload = (P.STATUS_OK, LOOPBACK_ID)
        elif opcode == P.OP_TARGET:
            payload = (P.STATUS_OK, P.TARGET_LOOPBACK, CAP_LOOPBACK)
        else:
            payload = (P.STATUS_UNSUPPORTED,)
        return self._response(opcode, sequence, target, payload)

    def _response(self, opcode: int, sequence: int, target: int,
                  payload: tuple[int, ...]) -> bytes:
        return P.encode_frame(opcode | P.RESPONSE_BIT, sequence, target,
                              _payload_bytes(payload))

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
            return (P.STATUS_NOT_READY, self.words_written, self.faults,
                    self._echo())
        self.words_written = 0
        self.committed_words = []
        abort_after = self.abort_after_words
        self.abort_after_words = None
        for index, word in enumerate(payload):
            if index >= IMEM_WORDS:
                self.faults |= FAULT_RANGE
                return (P.STATUS_RANGE, self.words_written, self.faults,
                        self._echo())
            if abort_after is not None and index == abort_after:
                self.run = True
                self.faults |= FAULT_LOAD
                return (P.STATUS_FAULT, self.words_written, self.faults,
                        self._echo())
            self.imem[index] = word
            self.committed_words.append(word)
            self.words_written += 1
        return (P.STATUS_OK, self.words_written, self.faults, self._echo())

    def _status(self, payload: tuple[int, ...] = ()) -> tuple[int, ...]:
        return (P.STATUS_OK, self.state, 1 if self.run else 0,
                self.selected_target, self.pc, self.a, self.x, self.y,
                self.timer, self.faults, self.words_written)

    def _read_cpu(self, payload: tuple[int, ...] = ()) -> tuple[int, ...]:
        return (P.STATUS_OK, self.pc, self.a, self.x, self.y, self.insn,
                self.state)

    def _read_imem(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        if self.run:
            return (P.STATUS_NOT_READY,)
        address = int(payload[0]) if payload else 0
        count = int(payload[1]) if len(payload) > 1 else 0
        if address < 0 or count < 0 or address + count > IMEM_WORDS:
            self.faults |= FAULT_RANGE
            return (P.STATUS_RANGE,)
        return (P.STATUS_OK, *self.imem[address:address + count])

    def _read_dmem(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        if self.run:
            return (P.STATUS_NOT_READY,)
        address = int(payload[0]) if payload else 0
        count = int(payload[1]) if len(payload) > 1 else 0
        if address < 0 or count < 0 or address + count > DMEM_BYTES:
            self.faults |= FAULT_RANGE
            return (P.STATUS_RANGE,)
        chunk = bytearray(self.dmem[address:address + count])
        if len(chunk) % 2:
            chunk.append(0)                       # zero-pad the last word
        return (P.STATUS_OK,
                *(int.from_bytes(chunk[i:i + 2], "big")
                  for i in range(0, len(chunk), 2)))

    def _dump_core(self, payload: tuple[int, ...] = ()) -> tuple[int, ...]:
        if self.run:
            return (P.STATUS_NOT_READY,)
        return self._status()

    def _clear_fault(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        mask = int(payload[0]) if payload else 0
        self.faults &= ~mask & 0xFFFF
        return (P.STATUS_OK, self.faults)

    def _target(self, payload: tuple[int, ...]) -> tuple[int, ...]:
        requested = int(payload[0]) if payload else 0
        if requested == P.TARGET_HOST:
            self.selected_target = P.TARGET_HOST
            return (P.STATUS_OK, P.TARGET_HOST, CAP_HOST)
        if requested == P.TARGET_LOOPBACK:
            self.selected_target = P.TARGET_LOOPBACK
            return (P.STATUS_OK, P.TARGET_LOOPBACK, CAP_LOOPBACK)
        return (P.STATUS_UNSUPPORTED,)


class FakeBridge:
    """Newline-JSON USB bridge over ``FakePE`` (the Pico's role)."""

    def __init__(self) -> None:
        self.pe = FakePE()
        self._known_faults = 0
        self._pending_events: deque[dict] = deque()

    # ---- newline-JSON interface -------------------------------------------
    def handle_line(self, line: str) -> list[str]:
        """Consume one request line; return event/response lines in order."""
        try:
            message = json.loads(line)
        except ValueError:
            return [self._event_line("protocol.error",
                                     {"error": "malformed JSON"})]
        if (not isinstance(message, dict) or message.get("v") != 1
                or not isinstance(message.get("id"), int)
                or not isinstance(message.get("op"), str)):
            replies = [self._event_line("protocol.error",
                                        {"error": "malformed request"})]
            request_id = message.get("id") if isinstance(message, dict) else None
            if isinstance(request_id, int):
                replies.append(self._response_line(
                    request_id, False, None, "malformed request"))
            return replies

        request_id = message["id"]
        op = message["op"]
        args = message.get("args") or {}
        if not isinstance(args, dict):
            return [self._event_line("protocol.error",
                                     {"error": "args must be an object"}),
                    self._response_line(request_id, False, None,
                                        "args must be an object")]
        try:
            result = self._dispatch(op, args)
        except FakeBridgeError as exc:
            self._emit_fault_events()
            return [*self._drain_events(),
                    self._response_line(request_id, False, None, str(exc))]
        self._emit_fault_events()
        return [*self._drain_events(),
                self._response_line(request_id, True, result, None)]

    # ---- operations --------------------------------------------------------
    def _dispatch(self, op: str, args: dict) -> dict:
        target = int(args.get("target", P.TARGET_HOST))
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
            self._event("board.reset", {})
            return {"state": "PREPARED", "run": False}
        if op == "ping":
            frame = self.pe.request(P.OP_PING, target=target)
            return {"status": frame.payload[0]}
        if op == "load":
            self.pe.run = False          # LOAD forces run=0 (plan Task 2)
            words = args.get("words", [])
            if not isinstance(words, list) or not all(
                    isinstance(w, int) and 0 <= w <= 0xFFFF for w in words):
                raise FakeBridgeError("load words must be 16-bit integers")
            frame = self.pe.request(P.OP_LOAD, payload_words=words)
            result = {"status": frame.payload[0],
                      "words_written": frame.payload[1],
                      "faults": frame.payload[2],
                      "echo": frame.payload[3],
                      "target": frame.target}
            self._event("chip.status", dict(result))
            return result
        if op == "start":
            self.pe.run = True
            result = {"state": "RUNNING", "run": True}
            self._event("chip.status", dict(result))
            return result
        if op == "stop":
            self.pe.run = False
            result = {"state": "STOPPED", "run": False}
            self._event("chip.status", dict(result))
            return result
        if op == "status":
            return self._status_result(self.pe.request(P.OP_STATUS,
                                                       target=target))
        if op == "dump_core":
            return self._status_result(self.pe.request(P.OP_DUMP_CORE,
                                                       target=target))
        if op == "read_cpu":
            values = self.pe.request(P.OP_READ_CPU, target=target).payload
            return {"status": values[0], "pc": values[1], "a": values[2],
                    "x": values[3], "y": values[4], "insn": values[5],
                    "state": values[6]}
        if op == "read_imem":
            address = int(args.get("address", 0))
            count = int(args.get("count", 0))
            frame = self.pe.request(P.OP_READ_IMEM, target=target,
                                    payload_words=(address, count))
            ok = frame.payload[0] == P.STATUS_OK
            return {"status": frame.payload[0], "address": address,
                    "words": list(frame.payload[1:]) if ok else []}
        if op == "read_dmem":
            address = int(args.get("address", 0))
            count = int(args.get("count", 0))
            frame = self.pe.request(P.OP_READ_DMEM, target=target,
                                    payload_words=(address, count))
            ok = frame.payload[0] == P.STATUS_OK
            packed = _payload_bytes(frame.payload[1:]) if ok else b""
            return {"status": frame.payload[0], "address": address,
                    "bytes": list(packed[:count]) if ok else []}
        if op == "clear_fault":
            mask = int(args.get("mask", 0xFFFF))
            frame = self.pe.request(P.OP_CLEAR_FAULT, target=target,
                                    payload_words=(mask,))
            return {"status": frame.payload[0], "faults": frame.payload[1]}
        if op == "target":
            requested = int(args.get("target", P.TARGET_HOST))
            frame = self.pe.request(P.OP_TARGET, payload_words=(requested,))
            ok = frame.payload[0] == P.STATUS_OK
            return {"status": frame.payload[0],
                    "target": frame.payload[1] if ok else self.pe.selected_target,
                    "capabilities": frame.payload[2] if ok else 0}
        raise FakeBridgeError(f"unknown op {op!r}")

    # ---- helpers -----------------------------------------------------------
    @staticmethod
    def _status_result(frame: P.Frame) -> dict:
        result: dict[str, int] = {
            "status": frame.payload[0] if frame.payload else P.STATUS_BAD_FRAME}
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
            self._event("chip.irq", {"faults": self.pe.faults, "new": new,
                                     "status": status})
        self._known_faults = self.pe.faults

    def _drain_events(self) -> list[str]:
        out = list(self._pending_events)
        self._pending_events.clear()
        return out

    @staticmethod
    def _response_line(request_id: int, ok: bool, result,
                       error: str | None) -> str:
        return json.dumps({"v": 1, "id": request_id, "ok": ok,
                           "result": result, "error": error})

    @staticmethod
    def _event_line(name: str, data: dict) -> str:
        return json.dumps({"v": 1, "event": name, "data": data})
