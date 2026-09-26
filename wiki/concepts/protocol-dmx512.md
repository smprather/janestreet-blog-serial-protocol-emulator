---
title: "DMX512-A at 250 kbaud — the rate a tick cannot express at all"
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, physical-layer, verification, architecture]
sources: [firmware/dmx512.pe, tb/tb_pe_soc_dmx512.v, tools/fw/peasm.py, reviews/2026-09-25/FW-BUS-BLOCK3-FINDINGS.md, diagrams/proto-dmx512.puml]
confidence: high
---

# DMX512-A at 250 kbaud

`firmware/dmx512.pe` is a DMX512-A transmitter in software: a break, a mark, a
START code and 512 data slots, at 250 kbaud. It is the mirror image of
[[concepts/protocol-midi]], and the pair brackets the rate problem exactly.

> **MIDI is the rate a fractional tick cannot express; DMX is the rate a tick
> cannot express at all.**

A DMX bit is 4 µs. The shared tick is 260 clocks = 4.3333 µs, so **one bit cell is
0.923 of a tick** — the timer is *longer* than the bit it is supposed to measure.
No integer number of ticks is even close, and reading the counter cannot help:
the delay does not jitter, it rounds the wrong way. The timer is therefore not
used once in this file, and the delay is counted in instructions.

Figures: `diagrams/proto-dmx512.puml` (frame layer and transmitter, the frame's
parts, the START code ranges, eleven cells of 8N2, and the frame to scale), with
colocated PNG and SVG renders.

## The wire format

A DMX512-A frame is a **break**, a **mark**, and **513 slots**: one START code
followed by 512 data slots. Each slot is 8N2 — a start bit, eight data bits LSB
first, and **two** stop bits — so a slot is eleven cells and a frame is
513 × 11 × 4.000 µs = **22.572 ms**.

Two stop bits are a real obligation, not a belt-and-braces habit: a receiver is
entitled to assume two, and a one-stop version puts 513 slots on the wire that a
strict receiver may discard. The testbench's receiver **verifies both stop bits on
every one of the 513 slots**, and the mutation `dmx-first-stop-driven-low` exists
to prove that check is load-bearing: with the first stop low, the line is only
high for the second and every slot is rejected.

### The break and the mark

A DMX receiver will not look at a frame that does not begin with a break: a LOW of
at least **87.5 µs**, followed by a MARK of at least **8.0 µs**. Both are
expressed here in **whole bit cells of the same counted delay** — 22 and 3 — which
is the elegant part: there is no second timing constant in the file to get wrong,
and each iteration of both loops is exactly 240 clocks, one bit.

```
  break  22 cells = 22 x 4.000 us = 88.0 us   (>= 87.5 us required)
  mark    3 cells =  3 x 4.000 us = 12.0 us   (>=  8.0 us required)
```

87.5 / 4 = 21.875, so 22 is the smallest whole number of cells that clears the
break floor, and it clears it by 0.5 µs. The mark uses **three** cells rather than
two: two is 8.000 µs, *exactly* the minimum, and "exactly the minimum" is not a
place to build a design when one more cell costs nothing and buys 50% of margin
on a timing the standard bounds only from below.

**The loops are 22 and 3; the testbench measures 88.06 µs and 12.38 µs.** Both are
right — they are different intervals, and the difference is worth stating because
it is the fourth instance in this block of one artifact disagreeing with another:

| | what the loop holds LOW/HIGH | what the TB measures |
|---|---|---|
| break | 22 × 240 = 5280 clks = 88.000 µs | the fall to the first rise, so it includes the 4 clocks of LDI/STM/OUT before the loop: 88.0 + 0.07 = **88.06** |
| mark | 3 × 240 = 720 clks = 12.000 µs | the break's end to the **first START BIT**, so it includes the frame layer's whole 22-instruction prologue: 12.0 + 0.367 = **12.38** |

A receiver measures the second column, not the first, so the second column is the
one that has to clear 87.5 µs and 8 µs. It does, with 0.56 µs and 4.37 µs of
margin.

### The START code

The START code is what tells a receiver what the 512 slots **mean**. Sending 512
slots with no START code is the most common way to end up with a working fixture
that lights nothing. DMX512-A defines three ranges:

| START code | meaning |
|---|---|
| `0x00` | all-slot: every one of the 512 data slots is a dimmer or fixture level |
| `0x01`–`0x7F` | first 1 to 127 slots: the following slots are patch-cable positions |
| `0x80`–`0xFF` | start address: the next two slots are one big-endian 16-bit slot number |

This firmware sends **`0x00` and nothing else** — the only range that needs no
follow-up slot, so all 512 payload slots are payload. It goes out through the
**same transmitter** as the data slots, so there is one bit format in this file
rather than two, and a START code sent by a different code path is a START code
that can disagree with the slots.

### The payload is a wrapping 8-bit ramp

An 8-bit register incremented with an 8-bit add **is** a wrapping ramp, so the
payload costs two instructions per slot to produce and the testbench recomputes
all 512 independently rather than trusting a 513-entry list of its own. Slot *n*
is `(n − 1) & 0xFF`, wrapped over two pages of 256.

