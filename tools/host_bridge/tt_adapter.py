"""Tiny Tapeout SDK adapter for the Pico bridge (plan Task 2 Step 4).

Everything that touches the board, the SDK or Pico pins lives here, behind a
small duck-typed HAL so ``main.PicoBridge`` is testable under CPython against
``tests/fakes.FakeTTAdapter``:

    enable_project(name)              # shuttle/project selection
    set_clock(hz) -> int              # project clock PWM; NEVER stopped
    reset(active)                     # project reset (active high)
    set_run(active)                   # ui_in[1] RUN strap
    configure_host_spi(sclk_hz)       # uio direction + SPI peripheral
    host_spi_transfer(data) -> bytes  # one CS-framed full-duplex transaction
    irq_n() -> True|False|None        # None = no IRQ input (RTL phase R1)

The concrete ``TTAdapter`` speaks the TT MicroPython SDK v3 (``ttboard``):
``DemoBoard.get()``, ``tt.shuttle.<name>.enable()``, ``tt.clock_project_PWM``,
``tt.reset_project``, ``tt.ui_in``, ``tt.uio_oe_pico`` and ``tt.uo_out``. The
SDK import is lazy so this module imports under CPython; the project clock is
only ever started, never stopped (the plan requires the clock to stay alive
through a connected session).

Two facts are deliberately configuration, not guesses:

  * the host SPI pin map (which RP2040 GPIOs carry uio[4..7]) is board-revision
    specific -- plan Open Item 2 -- so ``pins`` must be supplied; there is no
    invented default;
  * ``IRQ_N`` on ``uo_out[1]`` does not exist until RTL phase R1, so ``irq_n``
    returns ``None`` unless ``irq_enabled=True`` is explicitly set. The bridge
    must not require an interrupt input.
"""

from __future__ import annotations

# Host SPI pads on the chip (plan mapping, review R0): uio[4..7].
PAD_CS_N = 4
PAD_MOSI = 5
PAD_MISO = 6
PAD_SCK = 7

RUN_UI_BIT = 1                  # ui_in[1] = RUN
IRQ_UO_BIT = 1                  # uo_out[1] = IRQ_N after RTL phase R1

# uio_oe_pico bits for the host SPI: CS_N, MOSI and SCK are Pico outputs,
# MISO is an input. The firmware protocol row (uio[0:3]) is untouched.
_HOST_DRIVE_MASK = (1 << PAD_CS_N) | (1 << PAD_MOSI) | (1 << PAD_SCK)
_HOST_INPUT_MASK = 1 << PAD_MISO


class TTAdapter:
    """Concrete adapter over the Tiny Tapeout MicroPython SDK (ttboard v3)."""

    def __init__(self, pins: dict | None = None, *, irq_enabled: bool = False,
                 spi_id: int = 0) -> None:
        self.pins = dict(pins) if pins else None
        self.irq_enabled = bool(irq_enabled)
        self.spi_id = spi_id
        self._board_ref = None
        self._spi = None

    # ---- SDK plumbing ------------------------------------------------------
    def _board(self):
        if self._board_ref is None:
            try:
                from ttboard.demoboard import DemoBoard
                from ttboard.mode import RPMode
            except ImportError as exc:  # pragma: no cover - board only
                raise RuntimeError(
                    "ttboard SDK not found; run on the TT demo board with the "
                    "TT MicroPython SDK (v3) installed") from exc
            board = DemoBoard.get()
            board.mode = RPMode.ASIC_RP_CONTROL
            self._board_ref = board
        return self._board_ref

    def _require_pins(self):
        if not self.pins:
            raise RuntimeError(
                "host SPI pin map is not configured; which RP2040 GPIOs carry "
                "uio[4..7] is board-revision specific (plan Open Item 2)")
        return self.pins

    # ---- HAL ---------------------------------------------------------------
    def enable_project(self, name: str) -> None:
        board = self._board()
        try:
            design = getattr(board.shuttle, name)
        except AttributeError:
            matches = board.shuttle.find(name)
            if not matches:
                raise RuntimeError(f"project {name!r} not found on this shuttle")
            design = matches[0]
        design.enable()

    def set_clock(self, hz: int) -> int:
        # Ownership: the project clock is started here and is NEVER stopped by
        # the bridge while the host session is connected.
        self._board().clock_project_PWM(hz)
        return int(hz)

    def reset(self, active: bool) -> None:
        self._board().reset_project(bool(active))

    def set_run(self, active: bool) -> None:
        self._board().ui_in[RUN_UI_BIT] = 1 if active else 0

    def configure_host_spi(self, sclk_hz: int) -> None:
        pins = self._require_pins()
        board = self._board()
        direction = int(board.uio_oe_pico.value)
        direction = (direction | _HOST_DRIVE_MASK) & ~_HOST_INPUT_MASK
        board.uio_oe_pico.value = direction
        board.uio_out[PAD_CS_N] = 1          # CS_N idles high
        try:
            from machine import SPI, Pin
        except ImportError as exc:  # pragma: no cover - board only
            raise RuntimeError("machine.SPI is only available on the board") from exc
        self._spi = SPI(self.spi_id, baudrate=int(sclk_hz), polarity=0, phase=0,
                        sck=Pin(pins["sck"]), mosi=Pin(pins["mosi"]),
                        miso=Pin(pins["miso"]))

    def host_spi_transfer(self, data: bytes) -> bytes:
        if self._spi is None:
            raise RuntimeError("configure_host_spi() must run before a transfer")
        board = self._board()
        received = bytearray(len(data))
        board.uio_out[PAD_CS_N] = 0          # CS_N low for the whole frame
        try:
            self._spi.write_readinto(data, received)
        finally:
            board.uio_out[PAD_CS_N] = 1      # release even on error
        return bytes(received)

    def irq_n(self):
        if not self.irq_enabled:
            return None                      # no IRQ input until RTL phase R1
        board = self._board()
        try:
            return not bool(board.uo_out[IRQ_UO_BIT])   # active low
        except (AttributeError, IndexError, KeyError, OSError):
            return None                      # pragma: no cover - board only
