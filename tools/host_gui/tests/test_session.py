"""Tests for tools/host_gui/session.py — controller state machine.

Contract source: wiki/plans/host-controller-gui.md Task 6 Step 3: only load
while stopped, start after a successful load, stop from any running state,
dump only while stopped, preserve the last status and fault across disconnect,
and never reuse request ids or report a timeout as success.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from tools.host_gui import board
from tools.host_gui import fake_pe as F
from tools.host_gui import image as I
from tools.host_gui import protocol as P
from tools.host_gui import session as S
from tools.host_gui import transport as T
from tools.host_gui.tests.fakes import FakeClock, LoopbackPort, StubTransport

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
ECHO = I.assemble_program(FIXTURES / "echo.pe", REPO_ROOT)

HELLO = {"protocol_version": 1, "bridge_version": "test", "clock_hz": 60_000_000,
         "sclk_hz_max": 5_000_000, "pads": dict(board.HOST_SPI_PADS)}
PREPARE = {"state": "PREPARED", "run": False}


def make_stack():
    clock = FakeClock()
    bridge = F.FakeBridge()
    port = LoopbackPort(bridge)
    transport = T.SerialTransport(port, clock=clock, sleep=clock.sleep)
    session = S.ControllerSession(lambda: transport, clock=clock)
    return session, bridge, port, transport


def make_reconnect_stack():
    clock = FakeClock()
    bridge = F.FakeBridge()
    ports = [LoopbackPort(bridge), LoopbackPort(bridge)]
    transports = [T.SerialTransport(p, clock=clock, sleep=clock.sleep)
                  for p in ports]
    pool = list(transports)
    session = S.ControllerSession(lambda: pool.pop(0), clock=clock)
    return session, bridge, ports, transports


def push_event(port, name: str, data: dict | None = None) -> None:
    port.incoming.append(json.dumps(
        {"v": 1, "event": name, "data": data or {}}).encode())


class TestBoardDecisions(unittest.TestCase):
    def test_plan_pad_mapping_wins(self):
        self.assertEqual(board.HOST_SPI_PADS,
                         {"cs_n": 4, "mosi": 5, "miso": 6, "sck": 7})

    def test_host_guard_rate_is_5mhz(self):
        self.assertEqual(board.SCLK_GUARD_HZ, 5_000_000)
        self.assertEqual(board.PE_CLOCK_HZ, 60_000_000)


class TestConnection(unittest.TestCase):
    def test_connect_prepares_and_negotiates_cap(self):
        session, _, _, _ = make_stack()
        self.assertEqual(session.state, S.SessionState.DISCONNECTED)
        session.connect()
        self.assertEqual(session.state, S.SessionState.PREPARED)
        self.assertEqual(session.session_id, 1)
        self.assertEqual(session.negotiated_sclk_hz, 5_000_000)

    def test_connect_twice_is_rejected(self):
        session, _, _, _ = make_stack()
        session.connect()
        with self.assertRaises(S.SessionStateError):
            session.connect()

    def test_reconnect_uses_fresh_request_ids(self):
        session, _, ports, _ = make_reconnect_stack()
        session.connect()
        push_event(ports[0], "usb.disconnect")
        session.process_events()
        self.assertEqual(session.state, S.SessionState.DISCONNECTED)
        session.connect()
        self.assertEqual(session.session_id, 2)
        first = json.loads(ports[1].writes[0].decode().strip())
        self.assertEqual(first["id"], 1)

    def test_hello_version_mismatch_is_rejected(self):
        stub = StubTransport(responses=[{"protocol_version": 99}])
        session = S.ControllerSession(lambda: stub)
        with self.assertRaises(S.SessionError):
            session.connect()

    def test_negotiate_sclk_never_exceeds_cap(self):
        session, _, _, _ = make_stack()
        session.connect()
        self.assertEqual(session.negotiate_sclk(2_500_000), 2_500_000)
        with self.assertRaises(S.SessionError):
            session.negotiate_sclk(5_000_001)


class TestLoadStartStop(unittest.TestCase):
    def test_load_start_stop_flow(self):
        session, bridge, _, _ = make_stack()
        session.connect()
        result = session.load(ECHO)
        self.assertEqual(session.state, S.SessionState.LOADED)
        self.assertEqual(result.words_written, 3)
        self.assertEqual(result.faults, 0)
        self.assertEqual(result.echo, 0x4002)
        self.assertEqual(tuple(bridge.pe.committed_words), ECHO.words)
        session.start()
        self.assertEqual(session.state, S.SessionState.RUNNING)
        self.assertTrue(bridge.pe.run)
        session.stop()
        self.assertEqual(session.state, S.SessionState.STOPPED)
        self.assertFalse(bridge.pe.run)

    def test_load_rejected_while_running(self):
        session, _, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        session.start()
        with self.assertRaises(S.SessionStateError):
            session.load(ECHO)

    def test_start_rejected_before_load(self):
        session, _, _, _ = make_stack()
        session.connect()
        with self.assertRaises(S.SessionStateError):
            session.start()

    def test_stop_rejected_when_not_running(self):
        session, _, _, _ = make_stack()
        session.connect()
        with self.assertRaises(S.SessionStateError):
            session.stop()

    def test_load_timeout_is_not_success(self):
        stub = StubTransport(responses=[HELLO, PREPARE, T.TransportTimeout("slow")])
        session = S.ControllerSession(lambda: stub)
        session.connect()
        with self.assertRaises(S.SessionError):
            session.load(ECHO)
        self.assertNotEqual(session.state, S.SessionState.LOADED)
        self.assertEqual(session.state, S.SessionState.FAULTED)

    def test_echo_mismatch_is_a_fault(self):
        bad = {"status": P.STATUS_OK, "words_written": 3, "faults": 0,
               "echo": 0xBADD}
        stub = StubTransport(responses=[HELLO, PREPARE, bad])
        session = S.ControllerSession(lambda: stub)
        session.connect()
        with self.assertRaises(S.SessionError):
            session.load(ECHO)
        self.assertEqual(session.state, S.SessionState.FAULTED)


class TestReadbackAndDump(unittest.TestCase):
    def test_dump_allowed_when_stopped(self):
        session, _, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        dump = session.dump_core()
        self.assertEqual(dump.pc, 0)
        self.assertEqual(dump.words_written, 3)
        session.start()
        with self.assertRaises(S.SessionStateError):
            session.dump_core()

    def test_read_imem_and_dmem(self):
        session, bridge, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        self.assertEqual(session.read_imem(1, 2), (0x1001, 0x4002))
        bridge.pe.dmem[0:3] = b"\x0a\x0b\x0c"
        self.assertEqual(session.read_dmem(0, 3), b"\x0a\x0b\x0c")

    def test_read_imem_rejected_while_running(self):
        session, _, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        session.start()
        with self.assertRaises(S.SessionStateError):
            session.read_imem(0, 1)

    def test_read_cpu_is_non_halting_while_running(self):
        session, bridge, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        session.start()
        bridge.pe.pc, bridge.pe.a, bridge.pe.x = 5, 6, 7
        bridge.pe.y, bridge.pe.insn = 8, 0x0041
        cpu = session.read_cpu()
        self.assertEqual((cpu.pc, cpu.a, cpu.x, cpu.y, cpu.insn),
                         (5, 6, 7, 8, 0x0041))
        self.assertTrue(bridge.pe.run)          # still running: non-halting
        self.assertEqual(session.state, S.SessionState.RUNNING)

    def test_read_cpu_while_stopped(self):
        session, bridge, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        bridge.pe.pc = 3
        cpu = session.read_cpu()
        self.assertEqual(cpu.pc, 3)
        self.assertFalse(bridge.pe.run)

    def test_read_cpu_requires_a_connected_session(self):
        session, _, _, _ = make_stack()
        with self.assertRaises(S.SessionStateError):
            session.read_cpu()

    def test_read_cpu_full_width_registers(self):
        # Manager RULING: R2 exposes full-width PC/A/X/Y/insn (the old RTL
        # truncated dbg_pc/dbg_a to 8 bits); the host must carry them whole.
        session, bridge, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        bridge.pe.pc, bridge.pe.a, bridge.pe.x = 0x3FF, 0x1FFF, 0x2AA
        bridge.pe.y, bridge.pe.insn = 0x155, 0xFFFF
        cpu = session.read_cpu()
        self.assertEqual((cpu.pc, cpu.a, cpu.x, cpu.y, cpu.insn),
                         (0x3FF, 0x1FFF, 0x2AA, 0x155, 0xFFFF))


class TestFaultsAndEvents(unittest.TestCase):
    def test_fault_sets_faulted_and_survives_disconnect(self):
        session, bridge, port, _ = make_stack()
        session.connect()
        bridge.pe.abort_after_words = 1
        result = session.load(ECHO)
        self.assertNotEqual(result.faults, 0)
        self.assertEqual(session.state, S.SessionState.FAULTED)
        events = session.process_events()
        self.assertIn("chip.irq", [e["event"] for e in events])
        self.assertIsNotNone(session.last_fault)
        session.status()                      # still readable while faulted
        push_event(port, "usb.disconnect")
        session.process_events()
        self.assertEqual(session.state, S.SessionState.DISCONNECTED)
        self.assertIsNotNone(session.last_fault)   # preserved
        self.assertIsNotNone(session.last_status)

    def test_clear_fault_returns_to_stopped(self):
        session, bridge, _, _ = make_stack()
        session.connect()
        session.load(ECHO)                  # a valid image is loaded...
        bridge.pe.faults = F.FAULT_LOAD     # ...then a fault appears
        session.status()                    # observed: FAULTED
        self.assertEqual(session.state, S.SessionState.FAULTED)
        session.clear_fault()
        self.assertEqual(session.state, S.SessionState.STOPPED)

    def test_clear_fault_after_aborted_load_returns_to_prepared(self):
        # An aborted load never became a valid program, so clearing its fault
        # must not leave the session claiming a loaded image.
        session, bridge, _, _ = make_stack()
        session.connect()
        bridge.pe.abort_after_words = 1
        session.load(ECHO)
        self.assertEqual(session.state, S.SessionState.FAULTED)
        session.clear_fault()
        self.assertEqual(session.state, S.SessionState.PREPARED)

    def test_spi_timeout_event_is_processed(self):
        session, _, port, _ = make_stack()
        session.connect()
        push_event(port, "spi.timeout", {"op": "status"})
        events = session.process_events()
        self.assertEqual([e["event"] for e in events], ["spi.timeout"])

    def test_board_reset_event_returns_to_prepared(self):
        session, _, port, _ = make_stack()
        session.connect()
        session.load(ECHO)
        session.start()
        push_event(port, "board.reset")
        session.process_events()
        self.assertEqual(session.state, S.SessionState.PREPARED)


if __name__ == "__main__":
    unittest.main(verbosity=2)
