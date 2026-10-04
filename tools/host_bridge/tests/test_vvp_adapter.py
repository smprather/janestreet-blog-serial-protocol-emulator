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


class FakeReplay:
    """Stands in for VvpTTAdapter._run_script: a deterministic 'chip' whose
    n-th transfer always captures [0xFFFF, 0xA55A, n]."""

    def __init__(self):
        self.scripts: list[list[str]] = []
        self.fail_next = False
        self.diverge = False

    def __call__(self, events):
        self.scripts.append(list(events))
        if self.fail_next:
            self.fail_next = False
            raise V.VvpTTAdapterError("vvp did not complete: simulated")
        xfers = [event for event in events if event.startswith("3 ")]
        captures = [[0xFFFF, 0xA55A, index] for index in range(len(xfers))]
        if self.diverge and len(captures) > 1:
            captures[0] = [0xDEAD]
        return captures


class TestAdapterReplay(unittest.TestCase):
    def setUp(self):
        self.adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        self.addCleanup(self.adapter.close)
        self.replay = FakeReplay()
        patcher = mock.patch.object(self.adapter, "_run_script", side_effect=self.replay)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.adapter.configure_host_spi(5_000_000)  # period_ns = 200 = 0xC8

    def test_every_transfer_replays_the_whole_session_in_order(self):
        self.adapter.reset(True)
        self.adapter.reset(False)
        self.adapter.set_run(False)
        self.adapter.host_spi_transfer(bytes.fromhex("a55a1010000700007dfe"), 21)
        self.adapter.set_run(True)
        self.adapter.host_spi_transfer(bytes.fromhex("a55a1010000800001234"), 21)
        first = ["1 1", "1 0", "2 0", "3 C8 15 5 A55A 1010 0007 0000 7DFE"]
        self.assertEqual(self.replay.scripts[0], first)
        self.assertEqual(
            self.replay.scripts[1],
            first + ["2 1", "3 C8 15 5 A55A 1010 0008 0000 1234"],
        )

    def test_a_transfer_returns_only_its_own_capture(self):
        self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        second = self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        self.assertEqual(second, bytes.fromhex("ffffa55a0001"))

    def test_a_replay_that_diverges_is_a_harness_error(self):
        self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        self.replay.diverge = True
        with self.assertRaisesRegex(V.VvpTTAdapterError, "diverged"):
            self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)

    def test_a_failed_transfer_is_not_replayed_later(self):
        self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        self.replay.fail_next = True
        with self.assertRaises(V.VvpTTAdapterError):
            self.adapter.host_spi_transfer(b"\x00\x01", read_words=2)
        self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        xfers = [e for e in self.replay.scripts[-1] if e.startswith("3 ")]
        self.assertEqual(len(xfers), 2)
        self.assertNotIn("0001", " ".join(xfers))

    def test_a_transfer_past_the_testbench_capacity_is_refused_up_front(self):
        too_long = b"\x00\x00" * (V.TB_MAX_WORDS + 1)
        with self.assertRaisesRegex(V.VvpTTAdapterError, "capacity"):
            self.adapter.host_spi_transfer(too_long, read_words=1)
        with self.assertRaisesRegex(V.VvpTTAdapterError, "capacity"):
            self.adapter.host_spi_transfer(b"\x00\x00", read_words=V.TB_MAX_WORDS)
        self.assertEqual(self.replay.scripts, [])

    def test_an_empty_request_is_refused(self):
        with self.assertRaises(V.VvpTTAdapterError):
            self.adapter.host_spi_transfer(b"", read_words=2)


if __name__ == "__main__":
    unittest.main()
