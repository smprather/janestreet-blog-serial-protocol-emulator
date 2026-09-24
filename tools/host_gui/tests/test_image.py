"""Tests for tools/host_gui/image.py — .pe assembly, manifest, digest.

Contract source: wiki/plans/host-controller-gui.md, "Program-image format":
  * assemble through tools/fw/peasm.py; do not change the ISA;
  * refuse more than 1,024 words; never pad the image;
  * manifest: source name, word count, load address zero, 60 MHz clock,
    SHA-256 of the canonical big-endian 16-bit word bytes;
  * a short image must end in a terminal jump (review correction: the repo's
    convention is an unconditional backward JMP, not literally JMP-to-itself —
    see reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md, row P23).
"""

from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path

from tools.host_gui import image as I

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
ECHO = FIXTURES / "echo.pe"
OVERSIZE = FIXTURES / "oversize.pe"

# echo.pe assembles to these words (verified against peasm.py directly):
#   LDI A, 0x41 -> 0x0041; OUT TXPIN, A -> 0x1001; loop: JMP loop -> 0x4002
ECHO_WORDS = (0x0041, 0x1001, 0x4002)


def canonical_digest(words: tuple[int, ...]) -> str:
    return hashlib.sha256(
        b"".join(w.to_bytes(2, "big") for w in words)).hexdigest()


class TestAssembleProgram(unittest.TestCase):
    def test_echo_fixture_words(self):
        self.assertEqual(I.assemble_program(ECHO, REPO_ROOT).words, ECHO_WORDS)

    def test_assemble_program_returns_words_and_digest(self):
        image = I.assemble_program(ECHO, REPO_ROOT)
        self.assertGreater(image.word_count, 0)
        self.assertEqual(len(image.sha256), 64)

    def test_sha256_is_canonical_big_endian_words(self):
        image = I.assemble_program(ECHO, REPO_ROOT)
        self.assertEqual(image.sha256, canonical_digest(ECHO_WORDS))

    def test_words_are_a_tuple_of_int16(self):
        image = I.assemble_program(ECHO, REPO_ROOT)
        self.assertIsInstance(image.words, tuple)
        self.assertTrue(all(isinstance(w, int) and 0 <= w <= 0xFFFF
                            for w in image.words))

    def test_source_name_is_recorded(self):
        self.assertEqual(I.assemble_program(ECHO, REPO_ROOT).source, "echo.pe")

    def test_oversize_image_is_rejected(self):
        with self.assertRaises(I.ImageError) as ctx:
            I.assemble_program(OVERSIZE, REPO_ROOT)
        self.assertIn("1024", str(ctx.exception))

    def test_missing_source_is_rejected(self):
        with self.assertRaises(I.ImageError):
            I.assemble_program(FIXTURES / "does-not-exist.pe", REPO_ROOT)

    def test_assembler_failure_is_wrapped(self):
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / "bad.pe"
            bad.write_text("        BOGUS A, 1\n", encoding="utf-8")
            with self.assertRaises(I.ImageError) as ctx:
                I.assemble_program(bad, REPO_ROOT)
        self.assertIn("BOGUS", str(ctx.exception))

    def test_empty_program_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            empty = Path(td) / "empty.pe"
            empty.write_text("; nothing here\n", encoding="utf-8")
            with self.assertRaises(I.ImageError):
                I.assemble_program(empty, REPO_ROOT)

    def test_assemble_does_not_touch_the_source(self):
        before = ECHO.read_bytes()
        I.assemble_program(ECHO, REPO_ROOT)
        self.assertEqual(ECHO.read_bytes(), before)


class TestManifest(unittest.TestCase):
    def test_manifest_fields(self):
        image = I.assemble_program(ECHO, REPO_ROOT)
        manifest = image.manifest()
        self.assertEqual(manifest["source"], "echo.pe")
        self.assertEqual(manifest["word_count"], 3)
        self.assertEqual(manifest["load_address"], 0)
        self.assertEqual(manifest["clock_hz"], 60_000_000)
        self.assertEqual(manifest["sha256"], canonical_digest(ECHO_WORDS))
        self.assertTrue(manifest["terminal_jump"])
        self.assertEqual(manifest["warnings"], [])

    def test_manifest_json_round_trips(self):
        import json
        image = I.assemble_program(ECHO, REPO_ROOT)
        self.assertEqual(json.loads(image.manifest_json()), image.manifest())


class TestTerminalJump(unittest.TestCase):
    def _assemble_text(self, text: str) -> I.ProgramImage:
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        src = Path(td.name) / "prog.pe"
        src.write_text(text, encoding="utf-8")
        return I.assemble_program(src, REPO_ROOT)

    def test_terminal_backward_jump_has_no_warning(self):
        # The repo's firmware convention: end with JMP back into the image.
        image = self._assemble_text("start:\n        LDI A, 1\n        JMP start\n")
        self.assertTrue(image.terminal_jump)
        self.assertEqual(image.warnings, ())

    def test_terminal_self_jump_has_no_warning(self):
        image = self._assemble_text("here:\n        JMP here\n")
        self.assertTrue(image.terminal_jump)
        self.assertEqual(image.warnings, ())

    def test_missing_terminal_jump_warns(self):
        image = self._assemble_text("        LDI A, 1\n        NOP\n")
        self.assertFalse(image.terminal_jump)
        self.assertEqual(len(image.warnings), 1)
        self.assertIn("terminal", image.warnings[0])
        self.assertIn("undefined", image.warnings[0])

    def test_conditional_jump_is_not_terminal(self):
        # JNZ can fall through, so it is not a terminal guard.
        image = self._assemble_text("        LDI A, 1\n        JNZ later\nlater:  NOP\n")
        self.assertFalse(image.terminal_jump)
        self.assertEqual(len(image.warnings), 1)

    def test_forward_jump_is_not_terminal(self):
        image = self._assemble_text("        JMP last\n        NOP\nlast:   NOP\n")
        self.assertFalse(image.terminal_jump)


class TestParseWordLines(unittest.TestCase):
    def test_parses_hex_words(self):
        self.assertEqual(I.parse_word_lines("0041\n1001\n4002\n"),
                         (0x0041, 0x1001, 0x4002))

    def test_blank_lines_and_whitespace_are_ignored(self):
        self.assertEqual(I.parse_word_lines("\n  0041  \n\n4002\n"),
                         (0x0041, 0x4002))

    def test_non_hex_word_is_rejected(self):
        with self.assertRaises(I.ImageError):
            I.parse_word_lines("gggg\n")

    def test_word_out_of_range_is_rejected(self):
        with self.assertRaises(I.ImageError):
            I.parse_word_lines("10000\n")

    def test_too_many_words_is_rejected(self):
        with self.assertRaises(I.ImageError):
            I.parse_word_lines("\n".join(["0000"] * 1025))


class TestConstants(unittest.TestCase):
    def test_limits_match_the_contract(self):
        self.assertEqual(I.IMEM_WORDS, 1024)
        self.assertEqual(I.CLOCK_HZ, 60_000_000)
        self.assertEqual(I.LOAD_ADDRESS, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
