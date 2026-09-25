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
        pe.request(P.OP_DEBUG_STEP)  # executes imem[0], pc -> 1, held
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
                        package["model_images"][step["model_image_id"]]
                    )
                    fetched[(vector["name"], step["name"])] = (
                        step["response_payload_words"][5],
                        pe.imem[pe.fetch_address],
                    )
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

    def test_obligations_stay_unconfirmed_even_though_the_steps_do_not(self):
        """Two different things, deliberately not collapsed into one flag.

        The VECTOR STEPS are chip-confirmed (the chip's conformance TB ran
        them). The r3_reads OBLIGATIONS stay unconfirmed: those are host-side
        probes of the model, and a host probe is never evidence about silicon
        no matter how many of them pass. A flag that covered both would let a
        green host suite imply confirmation.
        """
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

    def test_exactly_the_confirmed_steps_are_confirmed(self):
        """25 of 26, and the 26th is the pinned TB model boundary.

        The chip's tb_pe_ctrl_r3_conf is GREEN and its citations are recorded,
        so the steps it ran byte-exactly are confirmed. The one exception is
        `status_full_readback`, which BOTH sides deliberately leave unproven.
        The package-level flag therefore stays False, because not every vector
        is confirmed -- that is the honest aggregate, not an oversight.
        """
        package = V3.build_package()
        steps = [(v["name"], s) for v in package["vectors"] for s in v["steps"]]
        boundary = package["model_boundaries"][0]["step"]
        self.assertEqual(len(steps), 26)
        # `steps` is (vector_name, step) pairs, so the STEP name comes from the
        # step dict -- not from the vector.
        confirmed = [s["name"] for _, s in steps if s["chip_confirmed"]]
        unconfirmed = [s["name"] for _, s in steps if not s["chip_confirmed"]]
        self.assertEqual(len(confirmed), 25)
        self.assertEqual(unconfirmed, [boundary])
        self.assertEqual(boundary, "status_full_readback")
        self.assertFalse(package["chip_confirmed"])

    def test_duplicate_step_names_cannot_drift_apart_silently(self):
        """Evidence is keyed by step NAME, and `step_one` names two steps.

        The framework keys confirmation by step name, so a name shared by two
        vectors confirms both. That is right today (both are confirmed), but
        it is only safe while they agree -- so pin that they do, rather than
        leaving it to a reader to notice.
        """
        package = V3.build_package()
        seen = {}
        for vector in package["vectors"]:
            for step in vector["steps"]:
                seen.setdefault(step["name"], []).append(
                    (vector["name"], step["chip_confirmed"])
                )
        shared = {n: v for n, v in seen.items() if len(v) > 1}
        self.assertIn("step_one", shared, "the name collision this guards")
        for name, entries in shared.items():
            with self.subTest(step=name):
                self.assertEqual(
                    {flag for _, flag in entries},
                    {True},
                    f"steps sharing the name {name!r} disagree "
                    f"on confirmation, which name-keyed evidence "
                    f"cannot express: {entries}",
                )

    def test_a_confirmed_step_must_cite_the_evidence(self):
        """The R2 discipline: confirmation is a citation, never an assertion."""
        for vector in V3.build_package()["vectors"]:
            for step in vector["steps"]:
                if step["chip_confirmed"]:
                    self.assertIn("chip_evidence", step)
                    self.assertTrue(step["chip_evidence"]["review"])
        confirmed = V3.CHIP_EVIDENCE["confirmed_steps"]
        self.assertEqual(
            len(confirmed), 24, "distinct names; step_one covers two steps, so 25 steps"
        )
        self.assertNotIn("status_full_readback", confirmed)
        for key in ("review", "testbench", "harness", "conformance", "scope"):
            with self.subTest(citation=key):
                self.assertTrue(V3.CHIP_EVIDENCE[key])

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


class TestTheNoticeMatchesTheFlagArithmetic(unittest.TestCase):
    """The shipped prose must agree with the package's own data.

    This class exists because prose staleness has now bitten three times, and
    the DRIFT GATE structurally cannot catch it: the notice and the flags are
    generated from the same source, so a fresh build faithfully reproduces
    stale prose and `--check` passes. The only thing that can catch it is a
    check that compares the prose against the DATA it describes.
    """

    @classmethod
    def setUpClass(cls):
        cls.package = V3.build_package()
        cls.steps = [s for v in cls.package["vectors"] for s in v["steps"]]
        cls.confirmed = [s for s in cls.steps if s["chip_confirmed"]]
        cls.boundary = {b["step"] for b in cls.package["model_boundaries"]}

    def test_the_notice_states_the_real_counts(self):
        notice = self.package["notice"]
        self.assertIn(f"{len(self.confirmed)} of {len(self.steps)}", notice)

    def test_the_notice_names_the_unconfirmed_step(self):
        for step in self.boundary:
            with self.subTest(step=step):
                self.assertIn(step, self.package["notice"])

    def test_the_notice_makes_no_contradicted_claim(self):
        """The specific failure: a notice that says "every step is false"."""
        forbidden = (
            "every step is chip_confirmed=false",
            "every step is chip_confirmed=False",
            "no step here has been run",
            "NOT CHIP-CONFIRMED.",
        )
        for phrase in forbidden:
            with self.subTest(phrase=phrase):
                self.assertNotIn(phrase, self.package["notice"])

    def test_the_notice_still_refuses_the_hardware_claim(self):
        """Fresh numbers must not quietly become a hardware claim."""
        self.assertIn("HARDWARE-CONFIRMED", self.package["notice"])
        self.assertIn("has never been executed", self.package["notice"])

    def test_the_rulings_do_not_contradict_themselves(self):
        joined = " ".join(self.package["rulings_applied"])
        self.assertNotIn("every step is chip_confirmed=False", joined)
        self.assertIn(f"{len(self.confirmed)} of {len(self.steps)}", joined)

    def test_the_hex_export_carries_the_same_notice(self):
        """The hex manifest is what a chip TB reads; it must not lag the JSON."""
        import json
        manifest = json.loads(
            (V3.SPEC.hex_dir / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["notice"], self.package["notice"])

    def test_confirmed_count_is_derived_not_asserted(self):
        """Guard the arithmetic itself: 25 of 26, boundary excluded."""
        self.assertEqual(len(self.confirmed), 25)
        self.assertEqual(len(self.steps), 26)
        unconfirmed = {s["name"] for s in self.steps if not s["chip_confirmed"]}
        self.assertEqual(unconfirmed, self.boundary)


if __name__ == "__main__":
    unittest.main()
