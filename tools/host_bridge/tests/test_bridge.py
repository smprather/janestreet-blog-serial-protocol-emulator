"""Tests for the Pico bridge (plan Task 2).

Run under CPython against the fake-PE chip model and a fake HAL; no board, tt
SDK, pyserial or MicroPython needed. The framed bytes the bridge sends are
decoded with the host-side ``tools.host_gui.protocol`` module and the shared
golden vectors, so the bridge and the host are checked against each other, not
against themselves.
"""

from __future__ import annotations

import json
import unittest
from collections import deque
from pathlib import Path

from tools.host_bridge import main as M
from tools.host_bridge import pe_frame as PF
from tools.host_bridge.tests.fakes import FakeTTAdapter
from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P

GOLDEN = Path(__file__).resolve().parent / "golden_vectors.json"
WORDS = (0x0041, 0x1001, 0x4002)
PROJECT = "tt_um_protocol_emulator"


def make_bridge(*, irq_supported=False, project=PROJECT, max_line=65536):
    pe = F.FakePE()
    adapter = FakeTTAdapter(pe, irq_supported=irq_supported)
    bridge = M.PicoBridge(adapter, project=project, sleep=lambda _seconds: None,
                          max_line=max_line)
    return bridge, adapter, pe


def call(bridge, request_id, op, args=None):
    line = json.dumps({"v": 1, "id": request_id, "op": op, "args": args or {}})
    messages = [json.loads(text) for text in bridge.handle_line(line)]
    return messages[-1], messages[:-1]


