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
from typing import cast

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

HELLO = {
    "protocol_version": 1,
    "bridge_version": "test",
    "clock_hz": 60_000_000,
    "sclk_hz_max": 5_000_000,
    "pads": dict(board.HOST_SPI_PADS),
}
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
    transports = [T.SerialTransport(p, clock=clock, sleep=clock.sleep) for p in ports]
    pool = list(transports)
    session = S.ControllerSession(lambda: pool.pop(0), clock=clock)
    return session, bridge, ports, transports


def push_event(port, name: str, data: dict | None = None) -> None:
    port.incoming.append(json.dumps({"v": 1, "event": name, "data": data or {}}).encode())


class TestPayloadWordValidation(unittest.TestCase):
    """A caller value that cannot be a frame word must fail TYPED.

    Found by the R3 debug fuzz campaign: `session.bp_set(-1)` reached the
    payload encoder and raised a bare ValueError, which the API's error handler
    does not catch -- an unhandled 500 rather than a 409. The old lenient
    encoder raised OverflowError for the same input, so the 500 predates R3 and
    affected the R2 read ops too; this pins the whole family.
    """

    def setUp(self):
        self.session, self.bridge, self.port, self.transport = make_stack()
        self.session.connect()
        self.session.load(ECHO)

    def test_unencodable_values_are_typed_session_errors(self):
        cases = (
            ("bp_set", (-1,)),
            ("bp_set", (0x10000,)),
            ("read_imem", (-1, 4)),
            ("read_imem", (0, -1)),
            ("read_imem", (0, 0x10000)),
            ("read_dmem", (-1, 4)),
            ("clear_fault", (-1,)),
        )
        for name, args in cases:
            with self.subTest(op=name, args=args):
                call = getattr(self.session, name)
                with self.assertRaises(S.SessionError):
                    call(*args)

    def test_a_non_integer_is_also_a_typed_error(self):
        # `address: int` is the CONTRACT, and it stays useful for every
        # legitimate caller. These values are deliberately below it: the point
        # is that the session validates at RUNTIME, because the API hands it raw
        # JSON. The cast says "on purpose" instead of silencing a diagnostic or
        # weakening an annotation that should be trusted.
        for bad in cast("tuple[object, ...]", ("2", None, 1.5, [1], {"a": 1})):
            with self.subTest(value=bad), self.assertRaises(S.SessionError):
                self.session.bp_set(bad)  # type: ignore[arg-type]

    def test_in_range_but_past_imem_stays_the_chips_answer(self):
        """The session validates the FRAME, not the chip's memory size.

        1024 fits a frame word, so it must reach the chip and be answered
        RANGE; pre-empting that here would hide the chip's own contract.
        """
        with self.assertRaises(S.SessionError) as caught:
            self.session.bp_set(F.IMEM_WORDS)
        self.assertIn("status", str(caught.exception))

    def test_address_zero_is_legal(self):
        """Address 0 is a real breakpoint, told apart by bp_flags bit0."""
        self.assertTrue(self.session.bp_set(0).armed)

    def test_the_session_still_works_afterwards(self):
        """A rejected value must leave the session usable."""
        with self.assertRaises(S.SessionError):
            self.session.bp_set(-1)
        self.assertEqual(self.session.debug_status().state, F.DEBUG_STOPPED)
        self.assertEqual(self.session.debug_step().pc_next, 1)


class TestBoardDecisions(unittest.TestCase):
    def test_plan_pad_mapping_wins(self):
        self.assertEqual(board.HOST_SPI_PADS, {"cs_n": 4, "mosi": 5, "miso": 6, "sck": 7})

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

    def test_failed_load_does_not_stick_in_loading(self):
        """fuzz_server state/stuck-loading: a mid-load protocol error used to
        leave the session in LOADING, so every later load was refused until a
        reconnect. The failed load must restore the pre-load state and a retry
        must work on the same connection."""
        good = {
            "status": P.STATUS_OK,
            "words_written": 3,
            "faults": 0,
            "echo": ECHO.words[-1],
        }
        stub = StubTransport(
            responses=[HELLO, PREPARE, T.TransportProtocolError("garbage"), good]
        )
        session = S.ControllerSession(lambda: stub)
        session.connect()
        with self.assertRaises(S.SessionError):
            session.load(ECHO)
        self.assertEqual(session.state, S.SessionState.PREPARED)
        result = session.load(ECHO)  # no reconnect needed
        self.assertEqual(result.words_written, 3)
        self.assertEqual(session.state, S.SessionState.LOADED)

    def test_echo_mismatch_is_a_fault(self):
        bad = {"status": P.STATUS_OK, "words_written": 3, "faults": 0, "echo": 0xBADD}
        stub = StubTransport(responses=[HELLO, PREPARE, bad])
        session = S.ControllerSession(lambda: stub)
        session.connect()
        with self.assertRaises(S.SessionError):
            session.load(ECHO)
        self.assertEqual(session.state, S.SessionState.FAULTED)


