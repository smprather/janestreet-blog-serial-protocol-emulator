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
from pathlib import Path

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
        # ISA-native: pc 10 bits, a/x/y 8, insn 16.
        self.pe.pc, self.pe.a, self.pe.x, self.pe.y, self.pe.insn = (
            0x3FF, 0xFF, 0xFF, 0xFF, 0xFFFF)
        payload = self.pe.request(P.OP_READ_CPU).payload
        self.assertEqual(payload[1:6], (0x3FF, 0xFF, 0xFF, 0xFF, 0xFFFF))

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


class TestISAWidthsAreChipNative(unittest.TestCase):
    """The ISA is the source of truth (manager ruling 2026-09-25).

    The R2 package once encoded a 13-bit A (0x1FFF) because the host model
    invented width instead of mirroring the chip. These tests pin the widths to
    rtl/pe_cpu.v itself, so the model and the golden vectors cannot drift from
    the RTL again.
    """

    @staticmethod
    def _pe_cpu_source() -> str:
        # The chip repo is a sibling checkout; fall back to this worktree's copy
        # (identical content at the fork point) if the sibling is absent.
        sibling = Path("/home/mylesp/janestreet-blog-serial-protocol-emulator")
        candidate = sibling / "rtl" / "pe_cpu.v"
        if not candidate.is_file():
            candidate = Path(__file__).resolve().parents[3] / "rtl" / "pe_cpu.v"
        return candidate.read_text(encoding="utf-8")

    def test_register_widths_match_the_cpu_rtl(self):
        source = self._pe_cpu_source()
        # a, x, y are declared 8-bit in pe_cpu.v
        self.assertRegex(source, r"logic\s*\[7:0\]\s*a\s*,\s*y\s*,\s*x\s*;")
        # pc is PCW bits, with PCW = max(8, IAW) and IAW from IMEM_WORDS
        self.assertIn("logic [PCW-1:0] pc;", source)
        self.assertEqual(F.ISA_A_BITS, 8)
        self.assertEqual(F.ISA_X_BITS, 8)
        self.assertEqual(F.ISA_Y_BITS, 8)
        # At the SoC's IMEM_WORDS=1024, IAW = clog2(1024) = 10, so PCW = 10.
        self.assertEqual(F.ISA_PC_BITS, 10)
        self.assertEqual(F.ISA_INSN_BITS, 16)      # 16-bit instruction word

    def test_model_masks_registers_to_the_isa(self):
        pe = F.FakePE()
        # Poke a wider-than-ISA value: the response must stay ISA-native.
        pe.pc = 0xFFFF
        pe.a = pe.x = pe.y = 0x1FFF
        pe.insn = 0x1FFFF
        payload = pe.request(P.OP_READ_CPU).payload
        self.assertEqual(payload[1], 0x3FF)        # pc 10 bits
        self.assertEqual(payload[2], 0xFF)         # a 8 bits
        self.assertEqual(payload[3], 0xFF)         # x 8 bits
        self.assertEqual(payload[4], 0xFF)         # y 8 bits
        self.assertEqual(payload[5], 0xFFFF)       # insn 16 bits

    def test_status_header_registers_are_isa_native(self):
        pe = F.FakePE()
        pe.a = 0x1FFF
        payload = pe.request(P.OP_STATUS).payload
        # STATUS: status, state, run, target, pc, a, x, y, timer, faults, words
        self.assertEqual(payload[5], 0xFF)

    def test_golden_vectors_use_no_wider_than_isa_values(self):
        from tools.host_gui import r2_vectors as V
        package = V.build_package()
        widths = {"pc": F.ISA_PC_BITS, "a": F.ISA_A_BITS, "x": F.ISA_X_BITS,
                  "y": F.ISA_Y_BITS, "insn": F.ISA_INSN_BITS}
        for vector in package["vectors"]:
            for step in vector["steps"]:
                payload = step["response_payload_words"]
                if step["opcode_name"] == "OP_READ_CPU":
                    for offset, (name, bits) in enumerate(widths.items(),
                                                          start=1):
                        with self.subTest(vector=vector["name"], field=name):
                            self.assertLess(payload[offset], 1 << bits)
                if step["opcode_name"] in ("OP_STATUS", "OP_DUMP_CORE"):
                    # A NOT_READY/one-word payload has no register header.
                    if len(payload) < 9 or step["status"] != P.STATUS_OK:
                        continue
                    for offset, (name, bits) in enumerate(
                            (("pc", F.ISA_PC_BITS), ("a", F.ISA_A_BITS),
                             ("x", F.ISA_X_BITS), ("y", F.ISA_Y_BITS)),
                            start=4):
                        with self.subTest(vector=vector["name"], field=name):
                            self.assertLess(payload[offset], 1 << bits)


if __name__ == "__main__":
    unittest.main(verbosity=2)