**The bit order is not a palindrome anywhere.** Slot 1 is `0x01` and slot 128 is
`0x80`, so a transmitter that shifted the wrong way produces `0x80` and `0x01` —
swapped, not identical. That is the property that makes the per-slot comparison
worth anything, and it is why the payload is a ramp and not a constant.

## The bit cell, and why 512 slots need two bytes of counter

```
  21  the code around the loop, from this cell's OUT to the next
 219  the delay block = 1 (the LDI) + 109 x 2
  ---
  240 clocks = 4.000 us = exactly 250,000 baud
```

The delay block is 109 iterations of a **two-instruction** body — the shortest
loop this ISA can express. 218 = 2 × 109 and 109 is prime, so the alternatives
are this or a 109-instruction body run twice, which is the same arithmetic
written out in 107 NOPs. The break and mark loops use a **236-clock** block
instead of 219 because they spend four instructions per iteration on the cell
counter where the transmitter spends seven; both count to 240 per iteration, which
is the number that matters.

**A cell's length belongs to the path between two cells** — the same rule MIDI
paid for twice, stated here as a rule rather than discovered again. Reaching a
data cell runs seven instructions of dispatch, reaching the start bit the same
seven, the first stop two and the second stop three. **Fifteen NOPs exist in this
file for no reason other than to make those four paths the same length**, and
every one of them makes some *other* cell the right size.

```
  cell 0    start    240 clocks   three NOPs
  cells 1-8 data     240 clocks   the reference: no padding anywhere
  cell 9    stop     240 clocks   five NOPs (the shortest dispatch corrects cell 8),
                                then two NOPs for cell 9
  cell 10   stop     240 clocks   four NOPs, for cell 9's sake
  after 10          255 clocks   240 plus the frame layer's inter-slot work
```

Those fourteen NOPs are the whole of the transmitter's 14, counted from the
listing: 3 in `sb_start`, 7 in `sb_stop` (5 + 2) and 4 in `sb_stop2`. The
break and mark loops carry one NOP each as well, so a `grep` over the whole file
finds **sixteen** — the header's "fifteen" counts neither exactly. That is a
firmware-source discrepancy rather than a wire one; the measured cell is 240
clocks either way, because the loops that use the padding are the ones the
assertions measure.

**512 slots in an 8-bit counter** is a real constraint: a single 8-bit counter
cannot reach 512, and the obvious "count to 0xFF and stop" version would send 255
slots. The frame layer counts a **slot counter within a page** (which wraps on
its own, so it needs no comparison at all) and a **page counter** beside it
(`512 = 2 × 256`, compared against 2).

## How the emulator implements it

TX is bit 0 of the same shared port. Two layers, reached by `JMP` and left by
falling out of the transmitter's last cell — so the continuation **is** the
program counter and the `dmem` return slot that MIDI needs is not needed at all.

- **The frame layer** runs break, mark, START code, then 512 slots across two
  pages, and `dmem[10] = 0xA5` when the frame is out.
- **The transmitter** is one loop over the eleven bit cells: **61 of the
  program's 126 words**, counted from the assembler's own listing (`--listing`,
  the transmitter starts at word 65: 47 instructions + 14 NOPs). The frame layer
  is the other 65 words. The shift lives in the **data branch only**, never in
  the common tail — on a ramp the LOW bits are the difference between a fixture
  that works and one that does not.
- **One exit for all 513 slots**: `dmem[7]` ("this slot is a data slot") decides
  what leaving the transmitter means. The START code's exit starts the payload; a
  data slot's exit advances it.

The inter-slot mark after the second stop bit is **255 clocks = 4.25 µs** against
a 240-clock minimum, and it is deliberately *not* constant — it is the frame
layer's loop and its length depends on which branch it takes. That is legal (a
DMX receiver resynchronises on every start bit, and the mark has a minimum, not a
fixed length), and it is also why the testbench measures the cell from two edges
*inside* one slot rather than by differencing slot starts.

## How the testbench proves it

`tb/tb_pe_soc_dmx512.v` is a **lean** receiver: it samples only *while decoding a
slot*, eleven waits per slot, and the idle time between slots costs nothing. Every
sample point is computed from the slot's own start edge, so it never has to reason
about a grid that has to be re-anchored across a quarter-second of wire. It keeps
the one property that matters from the MIDI receiver — **a frame is accepted only
if both stop bits read high** — because the mark between slots is not a start bit
and a transition inside a slot is not a start bit.

**How a slot's start bit is found, since a falling edge is not one:** within a
slot of 8N2 the *last* possible falling edge is at cell 8, because cells 9 and 10
are both stop bits and cannot fall. A fall at least 9.5 cells after the current
slot's start bit is therefore not inside that slot, and the next slot's start bit
is the only thing it can be. The first slot is anchored on the break, which is
88 µs of LOW and is not confusable with anything.

