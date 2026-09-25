"""Tests for the soak runner: the analysis is pure, the run is bounded.

The analysis must call a flat footprint bounded, a rising RSS a leak, and a
rising live-object count a leak, without mistaking initial warmup for growth.
A short real run keeps the runner itself honest (it cycles, samples and
returns a verdict) at smoke speed.
"""

from __future__ import annotations

import unittest

from tools.host_gui import soak_host as Z


def samples_with(rss_mb, objects=None, span_s=60.0):
    count = len(rss_mb)
    objs = objects if objects is not None else [1_000] * count
    step = span_s / max(1, count - 1)
    return [
        (step * index, index + 1, int(mb * 1e6), objs[index])
        for index, mb in enumerate(rss_mb)
    ]


class TestSummarize(unittest.TestCase):
    def test_flat_footprint_is_bounded(self):
        summary = Z.summarize(samples_with([50.0] * 12))
        self.assertTrue(summary["ok"])
        self.assertEqual(summary["verdict"], "bounded")
        self.assertLess(abs(summary["growth_mb"]), 0.1)

    def test_rss_growth_is_a_leak(self):
        summary = Z.summarize(
            samples_with([50.0, 50.1, 51.0, 53.0, 56.0, 60.0]), max_growth_mb=4.0
        )
        self.assertFalse(summary["ok"])
        self.assertEqual(summary["verdict"], "leak")
        self.assertGreater(summary["growth_mb"], 4.0)

    def test_gc_object_growth_is_a_leak(self):
        summary = Z.summarize(
            samples_with(
                [50.0] * 8, objects=[1000, 1000, 1200, 2000, 4000, 8000, 16000, 32000]
            ),
            max_object_growth=1000,
        )
        self.assertFalse(summary["ok"])
        self.assertGreater(summary["object_growth"], 1000)

    def test_initial_warmup_peak_is_not_growth(self):
        # A first-allocation spike followed by a flat line: the baseline is the
        # min of the warmup quarter, so the spike must not read as a leak.
        summary = Z.summarize(
            samples_with([50.0, 62.0, 52.0, 51.0, 51.0, 51.0, 51.0, 51.0])
        )
        self.assertTrue(summary["ok"])
        self.assertLess(summary["growth_mb"], 1.5)

    def test_short_run_is_insufficient_not_a_finding(self):
        summary = Z.summarize([(0.0, 1, 50_000_000, None), (5.0, 2, 50_000_000, None)])
        self.assertEqual(summary["verdict"], "insufficient")
        self.assertTrue(summary["ok"])


class TestProbes(unittest.TestCase):
    def test_rss_bytes_is_positive(self):
        self.assertGreater(Z.rss_bytes(), 0)

    def test_gc_object_count_is_positive(self):
        self.assertGreater(Z.gc_object_count(), 0)


class TestSmokeRun(unittest.TestCase):
    def test_short_soak_cycles_samples_and_returns(self):
        result = Z.run(
            minutes=0.0,
            cycles=40,
            sample_every=5,
            sample_seconds=100.0,
            reconnect_every=15,
            assemble_every=1000,
            hostile_every=20,
            fuzz_every=25,
        )
        self.assertEqual(result["cycles"], 40)
        self.assertGreater(len(result["samples"]), 2)
        # 40 fast cycles cannot judge memory (span < 20 s) - explicit, not a pass
        self.assertEqual(result["summary"]["verdict"], "insufficient")
        self.assertTrue(result["ok"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
