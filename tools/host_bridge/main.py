"""Pico bridge: USB CDC newline-JSON endpoint -> framed PE SPI transactions.

Deployed to the Tiny Tapeout demo board (``main.py`` on the MicroPython
filesystem). The host contract is ``tools/host_gui/transport.py``: one JSON
object per line, versioned requests with monotonic integer ids, id-echoed
responses, and asynchronous event objects. Events emitted here:

    board.reset      prepare held and released reset
    chip.status      after a load/start/stop
    chip.irq         IRQ_N asserted (optional input; absent until RTL phase R1)
    spi.timeout      the PE gave no answer for a framed transaction
    protocol.error   malformed request or a PE response that fails the codec
    usb.disconnect   the read loop hit EOF (best-effort, at exit)

Run sequencing (plan Task 2): RUN is ``ui_in[1]``; the bridge holds it low
through reset/load and raises it only after a successful LOAD response. LOAD
forces RUN low first (the plan's bridge behaviour). Memory reads and DUMP_CORE
are gated on run=0 with ``STATUS_NOT_READY`` and no fault (review section 8);
READ_CPU stays non-halting. The project clock is started at 60 MHz and is
never stopped while the session is connected. The SCLK rate is negotiated from
``hello.sclk_hz_max`` and never exceeds ``min(5 MHz, project_clk / 6)``.

All board access goes through the adapter HAL (see ``tt_adapter.py``), so this
module runs under CPython tests against ``tests/fakes.FakeTTAdapter``.
"""

import json
import sys
import time
from collections import deque

try:                            # package import (CPython tests)
    from . import pe_frame
except ImportError:             # flat MicroPython deployment
    import pe_frame

BRIDGE_VERSION = "pe-bridge-1"
# The Pico has 264 KB of SRAM and the bridge parses every request line whole,
# so this bound is a RAM guard, not just an anti-garbage guard. The largest
# legal request is a full 1024-word LOAD: measured 4,142 bytes as sent by the
# host (json.dumps of {"words": [...]}), whose json.loads costs ~8.4 KB of
# MicroPython heap. 8 KB therefore accepts every legal request with ~2x margin
# and rejects a pathological line before it is parsed. Measured with
# tools/host_bridge/micropython_check.py on the MicroPython 1.30 unix port.
DEFAULT_MAX_LINE = 8192
SCLK_GUARD_HZ = 5_000_000
MAX_EVENT_QUEUE = 16

# Plan mapping (review R0): host SPI is uio[4..7].
PADS = {"cs_n": 4, "mosi": 5, "miso": 6, "sck": 7}

_STATUS_KEYS = ("state", "run", "target", "pc", "a", "x", "y", "timer",
                "faults", "words_written")


class BridgeError(Exception):
    """A request the bridge cannot complete; surfaces as ok=false."""


def _int_arg(args, key, default):
    """Read an integer argument; a non-integer is a clean request error."""
    value = args.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise BridgeError(f"{key} must be an integer")
    return value


class USBRequest:
    __slots__ = ("args", "id", "op", "version")

    def __init__(self, id, op, args=None, version=1):
        self.id = id
        self.op = op
        self.args = dict(args or {})
        self.version = version

    @classmethod
    def from_message(cls, message):
        return cls(message.get("id"), message.get("op"), message.get("args"),
                   message.get("v", 1))


class USBResponse:
    __slots__ = ("error", "id", "ok", "result")

    def __init__(self, id, ok, result=None, error=None):
        self.id = id
        self.ok = bool(ok)
        self.result = result
        self.error = error

    def to_message(self):
        return {"v": 1, "id": self.id, "ok": self.ok, "result": self.result,
                "error": self.error}


