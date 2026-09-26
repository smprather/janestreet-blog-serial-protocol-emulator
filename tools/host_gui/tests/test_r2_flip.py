"""The flag-flip choreography, tested before it exists.

When the chip re-runs `tb_pe_ctrl_r2` against the four held-core golden steps
and reports them byte-exact, the package has to change from "18 of 22
confirmed" to "22 of 22". That flip is nine surfaces at once, and the surface
that must not be hand-maintained is the NOTICE: it is generated from the same
source as the flags, so the drift gate structurally cannot catch it being wrong
— which is exactly the R3 review's F1 defect, where a shipped notice claimed
the opposite of the flags in the same file.

So the flip is a tool, not a checklist, and these tests pin the properties that
make it safe:

* it REFUSES without the chip report citation — the trigger is the chip's green
  report, and a flip that could be run on a hunch is a flip that will be;
* it REFUSES if any already-published byte has changed, so a flip can never
  launder a byte edit into "confirmed";
* it moves exactly the four named steps and leaves the eighteen alone;
* the notice is GENERATED from the flag arithmetic, so a hand-edited notice
  cannot survive a build;
* the artifact the chip actually reads (the hex manifest) carries that same
  generated notice.

Every test operates on a copy in a temp directory. Nothing here flips the real
package: the real flip waits for the chip's report, and the trigger for the
whole feature is that report, not this suite.
"""

from __future__ import annotations

import ast
import json
import unittest
from pathlib import Path

from tools.host_gui import r2_vectors as V

REPO_ROOT = Path(__file__).resolve().parents[3]
MODULE = REPO_ROOT / "tools" / "host_gui" / "r2_vectors.py"
# The flip's INPUT, frozen: the module as it stood with the four held-core steps
# still pending. It is a fixture rather than a copy of HEAD because the shipped
# module now REFUSES the transform, so a suite that read its input from HEAD
# would stop testing the mechanism the moment the tool was used. It is an input,
# not a copy of the truth, so it cannot drift into a second source of claims.
PREFLIP = (REPO_ROOT / "tools" / "host_gui" / "tests" / "fixtures"
           / "r2_vectors_preflip.py")

CITE = "chip repo: reviews/2026-09-25/R2-READ-PATH-REVIEW.md (section 'Conformance')"
DATE = "2026-09-26"


class FlipHarness(unittest.TestCase):
    """The flip exercised on its frozen input, never on the shipped module."""

    def setUp(self):
        self.source_text = PREFLIP.read_text(encoding="utf-8")
        # the premise, asserted rather than assumed: the shipped module must be
        # the FLIPPED one (pending set empty), or this suite is measuring the
        # wrong direction - it exists to test the transform, not the outcome
        self.assertIn(
            '"pending_steps": (),', MODULE.read_text(encoding="utf-8"),
            "the shipped module should be flipped; this suite exercises the "
            "pre-flip input on purpose")

    def source(self) -> str:
        return self.source_text

    def flipped(self, **kwargs):
        """Run the flip over the input; return the resulting source text."""
        params = {"cite": CITE, "date": DATE, **kwargs}
        return V.flip_held_steps(self.source(), **params)


class TestTheFlipRefusesWithoutEvidence(FlipHarness):
    """The trigger is the chip's green report, so the cite is not optional."""

    def test_a_flip_without_a_citation_is_refused(self):
        for missing in ("cite", "date"):
            kwargs = {"cite": CITE, "date": DATE}
            kwargs.pop(missing)
            with self.subTest(missing=missing):
                with self.assertRaises(V.FlipRefused) as caught:
                    V.flip_held_steps(self.source(), **kwargs)
                self.assertIn(missing, str(caught.exception).lower())

    def test_an_empty_citation_is_refused(self):
        for empty in ("", "   "):
            with self.subTest(cite=repr(empty)), self.assertRaises(V.FlipRefused):
                V.flip_held_steps(self.source(), cite=empty, date=DATE)

    def test_a_flip_is_not_idempotently_accepted(self):
        """A second flip must say so, not silently rewrite the same evidence.

        Re-flipping after the steps are already confirmed would restate the
        conformance line from a count it no longer has anything to add to, and
        the notice would be regenerated with a pending set the chip has already
        cleared. Reporting the no-op is the honest outcome.
        """
        once = self.flipped()
        with self.assertRaises(V.FlipRefused) as caught:
            V.flip_held_steps(once, cite=CITE, date=DATE)
        self.assertIn("already", str(caught.exception).lower())


