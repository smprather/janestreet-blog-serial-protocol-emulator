"""Tests for the portable R2 read verification package (chip-side spec).

The package is a generated artifact: `r2_vectors.build_package()` derives every
vector from the live `FakePE` model and the shared frame codec, and the
checked-in JSON must match a fresh build byte for byte. That makes it a
*contract* the chip-side R2 testbench can consume as golden values, and a
drift gate for the host at the same time.

Chip R2 is COMPLETE (2026-09-25): the chip repo's tb/tb_pe_ctrl_r2.v reports
per-vector PASS for all 15 golden steps, byte-exact including CRC, with the
model image loaded per vector (evidence: the chip repo's
reviews/2026-09-25/R2-READ-PATH-REVIEW.md). Steps therefore carry
`chip_confirmed: true` with a citation; a step with no citation stays false.
This confirms the RTL in SIMULATION - the real-board acceptance run is still
unexecuted and is not claimed.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from tools.host_gui import fake_pe as F
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
        # The 15 chip-proven steps are confirmed; the newly added ceiling /
        # zero-count vectors are NOT (the chip has not run them yet), so the
        # package-level flag is deliberately FALSE (partial) and the notice
        # must say what is and is not confirmed.
        confirmed = sum(1 for v in self.package["vectors"]
                        for s in v["steps"] if s["chip_confirmed"])
        self.assertEqual(confirmed, 15)
        self.assertFalse(self.package["chip_confirmed"])
        self.assertIn("chip-confirmed in simulation",
                      self.package["notice"].lower())
        # the honest boundary: simulation confirmed, hardware not
        self.assertIn("not hardware-confirmed",
                      self.package["notice"].lower())

    def test_every_vector_reports_its_confirmation_state(self):
        self.assertTrue(self.package["vectors"])
        for vector in self.package["vectors"]:
            with self.subTest(vector=vector["name"]):
                self.assertTrue(vector["obligation"].strip())
                self.assertTrue(vector["steps"])
                self.assertEqual(
                    vector["chip_confirmed"],
                    all(step["chip_confirmed"] for step in vector["steps"]))

    def test_every_confirmed_step_cites_chip_evidence(self):
        """A chip_confirmed=true step is only allowed WITH a citation."""
        cited = 0
        for vector in self.package["vectors"]:
            for step in vector["steps"]:
                with self.subTest(vector=vector["name"], step=step["name"]):
                    if step["chip_confirmed"]:
                        evidence = step["chip_evidence"]
                        self.assertIsNotNone(
                            evidence, "a confirmed step must cite evidence")
                        self.assertIn("R2-READ-PATH-REVIEW",
                                      evidence["review"])
                        self.assertIn("tb_pe_ctrl_r2", evidence["testbench"])
                        self.assertIn("15/15", evidence["conformance"])
                        self.assertIn("date", evidence)
                        # the citation must also say what it does NOT prove
                        self.assertIn("SIMULATION", evidence["scope"])
                        cited += 1
                    else:
                        self.assertIsNone(step.get("chip_evidence"))
        # the 15 chip-proven golden steps; the newer ceiling/zero vectors are
        # unconfirmed until the chip re-runs them.
        self.assertEqual(cited, 15)

    def test_no_step_is_confirmed_without_being_in_the_evidence_map(self):
        mapped = V.CHIP_EVIDENCE["confirmed_steps"]
        for vector in self.package["vectors"]:
            for step in vector["steps"]:
                with self.subTest(step=step["name"]):
                    self.assertEqual(step["chip_confirmed"],
                                     step["name"] in mapped)

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
        self.assertIn("chip-confirmed", text.lower())
        self.assertIn("low-word-first", text.lower())
        self.assertIn("R2-READ-VERIFICATION.json", text)


class TestReadmemhExport(unittest.TestCase):
    """The $readmemh export must be byte-identical to the JSON frames.

    The chip-side testbenches consume these .hex files directly, so this is the
    last translation step: if a hex stream ever diverged from the JSON frame,
    the TB would be asserting against a different protocol than the host. The
    check compares bytes, not strings.
    """

    @classmethod
    def setUpClass(cls):
        cls.package = V.build_package()
        cls.hex_dir = V.HEX_DIR
        cls.manifest = json.loads(
            (cls.hex_dir / "manifest.json").read_text(encoding="utf-8"))

    def _read_hex(self, path):
        # a $readmemh load is whitespace-insensitive; this mirrors that.
        return bytes.fromhex("".join(path.read_text(encoding="utf-8").split()))

    def test_manifest_covers_every_vector_and_step(self):
        self.assertEqual(len(self.manifest["vectors"]),
                         len(self.package["vectors"]))
        # package-level: partial (15 proven steps, newer ones unconfirmed)
        self.assertFalse(self.manifest["chip_confirmed"])
        for vector in self.manifest["vectors"]:
            with self.subTest(vector=vector["name"]):
                # a vector is confirmed iff all its steps are
                self.assertEqual(vector["chip_confirmed"],
                                 all(s["chip_confirmed"]
                                     for s in vector["steps"]))
                self.assertEqual(len(vector["steps"]),
                                 len(self.package["vectors"][
                                     [v["name"] for v in
                                      self.package["vectors"]]
                                     .index(vector["name"])]["steps"]))

    def test_hex_streams_round_trip_identical_to_the_json_bytes(self):
        for vector in self.manifest["vectors"]:
            source = next(v for v in self.package["vectors"]
                          if v["name"] == vector["name"])
            for index, step in enumerate(vector["steps"]):
                expected = source["steps"][index]
                with self.subTest(vector=vector["name"], step=step["name"]):
                    request = self._read_hex(self.hex_dir /
                                             step["request_file"])
                    response = self._read_hex(self.hex_dir /
                                              step["response_file"])
                    self.assertEqual(request, bytes.fromhex(
                        expected["request_hex"]))
                    self.assertEqual(response, bytes.fromhex(
                        expected["response_hex"]))

    def test_hex_streams_decode_as_the_same_frames(self):
        from tools.host_gui import protocol as P
        for vector in self.manifest["vectors"]:
            source = next(v for v in self.package["vectors"]
                          if v["name"] == vector["name"])
            for index, step in enumerate(vector["steps"]):
                request = P.decode_frame(self._read_hex(
                    self.hex_dir / step["request_file"]))
                response = P.decode_frame(self._read_hex(
                    self.hex_dir / step["response_file"]))
                with self.subTest(vector=vector["name"], step=step["name"]):
                    self.assertEqual(request.opcode,
                                     source["steps"][index]["opcode"])
                    self.assertEqual(list(response.payload), step[
                        "response_payload_words"])

    def test_hex_export_is_drift_checked(self):
        self.assertEqual(V.check_hex_export(), 0)

    def test_a_corrupted_hex_file_is_detected(self):
        victim = V.HEX_DIR / "full_width_debug_regs.read_cpu_full_width_regs.req.hex"
        original = victim.read_text(encoding="utf-8")
        try:
            victim.write_text(original.replace("a5", "a4", 1), encoding="utf-8")
            self.assertNotEqual(V.check_hex_export(), 0)
        finally:
            victim.write_text(original, encoding="utf-8")
        self.assertEqual(V.check_hex_export(), 0)   # restored

    def test_hex_readme_explains_readmemh_use(self):
        readme = (V.HEX_DIR / "README.md").read_text(encoding="utf-8")
        self.assertIn("$readmemh", readme)
        self.assertIn("chip-confirmed", readme.lower())
        self.assertIn("manifest.json", readme)


class TestModelImageShipsWithTheVectors(unittest.TestCase):
    """The package must ship the model image the vectors were made against.

    Without it, a data-path read proves only the framing, not the data
    (manager ruling 2026-09-25). These tests prove the image is present, that
    the hex image files decode to it, and - the point of the whole exercise -
    that re-running every step against a model rebuilt FROM THE SHIPPED IMAGE
    reproduces the shipped response bytes exactly.
    """

    @classmethod
    def setUpClass(cls):
        cls.package = V.build_package()
        cls.on_disk = json.loads(
            PACKAGE_JSON.read_text(encoding="utf-8"))
        cls.manifest = json.loads(
            (V.HEX_DIR / "manifest.json").read_text(encoding="utf-8"))

    def _read_hex(self, path):
        return bytes.fromhex("".join(path.read_text(encoding="utf-8").split()))

    def test_every_vector_and_step_references_a_shipped_image(self):
        images = self.on_disk["model_images"]
        self.assertTrue(images)
        for vector in self.on_disk["vectors"]:
            with self.subTest(vector=vector["name"]):
                self.assertIn(vector["model_image_id"], images)
                for step in vector["steps"]:
                    self.assertEqual(step["model_image_id"],
                                     vector["model_image_id"])

    def test_image_declares_imem_dmem_and_register_state(self):
        for image_id, image in self.on_disk["model_images"].items():
            with self.subTest(image=image_id):
                self.assertEqual(image["imem"]["words"], 1024)
                self.assertEqual(image["dmem"]["bytes"], 16)
                state = image["state"]
                for field in ("pc", "a", "x", "y", "insn", "timer", "run",
                              "faults", "words_written"):
                    self.assertIn(field, state)
                self.assertLess(state["pc"], 1 << F.ISA_PC_BITS)
                self.assertLess(state["a"], 1 << F.ISA_A_BITS)
                self.assertLess(state["x"], 1 << F.ISA_X_BITS)
                self.assertLess(state["y"], 1 << F.ISA_Y_BITS)
                self.assertLess(state["insn"], 1 << F.ISA_INSN_BITS)

    def test_vectors_regenerate_from_the_shipped_image_byte_identically(self):
        """The point of shipping the image: replay it and get the same bytes.

        Steps are replayed IN ORDER from the initial image, because a vector is
        a sequence (the lifecycle vector's first step latches the sticky fault
        its second step observes); the image is the state before step 1.
        """
        images = self.on_disk["model_images"]
        for vector in self.on_disk["vectors"]:
            image = images[vector["model_image_id"]]
            pe = V.load_model_from_image(image)     # the shipped initial state
            for step in vector["steps"]:
                with self.subTest(vector=vector["name"], step=step["name"]):
                    response = pe.exchange(bytes.fromhex(step["request_hex"]))
                    self.assertIsNotNone(response)
                    self.assertEqual(response.hex(), step["response_hex"])
                    self.assertEqual(pe.faults, step["model_faults"])

    def test_the_lifecycle_vector_is_stateful_from_its_image(self):
        # Guard the semantics: step 2 only makes sense after step 1 latched.
        vector = next(v for v in self.on_disk["vectors"]
                      if v["name"] == "read_range_fault_lifecycle")
        image = self.on_disk["model_images"][vector["model_image_id"]]
        self.assertEqual(image["state"]["faults"], 0)
        pe = V.load_model_from_image(image)
        pe.exchange(bytes.fromhex(vector["steps"][0]["request_hex"]))
        self.assertEqual(pe.faults & 0x0004, 0x0004)
        second = pe.exchange(bytes.fromhex(vector["steps"][1]["request_hex"]))
        self.assertEqual(second.hex(), vector["steps"][1]["response_hex"])

    def test_a_tampered_image_changes_the_data_the_vector_proves(self):
        image = json.loads(json.dumps(
            self.on_disk["model_images"]["v01-read_imem_bounded"]))
        image["imem"]["sparse"]["1"] = 0xDEAD       # not the shipped word
        pe = V.load_model_from_image(image)
        response = pe.exchange(bytes.fromhex(
            self.on_disk["vectors"][0]["steps"][0]["request_hex"]))
        self.assertNotEqual(response.hex(),
                            self.on_disk["vectors"][0]["steps"][0]["response_hex"])
    def test_imem_hex_file_decodes_to_the_shipped_image(self):
        image = self.manifest["model_images"][
            self.manifest["image_files"]["image_id"]]
        data = self._read_hex(V.HEX_DIR / self.manifest["image_files"]["imem_file"])
        self.assertEqual(len(data), 2 * image["imem"]["words"])
        fill = int(str(image["imem"]["fill"]), 0)
        words = [int.from_bytes(data[i:i + 2], "big")
                 for i in range(0, len(data), 2)]
        self.assertEqual(words[0], int(image["imem"]["sparse"]["0"]))
        self.assertEqual(words[1], int(image["imem"]["sparse"]["1"]))
        self.assertEqual(words[2], int(image["imem"]["sparse"]["2"]))
        self.assertEqual(words[500], fill)          # the fill default holds

    def test_dmem_hex_file_decodes_to_the_shipped_image(self):
        image = self.manifest["model_images"][
            self.manifest["image_files"]["image_id"]]
        data = self._read_hex(V.HEX_DIR / self.manifest["image_files"]["dmem_file"])
        self.assertEqual(len(data), image["dmem"]["bytes"])
        for address, byte in image["dmem"]["sparse"].items():
            self.assertEqual(data[int(address)], int(byte))

    def test_manifest_documents_the_load_procedure(self):
        self.assertIn("$readmemh", self.manifest["load_procedure"])
        readme = (V.HEX_DIR / "README.md").read_text(encoding="utf-8")
        self.assertIn("$readmemh", readme)
        self.assertIn("imem.hex", readme)
        self.assertIn("dmem.hex", readme)
        self.assertIn("chip-confirmed", readme.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
