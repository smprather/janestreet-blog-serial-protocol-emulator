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
                capture_output=True,
                text=True,
                check=True,
                cwd=repo,
            ).stdout
            available |= {
                line.split("/")[-1][:-2]
                for line in tree.splitlines()
                if line.startswith("tb/") and line.endswith(".v")
            }
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
            subprocess.run(
                ["python3", "tools/fw/peasm.py", f"firmware/{name}.pe", "-o", str(out)],
                capture_output=True,
                text=True,
                check=True,
                cwd=REPO_ROOT,
            )
            with self.subTest(firmware=name):
                self.assertEqual(len(out.read_text().split()), words)

    def test_proven_pending_split_is_honest(self):
        # R1 and R2 have both landed; R2 is confirmed in simulation. The one
        # thing still not demonstrated is the PHYSICAL board run. The document
        # must say exactly that, cite the chip evidence, and must not call R2
        # pending.
        self.assertRegex(self.text, r"R2[^\n]*(chip-confirmed|LANDED|landed)")
        self.assertIn("R2-READ-PATH-REVIEW", self.text)
        # the conformance count: the R2 READ-PATH steps are confirmed 18/18
        # (the ceiling/zero-count vectors were proven after the 15 original
        # ones). The package is no longer wholly confirmed - 4 held-core
        # steps were added 2026-09-25 and await a chip re-run - so the count
        # alone is not the whole claim, and the row has to carry the
        # unconfirmed half too.
        self.assertIn("18/18", self.text)
        self.assertNotRegex(
            self.text, r"Memory/register readback \(R2\)[^\n]*\*\*pending\*\*"
        )
        # the honest boundary that remains: the real board, never claimed
        self.assertRegex(
            self.text, r"[Pp]hysical[^\n]*(not|unexecuted)|not yet demonstrated"
        )
        self.assertRegex(self.text, r"Board-in-the-loop acceptance[^\n]*\*\*pending\*\*")
        # and it must carry the no-hardware fallback
        self.assertIn("Fallback demo", self.text)
        self.assertIn("no board", self.text.lower())

    def test_the_r2_row_does_not_claim_a_wholly_confirmed_package(self):
        """18/18 is about the read-path steps; the package is 18 of 22.

        The walkthrough is the judge-facing claim surface, and the R3 review's
        F1 was exactly a shipped claim contradicting the flags in the same
        repository. Four held-core steps ship unconfirmed, so the R2 row has
        to say which half is which rather than presenting one number.
        """
        row = next(line for line in self.text.splitlines()
                   if "Memory/register readback (R2)" in line)
        self.assertIn("18/18", row)
        self.assertIn("18 of 22", row)
        self.assertRegex(row, r"NOT confirmed|unconfirmed")
        self.assertIn("R2-HELD-STATUS-BYTES.md", row)
        # the unqualified "this row is wholly chip-confirmed" form is exactly
        # the claim that stopped being true when the held steps landed
        self.assertNotIn("| **chip-confirmed (simulation)** |", row)

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
        audit = (
            Path(__file__).resolve().parents[3] / "docs" / "cold-clone-audit.md"
        ).read_text(encoding="utf-8")
        for number in ("34/34", "26/26"):
            with self.subTest(number=number):
                self.assertIn(number, self.text)
                self.assertIn(number, audit)

    def test_walkthrough_points_at_the_real_commands(self):
        for command in (
            "tools/host_gui/run_host_tests.sh",
            "acceptance.py --fake",
            "acceptance.py --device /dev/ttyACM0",
            "tools/fw/peemu.py",
        ):
            with self.subTest(command=command):
                self.assertIn(command, self.text)
                self.assertIn(command, read(BRINGUP) + self.text)


class TestBringupRunbook(unittest.TestCase):
    def test_bringup_has_the_operator_steps_and_a_triage_table(self):
        text = read(BRINGUP)
        for needed in (
            "deploy.sh",
            "dialout",
            "/dev/ttyACM0",
            "acceptance.py --device",
            "Failure triage",
            "udevadm",
        ):  # the udev escape hatch
            with self.subTest(needed=needed):
                self.assertIn(needed, text)
        rows = [
            line
            for line in text.splitlines()
            if line.startswith("| ") and "---" not in line
        ]
        self.assertGreaterEqual(len(rows), 8)  # a real triage table


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
        self.assertIn("not", text.lower())  # honest about what is pending


