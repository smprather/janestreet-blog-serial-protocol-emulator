---
title: Servo PWM — a protocol with nothing in it but a number
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, verification, clocking, physical-layer, gpio, architecture]
sources: []
confidence: high
---

# Servo PWM

The servo act is the cleanest demonstration of the project's central claim, and it
is cleanest precisely because there is almost nothing to it. A hobby servo has no
clock, no framing, no acknowledgement and no checksum. The entire protocol is:

> hold the line high for between 1.0 and 2.0 milliseconds, once every 20 milliseconds.

There is nothing to decode and nothing to verify. The only question a servo asks of
the wire is *how long it was high*, and the only way to be wrong is to be wrong about
time.

- firmware: `firmware/servo_sweep.pe` (84 words)
- testbench: `tb/tb_pe_soc_servo.v`
- constant: `SRV_DATA` in the timing-constants block of `tools/fw/peasm.py`
- state machine: `diagrams/proto-servo.puml`
- frame and tables: `diagrams/proto-servo-frame.puml`
- timing: `diagrams/proto-servo-timing.puml`

All figures here are measured by the testbench on **real RTL** — `rtl/pe_cpu.v`, the
real instruction-memory SRAM macro, Icarus, 60 MHz.

## Why it is interesting

If the pulse width is a count of instructions, then "the chip is cycle-accurate" is
not a property of the gates at all. It is a property of the **program**, and anyone
can read the numbers out of the source and check them with a scope. Nothing in
`rtl/` knows what a servo is: a pulse is an `OUT`, a delay, and another `OUT` — the
same three instructions as the I²C START.

And the interesting failure mode is not a wrong number, it is a wrong *shape*.

## The frame is a slot, not a delay

The obvious implementation is "pulse for 1.5 ms, then wait 18.5 ms". That works
until the position changes. If the gap is a constant rather than *the frame minus
this pulse*, a single forgotten subtraction turns 50 Hz into 45 Hz at one end of the
travel and 58 Hz at the other — and a servo notices, because the position jitters and
the motor hums.

So **each position carries its own gap**, chosen as 20 ms minus its own pulse, and
the rise-to-rise interval is 20 ms whatever the pulse width is. The gap is not "the
rest of the frame"; it *is* the frame, minus the pulse.

| position | pulse | gap | slot | pulse n1 | gap n1 |
|---|---|---|---|---|---|
| 0 — 0° | 1 000 µs | 19 000 µs | **20 000 µs (full)** | 97 | 229 |
| 1 — centre | 1 500 µs | 18 500 µs | **20 000 µs (full)** | 145 | 223 |
| 2 | 1 750 µs | 2 500 µs | 4 250 µs (short) | 169 | 31 |
| 3 | 1 250 µs | 2 500 µs | 3 750 µs (short) | 121 | 31 |
| 4 — full travel | 2 000 µs | 2 500 µs | 4 500 µs (short) | 193 | 31 |

## The sweep order is a checkable property

The order is 1.0, 1.5, 1.75, 1.25, 2.0 — **not monotonic**, and that is deliberate.

A sweep that only grows can be satisfied by a firmware that emits the right widths
in the wrong order, and a testbench that sorts its measurements before checking them
cannot tell the difference. Emitting a non-monotonic order makes the order a
checkable property: width *i* is compared against position *i*. The mutation case
`sv-sweep-order` swaps two entries to prove the check has teeth.

## How the widths are made exact

Three nested 8-bit counters, because one counter reaches 255 clocks (4.2 µs) and the
longest delay here is 19 ms — 1.14 million clocks:

```text
dly1: LDM A,11 / SUB A,1 / STM 11,A / JZ dly_done     4
      LDM A,12 / STM 14,A                             2   reload the middle
dly2: LDM A,14 / SUB A,1 / STM 14,A / JZ dly1          4   the middle counter
      LDM A,13 / STM 15,A                             2   reload the inner
dly3: LDM A,15 / SUB A,1 / STM 15,A / JNZ dly3        4   the inner counter,
      JMP dly2                                       1   n3 times

total(n1,n2,n3) = (n1-1) * (10 + (n2-1) * (4*n3 + 7)) + 4   clocks
```text

