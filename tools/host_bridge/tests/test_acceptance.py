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
