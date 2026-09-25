"""Tests for the portable R2 read verification package (chip-side spec).

The package is a generated artifact: `r2_vectors.build_package()` derives every
vector from the live `FakePE` model and the shared frame codec, and the
checked-in JSON must match a fresh build byte for byte. That makes it a
*contract* the chip-side R2 testbench can consume as golden values, and a
drift gate for the host at the same time.

Still NOT chip-confirmed: these are the agreed expectations, not silicon
evidence. Every vector carries `chip_confirmed: false`.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from tools.host_gui import protocol as P
from tools.host_gui import r2_vectors as V

PACKAGE_JSON = (Path(__file__).resolve().parents[3] / "reviews" / "2026-09-25"
                / "R2-READ-VERIFICATION.json")
PACKAGE_README = (Path(__file__).resolve().parents[3] / "reviews" / "2026-09-25"
                  / "R2-READ-VERIFICATION.md")


class TestR2VectorPackage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.package = V.build_package()

    def test_package_declares_the_constants_and_the_flag(self):
        self.assertEqual(self.package["protocol"]["sync"], P.SYNC)
        self.assertEqual(self.package["protocol"]["version"], P.VERSION)
        self.assertEqual(self.package["protocol"]["crc"], "CRC-16/CCITT-FALSE")
        self.assertFalse(self.package["chip_confirmed"])
        self.assertIn("not chip-confirmed", self.package["notice"].lower())

    def test_every_vector_is_not_chip_confirmed(self):
        self.assertTrue(self.package["vectors"])
        for vector in self.package["vectors"]:
            with self.subTest(vector=vector["name"]):
                self.assertFalse(vector["chip_confirmed"])
                self.assertTrue(vector["obligation"].strip())
                self.assertTrue(vector["steps"])

    def test_every_step_carries_exact_framed_words(self):
        for vector in self.package["vectors"]:
            for step in vector["steps"]:
                with self.subTest(vector=vector["name"], step=step["name"]):
                    request = P.decode_frame(bytes.fromhex(step["request_hex"]))
                    response = P.decode_frame(bytes.fromhex(step["response_hex"]))
                    self.assertEqual(request.opcode, step["opcode"])
                    self.assertFalse(request.is_response)
                    self.assertTrue(response.is_response)
                    self.assertEqual(response.opcode,
                                     step["opcode"] | P.RESPONSE_BIT)
                    self.assertEqual(response.sequence, request.sequence)
                    self.assertEqual(list(response.payload),
                                     step["response_payload_words"])
                    self.assertEqual(response.payload[0], step["status"])

    def test_read_vectors_use_low_word_first_ascending_order(self):
        vectors = {v["name"]: v for v in self.package["vectors"]}
        read_imem = vectors["read_imem_bounded"]
        self.assertEqual(read_imem["steps"][-1]["request_payload_words"],
                         [1, 2])
        self.assertEqual(read_imem["steps"][-1]["response_payload_words"],
                         [P.STATUS_OK, 0x1001, 0x4002])
        self.assertEqual(read_imem["word_order"], "low-word-first ascending")

    def test_lifecycle_vector_covers_sticky_fault_and_clear(self):
        vectors = {v["name"]: v for v in self.package["vectors"]}
        lifecycle = vectors["read_range_fault_lifecycle"]
        statuses = [step["status"] for step in lifecycle["steps"]]
        self.assertIn(P.STATUS_RANGE, statuses)
        faults_after_bad_read = next(
            step for step in lifecycle["steps"]
            if step["name"] == "status_shows_sticky_fault")
        self.assertEqual(faults_after_bad_read["model_faults"], 0x0004)
        cleared = lifecycle["steps"][-1]
        self.assertEqual(cleared["name"], "clear_fault_clears_the_bit")
        self.assertEqual(cleared["response_payload_words"][1], 0)

    def test_obligations_cover_every_r2_read_obligation(self):
        from tools.host_gui import r2_reads as R
        names = {v["name"] for v in self.package["vectors"]}
        for obligation in R.OBLIGATIONS:
            with self.subTest(obligation=obligation.name):
                self.assertIn(obligation.name, names)

    def test_checked_in_json_matches_a_fresh_build(self):
        # Drift gate: regenerate and compare. A model or codec change that is
        # not reflected in the artifact fails here, so the chip-side spec can
        # never silently disagree with the host.
        self.assertTrue(PACKAGE_JSON.is_file(), f"missing {PACKAGE_JSON}")
        self.assertEqual(json.loads(PACKAGE_JSON.read_text(encoding="utf-8")),
                         self.package)

    def test_check_mode_passes_on_this_tree(self):
        self.assertEqual(V.main(["--check"]), 0)

    def test_readme_exists_and_states_the_status(self):
        self.assertTrue(PACKAGE_README.is_file(), f"missing {PACKAGE_README}")
        text = PACKAGE_README.read_text(encoding="utf-8")
        self.assertIn("not chip-confirmed", text.lower())
        self.assertIn("low-word-first", text.lower())
        self.assertIn("R2-READ-VERIFICATION.json", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