class TestAStepNeedsACoreWorthStepping(unittest.TestCase):
    """A single step is run-control, so it carries run-control's preconditions.

    `start` already refuses a session with nothing loaded ("start requires a
    successful load") and refuses every state but LOADED/STOPPED. A step is the
    same class of action - it executes an instruction - so it inherits both
    rules: there is nothing to step before a load, and a latched fault means
    the last frame the host sent was rejected, which is not a state to keep
    driving the core from. Both refusals are the HOST's policy, stated: the chip
    would execute the step, exactly as it accepts a LOAD under a debug hold
    (which the session also declines).

    They are here because the page's debug panel refused both cases already, off
    a hand-written list of state names, and the two sides disagreed. The rule
    belongs to the session; the button now mirrors it, and
    `tests/test_gui_capabilities.py` fails if either side moves.
    """

    def _loaded_session(self):
        session, bridge, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        return session, bridge

    def test_a_step_before_a_load_is_refused(self):
        session, bridge, _, _ = make_stack()
        session.connect()
        with self.assertRaises(S.SessionStateError) as caught:
            session.debug_step()
        self.assertIn("loaded", str(caught.exception))
        # and nothing moved: the refusal happened before any frame went out
        self.assertFalse(bridge.pe.debug_hold)
        self.assertEqual(bridge.pe.pc, 0)

    def test_a_step_while_faulted_is_refused(self):
        session, bridge = self._loaded_session()
        bridge.pe.faults = F.FAULT_PROTOCOL
        session.status()
        self.assertEqual(session.state, S.SessionState.FAULTED)
        with self.assertRaises(S.SessionStateError) as caught:
            session.debug_step()
        self.assertIn("fault", str(caught.exception).lower())
        self.assertFalse(bridge.pe.debug_hold)

    def test_a_step_still_works_once_the_program_is_there(self):
        session, bridge = self._loaded_session()
        session.bp_set(3)
        result = session.debug_step()
        self.assertEqual(result.state, F.DEBUG_HOLD)
        self.assertTrue(bridge.pe.debug_hold)

    def test_clearing_the_fault_reopens_the_step(self):
        """A refusal that only ever refuses is not a policy, it is a wall."""
        session, bridge = self._loaded_session()
        bridge.pe.faults = F.FAULT_PROTOCOL
        session.status()
        with self.assertRaises(S.SessionStateError):
            session.debug_step()
        session.clear_fault(F.FAULT_PROTOCOL)
        self.assertEqual(session.state, S.SessionState.STOPPED)
        self.assertEqual(session.debug_step().state, F.DEBUG_HOLD)


