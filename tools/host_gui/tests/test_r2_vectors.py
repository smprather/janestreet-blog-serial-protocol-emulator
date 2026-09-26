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

PACKAGE_JSON = (
    Path(__file__).resolve().parents[3]
    / "reviews"
    / "2026-09-25"
    / "R2-READ-VERIFICATION.json"
)
PACKAGE_README = (
    Path(__file__).resolve().parents[3]
    / "reviews"
    / "2026-09-25"
    / "R2-READ-VERIFICATION.md"
)

# The 18 chip-confirmed steps, pinned byte for byte: (request, response).
#
# These bytes ARE the R2 acceptance spec -- the chip's tb_pe_ctrl_r2.v drives
# the request streams and compares the responses, and the manager's standing
# order for the held-core work is that adding steps must NOT perturb them. A
# fingerprint is the only thing that turns "keep the existing steps
# byte-identical" from an intention into a gate: new vectors are allowed, a
# changed byte is not. Updating this table is a REVIEW decision (the chip has
# to re-run and re-confirm), never a way to make a failing build green.
# The freeze and the held-step list live in the MODULE, beside the evidence
# they are a statement about, because the flag-flip has to extend them
# atomically with the flags (see r2_vectors.flip_held_steps). One source: a
# table here and a table there would be two things to keep in step, and this
# one has to survive a real flip.
CONFIRMED_STEP_BYTES = V.CONFIRMED_STEP_BYTES

# The held-core steps added after the R3 debug work, and the state each one
# asserts. The chip has not re-run tb_pe_ctrl_r2 against them, so they ship
# unconfirmed -- the names are pinned so a test can require every one of them
# to still be named in the notice.
HELD_STEPS = V.HELD_STEP_NAMES


def confirmed_now() -> set[str]:
    """The confirmed set, from the evidence block the flip maintains.

    Every state-dependent assertion below reads this instead of a literal, so
    the suite is correct on both sides of a flip. A test that hard-codes "18
    of 22" is not a stronger claim than one that reads the number and checks
    the claim against it - it is a claim that goes stale on the next flip and
    then demands the package lie to satisfy it.
    """
    return set(V.CHIP_EVIDENCE["confirmed_steps"])


def pending_now() -> tuple[str, ...]:
    return tuple(V.CHIP_EVIDENCE["pending_steps"])


