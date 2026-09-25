"""Fake-SDK tests for the concrete Tiny Tapeout adapter (plan Task 2 Step 4).

``tt_adapter.TTAdapter`` is board-only code, but everything it does is a
bounded set of SDK calls. These tests install a fake ``ttboard``/``machine``
in ``sys.modules`` and record those calls, so the plan's Step 1 requirement --
the fake must record project selection, clock, reset, run and ``uio_oe_pico``
-- is met for the adapter itself, not only for the HAL below it.
"""

from __future__ import annotations

import sys
import types
import unittest

from tools.host_bridge import tt_adapter as A

PINS = {"sck": 2, "mosi": 3, "miso": 4}


class FakeProject:
    def __init__(self, name):
        self.name = name
        self.enabled = 0

    def enable(self):
        self.enabled += 1


class FakeShuttle:
    def __init__(self, *names):
        self.projects = {name: FakeProject(name) for name in names}

    def __getattr__(self, name):
        try:
            return self.projects[name]
        except KeyError as exc:
            raise AttributeError(name) from exc

    def find(self, name):
        return [project for key, project in self.projects.items() if name in key]


class FakeDemoBoard:
    def __init__(self):
        self.shuttle = FakeShuttle("tt_um_protocol_emulator", "tt_um_other")
        self.mode = None
        self.ui_in = [0] * 8
        self.uo_out = [0] * 8
        self.uio_out = [0] * 8
        self.uio_oe_pico = types.SimpleNamespace(value=0)
        self.clock_calls = []
        self.reset_calls = []

    def clock_project_PWM(self, hz):
        self.clock_calls.append(hz)

    def reset_project(self, active):
        self.reset_calls.append(active)


def install_fake_sdk():
    """Install fake SDK modules; return (recorded state, sys.modules map).

    The fake SPI is a STREAM: each ``write_readinto`` returns the next bytes
    of ``state.response`` (via a cursor), exactly as real SPI shifts MISO out
    during the request and keeps clocking afterwards. That is what makes
    variable-length (wait-word) responses testable — the fixed-length double
    that echoed the whole response every call is precisely why B1 was invisible.
    """
    state = types.SimpleNamespace(
        board=FakeDemoBoard(),
        spi_params=None,
        spi_calls=[],
        pin_calls=[],
        response=b"",
        boom=False,
        cursor=0,
        max_words=None,          # optional cap the bridge must respect
    )

    class Pin:
        def __init__(self, gpio):
            self.gpio = gpio
            state.pin_calls.append(gpio)

    class SPI:
        def __init__(self, spi_id, baudrate, polarity, phase, sck, mosi, miso):
            state.spi_params = {
                "spi_id": spi_id, "baudrate": baudrate, "polarity": polarity,
                "phase": phase, "sck": sck, "mosi": mosi, "miso": miso,
            }

        def write_readinto(self, data, received):
            state.spi_calls.append(
                {"cs_n": state.board.uio_out[A.PAD_CS_N], "tx": bytes(data),
                 "cursor": state.cursor})
            if state.boom:
                raise OSError("spi down")
            # Stream out the next len(received) bytes of the response; past the
            # end, MISO idles (the chip released it) as zeros.
            for index in range(len(received)):
                if state.cursor < len(state.response):
                    received[index] = state.response[state.cursor]
                    state.cursor += 1
                else:
                    received[index] = 0x00

    class DemoBoard:
        @staticmethod
        def get():
            return state.board

    class RPMode:
        ASIC_RP_CONTROL = "ASIC_RP_CONTROL"

    demoboard = types.ModuleType("ttboard.demoboard")
    demoboard.DemoBoard = DemoBoard
    mode = types.ModuleType("ttboard.mode")
    mode.RPMode = RPMode
    ttboard = types.ModuleType("ttboard")
    ttboard.demoboard = demoboard
    ttboard.mode = mode
    machine = types.ModuleType("machine")
    machine.SPI = SPI
    machine.Pin = Pin

    modules = {"ttboard": ttboard, "ttboard.demoboard": demoboard,
               "ttboard.mode": mode, "machine": machine}
    return state, modules


