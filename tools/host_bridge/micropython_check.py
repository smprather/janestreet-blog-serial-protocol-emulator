"""MicroPython conformance check for the deployed bridge modules.

Runs the SAME checks on CPython and on the MicroPython unix port, so the
bridge's MicroPython compatibility is measured, not assumed. Landmarks this
file checks (MicroPython has no `__future__` module, so the deployed modules
must not use it):

  * every deployed module imports on a bare MicroPython (a
    `from __future__ import annotations` line kills the deployment at the
    first import);
  * `collections.deque`, `collections.namedtuple`, `json`, `time` exist;
  * annotations must not break at def time (MicroPython evaluates them unless
    it honours PEP 563);
  * the whole 1024-word LOAD transaction must fit on a device heap - the
    unix port reports the live `gc.mem_free()` delta, which is the number to
    compare against the Pico's 264 KB SRAM.

Usage:
    python3 tools/host_bridge/micropython_check.py
    /path/to/micropython tools/host_bridge/micropython_check.py

Exit: 0 = all checks pass on this interpreter, 1 = a check failed.
"""

import gc
import json
import os
import sys

BRIDGE_DIR = os.getcwd() + "/tools/host_bridge"
GOLDEN = BRIDGE_DIR + "/tests/golden_vectors.json"

# Flat deployment layout: the Pico filesystem holds these three files side by
# side, so the bridge must import them flat (its own ImportError fallback).
if BRIDGE_DIR not in sys.path:
    sys.path.insert(0, BRIDGE_DIR)

import main
import pe_frame
import tt_adapter

FAILURES = []


def check(name, ok, detail=""):
    if ok:
        print("  [ok]   {}{}".format(name, (" - " + detail) if detail else ""))
    else:
        print("  [FAIL] {}{}".format(name, (" - " + detail) if detail else ""))
        FAILURES.append(name)


class FakeAdapter:
    """Minimal MicroPython-safe HAL double (no dataclasses, no typing)."""

    def __init__(self, fail=""):
        self.run = False
        self.faults = 0
        self.project_calls = []
        self.clock_calls = []
        self.reset_calls = []
        self.spi_rates = []
        self.transfers = 0
        self.fail = fail

    def enable_project(self, name):
        if self.fail == "enable_project":
            raise RuntimeError(f"project {name!r} not found on this shuttle")
        self.project_calls.append(name)

    def set_clock(self, hz):
        if self.fail == "set_clock":
            raise OSError("clock_project_PWM failed")
        self.clock_calls.append(hz)
        return hz

    def stop_clock(self):
        raise AssertionError("the bridge must never stop the project clock")

    def reset(self, active):
        self.reset_calls.append(active)

    def set_run(self, active):
        self.run = bool(active)

    def configure_host_spi(self, sclk_hz):
        if self.fail == "configure_host_spi":
            raise RuntimeError("host SPI pin map is not configured")
        self.spi_rates.append(sclk_hz)

    def host_spi_transfer(self, data):
        if self.fail == "spi":
            raise OSError("no MISO")
        self.transfers += 1
        frame = pe_frame.decode_frame(data)
        if frame.opcode & pe_frame.RESPONSE_BIT:
            raise AssertionError("bridge sent a response frame")
        payload = list(frame.payload)
        if frame.opcode == pe_frame.OP_LOAD:
            if self.run:
                status = (pe_frame.STATUS_NOT_READY, 0, self.faults, 0)
            else:
                if len(payload) > 1024:
                    self.faults = self.faults | 0x0004
                    status = (pe_frame.STATUS_RANGE, 0, self.faults, 0)
                else:
                    self.words = payload
                    status = (pe_frame.STATUS_OK, len(payload), self.faults,
                              payload[-1] if payload else 0)
        elif frame.opcode == pe_frame.OP_PING:
            status = (pe_frame.STATUS_OK,)
        elif frame.opcode == pe_frame.OP_READ_IMEM:
            if self.run:
                status = (pe_frame.STATUS_NOT_READY,)
            else:
                address = payload[0]
                count = payload[1]
                if address + count > 1024:
                    self.faults = self.faults | 0x0004
                    status = (pe_frame.STATUS_RANGE,)
                else:
                    status = (pe_frame.STATUS_OK,) + tuple(
                        self.words[address:address + count])
        elif frame.opcode == pe_frame.OP_STATUS:
            status = (pe_frame.STATUS_OK, 1 if self.run else 0, 0, 0,
                      0, 0, 0, 0, 0, self.faults, len(getattr(self, "words", ())))
        elif frame.opcode == pe_frame.OP_DUMP_CORE:
            if self.run:
                status = (pe_frame.STATUS_NOT_READY,)
            else:
                status = (pe_frame.STATUS_OK, 0, 0, 0, 0, 0, 0, 0, 0,
                          self.faults, len(getattr(self, "words", ())))
        elif frame.opcode == pe_frame.OP_CLEAR_FAULT:
            self.faults = 0
            status = (pe_frame.STATUS_OK, 0)
        else:
            status = (pe_frame.STATUS_UNSUPPORTED,)
        return pe_frame.encode_frame(frame.opcode | pe_frame.RESPONSE_BIT,
                                     frame.sequence, frame.target,
                                     pe_frame.words_to_bytes(status))

    def irq_n(self):
        return None


