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


class TestLatchedInsnRule(unittest.TestCase):
    """BOTH halves of the insn rule, which is a cross-phase constraint.

    Fixing READ_CPU introduced an asymmetry: the FETCHED word while a debug hold
    is asserted, the LATCHED register otherwise. The held half is what R3 needs
    (a debugger must see the landing instruction). The un-held half is what
    R2 needs, and it is the half nobody would think to protect: both
    chip-confirmed R2 READ_CPU vectors PRELOAD insn=0xFFFF and expect it back,
    while the word their fetch address would give is something else entirely.
    """

    def test_held_reports_the_fetched_word_at_pc(self):
        pe = R.loaded(pc=0)
        pe.request(P.OP_DEBUG_STEP)          # executes imem[0], pc -> 1, held
        self.assertTrue(pe.debug_hold)
        self.assertEqual(pe.latched_insn, R.PROGRAM[1])
        self.assertNotEqual(pe.latched_insn, pe.insn)

    def test_unheld_preserves_the_latched_register(self):
        """The half a 'cleanup' would break, and the R2 vectors depend on it."""
        for image_id in ("v04-read_cpu_non_halting", "v05-full_width_debug_regs"):
            with self.subTest(image=image_id):
                image = V2.build_package()["model_images"][image_id]
                pe = V.load_model_from_image(image)
                self.assertFalse(pe.debug_hold)
                # The preloaded register survives...
                self.assertEqual(pe.latched_insn, 0xFFFF)
                # ...even though the word the fetch address would give differs,
                # which is the whole reason the rule is two-sided.
                self.assertNotEqual(pe.imem[pe.fetch_address], 0xFFFF)

    def test_simplifying_the_rule_would_break_the_chip_confirmed_r2_package(self):
        """The concrete consequence, so the trade-off is not folklore.

        Both R2 READ_CPU vectors expect 0xFFFF because a conformance-TB snapshot
        preloads the register. Reporting the fetched word unconditionally would
        hand them 0x0041 and 0x0000 respectively, and the chip passes them
        byte-exactly today (18/18).
        """
        package = V2.build_package()
        fetched = {}
        for vector in package["vectors"]:
            for step in vector["steps"]:
                if step["opcode_name"] == "OP_READ_CPU":
                    pe = V.load_model_from_image(
                        package["model_images"][step["model_image_id"]])
                    fetched[(vector["name"], step["name"])] = (
                        step["response_payload_words"][5],
                        pe.imem[pe.fetch_address])
        self.assertTrue(fetched)
        for key, (expected, would_report) in fetched.items():
            with self.subTest(vector=key):
                self.assertEqual(expected, 0xFFFF)
                self.assertNotEqual(would_report, expected)

    def test_r2_still_checks_clean(self):
        self.assertEqual(V2.check_package(), 0)
        self.assertEqual(V2.check_hex_export(), 0)