class TestTheFlipMovesOnlyTheFourSteps(FlipHarness):
    def test_the_flip_moves_only_the_four_steps(self):
        """The flipped source must still be a valid module.

        The first version of the transform used one span-replace for both
        "append four names" and "rewrite this value", so it DELETED the
        eighteen it was adding to and emitted source nobody could import. The
        test that would have caught it in one second is "does it parse", so
        that is the test.
        """
        flipped = self.flipped()
        try:
            ast.parse(flipped)
        except SyntaxError as exc:  # pragma: no cover - the failure itself
            self.fail(f"the flip produced unparseable source: {exc}")

    def test_the_four_held_steps_move_from_pending_to_confirmed(self):
        flipped = self.flipped()
        # the new evidence, read back out of the flipped source
        namespace: dict = {}
        exec(compile(flipped, "r2_vectors.py", "exec"), namespace)  # noqa: S102
        evidence = namespace["CHIP_EVIDENCE"]
        self.assertEqual(sorted(evidence["pending_steps"]), [])
        for name in V.HELD_STEP_NAMES:
            self.assertIn(name, evidence["confirmed_steps"])
        self.assertEqual(len(evidence["confirmed_steps"]), 18 + len(V.HELD_STEP_NAMES))
        self.assertIn("22/22", evidence["conformance"])
        self.assertIn(CITE.split(" (")[0], evidence["review"])

    def test_the_eighteen_published_steps_are_untouched(self):
        flipped = self.flipped()
        namespace: dict = {}
        exec(compile(flipped, "r2_vectors.py", "exec"), namespace)  # noqa: S102
        evidence = namespace["CHIP_EVIDENCE"]
        # "before" is the flip's own INPUT, not the shipped artifact. Reading it
        # from the artifact compares the transform against a file the transform
        # has already been applied to, which made this test assert that a second
        # flip would add four more steps - a description of nothing.
        before = set(V._source_literal(self.source(), "CONFIRMED_STEP_NAMES"))
        after = set(evidence["confirmed_steps"])
        self.assertEqual(len(before), 18)
        self.assertTrue(
            before.issubset(after), "the flip must only ADD to the confirmed set"
        )
        self.assertEqual(after - before, set(V.HELD_STEP_NAMES))

    def test_the_fingerprint_gains_the_four_pairs_and_keeps_the_eighteen(self):
        flipped = self.flipped()
        namespace: dict = {}
        exec(compile(flipped, "r2_vectors.py", "exec"), namespace)  # noqa: S102
        pinned = namespace["CONFIRMED_STEP_BYTES"]
        # the INPUT's own freeze is the baseline (see the note above): the
        # shipped table is already flipped, so measuring the transform's output
        # against it would ask a second flip to add four more pairs
        input_pinned = V._source_literal(self.source(), "CONFIRMED_STEP_BYTES")
        for name, pair in input_pinned.items():
            with self.subTest(step=name):
                self.assertEqual(tuple(pinned[name]), pair)
        self.assertEqual(
            len(pinned), len(input_pinned) + len(V.HELD_STEP_NAMES)
        )
        # the new pairs are the SHIPPED bytes, not invented ones
        on_disk = json.loads(V.SPEC.artifact.read_text(encoding="utf-8"))
        shipped = {
            step["name"]: (step["request_hex"], step["response_hex"])
            for vector in on_disk["vectors"]
            for step in vector["steps"]
        }
        for name in V.HELD_STEP_NAMES:
            with self.subTest(step=name):
                self.assertEqual(tuple(pinned[name]), shipped[name])

    def test_the_notice_is_generated_not_written(self):
        """A flipped module must still COMPUTE its notice, not carry one.

        The generator legitimately CONTAINS both wordings - that is how it can
        produce either - so "the partial wording is gone" is the wrong thing to
        assert (I wrote that first, and it fails for the right reason: the
        generator is supposed to be able to say it). The property is that the
        notice remains an EXPRESSION of the evidence, with no literal to go
        stale, and that the flip introduces none.
        """
        flipped = self.flipped()
        self.assertIn("PACKAGE_NOTICE = _notice(", flipped.replace("\n", " "))
        self.assertNotRegex(flipped, r"PACKAGE_NOTICE\s*=\s*\(")


