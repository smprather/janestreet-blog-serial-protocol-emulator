"""Fake hardware-adapter double for the Pico bridge tests.

Implements the same duck-typed HAL as ``tools.host_bridge.tt_adapter.TTAdapter``
but routes framed SPI bytes to the host-side ``FakePE`` chip model, so the
bridge logic runs under CPython with no board, no tt SDK and no pyserial.
"""

from __future__ import annotations


class FakeTTAdapter:
    def __init__(self, pe, *, irq_supported: bool = False) -> None:
        self.pe = pe
        self.calls: list[tuple] = []
        self.project_calls: list[str] = []
        self.clock_calls: list[int] = []
        self.clock_stops = 0  # exists only to prove it is never called
        self.reset_calls: list[bool] = []
        self.run_calls: list[bool] = []
        self.spi_rates: list[int] = []
        self.transfers: list[bytes] = []
        # Test hooks
        self.fail_transfer = False  # raise OSError: simulate no MISO
        self.corrupt_responses = False
        self.run_lock = False  # ignore set_run: simulate a stuck strap
        self.wait_words = 0  # leading 0xFFFF filler before the frame
        # Trailing words the host clocked out AFTER the response, i.e. the
        # released pad's idle level. The real adapter always reads a fixed
        # budget (`read_words`) and gets whatever the pad says once the chip
        # stops driving it; modelling that is opt-in because the default here
        # is the historically forgiving "exactly the response" shape.
        self.idle_words = 0
        self.idle_value = 0x0000
        self._irq = False if irq_supported else None
        self._irq_supported = irq_supported

    # ---- test helpers ------------------------------------------------------
    def set_irq(self, asserted: bool) -> None:
        if not self._irq_supported:
            raise RuntimeError("IRQ is not supported by this adapter")
        self._irq = bool(asserted)

    # ---- HAL ---------------------------------------------------------------
    def enable_project(self, name: str) -> None:
        self.project_calls.append(name)
        self.calls.append(("enable_project", name))

    def set_clock(self, hz: int) -> int:
        self.clock_calls.append(hz)
        self.calls.append(("set_clock", hz))
        return hz

    def stop_clock(self) -> None:  # not part of the HAL contract
        self.clock_stops += 1

    def reset(self, active: bool) -> None:
        self.reset_calls.append(bool(active))
        self.calls.append(("reset", bool(active)))

    def set_run(self, active: bool) -> None:
        active = bool(active)
        self.run_calls.append(active)
        self.calls.append(("set_run", active))
        if not self.run_lock:
            self.pe.run = active

    def configure_host_spi(self, sclk_hz: int) -> None:
        self.spi_rates.append(sclk_hz)
        self.calls.append(("configure_host_spi", sclk_hz))

    def host_spi_transfer(self, data: bytes, read_words: int | None = None) -> bytes:
        if self.fail_transfer:
            raise OSError("no MISO")
        self.transfers.append(bytes(data))
        self.calls.append(("spi_transfer", len(data)))
        response = self.pe.exchange(bytes(data)) or b""
        if self.corrupt_responses and response:
            corrupted = bytearray(response)
            corrupted[-1] ^= 0xFF
            response = bytes(corrupted)
        if self.wait_words:
            # The chip's bounded reads may emit leading 0xFFFF filler words.
            response = b"\xff\xff" * self.wait_words + response
        if self.idle_words:
            # The words the host clocked out past the response: the pad is
            # RELEASED then (pe_ctrl asserts miso_oe only while a response
            # shifts), so the host reads the idle level, not the chip.
            response += self.idle_value.to_bytes(2, "big") * self.idle_words
        return response

    def irq_n(self):
        return self._irq
