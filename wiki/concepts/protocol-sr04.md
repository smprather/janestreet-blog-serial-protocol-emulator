---
title: HC-SR04 ranging — a red act, and the one thing it does prove
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, verification, clocking, physical-layer, gpio, architecture]
sources: []
confidence: high
---

# HC-SR04 ultrasonic ranging

> **This act is RED.** `firmware/sr04_range.pe` + `tb/tb_pe_soc_sr04.v` elaborate on
> real RTL and **fail five checks**. It is not wired into `regress/run_all.sh`, so a
> green gate says nothing about it in either direction. This page records what the act
> *does* prove and what remains open, and the figures mark the failing state rather
> than drawing over it.

- firmware: `firmware/sr04_range.pe`
- testbench: `tb/tb_pe_soc_sr04.v`
- constants: `SR_TRIG`, `SR_ECHO`, `SR_TRIG_LEN`, `SR_RECOV_LEN` in `tools/fw/peasm.py`
- state machine: `diagrams/proto-sr04.puml`
- the exchange and the conversion: `diagrams/proto-sr04-frame.puml`
- timing, with the red state: `diagrams/proto-sr04-timing.puml`

## What the act is

HC-SR04 is the only act in this family whose **answer is a number** rather than a
waveform. A 10 µs pulse on `TRIG` makes the device emit eight 40 kHz bursts and then
hold `ECHO` high for the round trip, so **the width of the echo pulse is the
distance**:

```text
t (us) = 2 * d (mm) / 0.343 mm/us   ->   d (mm) = t * 11/64
```text

`11/64` is **+0.22 % long** against the speed of sound. That error belongs to the
*constant*, and the act states it rather than absorbing it — because "the arithmetic
is exact for 11/64" and "the ranging is right to two parts in a thousand" are
different claims, and only the first can be asserted as an equality.

## The protocol, and the two pads

| step | who | what |
|---|---|---|
| 1 | **host** | `TRIG`, pin 6: a ≥ 10 µs pulse, **driven** |
| 2 | sensor | recovery, then eight 40 kHz bursts |
| 3 | sensor | `ECHO`, pin 5: **released**, and read back — high for the round trip |
| 4 | **host** | measure the width, convert, bank |

Two separate pads because the host drives one and listens on the other: the level
and the enable cannot be written together the way the other acts do, so the firmware
keeps them in `dmem[5]` and `PINOE` and writes them deliberately.

**The echo is captured, not sampled** — and that is what makes the act safe at 4 m.
A receiver that samples a level and decides "something is there" has to poll, and a
poll loop that is long relative to the distance reading adds its own uncertainty to
every sample. A receiver that measures the *width* does not care when it looked: the
two edges define the interval, and the interval is the answer.

## The conversion is the act, and it is exact

The plan budgeted a 16×16 multiply. The identity removes it:

```text
us = 64q + r
us * 11 / 64  =  11q + 11r/64  =  11q + floor(11r/64)
```text

**exactly, because `11q` is an integer.** So the conversion is a multiply by eleven of
a ten-bit number, a multiply by eleven of a six-bit number, and one add — no
division, no approximation.

**A multiply by eleven is four doublings and two adds:** `x → 2x → 4x → 5x → 10x →
11x`. No loop, no counter, no second temporary; the multiplicand stays in Q
throughout.

**A doubling is the cheapest 16-bit operation this ISA has, and unlike any other
16-bit add it needs no both-zero guard.** The carry out of `lo+lo` is bit 7 of the
*original* low byte, so one `AND` with `0x80` and one `JNZ` is the whole test; and
"the result is zero" means "nothing carried", because doubling zero cannot carry and
is the only way to reach zero. A general add of a variable *is* different — `0 + 0 = 0`
is not a carry, so the addends must be re-read to tell a wrap from a pair of zeros.
**That asymmetry is the reason the conversion is mostly doublings.**

