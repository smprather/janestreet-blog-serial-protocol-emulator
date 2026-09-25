"""Cross-layer integration: the real host stack over the real Pico bridge.

The host phase tests drive a `FakeBridge` and the bridge phase tests drive a
`FakeTTAdapter`, so before this module the two real line-protocol endpoints
had never spoken to each other. This wires `SerialTransport` +
`ControllerSession` (``tools.host_gui``) to the real `PicoBridge` and
`FakeTTAdapter` over the existing `LoopbackPort`, proving the two framings,
the load/run/dump gating and the fault path agree end to end.
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace

from tools.host_bridge import main as M
from tools.host_bridge.tests.fakes import FakeTTAdapter
from tools.host_gui import fake_pe as F
from tools.host_gui.session import (
    ControllerSession,
    SessionError,
    SessionState,
    SessionStateError,
)
from tools.host_gui.tests.fakes import LoopbackPort
from tools.host_gui.transport import SerialTransport

PROJECT = "tt_um_protocol_emulator"
WORDS = (0x0041, 0x1001, 0x4002)


class TestHostOverRealBridge(unittest.TestCase):
    def setUp(self):
        self.pe = F.FakePE()
        self.adapter = FakeTTAdapter(self.pe, irq_supported=True)
        self.bridge = M.PicoBridge(self.adapter, project=PROJECT,
                                   sleep=lambda _seconds: None)
        self.port = LoopbackPort(self.bridge)
        self.transport = SerialTransport(self.port, timeout_s=1.0)
        self.session = ControllerSession(lambda: self.transport)
        self.image = SimpleNamespace(words=WORDS, word_count=len(WORDS),
                                     sha256="ab" * 32)

    def test_connect_load_start_stop_dump_round_trip(self):
        self.session.connect()
        self.assertEqual(self.session.state, SessionState.PREPARED)
        self.assertEqual(self.session.negotiated_sclk_hz, 5_000_000)
        self.assertEqual(self.adapter.project_calls, [PROJECT])
        self.assertEqual(self.adapter.clock_calls, [60_000_000])

        result = self.session.load(self.image)
        self.assertEqual(result.words_written, len(WORDS))
        self.assertEqual(result.echo, WORDS[-1])
        self.assertEqual(tuple(self.pe.committed_words), WORDS)
        self.assertEqual(self.session.state, SessionState.LOADED)

        self.session.start()
        self.assertTrue(self.pe.run)
        self.assertEqual(self.session.state, SessionState.RUNNING)

        snapshot = self.session.status()
        self.assertTrue(snapshot.run)
        self.assertEqual(snapshot.pc, 0)

        self.session.stop()
        self.assertFalse(self.pe.run)
        self.assertEqual(self.session.state, SessionState.STOPPED)

        words = self.session.read_imem(1, 2)
        self.assertEqual(words, WORDS[1:3])
        self.pe.dmem[0:3] = b"\x0a\x0b\x0c"
        self.assertEqual(self.session.read_dmem(0, 3), b"\x0a\x0b\x0c")
        dump = self.session.dump_core()
        self.assertEqual(dump.words_written, len(WORDS))

    def test_fault_event_reaches_the_session_over_the_wire(self):
        self.session.connect()
        self.pe.faults = F.FAULT_LOAD
        self.adapter.set_irq(True)
        self.assertEqual([e["event"] for e in self.bridge.poll_irq()],
                         ["chip.irq"])
        self.session.status()
        self.assertEqual(self.session.state, SessionState.FAULTED)
        self.session.process_events()
        self.assertEqual(self.session.last_fault["event"], "chip.irq")
        self.assertEqual(self.session.last_fault["data"]["faults"],
                         F.FAULT_LOAD)
        self.assertEqual(self.session.clear_fault(F.FAULT_LOAD), 0)
        self.assertEqual(self.session.state, SessionState.PREPARED)

    def test_memory_reads_are_gated_while_running_over_the_wire(self):
        self.session.connect()
        self.session.load(self.image)
        self.session.start()
        self.assertRaises(SessionStateError, self.session.read_imem, 0, 1)

    def test_spi_timeout_never_reports_success_or_a_load(self):
        self.session.connect()
        self.adapter.fail_transfer = True
        with self.assertRaises(SessionError):
            self.session.load(self.image)
        self.assertNotEqual(self.session.state, SessionState.LOADED)
        events = self.session.process_events()
        self.assertEqual([e["event"] for e in events], ["spi.timeout"])
        # The next reachable STATUS recovers the session state; the failed
        # load is not remembered as loaded.
        self.adapter.fail_transfer = False
        snapshot = self.session.status()
        self.assertEqual(snapshot.words_written, 0)
        self.assertEqual(self.session.state, SessionState.PREPARED)


if __name__ == "__main__":
    unittest.main(verbosity=2)