class TestTheFlipRefusesToLaunderAByteChange(FlipHarness):
    """A flip is a statement about bytes, so it may not ride in on a byte edit.

    If a published step's bytes had already changed and someone then ran the
    flip, the new "confirmed" set would cover steps nobody re-ran. The flip
    therefore checks the fingerprint against a FRESH BUILD first, and refuses
    if they disagree.
    """

    def test_a_fingerprint_that_disagrees_with_a_fresh_build_is_refused(self):
        source = self.source()
        # perturb ONE published byte in the fingerprint
        original = V.CONFIRMED_STEP_BYTES["status_header"][0]
        broken = original[:-1] + ("0" if original[-1] != "0" else "1")
        tampered = source.replace(original, broken, 1)
        self.assertNotEqual(tampered, source, "the tamper must apply")
        with self.assertRaises(V.FlipRefused) as caught:
            V.flip_held_steps(tampered, cite=CITE, date=DATE)
        message = str(caught.exception).lower()
        self.assertIn("status_header", message)
        self.assertIn("byte", message)


class TestTheNoticeIsGeneratedFromTheFlags(unittest.TestCase):
    """The shipped notice must be an expression of the flag arithmetic."""

    def test_the_shipped_notice_is_the_generated_one(self):
        """The property that makes hand-writing pointless.

        Not "the text looks right" - the shipped notice must EQUAL what the
        generator produces from the current flags. Then a hand-edit is not a
        claim that can survive a build, and the F1 class cannot recur.
        """
        self.assertEqual(
            V.PACKAGE_NOTICE,
            V.notice_for(
                confirmed=len(V.CHIP_EVIDENCE["confirmed_steps"]),
                pending=V.CHIP_EVIDENCE["pending_steps"],
            ),
        )

    def test_the_shipped_notice_says_22_of_22_now_that_the_four_are_confirmed(self):
        """The state the flip produced, and the state the guard must police.

        This used to assert the PARTIAL wording (18 of the 22, four named).
        After a legitimate flip that assertion is not merely stale — it is wrong,
        and a test that kept it would be demanding the package lie. So the
        numbers now come from the evidence block, the same source the notice is
        generated from: the two cannot disagree, which is the entire point of
        generating one from the other.
        """
        confirmed = len(V.CHIP_EVIDENCE["confirmed_steps"])
        pending = tuple(V.CHIP_EVIDENCE["pending_steps"])
        self.assertEqual(pending, ())
        self.assertEqual(confirmed, 22)
        self.assertIn(f"all {confirmed} golden steps", V.PACKAGE_NOTICE)
        self.assertIn(f"({confirmed}/{confirmed})", V.PACKAGE_NOTICE)
        self.assertNotIn("NOT CHIP-CONFIRMED", V.PACKAGE_NOTICE)
        for name in V.HELD_STEP_NAMES:
            self.assertNotIn(name, V.PACKAGE_NOTICE,
                             "a confirmed step must not be listed as pending")

    def test_the_notice_generated_for_a_fully_confirmed_package_reads_right(self):
        """The other branch of the generator, which the flip will land on.

        Its wording is deliberately different from the partial one - "all 22"
        rather than "22 of the 22" - because a fully confirmed package is not a
        special case of a partial one, and phrasing it as a fraction would read
        as if something were still outstanding.
        """
        notice = V.notice_for(confirmed=22, pending=())
        self.assertIn("CHIP-CONFIRMED IN SIMULATION", notice)
        self.assertIn("all 22 golden steps", notice)
        self.assertIn("22/22", notice)
        self.assertNotIn("PARTIALLY", notice)
        self.assertNotIn("NOT CHIP-CONFIRMED", notice)
        # the hardware boundary survives every state of the flags
        self.assertIn("NOT HARDWARE-CONFIRMED", notice)

    def test_a_tampered_notice_cannot_survive_a_build(self):
        """There must be no hand-written notice literal left to go stale.

        The generator necessarily CONTAINS both wordings - that is how it can
        produce either - so the property to pin is that the module's notice is
        an expression of the evidence, not a string someone typed: the
        assignment calls the generator, and no literal `PACKAGE_NOTICE = (...)`
        survives anywhere in the source.
        """
        source = MODULE.read_text(encoding="utf-8").replace("\n", " ")
        self.assertIn("PACKAGE_NOTICE = _notice(", source)
        self.assertNotRegex(source, r"PACKAGE_NOTICE\s*=\s*\(")


if __name__ == "__main__":
    unittest.main(verbosity=2)