class PicoBridge:
    # MicroPython (1.30) does not accept keyword-only parameters (`*,`) in a
    # def, so these stay ordinary defaulted parameters; callers still pass
    # them by name.
    def __init__(self, adapter, project=None, clock_hz=60_000_000,
                 sleep=None, max_line=DEFAULT_MAX_LINE):
        self._adapter = adapter
        self._project = project
        self._clock_hz = int(clock_hz)
        self._sleep = sleep if sleep is not None else time.sleep
        self._max_line = int(max_line)
        # MicroPython's collections.deque has no zero-argument form: it is
        # deque(iterable, maxlen). A bound is also what a 264 KB Pico wants -
        # the queue is drained after every request, so 16 slots is ample and
        # caps the event memory instead of letting it grow.
        self._events = deque([], MAX_EVENT_QUEUE)
        self._sequence = 1
        self._project_enabled = False
        self._clock_started = False
        self._sclk_hz = None
        self._loaded = False
        self._run = False
        self._irq_latched = False
        self._handlers = {
            "hello": self._op_hello,
            "prepare": self._op_prepare,
            "ping": self._op_ping,
            "load": self._op_load,
            "start": self._op_start,
            "stop": self._op_stop,
            "status": self._op_status,
            "read_cpu": self._op_read_cpu,
            "read_imem": self._op_read_imem,
            "read_dmem": self._op_read_dmem,
            "dump_core": self._op_dump_core,
            "clear_fault": self._op_clear_fault,
            "target": self._op_target,
            "debug_step": self._op_debug_step,
            "bp_set": self._op_bp_set,
            "bp_clr": self._op_bp_clr,
            "debug_status": self._op_debug_status,
            "set_sclk": self._op_set_sclk,
        }

    # ---- USB line protocol --------------------------------------------------
    def handle_line(self, line):
        """Consume one request line; return JSON lines (events then response)."""
        if isinstance(line, bytes):
            line = line.decode("utf-8")
        line = line.strip()
        if len(line) > self._max_line:
            return [json.dumps({"v": 1, "event": "protocol.error",
                                "data": {"error": "line exceeds max_line"}},
                               separators=(",", ":"))]
        try:
            message = json.loads(line)
        except ValueError:
            return [json.dumps({"v": 1, "event": "protocol.error",
                                "data": {"error": "malformed JSON"}},
                               separators=(",", ":"))]
        return [json.dumps(m, separators=(",", ":"))
                for m in self.handle_message(message)]

    def handle_message(self, message):
        """Validate one request object; return event dicts + response dict."""
        if (not isinstance(message, dict) or message.get("v") != 1
                or not isinstance(message.get("id"), int)
                or not isinstance(message.get("op"), str)):
            messages = [self._event("protocol.error",
                                    {"error": "malformed request"})]
            request_id = message.get("id") if isinstance(message, dict) else None
            if isinstance(request_id, int):
                messages.append(USBResponse(
                    request_id, False, None, "malformed request").to_message())
            return messages
        args = message.get("args") or {}
        if not isinstance(args, dict):
            return [self._event("protocol.error",
                                {"error": "args must be an object"}),
                    USBResponse(message["id"], False, None,
                                "args must be an object").to_message()]
        response = self.handle(USBRequest.from_message(message))
        # MicroPython's parser rejects starred unpacking inside a list
        # display (`[*events, response]`), so build the list the plain way.
        messages = self.drain_events()
        messages.append(response.to_message())
        return messages

    def handle(self, request):
        """Dispatch one ``USBRequest``; returns a ``USBResponse``."""
        handler = self._handlers.get(request.op)
        if handler is None:
            return USBResponse(request.id, False, None,
                               f"unknown op {request.op!r}")
        try:
            result = handler(request.args)
        except BridgeError as exc:
            return USBResponse(request.id, False, None, str(exc))
        except (OSError, RuntimeError) as exc:
            # A board/deployment failure (unknown project, dead clock, missing
            # pin map, reset/IO error) must not kill the serve loop: answer the
            # request with a typed error and stay alive. SPI transfer failures
            # are already converted to BridgeError + spi.timeout in
            # _pe_request, so they never reach this branch.
            return USBResponse(request.id, False, None,
                               f"board error during {request.op}: {exc}")
        return USBResponse(request.id, True, result, None)

    def serve_io(self, readline, write):
        """Serve request lines until EOF; writes JSON lines via ``write``."""
        while True:
            for event in self.poll_irq():
                self._write_message(write, event)
            line = readline()
            if not line:
                try:
                    self._write_message(write, {"v": 1,
                                                "event": "usb.disconnect",
                                                "data": {}})
                except OSError:
                    pass
                return
            for text in self.handle_line(line):
                write(text if text.endswith("\n") else text + "\n")

    # ---- IRQ ---------------------------------------------------------------
    def poll_irq(self):
        """Return pending ``chip.irq`` events (one per asserted edge)."""
        level = self._adapter.irq_n()
        if level is None:                     # no IRQ input (RTL phase R1)
            return []
        if not level:                         # released: re-arm the edge
            self._irq_latched = False
            return self.drain_events()
        if self._irq_latched:
            return self.drain_events()
        self._irq_latched = True
        try:
            frame = self._pe_request(pe_frame.OP_STATUS)
            result = self._status_result(frame)
            self._event("chip.irq", {"faults": result.get("faults", 0),
                                     "status": result})
        except BridgeError:
            pass                              # error event already queued
        return self.drain_events()

    # ---- request helpers ----------------------------------------------------
    def drain_events(self):
        # MicroPython's deque has no .clear(); popleft-until-empty is the
        # portable form (it is also the documented way to empty one).
        out = list(self._events)
        while self._events:
            self._events.popleft()
        return out

    def _event(self, name, data):
        message = {"v": 1, "event": name, "data": data}
        self._events.append(message)
        return message

    @staticmethod
    def _write_message(write, message):
        write(json.dumps(message, separators=(",", ":")) + "\n")

    def _ensure_clock(self):
        if not self._clock_started:
            actual = self._adapter.set_clock(self._clock_hz)
            if actual:
                self._clock_hz = int(actual)
            self._clock_started = True

    def _sclk_max(self):
        # Plan Global Constraints: min(5 MHz, project_clk / 6), never more.
        return min(SCLK_GUARD_HZ, self._clock_hz // 6)

    # Worst-case words to clock out for an opcode, given its request payload.
    # A bounded read's response carries the data it asked for, so this is
    # computed from the request; every other reply is fixed-size.
    @staticmethod
    def _response_words(opcode, payload_words):
        count = len(payload_words)
        if opcode == pe_frame.OP_READ_IMEM:
            data = payload_words[1] if count > 1 else 0
        elif opcode == pe_frame.OP_READ_DMEM:
            count_bytes = payload_words[1] if count > 1 else 0
            data = (count_bytes + 1) // 2
        else:
            data = 0
        # 6 overhead words (sync, hdr, seq, len, crc, and one slack) + data,
        # plus the 15 worst-case wait words.
        return 6 + data + pe_frame.MAX_WAIT_WORDS

    def _pe_request(self, opcode, payload_words=()):
        sequence = self._sequence
        self._sequence = (self._sequence + 1) & 0xFFFF
        raw = pe_frame.encode_frame(opcode, sequence, pe_frame.TARGET_HOST,
                                    pe_frame.words_to_bytes(payload_words))
        read_words = self._response_words(opcode, payload_words)
        try:
            response = self._adapter.host_spi_transfer(raw, read_words)
        except (OSError, RuntimeError) as exc:
            self._event("spi.timeout", {"opcode": opcode, "error": str(exc)})
            raise BridgeError(f"no PE response: {exc}")
        if not response:
            self._event("spi.timeout", {"opcode": opcode})
            raise BridgeError("no PE response (SPI timeout)")
        try:
            real = pe_frame.strip_wait_words(response)
        except pe_frame.FrameError as exc:
            # Only wait words and no frame: the chip never answered within the
            # bounded wait, so this is a timeout, not a corrupt frame.
            self._event("spi.timeout", {"opcode": opcode, "error": str(exc)})
            raise BridgeError(f"no PE response: {exc}")
        try:
            frame = pe_frame.decode_frame(real)
        except pe_frame.FrameError as exc:
            self._event("protocol.error", {"opcode": opcode, "error": str(exc)})
            raise BridgeError(f"bad PE response: {exc}")
        if not frame.opcode & pe_frame.RESPONSE_BIT:
            self._event("protocol.error", {"opcode": opcode,
                                           "error": "not a response frame"})
            raise BridgeError("PE response is not a response frame")
        return frame

    @staticmethod
    def _load_result(frame):
        payload = frame.payload
        return {"status": payload[0] if len(payload) > 0 else pe_frame.STATUS_BAD_FRAME,
                "words_written": payload[1] if len(payload) > 1 else 0,
                "faults": payload[2] if len(payload) > 2 else 0,
                "echo": payload[3] if len(payload) > 3 else 0,
                "target": frame.target}

    @staticmethod
    def _status_result(frame):
        payload = frame.payload
        result = {"status": payload[0] if payload else pe_frame.STATUS_BAD_FRAME}
        for key, value in zip(_STATUS_KEYS, payload[1:]):
            result[key] = value
        return result

    # ---- operations ----------------------------------------------------------
    def _op_hello(self, args):
        if self._project and not self._project_enabled:
            self._adapter.enable_project(self._project)
            self._project_enabled = True
        self._ensure_clock()                  # start after project selection
        return {"protocol_version": 1, "bridge_version": BRIDGE_VERSION,
                "clock_hz": self._clock_hz, "sclk_hz_max": self._sclk_max(),
                "pads": dict(PADS)}

    def _op_prepare(self, args):
        self._ensure_clock()
        self._adapter.reset(True)
        self._sleep(0.01)
        self._adapter.reset(False)
        self._adapter.set_run(False)
        self._run = False
        self._loaded = False
        self._irq_latched = False
        rate = self._sclk_max()
        self._adapter.configure_host_spi(rate)
        self._sclk_hz = rate
        self._event("board.reset", {})
        return {"state": "PREPARED", "run": False}

    def _op_ping(self, args):
        frame = self._pe_request(pe_frame.OP_PING)
        return {"status": frame.payload[0] if frame.payload
                else pe_frame.STATUS_BAD_FRAME}

    def _op_load(self, args):
        words = args.get("words", [])
        if not isinstance(words, list) or any(
                not isinstance(word, int) or not 0 <= word <= 0xFFFF
                for word in words):
            raise BridgeError("load words must be 16-bit integers")
        self._adapter.set_run(False)          # LOAD forces run=0 (plan)
        self._run = False
        frame = self._pe_request(pe_frame.OP_LOAD, words)
        result = self._load_result(frame)
        self._loaded = (result["status"] == pe_frame.STATUS_OK
                        and result["faults"] == 0)
        self._event("chip.status", dict(result))
        return result

    def _op_start(self, args):
        if not self._loaded:
            raise BridgeError("start requires a successful load response")
        self._adapter.set_run(True)
        self._run = True
        result = {"state": "RUNNING", "run": True}
        self._event("chip.status", dict(result))
        return result

    def _op_stop(self, args):
        self._adapter.set_run(False)
        self._run = False
        result = {"state": "STOPPED", "run": False}
        self._event("chip.status", dict(result))
        return result

    def _op_status(self, args):
        result = self._status_result(self._pe_request(pe_frame.OP_STATUS))
        self._run = bool(result.get("run", 0))
        return result

    def _op_read_cpu(self, args):
        payload = self._pe_request(pe_frame.OP_READ_CPU).payload
        return {"status": payload[0] if payload else pe_frame.STATUS_BAD_FRAME,
                "pc": payload[1] if len(payload) > 1 else 0,
                "a": payload[2] if len(payload) > 2 else 0,
                "x": payload[3] if len(payload) > 3 else 0,
                "y": payload[4] if len(payload) > 4 else 0,
                "insn": payload[5] if len(payload) > 5 else 0,
                "state": payload[6] if len(payload) > 6 else 0}

    def _op_read_imem(self, args):
        address = _int_arg(args, "address", 0)
        count = _int_arg(args, "count", 0)
        if self._run:                         # run=0 gating (review section 8)
            return {"status": pe_frame.STATUS_NOT_READY, "address": address,
                    "words": []}
        frame = self._pe_request(pe_frame.OP_READ_IMEM, (address, count))
        ok = frame.payload and frame.payload[0] == pe_frame.STATUS_OK
        return {"status": frame.payload[0] if frame.payload
                else pe_frame.STATUS_BAD_FRAME,
                "address": address,
                "words": list(frame.payload[1:]) if ok else []}

    def _op_read_dmem(self, args):
        address = _int_arg(args, "address", 0)
        count = _int_arg(args, "count", 0)
        if self._run:
            return {"status": pe_frame.STATUS_NOT_READY, "address": address,
                    "bytes": []}
        frame = self._pe_request(pe_frame.OP_READ_DMEM, (address, count))
        ok = frame.payload and frame.payload[0] == pe_frame.STATUS_OK
        packed = pe_frame.words_to_bytes(frame.payload[1:]) if ok else b""
        return {"status": frame.payload[0] if frame.payload
                else pe_frame.STATUS_BAD_FRAME,
                "address": address,
                "bytes": list(packed[:count]) if ok else []}

    def _op_dump_core(self, args):
        if self._run:
            return {"status": pe_frame.STATUS_NOT_READY}
        return self._status_result(self._pe_request(pe_frame.OP_DUMP_CORE))

    def _op_clear_fault(self, args):
        mask = _int_arg(args, "mask", 0xFFFF)
        frame = self._pe_request(pe_frame.OP_CLEAR_FAULT, (mask,))
        faults = frame.payload[1] if len(frame.payload) > 1 else 0
        if faults == 0:
            self._irq_latched = False
        return {"status": frame.payload[0] if frame.payload
                else pe_frame.STATUS_BAD_FRAME, "faults": faults}

    def _op_target(self, args):
        requested = _int_arg(args, "target", pe_frame.TARGET_HOST)
        frame = self._pe_request(pe_frame.OP_TARGET, (requested,))
        ok = frame.payload and frame.payload[0] == pe_frame.STATUS_OK
        return {"status": frame.payload[0] if frame.payload
                else pe_frame.STATUS_BAD_FRAME,
                "target": frame.payload[1] if ok else requested,
                "capabilities": frame.payload[2] if ok and len(frame.payload) > 2
                else 0}

    def _op_set_sclk(self, args):
        hz = _int_arg(args, "hz", 0)
        cap = self._sclk_max()
        if hz <= 0 or hz > cap:
            raise BridgeError(
                f"requested SCLK {hz} Hz is outside 0..{cap} Hz (negotiated cap)"
                )
        self._adapter.configure_host_spi(hz)
        self._sclk_hz = hz
        return {"sclk_hz": hz, "sclk_hz_max": cap}

    # ---- R3 debug control ---------------------------------------------------
    # These ops speak the DRAFT R3 contract (opcodes 0x21-0x24). The opcode
    # numbers are fixed by the manager dispatch; the response layouts are the
    # host's provisional reading (see tools/host_gui/r3_reads.py) and are NOT
    # chip-confirmed. They are implemented here, on the Pico, so the debug path
    # is not a host-only fiction: on a chip without R3 the PE answers
    # UNSUPPORTED and the host surfaces that verbatim rather than pretending.
    #
    # Note `_op_start` is deliberately left alone. It reports the strap it
    # commanded, because that is all this bridge can know without a second
    # SPI round-trip on every start. Whether a resume that lands on an armed
    # breakpoint traps is the CHIP's call, so the host confirms the real
    # debug state with `debug_status` instead of the bridge guessing it.
    def _op_debug_step(self, args):
        steps = _int_arg(args, "steps", 1)
        frame = self._pe_request(pe_frame.OP_DEBUG_STEP, (steps,))
        payload = frame.payload
        if not payload or payload[0] != pe_frame.STATUS_OK:
            return {"status": payload[0] if payload
                    else pe_frame.STATUS_BAD_FRAME, "steps": 0, "hit": 0}
        return {"status": payload[0], "steps": payload[1], "pc": payload[2],
                "a": payload[3], "x": payload[4], "y": payload[5],
                "insn": payload[6], "hit": payload[7]}

    def _op_bp_set(self, args):
        slot = _int_arg(args, "slot", 0)
        address = _int_arg(args, "address", 0)
        frame = self._pe_request(pe_frame.OP_DEBUG_BP_SET, (slot, address))
        payload = frame.payload
        if not payload or payload[0] != pe_frame.STATUS_OK:
            return {"status": payload[0] if payload
                    else pe_frame.STATUS_BAD_FRAME, "slot": slot,
                    "address": address}
        return {"status": payload[0], "slot": payload[1], "address": payload[2],
                "bp_count": payload[3] if len(payload) > 3 else 0}

    def _op_bp_clr(self, args):
        slot = _int_arg(args, "slot", 0)
        frame = self._pe_request(pe_frame.OP_DEBUG_BP_CLR, (slot,))
        payload = frame.payload
        if not payload or payload[0] != pe_frame.STATUS_OK:
            return {"status": payload[0] if payload
                    else pe_frame.STATUS_BAD_FRAME, "slot": slot}
        return {"status": payload[0], "slot": payload[1],
                "bp_count": payload[2] if len(payload) > 2 else 0}

    def _op_debug_status(self, args):
        payload = self._pe_request(pe_frame.OP_DEBUG_STATUS).payload
        if not payload or payload[0] != pe_frame.STATUS_OK:
            return {"status": payload[0] if payload
                    else pe_frame.STATUS_BAD_FRAME}
        return {"status": payload[0], "debug_state": payload[1],
                "run": payload[2], "pc": payload[3], "a": payload[4],
                "x": payload[5], "y": payload[6], "insn": payload[7],
                "bp_count": payload[8] if len(payload) > 8 else 0,
                "bp_mask": payload[9] if len(payload) > 9 else 0,
                "hit_slot": payload[10] if len(payload) > 10 else 0xFFFF,
                "hit_address": payload[11] if len(payload) > 11 else 0xFFFF}


def run(project=None, clock_hz=60_000_000):
    """Board entry point: serve the USB CDC console as the bridge endpoint."""
    try:                          # package import (CPython)
        from .tt_adapter import TTAdapter
    except ImportError:           # flat MicroPython deployment
        from tt_adapter import TTAdapter
    bridge = PicoBridge(TTAdapter(), project=project, clock_hz=clock_hz)

    def readline():
        return sys.stdin.readline()

    bridge.serve_io(readline, sys.stdout.write)


if __name__ == "__main__":
    run()
