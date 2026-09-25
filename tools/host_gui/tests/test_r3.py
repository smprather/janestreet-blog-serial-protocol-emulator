"""R3 debug-control tests: the model, the obligations, and the package.

Three layers, deliberately kept separate:

* the FakePE debug model, checked against the RTL's response layouts
  directly (so a model bug is not masked by the probes that use it);
* the r3_reads obligations, including the per-probe model isolation that keeps
  the suite order-independent;
* the r3_vectors package: drift gates, the R2 shape the chip TB consumes, and
  the chip_confirmed discipline.
"""

import json
import unittest

from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P
from tools.host_gui import r2_vectors as V2
from tools.host_gui import r3_reads as R
from tools.host_gui import r3_vectors as V3
from tools.host_gui import vectors as V


class TestDebugStateEncoding(unittest.TestCase):
    """The state and flag words are the chip's, transcribed from pe_ctrl.v."""

    def test_state_matches_the_rtl_expression(self):
        # dbg_state = dbg_hold_r ? (bp_hit ? 2'd3 : 2'd2) : (run ? 2'd1 : 2'd0)
        cases = {
            (False, False, False): F.DEBUG_STOPPED,
            (False, False, True): F.DEBUG_RUNNING,
            (True, False, False): F.DEBUG_HOLD,
            (True, True, False): F.DEBUG_BP_HIT,
        }
        for (hold, hit, run), expected in cases.items():
            with self.subTest(hold=hold, hit=hit, run=run):
                pe = F.FakePE()
                pe.debug_hold, pe.bp_hit, pe.run = hold, hit, run
                self.assertEqual(pe.state, expected)

    def test_bp_flags_is_hit_then_armed(self):
        # wire [1:0] bp_flags = {bp_hit, bp_en}
        for en, hit, expected in (
            (False, False, 0b00),
            (True, False, 0b01),
            (False, True, 0b10),
            (True, True, 0b11),
        ):
            with self.subTest(en=en, hit=hit):
                pe = F.FakePE()
                pe.bp_en, pe.bp_hit = en, hit
                self.assertEqual(pe.bp_flags, expected)

    def test_r2_state_values_are_unchanged_without_a_hold(self):
        """R2's STATUS state word must keep meaning 0/1 for R2's vectors."""
        pe = F.FakePE()
        pe.run = False
        self.assertEqual(pe.state, 0)
        pe.run = True
        self.assertEqual(pe.state, 1)


class TestDebugOps(unittest.TestCase):
    """The four handlers, checked against the RTL's response builders."""

    def setUp(self):
        self.pe = R.loaded(pc=0)

    def test_step_shape_and_isa_effect(self):
        payload = self.pe.request(P.OP_DEBUG_STEP).payload
        self.assertEqual(payload, (P.STATUS_OK, F.DEBUG_HOLD, 1, 0, 0))
        # imem[0] is LDI A,0x55 and it really executed.
        self.assertEqual(self.pe.a, 0x55)
        self.assertEqual(self.pe.pc, 1)

    def test_step_takes_no_payload_and_a_payload_is_bad_frame(self):
        good = self.pe.request(P.OP_DEBUG_STEP).payload
        self.assertEqual(good[0], P.STATUS_OK)
        bad = self.pe.request(P.OP_DEBUG_STEP, payload_words=(1,)).payload
        self.assertEqual(bad, (P.STATUS_BAD_FRAME,))
        self.assertTrue(self.pe.faults & F.FAULT_PROTOCOL)

    def test_step_while_running_answers_the_full_prefix(self):
        pe = R.loaded(pc=7, run=True)
        payload = pe.request(P.OP_DEBUG_STEP).payload
        # NOT_READY still carries 5 words, with the PRE-step state.
        self.assertEqual(payload, (P.STATUS_NOT_READY, F.DEBUG_RUNNING, 7, 0, 0))
        self.assertFalse(pe.debug_hold)
        self.assertEqual(pe.pc, 7)
        self.assertEqual(pe.faults, 0)  # a refusal latches no fault

    def test_bp_set_reports_the_new_address_with_pre_state(self):
        payload = self.pe.request(P.OP_DEBUG_BP_SET, payload_words=(2,)).payload
        self.assertEqual(payload, (P.STATUS_OK, F.DEBUG_STOPPED, 0, 2, 0b01))

    def test_bp_set_past_imem_is_range_and_changes_nothing(self):
        pe = R.loaded(pc=0, bp_addr=3, bp_en=True)
        payload = pe.request(P.OP_DEBUG_BP_SET, payload_words=(F.IMEM_WORDS,)).payload
        self.assertEqual(payload[0], P.STATUS_RANGE)
        self.assertEqual(payload[3:], (3, 0b01))  # unchanged
        self.assertEqual(pe.bp_addr, 3)
        self.assertEqual(pe.faults, 0)  # R3 adds no fault class

    def test_bp_clr_releases_to_running_when_the_strap_is_high(self):
        pe = R.loaded(pc=2, run=True, bp_addr=2, bp_en=True, bp_hit=True, debug_hold=True)
        payload = pe.request(P.OP_DEBUG_BP_CLR).payload
        self.assertEqual(payload, (P.STATUS_OK, F.DEBUG_RUNNING, 2, 2, 0))
        self.assertTrue(pe.run)
        self.assertFalse(pe.debug_hold)

    def test_bp_clr_releases_to_the_boot_stop_and_rezeroes(self):
        pe = R.loaded(pc=3, bp_en=True, debug_hold=True)
        payload = pe.request(P.OP_DEBUG_BP_CLR).payload
        # The RTL answers with the PC AT THE REQUEST; the re-zero lands at the
        # same edge, so the NEXT read sees 0. (The contract's table row says 0
        # here; the RTL wins -- see r3_reads.DISCREPANCIES.)
        self.assertEqual(payload, (P.STATUS_OK, F.DEBUG_STOPPED, 3, 0, 0))
        self.assertEqual(pe.pc, 0)
        self.assertEqual(pe.request(P.OP_DEBUG_STATUS).payload[2], 0)

    def test_debug_status_is_ten_words(self):
        payload = self.pe.request(P.OP_DEBUG_STATUS).payload
        self.assertEqual(len(payload), 10)
        self.assertEqual(payload[0], P.STATUS_OK)

    def test_debug_ops_are_unsupported_on_the_loopback_target(self):
        for opcode, payload in (
            (P.OP_DEBUG_STEP, ()),
            (P.OP_DEBUG_BP_CLR, ()),
            (P.OP_DEBUG_STATUS, ()),
            (P.OP_DEBUG_BP_SET, (2,)),
        ):
            with self.subTest(opcode=opcode):
                frame = self.pe.request(
                    opcode, target=P.TARGET_LOOPBACK, payload_words=payload
                )
                self.assertEqual(frame.payload[0], P.STATUS_UNSUPPORTED)


