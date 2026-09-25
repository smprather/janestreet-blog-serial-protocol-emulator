"""Tests for the Pico deployment helper (tools/host_bridge/deploy.sh).

The deploy helper is what an operator runs to put the bridge on the board, so
its two safety properties are pinned here: it installs exactly the three
runtime modules, and it refuses to write to anything that is not a board
filesystem. These tests drive the real script against a temporary directory
(dry run for the manifest, a throwaway "board" for the install and the
refusal), so the behavior is exercised, not just grepped.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DEPLOY = REPO_ROOT / "tools" / "host_bridge" / "deploy.sh"
MODULES = ("main.py", "pe_frame.py", "tt_adapter.py")


def run_deploy(*args):
    return subprocess.run([str(DEPLOY), *args], capture_output=True, text=True,
                          check=False)


class TestDeployScript(unittest.TestCase):
    def test_deploy_script_exists_and_is_executable(self):
        self.assertTrue(DEPLOY.is_file())
        self.assertTrue(DEPLOY.stat().st_mode & 0o111)

    def test_dry_run_lists_the_three_modules_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            board = Path(td) / "RPI-RP2"
            board.mkdir()
            (board / "boot.py").touch()
            result = run_deploy("--dry-run", str(board))
            self.assertEqual(result.returncode, 0, result.stderr)
            for module in MODULES:
                self.assertIn(module, result.stdout)
            self.assertIn("sha256:", result.stdout)
            for module in MODULES:                      # nothing was written
                self.assertFalse((board / module).exists())

    def test_install_copies_exactly_the_three_modules(self):
        with tempfile.TemporaryDirectory() as td:
            board = Path(td) / "RPI-RP2"
            board.mkdir()
            (board / "boot.py").touch()
            result = run_deploy(str(board))
            self.assertEqual(result.returncode, 0, result.stderr)
            for module in MODULES:
                self.assertTrue((board / module).is_file())
                self.assertEqual((board / module).read_bytes(),
                                 (REPO_ROOT / "tools" / "host_bridge" / module)
                                 .read_bytes())
            # the host-only modules must not be shipped to the board
            for host_only in ("acceptance.py", "protocol.py"):
                self.assertFalse((board / host_only).exists())

    def test_refuses_a_directory_that_is_not_a_board(self):
        with tempfile.TemporaryDirectory() as td:
            result = run_deploy(td)                      # plain empty dir
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not look like a MicroPython board", result.stderr)
            self.assertEqual(list(Path(td).iterdir()), [])   # wrote nothing

    def test_refuses_a_missing_target(self):
        result = run_deploy("/nonexistent-board-mount")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