**Why three levels and not a NOP sled.** 19 ms as NOPs is 1.14 million words against
a 1 024-word instruction memory — the program would not fit. As a loop it is 19
words. The price is a quantisation equal to one step of the outer counter: **10.4167 µs**
for the pulses (on the `(2,152)` pair) and **83.3333 µs** for the gaps (on
`(11,123)`).

**And the outer step is `10 + (n2-1)*(4*n3+7)` — not `4*n3+11`.** That distinction is
not cosmetic, because the short form is the one a reader is likely to reconstruct:

| pair | step, the right way | the short form |
|---|---|---|
| `(2,152)` — pulses | `10 + 1*(4*152+7)` = **625 clocks = 10.4167 µs** | `4*152+11` = 619 clocks |
| `(11,123)` — gaps | `10 + 10*(4*123+7)` = **5 000 clocks = 83.3333 µs** | — |

The short form misses the outer loop's own six instructions and the four that return
it. Multiply 619 out by 96 and you get 990 µs, and a reader concludes the measured
1 000.15 µs is a percent out — from a figure that is in fact exact to 0.0009 %. The
same trap is live in `firmware/servo_sweep.pe`'s own header, which prints the 619 and
the 4 655 forms; the code and the `total()` formula in the same header are right, and
those two intermediate lines are not. This page and the three servo figures use the
formula.

**The reload lines are not optimisation.** Both inner counters are *destroyed* by
their own loops — they arrive at zero — so the caller's count has to be copied into a
working slot at the top of every pass. A version without the reloads reads zero,
subtracts one, wraps to 255, and produces hundreds of thousands of clocks where
thousands were asked for, while looking completely correct. `firmware/ws2812.pe` hit
exactly this; an 8-bit machine with no reload idiom finds the shape by itself.

**How the tables were built.** Not by trial and error and not by eyeballing a scope.
For a chosen `(n2,n3)` the routine reaches any value of the form
`(n1-1)*(10 + (n2-1)*(4*n3+7)) + 4`, so the outer counter that lands nearest a target
*T* is a **division**, and choosing `(n2,n3)` to keep every table entry inside 255 is
a small search. Both tables are the result of that, and every entry lands within
0.25 µs of its target.

### Reproducing the table, so the figures can be checked

| what | arithmetic | clocks | µs |
|---|---|---|---|
| pulse 0, n1 = 97 on (2,152) | 96·625 + 4 | 60 004 | 1 000.07 |
| pulse 1, n1 = 145 on (2,152) | 144·625 + 4 | 90 004 | 1 500.07 |
| pulse 2, n1 = 169 on (2,152) | 168·625 + 4 | 105 004 | 1 750.07 |
| pulse 3, n1 = 121 on (2,152) | 120·625 + 4 | 75 004 | 1 250.07 |
| pulse 4, n1 = 193 on (2,152) | 192·625 + 4 | 120 004 | 2 000.07 |
| gap 0, n1 = 229 on (11,123) | 228·5 000 + 4 | 1 140 004 | 19 000.07 |
| gap 1, n1 = 223 on (11,123) | 222·5 000 + 4 | 1 110 004 | 18 500.07 |
| gaps 2…4, n1 = 31 on (11,123) | 30·5 000 + 4 | 150 004 | 2 500.07 |

Slot 0 is 60 004 + 1 140 004 = **1 200 008 clocks = 20 000.13 µs**. The testbench
**measured 19 999.95 µs** on the wire — 0.0009 % apart, and arrived at from
instruction counts rather than from a fitted constant. That agreement is the evidence
that the derivation is the right model of the machine and not a fit to the answer.

## The measured result

