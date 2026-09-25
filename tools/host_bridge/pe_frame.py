"""MicroPython-compatible PE frame codec for the Pico bridge.

The wire contract is the plan's framed protocol: 16-bit words, MSB-first,
CS-framed, CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no
final XOR). This module is the bridge's own copy so the Pico deployment needs
no host package; it is kept deliberately small and dependency-free (only
``collections.namedtuple``) and is tested against the shared golden vectors and
against ``tools/host_gui/protocol.py`` so the two cannot drift.
"""

from collections import namedtuple

SYNC = 0xA55A
VERSION = 1

RESPONSE_BIT = 0x80

HEADER_WORDS = 4  # sync, header, sequence, length
TRAILER_WORDS = 1  # CRC
MIN_FRAME_WORDS = HEADER_WORDS + TRAILER_WORDS
MAX_PAYLOAD_WORDS = 0xFFFF

OP_PING = 0x01
OP_LOAD = 0x10
OP_STATUS = 0x11
OP_READ_CPU = 0x12
OP_READ_IMEM = 0x13
OP_READ_DMEM = 0x14
OP_DUMP_CORE = 0x15
OP_CLEAR_FAULT = 0x16
OP_TARGET = 0x20

# R3 debug-control opcodes (NOT chip-confirmed: the R3 contract is a chip-side
# draft under the manager's dispatch). The opcode NUMBERS are fixed by that
# dispatch; the response layouts live in tools/host_gui/r3_reads.py and are
# provisional until rtl/pe_ctrl.v's header lands. This list must stay in parity
# with tools/host_gui/protocol.py so the Pico can speak the debug ops.
OP_DEBUG_STEP = 0x21
OP_DEBUG_BP_SET = 0x22
OP_DEBUG_BP_CLR = 0x23
OP_DEBUG_STATUS = 0x24

STATUS_OK = 0
STATUS_BUSY = 1
STATUS_BAD_FRAME = 2
STATUS_RANGE = 3
STATUS_FAULT = 4
STATUS_UNSUPPORTED = 5
STATUS_NOT_READY = 6

TARGET_HOST = 0
TARGET_LOOPBACK = 1

Frame = namedtuple("Frame", ("version", "opcode", "sequence", "target", "payload"))


class FrameError(Exception):
    """Any framing, length, CRC or version violation."""


def crc16_ccitt(data):
    """CRC-16/CCITT-FALSE over a bytes-like object; returns an int."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def words_to_bytes(words):
    """Pack 16-bit words big-endian (the MSB-first wire order).

    Strict on purpose. This used to call ``int(word)`` per word, which is
    LENIENT rather than safe: ``1.5`` silently encoded as ``1`` and ``"5"``
    encoded as ``5``, so a caller's bug became a plausible-looking frame on
    the wire instead of an error. A codec exists to be exact, so a word that
    is not an int in 0..0xFFFF is rejected here, at the boundary, rather
    than coerced. MicroPython-safe: isinstance, comparison and raise are all
    core MicroPython.
    """
    out = bytearray()
    for word in words:
        if not isinstance(word, int) or not 0 <= word <= 0xFFFF:
            raise ValueError(f"not a 16-bit word: {word!r}")
        out.append((word >> 8) & 0xFF)
        out.append(word & 0xFF)
    return bytes(out)


def bytes_to_words(data):
    """Unpack big-endian byte pairs into a tuple of 16-bit words."""
    words = []
    for index in range(0, len(data), 2):
        words.append((data[index] << 8) | data[index + 1])
    return tuple(words)


MAX_WAIT_WORDS = 15  # the chip's worst-case wait-word count (R2 contract)


def strip_wait_words(raw, max_wait=MAX_WAIT_WORDS):
    """Return the real frame from a response that may lead with 0xFFFF words.

    A bounded read cannot answer inside the request's bit times, so the chip
    drives 0xFFFF filler words on MISO and the real frame begins at the first
    non-0xFFFF WORD (chip R2 wait-word contract; worst case 15). The skip is
    leading-ONLY, so a 0xFFFF inside a payload is data. Raises FrameError if
    the stream is exhausted without a real frame, so the caller reports a
    timeout rather than decoding filler.
    """
    if len(raw) < 4:
        raise FrameError("response too short to hold a frame")
    words = bytes_to_words(raw[: len(raw) - (len(raw) % 2)])
    index = 0
    while index < len(words) and words[index] == 0xFFFF and index < max_wait:
        index += 1
    if index >= len(words) or words[index] == 0xFFFF:
        raise FrameError(f"no frame after {index} wait words (chip bound {max_wait})")
    return words_to_bytes(words[index:])


def encode_frame(opcode, sequence, target, payload=b""):
    """Encode one frame. ``payload`` is big-endian 16-bit words as bytes."""
    if not 0 <= opcode <= 0xFF:
        raise FrameError(f"opcode {opcode!r} does not fit 8 bits")
    if not 0 <= sequence <= 0xFFFF:
        raise FrameError(f"sequence {sequence!r} does not fit 16 bits")
    if not 0 <= target <= 0xF:
        raise FrameError(f"target {target!r} does not fit 4 bits")
    if len(payload) % 2:
        raise FrameError("payload is not whole 16-bit words")
    payload_words = len(payload) // 2
    if payload_words > MAX_PAYLOAD_WORDS:
        raise FrameError("payload exceeds the 16-bit length field")
    header = (VERSION << 12) | (opcode << 4) | target
    body = words_to_bytes((SYNC, header, sequence, payload_words)) + payload
    return body + crc16_ccitt(body).to_bytes(2, "big")


def decode_frame(raw):
    """Decode and validate one frame; raises ``FrameError``."""
    if len(raw) % 2:
        raise FrameError("frame is not whole 16-bit words")
    if len(raw) < MIN_FRAME_WORDS * 2:
        raise FrameError("frame is under the minimum length")
    words = bytes_to_words(raw)
    if words[0] != SYNC:
        raise FrameError(f"bad sync 0x{words[0]:04X}")
    payload_words = words[3]
    if len(words) != HEADER_WORDS + payload_words + TRAILER_WORDS:
        raise FrameError("length field does not match the frame")
    if crc16_ccitt(raw[:-2]) != words[-1]:
        raise FrameError("CRC mismatch")
    header = words[1]
    version = (header >> 12) & 0xF
    if version != VERSION:
        raise FrameError(f"unsupported version {version}")
    return Frame(
        version,
        (header >> 4) & 0xFF,
        words[2],
        header & 0xF,
        tuple(words[HEADER_WORDS : HEADER_WORDS + payload_words]),
    )