class TestTTAdapter(unittest.TestCase):
    def setUp(self):
        self.state, modules = install_fake_sdk()
        self._saved = {}
        for name, module in modules.items():
            if name in sys.modules:
                self._saved[name] = sys.modules[name]
            sys.modules[name] = module

    def tearDown(self):
        for name in ("ttboard", "ttboard.demoboard", "ttboard.mode",
                     "machine"):
            sys.modules.pop(name, None)
        sys.modules.update(self._saved)

    def test_configure_host_spi_sets_direction_cs_and_pins(self):
        board = self.state.board
        # uio[0:1] firmware is already output; uio[6] is set so the test can
        # tell whether configure_host_spi actively hands MISO back to input.
        board.uio_oe_pico.value = 0b0100_0011
        adapter = A.TTAdapter(pins=PINS)
        adapter.configure_host_spi(5_000_000)

        direction = board.uio_oe_pico.value
        self.assertEqual(direction & 0b0000_0011, 0b0000_0011)   # uio[0:1]
        self.assertEqual((direction >> A.PAD_CS_N) & 1, 1)
        self.assertEqual((direction >> A.PAD_MOSI) & 1, 1)
        self.assertEqual((direction >> A.PAD_SCK) & 1, 1)
        self.assertEqual((direction >> A.PAD_MISO) & 1, 0)       # MISO input
        self.assertEqual(board.uio_out[A.PAD_CS_N], 1)           # idles high
        self.assertEqual(board.mode, "ASIC_RP_CONTROL")
        self.assertEqual(
            {key: self.state.spi_params[key]
             for key in ("spi_id", "baudrate", "polarity", "phase")},
            {"spi_id": 0, "baudrate": 5_000_000, "polarity": 0, "phase": 0})
        self.assertEqual(
            [self.state.spi_params[key].gpio
             for key in ("sck", "mosi", "miso")], [2, 3, 4])
        self.assertEqual(self.state.pin_calls, [2, 3, 4])

    def test_host_spi_transfer_holds_cs_low_and_releases(self):
        board = self.state.board
        adapter = A.TTAdapter(pins=PINS)
        adapter.configure_host_spi(5_000_000)
        # A real framed reply (STATUS): sync, hdr, seq, len, CRC. The request
        # is 3 words; the reply is 6 words, so the adapter MUST keep clocking
        # past the request length to collect it (variable-length).
        frame = bytes.fromhex("a55a1910000100010000" "1eed")
        self.state.response = frame
        received = adapter.host_spi_transfer(b"\x00" * 6,
                                              read_words=6)
        self.assertEqual(received, frame)
        self.assertEqual(self.state.spi_calls[0]["cs_n"], 0)
        # more than one clocking call was needed (6 words in, 6 words out)
        self.assertGreater(len(self.state.spi_calls), 1)
        self.assertEqual(board.uio_out[A.PAD_CS_N], 1)

    def test_host_spi_transfer_streams_beyond_the_request_length(self):
        # B1 regression: a response LONGER than the request must be read in
        # full by continuing to clock, not truncated to the request length.
        adapter = A.TTAdapter(pins=PINS)
        adapter.configure_host_spi(5_000_000)
        frame = bytes.fromhex("a55a1910000100010000" "1eed")  # 6 words
        self.state.response = frame
        received = adapter.host_spi_transfer(b"\x00" * 2, read_words=6)
        self.assertEqual(received, frame)

    def test_host_spi_transfer_skips_leading_wait_words(self):
        # B1 regression: the chip may drive up to 15 leading 0xFFFF filler
        # words before the real frame. The adapter returns the frame; the
        # bridge's pe_frame.strip_wait_words (tested there) removes fillers.
        adapter = A.TTAdapter(pins=PINS)
        adapter.configure_host_spi(5_000_000)
        frame = bytes.fromhex("a55a1910000100010000" "1eed")
        self.state.response = b"\xff\xff" * 2 + frame   # 2 wait words
        received = adapter.host_spi_transfer(b"\x00" * 2, read_words=8)
        # the adapter hands the raw stream; the wait words are still there ...
        self.assertTrue(received.startswith(b"\xff\xff\xff\xff"))
        # ... and the real frame is present after them
        self.assertIn(frame, received)

    def test_host_spi_transfer_releases_cs_on_error(self):
        board = self.state.board
        adapter = A.TTAdapter(pins=PINS)
        adapter.configure_host_spi(5_000_000)
        self.state.boom = True
        with self.assertRaises(OSError):
            adapter.host_spi_transfer(b"\x00\x00")
        self.assertEqual(board.uio_out[A.PAD_CS_N], 1)

    def test_project_clock_reset_and_run_calls(self):
        board = self.state.board
        adapter = A.TTAdapter(pins=PINS)
        adapter.enable_project("tt_um_protocol_emulator")
        self.assertEqual(
            board.shuttle.projects["tt_um_protocol_emulator"].enabled, 1)
        self.assertEqual(adapter.set_clock(60_000_000), 60_000_000)
        self.assertEqual(board.clock_calls, [60_000_000])
        adapter.reset(True)
        adapter.reset(False)
        self.assertEqual(board.reset_calls, [True, False])
        adapter.set_run(True)
        self.assertEqual(board.ui_in[A.RUN_UI_BIT], 1)
        adapter.set_run(False)
        self.assertEqual(board.ui_in[A.RUN_UI_BIT], 0)

    def test_project_lookup_falls_back_to_shuttle_find(self):
        board = self.state.board
        adapter = A.TTAdapter(pins=PINS)
        adapter.enable_project("other")
        self.assertEqual(board.shuttle.projects["tt_um_other"].enabled, 1)

    def test_unknown_project_raises(self):
        adapter = A.TTAdapter(pins=PINS)
        with self.assertRaises(RuntimeError):
            adapter.enable_project("tt_um_nope")

    def test_no_default_pin_map(self):
        adapter = A.TTAdapter()
        with self.assertRaises(RuntimeError):
            adapter.configure_host_spi(5_000_000)

    def test_irq_n_is_optional_and_active_low(self):
        adapter = A.TTAdapter(pins=PINS, irq_enabled=False)
        self.assertIsNone(adapter.irq_n())
        adapter = A.TTAdapter(pins=PINS, irq_enabled=True)
        self.state.board.uo_out[A.IRQ_UO_BIT] = 1
        self.assertFalse(adapter.irq_n())
        self.state.board.uo_out[A.IRQ_UO_BIT] = 0
        self.assertTrue(adapter.irq_n())


if __name__ == "__main__":
    unittest.main(verbosity=2)
