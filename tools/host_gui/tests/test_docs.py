"""Tests for the judge-facing documentation (docs/).

A demo document is a claim surface, so the claims that must stay true are
pinned here: the walkthrough names only testbenches and firmware that exist
in the repo, quotes the regression numbers the chip team publishes, and keeps
the proven/pending split honest (the chip's register readback is still
pending; the framed host bus has landed). If a claim goes stale, this fails
rather than the document quietly lying to a judge.
"""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DOCS = REPO_ROOT / "docs"
WALKTHROUGH = DOCS / "demo-walkthrough.md"
BRINGUP = DOCS / "host-bridge-bringup.md"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class TestDemoWalkthrough(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = read(WALKTHROUGH)

    def test_walkthrough_exists(self):
        self.assertTrue(WALKTHROUGH.is_file())

    def test_every_cited_testbench_exists(self):
        cited = set(re.findall(r"tb_pe_[a-z0-9_]+", self.text))
        self.assertTrue(cited)
        tree = subprocess.run(["git", "ls-tree", "main", "--name-only", "tb/"],
                              capture_output=True, text=True, check=True,
                              cwd=REPO_ROOT).stdout
        available = {line.split("/")[-1][:-2] for line in tree.splitlines()
                     if line.startswith("tb/") and line.endswith(".v")}
        for name in sorted(cited):
            with self.subTest(testbench=name):
                self.assertIn(name, available)

    def test_quoted_word_counts_match_the_assembler(self):
        for name, words in (("uart_echo", 118), ("i2c_xfer", 311)):
            out = Path("/tmp") / f"doc_check_{name}.hex"
            subprocess.run(["python3", "tools/fw/peasm.py",
                            f"firmware/{name}.pe", "-o", str(out)],
                           capture_output=True, text=True, check=True,
                           cwd=REPO_ROOT)
            with self.subTest(firmware=name):
                self.assertEqual(len(out.read_text().split()), words)

    def test_proven_pending_split_is_honest(self):
        # The chip's framed host bus has landed; the register/memory readback
        # has not. The document must not describe either the other way round.
        self.assertRegex(self.text, r"R1[^\n]*LANDED|LANDED[^\n]*R1")
        self.assertRegex(self.text, r"readback[^\n]*pending|pending[^\n]*readback")
        # and it must carry the no-hardware fallback
        self.assertIn("Fallback demo", self.text)
        self.assertIn("no board", self.text.lower())

    def test_regression_numbers_match_the_chip_record(self):
        # The numbers the walkthrough quotes must appear in the chip-side
        # record it cites (main's HANDOFF/STATUS), so they cannot drift.
        chip = subprocess.run(["git", "show", "main:HANDOFF.md"],
                              capture_output=True, text=True, check=True,
                              cwd=REPO_ROOT).stdout
        for number in ("33/33", "26/26"):
            with self.subTest(number=number):
                self.assertIn(number, self.text)
                self.assertIn(number, chip)

    def test_walkthrough_points_at_the_real_commands(self):
        for command in ("tools/host_gui/run_host_tests.sh",
                        "acceptance.py --fake",
                        "acceptance.py --device /dev/ttyACM0",
                        "tools/fw/peemu.py"):
            with self.subTest(command=command):
                self.assertIn(command, self.text)
                self.assertIn(command, read(BRINGUP) + self.text)


class TestBringupRunbook(unittest.TestCase):
    def test_bringup_has_the_operator_steps_and_a_triage_table(self):
        text = read(BRINGUP)
        for needed in ("deploy.sh", "dialout", "/dev/ttyACM0",
                       "acceptance.py --device", "Failure triage",
                       "udevadm"):                   # the udev escape hatch
            with self.subTest(needed=needed):
                self.assertIn(needed, text)
        rows = [line for line in text.splitlines()
                if line.startswith("| ") and "---" not in line]
        self.assertGreaterEqual(len(rows), 8)       # a real triage table


if __name__ == "__main__":
    unittest.main(verbosity=2)