**No 16-bit overflow is possible anywhere**, and the largest value involved is
`11 × (23000 >> 6) = 3949`; the intermediates are `8q = 2872` and `10q = 3590`, and
the second term is `11 × 63 = 693`. Recorded rather than assumed, because an unnoticed
overflow in the high byte is invisible from the outside — the answer would still be a
plausible millimetre figure.

## What the act proves: the conversion, on the one measurement that ran

```text
    measurement 0: echo 1160 us -> firmware 1160 us, answer 199 mm (expected 199 mm)
    measurement 1: echo 5816 us -> firmware 1160 us, answer X mm (expected 999 mm)
```text

**`1160 × 11/64 = 199.375 → 199 mm`, expected 199 mm.** The testbench asserts this
as an *equality*, and it holds. The arithmetic the act exists to demonstrate is
correct.

The two targets are 1 160 µs and 5 816 µs for a reason: the small one fits in twelve
bits and the large one does not, so the pair exercises the ten-bit path **and** the
high byte. A single near target would prove the conversion works and say nothing
about the case that could overflow.

## What is open, stated exactly

```text
FAIL: the firmware banked both measurements (dmem[10] = 01)
FAIL: the model saw exactly 2 triggers (1) -- a trigger that is driven rather than pulsed shows up here
FAIL: the trigger pulse is EXACTLY 600 clocks = 10.000 us (measured 601 = 10.017 us), and the device asks for 10 us minimum
FAIL: measurement 1: the measured width 1160 us is outside 1 % (floor 2 us) of the model's 5816 us
FAIL: measurement 1: 1160 us is X mm, not 999 mm -- us*11/64 is exact and this is an equality
```text

| quantity | derived / datasheet | measured | status |
|---|---|---|---|
| trigger pulse | `4 × 149 + 4 = 600` clocks = 10.000 µs | **601 clocks = 10.0167 µs** | FAIL, one clock long |
| echo 1 | 1 160 µs | **1 160 µs** | PASS, exact |
| echo 2 | 5 816 µs | **1 160 µs** | FAIL, never measured |
| mm from echo 1 | `1160 × 11/64 = 199.375` | **199 mm** | PASS, an equality |
| mm from echo 2 | `5816 × 11/64 = 999.4` | **X** | FAIL, X is an unwritten byte |
| measurements banked | 2 | **1** (`dmem[10] = 01`) | FAIL |

**The failure is upstream of the conversion.** Every failing check is about the second
measurement not happening, and none is about the answer being wrong.

**What is not claimed: which instruction is wrong.** The five checks say the second
measurement does not happen; they do not say why, and a page that named a cause
would be presenting a hypothesis as a finding. **Where to look first** is the
601-vs-600 trigger — it is a one-instruction error of exactly the kind this family has
found six times, and it sits in the path that issues the second trigger and re-arms
for the second echo. That is a place to look, not the fault.

**And note what is absent from the failure list:** no conversion check failed, and no
first-measurement check failed. A red table that mixes a proven property with a broken
one, without saying which is which, is worse than a red table — the reader cannot
tell whether to trust the arithmetic or to distrust it.

## The timebase, for the same reason as the frequency meter

The echo width is read from the **1 µs counter as a difference**, exactly as in
`firmware/freqmeter.pe`: the clear-on-read flag on port 6 is *one bit*, so a poll loop
longer than a tick reports several ticks as one, and the loss is invisible in the
result. Port 7 is the 4.33 µs UART half-bit tick and is not a microsecond.

And there is **no 16-bit subtract** in the measurement: the counter is *reset* at the
echo's rising edge and *read* at its falling edge, so the answer is whatever
accumulated. This machine has no carry flag, so a 16-bit subtract is a four-case
analysis on bit 7 and a compare is the same analysis again — one reset removes both.

## The trigger is a count of instructions, not microseconds

