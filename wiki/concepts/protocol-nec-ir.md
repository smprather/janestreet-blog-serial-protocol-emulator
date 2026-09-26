---
title: NEC infrared — the protocol with no wire, and a carrier that cannot be late
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, verification, clocking, physical-layer, gpio, architecture]
sources: []
confidence: high
---

# NEC infrared

NEC is the sharpest timing claim in this repository and the only act in the
family with **no wire**. The only thing that leaves the pin is light, so a
receiver has to *find* a 38 kHz burst, integrate it, and time the **silences
between bursts** — and there is nothing at all to resynchronise to.

- firmware: `firmware/nec_ir.pe` (165 words)
- testbench: `tb/tb_pe_soc_ir_nec.v`
- constants: the `IR_DATA`, `IR_H1`, `IR_H2`, `IR_LEADR`, `IR_LEAD`, `IR_BIT`,
  `IR_GAP0`, `IR_GAP1`, `IR_LEADGAP` block in `tools/fw/peasm.py`
- state machine: `diagrams/proto-nec-ir.puml`
- frame and repeat code: `diagrams/proto-nec-ir-frame.puml`
- timing: `diagrams/proto-nec-ir-timing.puml`

All figures here are measured by the testbench on **real RTL** — `rtl/pe_cpu.v`,
the real SRAM macro, Icarus, 60 MHz.

## What the protocol is

A NEC remote sends a leader, a gap, a burst per bit, and a stop burst. The bit
value is **the length of the silence that follows the burst**, because the burst
itself is identical for a 0 and a 1:

| bit | burst | silence | slot |
|---|---|---|---|
| 0 | 562.5 µs | **1 687.5 µs** | 2 250 µs |
| 1 | 562.5 µs | **562.5 µs** | 1 125 µs |

A gap 3 % long is still a gap a receiver calls a zero. A gap 30 % short is not a
one. That is the whole fragility of the protocol, and it is why this act's
measurement discipline is the strictest in the block.

## The frame, the repeat code, and what this act actually sends

A real NEC frame is **32 bits, LSB first**, in four bytes, each followed by its
one's complement:

```text
ADDRESS   ~ADDRESS   COMMAND   ~COMMAND
```text

The inverses are NEC's *only* error detection — there is no checksum, no
acknowledge and no retry. A receiver that gets the inverse wrong drops the frame.

The **auto-repeat** is a different 16-bit sequence, not a repeat of the 32: while a
key is held the remote re-sends a leader, a gap, and then command `0x00` with its
inverse `0xFF`, about 40 ms after the original. The inverse is what makes it
unambiguous, because `0x00` is also a legitimate command code.

**What this act sends is not 32 bits.** `firmware/nec_ir.pe` sends a correct NEC
frame *envelope* — leader, leader gap, eight bit-slots, stop burst — around a
**single payload byte, `0xA5`**. So what the act proves is the **framing and the
carrier**; the 32-bit payload with its inverse bytes, and the repeat code, are not
exercised. `diagrams/proto-nec-ir-frame.puml` marks those boxes grey and says so,
because a diagram that draws the protocol's frame without saying which parts the
firmware produces is a diagram that overstates the claim.

### Why 0xA5

Both bit values appear, and there are six transitions in eight. Its bit-reverse is
`0xA5` — it is a palindrome — and its complement is `0x5A`, and **neither is
anything a wrong bit order produces by accident**. A firmware that reversed the
byte, complemented it, or rotated it cannot pass.

The bits go out LSB first, and the loop needs no shifting at all: the bit to send
is the rotating copy's own bit 0, and the copy is rotated right after each slot.
The same idiom the 1-Wire write path uses, for the same reason. `dmem[0]` holds
the original byte and is never modified, because it is the record the testbench
compares against what it decoded off the wire.

## The carrier is fitted to the clock, not to microseconds

A half period at 38 kHz is `60e6 / (2 × 38000) = 789.47` clocks, so **789 clocks
is 38.0228 kHz — +0.06 %** — and there is **no way to be wrong by more than half a
clock** if the constant is one of 789 or 790.

That matters more here than anywhere else in the block: a gap 3 % long is still a
zero, but a carrier 1 % off is not a carrier. The carrier is the one quantity that
cannot be a little bit late.

**And the two halves are fitted separately, on different `(n2,n3)` pairs**, because
the phase ladder costs 7 clocks more coming out of phase 1 than out of phase 0:

```text
low  half = ladder 13 + 4 x 193 + 4 = 13 + 772 = 789 clocks   on (2,44)
high half = ladder 20 + 5 x 153 + 4 = 20 + 769 = 789 clocks   on (2,34)
carrier   = 1578 clocks = 26.3 us = 38.0228 kHz
```text

The delay *alone* cannot make them equal, because the ladder cost is not a
multiple of either step. The testbench measures both halves off the pin, so the
ladder costs above are a **prediction** and the measurement is the claim — and it
came out 788.95 / 787.95–794.95 on the first run, which is the whole point of
fitting the ladder and the delay together rather than tuning the delay alone.

## The measured result

```text
    carrier: LOW half 13.133-13.249 us (787.95-794.95 clocks), HIGH half 13.149 us (788.95 clocks)
    carrier frequency off the pin: 38049 Hz (nominal 38000, +0.128 %)
    half-period spread: 7.00 clocks LOW, 0.01 clocks HIGH, over 521 pulses
    pulses 541 -> bursts 10 (leader, 8 data bits, stop)
    leader: 8988.0 us in 343 carrier cycles, then 4504.0 us of silence
    gaps: 4 long (a zero) and 4 short (a one)
    decoded off the pin: a5   firmware dmem[0]: a5
    stop burst: 552.0 us in 22 carrier cycles
    payload bit-transitions: 6 of 7
```text

Four longs and four shorts, which is `0xA5` = `1010 0101` sent LSB first, and six
transitions in seven inter-bit gaps — the count follows from the decode rather
than being written down.

## Five firmware defects, all invisible from the waveform's shape

1. **The eight-bit immediate, twice.** 9 ms is 342 carrier cycles and
   `LDI A, 342` assembled to `LDI A, 86` — a perfectly good 38 kHz carrier whose
   9 ms leader was **2.3 ms**. The carrier was right, the bursts were right, the
   gaps were right; only the leader was wrong, and only because a count did not fit
   in an immediate. The leader is now `IR_LEADR` runs of `IR_LEAD` cycles.

   The same truncation hit the leader's *gap*: `(4,40)` wants 529 outer steps and
   `529 & 0xFF` is 17, so 4.5 ms came out as **136 µs**. That does not look like a
   truncated constant — it looks like a transmitter that is in a hurry, which is
   the worst kind of wrong: plausible, small, and in the one place a receiver uses
   for frame detection. It now uses `(3,130)`, whose 1 064-clock step reaches the
   target inside one byte: `254 × 1064 + 4 = 270 260` clocks = 4 504.33 µs.

2. **The bursts never re-drove the pin.** A gap is made by releasing the pad and a
   burst by driving it again; the pad was driven once at the leader, so the program
   ran the whole frame with it released for every burst but the first and the last
   — emitting a leader, 13.6 ms of silence and one burst. One shared `ir_emit` now,
   which is the copy the duplication risk warned about.

3. **A ladder that did not cover its own input domain.** `dmem[6]` held 2/3/4 — the
   phase numbers, the obvious thing to write — and `ir_burst_end` treated anything
   past 1 as the stop burst, so the frame ended after the leader. **Third instance
   of this defect in the block.** A dispatch is a function over the values the
   program actually *produces*; using the phase numbers as the enum hides the
   mismatch until someone reorders the phases.

4. **A setup block with no entry point**, so the bit counter was never set and the
   loop ran 255 times instead of eight. The frame that left the pin was a valid
   carrier with a valid-looking burst train and the wrong number of slots in it.
   Falling into a setup block is the cheap way to write one and the expensive way
   to miss one.

5. **A block that fell through into its own caller**, which never emitted.

## The measurement instrument, and the check the gate forced into it

**Every width is in tenths of a nanosecond, from `$realtime`.** `$time` is scaled
to the module's `timeunit` and returns an integer, so every width here would be
quantised — and a measuring instrument with 0.4 % quantisation cannot support a
0.06 % claim. Before that, the carrier appeared to jitter `787/788/789` every
sixteen cycles, which was the instrument, not the firmware.

**The bursts are reconstructed in two passes, not by a running accumulator.** The
first version reported every burst as 22 carrier cycles while measuring its width
correctly — not a combination of numbers any waveform has.

**A "whole number of carrier cycles" check was written and then deleted as
unsound.** The burst opens with a two-instruction initiation pulse, so its span is
not a whole number of periods, and the check fired on all ten bursts *including the
correct ones*. A check that is wrong about what it measures is worse than no check:
the first thing anyone would do is loosen the tolerance until it went away, and
then the loosened tolerance is the one that is believed.

