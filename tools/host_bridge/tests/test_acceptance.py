"""Tests for the acceptance runner (plan Task 7 Step 2, the --fake dry run).

The dry run must exercise the whole host stack against the fake PE simulator
and the fake SDK adapter and must never open a serial device. These tests
also pin the operator-facing failure text for a missing/unreadable device.
"""

from __future__ import annotations

import unittest
from unittest import mock

from tools.host_bridge import acceptance as ACC
from tools.host_gui.transport import TransportError

EXPECTED_CHECKS = (
    "open",
    "hello",
    "prepare",
    "sclk",
    "assemble",
    "load",
    "readback",
    "start",
    "heartbeat",
    "stop",
    "dump",
    "irq",
    "fault",
    "clear_fault",
    "uart",
    "disconnect",
    "reconnect",
)


class TestFakeDryRun(unittest.TestCase):
    def test_fake_dry_run_passes_and_never_opens_a_serial_device(self):
        with mock.patch(
            "tools.host_gui.transport.open_serial",
            side_effect=AssertionError("--fake opened a device"),
        ):
            report = ACC.run_acceptance(fake=True)
        self.assertTrue(report.passed, report.render())
        names = [check.name for check in report.checks]
        for expected in EXPECTED_CHECKS:
            with self.subTest(check=expected):
                self.assertIn(expected, names)
        self.assertEqual(report.manifest["clock_hz"], 60_000_000)
        self.assertEqual(report.manifest["sclk_hz_max"], 5_000_000)
        self.assertEqual(report.manifest["source"], "uart_echo.pe")
        self.assertGreater(report.manifest["word_count"], 0)
        self.assertEqual(len(report.manifest["sha256"]), 64)

    def test_fake_dry_run_only_skips_uart(self):
        report = ACC.run_acceptance(fake=True)
        skipped = [check.name for check in report.checks if check.status == "SKIP"]
        self.assertEqual(skipped, ["uart"])
        uart = next(c for c in report.checks if c.name == "uart")
        self.assertIn("no bridge op", uart.detail)

    def test_fake_dry_run_exercises_the_chip_fault_path(self):
        report = ACC.run_acceptance(fake=True)
        by_name = {check.name: check for check in report.checks}
        self.assertEqual(by_name["irq"].status, "PASS")
        self.assertEqual(by_name["fault"].status, "PASS")
        self.assertEqual(by_name["clear_fault"].status, "PASS")
        self.assertEqual(by_name["reconnect"].status, "PASS")

    def test_fake_dry_run_covers_the_r2_read_contract(self):
        report = ACC.run_acceptance(fake=True)
        names = {check.name for check in report.checks}
        for expected in (
            "r2_read_imem",
            "r2_read_dmem",
            "r2_range",
            "r2_read_cpu",
            "r2_dump_header",
            "r2_range_fault_lifecycle",
        ):
            with self.subTest(check=expected):
                self.assertIn(expected, names)
        r2 = [c for c in report.checks if c.name.startswith("r2_")]
        self.assertTrue(r2)
        for check in r2:
            with self.subTest(check=check.name):
                self.assertEqual(check.status, "PASS")
                # Chip R2 is confirmed in simulation; the hardware run is not.
                self.assertIn("chip-confirmed in simulation", check.detail.lower())

    def test_range_fault_lifecycle_check_reports_the_sticky_fault(self):
        report = ACC.run_acceptance(fake=True)
        check = next(c for c in report.checks if c.name == "r2_range_fault_lifecycle")
        self.assertEqual(check.status, "PASS")
        # The manager ruling: a bad read latches sticky FAULT_RANGE and
        # CLEAR_FAULT clears it; the detail must record both facts.
        self.assertIn("FAULT_RANGE", check.detail)
        self.assertIn("cleared", check.detail.lower())

    def test_dry_run_still_reports_uart_as_the_only_skip(self):
        report = ACC.run_acceptance(fake=True)
        skipped = [c.name for c in report.checks if c.status == "SKIP"]
        self.assertEqual(skipped, ["uart"])