def request(bridge, req_id, op, args=None):
    line = json.dumps({"v": 1, "id": req_id, "op": op, "args": args or {}})
    messages = [json.loads(text) for text in bridge.handle_line(line)]
    return messages[-1], messages[:-1]


def mem_free():
    """Free heap in bytes; MicroPython reports it, CPython does not."""
    reader = getattr(gc, "mem_free", None)
    return reader() if reader else 0


def check_pe_frame():
    print("pe_frame: frame codec")
    check("crc check value 0x29B1",
          pe_frame.crc16_ccitt(b"123456789") == 0x29B1)
    check("crc of empty is 0xFFFF", pe_frame.crc16_ccitt(b"") == 0xFFFF)
    with open(GOLDEN) as handle:
        golden = json.loads(handle.read())
    crc_ok = True
    for entry in golden["crc"]:
        data = bytes.fromhex(entry["data_hex"])
        if pe_frame.crc16_ccitt(data) != int(entry["crc"], 16):
            crc_ok = False
    check(f"shared CRC vectors ({len(golden['crc'])})", crc_ok)
    frame_ok = True
    for entry in golden["frames"]:
        payload = bytes.fromhex(entry["payload_hex"])
        raw = pe_frame.encode_frame(entry["opcode"], entry["sequence"],
                                    entry["target"], payload)
        if raw.hex() != entry["frame_hex"]:
            frame_ok = False
            continue
        decoded = pe_frame.decode_frame(raw)
        if list(decoded.payload) != list(pe_frame.bytes_to_words(payload)):
            frame_ok = False
    check(f"shared frame vectors ({len(golden['frames'])})", frame_ok)
    bad = True
    cases = [
        bytes([0x00, 0x00]) + b"\x00" * 8,      # bad sync
        b"\x00\x00",                              # too short
    ]
    for raw in cases:
        try:
            pe_frame.decode_frame(raw)
            bad = False
        except pe_frame.FrameError:
            pass
    check("malformed frames raise FrameError", bad)