class TestStatusReportsTheHeldState(unittest.TestCase):
    """STATUS carries the chip's own state word; the session must use it.

    R3 gave the chip two more ways to be stopped, and R2's STATUS reports both
    of them in its own `state` word — so the op a host polls continuously is
    the one that can tell it the core is parked on a breakpoint. It cannot,
    today: `status()` maps the session state from the `run` word ALONE, so a
    live hit (`state=3, run=1`, the state the golden R2 step
    `status_reports_the_hit` now pins) reads as RUNNING, and a step-pause
    (`state=2, run=0`) reads as a plain STOPPED. The debug ops get this right —
    `_debug_state_from` maps 2/3 — which is why the gap is easy to miss: the
    panel path is right and the poll path is wrong, and a host that only uses
    the R2 readback never sees a hold at all.

    Nothing here is inferred: STATUS reports the state word and the run strap
    as SEPARATE words, so the session takes the debug state from the first and
    the strap from the second. The same discipline `_debug_state_from` states
    for the debug prefix, which does not carry the strap.
    """

    def _running_stack(self):
        session, bridge, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        session.start()
        return session, bridge

    def test_a_core_parked_on_a_breakpoint_is_not_reported_as_running(self):
        session, bridge = self._running_stack()
        pe = bridge.pe
        pe.bp_addr, pe.bp_en = 1, True
        pe.set_run(True)
        self.assertTrue(pe.advance_free_running(), "the core must stop on the bp")
        self.assertEqual(pe.state, F.DEBUG_BP_HIT)

        snapshot = session.status()

        # what the chip said, unchanged
        self.assertEqual(snapshot.state, F.DEBUG_BP_HIT)
        self.assertEqual(snapshot.run, 1, "a hit holds the core, not the strap")
        # what the session made of it
        self.assertEqual(session.state, S.SessionState.BP_HIT)

    def test_a_step_pause_is_reported_as_the_hold_it_is(self):
        session, bridge = self._running_stack()
        pe = bridge.pe
        pe.bp_addr, pe.bp_en = 2, True
        pe.set_run(False)  # back to the boot stop
        pe.debug_step_once()  # one instruction, then held
        self.assertEqual(pe.state, F.DEBUG_HOLD)

        snapshot = session.status()

        self.assertEqual(snapshot.state, F.DEBUG_HOLD)
        self.assertEqual(snapshot.run, 0)
        self.assertEqual(session.state, S.SessionState.DEBUG_HOLD)

    def test_the_strap_still_governs_the_stopped_only_reads(self):
        """A GUARD, not the finding: knowing the core is HELD must not unlock it.

        DUMP_CORE is gated on the run strap (the golden step
        `dump_core_refused_the_strap_is_high` pins NOT_READY under a live hit),
        so the session's stopped-only guard keeps following the strap: refused
        under a live hit, answered under a step-pause. Learning the hold must
        not move the host across that gate, and this is driven through the
        session's own API so it cannot pass by accident.
        """
        session, bridge = self._running_stack()
        session.bp_set(1)
        bridge.pe.advance_free_running()  # the core stops on the breakpoint
        with self.assertRaises(S.SessionStateError):
            session.dump_core()  # strap high: refused, as the chip does

        # a step-pause with the strap LOW, reached the way an operator reaches
        # one: stop, arm FURTHER AHEAD, step. (Arming the next landing address
        # would land the step ON the breakpoint and give a BP_HIT instead,
        # which is a different state and already covered above.)
        session.stop()
        session.bp_set(3)
        step = session.debug_step()
        self.assertEqual(step.state, F.DEBUG_HOLD)
        dump = session.dump_core()  # strap low: answered
        self.assertEqual(dump.state, F.DEBUG_HOLD)
        self.assertEqual(dump.run, 0)

    def test_an_unheld_core_reads_exactly_as_before(self):
        session, _ = self._running_stack()
        self.assertEqual(session.status().state, F.DEBUG_RUNNING)
        self.assertEqual(session.state, S.SessionState.RUNNING)
        session.stop()
        self.assertEqual(session.status().state, F.DEBUG_STOPPED)
        self.assertEqual(session.state, S.SessionState.STOPPED)

    def test_a_fault_still_outranks_the_held_state(self):
        session, bridge = self._running_stack()
        bridge.pe.faults = F.FAULT_PROTOCOL
        session.status()
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
        self.assertEqual((cpu.pc, cpu.a, cpu.x, cpu.y, cpu.insn), (5, 6, 7, 8, 0x0041))
        self.assertTrue(bridge.pe.run)  # still running: non-halting
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
        # Manager RULING: the ISA is the source of truth. R2 exposes every bit
        # the chip has - pc 10, a/x/y 8, insn 16 - not more; the old
        # dbg_pc = pc[7:0] truncation is what R2 removes.
        session, bridge, _, _ = make_stack()
        session.connect()
        session.load(ECHO)
        bridge.pe.pc = 0x3FF
        bridge.pe.a = bridge.pe.x = bridge.pe.y = 0xFF
        bridge.pe.insn = 0xFFFF
        cpu = session.read_cpu()
        self.assertEqual(
            (cpu.pc, cpu.a, cpu.x, cpu.y, cpu.insn), (0x3FF, 0xFF, 0xFF, 0xFF, 0xFFFF)
        )


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
        session.status()  # still readable while faulted
        push_event(port, "usb.disconnect")
        session.process_events()
        self.assertEqual(session.state, S.SessionState.DISCONNECTED)
        self.assertIsNotNone(session.last_fault)  # preserved
        self.assertIsNotNone(session.last_status)

    def test_clear_fault_returns_to_stopped(self):
        session, bridge, _, _ = make_stack()
        session.connect()
        session.load(ECHO)  # a valid image is loaded...
        bridge.pe.faults = F.FAULT_LOAD  # ...then a fault appears
        session.status()  # observed: FAULTED
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
