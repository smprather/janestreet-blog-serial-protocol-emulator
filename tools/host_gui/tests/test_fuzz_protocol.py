"""Tests for the protocol fuzzer (plan Task 7 follow-up: hostile input).

The fuzzer itself is the test: running a bounded campaign against both frame
decoders and the chip-side model must find nothing. This module keeps the
campaign fast for the suite (a small, fixed seed) while the tool can be run
standalone with far more iterations. It also pins the determinism and the
bounded-runtime properties, and a couple of regressions the fuzzer surfaced.
"""

from __future__ import annotations

import unittest

from tools.host_gui import fuzz_protocol as Z
from tools.host_gui import protocol as P


class TestFuzzerFindsNothing(unittest.TestCase):
    def test_bounded_campaign_is_clean(self):
        report = Z.run(seed=Z.DEFAULT_SEED, iterations=150)
        self.assertTrue(report.ok, "\n".join(f.render()
                                            for f in report.findings))

    def test_campaign_is_deterministic_for_a_seed(self):
        first = Z.run(seed=99, iterations=40)
        second = Z.run(seed=99, iterations=40)
        self.assertEqual(first.to_dict()["counters"],
                         second.to_dict()["counters"])
        self.assertEqual(first.ok, second.ok)

    def test_campaign_exercises_every_hostile_class(self):
        report = Z.run(seed=1, iterations=30)
        for label in ("valid", "bitflip", "sync", "truncated", "extended",
                      "concatenated", "odd-length", "noise", "filler",
                      "chip-side"):
            with self.subTest(label=label):
                self.assertGreater(report.counters.get(label, 0), 0)

    def test_budget_overrun_is_reported_as_a_finding(self):
        report = Z.run(seed=1, iterations=30, budget_s=0.0)
        self.assertFalse(report.ok)
        self.assertTrue(any(f.kind.startswith("budget/") for f in report.findings))


class TestWaitWordContractBothCopies(unittest.TestCase):
    """The fuzzer found strip_wait_words living only in the bridge copy."""

    def test_host_protocol_has_the_wait_word_skip(self):
        for count in (0, 1, 15):
            raw = b"\xff\xff" * count + P.encode_frame(
                P.OP_PING, 7, P.TARGET_HOST, b"")
            with self.subTest(fillers=count):
                self.assertEqual(P.decode_frame(
                    P.strip_wait_words(raw)).sequence, 7)

    def test_over_the_bound_is_rejected_not_skipped(self):
        raw = b"\xff\xff" * 16 + P.encode_frame(P.OP_PING, 7, P.TARGET_HOST, b"")
        with self.assertRaises(P.FrameError):
            P.strip_wait_words(raw)

    def test_all_filler_is_rejected(self):
        with self.assertRaises(P.FrameError):
            P.strip_wait_words(b"\xff\xff" * 40)


if __name__ == "__main__":
    unittest.main(verbosity=2)
