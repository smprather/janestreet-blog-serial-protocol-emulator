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
    "open", "hello", "prepare", "sclk", "assemble", "load", "readback",
    "start", "heartbeat", "stop", "dump", "irq", "fault", "clear_fault",
    "uart", "disconnect", "reconnect",
)


class TestFakeDryRun(unittest.TestCase):
    def test_fake_dry_run_passes_and_never_opens_a_serial_device(self):
        with mock.patch("tools.host_gui.transport.open_serial",
                        side_effect=AssertionError("--fake opened a device")):
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
        skipped = [check.name for check in report.checks
                   if check.status == "SKIP"]
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
        for expected in ("r2_read_imem", "r2_read_dmem", "r2_range",
                         "r2_read_cpu", "r2_dump_header",
                         "r2_range_fault_lifecycle"):
            with self.subTest(check=expected):
                self.assertIn(expected, names)
        r2 = [c for c in report.checks if c.name.startswith("r2_")]
        self.assertTrue(r2)
        for check in r2:
            with self.subTest(check=check.name):
                self.assertEqual(check.status, "PASS")
                # Chip R2 is confirmed in simulation; the hardware run is not.
                self.assertIn("chip-confirmed in simulation",
                              check.detail.lower())

    def test_range_fault_lifecycle_check_reports_the_sticky_fault(self):
        report = ACC.run_acceptance(fake=True)
        check = next(c for c in report.checks
                     if c.name == "r2_range_fault_lifecycle")
        self.assertEqual(check.status, "PASS")
        # The manager ruling: a bad read latches sticky FAULT_RANGE and
        # CLEAR_FAULT clears it; the detail must record both facts.
        self.assertIn("FAULT_RANGE", check.detail)
        self.assertIn("cleared", check.detail.lower())

    def test_dry_run_still_reports_uart_as_the_only_skip(self):
        report = ACC.run_acceptance(fake=True)
        skipped = [c.name for c in report.checks if c.status == "SKIP"]
        self.assertEqual(skipped, ["uart"])


class TestDeviceOpen(unittest.TestCase):
    def test_permission_error_carries_the_dialout_hint(self):
        with (mock.patch("tools.host_gui.transport.open_serial",
                         side_effect=PermissionError("denied")),
              self.assertRaises(TransportError) as caught):
            ACC.build_serial_link("/dev/ttyACM0")
        message = str(caught.exception)
        self.assertIn("/dev/ttyACM0", message)
        self.assertIn("dialout", message)

    def test_open_failure_is_reported_not_raised(self):
        with mock.patch.object(ACC, "build_serial_link",
                               side_effect=TransportError("boom: dialout")):
            report = ACC.run_acceptance(fake=False, device="/dev/nope")
        self.assertFalse(report.passed)
        self.assertIn("dialout", report.render())
        self.assertIn("FAIL", report.render())


class TestCli(unittest.TestCase):
    def test_main_returns_zero_on_the_fake_dry_run(self):
        self.assertEqual(ACC.main(["--fake"], printer=lambda _line: None), 0)

    def test_main_returns_nonzero_when_the_link_cannot_open(self):
        with mock.patch.object(ACC, "build_serial_link",
                               side_effect=TransportError("no device")):
            code = ACC.main(["--device", "/dev/nope"],
                            printer=lambda _line: None)
        self.assertEqual(code, 1)

    def test_fake_and_device_are_mutually_exclusive(self):
        with self.assertRaises(SystemExit):
            ACC.main(["--fake", "--device", "/dev/ttyACM0"],
                     printer=lambda _line: None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