class TestChipConformanceCorrections(unittest.TestCase):
    """Semantics the chip's conformance run proved this host model had wrong.

    Two host-side vector defects and one TB model boundary, from the chip's
    tb_pe_ctrl_r3_conf (its pinned R3_KNOWN_DIVERGENCES list). The chip is
    right in all three; these pin the corrected semantics so they cannot
    silently regress.
    """

    def test_read_cpu_reports_run_not_the_debug_state(self):
        """The last READ_CPU word is the run STRAP, not the debug state.

        pe_ctrl's OP_RDCPU builder is `resp_buf[6] <= {15'b0, run}`, and the R2
        header agrees. The host builder used to put the debug STATE there, which
        matched only while no hold was asserted and disagreed the moment one
        was -- exactly the word a debugger reads to decide whether the core is
        executing.
        """
        pe = R.loaded(pc=0)
        pe.request(P.OP_DEBUG_STEP)  # now held: state 2, run 0
        self.assertEqual(pe.state, F.DEBUG_HOLD)
        payload = pe.request(P.OP_READ_CPU).payload
        self.assertEqual(payload[0], P.STATUS_OK)
        self.assertEqual(payload[6], 0, "last word is run, and the strap is low")
        self.assertNotEqual(payload[6], pe.state)

    def test_read_cpu_while_held_reports_the_fetched_word(self):
        """While held, the fetch mode is pc, so insn is the word AT that pc."""
        pe = R.loaded(pc=0)
        pe.request(P.OP_DEBUG_STEP)  # executes imem[0], pc -> 1
        payload = pe.request(P.OP_READ_CPU).payload
        self.assertEqual(payload[1], 1)  # pc
        self.assertEqual(payload[2], 0x55)  # a = LDI retired
        self.assertEqual(
            payload[5], R.PROGRAM[1], "insn is imem[pc], not the last-executed word"
        )

    def test_a_step_executes_one_instruction_and_the_hold_protects_the_next(self):
        """Stop-before withholds the LANDING instruction, not the stepped one.

        The host model used to skip the execute whenever the landing address
        matched, which suppressed the wrong instruction: a step from 1 to 2
        really does retire the LDI A,0xAA at address 1, and the hold is what
        keeps the instruction AT the breakpoint from running.
        """
        pe = R.loaded(pc=0, bp_addr=2, bp_en=True)
        pe.request(P.OP_DEBUG_STEP)  # 0 -> 1, retires LDI A,0x55
        self.assertEqual(pe.a, 0x55)
        payload = pe.request(P.OP_DEBUG_STEP).payload  # 1 -> 2, lands on bp
        self.assertEqual(pe.a, 0xAA, "the step from 1 to 2 retires the LDI at 1")
        self.assertEqual(payload[1], F.DEBUG_BP_HIT)
        self.assertEqual(payload[2], 2)
        self.assertEqual(payload[4], F.BP_FLAG_ARMED | F.BP_FLAG_HIT)
        self.assertEqual(pe.pc, 2)
        # The instruction at the breakpoint has NOT run: the next step retires
        # imem[2] (NOP) and lands at 3.
        self.assertEqual(pe.request(P.OP_DEBUG_STEP).payload[2], 3)

    def test_the_two_corrected_steps_match_the_chips_observed_bytes(self):
        """The exact frame words the chip reported, so the vectors cannot drift."""
        package = V3.build_package()
        steps = {
            (v["name"], s["name"]): s for v in package["vectors"] for s in v["steps"]
        }

        def words(key):
            raw = bytes.fromhex(steps[key]["response_hex"])
            return [
                f"{int.from_bytes(raw[i : i + 2], 'big'):04X}"
                for i in range(0, len(raw), 2)
            ]

        # 0-based frame words: 0=SYNC 1=header 2=seq 3=len 4=OK ... last=CRC.
        self.assertEqual(
            words(("debug_step_executes_one", "read_cpu_shows_a_55"))[9:12],
            ["00AA", "0000", "77B8"],
        )
        self.assertEqual(
            words(("debug_step_lands_on_bp", "status_reports_the_hit"))[10], "00AA"
        )
        self.assertEqual(
            words(("debug_step_lands_on_bp", "status_reports_the_hit"))[14], "7D55"
        )

    def test_the_model_boundary_stays_unproven_and_unchanged(self):
        """insn is not contract-determined for a free-running core.

        The chip's freeze-snapshot TB reports 0x0000 where the ruled landing
        word is 0xF000. That is a TB artefact -- its own doc says it is "not a
        disagreement about the contract" -- so the expectation stays the ruled
        value, the step stays chip_confirmed=false, and the boundary is
        recorded rather than quietly "fixed" to match a testbench.
        """
        package = V3.build_package()
        step = next(
            s
            for v in package["vectors"]
            if v["name"] == "debug_status_common_prefix"
            for s in v["steps"]
            if s["name"] == "status_full_readback"
        )
        raw = bytes.fromhex(step["response_hex"])
        insn = f"{int.from_bytes(raw[26:28], 'big'):04X}"
        self.assertEqual(insn, "F000")
        self.assertFalse(step["chip_confirmed"])
        self.assertTrue(package["model_boundaries"])
        self.assertFalse(package["model_boundaries"][0]["chip_confirmed"])

    def test_r2_is_still_byte_identical_after_the_read_cpu_change(self):
        """The READ_CPU fix must not perturb the chip-confirmed R2 package."""
        self.assertEqual(V2.check_package(), 0)
        self.assertEqual(V2.check_hex_export(), 0)


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