`SR_TRIG_LEN = 149`, and the act's own derivation is `4 × SR_TRIG + 4` — a count of
*instructions*, which is why it lives in `peasm`'s `CONSTS` table rather than in the
`.pe` source, and why the act can be perturbed through `--const` at all.

The device asks for 10 µs **minimum**, so the extra clock is harmless to a real sensor,
and the check is an equality anyway — because the act claims the *count* and not a
datasheet floor. That is the same discipline `firmware/ws2812.pe` uses when a 74-clock
cell clears every window in print.

## Limits, stated rather than implied

- **The act is red.** Everything above about the conversion is true of measurement 0
  only, and the second measurement is not reached.
- **Not in the regression.** `tb_pe_soc_sr04.v` is tracked but not wired into
  `regress/run_all.sh`, so this act's state has to be read by running it. That is how
  the numbers on this page were obtained.
- **No acoustic model.** There is no propagation delay, no reflection, no target
  angle and no noise: the "sensor" presents an echo of a width the testbench chooses.
  The act measures a *counter*, not the speed of sound, and the `0.343 mm/µs` constant
  is a property of air that this simulation does not model at all.
- **The 40 kHz bursts are not used.** The firmware cannot resynchronise to a burst it
  did not send, so it ignores them; a real ranging front end sometimes uses them for
  exactly that.
- **No `SR_RECOV_LEN` verification in this run.** The recovery wait's *absence* was a
  real defect once; its presence did not make the second measurement happen, and this
  run does not separate the two.

## See also

- [[protocol-freqmeter]] — the sibling act that also reads the 1 µs counter as a
  difference, and for the same reason
- [[protocol-ws2812]] — the act whose equalised-branch discipline the 601-vs-600
  trigger error is the same shape as
- [[physical-layer-gpio]] — the pads, and why `ECHO` is released and read rather than
  driven
- [[tx-timing-generation]] — why a counted delay is a count of instructions and not a
  number of microseconds

## A note on the quoted failure message, which is itself wrong

The testbench's failing check prints:

```text
FAIL: the trigger pulse is EXACTLY 600 clocks = 10.000 us (measured 601 = 10.017 us), and the device asks for 10 us minimum
```

**The clock counts are right and the microsecond conversions are now right too.** That
was not always so, and the history is worth keeping because it is a small instance of
a class this branch spent a lot of effort on.

The message used to report `600 clocks` as `10000.000 us` — **out by a factor of
1000**.
600 clocks at 60 MHz is 10.000 µs. The clock count was right; the conversion was
folded the wrong way, because `CLK_NS` is nanoseconds and the check reports in
microseconds, and folding one into the other is not a rounding detail.

It was found by `tools/diag/delay_lattice.py` — the numbers gate this branch added —
on its first full run over all thirty-two files, as the **fourth** instance of the
same class: a clock count and a microsecond conversion printed side by side, with
only one of them derived. That is the same class as the three the gate was built to
catch, and it was in a file written minutes earlier, quoted from a testbench message
that had the same error in it. **The instrument's output was wrong and the figure
faithfully reproduced it**, which is the worst shape for a documentation page: it is
exactly right about what the testbench said.

It was fixed in `tb/tb_pe_soc_sr04.v` (f7ac41b, by its owner, not from this page),
which added `CLK_US = CLK_NS / 1000.0` and changed the check to use it. The fix's own
comment carries the lesson: *a red act's output gets quoted verbatim — it is the first
thing a reader sees — so a unit error in a failure message is a defect in the report,
not a cosmetic slip.*

**An earlier revision of this page quoted the broken message and marked it `[sic]`.**
Those markers are gone, and deliberately: `[sic]` is the exemption
`delay_lattice.py` uses to skip a conversion it is asked to recompute, so a stale
marker does not just make a page wrong, it **switches off the check on a line that is
now correct**. A marker that outlives the thing it marked is worse than no marker.

The act is still **RED**, with the same five checks, and the second measurement is
still not reached. What changed here is only that the failure report now says what it
means.
