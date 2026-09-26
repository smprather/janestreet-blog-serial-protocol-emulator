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
import sys
import unittest
from pathlib import Path

from tools.host_bridge import acceptance as ACC

REPO_ROOT = Path(__file__).resolve().parents[3]
DOCS = REPO_ROOT / "docs"
WALKTHROUGH = DOCS / "demo-walkthrough.md"
BRINGUP = DOCS / "host-bridge-bringup.md"
# The judge-facing scorecard. One test class below also carries this path as a
# class attribute; a module constant is the one place a new pin should reach
# for, so the duplication ends here rather than spreading.
SCORECARD = DOCS / "submission-readiness.md"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class TestTheDistributionInstallsItsOwnExtra(unittest.TestCase):
    """`pip install .[host-gui]` is the runbook's first step. It has to work.

    The operator's board run starts with installing the extra. That command
    FAILED on a fresh clone: the `[project]` table declares the extra, but
    nothing told setuptools what the distribution contains, so flat-layout
    auto-discovery found `tb/`, `sim/`, `rtl/`, `wiki/`, `flow/`, `regress/`,
    `firmware/` and `diagrams/` and refused to guess. The error arrives while
    BUILDING, so it looks like a packaging problem rather than a missing
    install step - and nobody noticed because nobody ran it, for the same
    reason nobody ran the server: the extra was never installed here.

    These tests pin the two halves that can be checked without a network: that
    the packaging is DECLARED (so a future scaffold cannot silently re-break
    it), and that the extra still names the three modules the host actually
    imports. The effect itself is verified by
    `python3 -m pip install --dry-run ".[host-gui]"`, which is a command, not a
    test - a gate that shelled out to pip would be slow and would need a
    network, which is a worse trade than a documented command.
    """

    @classmethod
    def setUpClass(cls):
        import tomllib

        REPO_ROOT = Path(__file__).resolve().parents[3]
        cls.text = (REPO_ROOT / "pyproject.toml").read_text(encoding="utf-8")
        cls.data = tomllib.loads(cls.text)

    def test_the_packaging_is_declared_so_flat_layout_discovery_cannot_guess(self):
        setuptools = self.data.get("tool", {}).get("setuptools")
        self.assertIsNotNone(
            setuptools,
            "without [tool.setuptools] the flat layout is ambiguous and the "
            "install the runbook names fails before it resolves anything",
        )
        # This distribution ships no importable package on purpose (the header
        # says so): the tools live in tools/ and are run from the clone. So the
        # declaration must be an explicit EMPTY one, not a guess.
        self.assertEqual(setuptools.get("packages", []), [])
        self.assertEqual(setuptools.get("py-modules", []), [])

    def test_the_extra_still_names_what_the_host_imports(self):
        extra = self.data["project"]["optional-dependencies"]["host-gui"]
        names = " ".join(extra)
        # server.py imports fastapi and uvicorn; the transport imports pyserial
        # lazily behind open_serial. If a module is added to the runtime and
        # not to the extra, the board run fails at import with no clue why.
        for module in ("fastapi", "uvicorn", "pyserial"):
            with self.subTest(module=module):
                self.assertIn(module, names)


