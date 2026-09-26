---
title: WS2812 — a clockless receiver, and why "nearly right" is wrong
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, verification, clocking, physical-layer, gpio, architecture]
sources: []
confidence: high
---

# WS2812

The WS2812 is the project's first *timing* protocol, and the one that made the
rest of the family's design rules visible. It is worth reading first because every
later act in the same block inherits one of its disciplines.

The figures on this page are the ones the design produces on **real RTL** —
`rtl/pe_cpu.v`, the real instruction-memory SRAM macro, Icarus, 60 MHz — measured
by `tb/tb_pe_soc_ws2812.v` and printed by it. Where a number is a datasheet bound
rather than a measurement it says so.

- firmware: `firmware/ws2812.pe` (129 words)
- testbench: `tb/tb_pe_soc_ws2812.v`
- constants: the `LED_DIN`, `WS_RST1`, `WS_RST2` block in `tools/fw/peasm.py`
- state machine: `diagrams/proto-ws2812.puml`
- frame breakout: `diagrams/proto-ws2812-frame.puml`
- timing: `diagrams/proto-ws2812-timing.puml`
- defects found on the way: `reviews/2026-09-25/TIMING-PROTOCOLS-REVIEW.md` §1

## What the protocol is

A WS2812 strip is a string of 24-bit RGB pixels chained together: one data pin in,
one data pin out, each pixel latching the 24 bits it is given and then passing the
*rest* of the stream down the chain. The host never addresses a pixel. The protocol
is a stream and the address is "wherever you stopped counting".

Each pixel latches its 24 bits and then holds its output low until the host has
driven the line low again for long enough to call it a reset. There is no clock, no
handshake, no checksum, no acknowledge. **The entire error-detection mechanism is
the reset**, which is why the reset is in every claim this act makes.

## Why it is interesting: there is no clock to resynchronise to

UART, SPI and I²C — the other protocols in this repository — all have a clock on the
wire, or a clock the peer's edges define. A bit-bang that runs 10 % fast still
produces a readable waveform, and one that runs 10 % slow does too, because the
receiver finds the cells from the transitions rather than from a fixed period.

A WS2812 has neither. The line carries 24 NRZ cells in a row with no gaps to
re-time against, and the strip decodes them by **sampling the line at one instant in
every cell**. Nothing in the stream says "a new cell starts here" other than the
cell period itself. So:

- a cell that is 10 % long shifts every sample in the frame;
- a firmware that is "nearly right" is not right;
- and a receiver that resynchronises on rising edges — the obvious implementation —
  silently tolerates a frame that a real strip would not.

This makes WS2812 the sharpest available test of the project's cycle-accuracy claim,
and the reason it is the one act in the demo.

## The wire format

Three bytes, in **G, R, B** order — not RGB; the strip latches the *first* byte as
green. MSB first. Twenty-four cells, then a reset.

The frame `firmware/ws2812.pe` sends is `0x9C 0xE0 0x8A`. All three components are
non-trivial and all three are **different**, so a firmware that sent RGB, GBR, BRG or
a rotation of the frame fails the decode rather than accidentally agreeing with it.

Each bit is a **pulse, not a level**. A 1 is high for most of the cell and low for
the rest; a 0 is low throughout. The strip samples about two thirds of the way into
the cell and calls the line a 1 or a 0 accordingly.

The frame is sent **twice**. A single frame cannot show a reset at all, and the
reset that matters on a strip that is already lit is the one *between* frames.

## The timing, and why 75 clocks is the whole claim

At 800 kHz a cell is 1.25 µs. At 60 MHz that is **75 clocks with no remainder** —
which is not a coincidence to be discovered but the reason this cell length was
chosen for the first timing act. One clock is 16.6667 ns.

