---
title: "SPI mode 3 with a per-word CRC-8"
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, physical-layer, verification, architecture]
sources: [firmware/spi_mode3.pe, tb/tb_pe_soc_spi3.v, rtl/pe_soc.v, diagrams/proto-spi3-crc.puml]
confidence: high
---

# SPI mode 3 with a per-word CRC-8

`firmware/spi_mode3.pe` is an SPI **mode 3 (CPOL=1, CPHA=1)** master with a
CRC-8 on every word, in both directions. There is no SPI hardware in this chip
and nothing below adds any: the same `rtl/pe_pinmux.v` per-pin direction file,
the same 8-bit port, the same tick counter and the same 16-opcode CPU that run
`firmware/spi_xfer.pe` run this program. The entire difference between the two
protocols is **which pin edge each phase happens on** — see
[[concepts/spi-as-firmware]] for the mode-0 act this one is a sharpening of.

Figures: `diagrams/proto-spi3-crc.puml` (state machine, the 40-rise frame, the
two capture edges, one bit cell, and the frame's field ownership), with colocated
PNG and SVG renders.

## What mode 3 actually means

```
  CPOL=1  SCLK idles HIGH, and the "first edge" of a frame is the FALLING one.
  CPHA=1  data is CAPTURED on the SECOND edge, so with CPOL=1 the second edge
          is the RISING one.
```

Read together: **data changes on the falling edge and is captured on the rising
edge, in both directions.** The master's per-bit loop is therefore:

1. SCLK is HIGH — put the next MOSI bit on the wire (the launch).
2. Lower SCL. The slave may now change MISO.
3. Wait half a period.
4. Raise SCL. The slave captures MOSI; we capture MISO.

Compare mode 0, which does the same three phases in a different order:

```
  mode 0:  set MOSI (SCLK low)  | SCLK ^  sample | SCLK v
  mode 3:  set MOSI (SCLK high) | SCLK v  wait   | SCLK ^  sample
```

### Why this is not mode 0 with the clock inverted

Both modes sample on the **rising** edge. That is the trap: a mode-0 program is
a plausible-looking mode-3 program for the first half-frame and then diverges
silently, because a master that launched MOSI one phase early delivers bit k−1
as bit k and the received bytes come back shifted by one with **nothing on the
wire that looks wrong**.

Two things catch it, and neither is a byte comparison:

- **A slave that decodes the pins.** `tb_pe_soc_spi3.v`'s model is a real mode-3
  device written from the CPOL/CPHA rules: CS_N falling selects it and zeroes the
  bit counter; SCLK rising captures MOSI; SCLK falling advances the index and
  presents the next MISO bit; CS_N rising ends a 40-rise frame.
- **The idle level, and specifically an EDGE rather than a level.** Reset already
  drives the output register's bit 0 HIGH, which is mode 3's idle clock *by
  coincidence* and mode 0's **active edge by construction**. So "SCLK is HIGH at
  the end of the run" passes under both modes, and a check that cannot fail is
  worse than no check — it is a green tick in a table of claims. The property
  that does separate the modes: in mode 3 the firmware only ever touches bit 0
  inside a frame, so **SCLK must not make a single falling edge while CS_N is
  high**. A mode-0 init (`LDI A, 4`) makes one immediately, before the slave is
  even selected.

Two pin-discipline counters do the rest, and both are asserted zero:

- **MOSI must not move while SCL is low** — in mode 3 the whole low phase has to
  be quiet on both wires.
- **MISO must not move while SCL is high** — and that one has to be *gated on
  CS_N*, because a deselected slave is free to let MISO float at any moment.
  This model floats it on the CS_N rising edge, which in mode 3 happens with
  SCLK at its idle HIGH; counting that as a violation is counting the frame
  boundary itself, and it fired once per transaction no matter how correct the
  data was.

## The frame

```
  CS_N v | WORD(16) TX | CRC8(WORD)(8) TX | RESP(8) RX | CRC8(RESP)(8) RX | CS_N ^
```

**Forty SCLK rises**, and the slave counts every one of them. A master that
clocked 39 or 41 would shift bytes that still look plausible, so the count is a
real check rather than decoration. One CS_N frame per word, because that is how
a command/response device with an integrity check is actually driven, and it
gives the testbench a hard per-word frame boundary to count.

The program sends three words, `0x1134`, `0x1245`, `0x1356`, each with its own
CRC. None is a bit palindrome (reversals: `0x1134`→`0x3411`, `0x1245`→`0x5421`,
`0x1356`→`0x6531`), so a master that shifted the other way puts a visibly
different pattern on MOSI. A palindromic word puts the identical pin sequence
whichever way the shift goes and cannot catch a bit-order defect at all — the
trap `spi_xfer.pe` records for `0x5A`, and the reason it sends `0x5B` instead.

The slave's response is a **function** of the word it decoded
(`resp = word XOR 0x7E5A`, applied byte-wise) rather than a played-back table.
That is what makes a shifted word visible: a master that lost or gained a bit
gets a different response, and the comparison fails with the word itself intact.

## CRC-8 in an ISA with no XOR

Poly `0x07`, init `0x00`, no reflection, no final XOR — the textbook MSB-first
bit-serial form. A word's CRC covers its two bytes in **transmission order**:
high byte first, then low.

The ALU has ADD, SUB, AND, OR. No XOR, and no shift left. Two consequences shape
the fold:

- **Shift left is `MOV X, A ; ADD A, X`.** The adder truncates to 8 bits, so that
  *is* an 8-bit shift with the top bit lost.
- **XOR is derivable**: for every byte pair, `(A|P) − (A&P) == A ^ P`, with no
  carry between the two terms because `A|P` is exactly `(A&P) + (A^P)` bit by
  bit. Verified exhaustively over all 65,536 pairs rather than argued. `ADD`
  would *not* have worked: `0xFF + 0x07 = 0x06` where `0xFF ^ 0x07 = 0xF8`,
  because the addition carries out of the low three bits.

The reference CRC-8 datapath in the testbench is written in Verilog straight
from the polynomial. The two are different constructions and **must agree**, so
agreement is evidence — a CRC checked against itself proves nothing.

### The CRC is checked on both sides of the wire

That is the point of the act:

- the slave computes CRC-8 over the 16 bits it decoded from MOSI and requires it
  to equal the 8 that followed, which proves the firmware's CRC reached the wire
  intact;
- the slave then sends a response byte **plus CRC-8 of that byte**, and the
  firmware recomputes it in software and compares — which proves the check is a
  round trip, not a one-way decoration.

And a case **deliberately corrupts one response CRC**. Without it, "3 of 3 CRCs
checked out" is satisfied by a firmware that never compares anything and always
increments the counter. With it, the firmware must report exactly two, and it
must be the *second* word that fails — so both the count and the position are
checked.

## Timing

The bit cell is built from the shared timer, not from the 1 µs I2C tick. `TIMER`
is a free-running 8-bit counter incremented once per 260 clocks, which is
`60 MHz / 115200 / 2` — a **half-bit** period, 4.3333 µs. The wait idiom is
"snapshot the counter once into X, poll until it changes", and `SUB A, X` leaves
X alone, so the loop is three instructions and no `dmem` slot is spent on the
snapshot.

Measured on the pins by `tb_pe_soc_spi3.v` (reproduced on this worktree):
**SCLK period 4.367 µs**, against a testbench bound of *less than five ticks*
(21.67 µs). The testbench prints the measured period and checks the bound; it
does not check a nominal value, because a nominal value is what the firmware
would be compared against by construction.

Two things the *level* checks carry that a period check cannot:

- **40 rises per frame**, exactly.
- **No SCLK falling edge while deselected**, exactly.

## How the emulator implements it

| bit | direction | signal |
|---|---|---|
| 0 | out | SCLK |
| 1 | out | MOSI |
| 2 | out | CS_N |
| 3 | in | MISO |

Init is `LDI A, 5` — CS_N high, MOSI low, **SCLK high** — written explicitly, and
the high is the load-bearing half.

`dmem[10]` is the state, ten of them, dispatched by a **positional** cumulative
subtract chain. Positional is worth saying out loud: each branch tests the state
one lower than the branch above, so a state number with no branch does not
become unreachable, it **shifts every state above it** and the program runs the
wrong handler for each. The first version left out state 4 on the theory that
folding straight into the CRC shift-out saved a jump; the result was that state 5
ran state 6's handler, state 6 ran state 7's, and the frame closed 16 bits early
with CS_N raised from the wrong place.

`bit_loop` is entered and left with SCLK HIGH, holds the byte to send in
`dmem[8]`, the bit count in `dmem[10]`, the receive accumulator in `dmem[11]`
and the caller's return state in `dmem[12]`. One loop for all ten opcodes'
worth of shifting, no subroutine, because the ISA has no CALL/RET.

## How the testbench proves it

Measured on the wire, from `tb_pe_soc_spi3.v` (reproduced locally):

| frame | word decoded | CRC8(WORD) sent | response | CRC8(RESP) |
|---|---|---|---|---|
| 0 | `1134` | `ce` (reference `ce`) | `6f` | `0a` |
| 1 | `1245` | `a1` (reference `a1`) | `6c` | `03` |
| 2 | `1356` | `cd` (reference `cd`) | `6d` | `04` |

With the directed corruption on frame 1's response CRC (`03` → `59`), the
firmware reports `crc_ok = 2 of 3` while the transmitted side is untouched.

The wait is on the firmware's **own** completion evidence and specifically *not*
on `dmem[15]` — that slot is also the CRC fold's continuation slot, so it takes
the value 4 or 7 the moment a fold starts and is non-zero for most of the run. A
wait on it returned mid-frame, the CPU kept running, and the next case's checks
were made against the *previous* case's tail. `dmem[5]` (words transmitted) only
takes its final value at the end of the last frame, and it is taken one frame
short of the CS_N release, so the wait is on `dmem[5]` and then on the `0xA5`
that state 9 leaves behind.

## Mutation coverage

Four mutations in `regress/mutate_fwbus_tb.sh`, all detected:

| mutation | what it breaks | caught by |
|---|---|---|
| `spi3-sclk-idles-low` | `LDI A, 5` → `LDI A, 4`, mode 0's idle level | the SCLK-falls-while-deselected edge monitor |
| `spi3-crc-no-reduction` | the polynomial is zeroed, so the fold is a plain shift | the slave's per-frame recomputation **and** the reference datapath |
| `spi3-crc-xor-without-park` | ANDs the already-OR'd value, so the XOR reduces to the polynomial | the CRC comparison; the CRC was right for a few bytes and wrong after, which is the worst shape a bug can have |
| `spi3-crc-compare-vs-constant` | `SUB A, 2` reads like "subtract the received CRC" and assembles to `A := dmem[14] − 2` | the counter stays at 0 while the transaction otherwise completes perfectly |

The third is the instructive one: `(V|P) & P` is `P` every time, so the mutation
looks like a CRC that is right sometimes. It was caught by this testbench while
`spi_mode3.pe` was being written, which is the argument for writing the receiver
before trusting the arithmetic.

## See also

- [[concepts/spi-as-firmware]] — the mode-0 act, the port, and the model that
  had to be written before the firmware could be trusted
- [[concepts/i2c-on-the-matrix]] — the other open-drain, poll-the-pin discipline
  in the tree, and why the init order is load-bearing there too
- [[concepts/clock-doubler]] — the 60 MHz timebase, and the 260-clock half-bit
  tick every one of these cells is built from
- [[concepts/tx-timing-generation]] — how the counting here relates to the
  Ethernet path's timing generation