```text
    5 rising edges, 6 falling edges on the pin
    pulse 0:  1000.15 us high  (requested 1000 us, +0.15 us)
    pulse 1:  1500.13 us high  (requested 1500 us, +0.13 us)
    pulse 2:  1750.12 us high  (requested 1750 us, +0.12 us)
    pulse 3:  1250.13 us high  (requested 1250 us, +0.13 us)
    pulse 4:  2000.10 us high  (requested 2000 us, +0.10 us)
    frame period (1000 us -> 1500 us): 19999.95 us = 50.000 Hz
    (positions 2..4 use a 2.5 ms sweep gap by design)
    dmem[10] (position index) = 5

PASS: all checks
```text

**All five widths are 0.10 to 0.15 µs LONG, and that direction is systematic rather
than noise.** The clock count is exact — the core is single-cycle, so *N* instructions
take exactly *N* clocks — and the residue is the table entry's *fitting*: the outer
counter is a whole number of steps, so each entry lands at or just above its target. A
count that could fall short as easily as long would be a worse mechanism here, because
the datasheet's interesting bound on this protocol is a **minimum**.

### The tolerances, and why they are the ones they are

| what | band | what it protects |
|---|---|---|
| pulse width | 1 000 … 2 001 µs | the servo ignores or saturates outside |
| vs the requested width | ± 30 µs | a sweep that is not a sweep |
| frame period | 19 900 … 20 100 µs | 49.5 … 50.25 Hz; the motor hums outside |
| short gap | > 1 000 µs | a short gap is still a gap, not a second pulse |

`PULSE_MAX_US` is 2 000 **+ 1**, and the 1 µs is stated in the testbench rather than
hidden: a firmware that produced exactly 2 000.0 µs would otherwise sit *on* the
datasheet ceiling, and a ceiling a program can land on exactly is a ceiling a rounding
error can push it over.

The frame period is a band and the pulse widths are compared against the **request**,
which are two different and both-necessary shapes. A frame period is two measured
widths added together, so its error is the sum of the two tables' fitting error —
bounded at 0.25 µs each by construction — and a band is the honest shape of that
claim. The widths are compared against what the firmware was *asked for*, which pins
the sweep rather than merely the band.

## The idle level is part of the protocol

The servo's idle level is LOW, and the program sets it **before** claiming the pin.
A first version wrote `SRV_DATA` there instead of `0`, reasoning that the pin was
about to go high anyway.

The consequence: the line stayed *released* — so pulled HIGH by the board's pull-up —
from reset until the first pulse, and the first pulse therefore had **no rising edge
at all**. The testbench saw four rises and five falls and correctly refused to call it
five pulses. The mutation cases `sv-idle-level` and `sv-first-rise` are this defect
made into permanent cases.

## How the testbench proves it

Eight checks, and the shape of them is the family pattern:

1. **exactly five rising edges** — the pulse count;
2. every width inside 1 000 … 2 001 µs;
3. every width within 30 µs of the **request**, in the firmware's order;
4. the frame period inside 19 900 … 20 100 µs;
5. each short gap still exceeds 1 000 µs;
6. `dmem[10] == 5` — the firmware actually finished;
7. the **last** recorded edge is a fall — the line parks low;
8. non-vacuity: the five widths are pairwise **distinct** and span more than 900 µs.

### Two measuring-instrument defects worth recording

**Each rise is paired with the *next* fall, not with the *j*-th fall in the list.**
The pin has a *leading* fall: the firmware drives the line from the released pull-up
high down to the servo's idle low as it claims the pin. Counting falls independently
pairs pulse 0 with that fall and shifts every measurement by one pulse. Pairing by
order is the obvious version and it is wrong in exactly the way this protocol is
about — the leading edge is a *level*, not a *pulse*.

**The frame period is measured across two *different* pulse widths.** 1 000 µs then
1 500 µs, rise to rise. A fixed gap after each pulse would give 20.5 ms and then
21.0 ms — 49 Hz, then 47.6 Hz — and every per-pulse *width* check would still pass.
This is the measurement that tells a slot from a delay, and it is the one number in
the act that is a band rather than an equality.

### The four stopped clocks before `run`

The testbench waits four clocks and then `#1` before raising `run`, and neither is a
fudge:

- the instruction memory is a real SRAM macro with a **registered read** and REN
  deasserted through every loader write. Without the stopped clocks the first running
  cycle can see a stale fetch word and the program's **first instruction is silently
  dropped**;
- the `#1` is what makes the four clocks count. Rising `run` in the same active-region
  instant as a clock edge leaves the macro's fetch half-updated — the `always_ff`
  blocks and the `initial` block race — and which way they resolve is not something a
  test may depend on. Without it this testbench lost **two** instructions instead of
  none, a strictly worse failure than the one the stopped clocks prevent.

What it cost, in a form worth keeping: the servo firmware's first instruction is
`LDI A,97` — the one that loads the first entry of the pulse table. Dropped, it left
`dmem[0]` as `X`; the program then ran perfectly happily, five pulses and all, with
the first position's delay counter taken from an unwritten byte, which is a 2.6 ms
pulse where 1.0 ms was asked for. **The testbench failure pointed at the delay
arithmetic rather than at the load, which is the worst possible place for it to
point.**

## The mutation coverage that pins the testbench

Five cases in `regress/mutate_timing_tb.sh`, chosen so the check each trips is the
specific property claimed:

| case | the change | what catches it |
|---|---|---|
| `sv-pulse-width` | `dmem[0]`: 97 → 170 | the per-pulse width **and** the sweep span — 1.75 ms where 1.0 ms was asked for |
| `sv-frame-slot` | `dmem[5]`: 229 → 210 | the frame period — a 17.6 ms gap makes the slot 18.6 ms, and this is the only check that sees the *sum* |
| `sv-sweep-order` | `dmem[1]`: 145 → 169 | the sweep **order**: the widths are all still legal and in range, and measurement 1 is simply the wrong position's width |
| `sv-idle-level` | the idle level becomes HIGH | the pulse count: the first pulse has no rising edge at all |
| `sv-first-rise` | the initial drive is HIGH | the pulse count, from the other direction |

`sv-frame-slot` and `sv-sweep-order` are the two worth singling out. `sv-frame-slot`
keeps **every individual pulse width legal** and breaks only the relationship between
them — a per-width check suite would call it a pass, and a servo would hum. And
`sv-sweep-order` is a defect no window check of any kind can express, because the set
of widths is unchanged; only the order differs, and the order is a claim.

## The cost, stated

The servo testbench simulates **52.5 ms** of 60 MHz — 3.15 million clocks, about 66
seconds of wall time. It is the longest simulation in the repository at the time of
writing, and three things were done about it, none of which weakened a claim:

- the frame rate is measured on **two** 20 ms slots rather than five. The 50 Hz claim
  rests on the measured frame period; the sweep claim rests on five measured *widths*,
  which is what it needs;
- the testbench dumps a **narrow** signal set instead of `$dumpvars(0, tb)` — that was
  99 s → 66 s on its own. The waveform, not the design, was the bottleneck;
- the edge recorders are edge-triggered with `$realtime` rather than per-clock with a
  counter, worth another ~40 %.

## Limits, stated rather than implied

- **The position-feedback pulse is not read.** Some servos drive one back on the same
  wire. That is a limitation of the *program*, not of the matrix, which can read the
  pin — the same `IN A, PIN` the I²C firmware uses for arbitration would see it. A real
  driver would read it; this one drives and parks.
- **The 50 Hz claim rests on the two full slots.** Positions 2…4 are not in 20 ms
  slots, and the testbench labels them "a short sweep gap, not a frame" rather than
  reporting them as slots.
- **Signal-level only.** A real servo needs a supply and a common ground. This is a
  demonstration on a pin matrix, not a board bring-up.

## See also

- [[protocol-ws2812]] — the sibling act whose equalised-branch discipline this one
  does not need, and whose delay loop this one's header is careful about
- [[physical-layer-gpio]] — the pads, `pin_oe`, and why a released pin reads high
- [[tx-timing-generation]] — how a counted instruction count becomes a delay
- [[tx-timing-generation]] and [[clock-doubler]] — why a deterministic count scales
  with the clock and a calibrated one does not
