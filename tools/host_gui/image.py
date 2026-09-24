"""Program-image contract: assemble .pe, validate, digest, manifest.

Contract source: wiki/plans/host-controller-gui.md, "Program-image format".
The ISA and the assembler are NOT changed: this module invokes
``tools/fw/peasm.py`` and validates its output.

  * refuse an image over 1,024 words (instruction memory depth);
  * never pad the image; the first contract sends exactly the words assembled;
  * manifest: source name, declared word count, load address zero, the 60 MHz
    operating point, and a SHA-256 over the canonical big-endian 16-bit word
    bytes (the same bytes that go on the SPI wire, MSB-first);
  * warn when a short image does not end in a terminal jump, because the tail
    of instruction memory is undefined on silicon (ADR-007).

Review correction recorded in
``reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md`` (row P23): the repo's
firmware convention is an **unconditional backward JMP back into the image**
(``JMP main``/``JMP poll``), not literally JMP-to-itself — only
``firmware/i2c_pins.pe`` ends in a true self-jump. The predicate below uses
the backward form; a literal self-jump is a subset of it.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

IMEM_WORDS = 1024
CLOCK_HZ = 60_000_000
LOAD_ADDRESS = 0

# pe_cpu ISA: [15:12] = opcode, jump targets live in arg[PCW-1:0].
JMP_OPCODE = 0x4
PCW = max(8, (IMEM_WORDS - 1).bit_length())     # 10 at 1024 words

_WORD_RE = re.compile(r"[0-9a-fA-F]{1,4}")


class ImageError(Exception):
    """Any .pe assembly, validation, or parsing failure."""


def parse_word_lines(text: str, limit: int = IMEM_WORDS) -> tuple[int, ...]:
    """Parse peasm's output: one hexadecimal 16-bit word per non-empty line."""
    words: list[int] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        token = line.strip()
        if not token:
            continue
        if not _WORD_RE.fullmatch(token):
            raise ImageError(
                f"line {lineno}: {token!r} is not a 1-4 digit hexadecimal word")
        words.append(int(token, 16))
        if len(words) > limit:
            raise ImageError(
                f"image is over {limit} words; instruction memory holds "
                f"{IMEM_WORDS} and the PC aliases word {IMEM_WORDS} onto word 0")
    return tuple(words)


def _has_terminal_jump(words: tuple[int, ...]) -> bool:
    """True when the last word is an unconditional JMP back into the image.

    A backward JMP is the repo's terminal convention. A conditional branch or
    a forward JMP can still fall off the end into undefined instruction memory,
    so neither counts.
    """
    if not words:
        return False
    last = words[-1]
    if (last >> 12) != JMP_OPCODE:
        return False
    target = last & ((1 << PCW) - 1)
    return target <= len(words) - 1


@dataclass(frozen=True)
class ProgramImage:
    source: str
    words: tuple[int, ...]
    sha256: str
    terminal_jump: bool
    warnings: tuple[str, ...]
    load_address: int = LOAD_ADDRESS
    clock_hz: int = CLOCK_HZ

    @property
    def word_count(self) -> int:
        return len(self.words)

    def manifest(self) -> dict[str, object]:
        return {
            "source": self.source,
            "word_count": self.word_count,
            "load_address": self.load_address,
            "clock_hz": self.clock_hz,
            "sha256": self.sha256,
            "terminal_jump": self.terminal_jump,
            "warnings": list(self.warnings),
        }

    def manifest_json(self) -> str:
        return json.dumps(self.manifest(), sort_keys=True, indent=2) + "\n"


def assemble_program(source: Path, repo_root: Path) -> ProgramImage:
    """Assemble ``source`` through tools/fw/peasm.py and validate the image."""
    source = Path(source)
    if not source.is_file():
        raise ImageError(f"source file not found: {source}")

    peasm = Path(repo_root) / "tools" / "fw" / "peasm.py"
    if not peasm.is_file():
        raise ImageError(f"assembler not found: {peasm}")

    with tempfile.TemporaryDirectory(prefix="pe_image_") as td:
        out = Path(td) / "image.hex"
        proc = subprocess.run(
            [sys.executable, str(peasm), str(source), "-o", str(out)],
            capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout).strip()
            raise ImageError(f"peasm failed for {source.name}: {detail}")
        text = out.read_text(encoding="utf-8")

    words = parse_word_lines(text)
    if not words:
        raise ImageError(f"assembler produced no words for {source.name}")

    digest = hashlib.sha256(
        b"".join(w.to_bytes(2, "big") for w in words)).hexdigest()
    terminal = _has_terminal_jump(words)
    warnings: list[str] = []
    if len(words) < IMEM_WORDS and not terminal:
        warnings.append(
            f"image is {len(words)} of {IMEM_WORDS} words and does not end in a "
            f"terminal backward jump; instruction memory past word "
            f"{len(words) - 1} is undefined")
    return ProgramImage(source=source.name, words=words, sha256=digest,
                        terminal_jump=terminal, warnings=tuple(warnings))