class TestTheDemoWalkthrough(unittest.TestCase):
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
        row = next(
            line
            for line in self.text.splitlines()
            if "Memory/register readback (R2)" in line
        )
        self.assertIn("18/18", row)
        # a regex, not a literal: the claim is "18 of 22", and insisting on the
        # exact words makes the pin fail on phrasing ("18 of its 22") instead of
        # on the claim. Same lesson as the walkthrough's whitespace-tolerant
        # patterns - a pin that breaks on a reword is a pin people disable.
        self.assertRegex(row, r"18 of (its )?22")
        self.assertRegex(row, r"NOT confirmed|unconfirmed")
        self.assertIn("R2-HELD-STATUS-BYTES.md", row)
        # the unqualified "this row is wholly chip-confirmed" form is exactly
        # the claim that stopped being true when the held steps landed
        self.assertNotIn("| **chip-confirmed (simulation)** |", row)

    def test_the_debug_act_documents_what_the_new_beats_prove(self):
        """The walkthrough must describe the beats the run now performs.

        Two beats were added to the judge-facing run: the held-state R2
        readback, and the fault-state refusals. A document that lists the act
        without them is not wrong exactly, but it leaves the reader with a
        smaller story than the run tells - and the two facts that matter most
        are the ones a reader would otherwise assume: the strap is what gates
        DUMP_CORE, and the refusal rules are the HOST's, not the chip's.
        """
        # the act's own beat count, which the run produces
        report = ACC.run_acceptance(fake=True)
        demo_beats = [c.name for c in report.checks if c.name.startswith("r3_demo_")]
        with self.subTest(beats=demo_beats):
            self.assertIn(f"the {len(demo_beats)} r3_demo_* beats", self.text)
        # ...and the run's total PASS count, for the same reason: a number in a
        # judge-facing document that nobody re-derives is a number that rots
        passes = sum(1 for c in report.checks if c.status == "PASS")
        with self.subTest(passes=passes):
            self.assertIn(f"{passes} PASS, 0 FAIL", self.text)
        # the two new beats are named, so a reader can find them
        self.assertIn("r3_demo_held_readback", self.text)
        self.assertIn("fault_refusals", self.text)
        # and what they prove, in the document's own words
        self.assertIn("DUMP_CORE", self.text)
        # whitespace-tolerant: prose wraps, and a pattern that only matches a
        # single line is a pattern that fails on a rewrap rather than on a lie
        self.assertRegex(
            self.text, r"gate[d]?\s+is\s+the\s+(run\s+)?strap|strap\s+is\s+what\s+gates"
        )
        self.assertRegex(self.text, r"host('s)?\s+own\s+policy|HOST's\s+rule")
        # the honest boundary: the four held-core steps are not yet chip-confirmed
        self.assertRegex(self.text, r"18 of 22|not yet re-run|not yet confirmed")

    def test_the_pending_board_row_says_what_the_run_now_covers(self):
        """The pending row is a claim about scope, and the scope just grew.

        The board run used to skip the debug act. It no longer does, so a row
        that says only "needs a board" understates what a board run would
        demonstrate - and this row is the one a judge reads to decide what is
        left.
        """
        row = next(
            line
            for line in self.text.splitlines()
            if "Board-in-the-loop acceptance" in line
        )
        self.assertIn("debug act", row)
        self.assertIn("pending", row.lower())

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

    def test_the_runbook_says_the_device_run_includes_the_debug_act(self):
        """What the device run DOES, since the act stopped being skipped.

        Section 4 enumerates the scripted sequence for `--device`. Before
        bce4ee0 that list was complete, because the debug act was skipped
        without a FakePE. Now the device run performs the whole `r3_demo` group
        as well, so an operator reading an accurate-but-stale list would not
        know to expect eight debug beats - and, worse, the "what a healthy run
        looks like" sentence claimed EVERY step passes except `uart`, which on
        an R1-only shuttle would be false the moment the act ran.
        """
        text = read(BRINGUP)
        section = text[
            text.index("## 4. Run the real acceptance") : text.index(
                "## 5. Failure triage"
            )
        ]
        # The SEQUENCE LINE, not the section: a first version of this asserted
        # the word "breakpoint" appeared somewhere below, which the explanatory
        # paragraph satisfied on its own — so deleting the act from the list
        # left the pin green. Asserting on a superset is how a pin rots.
        sequence = next(
            (line for line in section.splitlines() if "register dump" in line), ""
        )
        self.assertIn(
            "debug act", sequence, "the device-run sequence omits the debug act"
        )
        # and the healthy-run claim has to name the precondition it depends on
        self.assertRegex(
            section, r"R3|0x21", "the healthy-run claim must say the debug act needs R3"
        )
        self.assertNotIn("every step passes except `uart`", section)

    def test_the_read_length_failure(self):
        """A defect I found on this host, reachable only on hardware.

        The bridge reads a fixed budget of wait words past every reply, so the
        words after the frame come off a RELEASED MISO pad. When the reader did
        not trim to the length field, EVERY op failed - including `ping` - with
        "length field does not match the frame", which reads like a protocol bug
        and is not one. An operator meets this on the board and has no other
        place to look, so the row has to exist and name the exact error text.
        """
        text = read(BRINGUP)
        rows = [
            line
            for line in text.splitlines()
            if "length field does not match the frame" in line
        ]
        # exactly one: a duplicated triage row is itself a doc smell, and two
        # would let them drift apart
        self.assertEqual(len(rows), 1, "the triage table needs one read-length row")
        row = rows[0]
        self.assertIn(
            "released", row.lower(), "the row must name the released pad as the cause"
        )
        # and it must not blame the contract, which is what makes this failure
        # expensive to diagnose from the symptom alone
        self.assertIn("MISO", row)

    def test_the_r2_triage_row_does_not_quote_a_stale_step_count(self):
        """The row quoted '15 steps'; the package is 18 of 22 confirmed.

        A triage table is read under time pressure by someone holding a board,
        so a stale count in it is a claim with a short half-life.
        """
        text = read(BRINGUP)
        row = next(line for line in text.splitlines() if "r2_read_*" in line)
        self.assertNotIn("the 15 steps", row)
        self.assertIn("18 read-path steps", row)


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


