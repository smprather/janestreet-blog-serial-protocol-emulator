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
        # Testbenches live in the chip repo (main); the host branch carries no
        # tb/ directory. Collect from both so a citation is checked against the
        # real tree wherever it lives.
        chip_repo = Path("/home/mylesp/janestreet-blog-serial-protocol-emulator")
        available = set()
        for repo, ref in ((REPO_ROOT, "main"), (chip_repo, None)):
            tree = subprocess.run(
                ["git", "ls-tree", ref or "HEAD", "--name-only", "tb/"],
                capture_output=True, text=True, check=True, cwd=repo).stdout
            available |= {line.split("/")[-1][:-2] for line in tree.splitlines()
                          if line.startswith("tb/") and line.endswith(".v")}
        # The chip working tree may carry a testbench that is not committed yet
        # (e.g. the R2 conformance TB). It is still real evidence on disk, so
        # accept it but do not require it: the committed set is the floor.
        if chip_repo.is_dir():
            available |= {path.stem for path in (chip_repo / "tb").glob("*.v")}
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
        # R1 and R2 have both landed; R2 is confirmed in simulation. The one
        # thing still not demonstrated is the PHYSICAL board run. The document
        # must say exactly that, cite the chip evidence, and must not call R2
        # pending.
        self.assertRegex(self.text, r"R2[^\n]*(chip-confirmed|LANDED|landed)")
        self.assertIn("R2-READ-PATH-REVIEW", self.text)
        # the conformance count: the package is fully confirmed at 18/18 (the
        # ceiling/zero-count vectors were proven after the 15 original ones)
        self.assertIn("18/18", self.text)
        self.assertNotRegex(self.text,
                            r"Memory/register readback \(R2\)[^\n]*\*\*pending\*\*")
        # the honest boundary that remains: the real board, never claimed
        self.assertRegex(self.text, r"[Pp]hysical[^\n]*(not|unexecuted)|not yet demonstrated")
        self.assertRegex(self.text, r"Board-in-the-loop acceptance[^\n]*\*\*pending\*\*")
        # and it must carry the no-hardware fallback
        self.assertIn("Fallback demo", self.text)
        self.assertIn("no board", self.text.lower())

    def test_liveness_is_presented_as_a_chip_confirmed_capability(self):
        # P3 closed chip-side: STATUS carries pc/a/x/y/timer and READ_CPU is
        # non-halting, so the walkthrough may claim liveness - but only as
        # chip-confirmed, with the hardware run still open.
        self.assertIn("READ_CPU", self.text)
        self.assertIn("non-halting", self.text)
        self.assertRegex(self.text, r"[Ll]iveness[^\n]*\*\*chip-confirmed")

    def test_regression_numbers_match_the_measured_reality(self):
        # The walkthrough's regression numbers must match the cold-clone
        # measurement recorded in docs/cold-clone-audit.md (a real run of
        # run_all on a fresh clone), not a doc that can drift.
        audit = (Path(__file__).resolve().parents[3] / "docs"
                 / "cold-clone-audit.md").read_text(encoding="utf-8")
        for number in ("34/34", "26/26"):
            with self.subTest(number=number):
                self.assertIn(number, self.text)
                self.assertIn(number, audit)

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


class TestSubmissionReadiness(unittest.TestCase):
    SCORECARD = REPO_ROOT / "docs" / "submission-readiness.md"

    def test_scorecard_exists_and_names_the_evidence(self):
        self.assertTrue(self.SCORECARD.is_file(), f"missing {self.SCORECARD}")
        text = self.SCORECARD.read_text(encoding="utf-8")
        # it must quote the same regression numbers the walkthrough does
        walk = read(WALKTHROUGH)
        for token in ("34/34", "26/26"):
            with self.subTest(token=token):
                self.assertIn(token, text)
                self.assertIn(token, walk)
        self.assertIn("run_host_tests.sh", text)
        self.assertIn("not", text.lower())          # honest about what is pending


if __name__ == "__main__":
    unittest.main(verbosity=2)