class TestDebugActIsHonest(unittest.TestCase):
    """The R3 debug act is a judge-facing claim surface; pin it.

    The demo act makes three claims a judge could check: the act's beats exist
    and pass, the evidence numbers are the real ones, and the hardware run is
    still called pending. Each is pinned against the thing it describes, so
    the document cannot quietly drift into a claim nobody checked.
    """

    @classmethod
    def setUpClass(cls):
        cls.text = read(WALKTHROUGH)
        cls.package = __import__(
            "tools.host_gui.r3_vectors", fromlist=["r3_vectors"]
        ).build_package()
        cls.steps = [s for v in cls.package["vectors"] for s in v["steps"]]

    def test_the_act_is_present_and_wired(self):
        self.assertIn("The debug act", self.text)
        for beat in ("arm", "hit", "inspect", "step", "clear", "resume"):
            with self.subTest(beat=beat):
                self.assertIn(beat, self.text)

    def test_every_demo_beat_named_exists_in_acceptance(self):
        acceptance = (REPO_ROOT / "tools" / "host_bridge" / "acceptance.py").read_text(
            encoding="utf-8"
        )
        beats = set(re.findall(r"r3_demo_\d_[a-z_]+", self.text))
        # The document points at the runner; if it names beats, they must be
        # real, and the runner must still contain the demo act itself.
        self.assertIn("demo_act", acceptance)
        for beat in sorted(beats):
            with self.subTest(beat=beat):
                self.assertIn(beat, acceptance)

    def test_the_quoted_acceptance_counts_are_current(self):
        """A quoted PASS/FAIL/SKIP number with no pin is a claim nobody checks.

        This is the pin that would have caught the walkthrough still quoting
        "22 PASS" after the demo act moved the real number to 35.
        """
        # check=False is explicit: this pin INSPECTS the runner's output
        # rather than reacting to its exit code, and a non-zero exit with a
        # parseable RESULT line is itself information.
        out = subprocess.run(
            ["python3", "tools/host_bridge/acceptance.py", "--fake"],
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
            check=False,
        )
        # The separator is whatever the runner actually prints -- commas. An
        # earlier revision of the walkthrough quoted "22 PASS / 0 FAIL / 1
        # SKIP" while the tool printed commas, and nothing noticed for months;
        # matching the real output is the point of this pin.
        match = re.search(
            r"RESULT: PASS \((\d+) PASS, (\d+) FAIL, (\d+) SKIP\)", out.stdout
        )
        # An explicit guard rather than assertIsNotNone: the failure message
        # is the tail of the real output, and self.fail() is NoReturn, so the
        # match is narrowed for anyone reading this afterwards.
        if match is None:
            self.fail(f"acceptance printed no RESULT line: {out.stdout[-400:]}")
        passes, fails, skips = (int(g) for g in match.groups())
        self.assertEqual(fails, 0)
        for label, value in (("PASS", passes), ("FAIL", fails), ("SKIP", skips)):
            with self.subTest(label=label):
                self.assertIn(f"{value} {label}", self.text)

    def test_the_r3_evidence_counts_match_the_package(self):
        """The act's "25 of 26" must be the package's real arithmetic."""
        boundaries = self.package["model_boundaries"]
        self.assertEqual(len(self.steps), 26)
        self.assertEqual(len(boundaries), 1)
        covered = len(self.steps) - len(boundaries)
        self.assertEqual(covered, 25)
        self.assertIn(f"**{covered} of the {len(self.steps)}**", self.text)

    def test_the_model_boundary_is_not_claimed_as_proven(self):
        """The one uncovered step must be presented as unproven, both sides."""
        self.assertIn("unproven", self.text.lower())
        self.assertIn("model boundary", self.text.lower())
        for entry in self.package["model_boundaries"]:
            with self.subTest(vector=entry["vector"]):
                self.assertFalse(entry["chip_confirmed"])
        # The 25 the chip ran ARE confirmed now; only the boundary is not.
        boundary = {e["step"] for e in self.package["model_boundaries"]}
        unconfirmed = [s["name"] for s in self.steps if not s["chip_confirmed"]]
        self.assertEqual(len(self.steps), 26)
        self.assertEqual(unconfirmed, sorted(boundary))

    def test_the_r3_row_is_simulated_not_hardware(self):
        row = [
            line for line in self.text.splitlines() if line.startswith("| Debug control")
        ]
        self.assertEqual(len(row), 1, "the R3 evidence row must appear once")
        self.assertIn("chip-confirmed (simulation)", row[0])
        self.assertIn("Not** hardware-confirmed", row[0])
        # The board row must still be pending: R3 did not unblock hardware.
        board = [
            line
            for line in self.text.splitlines()
            if line.startswith("| Board-in-the-loop acceptance")
        ]
        self.assertTrue(board and "**pending**" in board[0])

    def test_the_opcodes_named_are_the_real_ones(self):
        from tools.host_gui import protocol as P

        self.assertIn("DEBUG_BP_SET", self.text)
        for name in (
            "OP_DEBUG_STEP",
            "OP_DEBUG_BP_SET",
            "OP_DEBUG_BP_CLR",
            "OP_DEBUG_STATUS",
        ):
            with self.subTest(opcode=name):
                self.assertIn(getattr(P, name), (0x21, 0x22, 0x23, 0x24))

    def test_both_step_semantics_are_stated(self):
        """Stop-before alone would be a half-truth, and it is the subtle one.

        A step retires exactly one instruction; stop-before is about the
        instruction AT the breakpoint. This repo's own model once got that
        backwards and the chip's conformance run caught it, so the document
        must state both halves.
        """
        lowered = self.text.lower()
        self.assertIn("exactly one instruction", lowered)
        self.assertIn("stop-before", lowered)
        self.assertRegex(self.text, r"had \*\*not\*\*\s*\n?\s*run")


if __name__ == "__main__":
    unittest.main(verbosity=2)