class TestR2VectorPackage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.package = V.build_package()

    def test_package_declares_the_constants_and_the_flag(self):
        self.assertEqual(self.package["protocol"]["sync"], P.SYNC)
        self.assertEqual(self.package["protocol"]["version"], P.VERSION)
        self.assertEqual(self.package["protocol"]["crc"], "CRC-16/CCITT-FALSE")
        # The 18 read-path steps are chip-proven byte-exact; the held-core
        # steps added after the R3 debug work are NOT (the chip has not re-run
        # tb_pe_ctrl_r2 against them), so the package-level flag is
        # deliberately FALSE (partial) and the notice must say which steps are
        # confirmed and which are not.
        confirmed = sum(
            1 for v in self.package["vectors"] for s in v["steps"] if s["chip_confirmed"]
        )
        self.assertEqual(confirmed, len(V.CONFIRMED_STEP_BYTES))
        self.assertEqual(self.package["chip_confirmed"], not pending_now(),
                         "the package-level flag IS the pending set being empty")
        self.assertIn("chip-confirmed in simulation", self.package["notice"].lower())
        # the honest boundary: simulation confirmed, hardware not
        self.assertIn("not hardware-confirmed", self.package["notice"].lower())

    def test_every_vector_reports_its_confirmation_state(self):
        self.assertTrue(self.package["vectors"])
        for vector in self.package["vectors"]:
            with self.subTest(vector=vector["name"]):
                self.assertTrue(vector["obligation"].strip())
                self.assertTrue(vector["steps"])
                self.assertEqual(
                    vector["chip_confirmed"],
                    all(step["chip_confirmed"] for step in vector["steps"]),
                )

    def test_every_confirmed_step_cites_chip_evidence(self):
        """A chip_confirmed=true step is only allowed WITH a citation."""
        cited = 0
        for vector in self.package["vectors"]:
            for step in vector["steps"]:
                with self.subTest(vector=vector["name"], step=step["name"]):
                    if step["chip_confirmed"]:
                        evidence = step["chip_evidence"]
                        self.assertIsNotNone(
                            evidence, "a confirmed step must cite evidence"
                        )
                        self.assertIn("R2-READ-PATH-REVIEW", evidence["review"])
                        self.assertIn("tb_pe_ctrl_r2", evidence["testbench"])
                        confirmed = len(V.CHIP_EVIDENCE["confirmed_steps"])
                        self.assertIn(f"{confirmed}/{confirmed}", evidence["conformance"])
                        self.assertIn("date", evidence)
                        # the citation must also say what it does NOT prove
                        self.assertIn("SIMULATION", evidence["scope"])
                        cited += 1
                    else:
                        self.assertIsNone(step.get("chip_evidence"))
        # all 18 golden steps are now chip-proven byte-exact
        self.assertEqual(cited, len(V.CONFIRMED_STEP_BYTES))

    def test_no_step_is_confirmed_without_being_in_the_evidence_map(self):
        mapped = V.CHIP_EVIDENCE["confirmed_steps"]
        for vector in self.package["vectors"]:
            for step in vector["steps"]:
                with self.subTest(step=step["name"]):
                    self.assertEqual(step["chip_confirmed"], step["name"] in mapped)

    def test_every_step_carries_exact_framed_words(self):
        for vector in self.package["vectors"]:
            for step in vector["steps"]:
                with self.subTest(vector=vector["name"], step=step["name"]):
                    request = P.decode_frame(bytes.fromhex(step["request_hex"]))
                    response = P.decode_frame(bytes.fromhex(step["response_hex"]))
                    self.assertEqual(request.opcode, step["opcode"])
                    self.assertFalse(request.is_response)
                    self.assertTrue(response.is_response)
                    self.assertEqual(response.opcode, step["opcode"] | P.RESPONSE_BIT)
                    self.assertEqual(response.sequence, request.sequence)
                    self.assertEqual(
                        list(response.payload), step["response_payload_words"]
                    )
                    self.assertEqual(response.payload[0], step["status"])

    def test_read_vectors_use_low_word_first_ascending_order(self):
        vectors = {v["name"]: v for v in self.package["vectors"]}
        read_imem = vectors["read_imem_bounded"]
        self.assertEqual(read_imem["steps"][-1]["request_payload_words"], [1, 2])
        self.assertEqual(
            read_imem["steps"][-1]["response_payload_words"],
            [P.STATUS_OK, 0x1001, 0x4002],
        )
        self.assertEqual(read_imem["word_order"], "low-word-first ascending")

    def test_lifecycle_vector_covers_sticky_fault_and_clear(self):
        vectors = {v["name"]: v for v in self.package["vectors"]}
        lifecycle = vectors["read_range_fault_lifecycle"]
        statuses = [step["status"] for step in lifecycle["steps"]]
        self.assertIn(P.STATUS_RANGE, statuses)
        faults_after_bad_read = next(
            step
            for step in lifecycle["steps"]
            if step["name"] == "status_shows_sticky_fault"
        )
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
        self.assertEqual(
            json.loads(PACKAGE_JSON.read_text(encoding="utf-8")), self.package
        )

    def test_the_fresh_build_is_already_json_shaped(self):
        """The build must survive a JSON round trip UNCHANGED.

        The artifact is a JSON document and the drift gate compares the parsed
        document to a fresh build, so a `tuple` anywhere in the build makes the
        gate report STALE immediately after `--write` and can never be
        satisfied -- and it does so with a message ("regenerate with --write")
        that points at the wrong fix. `evidence_json` already normalised
        `confirmed_steps` for exactly this reason and the trap waited for the
        next field. This test names the invariant at the point it bites.
        """
        self.assertEqual(
            json.loads(json.dumps(self.package, sort_keys=True)), self.package
        )

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
            (cls.hex_dir / "manifest.json").read_text(encoding="utf-8")
        )

    def _read_hex(self, path):
        # a $readmemh load is whitespace-insensitive; this mirrors that.
        return bytes.fromhex("".join(path.read_text(encoding="utf-8").split()))

    def test_manifest_covers_every_vector_and_step(self):
        self.assertEqual(len(self.manifest["vectors"]), len(self.package["vectors"]))
        # package-level: PARTIAL. 18 read-path steps are confirmed; the
        # held-core steps added after R3 await a chip re-run, and a manifest
        # that said otherwise would be the field a chip TB reads first.
        self.assertEqual(self.manifest["chip_confirmed"], not pending_now())
        for vector in self.manifest["vectors"]:
            with self.subTest(vector=vector["name"]):
                # a vector is confirmed iff all its steps are
                self.assertEqual(
                    vector["chip_confirmed"],
                    all(s["chip_confirmed"] for s in vector["steps"]),
                )
                self.assertEqual(
                    len(vector["steps"]),
                    len(
                        self.package["vectors"][
                            [v["name"] for v in self.package["vectors"]].index(
                                vector["name"]
                            )
                        ]["steps"]
                    ),
                )

    def test_hex_streams_round_trip_identical_to_the_json_bytes(self):
        for vector in self.manifest["vectors"]:
            source = next(
                v for v in self.package["vectors"] if v["name"] == vector["name"]
            )
            for index, step in enumerate(vector["steps"]):
                expected = source["steps"][index]
                with self.subTest(vector=vector["name"], step=step["name"]):
                    request = self._read_hex(self.hex_dir / step["request_file"])
                    response = self._read_hex(self.hex_dir / step["response_file"])
                    self.assertEqual(request, bytes.fromhex(expected["request_hex"]))
                    self.assertEqual(response, bytes.fromhex(expected["response_hex"]))

    def test_hex_streams_decode_as_the_same_frames(self):
        from tools.host_gui import protocol as P

        for vector in self.manifest["vectors"]:
            source = next(
                v for v in self.package["vectors"] if v["name"] == vector["name"]
            )
            for index, step in enumerate(vector["steps"]):
                request = P.decode_frame(
                    self._read_hex(self.hex_dir / step["request_file"])
                )
                response = P.decode_frame(
                    self._read_hex(self.hex_dir / step["response_file"])
                )
                with self.subTest(vector=vector["name"], step=step["name"]):
                    self.assertEqual(request.opcode, source["steps"][index]["opcode"])
                    self.assertEqual(
                        list(response.payload), step["response_payload_words"]
                    )

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
        self.assertEqual(V.check_hex_export(), 0)  # restored

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
        cls.on_disk = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))
        cls.manifest = json.loads(
            (V.HEX_DIR / "manifest.json").read_text(encoding="utf-8")
        )

    def _read_hex(self, path):
        return bytes.fromhex("".join(path.read_text(encoding="utf-8").split()))

    def test_every_vector_and_step_references_a_shipped_image(self):
        images = self.on_disk["model_images"]
        self.assertTrue(images)
        for vector in self.on_disk["vectors"]:
            with self.subTest(vector=vector["name"]):
                self.assertIn(vector["model_image_id"], images)
                for step in vector["steps"]:
                    self.assertEqual(step["model_image_id"], vector["model_image_id"])

    def test_image_declares_imem_dmem_and_register_state(self):
        for image_id, image in self.on_disk["model_images"].items():
            with self.subTest(image=image_id):
                self.assertEqual(image["imem"]["words"], 1024)
                self.assertEqual(image["dmem"]["bytes"], 16)
                state = image["state"]
                for field in (
                    "pc",
                    "a",
                    "x",
                    "y",
                    "insn",
                    "timer",
                    "run",
                    "faults",
                    "words_written",
                ):
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
            pe = V.load_model_from_image(image)  # the shipped initial state
            for step in vector["steps"]:
                with self.subTest(vector=vector["name"], step=step["name"]):
                    response = pe.exchange(bytes.fromhex(step["request_hex"]))
                    if response is None:
                        self.fail(f"no response for {step['name']}")
                    self.assertEqual(response.hex(), step["response_hex"])
                    self.assertEqual(pe.faults, step["model_faults"])

    def test_the_lifecycle_vector_is_stateful_from_its_image(self):
        # Guard the semantics: step 2 only makes sense after step 1 latched.
        vector = next(
            v
            for v in self.on_disk["vectors"]
            if v["name"] == "read_range_fault_lifecycle"
        )
        image = self.on_disk["model_images"][vector["model_image_id"]]
        self.assertEqual(image["state"]["faults"], 0)
        pe = V.load_model_from_image(image)
        pe.exchange(bytes.fromhex(vector["steps"][0]["request_hex"]))
        self.assertEqual(pe.faults & 0x0004, 0x0004)
        second = pe.exchange(bytes.fromhex(vector["steps"][1]["request_hex"]))
        if second is None:
            self.fail("no response for the status step")
        self.assertEqual(second.hex(), vector["steps"][1]["response_hex"])

    def test_a_tampered_image_changes_the_data_the_vector_proves(self):
        image = json.loads(
            json.dumps(self.on_disk["model_images"]["v01-read_imem_bounded"])
        )
        image["imem"]["sparse"]["1"] = 0xDEAD  # not the shipped word
        pe = V.load_model_from_image(image)
        response = pe.exchange(
            bytes.fromhex(self.on_disk["vectors"][0]["steps"][0]["request_hex"])
        )
        if response is None:
            self.fail("no response for the tampered-image read")
        self.assertNotEqual(
            response.hex(), self.on_disk["vectors"][0]["steps"][0]["response_hex"]
        )

    def test_imem_hex_file_decodes_to_the_shipped_image(self):
        image = self.manifest["model_images"][self.manifest["image_files"]["image_id"]]
        data = self._read_hex(V.HEX_DIR / self.manifest["image_files"]["imem_file"])
        self.assertEqual(len(data), 2 * image["imem"]["words"])
        fill = int(str(image["imem"]["fill"]), 0)
        words = [int.from_bytes(data[i : i + 2], "big") for i in range(0, len(data), 2)]
        self.assertEqual(words[0], int(image["imem"]["sparse"]["0"]))
        self.assertEqual(words[1], int(image["imem"]["sparse"]["1"]))
        self.assertEqual(words[2], int(image["imem"]["sparse"]["2"]))
        self.assertEqual(words[500], fill)  # the fill default holds

    def test_dmem_hex_file_decodes_to_the_shipped_image(self):
        image = self.manifest["model_images"][self.manifest["image_files"]["image_id"]]
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


