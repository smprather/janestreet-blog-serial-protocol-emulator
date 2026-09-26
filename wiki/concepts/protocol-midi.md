---
title: "MIDI 1.0 at 31.25 kbaud — the rate a fractional tick cannot express"
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, physical-layer, verification, architecture]
sources: [firmware/midi_xfer.pe, tb/tb_pe_soc_midi.v, tools/fw/peasm.py, reviews/2026-09-25/FW-BUS-BLOCK3-FINDINGS.md, diagrams/proto-midi.puml]
confidence: high
---

# MIDI 1.0 at 31.25 kbaud

`firmware/midi_xfer.pe` is a MIDI 1.0 transmitter in software: channel voice
messages on channel 0, sent back to back at 31.25 kbaud, using **running
status**. It exists because of the *rate*, not because of MIDI: a 31.25 kbaud
bit is 32 µs and the SoC's shared tick is 4.3333 µs, so a bit is **7.38 ticks**
and a fractional tick cannot express it.

Figures: `diagrams/proto-midi.puml` (message layer and counted cell, ten cells of
8N1, running status across six messages, one bit cell, and the rate window
against the loop's quantisation), with colocated PNG and SVG renders.

## The rate, and why the timer is not used at all

The obvious construction — a few whole ticks plus a remainder — does not work.
`pe_soc`'s target idiom (read the counter, add N, poll until it equals the
target) does **not** give N ticks: it gives anywhere in (N−1, N] ticks, because
the read lands at a random phase within the counter's 260-clock window. A 3-tick
wait is therefore anywhere in (520, 780] clocks — a 260-clock spread, which on a
1920-clock cell is 13.5%.

That is survivable at 115200, where a receiver re-synchronises on every start bit
and the jitter is 1.2% of a bit. It is **not** survivable here: an earlier
version built the cell from three whole ticks plus a remainder, the sampling grid
drifted, and after eight bits it was a third of a cell away from where it started
— which is why that run decoded `0x20` and `0x40` correctly and `0x21` as `0x10`.
**A UART cannot fix a transmitter that jitters; only a deterministic delay can.**

So the cell is counted in whole instructions:

```
  1 clock                    16.667 ns         (60 MHz, rtl/pe_soc.v)
  bit at 31.25 kbaud         1920 clocks = 32.000 us
```

```
  21  the code around the loop, from this cell's OUT to the next, EXCLUDING the LDI
   1  the LDI that loads the loop count
 146  iterations of a 13-clock body (11 NOPs + SUB + JNZ)
  ---
  21 + 1 + 146 x 13 = 1920 clocks = 32.000 us = 31,250 baud, 0.00% error
```

**One instruction is one clock is measured, not assumed.** The first version of
this loop counted 979 instructions from one cell's `OUT` to the next, and a
clock-resolution probe of the TX pin measured 979 clocks (16.316 µs). That exact
agreement is the single fact the whole file rests on.

13 is not a round choice: the delay has to be 1898 clocks, and 1898 = 13 × 146
is the only factorisation of it whose body is small enough to write out and whose
count fits an 8-bit register. **Keep every delay-loop counter ≤ 255** — a count
that does not fit is not a build error. The assembler is silent, the loop runs
`count mod 256` times, and nothing else in the system can tell. A previous
version of this file did exactly that with a 319-iteration loop, measured "the
delay", and reported the time since reset as the result.

## The wire format

One byte is **ten cells**: a start bit, eight data bits LSB first, and a stop
bit — the same 8N1 frame as [[concepts/protocol-uart-flow]], at a rate the ticks
cannot produce.

A MIDI **channel voice message** is three bytes: a status byte, a data byte 1 and
a data byte 2. The status byte is two nibbles — a message type in the high nibble
and a channel number in the low nibble:

```
  status    1001 0000 = 0x90   note on,  channel 0
  data 1    0x20             note number
  data 2    0x40             velocity
```

Every data byte is < 0x80, which is what makes the wire self-delimiting: a
receiver decides "status or data" from the top bit alone. (MIDI 1.0 confines data
bytes to `0x00`–`0x7F`; the escape for a larger value is the `0xF7` prefix, which
this firmware never needs because every value it sends fits.)

### Running status

Six two-data-byte messages cost **eighteen** bytes if each repeats its status
byte, and **fourteen** if it does not. Running status is what makes it fourteen,
and the saving is the point of the feature: a 31.25 kbaud wire saturates near
3,900 bytes per second and the status bytes are a fifth of them.

```
  m  status  note  vel      on the wire
  0  0x90    0x20   0x40     90 20 40   the status byte IS sent
  1  --      0x21   0x41     21 41      running status 0x90
  2  --      0x22   0x42     22 42      running status 0x90
  3  0x80    0x23   0x43     80 23 43   a NEW status byte: note-off
  4  --      0x24   0x44     24 44      running status 0x80
  5  --      0x25   0x45     25 45      running status 0x80
```

