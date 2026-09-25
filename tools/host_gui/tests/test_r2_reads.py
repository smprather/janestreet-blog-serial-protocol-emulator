"""Tests for the R2 read-path contract layer (plan Task 3-5 host prep).

R2 is the chip-side work (explicit full-width CPU debug ports, an IMEM host
read port, a SoC read mux with no-wrap range rejection, and chip-side
read-while-running rejection). None of it is on the chip yet. This layer
exists so the host model, the acceptance runner and — later — the chip TBs all
read the SAME list of read obligations, each explicitly marked
``chip_confirmed=False`` until the RTL lands and is validated.

These tests are about the *host-side contract and model*, not about silicon.
"""

from __future__ import annotations

import unittest

from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P
from tools.host_gui import r2_reads as R


class TestR2Obligations(unittest.TestCase):
    def test_every_obligation_is_marked_not_chip_confirmed(self):
        self.assertGreater(len(R.OBLIGATIONS), 0)
        for obligation in R.OBLIGATIONS:
            with self.subTest(obligation=obligation.name):
                self.assertFalse(obligation.chip_confirmed)
                self.assertTrue(obligation.description.strip())
                self.assertTrue(obligation.probe)          # callable check

    def test_obligations_cover_the_plan_read_ops(self):
        names = {obligation.name for obligation in R.OBLIGATIONS}
        for expected in ("read_imem_bounded", "read_dmem_bounded",
                         "dump_core_header", "read_cpu_non_halting",
                         "read_while_running_rejected", "range_never_wraps",
                         "full_width_debug_regs"):
            with self.subTest(obligation=expected):
                self.assertIn(expected, names)

    def test_not_chip_confirmed_note_is_explicit(self):
        self.assertIn("not chip-confirmed", R.NOT_CHIP_CONFIRMED.lower())


class TestFakePEReadFaultPolicy(unittest.TestCase):
    """A read range error may or may not latch a sticky fault; the chip
    decides. The model exposes both so the host never presumes one."""

    def test_default_policy_latches_range_fault(self):
        pe = F.FakePE()
        self.assertEqual(pe.read_fault_policy, "latch")
        pe.request(P.OP_READ_IMEM, payload_words=(2000, 1))
        self.assertEqual(pe.faults & F.FAULT_RANGE, F.FAULT_RANGE)

    def test_status_only_policy_does_not_latch_on_read(self):
        pe = F.FakePE(read_fault_policy="status-only")
        payload = pe.request(P.OP_READ_IMEM, payload_words=(2000, 1)).payload
        self.assertEqual(payload[0], P.STATUS_RANGE)
        self.assertEqual(pe.faults, 0)

    def test_status_only_policy_still_latches_write_range(self):
        # A LOAD over 1024 words is a loader fault, not a read-range question.
        pe = F.FakePE(read_fault_policy="status-only")
        payload = pe.request(P.OP_LOAD, payload_words=tuple(range(1025))).payload
        self.assertEqual(payload[0], P.STATUS_RANGE)
        self.assertEqual(pe.faults & F.FAULT_RANGE, F.FAULT_RANGE)


class TestR2ProbesAgainstFakePE(unittest.TestCase):
    """Each obligation's probe runs against the host model and passes; the same
    probe will run against the real chip once R2 lands (chip_confirmed flips
    only then)."""

    def setUp(self):
        self.pe = F.FakePE()

    def test_all_probes_pass_against_the_fake(self):
        for obligation in R.OBLIGATIONS:
            with self.subTest(obligation=obligation.name):
                self.assertTrue(obligation.probe(self.pe))

    def test_read_imem_bounded_probe(self):
        self.pe.request(P.OP_LOAD, payload_words=(0x0041, 0x1001, 0x4002))
        payload = self.pe.request(P.OP_READ_IMEM, payload_words=(1, 2)).payload
        self.assertEqual(payload, (P.STATUS_OK, 0x1001, 0x4002))

    def test_read_dmem_bounded_probe(self):
        self.pe.dmem[0:2] = b"\x0a\x0b"
        payload = self.pe.request(P.OP_READ_DMEM, payload_words=(0, 2)).payload
        self.assertEqual(payload, (P.STATUS_OK, 0x0A0B))

    def test_dump_core_header_probe_matches_status_when_stopped(self):
        self.pe.request(P.OP_LOAD, payload_words=(0x0041,))
        self.pe.pc, self.pe.a, self.pe.x, self.pe.y = 0x123, 0x456, 0x789, 0xABC
        dump = self.pe.request(P.OP_DUMP_CORE).payload
        status = self.pe.request(P.OP_STATUS).payload
        self.assertEqual(dump, status)

    def test_read_while_running_rejected_probe(self):
        self.pe.run = True
        for opcode, payload in ((P.OP_READ_IMEM, (0, 1)),
                                (P.OP_READ_DMEM, (0, 1)),
                                (P.OP_DUMP_CORE, ())):
            with self.subTest(opcode=opcode):
                response = self.pe.request(opcode, payload_words=payload)
                self.assertEqual(response.payload[0], P.STATUS_NOT_READY)

    def test_range_never_wraps_probe(self):
        # address+count past the end is RANGE, never a wrapped read.
        self.assertEqual(
            self.pe.request(P.OP_READ_IMEM, payload_words=(1023, 2)).payload[0],
            P.STATUS_RANGE)
        self.assertEqual(
            self.pe.request(P.OP_READ_DMEM, payload_words=(15, 2)).payload[0],
            P.STATUS_RANGE)

    def test_full_width_debug_regs_probe(self):
        self.pe.pc, self.pe.a, self.pe.x, self.pe.y, self.pe.insn = (
            0x3FF, 0x1FFF, 0x2AA, 0x155, 0xFFFF)
        payload = self.pe.request(P.OP_READ_CPU).payload
        self.assertEqual(payload[1:6], (0x3FF, 0x1FFF, 0x2AA, 0x155, 0xFFFF))

    def test_read_payload_is_low_word_first_ascending(self):
        # Manager RULING: READ payload matches LOAD's ascending stream.
        words = (0x1111, 0x2222, 0x3333, 0x4444)
        self.pe.request(P.OP_LOAD, payload_words=words)
        payload = self.pe.request(P.OP_READ_IMEM, payload_words=(1, 3)).payload
        self.assertEqual(payload, (P.STATUS_OK, 0x2222, 0x3333, 0x4444))

    def test_out_of_range_read_latches_sticky_fault_by_ruling(self):
        payload = self.pe.request(P.OP_READ_IMEM, payload_words=(2000, 1)).payload
        self.assertEqual(payload[0], P.STATUS_RANGE)
        self.assertEqual(self.pe.faults & F.FAULT_RANGE, F.FAULT_RANGE)
        # CLEAR_FAULT clears it.
        cleared = self.pe.request(P.OP_CLEAR_FAULT, payload_words=(F.FAULT_RANGE,))
        self.assertEqual(self.pe.faults, 0)
        self.assertEqual(cleared.payload, (P.STATUS_OK, 0))


if __name__ == "__main__":
    unittest.main(verbosity=2)