class TestPeFrameGoldenVectors(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.golden = json.loads(GOLDEN.read_text(encoding="utf-8"))

    def test_crc_check_value(self):
        self.assertEqual(PF.crc16_ccitt(b"123456789"), 0x29B1)
        self.assertEqual(PF.crc16_ccitt(b""), 0xFFFF)

    def test_crc_vectors_match_the_shared_file(self):
        for entry in self.golden["crc"]:
            with self.subTest(data=entry["data_hex"]):
                data = bytes.fromhex(entry["data_hex"])
                self.assertEqual(PF.crc16_ccitt(data), int(entry["crc"], 16))

    def test_frame_vectors_match_the_shared_file(self):
        for entry in self.golden["frames"]:
            with self.subTest(name=entry["name"]):
                payload = bytes.fromhex(entry["payload_hex"])
                raw = PF.encode_frame(entry["opcode"], entry["sequence"],
                                      entry["target"], payload)
                self.assertEqual(raw.hex(), entry["frame_hex"])
                frame = PF.decode_frame(raw)
                self.assertEqual(frame.version, PF.VERSION)
                self.assertEqual(frame.opcode, entry["opcode"])
                self.assertEqual(frame.sequence, entry["sequence"])
                self.assertEqual(frame.target, entry["target"])
                self.assertEqual(frame.payload, PF.bytes_to_words(payload))

    def test_pe_frame_matches_the_host_protocol_module(self):
        for entry in self.golden["frames"]:
            with self.subTest(name=entry["name"]):
                payload = bytes.fromhex(entry["payload_hex"])
                self.assertEqual(
                    PF.encode_frame(entry["opcode"], entry["sequence"],
                                    entry["target"], payload),
                    P.encode_frame(entry["opcode"], entry["sequence"],
                                   entry["target"], payload))
                host = P.decode_frame(PF.encode_frame(
                    entry["opcode"], entry["sequence"], entry["target"], payload))
                self.assertEqual(host.payload_bytes, payload)

    def test_malformed_frames_are_rejected(self):
        raw = bytearray(PF.encode_frame(P.OP_PING, 1, 0, b""))
        cases = {
            "sync": bytes([raw[0] ^ 1]) + bytes(raw[1:]),
            "crc": bytes(raw[:-1]) + bytes([raw[-1] ^ 1]),
            "short": bytes(raw[:8]),
            "odd": bytes(raw) + b"\x00",
        }
        for name, bad in cases.items():
            with self.subTest(case=name), self.assertRaises(PF.FrameError):
                PF.decode_frame(bad)

    def test_words_helpers_round_trip(self):
        self.assertEqual(PF.bytes_to_words(PF.words_to_bytes(WORDS)), WORDS)


class TestHelloPrepare(unittest.TestCase):
    def test_hello_selects_project_starts_clock_reports_cap(self):
        bridge, adapter, _ = make_bridge()
        response, events = call(bridge, 1, "hello")
        self.assertTrue(response["ok"])
        result = response["result"]
        self.assertEqual(result["protocol_version"], 1)
        self.assertEqual(result["clock_hz"], 60_000_000)
        self.assertEqual(result["sclk_hz_max"], 5_000_000)
        self.assertEqual(result["pads"],
                         {"cs_n": 4, "mosi": 5, "miso": 6, "sck": 7})
        self.assertEqual(adapter.project_calls, [PROJECT])
        self.assertEqual(adapter.clock_calls, [60_000_000])
        self.assertEqual(events, [])

    def test_hello_without_project_skips_selection(self):
        bridge, adapter, _ = make_bridge(project=None)
        response, _ = call(bridge, 1, "hello")
        self.assertTrue(response["ok"])
        self.assertEqual(adapter.project_calls, [])
        self.assertEqual(adapter.clock_calls, [60_000_000])

    def test_prepare_sequence_and_board_reset_event(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        response, events = call(bridge, 2, "prepare")
        self.assertEqual(response["result"], {"state": "PREPARED", "run": False})
        self.assertEqual(adapter.reset_calls, [True, False])
        self.assertEqual(adapter.run_calls, [False])
        self.assertEqual(adapter.spi_rates, [5_000_000])
        self.assertEqual([e["event"] for e in events], ["board.reset"])

    def test_hello_is_idempotent_for_clock_and_project(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "hello")
        call(bridge, 3, "prepare")
        self.assertEqual(adapter.clock_calls, [60_000_000])
        self.assertEqual(adapter.project_calls, [PROJECT])

    def test_clock_is_never_stopped(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        call(bridge, 3, "load", {"words": list(WORDS)})
        call(bridge, 4, "start")
        call(bridge, 5, "stop")
        call(bridge, 6, "status")
        call(bridge, 7, "dump_core")
        self.assertEqual(adapter.clock_stops, 0)
        self.assertEqual(adapter.clock_calls, [60_000_000])
        self.assertEqual(adapter.spi_rates[0], 5_000_000)


class TestLoad(unittest.TestCase):
    def test_load_forces_run_low_before_the_spi_transfer(self):
        bridge, adapter, pe = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        call(bridge, 3, "load", {"words": list(WORDS)})
        call(bridge, 4, "start")
        self.assertTrue(pe.run)
        transfers = len(adapter.transfers)
        response, _ = call(bridge, 5, "load", {"words": list(WORDS)})
        self.assertTrue(response["ok"])
        self.assertFalse(pe.run)
        self.assertEqual(len(adapter.transfers), transfers + 1)
        calls = adapter.calls
        last_run_false = max(i for i, c in enumerate(calls)
                             if c == ("set_run", False))
        last_transfer = max(i for i, c in enumerate(calls)
                            if c[0] == "spi_transfer")
        self.assertLess(last_run_false, last_transfer)

    def test_load_frame_is_the_planned_opcode_and_words(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        call(bridge, 3, "load", {"words": list(WORDS)})
        host_frame = P.decode_frame(adapter.transfers[-1])
        self.assertEqual(host_frame.opcode, P.OP_LOAD)
        self.assertEqual(host_frame.target, P.TARGET_HOST)
        self.assertEqual(host_frame.payload, WORDS)

    def test_load_commits_words_and_reports_echo(self):
        bridge, _, pe = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        response, events = call(bridge, 3, "load", {"words": list(WORDS)})
        result = response["result"]
        self.assertEqual(result["status"], P.STATUS_OK)
        self.assertEqual(result["words_written"], 3)
        self.assertEqual(result["faults"], 0)
        self.assertEqual(result["echo"], 0x4002)
        self.assertEqual(tuple(pe.committed_words), WORDS)
        self.assertIn("chip.status", [e["event"] for e in events])

    def test_full_1024_word_load_echoes_the_final_word(self):
        bridge, _, pe = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        words = list(range(1024))
        response, _ = call(bridge, 3, "load", {"words": words})
        self.assertEqual(response["result"]["words_written"], 1024)
        self.assertEqual(response["result"]["echo"], 1023)
        self.assertEqual(tuple(pe.imem), tuple(words))

    def test_aborted_load_never_marks_loaded(self):
        bridge, adapter, pe = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        pe.abort_after_words = 1
        response, _ = call(bridge, 3, "load", {"words": list(WORDS)})
        self.assertNotEqual(response["result"]["faults"], 0)
        self.assertEqual(tuple(pe.committed_words), WORDS[:1])
        response, _ = call(bridge, 4, "start")
        self.assertFalse(response["ok"])
        self.assertTrue(all(level is False for level in adapter.run_calls))

    def test_load_not_ready_passthrough_has_no_fault(self):
        bridge, adapter, pe = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        adapter.run_lock = True          # the strap cannot be dropped
        pe.run = True
        response, _ = call(bridge, 3, "load", {"words": list(WORDS)})
        result = response["result"]
        self.assertEqual(result["status"], P.STATUS_NOT_READY)
        self.assertEqual(result["faults"], 0)
        self.assertTrue(pe.run)
        response, _ = call(bridge, 4, "start")
        self.assertFalse(response["ok"])   # the rejected load did not mark loaded

    def test_load_rejects_non_integer_words(self):
        bridge, adapter, _ = make_bridge()
        response, _ = call(bridge, 1, "load", {"words": ["x"]})
        self.assertFalse(response["ok"])
        self.assertEqual(adapter.transfers, [])


class TestStartStop(unittest.TestCase):
    def test_start_requires_a_successful_load(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        response, _ = call(bridge, 3, "start")
        self.assertFalse(response["ok"])
        self.assertNotIn(True, adapter.run_calls)

    def test_start_raises_run_only_after_the_load_spi_response(self):
        bridge, adapter, pe = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        call(bridge, 3, "load", {"words": list(WORDS)})
        transfer_index = max(i for i, c in enumerate(adapter.calls)
                             if c[0] == "spi_transfer")
        response, events = call(bridge, 4, "start")
        self.assertTrue(response["ok"])
        run_true_index = adapter.calls.index(("set_run", True))
        self.assertGreater(run_true_index, transfer_index)
        self.assertTrue(pe.run)
        self.assertIn("chip.status", [e["event"] for e in events])

    def test_stop_drops_run(self):
        bridge, adapter, pe = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        call(bridge, 3, "load", {"words": list(WORDS)})
        call(bridge, 4, "start")
        response, _ = call(bridge, 5, "stop")
        self.assertTrue(response["ok"])
        self.assertFalse(pe.run)
        self.assertFalse(adapter.run_calls[-1])


class TestReads(unittest.TestCase):
    def setUp(self):
        self.bridge, self.adapter, self.pe = make_bridge()
        call(self.bridge, 1, "hello")
        call(self.bridge, 2, "prepare")

    def test_status_reads_miso(self):
        self.pe.pc, self.pe.a = 7, 9
        response, _ = call(self.bridge, 3, "status")
        self.assertEqual(response["result"]["pc"], 7)
        self.assertEqual(response["result"]["a"], 9)
        self.assertEqual(len(self.adapter.transfers), 1)

    def test_read_cpu_is_allowed_while_running(self):
        call(self.bridge, 3, "load", {"words": list(WORDS)})
        call(self.bridge, 4, "start")
        self.pe.pc, self.pe.a, self.pe.insn = 2, 3, 0x0041
        response, _ = call(self.bridge, 5, "read_cpu")
        self.assertEqual(response["result"]["pc"], 2)
        self.assertEqual(response["result"]["insn"], 0x0041)
        self.assertTrue(self.pe.run)

    def test_read_imem_and_dmem_when_stopped(self):
        call(self.bridge, 3, "load", {"words": list(WORDS)})
        response, _ = call(self.bridge, 4, "read_imem",
                           {"address": 1, "count": 2})
        self.assertEqual(response["result"]["words"], [0x1001, 0x4002])
        self.pe.dmem[0:3] = b"\x0a\x0b\x0c"
        response, _ = call(self.bridge, 5, "read_dmem",
                           {"address": 0, "count": 3})
        self.assertEqual(response["result"]["bytes"], [0x0A, 0x0B, 0x0C])

    def test_memory_and_dump_are_gated_while_running(self):
        call(self.bridge, 3, "load", {"words": list(WORDS)})
        call(self.bridge, 4, "start")
        transfers = len(self.adapter.transfers)
        for op, args in (("read_imem", {"address": 0, "count": 1}),
                         ("read_dmem", {"address": 0, "count": 1}),
                         ("dump_core", {})):
            with self.subTest(op=op):
                response, _ = call(self.bridge, 5, op, args)
                self.assertEqual(response["result"]["status"],
                                 P.STATUS_NOT_READY)
        self.assertEqual(len(self.adapter.transfers), transfers)
        self.assertTrue(self.pe.run)
        self.assertEqual(self.pe.faults, 0)

    def test_dump_core_header_when_stopped(self):
        call(self.bridge, 3, "load", {"words": list(WORDS)})
        response, _ = call(self.bridge, 4, "dump_core")
        result = response["result"]
        for key in ("state", "run", "target", "pc", "a", "x", "y", "timer",
                    "faults", "words_written"):
            self.assertIn(key, result)
        self.assertEqual(result["words_written"], 3)

    def test_status_does_not_clear_a_fault_and_clear_fault_does(self):
        self.pe.faults = F.FAULT_LOAD
        response, _ = call(self.bridge, 3, "status")
        self.assertEqual(response["result"]["faults"], F.FAULT_LOAD)
        self.assertEqual(self.pe.faults, F.FAULT_LOAD)
        response, _ = call(self.bridge, 4, "clear_fault",
                           {"mask": F.FAULT_LOAD})
        self.assertEqual(response["result"]["faults"], 0)
        self.assertEqual(self.pe.faults, 0)


class TestIrq(unittest.TestCase):
    def test_poll_irq_reads_status_and_fires_once(self):
        bridge, adapter, pe = make_bridge(irq_supported=True)
        call(bridge, 1, "hello")
        pe.faults = F.FAULT_LOAD
        adapter.set_irq(True)
        transfers = len(adapter.transfers)
        events = bridge.poll_irq()
        self.assertEqual([e["event"] for e in events], ["chip.irq"])
        self.assertEqual(events[0]["data"]["faults"], F.FAULT_LOAD)
        self.assertEqual(events[0]["data"]["status"]["faults"], F.FAULT_LOAD)
        self.assertEqual(len(adapter.transfers), transfers + 1)  # STATUS read
        self.assertEqual(bridge.poll_irq(), [])                  # one event only
        self.assertEqual(pe.faults, F.FAULT_LOAD)                # not cleared

    def test_irq_absent_is_a_noop(self):
        bridge, adapter, _ = make_bridge(irq_supported=False)
        call(bridge, 1, "hello")
        self.assertEqual(bridge.poll_irq(), [])
        self.assertEqual(len(adapter.transfers), 0)

    def test_poll_irq_rearms_after_deassert(self):
        bridge, adapter, pe = make_bridge(irq_supported=True)
        call(bridge, 1, "hello")
        pe.faults = F.FAULT_LOAD
        adapter.set_irq(True)
        self.assertEqual(len(bridge.poll_irq()), 1)
        adapter.set_irq(False)
        self.assertEqual(bridge.poll_irq(), [])
        adapter.set_irq(True)
        self.assertEqual(len(bridge.poll_irq()), 1)

    def test_poll_irq_status_failure_emits_timeout_once(self):
        bridge, adapter, _ = make_bridge(irq_supported=True)
        call(bridge, 1, "hello")
        adapter.set_irq(True)
        adapter.fail_transfer = True
        events = bridge.poll_irq()
        self.assertEqual([e["event"] for e in events], ["spi.timeout"])
        self.assertEqual(bridge.poll_irq(), [])


class TestProtocolLines(unittest.TestCase):
    def test_unknown_op_returns_an_error(self):
        bridge, _, _ = make_bridge()
        response, _ = call(bridge, 1, "warp")
        self.assertFalse(response["ok"])
        self.assertIn("warp", response["error"])

    def test_malformed_line_emits_protocol_error_without_dying(self):
        bridge, _, _ = make_bridge()
        messages = [json.loads(t) for t in bridge.handle_line("not json")]
        self.assertEqual(messages[0]["event"], "protocol.error")
        response, _ = call(bridge, 1, "ping")
        self.assertTrue(response["ok"])

    def test_malformed_argument_types_do_not_kill_the_bridge(self):
        bridge, adapter, _ = make_bridge()
        cases = (
            ("set_sclk", {"hz": "abc"}),
            ("read_imem", {"address": "x", "count": 1}),
            ("read_dmem", {"address": 0, "count": "x"}),
            ("clear_fault", {"mask": None}),
            ("target", {"target": "two"}),
        )
        for op, args in cases:
            with self.subTest(op=op):
                response, _ = call(bridge, 1, op, args)
                self.assertFalse(response["ok"])
                self.assertIn("integer", response["error"])
        self.assertEqual(adapter.transfers, [])      # nothing reached the wire
        response, _ = call(bridge, 2, "ping")        # the bridge is still alive
        self.assertTrue(response["ok"])

    def test_oversized_line_is_rejected(self):
        bridge, _, _ = make_bridge(max_line=256)
        messages = [json.loads(t) for t in bridge.handle_line("x" * 300)]
        self.assertEqual(messages[0]["event"], "protocol.error")

    def test_wrong_protocol_version_is_rejected(self):
        bridge, _, _ = make_bridge()
        line = json.dumps({"v": 2, "id": 1, "op": "ping", "args": {}})
        messages = [json.loads(t) for t in bridge.handle_line(line)]
        self.assertEqual(messages[0]["event"], "protocol.error")

    def test_handle_plan_interface(self):
        bridge, _, _ = make_bridge()
        response = bridge.handle(M.USBRequest(id=5, op="ping", args={}))
        self.assertIsInstance(response, M.USBResponse)
        self.assertEqual(response.id, 5)
        self.assertTrue(response.ok)
        self.assertEqual(response.result, {"status": P.STATUS_OK})
        message = response.to_message()
        self.assertEqual(set(message), {"v", "id", "ok", "result", "error"})

    def test_spi_timeout_emits_event_and_error(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        adapter.fail_transfer = True
        response, events = call(bridge, 2, "ping")
        self.assertFalse(response["ok"])
        self.assertEqual([e["event"] for e in events], ["spi.timeout"])

    def test_corrupt_response_emits_protocol_error(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        adapter.corrupt_responses = True
        response, events = call(bridge, 2, "ping")
        self.assertFalse(response["ok"])
        self.assertEqual([e["event"] for e in events], ["protocol.error"])

    def test_serve_io_loop_until_eof_emits_usb_disconnect(self):
        bridge, _, _ = make_bridge()
        lines = deque([
            json.dumps({"v": 1, "id": 1, "op": "hello", "args": {}}) + "\n",
            json.dumps({"v": 1, "id": 2, "op": "ping", "args": {}}) + "\n",
        ])

        def readline():
            return lines.popleft().encode("utf-8") if lines else b""

        written: list[str] = []
        bridge.serve_io(readline, written.append)
        messages = [json.loads(text) for text in written]
        self.assertEqual([m.get("id") for m in messages if "id" in m], [1, 2])
        self.assertEqual(messages[-1]["event"], "usb.disconnect")


class TestSclkNegotiation(unittest.TestCase):
    def test_set_sclk_within_the_cap(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        response, _ = call(bridge, 3, "set_sclk", {"hz": 2_500_000})
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["sclk_hz"], 2_500_000)
        self.assertEqual(adapter.spi_rates, [5_000_000, 2_500_000])

    def test_set_sclk_above_the_cap_is_rejected(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        response, _ = call(bridge, 3, "set_sclk", {"hz": 6_000_000})
        self.assertFalse(response["ok"])
        self.assertEqual(adapter.spi_rates, [5_000_000])

    def test_set_sclk_zero_is_rejected(self):
        bridge, adapter, _ = make_bridge()
        call(bridge, 1, "hello")
        call(bridge, 2, "prepare")
        response, _ = call(bridge, 3, "set_sclk", {"hz": 0})
        self.assertFalse(response["ok"])
        self.assertEqual(adapter.spi_rates, [5_000_000])


class BrokenBoardAdapter(FakeTTAdapter):
    """A deployment-time board failure: unknown project, dead clock, no pin map.

    The phase-2 record noted that these raise out of the serve loop (fail-fast)
    instead of answering the request; the bridge must report them as a typed
    ok=false and stay alive.
    """

    def __init__(self, pe, *, fail=None) -> None:
        super().__init__(pe)
        self.fail = fail

    def enable_project(self, name):
        if self.fail == "enable_project":
            raise RuntimeError(f"project {name!r} not found on this shuttle")
        return super().enable_project(name)

    def set_clock(self, hz):
        if self.fail == "set_clock":
            raise OSError("clock_project_PWM failed")
        return super().set_clock(hz)

    def configure_host_spi(self, sclk_hz):
        if self.fail == "configure_host_spi":
            raise RuntimeError("host SPI pin map is not configured")
        return super().configure_host_spi(sclk_hz)


def board_bridge(fail):
    pe = F.FakePE()
    adapter = BrokenBoardAdapter(pe, fail=fail)
    bridge = M.PicoBridge(adapter, project=PROJECT, sleep=lambda _s: None)
    return bridge, adapter, pe


class TestBoardFailureHandling(unittest.TestCase):
    def test_hello_reports_a_project_failure_instead_of_raising(self):
        bridge, _, _ = board_bridge("enable_project")
        response, _ = call(bridge, 1, "hello")
        self.assertFalse(response["ok"])
        self.assertIn("not found", response["error"])
        self.assertIn("board", response["error"])

    def test_hello_reports_a_clock_failure_instead_of_raising(self):
        bridge, _, _ = board_bridge("set_clock")
        response, _ = call(bridge, 1, "hello")
        self.assertFalse(response["ok"])
        self.assertIn("clock", response["error"])

    def test_prepare_reports_a_pin_map_failure_instead_of_raising(self):
        bridge, _, _ = board_bridge("configure_host_spi")
        response, _ = call(bridge, 1, "hello")
        self.assertTrue(response["ok"])
        response, _ = call(bridge, 2, "prepare")
        self.assertFalse(response["ok"])
        self.assertIn("pin map", response["error"])

    def test_bridge_still_serves_after_a_board_failure(self):
        bridge, _, _ = board_bridge("enable_project")
        call(bridge, 1, "hello")
        response, _ = call(bridge, 2, "ping")
        self.assertTrue(response["ok"])
        messages = [json.loads(t) for t in bridge.handle_line("not json")]
        self.assertEqual(messages[0]["event"], "protocol.error")

    def test_retry_after_the_board_is_fixed_succeeds(self):
        bridge, adapter, _ = board_bridge("enable_project")
        self.assertFalse(call(bridge, 1, "hello")[0]["ok"])
        adapter.fail = None
        response, _ = call(bridge, 2, "hello")
        self.assertTrue(response["ok"])
        self.assertEqual(adapter.project_calls, [PROJECT])
        self.assertEqual(adapter.clock_calls, [60_000_000])

    def test_retry_after_a_clock_failure_starts_the_clock_once(self):
        bridge, adapter, _ = board_bridge("set_clock")
        self.assertFalse(call(bridge, 1, "hello")[0]["ok"])
        adapter.fail = None
        response, _ = call(bridge, 2, "hello")
        self.assertTrue(response["ok"])
        self.assertEqual(adapter.clock_calls, [60_000_000])


if __name__ == "__main__":
    unittest.main(verbosity=2)