class TestTheConfirmedBytesArePinned(unittest.TestCase):
    """The 18 confirmed steps are the chip's acceptance spec: byte-frozen.

    The held-core work adds steps to this package, and the standing order is
    that it adds them WITHOUT touching the existing bytes. A count cannot
    prove that -- adding a step leaves every count right -- so the bytes
    themselves are pinned here.
    """

    @classmethod
    def setUpClass(cls):
        cls.package = V.build_package()
        cls.steps = {
            step["name"]: (step["request_hex"], step["response_hex"])
            for vector in cls.package["vectors"]
            for step in vector["steps"]
        }

    def test_the_eighteen_confirmed_steps_are_byte_identical(self):
        for name, (request, response) in sorted(CONFIRMED_STEP_BYTES.items()):
            with self.subTest(step=name):
                self.assertIn(name, self.steps)
                self.assertEqual(self.steps[name], (request, response))

    def test_the_pinned_set_is_exactly_the_confirmed_set(self):
        """Confirmation and the fingerprint move together, or not at all.

        Without this, a new step could be added to CHIP_EVIDENCE and the
        fingerprint would keep passing -- the test would pin the old bytes
        while the package quietly claimed a new one is proven.
        """
        confirmed = {
            step["name"]
            for vector in self.package["vectors"]
            for step in vector["steps"]
            if step["chip_confirmed"]
        }
        self.assertEqual(confirmed, set(CONFIRMED_STEP_BYTES))

    def test_no_confirmed_step_was_silently_renamed(self):
        """A rename changes the golden filename the chip's step table names."""
        for name in CONFIRMED_STEP_BYTES:
            with self.subTest(step=name):
                self.assertTrue(
                    (V.HEX_DIR / f"status_while_step_paused.{name}.req.hex").exists()
                    or any(
                        path.name.endswith(f".{name}.req.hex")
                        for path in V.HEX_DIR.glob("*.req.hex")
                    )
                )


