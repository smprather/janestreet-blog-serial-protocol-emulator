---
title: Frequency and duty meter — the first act that listens
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, verification, clocking, physical-layer, architecture]
sources: []
confidence: high
---

# Input frequency and duty meter

Six of the timing acts in this repository **drive** a pad. This one **listens**,
and that makes it a different shape of problem: the PWM arrives from outside, the
program cannot ask when the edges are coming, and the answer it has to produce is
a count between two edges it did not schedule. So the number that is the claim is
not a delay at all — it is the **accuracy of a count**.

- firmware: `firmware/freqmeter.pe` (103 words)
- testbench: `tb/tb_pe_soc_freqmeter.v`
- constants: `FM_IN`, `FM_PER_BASE`, `FM_HI_BASE` in `tools/fw/peasm.py`
- state machine: `diagrams/proto-freqmeter.puml`
- the two numbers and the twelve points: `diagrams/proto-freqmeter-frame.puml`
- edge timing and accuracy: `diagrams/proto-freqmeter-timing.puml`

All figures here are measured on **real RTL** — `rtl/pe_cpu.v`, the real SRAM
macro, Icarus, 60 MHz — and every banked point is checked against a *second,
independent* measurement of the pad rather than against the generator's table.

## What is measured

Per run, two 16-bit pairs — `(period, high time)` in whole microseconds — for two
consecutive periods. The testbench sweeps the input over **158 Hz to 10 kHz** with
a varying duty and checks **every banked point**, not the ends of the sweep.

## Why the low end is the whole point of the act

At 100 Hz the period is 10 000 µs, which does not fit in one 8-bit counter. A
firmware that counts into a byte **wraps and reports 16 µs** for a 100 Hz signal: a
wrong *answer* rather than a wrong precision, and a defect with **no symptom at any
other point in the sweep**.

That is why the counters are 16-bit and why the mutation gate perturbs the high
byte specifically. Point 1 is 10 001 µs, from a counter whose low byte wrapped
**39 times**.

## The timebase, and the trap in it

This SoC has **two** tick counters and they are not the same size:

| port | name | period | what it is for |
|---|---|---|---|
| 0x7 | `STATUS` | 260 clocks = **4.33 µs** | the UART half-bit tick: it exists to place a serial sample mid-cell |
| 0x4 | `I2CTICK` | 60 clocks = **1 µs** | the free-running microsecond counter |
| 0x6 | `I2CSTAT` | 1 µs | that counter's clear-on-read **flag** |

The first version counted `STATUS` and measured **0.24 ticks per microsecond** — a
factor of 4.33 out, reporting a 200 µs period as 46. A tick counter whose name says
TIMER is not a microsecond.

**And the flag is not the fix either.** A clear-on-read flag is *one bit*, so a poll
loop that takes longer than a tick reports several ticks as one, and the loss is
invisible in the result — the measurement is simply short, by an amount that depends
on how busy the program was. This program is one instruction from that defect and
does not have it, because it reads the **counter** and adds the **difference**:

```text
elapsed = (now - previous) mod 256
```

exact for any loop up to 255 µs, and this loop is 1.3 µs — two hundred times
inside it. Two properties follow from the same three instructions: there is no flag
to lose, so a slow iteration makes the measurement **late by exactly the right
amount** rather than wrong; and the borrow of `now - previous` is used only as *"is
it zero"*, which is the one comparison the ISA has — so one `SUB` does both jobs.

## The ISA constraint, and what it cost

The machine is 8-bit with **no carry flag** — only `JZ`/`JNZ` exist — so 16-bit
arithmetic is hand-built. Three facts decided the whole program:

1. **A 16-bit increment is cheap.** `+1` on the low byte is exactly zero when it
   carries, so the carry test is one `JZ` on the low result.
2. **A 16-bit add of a variable is affordable, but only just.** The carry test is
   the same `JZ`, except that `0 + 0 = 0` is not a carry, so a general addend needs
   a **guard**: when the low result is zero, reload the low operand and test *it*
   for zero too. This program gets that guard away **for free**, because its addend
   is the elapsed microsecond count and is therefore **never zero** — *"the low
   byte came out zero"* can then only mean *"the low byte wrapped"*. The guard is
   not skipped, it is **unnecessary**, and the source comment says which.
3. **A 16-bit subtract is a different machine.** The borrow of `a - b` cannot be read
   off the difference: `(a-b) mod 256` has two preimages, one positive and one
   negative, for every value except zero. Getting it exactly needs a four-case
   analysis on bit 7, and a *compare* is the same analysis again.

So the program contains **no 16-bit subtract and no compare at all**, and that is
the design rather than a limitation worked around:

> **The period is `T` at the rising edge, because `T` is *reset* at every rising
> edge. The high time is `H` at the rising edge, because `H` is also reset there
> and *stops counting* at the falling edge.**

**Two resets remove every subtract, every compare and every divide.** The commit
message called this act *"capture only"* before a line of it existed, and that is
what it turned out to be — for a reason the commit message could not have known.

## The machine has sixteen bytes, and the testbench had to be told

`DMEM_BYTES = 16`. A period is two bytes and a high time two, so the firmware banks
**two points per run** and the sweep is **six runs of three periods**.

The first period of each run is a **warm-up and is not checked**, for a reason that
is a property of the *protocol* and not of the firmware: the firmware starts in the
middle of it, so the time since the previous rising edge is not a period. A receiver
that starts mid-period misses that one period, and a testbench that pretended
otherwise would be asking the firmware to measure something it was never present for.

The map uses all sixteen bytes, and one byte is **shared rather than found**: the
slot index doubles as the *"no rising edge seen yet"* state (`FF`), because the
program needed one byte more than the machine has and the slot index is the one
value that is not a measurement.

## The measured result

| point | period | high | duty | pad (independent) |
|---|---|---|---|---|
| 0 | 8 000 µs (125.00 Hz) | 6 000 | 75.0 % | 8000.000 / 75.00 % |
| **1** | **10 001 µs (99.99 Hz)** | 2 500 | 25.0 % | 10000.000 / 25.00 % |
| 2 | 3 150 µs (317.46 Hz) | 1 039 | 33.0 % | 3150.000 / 33.00 % |
| 3 | 4 000 µs (250.00 Hz) | 400 | 10.0 % | 4000.000 / 10.00 % |
| 4 | 1 600 µs (625.00 Hz) | 1 056 | 66.0 % | 1600.000 / 66.00 % |
| 5 | 2 000 µs (500.00 Hz) | 1 600 | 80.0 % | 2000.000 / 80.00 % |
| 6 | **801 µs** (1 248.44 Hz) | 480 | 59.9 % | 800.000 / 60.00 % |
| 7 | 1 000 µs (1 000.00 Hz) | 399 | 39.9 % | 1000.000 / 40.00 % |
| 8 | 400 µs (2 500.00 Hz) | 180 | 45.0 % | 400.000 / 45.00 % |
| 9 | 500 µs (2 000.00 Hz) | 275 | 55.0 % | 500.000 / 55.00 % |
| 10 | 80 µs (12 500.00 Hz) | 12 | 15.0 % | 80.000 / 15.00 % |
| 11 | 100 µs (10 000.00 Hz) | 50 | 50.0 % | 100.000 / 50.00 % |

**Every period is exact except three, by exactly one tick** — 10 001, 801 and 399
against 10 000, 800 and 400 — and the duty follows to a tenth of a point because
the two counts share the same edge discipline.

That is the **resolution showing up in the log instead of hiding in a tolerance**,
which is what a measured-truth record should look like. A page that printed "within
1 %" here would be hiding the instrument's resolution in the one place a reader
wants to see it.

### Why the tolerance is per point and not one number

The instrument's resolution *is* the specification:

| point | period | relative error of a 1 µs counter |
|---|---|---|
| 10 000 µs (100 Hz) | 10 000 | **0.01 %** |
| 100 µs (10 kHz) | 100 | **1.0 %** |

The tolerance is therefore 1 % of the period with a floor of 1.5 ticks, and at the
fast end of the sweep the *tolerance* is the dominant term and the quantisation is a
percent of it. **A single accuracy number would be a false claim at one end or the
other** — which is why the act states per point.

## How the testbench proves it

Seven checks, and two of them exist because this act's own failure modes demanded
them:

1. every banked period within 1 % of the pad's, with a floor of 1.5 ticks;
2. every banked high time likewise, and the duty follows;
3. the `DONE` flag is set **and every result was actually written**;
4. the twelve periods are pairwise **distinct**;
5. the twelve duties are neither constant nor 50 % twice running;
6. at least one banked period is above 255 while another is inside a byte — the
   16-bit claim stated **from both sides**;
7. the twelve points are checked against the pad's own receiver.

That last point is the one that makes the rest mean anything: **a generator that
knew the answer would agree with a firmware that had the sweep wrong.**

## The mutation coverage that pins the testbench

Ten cases in `regress/mutate_timing_tb.sh`, two of which exist because this act's
own failure modes demanded them:

| case | what it proves |
|---|---|
| `fm-tick-port` | the timebase is the **1 µs counter** and not the 4.33 µs one — reached through `--const`, because a `sed` of the `.pe` cannot reach `peasm`'s table |
| `fm-t-high-byte` | the 16-bit claim: the period's high byte really is incremented |
| `fm-h-high-byte` | …in the *other* counter too. The longest high time, 6 000 µs, is **not** covered by the longest period, so the two cases are genuinely different |
| `fm-wrong-pad` | the pad mask constant |
| `fm-no-rearm` | the reset that makes the measurement *elapsed time* rather than *absolute time* — and it is the one mutant whose **first** point is still correct |
| `fm-double-count` | the counters advance once per elapsed microsecond |
| `fm-idx-stuck` | the slot index advances |
| `fm-finishes-early` | the run does not stop after one point — **caught only by the new "was it actually written" check** |
| `fm-high-is-period` | the high time is banked from the high-time counter and not the period counter — every duty would read 100 %, which is a value a careless reader accepts |
| `fm-per-base` | the slot base constant, where a shifted base **overlaps the working counters** on a sixteen-byte machine instead of running off the end |

`fm-t-high-byte` and `fm-h-high-byte` are the pair worth noticing: they exist
because the act has *two* 16-bit counters with different maxima, so a single
high-byte case would leave one of them unchecked.

## Six defects, in the firmware (2) and the testbench (4)

### In the firmware

1. **The wrong tick counter.** Port 7 is the 4.33 µs UART half-bit tick, not a
   microsecond. Every measurement was a factor of 4.33 out and *short* at every
   point — the shape a timebase mistake always has, and invisible in a log that only
   prints the two slowest points.
2. **A clear-on-read flag for a timebase.** Not a wrong answer yet, but the design
   was one busy iteration away from losing ticks silently.

### In the testbench

1. **`pin_in_bus` put the PWM on bit 5, not bit 6.** `{1'b1, 1'b1, pwm, 5'b11111}` is
   eight bits with `pwm` third from the top; the firmware reads bit 6, so the pad
   never appeared to change and the firmware sat in its poll loop for 60 ms
   reporting nothing. The first full run's only output was a watchdog. The three
   sibling acts write the same concatenation correctly, so the correct form was in
   the repository and was not copied.
2. **The receiver was armed before the pad was presented, not when the firmware was
   released.** Whether presenting the pad high is itself an edge depends on where the
   previous run's waveform stopped, so the edge list had a spurious entry on some
   runs and not others, and the index arithmetic was off by one exactly when nobody
   was looking. Two of the twelve points were compared against the wrong interval.
3. **A ternary that was never a comparison.** `if (a > b ? w : f)` parses as
   `if ((a > b) ? w : f)` and both arms are nonzero, so the condition was **always
   true** — the period and high-time checks reported "12 of 12 are not" for values
   that differed by 0.0000 µs. The same expression in a `$display` evaluated
   correctly, which is why it took a debug copy with the difference printed to find.
4. **A result that was never written passed every arithmetic check.** A comparison
   against an unknown is false in Verilog, so a firmware that banked one point and
   left the other slot alone passed the period, high-time, duty and `DONE` checks.
   Found by asking what a `fm-finishes-early` mutant would do, *before* writing the
   mutant.

## The machine sized to what it wished for

The original RED testbench asked for sixteen points in `dmem[0..63]` on a machine
with sixteen bytes: twelve of its own expectations were read out of an address space
that does not exist, and its `DONE` flag at `dmem[14]` was **inside the data it was
reporting**.

**A test that sizes memory to what it wishes for is a test that reports success
without measuring anything**, and the count of such elements in this block is now
three.

## Limits, stated rather than implied

- **The bank is two points per run, six runs of three periods.** Sixteen points in
  sixteen bytes does not fit, and the act's claim is about the *sweep*, which
  twelve points spanning 158 Hz to 10 kHz and ten duties establishes.
- **The warm-up period of each run is not checked**, for the protocol reason above.
- **The measurement is in whole microseconds.** Sub-microsecond period accuracy is
  not claimed, and the 80 µs point's floor of 1.5 ticks is 1.9 % of its period.
- **No input conditioning is modelled.** A real PWM source's rise time, its threshold
  and any filtering are absent; the act measures a digital pad.

## See also

- [[protocol-ws2812]] — the act that drives a pad, for the contrast between a
  generator and a receiver
- [[tx-timing-generation]] — the delay routine the other six acts share, and why
  this one has none
- [[physical-layer-gpio]] — the pads, and why `IN A, PIN` reads the pad rather than
  the output register
- [[cdr-oversampling]] — the other place in this repository where a receiver's
  accuracy is the specification rather than a tolerance