Slot 0 is decoded on the **nominal** cell and the measurement is taken
afterwards. The obvious version finds the fall, waits for the cell-9 rise to
measure the cell, and only then decodes — by which time the simulation clock is
nine cells past the slot it is about to sample, every sample lands in the past,
and it reads whatever the line happens to be doing. That version decoded the
START code as `0xFF`: eight ones, from eight samples taken at a single instant.
Sampling on the nominal grid and refining afterwards costs at most 0.0017 µs per
cell, 0.04% of a cell at the far end, and it cannot consume the timeline it is
measuring.

Results, reproduced on this worktree:

| quantity | measured | requirement |
|---|---|---|
| break | 88.06 µs | floor 87.5 µs |
| mark | 12.38 µs | floor 8.0 µs |
| slots decoded | **513 of 513**, both stop bits verified on each | 513 |
| slot values | every one equal to the recomputed ramp | `(n−1) & 0xFF` |
| cell, mean over 513 slots | **3.9998 µs = 250,010 baud** | 250,000 |
| cell spread across all 513 | **0.0000 µs** | — |

The **rate window is 0.3%**, for the same arithmetic reason as MIDI: the
transmitter's cell is `21 + 1 + 2N`, so the only values it can produce near 4 µs
are 238 clocks (3.967 µs), 240 and 242 (4.033 µs) — 0.83% apart. A window wide
enough to admit DMX's own tolerance would admit all three and the rate check would
be decorative.

**The cell is measured inside a frame, and every measurement is checked**, not
just the mean, so a transmitter that drifts across 513 slots cannot hide inside an
average. The testbench also prints a **histogram of the distinct measurements**,
because a rate that is 0.4% fast on every *other* slot and exact on the rest is
not a rate, it is a per-cell-length bug, and only the distribution says so — the
summary line alone would have reported a mean and a spread and left the reader to
guess.

### Non-vacuity, run both ways

Driven by `firmware/dmx512.hex` this passes. Driven by `firmware/midi_xfer.hex` — a
real 8N1 stream at 31.25 kbaud on the same pin — it **fails**, and the detail is
worth recording: **the break and mark checks PASS on the wrong protocol.** A
31.25 kbaud frame's long low run measures 159.99 µs and its idle high 32.00 µs,
which clears the 87.5 µs break floor and the 8 µs mark floor without meaning it.
What actually rejects the wrong stream is the stop-bit verification and the
per-slot comparison.

> A floor is a floor: it says "not shorter than", and a wrong protocol is not
> shorter. The two floor checks are **necessary, not sufficient**; only the
> structural checks (the two stop bits, the slot values, the count) distinguish
> *this* protocol from a slower one.

The `$dumpvars` is the TB scope only, and that is a measured call rather than
arithmetic: a full-hierarchy dump over 1.37 M clocks is hundreds of megabytes
written on every run, for a waveform whose only moving part is a 4 µs square wave
the assertions already measure on the pin.

The watchdog reports the slot index against the expected total, which
distinguishes "never started" from "stopped at slot 300" — and those point at
completely different firmware. A bare "watchdog" is the least informative failure
a testbench can emit; this file's own history is a truncated stream that looked
exactly like a protocol defect.

## Mutation coverage

Four mutations in `regress/mutate_fwbus_tb.sh`, all detected:

| mutation | what it breaks | caught by |
|---|---|---|
| `dmx-cell-count-minus-one` | `109 → 108` iterations: 238 clocks, 0.83% slow | the ±0.3% rate window |
| `dmx-break-too-short` | `22 → 21` cells: 84.0 µs, under the 87.5 µs floor | the break floor check |
| `dmx-first-stop-driven-low` | the first stop bit driven low | the both-stop-bits verification; all 513 slots rejected |
| `dmx-ramp-steps-by-two` | `ADD A,1 → ADD A,2` | the per-slot comparison; half the slots fail and half pass |

The first is the defect class both of these acts exist to prevent: a DMX receiver
resynchronises on every slot and would decode the frame anyway, and that is
exactly the point — **the defect is one that a receiver's resynchronisation
hides**.

`dmx-ramp-steps-by-two` produced a correction to the testbench's own reasoning.
The file had claimed "a transmitter that dropped a slot would still produce a
valid-looking pattern, and only a count gives that away" — **both halves are
wrong**, and running this mutation by hand is what showed it: a slot carrying the
wrong value produces *hundreds* of per-slot failures, because the ramp is 0, 1, 2,
… so one wrong or missing slot makes every later value wrong. The per-slot
comparison is the defence against a payload error. The count is there for the
other reason: it reads the CPU's own memory while the per-slot comparison reads
the wire, so the two are **independent witnesses** and their disagreement is
itself the signal. The transmission is the claim; `dmem` is the firmware's
account of it.

## See also

- [[concepts/protocol-midi]] — the sibling act, the other end of the rate
  problem, and the receiver discipline they share
- [[concepts/protocol-uart-flow]] — the same 10-cell UART frame at a rate the
  ticks *can* express
- [[concepts/clock-doubler]] — the 60 MHz timebase, and the 4.3333 µs tick that
  is longer than the bit it would have to measure
- [[concepts/factored-hardware-blocks]] — why the same port carries five
  protocols and nothing in the RTL knows which is running