class TestThePageAndTheServerAgreeOnTheRoutes(unittest.TestCase):
    """The page and the server are joined by URL strings, and nothing checked it.

    Every FastAPI test SKIPS in this environment (the extra is not installed
    here), so the one surface a board operator's browser actually talks to has
    no coverage at all. This is the half that does not need the extra: compare
    what the page CALLS against what the server REGISTERS, statically.

    Both directions matter, and they fail differently:
      * a page call with no route is a 404 at runtime, on a board, in front of
        an operator - and it would be the first thing anyone notices, which is
        the worst place to find out;
      * a route nobody calls is dead surface: not wrong, but it is the thing
        that rots silently while looking supported.

    The page's socket URL is built inside `eventSocketUrl()` rather than written
    as a literal, so a literal-only scan MISSES `/api/events` and would report a
    working endpoint as dead. The scan therefore reads the built URL too - the
    first version of this would have produced exactly that false positive, and
    the honest way to find a route the page reaches indirectly is to say so.

    `/api/assemble` is a route the page does not call: the page posts a source
    to `/api/load`, which assembles server-side, and the route exists for
    scripted and fuzz use (fuzz_server.py drives it directly). It is named
    explicitly rather than excused by a prefix rule, so a NEW uncalled route
    fails this test and has to be explained.

    KNOWN LIMIT, stated rather than left for a reader to discover: this
    compares PATHS, not VERBS. A page that POSTed a path the server registers
    GET-only would pass this test and fail at runtime with 405 Method Not
    Allowed. The verbs were checked by reading every call site on 2026-09-25 and
    are correct - `start`/`stop`/`dump` come off a table of `[id, path]` pairs
    fed to `api(path, { method: "POST" })`; the four debug paths go through
    `debugCall`, which hard-codes `method: "POST"`; `connect` and `load` name
    the verb inline. Inferring that from the source needs a real JS parse,
    because the verb sits at a distance from the path literal, and a REGEX that
    guessed it would be a pin that fails open - the exact failure mode this
    class was written to avoid. So the limit is written here instead: if you
    ever see a 405 from the GUI, this is the check that did not catch it.
    """

    PAGE_ONLY_ROUTES = frozenset(
        {
            "/api/assemble": "the page posts a source to /api/load, which "
            "assembles server-side; this route is for scripted "
            "and fuzz callers (fuzz_server.py drives it)",
        }
    )

    # The path pattern allows DIGITS. It did not at first: the class was
    # `[a-z_/]`, so a path like `/api/read_cpu_v2` matched nothing at all -
    # invisible in BOTH directions, which is the worst kind of hole in a
    # comparison. It was found by mutating the page with exactly such a path
    # and watching the pin stay green. `test_the_scanner_sees_digits` now pins
    # the scanner itself, so the hole cannot reopen quietly.
    PAGE_PATH = re.compile(r'"(/api/[A-Za-z0-9_/-]+)"')
    BUILT_PATH = re.compile(r"\$\{location\.host\}(/api/[A-Za-z0-9_/-]+)")
    ROUTE = re.compile(r'@app\.\w+\("(/api/[A-Za-z0-9_/-]+)"\)')

    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[3]
        cls.page = (root / "tools" / "host_gui" / "web" / "app.js").read_text(
            encoding="utf-8"
        )
        cls.server = (root / "tools" / "host_gui" / "server.py").read_text(
            encoding="utf-8"
        )
        # every quoted /api/... in the page, PLUS the ones it BUILDS: the
        # socket URL is a template over location.host, and a literal-only scan
        # misses it (the first version did, and reported a working endpoint as
        # dead). All three patterns capture the leading slash, because a capture
        # group around `api/...` silently drops it and the patterns then
        # disagree about the same path.
        cls.page_calls = set(cls.PAGE_PATH.findall(cls.page))
        cls.page_calls.update(cls.BUILT_PATH.findall(cls.page))
        cls.routes = set(cls.ROUTE.findall(cls.server))

    def test_the_scanner_sees_digits_in_a_path(self):
        """The comparison's own sensitivity, pinned.

        A hole in the SCANNER is worse than a hole in an assertion: it makes
        both directions vacuous for the affected paths, and it fails open. This
        feeds the patterns a path with a digit in it, which is the case that
        was silently dropped.
        """
        snippet = 'api("/api/read_cpu_v2")'
        self.assertEqual(self.PAGE_PATH.findall(snippet), ["/api/read_cpu_v2"])
        self.assertEqual(self.ROUTE.findall('@app.get("/api/status2")'), ["/api/status2"])
        self.assertEqual(
            self.BUILT_PATH.findall("${location.host}/api/events3"), ["/api/events3"]
        )

    def test_the_comparison_saw_both_sides(self):
        """A comparison that matched nothing would pass every other test here."""
        self.assertGreaterEqual(len(self.page_calls), 10)
        self.assertGreaterEqual(len(self.routes), 10)
        self.assertIn("/api/status", self.page_calls)
        self.assertIn("/api/status", self.routes)
        # and the indirectly-built socket URL is in the page's calls
        self.assertIn("/api/events", self.page_calls)

    def test_every_page_call_is_a_registered_route(self):
        missing = sorted(self.page_calls - self.routes)
        self.assertEqual(
            missing,
            [],
            f"the page calls routes the server does not register: "
            f"{missing} - a 404 on a board, in front of an operator",
        )

    def test_every_registered_route_is_called_or_explained(self):
        uncalled = sorted(self.routes - self.page_calls)
        self.assertEqual(
            set(uncalled),
            set(self.PAGE_ONLY_ROUTES),
            f"routes the page never calls: {uncalled}. Name each "
            f"one in PAGE_ONLY_ROUTES with why, or call it.",
        )


