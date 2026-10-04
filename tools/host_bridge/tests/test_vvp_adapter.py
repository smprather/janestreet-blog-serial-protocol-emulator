"""Unit tests for VvpTTAdapter that need no simulator.

The integration lane (test_vvp_integration.py) needs iverilog, vvp and the PDK
SRAM model, and skips without them. Everything here runs on python3 alone:
subprocess is replaced wherever a test needs a simulator's behaviour, so the
host gate checks the adapter's own logic on every host.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import unittest
from pathlib import Path
from unittest import mock

from tools.host_bridge import vvp_adapter as V

NO_REPO = "/nonexistent-repo"


class TestAdapterHarnessFaults(unittest.TestCase):
    """A broken simulator install is a HARNESS fault, reported in the adapter's
    own error type and within a bound - never a hang, never a raw OSError."""

    def setUp(self):
        self.adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        self.addCleanup(self.adapter.close)
        # _start() reads the source list from run_all.sh and the SRAM model from
        # sram_model.sh; neither is what these tests are about.
        for name in ("_rtl_list", "_sram_files"):
            patcher = mock.patch.object(self.adapter, name, return_value=[])
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_a_hung_compile_is_an_adapter_error(self):
        hang = subprocess.TimeoutExpired(cmd="iverilog", timeout=1)
        with (
            mock.patch.object(V.subprocess, "run", side_effect=hang),
            self.assertRaises(V.VvpTTAdapterError) as ctx,
        ):
            self.adapter.enable_project("tt_um_protocol_emulator")
        self.assertIn("iverilog did not complete", str(ctx.exception))

    def test_a_missing_iverilog_is_an_adapter_error(self):
        missing = FileNotFoundError(2, "No such file or directory", "iverilog")
        with (
            mock.patch.object(V.subprocess, "run", side_effect=missing),
            self.assertRaises(V.VvpTTAdapterError),
        ):
            self.adapter.enable_project("tt_um_protocol_emulator")

    def test_the_compile_is_bounded(self):
        done = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with mock.patch.object(V.subprocess, "run", return_value=done) as run:
            self.adapter.enable_project("tt_um_protocol_emulator")
        self.assertEqual(run.call_args.kwargs["timeout"], self.adapter.compile_timeout_s)


class TestSramModelFaults(unittest.TestCase):
    def test_a_hung_sram_model_is_an_adapter_error(self):
        adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        self.addCleanup(adapter.close)
        hang = subprocess.TimeoutExpired(cmd="sram_model.sh", timeout=1)
        with (
            mock.patch.object(V.subprocess, "run", side_effect=hang),
            self.assertRaises(V.VvpTTAdapterError),
        ):
            adapter._sram_files()


class TestAdapterClocking(unittest.TestCase):
    def setUp(self):
        self.adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        self.addCleanup(self.adapter.close)

    def test_set_clock_reports_the_clock_the_testbench_runs(self):
        # The testbench clock is fixed; the HAL returns the clock actually
        # running, exactly as TTAdapter returns what the board PWM got.
        self.assertEqual(self.adapter.set_clock(48_000_000), V.PROJECT_CLK_HZ)
        self.assertIn(("set_clock", 48_000_000), self.adapter.calls)

    def test_configure_host_spi_sets_the_bit_period_in_nanoseconds(self):
        self.adapter.configure_host_spi(5_000_000)
        self.assertEqual(self.adapter.period_ns, 200)
        self.adapter.configure_host_spi(1_000_000)
        self.assertEqual(self.adapter.period_ns, 1000)

    def test_configure_host_spi_refuses_a_non_positive_rate(self):
        with self.assertRaises(V.VvpTTAdapterError):
            self.adapter.configure_host_spi(0)


class TestAdapterCleanup(unittest.TestCase):
    def test_close_removes_the_scratch_directory_and_is_idempotent(self):
        adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        workdir = adapter._workdir
        adapter.close()
        self.assertFalse(os.path.exists(workdir))
        adapter.close()  # addCleanup and __exit__ may both call it
        self.assertIsNone(adapter.cleanup_error)

    @unittest.skipIf(
        hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores permissions"
    )
    def test_close_records_a_cleanup_error_instead_of_dropping_it(self):
        adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        workdir = adapter._workdir
        locked = Path(workdir, "locked")
        locked.mkdir()
        Path(locked, "file").touch()
        os.chmod(locked, 0o500)  # the file inside can no longer be unlinked

        def restore():
            os.chmod(locked, 0o700)
            shutil.rmtree(workdir, ignore_errors=True)

        self.addCleanup(restore)
        adapter.close()
        self.assertIsInstance(adapter.cleanup_error, PermissionError)


class TestParseCaptures(unittest.TestCase):
    def test_splits_captures_by_marker(self):
        text = "@0\nffff\na55a\n@1\n0001\n"
        self.assertEqual(V.parse_captures(text), [[0xFFFF, 0xA55A], [0x0001]])

    def test_an_undriven_word_is_a_harness_error(self):
        with self.assertRaises(V.VvpTTAdapterError):
            V.parse_captures("@0\nxxxx\n")

    def test_markers_must_count_up_from_zero(self):
        with self.assertRaises(V.VvpTTAdapterError):
            V.parse_captures("@1\nffff\n")

    def test_a_word_before_any_marker_is_a_harness_error(self):
        with self.assertRaises(V.VvpTTAdapterError):
            V.parse_captures("ffff\n@0\n")


if __name__ == "__main__":
    unittest.main()
