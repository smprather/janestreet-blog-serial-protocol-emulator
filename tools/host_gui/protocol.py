"""PE host frame contract: encode/decode, CRC-16/CCITT-FALSE, opcodes.

Contract source: wiki/plans/host-controller-gui.md, "PE host protocol". The
wire format is a sequence of 16-bit words, MSB-first, CS-framed:

    word 0        sync 16'hA55A
    word 1        {version[3:0], opcode[7:0], target[3:0]}
    word 2        sequence number
    word 3        payload length in 16-bit words
    word 4..N     payload words (big-endian on the wire)
    word N+1      CRC-16/CCITT-FALSE over all preceding words

The byte view is big-endian throughout: each word is two bytes, most
significant first. That is the same order the RTL shift register assembles
(rtl/pe_ctrl.v is MSB-first), so the host and the loader agree bit-for-bit.

CRC-16/CCITT-FALSE is polynomial 16'h1021, init 16'hFFFF, no input/output
reflection, no final XOR. Its RevEng catalogue check value is 0x29B1 for
"123456789"; the tests assert that plus an independent bit-by-bit reference.

This module is deliberately dependency-free (standard library only), so the
core regression and the bridge's MicroPython-compatible twin can share the
same golden vectors.
"""

from __future__ import annotations

from dataclasses import dataclass

# ---- physical framing constants ------------------------------------------
SYNC = 0xA55A
VERSION = 1

# {version[3:0], opcode[7:0], target[3:0]}
HEADER_WORDS = 4          # sync, header, sequence, length
TRAILER_WORDS = 1         # CRC
MIN_FRAME_WORDS = HEADER_WORDS + TRAILER_WORDS

RESPONSE_BIT = 0x80       # response opcodes set bit 7

MAX_OPCODE = 0xFF
MAX_SEQUENCE = 0xFFFF
MAX_TARGET = 0xF
MAX_PAYLOAD_WORDS = 0xFFFF

# ---- opcodes (plan "The initial opcode set is") --------------------------
OP_PING = 0x01
OP_LOAD = 0x10
OP_STATUS = 0x11
OP_READ_CPU = 0x12
OP_READ_IMEM = 0x13
OP_READ_DMEM = 0x14
OP_DUMP_CORE = 0x15
OP_CLEAR_FAULT = 0x16
OP_TARGET = 0x20

# ---- R3 debug-control opcodes (NOT CHIP-CONFIRMED) -----------------------
# The R3 wire contract is a DRAFT being drafted chip-side (manager dispatch
# 2026-09-25: opcodes 0x21/0x22/0x23/0x24 in the same framed host bus,
# ready-immediate responses, same CRC/sequence/target rules). The opcode
# NUMBERS come from the dispatch and are therefore fixed; the RESPONSE
# LAYOUTS below are the host's provisional reading and every one of them is
# listed in `tools/host_gui/r3_reads.py` as a reconciliation item to check
# against rtl/pe_ctrl.v's header the moment it appears. Nothing here is
# evidence about silicon -- it is the host side of a contract still being
# written.
OP_DEBUG_STEP = 0x21
OP_DEBUG_BP_SET = 0x22
OP_DEBUG_BP_CLR = 0x23
OP_DEBUG_STATUS = 0x24

# Debug-control opcodes are ready-immediate: none of them is a bounded read,
# so none carries wait words (the R2 wait-word rule applies only to the reads).
R3_OPCODES = (OP_DEBUG_STEP, OP_DEBUG_BP_SET, OP_DEBUG_BP_CLR, OP_DEBUG_STATUS)

# ---- response status codes (first response payload word) -----------------
STATUS_OK = 0
STATUS_BUSY = 1
STATUS_BAD_FRAME = 2
STATUS_RANGE = 3
STATUS_FAULT = 4
STATUS_UNSUPPORTED = 5
STATUS_NOT_READY = 6

# ---- targets --------------------------------------------------------------
TARGET_HOST = 0
TARGET_LOOPBACK = 1


class FrameError(Exception):
    """Base class for every frame contract violation."""


class FrameValueError(FrameError):
    """A value that cannot be encoded into a field (host-side bug)."""


class FrameSyncError(FrameError):
    """The first word is not SYNC."""


class FrameLengthError(FrameError):
    """Byte/word/field length mismatches: odd bytes, short frame, bad length."""


class FrameCRCError(FrameError):
    """The trailing CRC does not match the frame body."""


class FrameVersionError(FrameError):
    """The header's version nibble is not VERSION."""