class TestTheHeldCoreStatusSteps(unittest.TestCase):
    """R2's STATUS/DUMP_CORE while the core is HELD at a breakpoint.

    The chip's R3 debug work made the R2 readback surface reachable in states
    2 (DEBUG_HOLD, a step-pause) and 3 (BP_HIT, a live hit) -- and the R2
    golden package never exercised either, so a chip that was right on the
    normal states and wrong on the held ones passed 18/18. These steps close
    that, with the expectations taken from the frozen contract semantics
    rather than from a wish:

      * the state word is `dbg_hold ? (bp_hit ? 3 : 2) : (run ? 1 : 0)`, so
        only a HOLD can produce 2/3 and the hit is what separates them;
      * the `run` word is the STRAP, not the state: a hit HOLDS the core, it
        does not drop the strap, so state 3 arrives with run=1;
      * DUMP_CORE is gated on the raw `run` strap (pe_ctrl: `if (run)`), so a
        live hit -- strap still high -- is answered NOT_READY even though the
        core is stopped, while a step-pause with the strap low answers the
        full 11-word header.

    Every step here ships `chip_confirmed: false`: the chip has not re-run
    tb_pe_ctrl_r2 against these bytes, so they are a gate, not evidence.
    """

    @classmethod
    def setUpClass(cls):
        cls.package = V.build_package()
        cls.on_disk = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))
        cls.by_vector = {v["name"]: v for v in cls.on_disk["vectors"]}
        cls.images = cls.on_disk["model_images"]

    def _steps(self, vector_name):
        vector = self.by_vector[vector_name]
        return {step["name"]: step for step in vector["steps"]}

    def test_both_held_vectors_are_shipped_with_two_steps_each(self):
        for name in ("status_while_step_paused", "status_while_bp_hit"):
            with self.subTest(vector=name):
                vector = self.by_vector[name]
                self.assertEqual(
                    sorted(s["name"] for s in vector["steps"]),
                    sorted(s for s in HELD_STEPS if s in self._steps(name)),
                )
                self.assertEqual(len(vector["steps"]), 2)
                self.assertIn(vector["model_image_id"], self.images)
                self.assertEqual(vector["chip_confirmed"],
                                 not pending_now())

    def test_the_step_pause_reports_state_two_with_the_strap_still_low(self):
        step = self._steps("status_while_step_paused")["status_reports_the_hold"]
        self.assertEqual(step["opcode_name"], "OP_STATUS")
        self.assertEqual(step["status"], P.STATUS_OK)
        payload = step["response_payload_words"]
        self.assertEqual(payload[0], P.STATUS_OK)
        self.assertEqual(payload[1], F.DEBUG_HOLD)
        self.assertEqual(payload[2], 0, "the step-pause leaves the strap LOW")

    def test_the_live_hit_reports_state_three_with_the_strap_still_high(self):
        step = self._steps("status_while_bp_hit")["status_reports_the_hit"]
        self.assertEqual(step["opcode_name"], "OP_STATUS")
        self.assertEqual(step["status"], P.STATUS_OK)
        payload = step["response_payload_words"]
        self.assertEqual(payload[0], P.STATUS_OK)
        self.assertEqual(payload[1], F.DEBUG_BP_HIT)
        # The point of the whole step: the hit holds the CORE, not the strap.
        self.assertEqual(payload[2], 1, "a live hit must not drop the run strap")
        self.assertEqual(payload[4], 2, "the PC rests on the armed breakpoint")

    def test_dump_core_answers_the_same_header_while_the_strap_is_low(self):
        steps = self._steps("status_while_step_paused")
        dump = steps["dump_core_answers_the_same_header"]
        status = steps["status_reports_the_hold"]
        self.assertEqual(dump["opcode_name"], "OP_DUMP_CORE")
        self.assertEqual(dump["status"], P.STATUS_OK)
        # The R2 obligation restated under a hold: the two headers agree, and
        # the state word inside them says the hold is why the core is stopped.
        self.assertEqual(dump["response_payload_words"], status["response_payload_words"])
        self.assertEqual(dump["response_payload_words"][1], F.DEBUG_HOLD)

    def test_dump_core_is_refused_under_a_live_hit(self):
        """The gate is the STRAP, so a held-but-strapped core still refuses.

        A chip that gated DUMP_CORE on the debug state (or on the hold) would
        answer the full header here and pass every other R2 step; this is the
        step that separates the two readings.
        """
        dump = self._steps("status_while_bp_hit")["dump_core_refused_the_strap_is_high"]
        self.assertEqual(dump["opcode_name"], "OP_DUMP_CORE")
        self.assertEqual(dump["status"], P.STATUS_NOT_READY)
        self.assertEqual(dump["response_payload_words"], [P.STATUS_NOT_READY])
        # a refusal is not a fault: the sticky register must be untouched
        self.assertEqual(dump["model_faults"], 0)

    def test_the_held_images_are_states_a_real_core_can_reach(self):
        """Derive both pre-states by EXECUTING the shipped program.

        The chip review's M2 finding was a conformance TB preloading states the
        RTL cannot reach. An unreachable pre-state proves nothing, so neither
        image is asserted here: both are reproduced from the model driving the
        image the package actually ships.
        """
        program = dict(self.images["v01-read_imem_bounded"]["imem"]["sparse"])

        def load(pe):
            """The shipped 3-word program (imem keys are strings, values int)."""
            for address, word in program.items():
                pe.imem[int(address)] = int(word)
            return pe

        # ONE step from the boot stop: imem[0] (LDI A,0x41) retires and the
        # core pauses at 1, breakpoint armed at 2 and not yet hit.
        stepped = load(F.FakePE())
        stepped.bp_addr, stepped.bp_en = 2, True
        stepped.debug_step_once()
        self.assertEqual((stepped.pc, stepped.a, stepped.state), (1, 0x41, F.DEBUG_HOLD))
        pause = self.images["v09-status_while_step_paused"]
        self.assertEqual(pause["state"]["pc"], stepped.pc)
        self.assertEqual(pause["state"]["a"], stepped.a)
        self.assertEqual(pause["state"]["run"], 0)
        self.assertEqual(
            pause["debug"],
            {"bp_addr": 2, "bp_en": True, "bp_hit": False, "debug_hold": True},
        )

        # The SAME program free-running with the strap high: the core stops ON
        # the breakpoint, the hit latches, and the strap stays high.
        live = load(F.FakePE())
        live.bp_addr, live.bp_en = 2, True
        live.set_run(True)
        self.assertTrue(live.advance_free_running())
        self.assertEqual(
            (live.pc, live.a, live.state, int(live.run)), (2, 0x41, F.DEBUG_BP_HIT, 1)
        )
        hit = self.images["v10-status_while_bp_hit"]
        self.assertEqual(hit["state"]["pc"], live.pc)
        self.assertEqual(hit["state"]["a"], live.a)
        self.assertEqual(hit["state"]["run"], 1)
        self.assertEqual(
            hit["debug"],
            {"bp_addr": 2, "bp_en": True, "bp_hit": True, "debug_hold": True},
        )

    def test_the_held_steps_are_unconfirmed_and_cite_nothing(self):
        for name in HELD_STEPS:
            with self.subTest(step=name):
                step = next(
                    s
                    for v in self.package["vectors"]
                    for s in v["steps"]
                    if s["name"] == name
                )
                self.assertEqual(step["chip_confirmed"],
                                 name in confirmed_now())
                if step["chip_confirmed"]:
                    self.assertIsNotNone(step.get("chip_evidence"))
                else:
                    self.assertIsNone(step.get("chip_evidence"))

    def test_the_held_steps_replay_from_the_shipped_image(self):
        """The golden bytes are regenerable from the shipped image alone."""
        for vector_name in ("status_while_step_paused", "status_while_bp_hit"):
            vector = self.by_vector[vector_name]
            pe = V.load_model_from_image(self.images[vector["model_image_id"]])
            for step in vector["steps"]:
                with self.subTest(vector=vector_name, step=step["name"]):
                    response = pe.exchange(bytes.fromhex(step["request_hex"]))
                    if response is None:
                        self.fail(f"no response for {step['name']}")
                    self.assertEqual(response.hex(), step["response_hex"])

    def test_the_hex_export_ships_the_held_steps(self):
        manifest = json.loads((V.HEX_DIR / "manifest.json").read_text(encoding="utf-8"))
        shipped = {
            step["name"]: step
            for vector in manifest["vectors"]
            for step in vector["steps"]
        }
        for name in HELD_STEPS:
            with self.subTest(step=name):
                self.assertIn(name, shipped)
                self.assertEqual(shipped[name]["chip_confirmed"],
                                 name in confirmed_now())
                if shipped[name]["chip_confirmed"]:
                    self.assertIsNotNone(shipped[name]["chip_evidence"])
                else:
                    self.assertIsNone(shipped[name]["chip_evidence"])
                for key in ("request_file", "response_file"):
                    self.assertTrue((V.HEX_DIR / shipped[name][key]).is_file())


