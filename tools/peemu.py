#!/usr/bin/env python3
"""Bit-accurate emulator for pe_cpu + pe_uart_soc.

Runs an assembled program against a modelled UART wire, so firmware can be
developed and debugged without waiting on an RTL compile. The ISA and the memory
map here mirror rtl/pe_cpu.v and rtl/pe_uart_soc.v exactly — if they disagree,
one of them is wrong and the mismatch is the bug.

Cycle model (matches the RTL):
  * instruction fetch is combinational; imem read is REGISTERED (1 cycle),
    which is why pe_cpu drives next_pc at the ROM rather than pc
  * dmem read is COMBINATIONAL, dmem write is same-cycle. That is deliberate
    in rtl/pe_uart_soc.v: `LDM addr` changes the address on the very cycle it
    wants the data, so a registered read would return whatever the previous
    instruction addressed. (This line used to claim "registered", which
    contradicted the RTL this file exists to mirror.)
  * PC increments every cycle, wrapping at PCW bits (== clog2(IMEM_WORDS), min 8)
  * jump targets are the operand's low PCW bits, not a fixed 8

    python3 tools/peemu.py firmware/uart_echo.hex --send 41 42 43
    python3 tools/peemu.py firmware/uart_echo.hex --send 55 --trace 200

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
# rtl/pe_cpu.v and tools/peasm.py: the emulator is only useful as a fast loop if
# it mirrors the machine exactly, and a PC that is one bit wider or narrower than
# the RTL's is the kind of disagreement wiki/STATUS.md gotcha 11 says to treat as
# a signal rather than an inconvenience.
IMEM_WORDS = 1024
PCW = max(8, (IMEM_WORDS - 1).bit_length())      # 10 at 1024 words
PC_MASK = (1 << PCW) - 1

# ---- IO ports (mirrors rtl/pe_uart_soc.v) --------------------------------
P_PIN, P_TXPIN, P_TIMER, P_STATUS = 0x0, 0x1, 0x5, 0x7

CLK_HZ = 60_000_000
BAUD = 115_200
# The timer runs at 2x baud: one tick per HALF bit period, so firmware can
# sample mid-cell. This must match rtl/pe_uart_soc.v's TICKS_PER_BIT.
TICKS_PER_BIT = CLK_HZ // BAUD // 2      # 260 (integer division: baud is 115,385)
TICKS_PER_HALF = TICKS_PER_BIT
TICKS_PER_FULL_BIT = TICKS_PER_BIT * 2   # 521 clocks of real time per bit


def m8(v: int) -> int:
    return v & 0xFF


def _send_list(s: str) -> list[int]:
    """Accept '41 42 43' and '41,42,43' -- bytes are hex, whitespace-insensitive."""
    return [int(tok, 16) for tok in s.replace(",", " ").split()]


class Soc:
    """pe_uart_soc, cycle-accurate enough for firmware."""

    def __init__(self, words: list[int], imem_words: int = IMEM_WORDS, dmem_bytes: int = 16):
        self.imem = list(words) + [0xF000] * max(0, imem_words - len(words))
        self.dmem = [0] * dmem_bytes
        self.a = self.y = self.x = self.pc = 0
        self.run = False

        # peripherals
        self.pin_in = 1                 # idle high
        self.pin_out = 1
        self.tick_cnt = 0
        self.tick_val = 0
        self.tick_flag = 0

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

    # -- peripherals ------------------------------------------------------
    def _tick(self) -> None:
        self.tick_cnt += 1
        if self.tick_cnt >= TICKS_PER_BIT:
            self.tick_cnt = 0
            self.tick_val = m8(self.tick_val + 1)
            self.tick_flag = 1

    def _io_read(self, port: int) -> int:
        if port == P_PIN:
            return self.pin_in & 1
        if port == P_TXPIN:
            return self.pin_out & 1
        if port == P_TIMER:
            return self.tick_val
        if port == P_STATUS:
            f = self.tick_flag
            self.tick_flag = 0
            return f & 1
        return 0

    def _io_write(self, port: int, val: int) -> None:
        if port == P_TXPIN:
            self.pin_out = val & 1
            self.tx_history.append((self.cycles, self.pin_out))

    # -- one clock ---------------------------------------------------------
    cycles = 0

    def step(self) -> None:
        self.cycles += 1
        self._tick()

        if not self.run:
            self.pc = 0
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

    # -- wire side ---------------------------------------------------------
    def set_rx_bit(self, bit: int) -> None:
        self.pin_in = bit & 1

    def poll_tx(self) -> None:
        """Sample the TX pin once per bit period, on a grid anchored to the
        START-BIT EDGE.

        Anchoring matters: a free-running clock grid drifts against the
        firmware's tick loop and mangles the byte. After latching the edge, each
        subsequent sample is exactly one bit period later -- which is what the
        firmware guarantees, since it holds every bit for one bit period.
        """
        lvl = self.pin_out
        if not self.tx_in_frame:
            if self.sample_prev == 1 and lvl == 0:       # start-bit falling edge
                self.tx_in_frame = True
                self.tx_shift = 0
                self.tx_count = 0
                self.tx_next_sample = self.cycles + TICKS_PER_FULL_BIT
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

    # boot: the loader writes memories, then run goes high
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

    soc = Soc(words)
    soc.run = True
    soc.imem_rdata = soc.imem[0]

    seg_i, seg_clock = 0, 0
    soc.set_rx_bit(segments[0][0])

    while soc.cycles < max_cycles:
        soc.step()
        if trace and soc.cycles % trace == 0:
            print(f"  cyc {soc.cycles:6d} pc={soc.pc:3d} a={soc.a:02x} "
                  f"x={soc.x:02x} y={soc.y:02x} tick={soc.tick_val:02x} "
                  f"out={soc.pin_out} in={soc.pin_in}")
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
    args = ap.parse_args()

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
