"""Tests for tools/host_gui/fake_pe.py — in-memory chip model + fake bridge.

The fake implements the plan's framed protocol with protocol.py and mirrors the
current RTL loader semantics (rtl/pe_ctrl.v):
  * LOAD commits payload words from address 0; words_written/echo are per load;
  * a word queued when `run` rises is aborted, never committed, never echoed,
    and faults the load (the A1 run-abort rule, transferred to the framed
    response: reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md R0);
  * a full 1024-word image commits its final word exactly once (final-word
    echo moved from the superseded uio[4] A1 echo into the LOAD response);
  * LOAD/READ_IMEM/READ_DMEM/DUMP_CORE require run=0; STATUS/READ_CPU do not.
"""

from __future__ import annotations

import json
import unittest

from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P

WORDS = (0x0041, 0x1001, 0x4002)


class TestFakePEFrames(unittest.TestCase):
    def setUp(self):
        self.pe = F.FakePE()

    def test_ping_ok(self):
        self.assertEqual(self.pe.request(P.OP_PING).payload, (P.STATUS_OK,))

    def test_response_echoes_sequence_and_target_with_bit7(self):
        response = self.pe.request(P.OP_PING, sequence=0xABCD, target=0)
        self.assertEqual(response.sequence, 0xABCD)
        self.assertEqual(response.target, 0)
        self.assertTrue(response.is_response)
        self.assertEqual(response.opcode, P.OP_PING | P.RESPONSE_BIT)

    def test_load_commits_words_and_final_word_echo(self):
        response = self.pe.request(P.OP_LOAD, sequence=1, payload_words=WORDS)
        self.assertEqual(response.payload,
                         (P.STATUS_OK, 3, 0, 0x4002))
        self.assertEqual(tuple(self.pe.imem[:3]), WORDS)
        self.assertEqual(self.pe.words_written, 3)
        # Per-word echo content: every committed word is recorded, in order.
        self.assertEqual(tuple(self.pe.committed_words), WORDS)

    def test_full_1024_word_load_echoes_final_word_once(self):
        words = tuple(range(1024))
        response = self.pe.request(P.OP_LOAD, payload_words=words)
        self.assertEqual(response.payload,
                         (P.STATUS_OK, 1024, 0, 1023))
        self.assertEqual(tuple(self.pe.imem), words)
        self.assertEqual(len(self.pe.committed_words), 1024)

    def test_reload_starts_at_zero_and_resets_the_counters(self):
        self.pe.request(P.OP_LOAD, payload_words=(1, 2, 3, 4))
        response = self.pe.request(P.OP_LOAD, payload_words=(9,))
        self.assertEqual(response.payload, (P.STATUS_OK, 1, 0, 9))
        self.assertEqual(self.pe.imem[0], 9)
        self.assertEqual(self.pe.words_written, 1)
        self.assertEqual(tuple(self.pe.committed_words), (9,))

    def test_load_while_running_is_not_ready_and_writes_nothing(self):
        self.pe.run = True
        response = self.pe.request(P.OP_LOAD, payload_words=WORDS)
        self.assertEqual(response.payload, (P.STATUS_NOT_READY, 0, 0, 0))
        self.assertEqual(tuple(self.pe.imem[:3]), (0, 0, 0))
        self.assertEqual(self.pe.faults, 0)

    def test_run_abort_discards_the_queued_word(self):
        self.pe.abort_after_words = 2
        response = self.pe.request(P.OP_LOAD, payload_words=WORDS)
        self.assertEqual(response.payload,
                         (P.STATUS_FAULT, 2, F.FAULT_LOAD, WORDS[1]))
        self.assertEqual(tuple(self.pe.committed_words), WORDS[:2])
        self.assertEqual(self.pe.imem[2], 0)      # aborted word never committed
        self.assertTrue(self.pe.run)              # the abort left run raised

    def test_load_over_1024_words_range_faults_after_1024(self):
        words = tuple(range(1024)) + (0xFFFF,)
        response = self.pe.request(P.OP_LOAD, payload_words=words)
        self.assertEqual(response.payload,
                         (P.STATUS_RANGE, 1024, F.FAULT_RANGE, 1023))
        self.assertEqual(self.pe.imem[1023], 1023)
        self.assertEqual(len(self.pe.committed_words), 1024)

    def test_status_fields_and_non_halting(self):
        self.pe.pc, self.pe.a, self.pe.x, self.pe.y = 5, 6, 7, 8
        self.pe.timer = 9
        self.pe.run = True
        response = self.pe.request(P.OP_STATUS)
        self.assertEqual(response.payload,
                         (P.STATUS_OK, F.STATE_RUNNING, 1, 0, 5, 6, 7, 8, 9, 0, 0))

    def test_read_cpu_is_non_halting(self):
        self.pe.run = True
        self.pe.pc, self.pe.a, self.pe.x, self.pe.y = 1, 2, 3, 4
        self.pe.insn = 0x4002
        response = self.pe.request(P.OP_READ_CPU)
        self.assertEqual(response.payload,
                         (P.STATUS_OK, 1, 2, 3, 4, 0x4002, F.STATE_RUNNING))

    def test_read_imem_round_trip(self):
        self.pe.request(P.OP_LOAD, payload_words=WORDS)
        response = self.pe.request(P.OP_READ_IMEM, payload_words=(1, 2))
        self.assertEqual(response.payload, (P.STATUS_OK, 0x1001, 0x4002))

    def test_read_imem_range_is_rejected(self):
        response = self.pe.request(P.OP_READ_IMEM, payload_words=(1020, 8))
        self.assertEqual(response.payload, (P.STATUS_RANGE,))
        self.assertEqual(self.pe.faults & F.FAULT_RANGE, F.FAULT_RANGE)

    def test_read_imem_while_running_is_not_ready(self):
        self.pe.run = True
        response = self.pe.request(P.OP_READ_IMEM, payload_words=(0, 1))
        self.assertEqual(response.payload, (P.STATUS_NOT_READY,))

    def test_read_dmem_packs_bytes_big_endian(self):
        self.pe.dmem[1:5] = b"\x02\x03\x04\x05"
        response = self.pe.request(P.OP_READ_DMEM, payload_words=(1, 4))
        self.assertEqual(response.payload, (P.STATUS_OK, 0x0203, 0x0405))

    def test_read_dmem_odd_count_zero_pads_the_last_word(self):
        self.pe.dmem[1:4] = b"\x02\x03\x04"
        response = self.pe.request(P.OP_READ_DMEM, payload_words=(1, 3))
        self.assertEqual(response.payload, (P.STATUS_OK, 0x0203, 0x0400))

    def test_read_dmem_range_is_rejected(self):
        response = self.pe.request(P.OP_READ_DMEM, payload_words=(15, 4))
        self.assertEqual(response.payload, (P.STATUS_RANGE,))

    def test_dump_core_is_stable_when_stopped(self):
        self.pe.pc, self.pe.a = 11, 22
        first = self.pe.request(P.OP_DUMP_CORE)
        second = self.pe.request(P.OP_DUMP_CORE)
        self.assertEqual(first.payload, second.payload)
        self.assertEqual(first.payload[4], 11)
        self.assertEqual(first.payload[5], 22)

    def test_dump_core_while_running_is_not_ready(self):
        self.pe.run = True
        self.assertEqual(self.pe.request(P.OP_DUMP_CORE).payload,
                         (P.STATUS_NOT_READY,))

    def test_clear_fault_mask(self):
        self.pe.faults = F.FAULT_LOAD | F.FAULT_CRC
        response = self.pe.request(P.OP_CLEAR_FAULT, payload_words=(F.FAULT_LOAD,))
        self.assertEqual(response.payload, (P.STATUS_OK, F.FAULT_CRC))

    def test_clear_all_faults(self):
        self.pe.faults = F.FAULT_LOAD | F.FAULT_RANGE
        response = self.pe.request(P.OP_CLEAR_FAULT, payload_words=(0xFFFF,))
        self.assertEqual(response.payload, (P.STATUS_OK, 0))

    def test_target_selects_host_and_loopback(self):
        self.assertEqual(
            self.pe.request(P.OP_TARGET, payload_words=(0,)).payload,
            (P.STATUS_OK, 0, F.CAP_HOST))
        self.assertEqual(
            self.pe.request(P.OP_TARGET, payload_words=(1,)).payload,
            (P.STATUS_OK, 1, F.CAP_LOOPBACK))

    def test_unknown_target_is_unsupported_without_fault(self):
        response = self.pe.request(P.OP_TARGET, payload_words=(7,))
        self.assertEqual(response.payload, (P.STATUS_UNSUPPORTED,))
        self.assertEqual(self.pe.faults, 0)

    def test_loopback_target_is_deterministic(self):
        ping = self.pe.request(P.OP_PING, target=P.TARGET_LOOPBACK)
        self.assertEqual(ping.payload, (P.STATUS_OK, F.LOOPBACK_ID))
        target = self.pe.request(P.OP_TARGET, target=P.TARGET_LOOPBACK,
                                 payload_words=(1,))
        self.assertEqual(target.payload, (P.STATUS_OK, 1, F.CAP_LOOPBACK))
        unsupported = self.pe.request(P.OP_READ_IMEM, target=P.TARGET_LOOPBACK,
                                      payload_words=(0, 1))
        self.assertEqual(unsupported.payload, (P.STATUS_UNSUPPORTED,))

    def test_unknown_target_routes_to_unsupported(self):
        response = self.pe.request(P.OP_STATUS, target=5)
        self.assertEqual(response.payload, (P.STATUS_UNSUPPORTED,))
        self.assertEqual(self.pe.faults, 0)

    def test_unknown_opcode_is_unsupported(self):
        response = self.pe.request(0x3F)
        self.assertEqual(response.payload, (P.STATUS_UNSUPPORTED,))