**A new status byte REPLACES the running status; it does not merely add to it.**
That is the part which is easy to get wrong and which the testbench checks: a
receiver that *kept* `0x90` after seeing `0x80` would decode messages 4 and 5 as
note-**ons** — six messages, the right notes and velocities, and the wrong
direction on half of them. The firmware sends `0x80` exactly once, at m = 3, and
the expected event list puts messages 4–6 under `0x80`.

A status byte also **abandons a half-finished message** in the receiver's model,
which is the other half of the rule.

**And the saving is asserted, not inferred.** A firmware that repeated the status
byte would still decode into the right six messages under a receiver that ignored
running status, so the byte count is checked directly: exactly **2** status bytes
and exactly **14** bytes on the wire, against 6 messages.

### Active sensing is not implemented, and cannot be here

Active sensing is a real MIDI 1.0 obligation: any device that hears something on
the wire must transmit `0xFE` at least every **300 ms**, so a silent-but-broken
link is distinguishable from an idle one. At 31.25 kbaud a `0xFE` every 300 ms is
33 bytes per second, about 1% of the wire — the bandwidth is not the problem.

The *timing* is. 300 ms is 18,000,000 clocks. With a 13-clock loop body that is
1.38 million iterations, and with the shortest body this ISA can express (two
instructions, the `SUB`/`JNZ` pair) it is still 6 million. **An 8-bit loop
counter holds at most 255**, so a single counted delay is short by a factor of
23,000; expressing 300 ms needs a multi-byte down-counter in `dmem`, and the
sixteen-byte data buffer is already spoken for. There is no active-sensing code
in this program and none can be added in the same idiom, so the honest statement
is: **this transmitter is silent by design, and a receiver that implements
active sensing will time it out.** The receiver in `tb_pe_soc_midi.v` does not
implement active sensing, and its byte-count expectations (exactly 14) are what
would fail first if `0xFE` bytes were added.

## A cell's length belongs to the path between two cells

This is the most expensive piece of knowledge in the file. The obvious model is
"each cell drives its bit, waits, and repeats", and under that model the padding
NOPs look like arbitrary constants. They are not: the time from one cell's
**output** to the next cell's **output** depends on *which cell is next*, because
the dispatch that selects the next cell's code is only partly executed on each
path.

```
  cell 0    start    1920   after three NOPs in sb_start
  cells 1-7 data     1920   the reference: no padding anywhere
  cell 8    d7       1917   without the three NOPs at the top of sb_stop,
                           because the last data bit's successor is the
                           stop and that dispatch is the short one
  cell 9    stop     1920 + the message layer's inter-frame gap
```

An intermediate version of this file put cells of 1921, 1920 and 1917 in the same
frame, and the testbench reported a 32.0086 µs cell with a 0.9-clock spread —
a rate error with no obvious source. A receiver tolerates that; an assertion
about the rate does not.

**A cell that carries no data bit must not consume one.** The shift lives in the
data branch only, never in the common tail. With the shift in the tail, the
start and stop cells each shift the working copy as well: ten cells shift ten
times for eight bits, and every byte arrives `source >> 2` — `0x90` went out as
`0x24`, `0x20` as `0x08`, `0x40` as `0x10`. Only the two highest bits of a MIDI
status byte survive that, so a receiver would have decoded six well-formed
messages built out of the wrong data.

## How the emulator implements it

TX is bit 0 of the same shared port; `OUT TXPIN, A` with A = 0 or 1 drives the
whole byte. Two layers:

- **The message layer** decides *what* goes on the wire. `dmem[1]` is the message
  counter, `dmem[2]` is a mod-3 counter that decides where a status byte goes
  (status bytes fall on m = 0 and m = 3), and the ISA has neither a division nor
  a modulo — which is why `DECX` exists. The running-status count in `dmem[5]` is
  raised **here**, not in the transmitter: the transmitter cannot tell a status
  byte from a data byte and must not guess.
- **The transmitter** is one loop over the ten bit cells, 32 instructions and
  123 words total. One loop rather than a subroutine, because the ISA has no
  CALL/RET, so a shared cell routine would need a return address in a `dmem` slot
  and a dispatch to get back — more state, and one more thing to get wrong, in
  exchange for nothing. Ten cells in a loop is also how the wire is actually
  shaped, so the code reads as the frame does.

The transmitter's return point is `dmem[13]`: 0 = next message, 1 = the note
follows, 2 = the velocity. A shared transmitter gets an explicit continuation
rather than being written out three times.

## How the testbench proves it

`tb_pe_soc_midi.v` is a **free-running oversampling search**: a background
strobe every **eighth** bit (8×, 4 µs) on its own timeline, a high-to-low
transition as a *candidate* start bit, eight samples at mid-points, and **the
stop bit verified before the frame is accepted**. A candidate whose stop reads
low is discarded and the search continues, which costs nothing because the
sampler never waited for the decoder.

Three properties fix the four earlier receivers that all failed the same way —
**in a back-to-back 8N1 stream a falling edge is not a start bit and a rising
edge is not a stop bit**:

1. **Free-running.** The sampler is a background process; a candidate that turns
   out to be a data transition therefore costs the search nothing.