class TestStopBefore(unittest.TestCase):
    """S3: the hit compares the LANDING address, so nothing runs at the bp."""

    def test_the_instruction_at_the_breakpoint_did_not_run(self):
        pe = R.loaded(pc=0)
        pe.request(P.OP_DEBUG_STEP)  # 0 -> 1
        pe.bp_addr, pe.bp_en = 2, True
        payload = pe.request(P.OP_DEBUG_STEP).payload
        self.assertEqual(payload, (P.STATUS_OK, F.DEBUG_BP_HIT, 2, 2, 0b11))
        # imem[2] is NOP, so the proof that it did not run is that the PC is
        # parked ON 2 with the hit latched, and only the NEXT step advances.
        self.assertEqual(pe.pc, 2)
        self.assertTrue(pe.bp_hit)
        self.assertEqual(pe.request(P.OP_DEBUG_STEP).payload[2], 3)
        self.assertFalse(pe.bp_hit)  # stepping off clears it (S4)

    def test_a_live_core_stops_with_the_strap_still_high(self):
        pe = R.loaded(pc=0, run=True, bp_addr=2, bp_en=True)
        self.assertTrue(pe.advance_free_running())
        self.assertTrue(pe.run)
        payload = pe.request(P.OP_DEBUG_STATUS).payload
        self.assertEqual(payload[1], F.DEBUG_BP_HIT)
        self.assertEqual(payload[2], 2)
        self.assertEqual(payload[5], 1)  # the run strap is STILL high


class TestIsaExecution(unittest.TestCase):
    """R3's contract is stated over real instructions, so they must execute."""

    def test_program_words_are_distinct(self):
        self.assertEqual(len(set(R.PROGRAM)), len(R.PROGRAM))
        self.assertEqual(R.PROGRAM, (0x0055, 0x00AA, 0xF000, 0x000F, 0x4002))

    def test_ldi_and_jmp(self):
        pe = R.loaded(pc=0)
        pe.request(P.OP_DEBUG_STEP)  # LDI A,0x55
        self.assertEqual(pe.a, 0x55)
        pe.request(P.OP_DEBUG_STEP)  # LDI A,0xAA
        self.assertEqual(pe.a, 0xAA)
        pe.request(P.OP_DEBUG_STEP)  # NOP
        pe.request(P.OP_DEBUG_STEP)  # LDI A,0x0F
        self.assertEqual(pe.a, 0x0F)
        pe.request(P.OP_DEBUG_STEP)  # JMP 2
        self.assertEqual(pe.pc, 2)

    def test_a_held_pc_is_stable_across_reads(self):
        pe = R.loaded(pc=0)
        pe.request(P.OP_DEBUG_STEP)
        snapshot = (pe.pc, pe.a, pe.insn)
        for _ in range(5):
            pe.request(P.OP_DEBUG_STATUS)
        self.assertEqual((pe.pc, pe.a, pe.insn), snapshot)


