#!/usr/bin/env python3
"""Assembler for pe_cpu (rtl/pe_cpu.v). One pass, 16 opcodes, no linking.

    python3 tools/fw/peasm.py firmware/uart_echo.pe                 # -> .hex on stdout
    python3 tools/fw/peasm.py firmware/uart_echo.pe -o firmware/uart_echo.hex
    python3 tools/fw/peasm.py firmware/uart_echo.pe --listing       # addr + bytes + src
    python3 tools/fw/peasm.py firmware/uart_echo.pe --rtl-init      # imem initialiser
    python3 tools/fw/peasm.py firmware/ds18b20.pe --const OW_RST=40  # perturb a fitted delay

The ISA is deliberately tiny, so this is deliberately small: a table of
mnemonics, an immediate encoder, and a two-pass label resolver. If the assembler
needs a feature the ISA does not have, that is a sign the ISA is wrong.

Syntax
    label:                    a label on its own line
    MNEMONIC operands         ; comment
    ; full-line comment

Labels are resolved in a second pass, so forward references are fine.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# opcode nibble, operand kind
#   'none'  no operand
#   'imm8'  raw 8-bit immediate
#   'imm4'  raw 4-bit immediate (io port)
#   'addr8' 8-bit code address (label or literal)
#   'sel2'  MOV selector
#   'alu'   ALU sub-op + imm8
MNEMONICS: dict[str, tuple[int, str]] = {
    "LDI": (0x0, "imm8"),
    "OUT": (0x1, "out_port"),
    "IN": (0x2, "in_port"),
    "MOV": (0x3, "mov_sel"),
    "JMP": (0x4, "addr8"),
    "JZ": (0x5, "addr8"),
    "JNZ": (0x6, "addr8"),
    "ADD": (0x7, "alu"),
    "SUB": (0x7, "alu"),
    "AND": (0x7, "alu"),
    "OR": (0x7, "alu"),
    "INCX": (0x8, "none"),
    "DECX": (0x9, "none"),
    "SHR": (0xA, "none"),
    "LDS": (0xB, "none"),
    "STS": (0xC, "none"),
    "LDM": (0xD, "ldm_arg"),
    "STM": (0xE, "stm_arg"),
    "NOP": (0xF, "none"),
}

ALU_SUB = {"ADD": 0, "SUB": 1, "AND": 2, "OR": 3}

# Symbolic IO port names -> port number. The firmware writes IN A, RXSTAT
# rather than IN A, 3; the map lives here so it matches the RTL's memory map.
PORTS: dict[str, int] = {
    "PIN": 0x0,  # port levels: driven pins read back, released read the pad
    "TXPIN": 0x1,  # output levels (write)
    "PINOE": 0x2,  # per-pin output enable: 1 = drive, 0 = release (high-Z)
    "PINOD": 0x3,  # per-pin open-drain: with 1, a pin holding 1 is released
    "I2CTICK": 0x4,  # free-running 1 microsecond counter
    "TIMER": 0x5,  # free-running half-bit tick counter
    "I2CSTAT": 0x6,  # bit0 = an I2C tick happened (cleared by the read)
    "STATUS": 0x7,  # bit0 = a tick happened (cleared by the read)
    # 10BASE-T receive window (rtl/pe_soc.v's memory map). ETHSTAT's read
    # clears the valid/bad event bits; BUFBYTE's read advances the window.
    "ETHSTAT": 0x8,  # {5'b0, is_type, bad, valid}, clear-on-read
    "ETHLEN": 0x9,  # frame_len[7:0]
    "ETHLENH": 0xA,  # frame_len[15:8]
    "ETHFLD": 0xB,  # frame_field[7:0]
    "ETHFLDH": 0xC,  # frame_field[15:8]
    "BUFBYTE": 0xD,  # next frame byte; the read advances the pointer
    "BUFCTRL": 0xE,  # bit0 pulse: reclaim the frame buffer
    # The word-engine window (rtl/pe_soc.v, wiki/plans/serdes-integration.md).
    # INDEX phase sets the pointer, DATA phase bursts, any read re-arms INDEX.
    "ENGINE": 0xF,
}

MOV_SEL = {
    "A,Y": 0,
    "A<-Y": 0,
    "AY": 0,
    "Y,A": 1,
    "Y<-A": 1,
    "YA": 1,
    "X,A": 2,
    "X<-A": 2,
    "XA": 2,
    "A,X": 3,
    "A<-X": 3,
    "AX": 3,
}

# A few constants the firmware leans on; resolved like ports.
CONSTS: dict[str, int] = {
    "RX_VALID": 0x1,
    "RX_BUSY": 0x2,
    "RX_START": 0x1,
    "RX_CLR": 0x2,
    "LSB_FIRST": 0x1,
    "TRUE": 1,
    "FALSE": 0,
    # I2C port bits (see rtl/pe_soc.v's map). SDA and SCL are the two
    # bidirectional pins; both are open-drain on a real bus.
    "SDA": 0x10,
    "SCL": 0x20,
    # Software-UART port bits, on the SAME 8-bit port as SDA/SCL above --
    # which is the point: nothing in the RTL knows which protocol is running.
    #   bit 0  TX (out)   bit 3  RX (in)
    # The two extra bits are the hardware flow-control pair. RTS is ours and
    # CTS is the receiver's, and they are the only pins in the map that no
    # other program touches; firmware/uart_flow.pe is their only user.
    #   bit 4  RTS (out)  bit 5  CTS (in)
    "UTX": 0x01,
    "URX": 0x08,
    "RTS": 0x10,
    "CTS": 0x20,
    # Standard-mode tick counts at 1 us per tick. 5/6 rather than 5/5: 5/5 is
    # exactly 100.0 kHz, which is AT the ceiling and works on a bench while
    # failing a compliance report. See wiki/plans/through-i2c.md.
    # I2C standard-mode tick counts, in whole microseconds at 60 MHz (I2CTICK
    # is exactly 1 us, since 60 MHz / 1 MHz = 60 with no remainder).
    #
    # WHY THESE ARE NOT THE SPEC MINIMA. The tick counter is free-running and
    # firmware cannot see where in its 60-cycle window a read lands. A "wait N
    # ticks" delay therefore delivers (N-1, N] us -- up to a FULL TICK SHORT of
    # nominal -- so the number that has to clear the floor is N-1, not N.
    # Derivation and the measured shortfall: see the TIMING section of
    # firmware/i2c_pins.pe.
    #
    # Standard-mode floors and the counts chosen to clear them worst-case:
    "T_LOW": 7,  # tLOW   >= 4.7 us -> worst case 6 us (nominal 7)
    "T_HIGH": 6,  # tHIGH  >= 4.0 us -> worst case 5 us (nominal 6)
    "T_STA": 6,  # tHD;STA>= 4.0 us -> worst case 5 us (nominal 6)
    "T_DAT": 2,  # tSU;DAT>= 0.25 us-> worst case 1 us (nominal 2)
    "T_STO": 6,  # tSU;STO>= 4.0 us -> worst case 5 us (nominal 6)
    "T_BUF": 6,  # tBUF   >= 4.7 us -> worst case 5 us (nominal 6)
    #
    # WHY tLOW GETS THE LARGER SHARE. Both counts are reduced by up to one tick
    # by the phase residual, and the two floors differ (4.7 vs 4.0), so the
    # larger count belongs against the larger floor. Giving 7 to tHIGH and 6 to
    # tLOW -- which the first draft did, reasoning about pull-up rise time --
    # leaves tLOW with only 0.35 us of margin and tHIGH with 3.05. Swapping them
    # is free: the PERIOD is exactly tLOW + tHIGH ticks either way (the waits
    # chain in target form, so no phase is lost between them), so the swap only
    # rebalances the margins. Measured: 1.35 us on tLOW, 1.05 us on tHIGH.
    #
    # Period = 13 ticks + instruction overhead = 13.03 us = 76.7 kHz, against
    # the 100 kHz standard-mode ceiling.
    #
    # ---------------------------------------------------------------------
    # THE TIMING-PROTOCOL CONSTANTS (WS2812, servo, DHT11).
    #
    # These three protocols are the project's TIMING acts: protocols where the
    # waveform IS the specification, and where a firmware that is "nearly right"
    # is wrong. That is the whole reason they live next to the I2C constants
    # rather than in a separate file -- the I2C numbers are also timing numbers,
    # and the reason a delay cannot be built out of a 1 us tick (the phase
    # residual is up to a full tick, which is 80% of a WS2812 bit cell) is a
    # property of the TICK, not of either protocol.
    #
    # WS2812: one-wire NRZ at 800 kHz. 1.25 us per cell, and 1.25 us at 60 MHz
    # is 75 clocks with NO REMAINDER -- which is why this cell length was
    # chosen. The bit cell is straight-line code, not a delay loop, so its
    # period is the length of the code and is exact by construction. The
    # counters here are for the RESET only (>50 us of low), which does not need
    # cycle-exactness and would cost 3,600 words of NOPs to express.
    "LED_DIN": 0x40,  # bit 6: the strip's data pin (0-5 taken, 7 is the DRU)
    "WS_RST1": 10,  # (10-1)*(4*99+7)+4 = 3,631 clocks = 60.5 us of low
    "WS_RST2": 99,  # see firmware/ws2812.pe: the inner counter is RELOADED
    #
    # Servo PWM: 50 Hz frame, 1.0-2.0 ms pulse. The frame period is the sum of
    # the pulse and the gap, so each sweep position carries its OWN gap and the
    # rise-to-rise interval is 20 ms whatever the pulse width is -- which is
    # the property a real servo needs (position is set by the pulse, not by
    # where it sits in the frame). See the delay-lattice derivation in
    # firmware/servo_sweep.pe before changing a number here.
    "SRV_DATA": 0x40,  # the servo's signal pin, same unclaimed pad as LED_DIN
    #
    # DHT11: start signal plus a 40-bit timed read. The host start is >=18 ms of
    # low, then 20-40 us of high, then RELEASE. The 40 bits are each ~50 us of
    # low followed by 26-28 us of high (a 0) or 70 us of high (a 1), and the
    # host synchronises on the line's edges and samples 45 us into each
    # release -- 17 us of margin on the 0 side and 25 us on the 1 side.
    "DHT_DATA": 0x40,  # the sensor's single data wire
    #
    # ---------------------------------------------------------------------
    # 1-WIRE (DS18B20). The only protocol here where the DEVICE initiates: the
    # reset is a >=480 us low from the host, the sensor answers with a presence
    # pulse, and every read bit is a slot the host must time. Unlike the DHT11
    # the host SAMPLES INSIDE the slot, and the bits are LSB first.
    #
    # THESE ARE COUNTERS, NOT MICROSECONDS. The delay routine's outer step is 69
    # clocks (1.22 us) on the (2,13) pair, so a slot is aimed by division --
    # and writing a duration in as a counter is the mistake this block exists to
    # prevent: 480 us straight into the outer counter comes out as 1900 us,
    # because 480 wraps to 224 and the routine counts passes, not us.
    #   OW_RST   58 -> 485.5 us   the reset pulse,       (n2,n3) = (4,40)
    #   OW_T5     5 ->   4.7 us   a write-1's low pulse, (2,13)
    #   OW_T15   14 ->  15.0 us   the settle after the reset
    #   OW_T40   23 ->  25.4 us   into a read slot, after the sensor's edge
    #   OW_T55   49 ->  55.3 us   a write-1's high period
    #   OW_T65   57 ->  64.5 us   a write-0's low pulse
    "OW_DATA": 0x40,  # the 1-Wire data pin: the same first unclaimed pad
    "OW_RST": 58,
    "OW_T5": 5,
    "OW_T15": 14,
    "OW_T40": 23,
    "OW_T55": 49,
    "OW_T65": 57,
    #
    # ---------------------------------------------------------------------
    # NEC INFRARED REMOTE. The one protocol here with NO WIRE: the only thing
    # that leaves the pin is light, and a NEC receiver recovers the data from a
    # 38 kHz burst it has to find, integrate and time. There is nothing to
    # resynchronise to, which is what makes this the sharpest timing claim in
    # the repository.
    #
    #   leader  9 ms burst   leader gap  4.5 ms
    #   bit 0   0.5625 ms burst + 1.6875 ms silence
    #   bit 1   0.5625 ms burst + 0.5625 ms silence
    #   stop    one final 0.5625 ms burst
    #   bits are LSB first
    #
    # THE CARRIER IS FITTED TO THE CLOCK, NOT TO MICROSECONDS. A half period
    # at 38 kHz is 60e6 / (2 * 38000) = 789.47 clocks, so 789 clocks is
    # 38.0228 kHz -- +0.06 % -- and there is no way to be wrong by more than
    # half a clock if the constant is one of those two. That matters more here
    # than anywhere else in the block: a carrier is the one quantity that
    # cannot be a little bit late.
    #
    # The (2,44) and (2,34) pairs are the ones the two carrier half periods
    # are fitted on. Their outer steps are 10 + 143 = 153 and 10 + 127 = 143
    # clocks, and the difference is not arbitrary: the phase ladder costs 7
    # clocks more coming out of phase 1 than out of phase 0 (four instructions
    # of dispatch instead of two, plus the cycle-count block), and two step
    # sizes are what make the two halves come out EQUAL. The delay alone
    # cannot, because the ladder cost is not a multiple of either step. So:
    #   low half  = ladder 13 + (5-1) * 193 + 4 = 13 + 776 = 789 clocks
    #   high half = ladder 20 + (6-1) * 153 + 4 = 20 + 769 = 789 clocks
    #   carrier   = 1578 clocks = 38.0228 kHz, +0.06 % on 38.0 kHz
    # The TB measures both halves off the pin, so the ladder costs above are a
    # prediction and the number that is claimed is the measurement. (It came
    # out 789 and 789 on the first run, which is the whole point of fitting
    # the ladder and the delay together rather than tuning the delay alone.)
    #
    # Everything else uses (4,40): one outer step is 511 clocks = 8.52 us.
    #   IR_LEADGAP 255 -> 4504.3 us   4.5 ms   (the leader's silence)
    #
    # IR_LEADGAP USES THE (3,130) PAIR, not (4,40), and that is the eight-bit
    # immediate AGAIN. (4,40) wants 529 outer steps for 4.5 ms and 529 & 0xFF
    # is 17, so the leader's gap came out 136 us instead of 4.5 ms -- and
    # 136 us is not far enough off to look like a truncated constant, it looks
    # like a transmitter that is in a hurry. (3,130) has a 1064-clock step, so
    # 255 outer steps reach the target inside one byte. The other two gaps are
    # 200 and 67 and fit (4,40) as they are.
    #   IR_GAP0    200 -> 1694.9 us   1687.5 us (a ZERO's silence)
    #   IR_GAP1     67 ->  562.2 us   562.5 us (a ONE's silence)
    #
    # THE BURSTS ARE COUNTS OF CARRIER CYCLES, and the leader's count is SPLIT
    # IN TWO. 9 ms is 342 cycles of a 1578-clock carrier, and the ISA's LDI
    # immediate is EIGHT BITS: `LDI A, 342` assembled to `LDI A, 86` and the
    # frame that left the pin was a perfectly good 38 kHz carrier whose 9 ms
    # leader was 2.3 ms. Nothing downstream noticed. So the leader is
    # IR_LEADR runs of IR_LEAD cycles, and IR_BIT (21) is a single run.
    "IR_DATA": 0x40,  # the IR LED: cathode on the pin, so LOW emits
    "IR_H1": 5,  # the high half period, on the (2,44) pair: 776 clocks
    "IR_H2": 6,  # the low half period,  on the (2,34) pair: 769 clocks
    "IR_LEADR": 2,  # the leader is this many runs (2 x 171 = 342 cycles)
    "IR_LEAD": 171,  # ...of this many carrier cycles each
    "IR_BIT": 21,  # a data burst: 21 cycles = 0.5625 ms
    "IR_GAP0": 200,
    "IR_GAP1": 67,
    "IR_LEADGAP": 255,
    #
    # ---------------------------------------------------------------------
    # STEPPER STEP/DIR RAMP. The only act in this block that drives a
    # MECHANISM: the driver chip counts STEP edges and the motor's position
    # IS that count, so there is no acknowledgement, no status word, and
    # nothing at the far end to resynchronise to. A step period is a single
    # number and it is either right or the motor is in the wrong place.
    #
    #   STEP pin 6, idles RELEASED -- a stepper driver's input is pulled DOWN
    #   DIR  pin 5, held DRIVEN throughout, only its level changes
    #   twelve steps: six one way, the direction changes, six back
    #   the period falls by 5110 clocks = 85.2 us EVERY step
    #
    # THE RAMP IS A SUBTRACTION, NOT A TABLE, and that is the claim. Ten outer
    # steps of the (4,40) pair is 10 * 511 = 5110 clocks, so the program holds
    # ONE counter and subtracts 10 from it per step:
    #   n1 = 196, 186, 176, 166, 156, 146, 136, 126, 116, 106, 96, 86
    # A table of twelve constants would have been easier to read and would
    # have made the ramp's LINEARITY an assumption: twelve numbers that happen
    # to decrease, with nothing in the program saying they decrease by the
    # same amount. Here the constancy is in the program, and the TB measures
    # that every step period is exactly 5110 clocks shorter than the last.
    #
    # The period is a COUNTED DELAY and not a free-running 1 us tick, and for
    # the same reason the tick is refused everywhere in this block: its phase
    # residual is up to a full microsecond, which is 1.2 % of the longest step
    # period and 0.5 % of a ramp step -- an order of magnitude worse than the
    # claim.
    #   ST_PULSE  2 ->   2.4 us   the STEP low pulse (a driver wants >= 1 us)
    #   ST_SETUP  6 ->   7.0 us   DIR setup before the next STEP edge (5 us min)
    #   ST_GAP0 196 -> 100160 clocks = 1.669 ms, the first step period
    "ST_STEP": 0x40,  # the STEP pin
    "ST_DIR": 0x20,  # the DIR pin
    # ST_BOTH is what PINOE is written with while a step is being driven,
    # and it is a constant rather than a comment because writing ST_STEP
    # on its own RELEASES the DIR pad for the whole of the step pulse -- and
    # a driver samples DIR on the STEP edge, so that is the one instant at
    # which the direction has to be driven. That was the fourth write in
    # stepper_ramp.pe that cleared the other pin; see that file's header.
    "ST_BOTH": 0x60,
    # Both of these are on the (2,13) pair, whose outer step is
    # 10 + (4*13+7) = 69 clocks, so the delay is (n1-1)*69 + 4 -- which is
    # (n1-1) steps, NOT n1. A comment here said "6 * 69 + 4 = 418" for
    # ST_SETUP, which is off by a whole step: it is 5 * 69 + 4 = 349 clocks,
    # 5.8 us, and the TB measured the direction change costing 373 clocks
    # against a 349-clock delay, so 24 instructions is the whole of the
    # bookkeeping. An arithmetic error in the comment beside a fitted constant
    # is the same defect as an error in the constant, and cheaper to make.
    "ST_PULSE": 2,  # the low pulse, (2-1)*69+4 = 73 clocks = 1.2 us; a
    # driver wants at least 1 us
    "ST_SETUP": 6,  # the direction setup, (6-1)*69+4 = 349 clocks = 5.8 us;
    # a driver wants at least 5 us
    "ST_GAP0": 196,  # the first step period, on (4,40): 196 * 511 + 4
    #
    # ---------------------------------------------------------------------
    # INPUT FREQUENCY + DUTY METER. The one act here whose pin is an INPUT:
    # the PWM arrives from outside and the firmware recovers a period and a
    # high time from a waveform it does not control, so the number that is
    # the claim is the accuracy of a count rather than the accuracy of a
    # delay. The 100 Hz point is the point of the act -- its period is
    # 10 000 us, which does not fit in a byte, so a firmware counting into
    # one reports a plausible-looking wrong answer that has no symptom at
    # 10 kHz.
    #
    #   FM_IN  bit 6: the PWM pad, the same first unclaimed pad the WS2812,
    #         servo, DHT11, 1-Wire and stepper acts already use. It is an
    #         INPUT here, so the program never drives it and never writes
    #         TXPIN -- the edge detector reads the PAD through PIN.
    #
    # The two base addresses are constants rather than literals because they
    # are the program's data-memory MAP: the machine has sixteen bytes
    # (DMEM_BYTES = 16 in rtl/pe_soc.v) and all sixteen are used, so a
    # shifted base overlaps the working counters rather than running off the
    # end. The mutation gate perturbs them for exactly that reason.
    "FM_IN": 0x40,
    "FM_PER_BASE": 8,  # the period of slot n is at 8 + 4n
    "FM_HI_BASE": 10,  # its high time is at 10 + 4n
    #
    # ---------------------------------------------------------------------
    # HC-SR04 ULTRASONIC RANGING. The one act here whose ANSWER is a number
    # rather than a waveform: the width of the echo pulse IS the distance, and
    # the act is judged on the millimetre figure. Two pads this time -- the
    # device has a trigger in and an echo out -- and PINOE must be written
    # with BOTH bits, because PINOE is a whole register and a write claiming
    # one pad is a write giving the other away (the fourth such write in this
    # repository; see stepper_ramp.pe's header).
    #   SR_TRIG  bit 6: driven by this program, the trigger pulse
    #   SR_ECHO  bit 5: released, and read back as the pad
    #
    #   SR_TRIG_LEN is a COUNTED delay in instructions, not microseconds, and
    #   it is 149 for a reason worth stating exactly: the loop is four clocks
    #   per iteration (LDM, SUB, STM, JNZ) and the pulse spans the counter
    #   load, the loop and the release, so the width is 4*149 + 4 = 600 clocks
    #   = exactly 10.000 us at 60 MHz. The device asks for 10 us minimum.
    "SR_TRIG": 0x40,
    "SR_ECHO": 0x20,
    "SR_TRIG_LEN": 149,
}


# Target sizing. These are the pe_soc defaults and they are what makes
# the range checks below meaningful: every field in this ISA is narrower than
# the immediate that can be written into it, so without a check the assembler
# silently truncates and emits a program that runs wrong.
#
# The four that actually bite:
#   * the program counter is 8-bit but instruction memory is IMEM_WORDS deep,
#     so word 128 aliases onto word 0 at run time;
#   * a jump target is encoded in 8 bits and truncated to the memory's address
#     width, so `JMP 200` lands somewhere unrelated;
#   * LDM's bit 7 is a DESTINATION SELECTOR (A vs X), so `LDM A, 128` assembles
#     as `LDM X, 0`;
#   * data addresses wider than DMEM_BYTES wrap into occupied slots.
# Target sizing. IMEM_WORDS moved 128 -> 1024 with the SRAM swap
# (decisions/adr-004-program-counter-width.md); the jump-target field
# widened with it, because an 8-bit target cannot name word 1023.
IMEM_WORDS = 1024
DMEM_BYTES = 16
IO_PORTS = 16
# Jump targets are encoded in the operand's low bits. The PC is
# clog2(IMEM_WORDS) wide (min 8), so the field is that many bits.
PCW = max(8, (IMEM_WORDS - 1).bit_length())


class AsmError(Exception):
    pass


def check_range(value: int, limit: int, what: str, tok: str) -> int:
    """Reject a field that does not fit its hardware. `limit` is exclusive."""
    if not 0 <= value < limit:
        raise AsmError(
            f"{what} {tok} = {value} is out of range (0..{limit - 1}); "
            f"the field is truncated in hardware, so this would assemble "
            f"clean and run wrong"
        )
    return value


def strip_a(tok: str, what: str) -> str:
    """Drop a leading 'A,' from an operand. LDI A, 5 / OUT A, 1 / LDS A read
    better than the bare forms, and the destination is always A for these
    mnemonics -- the register name is documentation, not information."""
    t = tok.strip()
    if "," in t:
        head, _, tail = t.partition(",")
        if head.strip().upper() == "A":
            return tail.strip()
        raise AsmError(f"{what} takes a single A destination (got {tok!r})")
    return t


def parse_imm(tok: str, table: dict[str, int] | None = None) -> int:
    """Parse an immediate: a named constant, a port, or a number.

    Also accepts `A|B` to OR two or more of those together, which is how the
    pin-mask constants are written (`SDA|SCL` = 0x30, `TX|RX` etc.). The
    alternative is a literal 0x30 in the firmware with a comment explaining it,
    and the comment goes stale the moment a pin moves; the expression cannot.
    Only `|` is supported -- this is an assembler, not an expression language,
    and `|` is the only operator bit masks need.
    """
    tok = tok.strip()
    if "|" in tok:
        parts = [parse_imm(part, table) for part in tok.split("|")]
        if len(parts) < 2:
            raise AsmError(f"empty operand in immediate expression {tok!r}")
        val = 0
        for part in parts:
            val |= part
        return val
    if table and tok.upper() in table:
        return table[tok.upper()]
    if tok.upper() in PORTS:
        return PORTS[tok.upper()]
    try:
        if tok.lower().startswith("0x"):
            return int(tok, 16)
        if tok.startswith("%"):
            return int(tok, 2)
        return int(tok, 10)
    except ValueError as exc:
        raise AsmError(f"cannot parse immediate {tok!r}") from exc


def assemble(src: str) -> tuple[list[int], list[tuple[int, str, str]]]:
    """Returns (words, listing). Listing rows are (addr, hex, source-text)."""
    lines = src.splitlines()
    labels: dict[str, int] = {}

    # ---- pass 1: addresses + labels ------------------------------------
    items: list[tuple[int, str, str]] = []  # (addr, mnemonic, operands)
    addr = 0
    for lineno, raw in enumerate(lines, 1):
        line = raw.split(";")[0].strip()
        if not line:
            continue
        while ":" in line:
            label, _, rest = line.partition(":")
            label = label.strip()
            if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", label):
                break
            if label in labels:
                raise AsmError(f"line {lineno}: duplicate label {label!r}")
            labels[label] = addr
            line = rest.strip()
            if not line:
                break
        if not line:
            continue
        parts = line.split(None, 1)
        mnem = parts[0].upper()
        ops = parts[1].strip() if len(parts) > 1 else ""
        if mnem not in MNEMONICS:
            raise AsmError(f"line {lineno}: unknown mnemonic {mnem!r}")
        items.append((addr, mnem, ops))
        addr += 1

    # ---- pass 2: encode -------------------------------------------------
    words: list[int] = []
    listing: list[tuple[int, str, str]] = []
    for a, mnem, ops in items:
        opcode, kind = MNEMONICS[mnem]
        arg = 0
        try:
            if kind == "none":
                # Ops that implicitly act on A accept "SHR A" as documentation
                # ("SHR" alone is equivalent); anything else is an error.
                leftover = ops.strip().upper().replace(" ", "")
                ok = {"", "A"}
                if mnem == "LDS":
                    ok |= {"A,[X]", "[X]", "A"}
                if mnem == "STS":
                    ok |= {"[X],A", "[X]", "A"}
                if leftover not in ok:
                    raise AsmError(f"{mnem} takes no operands (got {ops!r})")
            elif kind == "imm8":
                arg = parse_imm(strip_a(ops, mnem), CONSTS) & 0xFF
            elif kind == "out_port" or kind == "in_port":
                # forms: "OUT TXPIN, A" / "IN A, PIN" / "OUT TXPIN" / "IN PIN"
                toks = [t.strip() for t in ops.split(",")]
                if len(toks) == 2:
                    if toks[0].upper() == "A":
                        port_tok = toks[1]
                    elif toks[1].upper() == "A":
                        port_tok = toks[0]
                    else:
                        raise AsmError(f"{mnem} needs A as one operand (got {ops!r})")
                elif len(toks) == 1:
                    port_tok = toks[0]
                else:
                    raise AsmError(f"{mnem} form is '{mnem} A, PORT' (got {ops!r})")
                arg = check_range(
                    parse_imm(port_tok, CONSTS), IO_PORTS, "IO port", port_tok
                )
            elif kind == "mov_sel":
                key = re.sub(r"\s+", "", ops).upper()
                if key not in MOV_SEL:
                    raise AsmError(
                        f"MOV selector {ops!r} is not one of {sorted(set(MOV_SEL))}"
                    )
                arg = MOV_SEL[key]
            elif kind == "addr8":
                tok = ops.strip()
                if tok in labels:
                    arg = labels[tok]
                else:
                    arg = parse_imm(tok, CONSTS)
                # The jump target is encoded in the operand field, which is as
                # wide as the PC (PCW bits, min 8). A target past the end of
                # instruction memory is not "high memory" -- it is a different
                # instruction, because the PC only has PCW bits.
                check_range(arg, IMEM_WORDS, "jump target", tok)
                # ...and it must also fit the FIELD. At IMEM_WORDS=1024 both are
                # 10 bits so they agree, but a depth that is not a power of two
                # would make clog2(IMEM_WORDS) > bits needed, and the wider of
                # the two is the real limit. Fail loudly rather than truncate.
                check_range(arg, 1 << PCW, "jump target field", tok)
            elif kind == "alu":
                # forms: "AND A, 1" / "AND 1" / "ADD A, A" (register form is
                # not in the ISA -- the assembler rejects it explicitly rather
                # than silently encoding nonsense)
                key = re.sub(r"\s+", "", strip_a(ops, mnem)).upper()
                if not key:
                    raise AsmError(f"{mnem} needs an immediate or X")
                # Only X is addressable as the ALU's second operand (arg[9]).
                # Y is not, deliberately: one register is enough for the
                # timer-delta idiom, and Y stays free as the snapshot.
                if key == "X":
                    arg = (ALU_SUB[mnem] << 10) | (1 << 9)
                elif (
                    re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", key)
                    and key not in CONSTS
                    and key not in PORTS
                ):
                    # A bare identifier that is not a known constant is almost
                    # always an attempt at register-register, which this ISA
                    # cannot encode -- so say that rather than "unknown symbol".
                    # Named constants and masks (T_STA, SDA|SCL) ARE allowed:
                    # they reduce to the same immediate, and forcing a literal
                    # would put a magic number in the firmware.
                    raise AsmError(
                        f"{mnem} second operand must be an immediate or X "
                        f"(got {key!r}); register-register is not in this ISA"
                    )
                else:
                    arg = (ALU_SUB[mnem] << 10) | (parse_imm(key, CONSTS) & 0xFF)
            elif kind == "ldm_arg":
                # LDM A, addr8  -> loads A
                # LDM X, addr8  -> loads X (arg[7]=1; only 4 address bits used)
                toks = [t.strip() for t in ops.split(",")]
                dest = "A"
                imm = None
                if len(toks) == 2:
                    dest, imm = toks[0].upper(), toks[1]
                elif len(toks) == 1:
                    imm = toks[0]
                else:
                    raise AsmError(f"LDM form is 'LDM A|X, addr8' (got {ops!r})")
                v = parse_imm(imm, CONSTS)
                if dest not in ("A", "X"):
                    raise AsmError(f"LDM destination must be A or X (got {dest!r})")
                # Bit 7 of the operand selects X as the destination, so an
                # address of 128 or more is not addressable at all -- it would
                # re-encode `LDM A` as `LDM X`. DMEM_BYTES is the real limit
                # and it is far below 128 anyway.
                check_range(v, DMEM_BYTES, "data address", imm)
                arg = (1 << 7) | (v & 0x0F) if dest == "X" else v & 0xFF
            elif kind == "stm_arg":
                # STM addr8, A
                toks = [t.strip() for t in ops.split(",")]
                # Both accepted forms assign toks[0] and nothing else, so
                # they are one condition. The `or` is NOT a weakening: the
                # 2-token form whose second token is not A still falls to the
                # else and is rejected, which is the whole point of the check.
                if len(toks) == 1 or (len(toks) == 2 and toks[1].upper() == "A"):
                    imm = toks[0]
                else:
                    raise AsmError(f"STM form is 'STM addr8, A' (got {ops!r})")
                arg = check_range(parse_imm(imm, CONSTS), DMEM_BYTES, "data address", imm)
        except AsmError as exc:
            raise AsmError(f"addr {a:3d} ({mnem} {ops}): {exc}") from exc

        word = (opcode << 12) | (arg & 0x0FFF)
        words.append(word)
        listing.append((a, f"{word:04X}", f"{mnem} {ops}".strip()))

    if len(words) > IMEM_WORDS:
        raise AsmError(
            f"program is {len(words)} words and instruction memory holds "
            f"{IMEM_WORDS}; the program counter aliases word {IMEM_WORDS} "
            f"onto word 0, so the overflow does not fail loudly at run time. "
            f"See wiki/plans/through-i2c.md Blocker 3 for the SRAM swap."
        )
    return words, listing


def rtl_init(words: list[int], width: int = IMEM_WORDS) -> str:
    """A Verilog initialiser for the SoC's instruction memory.

    Emits a valid `initial` block that assigns every word of an `imem` array
    declared with `width` entries -- no $readmemh, so a testbench can embed the
    image without a file path. Two defects this replaces, both measured:

      * the default width was 128, and a 301-word program was silently
        truncated when `--rtl-init` was the output format;
      * the emitted text was not Verilog at all (`initial $readmemh_unused;`
        followed by a bare comma-separated list).

    Truncation is now an error rather than a short image: a TB that initialises
    fewer words than the program has would run a different program than the one
    assembled, and the failure would look like a CPU bug.
    """
    if len(words) > width:
        raise AsmError(
            f"--rtl-init: program is {len(words)} words but the initialiser "
            f"width is {width}; pass a width >= {len(words)} (the SoC's IMEM "
            f"is {IMEM_WORDS} words)."
        )
    padded = words + [0xF000] * (width - len(words))  # NOP fill
    lines = [
        "  initial begin",
        f"    // {len(words)} words used of {width}; the rest is NOP fill",
    ]
    for i, w in enumerate(padded):
        lines.append(f"    imem[{i}] = 16'h{w:04X};")
    lines.append("  end")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("source", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=None)
    ap.add_argument("--listing", action="store_true")
    ap.add_argument(
        "--rtl-init",
        action="store_true",
        help="emit a Verilog register init instead of hex",
    )
    ap.add_argument(
        "--vh",
        action="store_true",
        help="emit a Verilog $readmemh include file (one word per line)",
    )
    ap.add_argument(
        "--const",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help=(
            "override one entry of the CONSTS table for this assembly, e.g. "
            "--const OW_T40=45. WHY THIS EXISTS: the timing programs name their "
            "delays as symbols (OW_RST, OW_T40) because the value is a FITTED "
            "instruction count, not a duration -- see the table's own comment. A "
            "mutation gate has to be able to perturb that number without editing "
            "the tree, and a sed of the .pe cannot reach it because the number is "
            "not in the .pe. The name must already exist, so a typo is an error "
            "rather than a new symbol that silently assembles."
        ),
    )
    args = ap.parse_args()

    for override in args.const:
        name, eq, value = override.partition("=")
        name = name.strip()
        if not eq or name not in CONSTS:
            print(
                f"peasm: --const needs NAME=VALUE with NAME already in the CONSTS "
                f"table; got {override!r}",
                file=sys.stderr,
            )
            return 2
        CONSTS[name] = int(value.strip(), 0)

    try:
        words, listing = assemble(args.source.read_text(encoding="utf-8"))
    except AsmError as exc:
        print(f"peasm: {exc}", file=sys.stderr)
        return 1

    if args.listing:
        for a, hx, txt in listing:
            print(f"{a:3d}  {hx}  {txt}")
        print(
            f"--- {len(words)} words ({len(words) * 2} bytes of instruction memory)",
            file=sys.stderr,
        )

    if args.rtl_init:
        try:
            out = rtl_init(words)
        except AsmError as exc:
            print(f"peasm: {exc}", file=sys.stderr)
            return 1
    elif args.vh:
        out = "\n".join(f"{w:04x}" for w in words)
    else:
        out = "\n".join(f"{w:04x}" for w in words)

    if args.out:
        args.out.write_text(out + "\n", encoding="utf-8")
        print(f"wrote {args.out} ({len(words)} words)", file=sys.stderr)
    elif not args.listing:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