class TestTheHeldReadbackAndRefusalBeats(unittest.TestCase):
    """The judge-facing run must DEMONSTRATE the host's held-state behaviour.

    Three host changes landed (the readback state word, the GUI capability
    rules, the debug-panel rules) and the acceptance run - the thing a judge
    watches - still walked the old path. A fix nobody can see in the demo is a
    fix that reads as unverified, so the run now carries the evidence:

    * `r3_demo_held_readback`, inside the demo group where the hit already
      happens: what the host REPORTS when the core is parked on a breakpoint
      through the R2 readback the GUI actually polls (`STATUS`), that
      `DUMP_CORE` is refused because its gate is the run strap and the strap is
      still high, and that `READ_CPU` answers anyway because it is the
      non-halting read. Unnumbered, because the walkthrough cites the 1-7
      numbering and renumbering would desynchronise the document from the run.
    * a fault-refusal beat between the existing `fault` and `clear_fault` beats
      (nothing reordered, so the rest of the sequence is untouched): the two
      host refusal rules, and the fact that the fault-state `DUMP_CORE` still
      answers - the header whose sticky fault word is the whole diagnostic, and
      the read the GUI button was hiding.

    The details are pinned, not just the PASS/FAIL: a beat that says "ok" and
    nothing else proves nothing to a reader, and a judge-facing line is the one
    place where the difference between a measurement and a claim shows up.
    """

    @classmethod
    def setUpClass(cls):
        cls.report = ACC.run_acceptance(fake=True)
        cls.by_name = {check.name: check for check in cls.report.checks}
        cls.order = [check.name for check in cls.report.checks]

    def test_the_held_readback_beat_runs_and_passes(self):
        self.assertIn("r3_demo_held_readback", self.by_name)
        check = self.by_name["r3_demo_held_readback"]
        self.assertEqual(check.status, "PASS", check.detail)

    def test_the_held_readback_beat_states_the_three_things_it_proves(self):
        detail = self.by_name["r3_demo_held_readback"].detail
        # 1. the poll path: STATUS is the op the GUI polls, and it must report
        #    the chip's own state word - BP_HIT, not "stopped"
        self.assertIn("STATUS", detail)
        self.assertIn("BP_HIT", detail)
        # 2. the strap gate: DUMP_CORE is refused, and the reason is the STRAP
        self.assertIn("DUMP_CORE", detail)
        self.assertIn("NOT_READY", detail)
        # 3. the non-halting read still answers on a held core
        self.assertIn("READ_CPU", detail)
        # and the run strap is stated as still high, which is the whole point
        self.assertIn("run=1", detail)

    def test_the_held_readback_beat_does_not_overclaim_the_r2_steps(self):
        """The R2 held readback is 4 steps the chip has NOT re-run.

        The debug-hold STATE is covered by the R3 package (chip-confirmed in
        simulation), but the R2 readback of that state is exactly the surface
        the R3 review found untested, and its golden steps ship
        `chip_confirmed=false` until the chip runs them. A demo line that
        borrows the R3 tag wholesale would repeat the F1 defect - a claim
        stronger than the evidence beside it.
        """
        detail = self.by_name["r3_demo_held_readback"].detail
        self.assertIn("18 of 22", detail)
        self.assertIn("not yet", detail.lower())

    def test_the_held_readback_beat_carries_one_claim_not_two(self):
        """One line, one package claim.

        The shared `_r3_detail` tag ends with the R3 package's own tally
        (25/26 chip_confirmed). Appending it to a line whose subject is the R2
        readback puts two different packages' tallies on one judge-facing line,
        so a reader cannot tell which claim covers the words in front of them -
        which is the F1 defect in a new place. So the beat carries its own tail
        and the R3 tally must not appear on it at all.
        """
        detail = self.by_name["r3_demo_held_readback"].detail
        self.assertNotIn("25/26", detail)
        self.assertNotIn("tb_pe_ctrl_r3_conf", detail)
        # ...while still attributing the debug-hold STATE to the R3 vectors in
        # its own words, because that part IS chip-confirmed in simulation
        self.assertIn("chip-confirmed in SIMULATION through the R3 vectors", detail)

    def test_the_fault_refusal_beat_sits_between_fault_and_clear_fault(self):
        """Placement, not just presence: nothing in the run is reordered."""
        refusal = [
            name
            for name in self.order
            if name not in ("fault", "clear_fault") and "refus" in name
        ]
        self.assertEqual(len(refusal), 1, f"expected one refusal beat: {self.order}")
        self.assertLess(self.order.index("fault"), self.order.index(refusal[0]))
        self.assertLess(self.order.index(refusal[0]), self.order.index("clear_fault"))

    def test_the_fault_refusal_beat_separates_host_policy_from_a_chip_claim(self):
        detail = next(
            c.detail
            for c in self.report.checks
            if "refus" in c.name and c.name != "fault"
        ).lower()
        # the refusal rules are the HOST's own, and the beat must say so
        self.assertIn("host", detail)
        self.assertIn("policy", detail)
        # the dump half IS a chip claim, and carries the R2 evidence tag
        self.assertIn("chip-confirmed in simulation", detail)
        self.assertIn("hardware acceptance not yet run", detail)

    def test_the_fault_refusal_beat_proves_the_fault_state_dump_answers(self):
        detail = next(
            c.detail
            for c in self.report.checks
            if "refus" in c.name and c.name != "fault"
        )
        # the sticky fault word is header field 9 and it is the diagnostic
        self.assertIn("FAULT", detail.upper())
        self.assertIn("0x0001", detail)

    def test_the_demo_beat_count_is_what_the_run_produces(self):
        """The walkthrough states a beat count; it must be the real one."""
        demo_beats = [name for name in self.order if name.startswith("r3_demo_")]
        self.assertEqual(
            len(demo_beats), 8, f"7 numbered + 1 unnumbered held readback: {demo_beats}"
        )
        numbered = [
            name for name in demo_beats if name[len("r3_demo_") :].split("_")[0].isdigit()
        ]
        self.assertEqual(len(numbered), 7, numbered)