class TestFakePEBadFrames(unittest.TestCase):
    def setUp(self):
        self.pe = F.FakePE()

    def test_bad_crc_returns_bad_frame_and_latches_crc_fault(self):
        raw = bytearray(P.encode_frame(P.OP_PING, 3, 0, b""))
        raw[-1] ^= 0x01
        response = P.decode_frame(self.pe.exchange(bytes(raw)))
        self.assertEqual(response.payload, (P.STATUS_BAD_FRAME,))
        self.assertEqual(response.sequence, 3)
        self.assertTrue(self.pe.faults & F.FAULT_CRC)

    def test_bad_version_returns_bad_frame_and_protocol_fault(self):
        header = (2 << 12) | (P.OP_PING << 4) | 0
        words = [P.SYNC, header, 4, 0]
        body = b"".join(w.to_bytes(2, "big") for w in words)
        raw = body + P.crc16_ccitt(body).to_bytes(2, "big")
        response = P.decode_frame(self.pe.exchange(raw))
        self.assertEqual(response.payload, (P.STATUS_BAD_FRAME,))
        self.assertTrue(self.pe.faults & F.FAULT_PROTOCOL)

    def test_bad_length_returns_bad_frame(self):
        header = (P.VERSION << 12) | (P.OP_PING << 4) | 0
        words = [P.SYNC, header, 1, 7]          # declares 7 payload words
        body = b"".join(w.to_bytes(2, "big") for w in words)
        raw = body + P.crc16_ccitt(body).to_bytes(2, "big")
        self.assertEqual(
            P.decode_frame(self.pe.exchange(raw)).payload,
            (P.STATUS_BAD_FRAME,))

    def test_bad_sync_gets_no_response(self):
        self.assertIsNone(self.pe.exchange(bytes.fromhex("00000000000000000000")))