def crc16_ccitt(data: bytes) -> int:
    """CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection/XOR."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def _words_from_bytes(raw: bytes) -> tuple[int, ...]:
    return tuple(int.from_bytes(raw[i:i + 2], "big")
                 for i in range(0, len(raw), 2))


def _bytes_from_words(words: tuple[int, ...]) -> bytes:
    return b"".join(w.to_bytes(2, "big") for w in words)


@dataclass(frozen=True)
class Frame:
    """A decoded frame. ``payload`` holds 16-bit words, not raw bytes."""

    version: int
    opcode: int
    sequence: int
    target: int
    payload: tuple[int, ...]

    @property
    def is_response(self) -> bool:
        return bool(self.opcode & RESPONSE_BIT)

    @property
    def status(self) -> int | None:
        """First response payload word (the status code), else None."""
        if self.is_response and self.payload:
            return self.payload[0]
        return None

    @property
    def payload_bytes(self) -> bytes:
        return _bytes_from_words(self.payload)

    def to_bytes(self) -> bytes:
        return encode_frame(self.opcode, self.sequence, self.target,
                            self.payload_bytes)


def encode_frame(opcode: int, sequence: int, target: int,
                 payload: bytes = b"") -> bytes:
    """Encode one frame. ``payload`` is big-endian 16-bit words as bytes."""
    if not 0 <= opcode <= MAX_OPCODE:
        raise FrameValueError(f"opcode {opcode!r} does not fit 8 bits")
    if not 0 <= sequence <= MAX_SEQUENCE:
        raise FrameValueError(f"sequence {sequence!r} does not fit 16 bits")
    if not 0 <= target <= MAX_TARGET:
        raise FrameValueError(f"target {target!r} does not fit 4 bits")
    if not isinstance(payload, (bytes, bytearray)):
        raise FrameValueError("payload must be bytes")
    payload = bytes(payload)
    if len(payload) % 2 != 0:
        raise FrameValueError(
            f"payload is {len(payload)} bytes, not whole 16-bit words")
    payload_words = len(payload) // 2
    if payload_words > MAX_PAYLOAD_WORDS:
        raise FrameValueError(
            f"payload is {payload_words} words, over the 16-bit length field")

    header = (VERSION << 12) | (opcode << 4) | target
    body = _bytes_from_words((SYNC, header, sequence, payload_words)) + payload
    return body + crc16_ccitt(body).to_bytes(2, "big")


MAX_WAIT_WORDS = 15   # the chip's worst-case wait words (R2 read contract)


def strip_wait_words(raw: bytes, max_wait: int = MAX_WAIT_WORDS) -> bytes:
    """Return the real frame from a response that may lead with 0xFFFF words.

    Mirrors ``tools/host_bridge/pe_frame.py`` (the Pico cannot import the host
    package, so the codec is kept in two copies that a fuzzer and a parity
    test tie together). Leading-ONLY and bounded, so a 0xFFFF inside a payload
    is data. Raises ``FrameError`` if no real frame follows, so an all-filler
    stream is a timeout rather than a bogus decode.
    """
    if len(raw) < 4:
        raise FrameLengthError("response too short to hold a frame")
    words = _words_from_bytes(bytes(raw)[:len(raw) - (len(raw) % 2)])
    index = 0
    while index < len(words) and words[index] == 0xFFFF and index < max_wait:
        index += 1
    if index >= len(words) or words[index] == 0xFFFF:
        raise FrameCRCError(
            f"no frame after {index} wait words (chip bound {max_wait})")
    return _bytes_from_words(words[index:])


def decode_frame(raw: bytes) -> Frame:
    """Decode and validate one frame. Raises a typed ``FrameError``."""
    if not isinstance(raw, (bytes, bytearray)):
        raise FrameLengthError("frame must be bytes")
    raw = bytes(raw)
    if len(raw) % 2 != 0:
        raise FrameLengthError(
            f"frame is {len(raw)} bytes, not whole 16-bit words")
    if len(raw) < MIN_FRAME_WORDS * 2:
        raise FrameLengthError(
            f"frame is {len(raw)} bytes, under the {MIN_FRAME_WORDS}-word minimum")

    words = _words_from_bytes(raw)
    if words[0] != SYNC:
        raise FrameSyncError(
            f"first word is 0x{words[0]:04X}, expected 0x{SYNC:04X}")

    payload_words = words[3]
    expected_words = HEADER_WORDS + payload_words + TRAILER_WORDS
    if len(words) != expected_words:
        raise FrameLengthError(
            f"frame carries {len(words)} words; the length field declares "
            f"{payload_words} payload words, so {expected_words} were expected")

    if crc16_ccitt(raw[:-2]) != words[-1]:
        raise FrameCRCError(
            f"CRC is 0x{words[-1]:04X}, computed 0x{crc16_ccitt(raw[:-2]):04X}")

    header = words[1]
    version = (header >> 12) & 0xF
    if version != VERSION:
        raise FrameVersionError(
            f"version {version} is not supported (this host speaks {VERSION})")

    opcode = (header >> 4) & 0xFF
    target = header & 0xF
    payload = tuple(words[HEADER_WORDS:HEADER_WORDS + payload_words])
    return Frame(version=version, opcode=opcode, sequence=words[2],
                 target=target, payload=payload)
