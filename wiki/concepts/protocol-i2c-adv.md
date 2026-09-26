---
title: "I2C advanced — combined format, read burst, clock stretching"
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, physical-layer, verification, architecture]
sources: [firmware/i2c_adv.pe, tb/tb_pe_soc_i2c_adv.v, tools/fw/peasm.py, diagrams/proto-i2c-adv.puml]
confidence: high
---

# I2C advanced

The baseline I2C act (`firmware/i2c_xfer.pe`, [[concepts/i2c-on-the-matrix]])
sends one address byte, one data byte, a repeated START, a read address, **one**
read byte, a NACK and a STOP. That is a legal transaction and it is the shape
almost every tutorial draws. It is also the easy half.

`firmware/i2c_adv.pe` is the other half, and the three obligations it adds are
real protocol obligations rather than a bigger version of the same loop:

1. **The repeated START follows an arbitrary-length write phase.** Two data
   bytes, not one, so the START is not at a fixed instruction offset in the byte
   engine.
2. **The master drives the bus during the read burst.** Continuing a burst means
   pulling SDA low on the 9th clock of every byte but the last. That is
   transmitter behaviour inside a receive phase, and a master that only ever
   releases SDA deadlocks: the slave waits for a second byte that nobody
   promises.
3. **The slave owns SCL.** A stretching slave holds the line low past the
   master's own tLOW, so the tHIGH window has to start from the **real** rising
   edge, not from the master's write.

Figures: `diagrams/proto-i2c-adv.puml` (state machine, nine-cell byte anatomy,
field-by-field transaction, clean bit cell, clock-stretch cell), with colocated
PNG and SVG renders.

## The wire format

Every byte is **nine cells**: eight data bits MSB first, then a ninth clock whose
owner depends on the phase.

```
  START  b7      b6      b5      b4      b3      b2      b1      b0    | cell 8
         A6      A5      A4      A3      A2      A1      A0      R/W   | ACK or NACK
```

For an **address byte**, bits 7..1 are the 7-bit slave address and bit 0 is
R/W: `0xA0` is address `0x50` write, `0xA1` is the same address read. For a
**data byte** the eight bits are the payload and the slave drives the ninth
clock. For a **read byte** the slave drives the eight bits and the *master*
drives the ninth clock — low to say "send another", released to say "that was
the last one".

The transaction this program sends, and the one
`tb/tb_pe_soc_i2c_adv.v`'s slave model is written to expect:

```
  START . 0xA0 ACK . 0x3C ACK . 0x5A ACK
        . repeated START . 0xA1 ACK
        . 0x11 ACK . 0x22 ACK . 0x33 NACK
        . STOP
```

Nineteen cells per byte, 63 cells of payload, two STARTs and one STOP.

### The ninth clock is a pin-discipline problem

The ninth clock is a **rising** edge, so SDA has to hold its value *across* it:

- **ACK** — SDA stays driven low while SCL is released. Releasing SCL alone
  (writing `SCL`, leaving SDA low) is the only correct instruction.
- **NACK** — SDA is already released, so releasing both together is correct.

Releasing **both** for the ACK is the natural-looking "release the bus" line and
it is wrong twice: the slave samples SDA on the rising edge and reads the
release instead of the ACK, so the burst ends after one byte; and SDA rises under
a rising clock, which is an illegal data move. The testbench caught it as two
grammar violations and a one-byte burst. Symmetrically, the phase *after* the
high window pulls SCL low **holding** SDA, and only then releases SDA.

## Timing constraints and tolerances

Standard mode. The floors and the counts `tools/fw/peasm.py` carries:

| parameter | floor | count | delivers | margin |
|---|---|---|---|---|
| tLOW | 4.7 µs | `T_LOW` = 7 | (6, 7] µs | ~1.3 µs |
| tHIGH | 4.0 µs | `T_HIGH` = 6 | (5, 6] µs | ~1.0 µs |
| tHD;STA | 4.0 µs | `T_STA` = 6 | (5, 6] µs | ~1.0 µs |
| tSU;DAT | 0.25 µs | `T_DAT` = 2 | (1, 2] µs | — |
| tSU;STO | 4.0 µs | `T_STO` = 6 | (5, 6] µs | ~1.0 µs |
| tBUF | 4.7 µs | `T_BUF` = 6 | (5, 6] µs | ~0.3 µs |

Two things about that table are worth stating rather than assuming.

**The wait delivers (N−1, N], not N.** `I2CTICK` is a free-running 1 µs counter
(60 clocks per tick at 60 MHz, exact) and firmware cannot see where in its
60-cycle window a read lands. So a "wait N ticks" delay returns anywhere in
(N−1, N] µs, and the number that has to clear the floor is N−1. The bigger count
goes against the bigger floor, which is why tLOW has 7 and tHIGH has 6 — the
first draft had them the other way round and left tLOW with 0.35 µs of margin.
The period is 13 ticks plus instruction overhead either way, so the swap only
rebalances the margins: **13.03 µs = 76.7 kHz**, against the 100 kHz
standard-mode ceiling.

**tHIGH starts at the pin, not at the write.** Every high-phase wait is a poll
loop on the input port (`sb_hi`, `sk_hi`, `rb_hi`, `rk_hi`, `ds_hi`, `w_sth0`):
read SCL, and while it still reads low increment `dmem[0]`. That is a *separate*
wait on the pin, not a longer tick wait, and the distinction is the whole point:
the master does not know how long the slave will hold the line, and guessing a
bigger constant is exactly the bug this replaces.

Measured on the pads by `tb_pe_soc_i2c_adv.v`, reproduced on this worktree:

| case | min tLOW | min tHIGH | max tLOW | `dmem[0]` polls |
|---|---|---|---|---|
| clean combined format | 5916 ns | 5999 ns | 7050 ns | 0 |
| slave stretches 900 clocks mid-burst | 5966 ns | 5950 ns | **15016 ns** | 70 |
| stretch 1500 clocks at the repeated START | — | — | — | > 0 |

The stretch is configured by the test, not by the firmware: the slave holds SCL
low for 900 clocks (15.0 µs) after its 30th falling edge, and the measured
maximum low phase is 15.016 µs. The tHIGH floor still holds after the stretch,
which is the property that matters — the high window starts at the real rise, so
extending the low phase does not shorten the high one.

## How the emulator implements it

No I2C hardware. The same 8-bit port, the same tick counter and the same
16-opcode CPU that run the rest of the protocols:

- `SDA` is bit 4, `SCL` is bit 5, and both are **open-drain** (`PINOD`), so
  writing a 1 *releases* the line. The bus is the wired-AND of everything
  driving it.
- The init order is **OD → OUT → OE** and it is load-bearing: writing OE first
  enables the pins while the output register still holds a value that pulls SDA
  low with SCL high, which *is* a START.
- `dmem[10]` is the state. Eleven states, dispatched by a cumulative subtract
  chain (`LDM A,10` then `SUB A,1` / `JZ` per state) — two instructions per
  state, where the reload-and-retest cascade in `i2c_xfer.pe` costs five.
- 16 bytes of data memory is the whole interface, and the read engine derives
  its own store slot and its own next state from the state number
  (`state − 1`, `state + 1`), which is what keeps the map at 16 bytes. The
  1024-word instruction memory bought program space, not data space.

Arbitration is implemented rather than ignored: every transmitted 1 is read back
while SCL is high, and a low reading means another master won. `arb_abort`
releases both lines and deliberately does **not** issue a STOP, because the
winner owns the transaction. There is no bus-free wait, because one sample of
{SDA,SCL} == 11 cannot distinguish an idle bus from a winner's data-1 high phase.

## How the testbench proves it

`tb/tb_pe_soc_i2c_adv.v` is not a scripted response. It is a Verilog
translation of the wire rules — START/STOP detection, data sampled on SCL rises,
an ACK on the 9th clock of every address and write byte, a read byte driven on
falling edges, tHD;DAT on every SDA change, a multi-byte burst continued only
while the master ACKs — written from the specification rather than from the
firmware's control flow, so a firmware that disagrees with the rules disagrees
with the test.

Four cases:

1. **Clean combined format.** Two STARTs, one STOP, zero grammar violations,
   the slave saw both addresses and both data bytes, it served three read bytes
   and the master ACKed exactly two, no ACK past the end of the burst, and
   `dmem[0] == 0` because no slave stretched.
2. **Stretch during the read burst.** `dmem[0] > 0` (70 polls measured), the
   three read bytes survive, the burst accounting is unchanged, and the measured
   maximum low phase clears a bound **derived from the configuration** — 80% of
   the configured stretch — so changing the stretch length cannot quietly turn
   the check into one that passes for the wrong reason.
3. **Stretch at the repeated START.** The slave owns SCL while the master is
   already committed to the read-address byte. This is the case a
   "wait one tick longer" fix cannot pass.
4. **Read-address NACK.** `dmem[4] == 0x10`, `dmem[15] == 0x55`, **no read byte
   is clocked at all**, the bus is released, and a STOP ends the abort.

Cases 1 and 2 are a **pair**, and the pairing is what makes the stretch path
non-vacuous: a counter that only ever reads zero satisfies case 1, one that only
ever reads non-zero satisfies case 2, and only both together show the counter is
counting the thing it claims to count.

The wait is on the firmware's own completion marker (`dmem[15]`), and it first
waits for the firmware's *init* to clear that marker — otherwise case 2 would
read case 1's `0xA5` and stop before executing an instruction. The completion cap
is 4 ms = 240,000 clocks, and the comment shows the budget arithmetic (≈21 µs
per cell × 63 cells ≈ 1.3 ms, plus the two condition sequences) rather than
asserting that a generous cap is fine.

## Mutation coverage

`regress/mutate_fwbus_tb.sh` mutation-tests this testbench against
`firmware/i2c_adv.hex`. Four mutations, all detected:

| mutation | what it breaks | caught by |
|---|---|---|
| `i2c-ack-releases-sda` | releases SDA with SCL on the ACK | the burst stops after one byte; two grammar violations; `dmem[5..7] = 00 00 00` |
| `i2c-no-stretch-poll` | never looks at the SCL level | the bits of a stretched cell are sampled while the slave owns SCL; `dmem[0] == 0` |
| `i2c-no-stop` | state 9 returns to `main` | no STOP at all; the bus is left held by a master that no longer owns it |
| `i2c-stretch-uncounted` | still waits, but stops counting | `dmem[0] == 0`, so the non-vacuity pair has nothing left to measure |

The last one is the interesting shape: the protocol behaviour is *unchanged* and
the check that fails is the one that measures the thing. A check that can be
satisfied by removing the thing it measures is not a check.

The gate runs all five advanced-bus testbenches together — 21 mutations, 21
detected, 0 survived — and classifies a hang differently from an assertion
failure, because a hang is evidence only that the test stopped consuming its
strobe, while an assertion failure is evidence that it *tests* the firmware.

## See also

- [[concepts/i2c-on-the-matrix]] — the port, the open-drain discipline and the
  init order, in full
- [[concepts/spi-as-firmware]] — the other bit-banged baseline, and why its
  executable specification had to be a model rather than an emulator
- [[concepts/clock-doubler]] — the 60 MHz timebase every one of these tick
  counts is built on
- [[concepts/factored-hardware-blocks]] — why the same port carries five
  protocols