class TestTheJudgeFacingCountsAreCurrent(unittest.TestCase):
    """Two documents a judge or an operator reads FIRST, with stale counts.

    The R2 count has moved twice: 15 golden steps became 18 when the ceiling
    vectors landed, and the package became PARTIAL when the four held-core
    steps were added (18 of 22). Both documents below were updated once and
    then left, which is how a claim rots: the number was right on the day
    someone wrote it and nobody revisited it because nothing failed.

    Dated review records are deliberately NOT swept - `wiki/log.md` and the
    per-day review files record what was true then, and rewriting them would
    destroy the only honest record of the change. These two are LIVE: one is
    the scorecard, the other is the runbook's opening, which is the first
    paragraph an operator reads about what is on the shuttle.
    """

    def test_the_scorecard_does_not_claim_the_whole_r2_contract_is_confirmed(self):
        row = next(
            line
            for line in read(SCORECARD).splitlines()
            if "Host-controller story" in line
        )
        self.assertNotIn(
            "18/18 chip-confirmed",
            row,
            "the scorecard presents 18/18 as the whole R2 contract; the package "
            "is 18 of 22 with four held-core steps unconfirmed",
        )
        # a regex, not a literal: the claim is "18 of 22", and insisting on the
        # exact words makes the pin fail on PHRASING ("18 of its 22") instead
        # of on the claim. Same lesson as the walkthrough's whitespace-tolerant
        # patterns - a pin that breaks on a reword is a pin people disable.
        self.assertRegex(row, r"18 of (its )?22")

    def test_the_runbooks_opening_names_the_current_step_count(self):
        text = read(BRINGUP)
        opening = text[: text.index("## 1.")]
        self.assertNotIn(
            "all 15 golden steps",
            opening,
            "the runbook's opening still says 15 golden steps",
        )
        self.assertIn("18", opening)
        # and it must not read as "the whole package is confirmed"
        self.assertRegex(
            opening,
            r"read-path|of 22|22 steps",
            "the opening must scope its count to the read-path steps",
        )