class TestObligations(unittest.TestCase):
    def test_every_probe_passes(self):
        results = R.run_all_probes()
        failed = {name: value for name, value in results.items() if not value}
        self.assertEqual(failed, {}, f"R3 obligations failing: {failed}")

    def test_probes_are_order_independent(self):
        """Each probe gets its own model, so a green run is reproducible."""
        forward = R.run_all_probes()
        backward = {
            name: bool(R.by_name()[name].probe(F.FakePE()))
            for name in reversed(list(forward))
        }
        self.assertEqual(forward, backward)

    def test_nothing_is_chip_confirmed_yet(self):
        # The R2 discipline: the host model is never evidence about silicon, so
        # no host obligation may claim confirmation on its own.
        self.assertEqual(R.unconfirmed_names(), list(R.by_name()))

    def test_the_provisional_table_is_gone(self):
        """The contract is implemented, so nothing reads as provisional."""
        self.assertNotIn("PROVISIONAL", (R.__doc__ or "").upper())
        self.assertTrue(R.DISCREPANCIES)


class TestPackage(unittest.TestCase):
    def test_package_has_the_r2_shape(self):
        package = V3.build_package()
        for key in (
            "vectors",
            "model_images",
            "chip_evidence",
            "notice",
            "protocol",
            "memory",
            "status_codes",
            "schema",
            "phase",
        ):
            self.assertIn(key, package)
        self.assertEqual(package["schema"], V.SCHEMA_VERSION)
        self.assertEqual(package["phase"], "R3")
        for vector in package["vectors"]:
            self.assertIn("steps", vector)
            for step in vector["steps"]:
                for key in (
                    "request_hex",
                    "response_hex",
                    "status",
                    "response_payload_words",
                    "model_image_id",
                    "chip_confirmed",
                ):
                    self.assertIn(key, step)

    def test_there_are_fourteen_contract_vectors(self):
        package = V3.build_package()
        self.assertEqual(len(package["vectors"]), 14)

    def test_no_step_is_chip_confirmed(self):
        """chip_confirmed stays False until the chip's TB passes the vectors."""
        package = V3.build_package()
        steps = [s for v in package["vectors"] for s in v["steps"]]
        self.assertTrue(steps)
        self.assertTrue(all(not s["chip_confirmed"] for s in steps))
        self.assertFalse(package["chip_confirmed"])

    def test_a_confirmed_step_must_cite_the_evidence(self):
        """The R2 discipline: confirmation is a citation, never an assertion."""
        for vector in V3.build_package()["vectors"]:
            for step in vector["steps"]:
                if step["chip_confirmed"]:
                    self.assertIn("chip_evidence", step)
                    self.assertTrue(step["chip_evidence"]["review"])
        self.assertEqual(V3.CHIP_EVIDENCE["confirmed_steps"], set())

    def test_images_declare_the_debug_registers_not_the_state_word(self):
        for image in V3.build_package()["model_images"].values():
            self.assertIn("debug", image)
            self.assertEqual(
                set(image["debug"]), {"bp_addr", "bp_en", "bp_hit", "debug_hold"}
            )
            self.assertNotIn("debug_state", image["debug"])

    def test_an_image_cannot_contradict_the_boot_stop(self):
        """run=0 with no hold holds the PC at 0, so the loader enforces it."""
        package = V3.build_package()
        pe = V.load_model_from_image(package["model_images"]["v01-bp-set-readback"])
        self.assertEqual(pe.pc, 0)
        self.assertEqual(pe.state, F.DEBUG_STOPPED)

    def test_the_bad_crc_step_ships_the_corrupt_bytes(self):
        vector = next(
            v
            for v in V3.build_package()["vectors"]
            if v["name"] == "debug_bad_crc_no_side_effect"
        )
        step = next(s for s in vector["steps"] if s["name"] == "bp_set_bad_crc")
        clean = P.encode_frame(P.OP_DEBUG_BP_SET, step["sequence"], 0, b"\x00\x02")
        self.assertNotEqual(step["request_hex"], clean.hex())
        self.assertEqual(step["status"], P.STATUS_BAD_FRAME)

    def test_drift_gates(self):
        self.assertEqual(V3.check_package(), 0)
        self.assertEqual(V3.check_hex_export(), 0)

    def test_the_artifact_on_disk_matches_a_fresh_build(self):
        self.assertEqual(
            json.loads(V3.ARTIFACT.read_text(encoding="utf-8")), V3.build_package()
        )

    def test_regenerating_does_not_change_anything(self):
        before = V3.ARTIFACT.read_text(encoding="utf-8")
        V3.write_package()
        self.assertEqual(V3.ARTIFACT.read_text(encoding="utf-8"), before)

    def test_the_spec_vs_rtl_discrepancies_are_published(self):
        package = V3.build_package()
        self.assertEqual(len(package["spec_vs_rtl_discrepancies"]), len(R.DISCREPANCIES))


class TestFrameworkIsSharedAndR2IsUntouched(unittest.TestCase):
    def test_r2_artifacts_are_still_byte_identical(self):
        """The extraction must never perturb the chip-confirmed R2 package."""
        self.assertEqual(V2.check_package(), 0)
        self.assertEqual(V2.check_hex_export(), 0)

    def test_both_phases_use_the_one_framework(self):
        self.assertIs(V2.V, V3.V)
        self.assertEqual(V2.SPEC.schema, None)  # R2 predates the stamp
        self.assertEqual(V3.SPEC.schema, V.SCHEMA_VERSION)


if __name__ == "__main__":
    unittest.main()
