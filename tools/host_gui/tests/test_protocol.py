"""Tests for tools/host_gui/protocol.py — the PE host frame contract.

Contract source: wiki/plans/host-controller-gui.md, "PE host protocol":
  word 0      sync 16'hA55A
  word 1      {version[3:0], opcode[7:0], target[3:0]}
  word 2      sequence
  word 3      payload length in 16-bit words
  word 4..N   payload (big-endian words on the wire)
  word N+1    CRC-16/CCITT-FALSE over all preceding words

CRC: polynomial 16'h1021, init 16'hFFFF, no reflection, no final XOR.
Golden CRC bytes below were produced by an independent bit-by-bit reference
implementation (the one embedded in `test_crc_matches_bitwise_reference`),
so the implementation is measured against a second algorithm, not itself.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from tools.host_gui import protocol as P

# Shared with tools/host_bridge/tests/test_bridge.py: the bridge's
# MicroPython-compatible pe_frame.py must produce these exact bytes, and so
# must this module. One file checks both implementations against each other.
GOLDEN = (Path(__file__).resolve().parents[2] / "host_bridge" / "tests"
          / "golden_vectors.json")


def words_of(raw: bytes) -> list[int]:
    return [int.from_bytes(raw[i:i + 2], "big") for i in range(0, len(raw), 2)]


def frame_words(
    opcode: int,
    sequence: int,
    target: int,
    payload: bytes = b"",
    version: int = P.VERSION,
) -> list[int]:
    """Build a raw word list (independent of the module's encoder)."""
    header = (version << 12) | (opcode << 4) | target
    body = words_of(
        b"".join(w.to_bytes(2, "big") for w in (P.SYNC, header, sequence,
                                                len(payload) // 2)) + payload
    )
    return [P.SYNC, header, sequence, len(payload) // 2, *words_of(payload),
            P.crc16_ccitt(b"".join(w.to_bytes(2, "big") for w in body))]


class TestCRC(unittest.TestCase):
    def test_crc_ccitt_false_check_value(self):
        # RevEng catalogue "123456789" check value for CRC-16/CCITT-FALSE.
        self.assertEqual(P.crc16_ccitt(b"123456789"), 0x29B1)

    def test_crc_empty_uses_init(self):
        self.assertEqual(P.crc16_ccitt(b""), 0xFFFF)

    def test_crc_known_vectors(self):
        self.assertEqual(P.crc16_ccitt(b"A"), 0xB915)
        self.assertEqual(P.crc16_ccitt(b"\x00"), 0xE1F0)
        self.assertEqual(P.crc16_ccitt(b"\xff"), 0xFF00)

    def test_crc_matches_bitwise_reference(self):
        """Independent shift-register reference over varied inputs."""
        def reference(data: bytes) -> int:
            crc = 0xFFFF
            for byte in data:
                crc ^= byte << 8
                for _ in range(8):
                    if crc & 0x8000:
                        crc = ((crc << 1) ^ 0x1021) & 0xFFFF
                    else:
                        crc = (crc << 1) & 0xFFFF
            return crc

        cases = [
            b"", b"\x00", b"\xff", b"A", b"123456789",
            bytes(range(256)),
            bytes((i * 37) & 0xFF for i in range(1000)),
        ]
        for data in cases:
            with self.subTest(length=len(data)):
                self.assertEqual(P.crc16_ccitt(data), reference(data))


class TestEncodeDecode(unittest.TestCase):
    def test_ping_frame_round_trips(self):
        raw = P.encode_frame(P.OP_PING, 7, P.TARGET_HOST, b"")
        frame = P.decode_frame(raw)
        self.assertEqual(frame.opcode, P.OP_PING)
        self.assertEqual(frame.sequence, 7)
        self.assertEqual(frame.target, P.TARGET_HOST)
        self.assertEqual(frame.version, P.VERSION)
        self.assertEqual(frame.payload, ())

    def test_ping_golden_bytes(self):
        self.assertEqual(
            P.encode_frame(P.OP_PING, 7, P.TARGET_HOST, b"").hex().upper(),
            "A5 5A 10 10 00 07 00 00 7D FE".replace(" ", ""),
        )

    def test_read_imem_golden_bytes(self):
        raw = P.encode_frame(P.OP_READ_IMEM, 1, P.TARGET_HOST,
                             bytes([0x00, 0x10, 0x00, 0x20]))
        self.assertEqual(
            raw.hex().upper(),
            "A55A113000010002" "00100020C9BE",
        )
        frame = P.decode_frame(raw)
        self.assertEqual(frame.payload, (0x0010, 0x0020))

    def test_response_frame_golden_bytes(self):
        # A response is an opcode with bit 7 set; STATUS|0x80 = 0x91.
        raw = P.encode_frame(P.OP_STATUS | P.RESPONSE_BIT, 7, P.TARGET_HOST,
                             b"\x00\x00")
        self.assertEqual(
            raw.hex().upper(),
            "A55A191000070001" "00001EED",
        )
        frame = P.decode_frame(raw)
        self.assertTrue(frame.is_response)
        self.assertEqual(frame.status, P.STATUS_OK)

    def test_payload_words_are_big_endian(self):
        raw = P.encode_frame(P.OP_LOAD, 2, P.TARGET_HOST, b"\x12\x34\xAB\xCD")
        self.assertEqual(words_of(raw)[4:6], [0x1234, 0xABCD])
        self.assertEqual(P.decode_frame(raw).payload, (0x1234, 0xABCD))

    def test_payload_bytes_property_is_canonical(self):
        frame = P.decode_frame(
            P.encode_frame(P.OP_LOAD, 2, P.TARGET_HOST, b"\x12\x34\xAB\xCD"))
        self.assertEqual(frame.payload_bytes, b"\x12\x34\xAB\xCD")

    def test_decode_encode_round_trip_via_to_bytes(self):
        raw = P.encode_frame(P.OP_TARGET, 0x1234, P.TARGET_LOOPBACK, b"\x00\x01")
        self.assertEqual(P.decode_frame(raw).to_bytes(), raw)

    def test_all_plan_opcodes_round_trip(self):
        opcodes = [
            P.OP_PING, P.OP_LOAD, P.OP_STATUS, P.OP_READ_CPU,
            P.OP_READ_IMEM, P.OP_READ_DMEM, P.OP_DUMP_CORE,
            P.OP_CLEAR_FAULT, P.OP_TARGET,
        ]
        for opcode in opcodes:
            with self.subTest(opcode=hex(opcode)):
                frame = P.decode_frame(P.encode_frame(opcode, 3, 1, b"\x00\x00"))
                self.assertEqual(frame.opcode, opcode)
                self.assertFalse(frame.is_response)

    def test_empty_payload_round_trips(self):
        frame = P.decode_frame(P.encode_frame(P.OP_STATUS, 0, 0, b""))
        self.assertEqual(frame.payload, ())
        self.assertIsNone(frame.status)

    def test_max_length_payload_round_trips(self):
        payload = bytes(range(256)) * 4  # 1024 bytes = 512 words
        frame = P.decode_frame(P.encode_frame(P.OP_LOAD, 9, 0, payload))
        self.assertEqual(frame.payload_bytes, payload)


class TestDecodeErrors(unittest.TestCase):
    def test_typed_errors_share_the_frame_error_base(self):
        for exc in (P.FrameSyncError, P.FrameLengthError, P.FrameCRCError,
                    P.FrameVersionError, P.FrameValueError):
            self.assertTrue(issubclass(exc, P.FrameError))

    def test_crc_mismatch_is_rejected(self):
        raw = bytearray(P.encode_frame(P.OP_STATUS, 1, P.TARGET_HOST, b""))
        raw[-1] ^= 0x01
        with self.assertRaises(P.FrameCRCError):
            P.decode_frame(bytes(raw))

    def test_bad_sync_is_rejected(self):
        raw = bytearray(P.encode_frame(P.OP_PING, 1, 0, b""))
        raw[0] ^= 0x01
        with self.assertRaises(P.FrameSyncError):
            P.decode_frame(bytes(raw))

    def test_bad_version_is_rejected(self):
        # A CRC-valid frame carrying version 2.
        words = frame_words(P.OP_PING, 1, 0, b"", version=2)
        raw = b"".join(w.to_bytes(2, "big") for w in words)
        with self.assertRaises(P.FrameVersionError):
            P.decode_frame(raw)

    def test_length_field_mismatch_is_rejected(self):
        words = frame_words(P.OP_PING, 1, 0, b"")
        words[3] = 1  # declare one payload word that is not there
        raw = b"".join(w.to_bytes(2, "big") for w in words)
        with self.assertRaises(P.FrameLengthError):
            P.decode_frame(raw)

    def test_truncated_frame_is_rejected(self):
        raw = P.encode_frame(P.OP_PING, 1, 0, b"")
        with self.assertRaises(P.FrameLengthError):
            P.decode_frame(raw[:8])

    def test_odd_byte_length_is_rejected(self):
        raw = P.encode_frame(P.OP_PING, 1, 0, b"") + b"\x00"
        with self.assertRaises(P.FrameLengthError):
            P.decode_frame(raw)

    def test_empty_input_is_rejected(self):
        with self.assertRaises(P.FrameLengthError):
            P.decode_frame(b"")


class TestEncodeErrors(unittest.TestCase):
    def test_odd_payload_is_rejected(self):
        with self.assertRaises(P.FrameValueError):
            P.encode_frame(P.OP_LOAD, 0, 0, b"\x01")

    def test_opcode_out_of_range_is_rejected(self):
        with self.assertRaises(P.FrameValueError):
            P.encode_frame(0x100, 0, 0, b"")

    def test_sequence_out_of_range_is_rejected(self):
        with self.assertRaises(P.FrameValueError):
            P.encode_frame(P.OP_PING, 0x1_0000, 0, b"")

    def test_target_out_of_range_is_rejected(self):
        with self.assertRaises(P.FrameValueError):
            P.encode_frame(P.OP_TARGET, 0, 0x10, b"")

    def test_payload_too_long_is_rejected(self):
        payload = b"\x00" * (2 * (P.MAX_PAYLOAD_WORDS + 1))
        with self.assertRaises(P.FrameValueError):
            P.encode_frame(P.OP_LOAD, 0, 0, payload)


class TestFrameSemantics(unittest.TestCase):
    def test_response_bit_marks_responses(self):
        self.assertTrue(P.decode_frame(
            P.encode_frame(P.OP_STATUS | P.RESPONSE_BIT, 0, 0, b"")).is_response)
        self.assertFalse(P.decode_frame(
            P.encode_frame(P.OP_STATUS, 0, 0, b"")).is_response)

    def test_status_is_first_response_payload_word(self):
        frame = P.decode_frame(P.encode_frame(
            P.OP_STATUS | P.RESPONSE_BIT, 0, 0, b"\x00\x03"))
        self.assertEqual(frame.status, P.STATUS_RANGE)

    def test_status_is_none_on_requests(self):
        frame = P.decode_frame(P.encode_frame(P.OP_STATUS, 0, 0, b"\x00\x03"))
        self.assertIsNone(frame.status)

    def test_status_codes_match_the_plan(self):
        self.assertEqual(
            (P.STATUS_OK, P.STATUS_BUSY, P.STATUS_BAD_FRAME, P.STATUS_RANGE,
             P.STATUS_FAULT, P.STATUS_UNSUPPORTED, P.STATUS_NOT_READY),
            (0, 1, 2, 3, 4, 5, 6),
        )

    def test_opcode_layout_matches_the_plan(self):
        # version in [15:12], opcode in [11:4], target in [3:0].
        raw = P.encode_frame(P.OP_TARGET, 0, 5, b"")
        header = words_of(raw)[1]
        self.assertEqual((header >> 12) & 0xF, 1)
        self.assertEqual((header >> 4) & 0xFF, P.OP_TARGET)
        self.assertEqual(header & 0xF, 5)


class TestSharedGoldenVectors(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.golden = json.loads(GOLDEN.read_text(encoding="utf-8"))

    def test_crc_vectors(self):
        for entry in self.golden["crc"]:
            with self.subTest(data=entry["data_hex"]):
                self.assertEqual(
                    P.crc16_ccitt(bytes.fromhex(entry["data_hex"])),
                    int(entry["crc"], 16))

    def test_frame_vectors(self):
        for entry in self.golden["frames"]:
            with self.subTest(name=entry["name"]):
                payload = bytes.fromhex(entry["payload_hex"])
                raw = P.encode_frame(entry["opcode"], entry["sequence"],
                                     entry["target"], payload)
                self.assertEqual(raw.hex(), entry["frame_hex"])
                frame = P.decode_frame(raw)
                self.assertEqual(frame.opcode, entry["opcode"])
                self.assertEqual(frame.sequence, entry["sequence"])
                self.assertEqual(frame.target, entry["target"])
                self.assertEqual(frame.payload_bytes, payload)


if __name__ == "__main__":
    unittest.main(verbosity=2)