class TestTheRunbooksCommandsAreReal(unittest.TestCase):
    """The runbook's commands must be commands, not plausible-looking text.

    The existing bring-up pin checks that certain strings APPEAR in the
    document. It does not check that they WORK: a renamed script, a moved
    module or a dropped flag leaves every pin green and leaves the operator
    holding a board with a runbook that fails at its first line. That is the
    worst place to discover a typo, and the cheapest thing to check is that the
    paths exist and the flags parse.

    The acceptance invocation is checked by handing its tokens to the real
    `parse_args`, so this is not "does the text look like a command" - it is
    "does the tool accept this command line".
    """

    @classmethod
    def setUpClass(cls):
        cls.text = read(BRINGUP)
        cls.command_paths = cls._paths_in_command_positions(cls.text)
        cls.usage_flags = cls._flags_from_help()

    @staticmethod
    def _paths_in_command_positions(text):
        """`tools/...` paths where the runbook RUNS them, not where it names them.

        Scoped to fenced blocks and lines that start with a command, because a
        prose mention like `tools/host_bridge/{main,pe_frame,tt_adapter}.py` is
        a source list, not a command - and the first version of this swept both
        in, then failed on a directory and on a brace expression it had
        truncated. A pin that fires on prose is a pin people turn off.
        """
        paths = set()
        in_block = False
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("```"):
                in_block = not in_block
                continue
            if in_block or stripped.startswith(
                    ("python3", "tools/", "MICROPYTHON", "$ ", "ls ", "sudo ")):
                paths.update(re.findall(r"tools/[A-Za-z0-9_./-]+", stripped))
        return sorted(paths)

    @staticmethod
    def _flags_from_help():
        """The flags the runner advertises, from the runner's own --help.

        Read from the tool rather than from its source, so a renamed flag
        cannot leave the pin agreeing with a stale copy of itself.
        """
        result = subprocess.run(
            [sys.executable, "-m", "tools.host_bridge.acceptance", "--help"],
            capture_output=True, text=True, check=False, cwd=str(REPO_ROOT))
        return set(re.findall(r"(--[a-z-]+)", result.stdout))

    def test_every_script_the_runbook_runs_exists(self):
        self.assertGreaterEqual(
            len(self.command_paths), 3,
            "the runbook should name the scripts it runs; found "
            f"{self.command_paths}")
        for path in self.command_paths:
            with self.subTest(path=path):
                self.assertTrue((REPO_ROOT / path).is_file(),
                                f"the runbook runs {path}, which does not exist")

    def test_every_flag_the_runbook_uses_is_one_the_runner_accepts(self):
        flags = set(re.findall(r"(?<![\w-])(--[a-z-]+)",
                               "\n".join(line for line in self.text.splitlines()
                                        if "acceptance.py" in line)))
        self.assertIn("--device", flags, "the runbook's device run should be pinned")
        self.assertTrue(self.usage_flags, "could not read the runner's --help")
        for flag in sorted(flags):
            with self.subTest(flag=flag):
                self.assertIn(
                    flag, self.usage_flags,
                    f"the runbook tells the operator to pass {flag}, which "
                    f"acceptance.py does not accept")

if __name__ == "__main__":
    unittest.main(verbosity=2)
