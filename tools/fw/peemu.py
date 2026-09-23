#!/usr/bin/env python3
"""Bit-accurate emulator for pe_cpu + pe_soc.

Runs an assembled program against a modelled UART wire, so firmware can be
developed and debugged without waiting on an RTL compile. The ISA and the memory
map here mirror rtl/pe_cpu.v and rtl/pe_soc.v exactly — if they disagree,
one of them is wrong and the mismatch is the bug.

Cycle model (matches the RTL):
  * instruction fetch is combinational; imem read is REGISTERED (1 cycle),
    which is why pe_cpu drives next_pc at the ROM rather than pc
  * dmem read is COMBINATIONAL, dmem write is same-cycle. That is deliberate
    in rtl/pe_soc.v: `LDM addr` changes the address on the very cycle it
    wants the data, so a registered read would return whatever the previous
    instruction addressed. (This line used to claim "registered", which
    contradicted the RTL this file exists to mirror.)
  * PC increments every cycle, wrapping at PCW bits (== clog2(IMEM_WORDS), min 8)
  * jump targets are the operand's low PCW bits, not a fixed 8

    python3 tools/fw/peemu.py firmware/uart_echo.hex --send 41 42 43
    python3 tools/fw/peemu.py firmware/uart_echo.hex --send 55 --trace 200

Wire model: a bit period is TICKS_PER_BIT clocks; the emulator drives the RX
pin at the UART bit rate and decodes the TX pin the same way, so the test is
end-to-end through the same pin the chip uses.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# ---- instruction set (mirrors rtl/pe_cpu.v) ------------------------------
OP_LDI, OP_OUT, OP_IN, OP_MOV = 0x0, 0x1, 0x2, 0x3
OP_JMP, OP_JZ, OP_JNZ, OP_ALU = 0x4, 0x5, 0x6, 0x7
OP_INCX, OP_DECX, OP_SHR = 0x8, 0x9, 0xA
OP_LDS, OP_STS, OP_LDM, OP_STM, OP_NOP = 0xB, 0xC, 0xD, 0xE, 0xF

ALU_ADD, ALU_SUB, ALU_AND, ALU_OR = 0, 1, 2, 3

# Instruction memory depth and the PC width derived from it. These MUST match
# rtl/pe_cpu.v and tools/fw/peasm.py: the emulator is only useful as a fast loop if
# it mirrors the machine exactly, and a PC that is one bit wider or narrower than
# the RTL's is the kind of disagreement wiki/STATUS.md gotcha 11 says to treat as
# a signal rather than an inconvenience.
IMEM_WORDS = 1024
PCW = max(8, (IMEM_WORDS - 1).bit_length())      # 10 at 1024 words
PC_MASK = (1 << PCW) - 1

# ---- IO ports (mirrors rtl/pe_soc.v) --------------------------------
P_PIN, P_TXPIN = 0x0, 0x1
P_PINOE, P_PINOD = 0x2, 0x3
P_I2CTICK, P_TIMER = 0x4, 0x5
P_I2CSTAT, P_STATUS = 0x6, 0x7

# The port is 8 bits wide with "outputs low, inputs high" (rtl/pe_soc.v
# header), and the map is shared between the three baseline protocols:
#   bit 0 = TX / SCLK (out), bit 1 = (spare) / MOSI (out),
#   bit 2 = (spare) / CS_N (out), bit 3 = RX / MISO (in),
#   bit 4 = I2C SDA, bit 5 = I2C SCL
# PIN_IN_MASK is the RESET direction, not a permanent one: the RTL seeds the
# pin matrix's OE register with it, and firmware may change any pin at runtime.
# That is exactly what the I2C firmware does, so this emulator models the
# register file rather than the mask. It keeps the wire levels separate --
# rx_level and tx_level -- exactly as the TB does, and composes the port value
# on a read.
PIN_IN_MASK = 0xF8
PORT_TX_BIT = 0x01
PORT_RX_BIT = 0x08
# I2C pins. Both open-drain on a real bus; see firmware/i2c_pins.pe.
PORT_SDA_BIT = 0x10
PORT_SCL_BIT = 0x20
# SPI uses the SAME port. Named here rather than written as literals in the
# wire model, because "bit 2 is CS_N" is a fact about the pin map, and the pin
# map is what the two protocols share.
PORT_SCLK_BIT = 0x01
PORT_MOSI_BIT = 0x02
PORT_CS_BIT = 0x04
PORT_MISO_BIT = 0x08

CLK_HZ = 60_000_000
BAUD = 115_200
# The timer runs at 2x baud: one tick per HALF bit period, so firmware can
# sample mid-cell. This must match rtl/pe_soc.v's TICKS_PER_BIT.
TICKS_PER_BIT = CLK_HZ // BAUD // 2      # 260 (integer division: baud is 115,385)
# The I2C microsecond tick. 60 MHz / 1 MHz = 60 exactly, so this divider has no
# rounding error at all -- unlike the UART's 260.42.
I2C_TICKS = CLK_HZ // 1_000_000
TICKS_PER_HALF = TICKS_PER_BIT
TICKS_PER_FULL_BIT = TICKS_PER_BIT * 2   # 521 clocks of real time per bit


def m8(v: int) -> int:
    return v & 0xFF


def _send_list(s: str) -> list[int]:
    """Accept '41 42 43' and '41,42,43' -- bytes are hex, whitespace-insensitive."""
    return [int(tok, 16) for tok in s.replace(",", " ").split()]


class Soc:
    """pe_soc, cycle-accurate enough for firmware."""

    def __init__(self, words: list[int], imem_words: int = IMEM_WORDS, dmem_bytes: int = 16):
        self.imem = list(words) + [0xF000] * max(0, imem_words - len(words))
        self.dmem = [0] * dmem_bytes
        self.a = self.y = self.x = self.pc = 0
        self.run = False

        # peripherals
        self.pin_in = 1                 # RX wire level (port bit 3)
        # The pin matrix register file (mirrors rtl/pe_pinmux.v). Reset seeds
        # are the RTL's: OE = ~PIN_IN_MASK, OD = 0, OUT = 0x01 (UART TX idle).
        self.reg_out = 0x01
        self.reg_oe = (~PIN_IN_MASK) & 0xFF
        self.reg_od = 0x00
        # The pad levels the outside world presents on the bidirectional pins,
        # and the levels an external device may be pulling. i2c_bus_* model the
        # OTHER devices on the bus: bit set = that device is pulling the line
        # low. Used by the I2C wire model below.
        self.pad_in = 0x00
        self.i2c_pull_low = 0x00
        self.tick_cnt = 0
        self.tick_val = 0
        self.tick_flag = 0
        self.i2c_cnt = 0
        self.i2c_val = 0
        self.i2c_flag = 0

        # registered read paths
        self.imem_rdata = 0
        self.first = True               # imem read is registered: 1-cycle lag

        # wire model
        self.wire_clocks = 0            # sub-tick clock counter for the TB side
        self.tx_bits: list[int] = []    # decoded output bytes
        self.tx_in_frame = False
        self.tx_shift = 0
        self.tx_count = 0
        self.sample_prev = 1
        self.tx_next_sample = 0
        self.tx_history: list[tuple[int, int]] = []

        # SPI slave model state (see poll_spi_slave). The master is the
        # firmware; this side is the peripheral it talks to.
        self.spi_sclk_prev = 0
        self.spi_cs_prev = 1
        self.spi_mosi_prev = 0
        self.spi_miso = 0
        self.spi_rx_shift = 0
        self.spi_bit_count = 0
        self.spi_idx = 0
        self.spi_waiting = False
        self.spi_present = 0
        self.spi_words: list[int] = []

    # -- peripherals ------------------------------------------------------
    def _tick(self) -> None:
        self.tick_cnt += 1
        if self.tick_cnt >= TICKS_PER_BIT:
            self.tick_cnt = 0
            self.tick_val = m8(self.tick_val + 1)
            self.tick_flag = 1

        # The I2C microsecond divider, same one-process set-beats-clear shape
        # as the RTL's (see rtl/pe_soc.v).
        if self.i2c_cnt == I2C_TICKS - 1:
            self.i2c_cnt = 0
            self.i2c_val = (self.i2c_val + 1) & 0xFF
            self.i2c_flag = 1
        else:
            self.i2c_cnt += 1

    def pad_oe(self) -> int:
        """The matrix's drive enable, per pin: reg_oe & ~(reg_od & reg_out).

        This ONE expression is the open-drain safety property (see
        rtl/pe_pinmux.v): in od mode a pin holding a 1 is RELEASED, so the pad
        can never drive high. The emulator must model it rather than the OE
        register, because every observable in the I2C firmware depends on it.
        """
        return self.reg_oe & ~(self.reg_od & self.reg_out) & 0xFF

    def wire_bits(self) -> int:
        """What the outside world sees on the 8 port bits.

        THERE ARE TWO KINDS OF DRIVE and conflating them is a bug this model
        had on the first attempt (it made a push-pull pin driving 1 read as 0,
        and the UART stopped echoing):

          * a pin in OD mode (od=1) can only pull LOW or release. Driving with
            out=1 therefore RELEASES, and the level is whatever the pull-up
            gives -- unless another device is pulling the line down, which is
            arbitration.
          * a pin in PUSH-PULL mode (od=0) drives BOTH ways, so out=1 really
            does put a high level on the wire and out=0 a low one.

        A released (oe=0) pin does not drive at all; its level is the pull-up's,
        again unless something else pulls it down.
        """
        oe = self.pad_oe()

        # 1. A pin we are DRIVING shows reg_out, full stop. There is no pull-up
        #    on a driven pin -- that is what "driven" means, and treating it as
        #    a pull-up plus a pull-down (the first version of this function)
        #    made a push-pull pin driving 1 read as 0, which stopped the UART
        #    echoing. In od mode the OD gate has already cleared oe for any pin
        #    holding 1, so "driven" here only ever means "pulling low" there.
        level = self.reg_out & oe

        # 2. A RELEASED pin floats to the pull-up. On one of the I2C lines,
        #    another device may be holding it down -- that is arbitration, and
        #    it is what the firmware's read-back is looking for.
        released = ~oe & 0xFF
        level |= released & ~self.i2c_pull_low & 0xFF

        # RX is an input-only pad in the current pin map, driven by the TB's
        # UART wire model rather than by any pull-up, so it is not part of the
        # released-pin story above.
        rxb = PORT_RX_BIT if self.pin_in else 0
        level = (level & ~PORT_RX_BIT & 0xFF) | rxb
        return level & 0xFF

    def _port_value(self) -> int:
        """The 8-bit port as firmware reads it: driven pins read back what we
        wrote, released pins read the pad. Same composition as the RTL's
        pin_rd, which is (pin_out & pin_oe) | (pin_in & ~pin_oe)."""
        oe = self.pad_oe()
        return ((self.reg_out & oe) | (self.wire_bits() & ~oe)) & 0xFF

    def _io_read(self, port: int) -> int:
        if port == P_PIN:
            return self._port_value()
        if port == P_TXPIN:
            return self._port_value()
        if port == P_PINOE:
            return self.reg_oe
        if port == P_PINOD:
            return self.reg_od
        if port == P_I2CTICK:
            return self.i2c_val
        if port == P_TIMER:
            return self.tick_val
        if port == P_I2CSTAT:
            f = self.i2c_flag
            self.i2c_flag = 0
            return f & 1
        if port == P_STATUS:
            f = self.tick_flag
            self.tick_flag = 0
            return f & 1
        return 0

    def _io_write(self, port: int, val: int) -> None:
        # The port -> register mapping is NOT the identity, and the emulator has
        # to repeat the RTL's translation exactly (see rtl/pe_soc.v):
        #   port 1 PINOUT -> reg_out, port 2 PINOE -> reg_oe, port 3 -> reg_od
        if port == P_TXPIN:
            self.reg_out = val & 0xFF
            self.tx_history.append((self.cycles, self.reg_out & PORT_TX_BIT))
        elif port == P_PINOE:
            self.reg_oe = val & 0xFF
        elif port == P_PINOD:
            self.reg_od = val & 0xFF

    # -- one clock ---------------------------------------------------------
    cycles = 0

    def step(self) -> None:
        self.cycles += 1

        if not self.run:
            # While stopped the core is held at PC=0 and -- because the ROM
            # read is registered -- still fetches word 0 every cycle. Keeping
            # the prefetch in sync is not cosmetic: on the resume edge the
            # first instruction executed must be imem[0]. An earlier version
            # returned without touching imem_rdata, so a stop->run sequence
            # executed whatever the previous run had registered (measured: a
            # program starting `LDI A,85` skipped it) while pc was already 0.
            self.pc = 0
            self.imem_rdata = self.imem[0]
            # Timers are NOT gated by run in the RTL, so they keep ticking.
            self._tick()
            return

        insn = self.imem_rdata
        op = (insn >> 12) & 0xF
        arg = insn & 0xFFF

        next_a, next_y, next_x, next_pc = self.a, self.y, self.x, (self.pc + 1) & PC_MASK
        dm_we, dm_addr, dm_data = False, self.x, self.a
        # No branch-operand forwarding: rtl/pe_cpu.v has none and needs none.
        # The core is single-cycle, so an instruction that writes A has already
        # committed it before the next cycle's JZ/JNZ reads it. A `branch_a`
        # variable used to be computed here, described as "mirroring
        # rtl/pe_cpu.v's branch_a" -- there is no such signal in the RTL, and
        # nothing but the branches ever read it, where it equalled self.a.

        if op == OP_LDI:
            next_a = arg & 0xFF
        elif op == OP_OUT:
            self._io_write(arg & 0xF, self.a)
        elif op == OP_IN:
            next_a = self._io_read(arg & 0xF)
        elif op == OP_MOV:
            sel = arg & 3
            if sel == 0:
                next_a = self.y
            elif sel == 1:
                next_y = self.a
            elif sel == 2:
                next_x = self.a
            else:
                next_a = self.x
        elif op == OP_JMP:
            next_pc = arg & PC_MASK
        elif op == OP_JZ:
            if self.a == 0:
                next_pc = arg & PC_MASK
        elif op == OP_JNZ:
            if self.a != 0:
                next_pc = arg & PC_MASK
        elif op == OP_ALU:
            sub = (arg >> 10) & 3
            rhs = self.x if (arg >> 9) & 1 else (arg & 0xFF)
            if sub == ALU_ADD:
                next_a = m8(self.a + rhs)
            elif sub == ALU_SUB:
                next_a = m8(self.a - rhs)
            elif sub == ALU_AND:
                next_a = self.a & rhs
            else:
                next_a = self.a | rhs
        elif op == OP_INCX:
            next_x = m8(self.x + 1)
        elif op == OP_DECX:
            next_x = m8(self.x - 1)
        elif op == OP_SHR:
            next_a = self.a >> 1
        elif op == OP_LDS:
            next_a = self.dmem[self.x % len(self.dmem)]
        elif op == OP_STS:
            dm_we, dm_addr, dm_data = True, self.x, self.a
        elif op == OP_LDM:
            # arg[7]=1 selects X as the destination (dmem is 16 bytes, so the
            # upper address bits are free for this)
            if (arg >> 7) & 1:
                next_x = self.dmem[(arg & 0x0F) % len(self.dmem)]
            else:
                next_a = self.dmem[(arg & 0xFF) % len(self.dmem)]
        elif op == OP_STM:
            dm_we, dm_addr, dm_data = True, arg & 0xFF, self.a
        # OP_NOP: nothing

        # commits
        if dm_we:
            self.dmem[dm_addr % len(self.dmem)] = m8(dm_data)
        self.a, self.y, self.x, self.pc = next_a, next_y, next_x, next_pc

        # The instruction ROM's registered read: the word fetched now is the
        # one executed next cycle. dmem needs no equivalent -- it is read
        # combinationally, in the opcode cases above, exactly as the RTL does.
        self.imem_rdata = self.imem[self.pc % len(self.imem)]

        # The tickers advance AFTER the instruction, and the order is
        # load-bearing. In the RTL every register updates on the same clock
        # edge: a read is combinational from the PRE-edge value, and when a
        # timer wrap and a STATUS read land on that same edge, `tick_now`
        # sets the flag with set-beats-clear (see rtl/pe_soc.v). Ticking
        # first -- the first version of this model -- returned the NEW counter
        # to an `IN TIMER` and could clear a flag that had just arrived: it
        # lost an event the RTL preserves. Measured mismatch, both timers.
        self._tick()

    # -- wire side ---------------------------------------------------------
    def set_rx_bit(self, bit: int) -> None:
        self.pin_in = bit & 1

    def poll_spi_slave(self, response: list[int]) -> None:
        """Model a mode-0 (CPOL=0, CPHA=0) SPI slave on the shared port.

        This is the counterpart to the firmware: the firmware is a mode-0
        MASTER, and a master with no slave is not a protocol, it is a pin
        toggling. The slave is what makes the test end-to-end, and it is what
        can catch a master that drives MOSI on the wrong edge.

        A real mode-0 slave, in the order the edges happen:

          CS_N falls        -> selected; present bit 7 of the response on MISO
          SCLK rises        -> sample MOSI (the master guarantees it is valid
                               before this edge)
          SCLK falls        -> shift the response out; present the next bit
          CS_N rises        -> frame over; the byte is complete

        MISO changes on the FALLING edge, never on the rising one -- that is
        what makes the master's post-rise sample of MISO safe to take with no
        delay at all, and it is exactly the property firmware/spi_xfer.pe
        depends on when it reads the pin straight after raising SCLK.
        """
        # Read the PAD level, not the output register. A released pin shows
        # whatever the wire has, which is what a real slave sees; reading
        # reg_out directly would claim a level on a pin we have released.
        _w = self.wire_bits()
        sclk = 1 if (_w & PORT_SCLK_BIT) else 0
        mosi = 1 if (_w & PORT_MOSI_BIT) else 0
        cs_n = 1 if (_w & PORT_CS_BIT) else 0

        # CS_N falling edge: selected, start a fresh RX byte.
        #
        # NOTE what is NOT reset here: self.spi_idx. The slave's response
        # sequence advances ACROSS frames -- frame 1 answers with response[0],
        # frame 2 with response[1], and so on. Resetting it here was the first
        # version of this model and it made every frame answer with the same
        # byte, which the master faithfully reported as A7 A7 A7: a wrong model
        # producing a confident-looking pass on the slave side (the slave never
        # cares what it sent) and a failure the firmware got blamed for.
        if self.spi_cs_prev == 1 and cs_n == 0:
            self.spi_rx_shift = 0
            self.spi_bit_count = 0
            self.spi_waiting = True
            self.spi_present = self._spi_response_bit(response, self.spi_idx, 0)

        if self.spi_waiting:
            # SCLK rising edge: the slave samples MOSI. MISO DOES NOT MOVE
            # here. It was set on the previous falling edge and must stay
            # stable through this edge, because CPHA=0 puts the master's
            # sample of MISO just after the rise -- changing it here would
            # hand the master a bit it never selected.
            if self.spi_sclk_prev == 0 and sclk == 1:
                self.spi_rx_shift = ((self.spi_rx_shift << 1) | mosi) & 0xFF
                self.spi_bit_count += 1

            # SCLK falling edge: NOW advance. Either move to the next bit of
            # the response, or -- after the 8th bit -- hand the assembled byte
            # to the slave's receive list and start the next one.
            elif self.spi_sclk_prev == 1 and sclk == 0:
                if self.spi_bit_count >= 8:
                    self.spi_words.append(self.spi_rx_shift)
                    self.spi_idx += 1
                    self.spi_rx_shift = 0
                    self.spi_bit_count = 0
                self.spi_present = self._spi_response_bit(
                    response, self.spi_idx, self.spi_bit_count)

        # Drive MISO onto the shared pad. Bit 3 is ONE pad: in UART mode a host
        # drives it, in SPI mode the slave does. Writing self.pin_in (the same
        # wire the UART's RX reads) is what keeps the port self-consistent --
        # two separate levels could disagree, which is the class of bug this
        # emulator exists to catch.
        self.pin_in = self.spi_present if self.spi_waiting else 0

        # CS_N rising edge: frame over.
        if self.spi_cs_prev == 0 and cs_n == 1:
            self.spi_waiting = False

        self.spi_sclk_prev = sclk
        self.spi_cs_prev = cs_n
        self.spi_mosi_prev = mosi

    def _spi_response_bit(self, response: list[int], byte_i: int,
                          bit_i: int) -> int:
        """Bit `bit_i` (0 = MSB, MSB-first) of the slave's `byte_i`th response
        byte, or 0 when the slave has nothing more to say.

        MSB-first is SPI's order and the opposite of the UART's LSB-first, and
        this is the single line where that difference lives.
        """
        if byte_i >= len(response):
            return 0
        bitpos = 7 - bit_i
        if bitpos < 0:
            return 0
        return (response[byte_i] >> bitpos) & 1

    def poll_tx(self) -> None:
        """Sample the TX pin once per bit period, on a grid anchored to the
        START-BIT EDGE.

        Anchoring matters: a free-running clock grid drifts against the
        firmware's tick loop and mangles the byte. After latching the edge, each
        subsequent sample is exactly one bit period later -- which is what the
        firmware guarantees, since it holds every bit for one bit period.

        The FIRST data sample is 1.5 bit periods after the edge -- the centre of
        data bit 0, not the start/data boundary. Sampling at +1.0 read the
        boundary, so a wire only slightly slower than the monitor's nominal
        period made every sample read the preceding bit: an independent 8N1 A5
        at 521 clocks/bit decoded as 4A, while 520 and 519 decoded correctly
        (measured, review 2 R2-6). The stop sample then lands at 9.5 bit
        periods, its centre too; the old grid sampled the stop early enough to
        accept the last data bit as the stop.
        """
        lvl = 1 if (self.wire_bits() & PORT_TX_BIT) else 0
        if not self.tx_in_frame:
            if self.sample_prev == 1 and lvl == 0:       # start-bit falling edge
                self.tx_in_frame = True
                self.tx_shift = 0
                self.tx_count = 0
                self.tx_next_sample = (self.cycles + TICKS_PER_FULL_BIT
                                       + TICKS_PER_HALF)
        elif self.cycles >= self.tx_next_sample:
            if self.tx_count < 8:
                if lvl:
                    self.tx_shift |= (1 << self.tx_count)     # LSB-first
                self.tx_count += 1
                self.tx_next_sample = self.cycles + TICKS_PER_FULL_BIT
            else:
                if lvl:                                      # stop bit == 1
                    self.tx_bits.append(self.tx_shift)
                self.tx_in_frame = False
        self.sample_prev = lvl


def run(hex_path: Path, send: list[int], max_cycles: int, trace: int,
        gap_bits: int = 24) -> tuple[list[int], Soc]:
    """gap_bits: idle bit periods between bytes.

    The firmware is a HALF-DUPLEX polled echo: it cannot receive while it
    transmits, and an echo takes ~10 bit periods. A sender that streams bytes
    back-to-back therefore loses them. gap_bits defaults to 24 so the echo has
    room to finish -- that is a property of the wire, not a fudge, and the
    limit is documented in wiki/plans/through-i2c.md.
    """
    words = [int(line, 16) for line in hex_path.read_text().split() if line.strip()]
    soc = Soc(words)

    # boot: the loader writes memories, then run goes high. The prefetch is set
    # for the first instruction; the model's own stopped-state prefetch keeps
    # imem[0] registered too, so this is belt-and-braces, not a requirement.
    soc.run = True
    soc.imem_rdata = soc.imem[0]

    # Build the RX schedule in CLOCK units: the pin must be driven at the bit
    # rate (TICKS_PER_FULL_BIT clocks per bit), not at the timer's tick rate.
    clk_per_bit = TICKS_PER_FULL_BIT
    segments: list[tuple[int, int]] = [(1, clk_per_bit * 4)]      # idle
    for b in send:
        segments.append((0, clk_per_bit))                        # start
        for k in range(8):
            segments.append(((b >> k) & 1, clk_per_bit))         # LSB first
        segments.append((1, clk_per_bit))                        # stop
        segments.append((1, clk_per_bit * gap_bits))             # idle gap

    seg_i, seg_clock = 0, 0
    soc.set_rx_bit(segments[0][0])

    while soc.cycles < max_cycles:
        soc.step()
        if trace and soc.cycles % trace == 0:
            print(f"  cyc {soc.cycles:6d} pc={soc.pc:3d} a={soc.a:02x} "
                  f"x={soc.x:02x} y={soc.y:02x} tick={soc.tick_val:02x} "
                  f"out={soc.reg_out} oe={soc.pad_oe()} in={soc.pin_in}")
        seg_clock += 1
        if seg_clock >= segments[seg_i][1]:
            seg_clock = 0
            seg_i += 1
            if seg_i >= len(segments):
                break
            soc.set_rx_bit(segments[seg_i][0])
        soc.poll_tx()

    # Let the final stop bit finish and the last byte decode. This runs whether
    # the loop exited on the schedule or on max_cycles, so a byte in flight is
    # never dropped on the floor. The margin is generous (8 bit periods) because
    # the firmware's own tick loop has ~1 tick of jitter against the wire.
    for _ in range(clk_per_bit * 8):
        soc.step()
        soc.poll_tx()
    return soc.tx_bits, soc


def run_spi(hex_path: Path, response: list[int], max_cycles: int,
            trace: int, frames: int = 4) -> Soc:
    """Run an SPI-master firmware against the modelled mode-0 slave.

    No RX schedule is needed: SPI is synchronous and the firmware IS the clock.
    The emulator only has to watch the pins and answer on MISO, which is the
    real asymmetry between this and run() -- a UART test has to drive a wire at
    the right baud because the receiver is free-running, while an SPI test just
    has to be the peripheral that answers.

    `frames` is how many CS_N frames to wait for before stopping; the firmware
    loops forever, so the run has to end on evidence (a counted frame) rather
    than on the schedule running out.
    """
    words = [int(line, 16) for line in hex_path.read_text().split() if line.strip()]
    soc = Soc(words)
    soc.run = True
    soc.imem_rdata = soc.imem[0]

    # Stop when the slave has CAPTURED `frames` bytes and CS_N is high again.
    #
    # Counting CS_N rising edges instead is wrong, and the first version of
    # this did: pin_out resets to 8'h01, which puts CS_N (bit 2) LOW out of
    # reset, so the firmware's very first write -- setting the SPI idle pattern
    # -- registers as a CS_N rising edge with no clock edges in between. That
    # phantom frame made the run stop one byte early and look like a firmware
    # bug. Counting captured bytes is anchored to evidence that a transfer
    # actually happened.
    #
    # The reset state is worth stating plainly, because it is not a firmware
    # bug and it is not harmless-by-accident either: CS_N is asserted for the
    # first few cycles of every power-up. Nothing shifts, because a mode-0
    # slave changes state only on SCLK edges and there are none -- which is
    # exactly why firmware/spi_xfer.pe states its idle pattern as its first
    # instruction rather than assuming the reset value is the SPI idle state.
    frames_done = 0
    cs_now = 1

    while soc.cycles < max_cycles:
        soc.step()
        if trace and soc.cycles % trace == 0:
            print(f"  cyc {soc.cycles:6d} pc={soc.pc:3d} a={soc.a:02x} "
                  f"out={soc.reg_out:02x} oe={soc.pad_oe():02x} in={soc.pin_in:02x}")
        soc.poll_spi_slave(response)
        cs_now = 1 if (soc.wire_bits() & PORT_CS_BIT) else 0
        if len(soc.spi_words) >= frames and cs_now == 1:
            break
        frames_done = len(soc.spi_words)

    # Drain: the store into the rolling buffer (LDM ptr / MOV X / LDM byte /
    # STS) follows the CS_N rise by a handful of instructions. Without this the
    # last frame's byte is simply not in dmem yet when it is read below.
    for _ in range(64):
        soc.step()
        soc.poll_spi_slave(response)
    return soc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hexfile", type=Path)
    ap.add_argument("--send", type=_send_list, default=[0x41])
    ap.add_argument("--max-cycles", type=int, default=3_000_000)
    ap.add_argument("--trace", type=int, default=0,
                    help="print state every N cycles")
    ap.add_argument("--gap", type=int, default=24,
                    help="idle bit periods between sent bytes (half-duplex turnaround)")
    ap.add_argument("--expect-buffer", type=_send_list, default=None,
                    help="also assert the firmware's rolling receive buffer "
                         "(dmem[0..]) holds exactly these bytes, in order")
    ap.add_argument("--dump-dmem", action="store_true",
                    help="print the data memory at the end of the run")
    ap.add_argument("--spi-slave", type=_send_list, default=None,
                    help="run the SPI-master wire model instead of the UART one, "
                         "with the slave responding with these bytes")
    ap.add_argument("--spi-frames", type=int, default=4,
                    help="how many CS_N frames to run before stopping")
    ap.add_argument("--expect-spi-rx", type=_send_list, default=None,
                    help="assert the byte the SLAVE received from the master, "
                         "per frame (checked against the rolling buffer)")
    args = ap.parse_args()

    # ---- SPI mode -------------------------------------------------------
    # Selected by --spi-slave rather than by sniffing the firmware, because
    # the two wire models are genuinely different tests: one drives a
    # free-running serial line at a baud rate, the other answers a bus whose
    # clock the firmware itself generates. Guessing which is which from the
    # hex would be magic; naming it is honest.
    if args.spi_slave is not None:
        soc = run_spi(args.hexfile, args.spi_slave, args.max_cycles,
                      args.trace, args.spi_frames)
        print(f"cycles: {soc.cycles:,}")
        print(f"slave responses: "
              f"{' '.join(f'{b:02X}' for b in args.spi_slave)}")
        print(f"slave captured:  "
              f"{' '.join(f'{b:02X}' for b in soc.spi_words)}")
        if args.dump_dmem:
            print("dmem:   " + " ".join(f"{v:02X}" for v in soc.dmem))

        ok = True
        # What the MASTER received: the firmware buffers each received byte at
        # dmem[ptr], so dmem[0..frames-1] is the master's view of MISO.
        n = min(args.spi_frames, len(soc.spi_words))
        master_got = soc.dmem[:n]
        want_rx = args.spi_slave[:n]
        print(f"master received: "
              f"{' '.join(f'{v:02X}' for v in master_got)}")
        if master_got != want_rx:
            print(f"FAIL: master received "
                  f"{[f'{v:02X}' for v in master_got]}, slave sent "
                  f"{[f'{v:02X}' for v in want_rx]}")
            ok = False
        # The slave's view of MOSI is an independent check: it is built from the
        # MOSI pin, not from the firmware's transmit shift register, so it
        # catches a master that presents bits on the wrong edge -- and, because
        # the check byte is not a bit palindrome, a master that shifts the
        # wrong way.
        if len(soc.spi_words) < args.spi_frames:
            print(f"FAIL: only {len(soc.spi_words)} of {args.spi_frames} "
                  f"frames completed")
            ok = False
        if args.expect_spi_rx is not None:
            want_tx = args.expect_spi_rx * (len(soc.spi_words) //
                                            max(1, len(args.expect_spi_rx)))
            want_tx = (want_tx + args.expect_spi_rx)[:len(soc.spi_words)]
            if soc.spi_words != want_tx:
                print(f"FAIL: slave captured "
                      f"{[f'{v:02X}' for v in soc.spi_words]}, expected "
                      f"{[f'{v:02X}' for v in want_tx]}")
                ok = False
            else:
                print(f"slave captured the master's byte MSB-first "
                      f"({len(want_tx)} frames)")
        if ok:
            print("PASS: SPI frames exchanged correctly")
            return 0
        return 1

    got, soc = run(args.hexfile, args.send, args.max_cycles, args.trace, args.gap)
    want = args.send

    print(f"cycles: {soc.cycles:,}")
    print(f"sent:   {' '.join(f'{b:02X}' for b in want)}")
    print(f"echoed: {' '.join(f'{b:02X}' for b in got)}")
    if args.dump_dmem:
        print("dmem:   " + " ".join(f"{v:02X}" for v in soc.dmem))

    ok = got == want
    if not ok:
        print(f"FAIL: expected {want}, got {got}")

    # The echo path only ever reads slot 15 ("last byte received"), so a broken
    # rolling buffer is invisible to the byte check above -- and it WAS broken:
    # the write pointer's wrap mask (AND 0x0E applied to ptr+1) evaluated to 0
    # for every input, so all three bytes of a three-byte run landed in slot 0.
    if args.expect_buffer is not None:
        n = len(args.expect_buffer)
        seen = soc.dmem[:n]
        if seen != args.expect_buffer:
            print(f"FAIL: receive buffer holds "
                  f"{[f'{v:02X}' for v in seen]}, expected "
                  f"{[f'{v:02X}' for v in args.expect_buffer]}")
            ok = False
        else:
            print(f"buffer: {' '.join(f'{v:02X}' for v in seen)} (rolled correctly)")

    if ok:
        print("PASS: every byte came back")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