| quantity | value | source |
|---|---|---|
| cell period | 75 clocks = 1.250 µs | datasheet 1.25 µs, exact at 60 MHz |
| `tHIGH1` (a 1's high time) | **48 clocks = 800.0 ns** | measured; the datasheet nominal is ~0.8 µs |
| `tLOW` after a 1 | **27 clocks = 450.0 ns** | measured; the datasheet floor is 450 ns |
| a 0's low time | 75 clocks = 1250 ns | low for the whole cell |
| the strip's sample point | +42 clocks = 0.700 µs | the margin statement |
| reset floor | > 50 µs; produced: **60.85 µs** before frame 1, **62.28 µs** between | measured |

### The tolerance story is what makes this act sharp

Every one of these numbers sits inside a datasheet band. `tHIGH1` is specified
0.70–0.90 µs, so 783 ns (47 clocks) and 817 ns (49 clocks) both pass. A 74-clock
cell is 1.23 µs and clears the cell-period band. **A firmware that is one clock out
every other edge would pass every window check the datasheet offers.**

So the testbench does not check windows as its primary claim. It checks:

1. **the 75-cycle grid** — for every cell it decodes, the measured rising edge sits
   at `t0 + 75k` *exactly*;
2. **the span** — the 24 cells span exactly `24 × 75` clocks;
3. `tHIGH1 == 48` clocks, equality, and `tLOW(1) >= 450` ns;
4. every 1-cell is *still high* at the strip's sample point, +42 clocks in;
5. the reset is over 50 µs, **twice** — before frame 1 and between the frames;
6. the line is **never released** — `n_released == 0`, asserted on the SoC's own
   `pin_oe`, so the wire model cannot hide it;
7. non-vacuity: cell 0 is a 1, the frame carries both bit values, and it repeats.

The reason to state (1) and (2) as equalities: a byte-boundary path that costs one
instruction more than the ordinary path stretches **three cells in every frame** — a
frame 3/24 wrong. No window check can see it. A strip can.

## How the emulator generates it

The cell is **straight-line code**, not a delay loop:

```text
  6  the cell's own work: mask the bit, drive the pin   <- the cell starts
 50  NOPs, padding the high period
  6  advance: the mask down one bit, the counter down one
  1  the byte-boundary test
 12  equalised branch: pad one way, do the boundary work the other
 ---
 75 clocks = 1.25 µs at 60 MHz
```text

The core is single-cycle — one instruction, one clock, no stalls, no pipeline
bubbles (`rtl/pe_cpu.v`) — so *N* instructions take exactly *N* clocks. The period is
therefore not a constant calibrated against a tick: it is **the length of the code**.
That distinction is the act.

Three things in the source are worth reading, because each of them was a real
defect first:

**The moving mask, not a moving byte.** The ISA has `SHR` and no shift-left. The
tempting version — mask bit 7, then shift the byte right — reads like MSB-first and
is not: after *k* shifts the bit due at position *k* has moved down to 7−*k*, so bit
7 is zero from the second cell onward and the frame decodes as twenty-four zeros.
The program instead leaves the byte alone in `dmem[6]` and walks a **mask** down it
(0x80, 0x40 … 0x01). That also keeps `dmem[0..2]` the frame the firmware was given,
in the order the datasheet names it, so the TB can compare against it by eye.

**The mask is also the loop counter.** After eight cells the mask has walked off the
end of the byte and reads 0, so `SHR` followed by `JZ` ends the byte with no second
counter, no comparison and no immediate. An earlier version kept a separate 8…1
counter in `dmem[3]`, and the cell came out at **77 clocks** — over budget, because
the extra counter cost three instructions and the byte-boundary work had nowhere to
hide them. The mask was already counting the same thing.

**The equalised branch.** The loop has two exits at the same point: eight bits of
one byte, or move to the next byte. The taken path does 14 instructions of real
work, the not-taken path pays 14 NOPs, and the byte-boundary *test* is inside the
taken path so the last byte of the frame does not load a fourth "byte" out of
`dmem[3]` — which is not data.

### Why a delay loop could not have built the cell

The obvious implementation waits on the free-running 1 µs tick, the way
`firmware/i2c_pins.pe` does. It cannot work here, and the reason is the whole
difference between this program and that one.

`I2CTICK` is free-running, so firmware cannot see where in its 60-clock window a
read lands. Call that unknown phase offset *φ*. A "wait *N* ticks" delay then
delivers somewhere in (*N*−1, *N*] µs — **up to a full microsecond short**, and a
full microsecond is **80 % of the bit cell this protocol is made of**. No choice of
*N* fixes that: the error is not a rounding error in the constant, it is the
*resolution of the mechanism*. The same arithmetic that produces a legal I²C tLOW
produces an illegal WS2812 cell.

The one delay that *is* a loop is the **reset**, and it is a counted one:

```text
dly1: LDM A,9  / SUB A,1 / STM 9,A / JZ dly_done   4
      LDM A,10 / STM 11,A                          2   <- the RELOAD
dly2: LDM A,11 / SUB A,1 / STM 11,A / JNZ dly2     4 per iteration
      JMP dly1                                     1

total = (n1-1) * (4*n2 + 7) + 4   clocks, exactly, no phase residual
```text

With `n1 = 10, n2 = 99`: `9 × 403 + 4 = 3631` clocks = 60.5 µs, and the pad
measures 60.85 µs (3 651 clocks) — the difference is the entry and exit, not
drift.

**The reload is the whole trick.** The inner counter is *destroyed* by its own loop;
it arrives at zero. A first version read and wrote the same slot, so on the next
outer pass it read zero, subtracted one, and wrapped to 255 — producing 1.1 million
clocks instead of 3 631 while the program looked completely correct. The target has
to be kept somewhere the loop does not touch, which is why there are two slots
(`dmem[10]` the caller's count, `dmem[11]` the loop's working copy) and not one.

### The pin, and the one thing that is easy to get backwards

Bit 6 is the data pin: bits 0–5 are the baseline protocols' and bit 7 is the
Ethernet DRU's input, so bit 6 is the first unclaimed pad. `PINOE` is written
directly with `0x40`, which *releases* the three pads the reset default had
enabled — right for a single-protocol program, and the point of a runtime matrix.

Open-drain is deliberately **not** set. A WS2812 DIN is a push-pull signal into a
high-impedance input, there is no second device to contend with, and the whole
protocol depends on the line being actively driven. Using `od` would release every 1
and turn the frame into a run of pull-up highs.

The level is written straight to `TXPIN`, so a 1 must arrive in the *data pin's
bit*. When the mask is `0x01` (the last cell of a byte) the selected bit lands in
bit 0 and has to be moved up to bit 6 — which this ISA cannot do. The fix is to hold
the mask **shifted up relative to the pin bit**: the cell masks with 0x80…0x01 and
then places the level with one shift of the whole value, which works for every mask
position because the mask is always applied to bit 7 of the byte before the shift.

## How the testbench proves it

`tb/tb_pe_soc_ws2812.v` is on real RTL with the real SRAM macro. Its own header
argues the case; the shape of it is worth stating because it is the model the other
six acts follow.

**The wire model is a pull-up plus the SoC's pads**, exactly as the I²C TB models its
bus. A released pin floats to the pull-up, which is what turns "the line was never
released" into a measurable property rather than a comment.

**The clock counter and the edge recorder are in one `always @(posedge clk)`.**
Icarus does not guarantee the order between two such blocks, and a recorder that
sees the counter before the increment on one cycle and after it on the next turns a
perfect 75-clock cell into an alternating 74/76 — a firmware that is one clock out
every other edge, which is exactly the defect the act exists to catch. That was one
of the thirteen defects this block found, and it was in the *measuring instrument*.

**Frame anchors come from the reset, not from the first two rising edges.** For this
data the first two rising edges are cell 0 and cell 3, so anchoring on them gives a
"second frame" that is really cell 3 of the first. A 50 µs low is a reset, so the
next rising edge is cell 0.

**The clock counter is its own grid.** Every timing assertion is written in *clocks*,
not in `$time`. The pads are registered, so every transition lands on a clock edge
by construction; a `$time`-based check would be measuring the simulator's 1 ps
resolution against a 16.667 ns clock to rediscover an integer that is already known.

**The expectations are bytes written in the TB**, not the decode of the same run.

The recorded result:

```text
    7 frame starts found (anchored on the >50 us reset)
    reset before frame 1: 60.85 us (3651 clocks)
    reset between frames: 62.28 us (3737 clocks)
    frame 0: 9c e0 8a (G,R,B)
      10 one-cells at 48 clocks (800.0 ns), 14 zero-cells at 0
    frame 1: 9c e0 8a (G,R,B)
      10 one-cells at 48 clocks (800.0 ns), 14 zero-cells at 0

PASS: all checks
```text

Ten one-cells and fourteen zero-cells in a 24-cell frame: 10 = popcount(0x9C) +
popcount(0xE0) + popcount(0x8A) = 4 + 3 + 3. The count is a consequence of the
decode, not a number written down.

## The mutation coverage that pins the testbench

`regress/mutate_timing_tb.sh` is a 58-case suite over the whole timing family; five
cases target this act. Each mutant is chosen so that the check it trips is the
*specific* property the testbench claims, and each is chosen to keep every datasheet
window satisfied where it can — so the mutation demonstrates that the claim is the
grid and the equality, not the window.

| case | the change | what catches it |
|---|---|---|
| `ws-cell-pad` | drop one NOP from the equalised branch | the 75-cycle grid — the ordinary cells become 74 clocks and only the three byte-boundary cells stay at 75. A 74-clock cell is still 1.23 µs and clears the cell band, so **only the grid check sees this** |
| `ws-level-bit` | `LDI A, LED_DIN` → `LDI A, 0x80` | the decode: correct-looking levels on the wrong bit of the port |
| `ws-drive-low` | the `OUT TXPIN, 0x00` at instruction 58 replaced by NOPs | the decode (7 checks): the line is never driven back low, so every cell runs into the next |
| `ws-byte-boundary` | `INCX` at instruction 68 → `NOP` | the decode: the byte index never advances |
| `ws-reset-reload` | the `LDM A,10 / STM 11,A` reload pair → NOPs | the >50 µs reset — and only the reset check. This is the reload from the delay routine above, reached by a two-instruction deletion whose *absence* is invisible in the source |

`ws-reset-reload` and `ws-cell-pad` are the two worth singling out, because they are
the cases that make the suite worth running. A one-clock stretch of the ordinary
cells and a deleted reload line are both **invisible in the waveform's shape**: the
frame still looks like a WS2812 stream and the reset still looks like a long low.
The first is caught only by an equality against the clock grid; the second only by a
check on a delay the rest of the frame does not depend on.

The suite's non-vacuity checks for this act are asserted rather than assumed: the
frame must open with a 1 (so the cell grid has a rising edge to anchor on), must
contain both bit values, and must repeat.

## Limits, stated rather than implied

- **A 0-cell is low for the whole 1.25 µs** rather than carrying a 0.4 µs high first.
  Measured and reported, not assumed: the strip samples at about two thirds into the
  cell, so a line low throughout is unambiguously a 0 — but it is a simplification,
  and the TB prints the zero-cell count so the shape of what was actually sent is on
  the record.
- **No chain is modelled.** A real strip latches and re-drives; this TB measures one
  pixel's worth of stream and the reset that follows it. The chain's behaviour
  between pixels is not exercised, and would need a per-pixel reset window the
  datasheet specifies separately.
- **The strip's sample point is a datasheet number, not a modelled receiver.** The
  TB samples at +42 clocks and asserts the 1-cells are still high there. A receiver
  that samples earlier or later would have a different window, and the TB's claim is
  exactly the datasheet's, not a receiver's.
- **Two frames, then park.** Real firmware loops; this simulation does not.

## See also

- [[physical-layer-gpio]] — the pad, `pin_oe` and the pull-up model every one of
  these acts measures against
- [[strobe-and-committing-edge]] — why "the cell starts on this edge" is a statement
  about a registered output, not about the instruction
- [[i2c-on-the-matrix]] — the sibling protocol that *does* use the 1 µs tick, and the
  contrast that explains why this one cannot
- [[tx-timing-generation]] — how a counted interval in this core becomes a delay