class TestTheDemoActReachesTheBreakpointWithoutTheModel(unittest.TestCase):
    """The act must run on a REAL link, not only where a model can be clocked.

    `demo_act` reached the breakpoint with `pe.advance_free_running()`, so on a
    board (`--device`, where there is no FakePE) the whole r3_demo group was
    SKIPPED - including the two beats about the held readback. The walkthrough
    tells a judge to run exactly this act, and the operator's board run would
    have silently not done it.

    What the act actually needs is to WAIT for the core to arrive, not to push
    it there: a real core advances on its own, the model does not. So the
    advance is an injected hook, and the wait is bounded - an unbounded wait is
    a hang, which is the same discipline the L1 bring-up trap taught about
    assuming hardware will do something.
    """

    @staticmethod
    def _clocking_model(max_instructions=None):
        """A stand-in for the FakePE's clocking, counting the calls."""
        calls = []

        def advance():
            calls.append(1)
            return True

        return advance, calls

    def test_the_wait_calls_the_injected_advance_until_the_hit(self):
        advance, calls = self._clocking_model()
        states = [0, 0, 3]          # the core arrives on the third poll

        def read():
            return states.pop(0) if states else 3

        hit = ACC.await_breakpoint_hit(debug_state=read, advance=advance, tries=5)
        self.assertTrue(hit["stopped"])
        self.assertEqual(len(calls), 2, "advance once per poll until the hit")

    def test_the_wait_gives_up_instead_of_hanging(self):
        """Bounded, and it says what it saw - a hang is the failure mode here."""
        advance, calls = self._clocking_model()
        hit = ACC.await_breakpoint_hit(debug_state=lambda: 1, advance=advance,
                                       tries=3)
        self.assertFalse(hit["stopped"])
        self.assertEqual(len(calls), 3, "exactly `tries` polls, no more")
        self.assertIn("state=1", hit["detail"])

    def test_a_real_link_needs_no_advance_hook(self):
        """The board path: no model to clock, so the wait is pure polling."""
        states = iter([1, 1, 3])
        hit = ACC.await_breakpoint_hit(debug_state=lambda: next(states),
                                       advance=None, tries=5)
        self.assertTrue(hit["stopped"])
        self.assertIn("on its own", hit["detail"],
                      "the beat must say the core advanced by itself, not "
                      "that the model clocked it")

    def test_the_fake_beat_output_is_unchanged(self):
        """The fake path must not move: its beats are pinned by the walkthrough.

        A refactor that improves the board run must not alter the text a judge
        reads on the fallback demo, so this compares the whole r3_demo group
        before and after - names, statuses and details.
        """
        report = ACC.run_acceptance(fake=True)
        group = [c for c in report.checks if c.name.startswith("r3_demo_")]
        self.assertTrue(group, "the act must still run under --fake")
        self.assertTrue(all(c.status == "PASS" for c in group))
        self.assertIn("model-clocked", next(
            c for c in group if c.name == "r3_demo_2_run_and_hit").detail)
        self.assertIn("a real core does", next(
            c for c in group if c.name == "r3_demo_2_run_and_hit").detail)

    def test_the_act_is_not_skipped_on_a_link_without_a_model(self):
        """The whole point: no FakePE must no longer mean no act.

        Driven with a link that has no model, which is the `--device` shape.
        """
        report = ACC.run_acceptance(fake=True, model_backed=False)
        self.assertNotIn("r3_demo_act", [c.name for c in report.checks
                                         if c.status == "SKIP"])
        group = [c for c in report.checks if c.name.startswith("r3_demo_")]
        self.assertTrue(group, "the act must run without a model to clock")


class TestDeviceOpen(unittest.TestCase):
    def test_permission_error_carries_the_dialout_hint(self):
        with (
            mock.patch(
                "tools.host_gui.transport.open_serial",
                side_effect=PermissionError("denied"),
            ),
            self.assertRaises(TransportError) as caught,
        ):
            ACC.build_serial_link("/dev/ttyACM0")
        message = str(caught.exception)
        self.assertIn("/dev/ttyACM0", message)
        self.assertIn("dialout", message)

    def test_open_failure_is_reported_not_raised(self):
        with mock.patch.object(
            ACC, "build_serial_link", side_effect=TransportError("boom: dialout")
        ):
            report = ACC.run_acceptance(fake=False, device="/dev/nope")
        self.assertFalse(report.passed)
        self.assertIn("dialout", report.render())
        self.assertIn("FAIL", report.render())


class TestCli(unittest.TestCase):
    def test_main_returns_zero_on_the_fake_dry_run(self):
        self.assertEqual(ACC.main(["--fake"], printer=lambda _line: None), 0)

    def test_main_returns_nonzero_when_the_link_cannot_open(self):
        with mock.patch.object(
            ACC, "build_serial_link", side_effect=TransportError("no device")
        ):
            code = ACC.main(["--device", "/dev/nope"], printer=lambda _line: None)
        self.assertEqual(code, 1)

    def test_fake_and_device_are_mutually_exclusive(self):
        with self.assertRaises(SystemExit):
            ACC.main(["--fake", "--device", "/dev/ttyACM0"], printer=lambda _line: None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