class TestFakeBridge(unittest.TestCase):
    def setUp(self):
        self.bridge = F.FakeBridge()

    def _request(self, request_id: int, op: str, args: dict | None = None):
        line = json.dumps({"v": 1, "id": request_id, "op": op, "args": args or {}})
        replies = [json.loads(r) for r in self.bridge.handle_line(line)]
        response = replies[-1]
        self.assertEqual(response["id"], request_id)
        self.assertTrue(response["ok"], response)
        return response["result"], replies[:-1]

    def test_hello_reports_version_clock_cap_and_plan_pads(self):
        result, _ = self._request(1, "hello")
        self.assertEqual(result["protocol_version"], 1)
        self.assertEqual(result["clock_hz"], 60_000_000)
        self.assertEqual(result["sclk_hz_max"], 5_000_000)
        self.assertEqual(result["pads"],
                         {"cs_n": 4, "mosi": 5, "miso": 6, "sck": 7})

    def test_prepare_emits_board_reset(self):
        _, events = self._request(1, "prepare")
        self.assertEqual([e["event"] for e in events], ["board.reset"])

    def test_load_result_matches_framed_contract(self):
        result, _ = self._request(2, "load", {"words": list(WORDS)})
        self.assertEqual(result["status"], P.STATUS_OK)
        self.assertEqual(result["words_written"], 3)
        self.assertEqual(result["faults"], 0)
        self.assertEqual(result["echo"], 0x4002)

    def test_load_forces_run_low(self):
        self._request(1, "start")
        result, _ = self._request(2, "load", {"words": [0x0041]})
        self.assertEqual(result["status"], P.STATUS_OK)
        self.assertFalse(self.bridge.pe.run)

    def test_start_then_stop_updates_run_and_emits_status(self):
        result, events = self._request(1, "start")
        self.assertTrue(result["run"])
        self.assertEqual(self.bridge.pe.run, True)
        self.assertIn("chip.status", [e["event"] for e in events])
        result, _ = self._request(2, "stop")
        self.assertFalse(result["run"])

    def test_irq_event_fires_once_per_new_fault_bits(self):
        self.bridge.pe.abort_after_words = 1
        _, first_events = self._request(1, "load", {"words": list(WORDS)})
        self.assertIn("chip.irq", [e["event"] for e in first_events])
        _, second_events = self._request(2, "status")
        self.assertNotIn("chip.irq", [e["event"] for e in second_events])
        self.assertNotEqual(self.bridge.pe.faults, 0)

    def test_status_does_not_clear_a_fault(self):
        self.bridge.pe.faults = F.FAULT_LOAD
        result, events = self._request(1, "status")
        self.assertEqual(result["faults"], F.FAULT_LOAD)
        self.assertEqual(self.bridge.pe.faults, F.FAULT_LOAD)
        self.assertIn("chip.irq", [e["event"] for e in events])

    def test_read_imem_returns_words(self):
        self._request(1, "load", {"words": list(WORDS)})
        result, _ = self._request(2, "read_imem", {"address": 1, "count": 2})
        self.assertEqual(result["words"], [0x1001, 0x4002])
        self.assertEqual(result["address"], 1)

    def test_read_dmem_returns_bytes(self):
        self.bridge.pe.dmem[0:3] = b"\x0a\x0b\x0c"
        result, _ = self._request(1, "read_dmem", {"address": 0, "count": 3})
        self.assertEqual(result["bytes"], [0x0A, 0x0B, 0x0C])

    def test_dump_core_returns_register_header(self):
        result, _ = self._request(1, "dump_core")
        for key in ("state", "run", "target", "pc", "a", "x", "y", "timer",
                    "faults", "words_written"):
            self.assertIn(key, result)

    def test_clear_fault_reports_remaining_bits(self):
        self.bridge.pe.faults = F.FAULT_LOAD | F.FAULT_CRC
        result, _ = self._request(1, "clear_fault", {"mask": F.FAULT_LOAD})
        self.assertEqual(result["faults"], F.FAULT_CRC)

    def test_target_reports_capabilities(self):
        result, _ = self._request(1, "target", {"target": 1})
        self.assertEqual(result["target"], 1)
        self.assertEqual(result["capabilities"], F.CAP_LOOPBACK)

    def test_malformed_line_emits_protocol_error_without_dying(self):
        replies = [json.loads(r) for r in self.bridge.handle_line("nonsense")]
        self.assertEqual(replies[0]["event"], "protocol.error")
        # The bridge still answers the next well-formed request.
        result, _ = self._request(1, "ping")
        self.assertEqual(result["status"], P.STATUS_OK)

    def test_unknown_op_is_an_error_response(self):
        line = json.dumps({"v": 1, "id": 9, "op": "warp", "args": {}})
        replies = [json.loads(r) for r in self.bridge.handle_line(line)]
        self.assertFalse(replies[-1]["ok"])
        self.assertIn("warp", replies[-1]["error"])

    def test_ping_result(self):
        result, _ = self._request(1, "ping")
        self.assertEqual(result["status"], P.STATUS_OK)


if __name__ == "__main__":
    unittest.main(verbosity=2)