def check_bridge():
    print("main: PicoBridge line protocol and sequencing")
    adapter = FakeAdapter()
    bridge = main.PicoBridge(adapter, project="tt_um_protocol_emulator",
                             sleep=lambda _s: None)
    response, _ = request(bridge, 1, "hello")
    check("hello reports v1 + 5 MHz cap",
          response["ok"] and response["result"]["sclk_hz_max"] == 5000000
          and response["result"]["clock_hz"] == 60000000)
    check("project selected once", adapter.project_calls ==
          ["tt_um_protocol_emulator"])
    check("clock started once, never stopped", adapter.clock_calls ==
          [60000000])
    response, events = request(bridge, 2, "prepare")
    check("prepare holds then releases reset",
          response["ok"] and adapter.reset_calls == [True, False])
    check("prepare configures SPI at the cap", adapter.spi_rates ==
          [5000000])
    check("board.reset event emitted",
          [event["event"] for event in events] == ["board.reset"])
    words = list(range(1024))
    before = mem_free()
    response, _ = request(bridge, 3, "load", {"words": words})
    after = mem_free()
    check("1024-word load acknowledged",
          response["ok"] and response["result"]["status"] == 0
          and response["result"]["words_written"] == 1024
          and response["result"]["echo"] == 1023)
    if before and after:
        used = before - after
        print(f"       heap delta for the 1024-word LOAD: {used} bytes")
        check("1024-word LOAD fits in a 96 KB heap slice (Pico has 264 KB)",
              used < 96 * 1024, f"{used} bytes")
    else:
        print("       heap delta: n/a (interpreter has no gc.mem_free)")
    load_line_len = len(json.dumps({"v": 1, "id": 3, "op": "load",
                                    "args": {"words": words}},
                                   separators=(",", ":")))
    check("the largest legal request line fits under DEFAULT_MAX_LINE",
          load_line_len < main.DEFAULT_MAX_LINE,
          f"line {load_line_len} bytes, bound {main.DEFAULT_MAX_LINE}")
    oversize = "x" * (main.DEFAULT_MAX_LINE + 1)
    messages = [json.loads(text) for text in bridge.handle_line(oversize)]
    check("an oversized line is rejected before parsing",
          messages and messages[0]["event"] == "protocol.error")
    response, _ = request(bridge, 4, "start")
    check("start raises run after a successful load",
          response["ok"] and adapter.run)
    response, _ = request(bridge, 5, "read_imem", {"address": 0, "count": 2})
    check("read while running is NOT_READY and never wraps",
          response["result"]["status"] == pe_frame.STATUS_NOT_READY)
    response, _ = request(bridge, 6, "stop")
    check("stop drops run", response["ok"] and not adapter.run)
    response, _ = request(bridge, 7, "read_imem", {"address": 0, "count": 2})
    check("read when stopped returns ascending words",
          response["result"]["words"] == [0, 1])
    response, _ = request(bridge, 8, "read_imem",
                          {"address": 1023, "count": 2})
    check("past-the-end read is RANGE, no wrap",
          response["result"]["status"] == pe_frame.STATUS_RANGE)
    check("bad read latched sticky FAULT_RANGE", adapter.faults == 0x0004)
    response, _ = request(bridge, 9, "status")
    check("STATUS shows the sticky fault",
          response["result"]["faults"] == 0x0004)
    response, _ = request(bridge, 10, "clear_fault", {"mask": 0x0004})
    check("CLEAR_FAULT clears it",
          response["ok"] and response["result"]["faults"] == 0
          and adapter.faults == 0)
    response, _ = request(bridge, 11, "dump_core")
    check("dump_core returns the register header", response["ok"])
    response, _ = request(bridge, 12, "set_sclk", {"hz": 6000000})
    check("SCLK above the cap is refused",
          not response["ok"] and "cap" in response["error"])
    response, _ = request(bridge, 13, "read_imem", {"address": "x",
                                                   "count": 1})
    check("malformed argument type is a typed error, not a crash",
          not response["ok"] and "integer" in response["error"])
    messages = [json.loads(text) for text in bridge.handle_line("not json")]
    check("malformed line is a protocol.error, bridge survives",
          messages and messages[0]["event"] == "protocol.error")
    response, _ = request(bridge, 14, "ping")
    check("bridge still serves after malformed input", response["ok"])


def check_board_failure():
    print("main: board/deployment failures are typed, not fatal")
    for fail, op, expect in (("enable_project", "hello", "not found"),
                             ("set_clock", "hello", "clock"),
                             ("configure_host_spi", "prepare", "pin map")):
        adapter = FakeAdapter(fail=fail)
        bridge = main.PicoBridge(adapter, project="p", sleep=lambda _s: None)
        if op == "prepare":
            request(bridge, 1, "hello")
        response, _ = request(bridge, 2, op)
        check(f"{fail} failure answers ok=false",
              not response["ok"] and expect in response["error"]
              and "board error" in response["error"])
        response, _ = request(bridge, 3, "ping")
        check(f"bridge survives a {fail} failure", response["ok"] or
              response["error"] != "")


def check_adapter():
    print("tt_adapter: import and deployment guards")
    check("module imports", hasattr(tt_adapter, "TTAdapter"))
    adapter = tt_adapter.TTAdapter()
    try:
        adapter.configure_host_spi(5000000)
        guarded = False
    except RuntimeError:
        guarded = True
    check("no invented default pin map (RuntimeError without pins)", guarded)
    adapter = tt_adapter.TTAdapter(pins={"sck": 2, "mosi": 3, "miso": 4})
    check("irq_n() is None until RTL phase R1 exists",
          adapter.irq_n() is None)


def main_check():
    print("MicroPython conformance: {} ({})".format(sys.implementation.name,
             getattr(sys.implementation, "version", "")))
    check_pe_frame()
    check_bridge()
    check_board_failure()
    check_adapter()
    print()
    if FAILURES:
        print(f"RESULT: FAIL ({len(FAILURES)}) - {', '.join(FAILURES)}")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main_check())