2. **The stop bit is verified before a frame is accepted.** A data transition
   inside a frame produces a candidate whose stop sample reads low, and that
   candidate is discarded. This is the whole safety argument, and it is why the
   search is allowed to latch onto any falling edge at all.
3. **Every frame re-anchors on an edge, never on an accumulated count.** The
   transmitter's rate error is −0.00% today, but a grid that accumulates walks
   out of its cell within eight bits at 1.85% — which is exactly what the first
   run of this testbench did.

An edge monitor still timestamps transitions to the picosecond, because using an
edge for *timing* is not the same as using it to *decide*. The stop-bit sample
decides; the monitor only measures.

### The rate window is 0.3%, and that number is not a preference

The transmitter is a counted-instruction divider on a known 60 MHz clock, so the
only bit periods it *can* produce near 32 µs sit on a 13-clock grid:

| clocks | cell time | error |
|---|---|---|
| 1907 | 31.783 µs | −0.68% |
| **1920** | **32.000 µs** | **0.00%** |
| 1933 | 32.217 µs | +0.68% |

MIDI 1.0 allows ±2%. **A ±2% window would admit all three of those and the rate
check would be decoration.** The window is 0.3%, narrower than the delay loop's
own quantisation, so it admits exactly one achievable value — which is the only
reason the counted-delay mutation can be proved non-vacuous.

### Measuring inside a frame

The obvious measurement, "difference consecutive start bits", is **wrong**: the
interval is ten cells *plus the message layer's inter-frame gap*, and that gap
depends on which branch the message layer takes (sending a status byte costs
more instructions than running status does). Measured that way this testbench
reported 32.0437 µs for a transmitter putting 32.000 µs on the wire: the 0.0437
is the message layer, not the transmitter.

What is exact is a pair of edges **inside one frame**, because a frame's cells are
all one length and nothing else comes between them. So the measurement takes the
start bit's falling edge, takes the next edge on the wire, counts how many cells
apart they are from the byte that was just decoded, and divides. The byte count
comes from a byte the verified stop bit has already vouched for, so the
measurement is not circular: **the bytes are known before the rate is asked for.**

Every frame's measurement is checked, not just the mean, so a transmitter whose
cells slow across the stream cannot hide inside an average. Results, reproduced
on this worktree:

| quantity | measured | nominal |
|---|---|---|
| wire bytes | 14 | 14 (not 18) |
| status bytes | 2 | 2 |
| framing errors | 0 | 0 |
| cell, mean over 14 frames | **31.9987 µs = 31,251 baud** | 32.000 µs = 31,250 |
| cell spread across all 14 frames | **0.0000 µs** | 0 |

## Mutation coverage

Five mutations in `regress/mutate_fwbus_tb.sh`, all detected:

| mutation | what it breaks | caught by |
|---|---|---|
| `midi-cell-count-minus-one` | `146 → 145` iterations: 1907 clocks, 0.68% fast | the ±0.3% rate window |
| `midi-cell-padding-nop` | a fourth NOP in `sb_start`: 0.05%, invisible to the window | the *every cell measures the same* assertion |
| `midi-stop-bit-driven-low` | the stop cell drives 0 | the receiver's stop-bit verification, on all fourteen frames |
| `midi-never-shifts-the-byte` | `SHR` replaced by a `NOP`, so the cell length is unchanged and the mutation tests the payload alone | the per-byte comparison |
| `midi-status-byte-every-message` | the mod-3 compare against 1 instead of 3 | the byte and status-byte counts |

The first two are the class both of these acts exist to prevent: a rate error a
forgiving receiver repairs by resynchronising on the next start bit, which is
precisely why it survives review.

**Which assertion catches the padding NOP, measured rather than argued:** the
gate prints one verdict per mutation and cannot distinguish which check fired,
so it was run by hand. With the fourth NOP the run produces **exactly one**
failure — `every cell is the same length (the measurements span 0.0146 us)` —
and nothing else: all fourteen per-frame rate-window checks **pass**. One clock
is 0.05% against a ±0.3% window, so the spread really is the only thing that sees
it. Two consequences: the spread assertion is load-bearing rather than
decorative, and if it were ever removed the mutation would **survive** and the
gate would say so.

`midi-status-byte-every-message` is the one that tests the *act's claim*: eighteen
bytes and six status bytes on the wire is still perfectly well formed, and a
receiver that ignored running status would reconstruct the same six messages. The
claim this act makes is the saving, so that is the mutation that tests it.

## See also

- [[concepts/protocol-dmx512]] — the sibling act, and the other end of the rate
  problem: a bit the tick cannot express **at all**
- [[concepts/protocol-uart-flow]] — the same 8N1 frame at a rate the ticks *can*
  express, and the cost of that
- [[concepts/spi-as-firmware]] — the third bit-banged protocol on this port, and
  what a counted delay looks like when it is allowed to be a tick
- [[concepts/clock-doubler]] — the 60 MHz timebase, and why 60 MHz / 115200 / 2
  is the one protocol constant here that is not exact
