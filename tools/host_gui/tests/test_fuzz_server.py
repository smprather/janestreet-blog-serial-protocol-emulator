"""Tests for the server/API fuzzer (hostile input above the wire).

The fuzzer itself is the test: a bounded campaign against the FastAPI/api
surface, the session state machine, a hostile bridge and concurrent requests
must find nothing. This module keeps the campaign fast for the suite while the
tool can be run standalone with far more iterations. It also pins the
determinism, bounded-runtime and coverage properties.
"""

from __future__ import annotations

import unittest

from tools.host_gui import fuzz_server as Z


class TestServerFuzzerFindsNothing(unittest.TestCase):
    def test_bounded_campaign_is_clean(self):
        report = Z.run(seed=Z.DEFAULT_SEED, iterations=20, rounds=3)
        self.assertTrue(report.ok, "\n".join(f.render()
                                            for f in report.findings))

    def test_campaign_is_deterministic_for_a_seed(self):
        # Concurrency finding *counts* depend on scheduling, but with a correct
        # transport the campaign outcome and coverage must be stable.
        first = Z.run(seed=99, iterations=12, rounds=2)
        second = Z.run(seed=99, iterations=12, rounds=2)
        self.assertEqual(first.ok, second.ok)
        self.assertEqual(sorted(first.counters), sorted(second.counters))

    def test_campaign_exercises_every_class(self):
        report = Z.run(seed=1, iterations=15, rounds=2)
        for label in ("state/connect", "state/load", "state/start",
                      "state/stop", "state/disconnect", "state/status",
                      "hostile/drop", "hostile/garbage", "hostile/wrong-id",
                      "storm/cycles", "concurrency/round"):
            with self.subTest(label=label):
                self.assertGreater(report.counters.get(label, 0), 0)

    def test_budget_overrun_is_reported_as_a_finding(self):
        report = Z.run(seed=1, iterations=5, rounds=1, budget_s=0.0)
        self.assertFalse(report.ok)
        self.assertTrue(any(f.kind.startswith("budget/")
                            for f in report.findings))


class TestRegressionsTheFuzzerFound(unittest.TestCase):
    """The two findings from the 2026-09-26 RED run (seed 20260926) are pinned
    by their own unit tests in test_session.py and test_transport.py; this
    module only confirms the fuzzer's invariants stay armed."""

    def test_hostile_bridge_never_leaves_the_session_loading(self):
        report = Z.run(seed=7, iterations=40, rounds=0)
        stuck = [f for f in report.findings if f.kind == "state/stuck-loading"]
        self.assertEqual(stuck, [])

    def test_concurrency_campaign_reports_nothing_on_a_healthy_bridge(self):
        report = Z.run(seed=11, iterations=5, rounds=4)
        unserialized = [f for f in report.findings
                        if f.kind == "concurrency/unserialized"]
        self.assertEqual(unserialized, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