### Check 2 is the act: the two halves are compared against *each other*

The mutation gate's first run had **three survivors of eleven**. One of them put
*both* half periods on the same delay pair and produced a carrier of 788 clocks
one way and 782 the other: **38.05 kHz against 37.88, 0.4 % asymmetric on every
edge** — inside every frequency window a real receiver has — and it **passed**.

"Each half is constant" is not "the two halves are equal". A receiver does not
care that the carrier is on frequency; it cares that the carrier is a *carrier*,
and one whose halves differ is a square wave at 38 kHz with the wrong duty cycle.
The testbench now measures the two distributions **against each other**, to within
a clock, and that check is the act's whole point.

The other two survivors: a burst of 20 carrier cycles (526 µs, −6.4 %, which the old
±10 % window accepted — now ±5 %, which admits the two widths a whole number of
cycles can produce, 21 at −1.7 % and 22 at +2.9 %, and rejects the third); and a
mutant that was **behaviourally a no-op** because its anchor was written against
the byte's *load* rather than its *rotate*.

## The mutation coverage that pins the testbench

Eleven cases in `regress/mutate_timing_tb.sh`. The four carrier cases are the point
of this act: each leaves the carrier **inside the 38 kHz tolerance** and breaks its
*constancy* or *equality*, which a single frequency window would forgive.

| case | the change | what catches it |
|---|---|---|
| `ir-carrier-h1` | `--const IR_H1=4` | the high half: 4 steps of 193, 13.0 µs instead of 13.15 — inside every window, wrong against the other half |
| `ir-carrier-h2` | `--const IR_H2=5` | the low half, symmetrically |
| `ir-carrier-n1` | **both** halves on the `(2,34)` pair | the two distributions against each other: the halves then differ by the 7 clocks the ladder costs, and the carrier alternates 38.05/37.88 kHz — **0.4 % asymmetric on every edge, inside every window** |
| `ir-gap0` | `--const IR_GAP0=67` | a ZERO sent with a ONE's gap — the decode |
| `ir-gap1` | `--const IR_GAP1=200` | a ONE sent with a ZERO's gap — the decode |
| `ir-leader` | `--const IR_LEADR=1` | the leader is one run instead of two: a 4.5 ms "leader" |
| `ir-leadgap` | `--const IR_LEADGAP=17` | the leader gap is the **truncated** constant — the eight-bit immediate again, 136 µs instead of 4.5 ms |
| `ir-burst-count` | `--const IR_BIT=20` | the burst width: 526 µs, −6.4 %, now outside ±5 % |
| `ir-no-rotate` | the `SHR` that advances the frame becomes a NOP | the decode: every bit is the same bit |
| `ir-stop-burst` | the stop burst is never sent | the burst count — a receiver cannot tell the frame ended from a long gap |
| `ir-no-drive` | the bursts leave the pad released | the decode: a leader and nothing else |

`ir-carrier-n1` is the one worth remembering. It is a mutant that **passes every
window a real receiver has**, and it was only caught because the testbench was
extended to compare the two half-period *distributions against each other* — a
check that does not exist anywhere in the NEC specification, because the
specification does not say the halves must be equal. The hardware requires it and
the datasheet does not state it.

## Limits, stated rather than implied

- **The 32-bit payload is not sent.** The envelope is a correct NEC frame and the
  payload is one byte. Address, inverse address, command, inverse command, and the
  `0x00`/`0xFF` auto-repeat, are not exercised.
- **No optical model.** The testbench models an LED into free space and a receiver
  that times bursts. Ambient light, interference from a fluorescent tube, and the
  bandwidth limit of the receiving photodiode are all absent — and those are the
  failures that make real remotes unreliable, none of which are timing faults.
- **One frame, then park.** A real remote sends on key-down and repeats on hold.
- **Carrier symmetry is checked, carrier phase is not.** The LED emits light during
  one half period; a real receiver integrates over several cycles and does not care
  about the phase relationship to its own clock, so the act does not model one.

## See also

- [[protocol-ws2812]] — the other clockless act, and the contrast between a receiver
  that samples at one instant per cell and one that integrates a burst
- [[protocol-ds18b20]] — the act with a wire, where the polarity flips between the
  two directions
- [[physical-layer-gpio]] — why the pad levels are inverted here (cathode on the pin)
- [[tx-timing-generation]] — the delay routine, its four `(n2,n3)` pairs, and why the
  eight-bit immediate is not a detail