class TestTheNoticeMatchesTheFlagArithmetic(unittest.TestCase):
    """The notice is the field a tapeout reader opens first; keep it true.

    The R3 review found a shipped notice claiming the opposite of the flags in
    the same file, and the drift gate STRUCTURALLY cannot catch that: the
    notice and the flags come from the same source, so a fresh build
    faithfully reproduces the same stale prose. This is that guard for R2.
    """

    @classmethod
    def setUpClass(cls):
        cls.package = V.build_package()
        cls.notice = cls.package["notice"]
        cls.confirmed = [
            step["name"]
            for vector in cls.package["vectors"]
            for step in vector["steps"]
            if step["chip_confirmed"]
        ]
        cls.unconfirmed = [
            step["name"]
            for vector in cls.package["vectors"]
            for step in vector["steps"]
            if not step["chip_confirmed"]
        ]

    def test_the_confirmed_and_unconfirmed_counts_are_stated(self):
        # derived, not literal: these numbers move when the chip confirms more
        # steps, and a test that hard-codes them goes stale on the next flip
        # and then insists the package misreport itself
        self.assertEqual(set(self.confirmed), confirmed_now())
        self.assertEqual(sorted(self.unconfirmed), sorted(pending_now()))
        total = len(self.confirmed) + len(self.unconfirmed)
        self.assertIn(f"{len(self.confirmed)}/{len(self.confirmed)}",
                      self.notice)
        if self.unconfirmed:
            self.assertIn(f"{len(self.confirmed)} of the {total}", self.notice)
        else:
            self.assertIn(f"all {total} golden steps", self.notice)

    def test_every_unconfirmed_step_is_named(self):
        for name in self.unconfirmed:
            with self.subTest(step=name):
                self.assertIn(name, self.notice)

    def test_the_notice_makes_none_of_the_contradicted_claims(self):
        """Forbid the claims that would be FALSE in the CURRENT state.

        A claim list written for one state becomes wrong the moment the state
        moves: the full-case notice says "all 22 golden steps ... pass" BY
        DESIGN once nothing is pending, and a list that forbade that phrase
        would be demanding the package understate itself. So the overstatement
        clause is conditional, and the two phrasings that are false in BOTH
        states stay unconditional.
        """
        lowered = self.notice.lower()
        total = len(self.confirmed) + len(self.unconfirmed)
        claims = [
            "every golden step in this package passes",
            "fully confirmed",
        ]
        if self.unconfirmed:
            claims.append(f"all {total} golden steps")
        for claim in claims:
            with self.subTest(claim=claim):
                self.assertNotIn(claim, lowered)

    def test_the_notice_still_refuses_the_hardware_claim(self):
        self.assertIn("not hardware-confirmed", self.notice.lower())
        self.assertIn("has not been executed", self.notice.lower())

    def test_the_rulings_do_not_contradict_themselves(self):
        # the ruling quotes the conformance line, so the number it carries is
        # whatever the evidence says - read from there, not typed
        confirmed = len(self.confirmed)
        for ruling in self.package["rulings_applied"]:
            if "confirmed" in ruling.lower():
                with self.subTest(ruling=ruling[:40]):
                    self.assertIn(f"{confirmed}/{confirmed}", ruling)
                    self.assertNotIn("every", ruling.lower())

    def test_the_hex_manifest_carries_the_identical_notice(self):
        manifest = json.loads((V.HEX_DIR / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["notice"], self.notice)
        self.assertEqual(manifest["chip_confirmed"], not pending_now())


if __name__ == "__main__":
    unittest.main(verbosity=2)
