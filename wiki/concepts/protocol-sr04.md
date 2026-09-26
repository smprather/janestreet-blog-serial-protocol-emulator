---
title: HC-SR04 ranging — a number, not a waveform
created: 2026-09-25
updated: 2026-09-26
type: concept
tags: [protocol, verification, clocking, physical-layer, architecture]
sources: []
confidence: high
---

# HC-SR04 ultrasonic ranging

HC-SR04 is the only act in this family whose **answer is a number** rather than a
waveform. A 10 µs pulse on `TRIG` makes the device emit eight 40 kHz bursts and then
hold `ECHO` high for the round trip, so **the width of the echo pulse is the
distance**.

> **Status: GREEN.** `tb/tb_pe_soc_sr04.v` passes on real RTL, the act is wired into
> `regress/run_all.sh`, and an earlier revision of this page described it as red. That
> description was true when written and is not true now — see *What changed*, which
> records the supersession rather than quietly replacing it.

- firmware: `firmware/sr04_range.pe`
- testbench: `tb/tb_pe_soc_sr04.v`
- constants: `SR_TRIG`, `SR_ECHO`, `SR_TRIG_LEN`, `SR_RECOV_LEN` in `tools/fw/peasm.py`
- state machine: `diagrams/proto-sr04.puml`
- exchange and conversion: `diagrams/proto-sr04-frame.puml`
- timing: `diagrams/proto-sr04-timing.puml`

Every figure on this page is measured by the testbench on real RTL — `rtl/pe_cpu.v`,
the real SRAM macro, Icarus, 60 MHz.

## The measured result

```text
image: 387 words loaded from firmware/sr04_range.hex (637 NOP-filled)

=== HC-SR04 ranging: 4 runs, one distance each: 1160, 5816, 2000 and 8000 us ===

  run 0: model armed for a 1160 us echo (199 mm), core released
    run 0: echo 1160 us -> firmware 1160 us, answer 199 mm (expected 199 mm)
  run 1: model armed for a 5816 us echo (999 mm), core released
    run 1: echo 5816 us -> firmware 5816 us, answer 999 mm (expected 999 mm)
  run 2: model armed for a 2000 us echo (343 mm), core released
    run 2: echo 2000 us -> firmware 2000 us, answer 343 mm (expected 343 mm)
  run 3: model armed for a 8000 us echo (1375 mm), core released
    run 3: echo 8000 us -> firmware 8000 us, answer 1375 mm (expected 1375 mm)
PASS: all checks
```

**Four runs, four distances, all four exact.** The act is no longer a two-target
demonstration with one target failing; it is four, and the pair that used to fail
(5 816 µs) is now the one that carries the ten-bit path *and* the high byte.

## The protocol, and the trigger's exact derivation

| step | who | what |
|---|---|---|
| 1 | **host** | `TRIG`, pin 6 (`SR_TRIG` = 0x40): a **601-clock** pulse, **driven** |
| 2 | sensor | recovery (`SR_RECOV_LEN` = 117), then eight 40 kHz bursts |
| 3 | sensor | `ECHO`, pin 5 (`SR_ECHO` = 0x20), **released** and read back — high for the round trip |
| 4 | **host** | measure the width, convert, bank |

### `601`, and the constant name that is easy to get wrong

```text
total = 4 * SR_TRIG_LEN + 5  =  4 * 149 + 5  =  601 clocks  =  10.0167 us
```

**`SR_TRIG_LEN` is not `SR_TRIG`.** Both constants exist and they are different
kinds of thing:

| constant | value | what it is |
|---|---|---|
| `SR_TRIG` | `0x40` | the **pin bit** — which pad drives the trigger |
| `SR_TRIG_LEN` | `149` | the **delay count** — how long the trigger is held |
| `SR_ECHO` | `0x20` | the pin bit for the released, read-back echo |
| `SR_RECOV_LEN` | `117` | the sensor's recovery wait |

An earlier revision of this page and of `diagrams/proto-sr04.puml` printed
`4 * SR_TRIG + 4 = 600 clocks = 10.000 us`. That is wrong in **three** ways at once —
the `+ 4` should be `+ 5`, the count is 601 not 600, and the constant is `SR_TRIG_LEN`
rather than `SR_TRIG` — and it was wrong in the way this branch has been repeatedly
burned: a plausible derivation, internally consistent, sitting next to a formula it
did not come from. The testbench pins **601** as an equality, and a 600-clock
derivation would have passed every datasheet window while failing the act's own
claim.

## The conversion is the act, and "exact" means two different things

The plan budgeted a 16×16 multiply. The identity removes it:

```text
us = 64q + r
us * 11 / 64  =  11q + 11r/64  =  11q + floor(11r/64)
```

**exactly, because `11q` is an integer.** So the conversion is a multiply by eleven
of a ten-bit number, a multiply by eleven of a six-bit number, and one add — no
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

### The three senses of "exact", and which is which

An earlier revision of this page used the word *exact* for two different claims at
once, which is a real ambiguity and not a stylistic one. The four measured runs
disambiguate it completely:

| run | echo | `us × 11/64` | answer | which "exact" applies |
|---|---|---|---|---|
| 0 | 1 160 µs | 199.375 | **199 mm** | the product is exact; **199 is its truncation** |
| 1 | 5 816 µs | 999.4375 | **999 mm** | same — and this is the case that used to fail |
| 2 | 2 000 µs | 343.75 | **343 mm** | same |
| 3 | 8 000 µs | **1375 exactly** | **1375 mm** | **no truncation at all** — `8000 = 64 × 125`, so `r = 0` |

So there are three claims, and only the last is unambiguous:

1. **The identity is exact.** `us*11/64 = 11q + floor(11r/64)` introduces no rounding
   error at all. This is a statement about the *algorithm*, and it is the one the
   firmware's own header makes.
2. **The arithmetic is exact, and the answer is truncated.** `1160 × 11/64 = 199.375`
   is exact; `199` is `floor` of it. "PASS, an equality" is therefore exact *against a
   truncating expectation* — and the testbench's `expected 199` **is** that
   truncation, so the two agree by construction rather than by luck.
3. **Run 3 has no truncation.** `8000 = 64 × 125` makes `r = 0`, so `floor` is the
   identity and `1375` is the whole product. This is the one input where "exact" means
   exact with nothing left over, and it is why four targets are better than two: the
   set now contains a case that distinguishes the two senses by itself.

A page that said only "the conversion is exact" was making claim 1 and being read as
claim 2. That is the defect the ambiguity was.

### `11/64` is +0.22 % long, and that error belongs to the constant

```text
t (µs) = 2 × d (mm) / 0.343 mm/µs   →   d (mm) = t × 11/64 = t × 0.171875
```

The constant is long by 0.22 % against the speed of sound. That is a property of a
number somebody chose, not of the arithmetic, and it is stated rather than absorbed:
the firmware is **exact for 11/64**, which is a different and checkable claim from
"the ranging is right to two parts in a thousand". Only the first can be asserted as
an equality, and the testbench asserts the first.

### No 16-bit overflow is possible anywhere

The largest value involved is `11 × (23000 >> 6) = 3949`; the intermediates are
`8q = 2872` and `10q = 3590`, and the second term is `11 × 63 = 693`. Recorded rather
than assumed, because an unnoticed overflow in the high byte is invisible from the
outside — the answer would still be a plausible millimetre figure.

## The image is 387 words of 1024, and that is correct

```text
image: 387 words loaded from firmware/sr04_range.hex (637 NOP-filled)
```

**The cause, because "387 words vs 1024 requested" reads as a defect and is not one:**

- the instruction memory is 1 024 words (`IMEM_WORDS` in the testbench, `pe_soc.v`);
- `tools/fw/peasm.py` pads the image to the requested width with `0xF000`, which is
  **NOP**, and says so in the generated file's own comment;
- `$readmemh` into `[0:1023]` from a 387-word file leaves 637 words unwritten and
  reports it as a *warning*, so the count is now taken from the file's own length and
  `$readmemh` is asked for exactly that many words — the array is pre-filled with
  `16'hF000` first;
- the firmware **parks** at `halt: JMP halt`, so the fill is never executed.

So the fill is a no-op region behind a program that never returns there. The
earlier symptom-only narration — an image that looked short — was a consequence of
the testbench asking `$readmemh` for more words than the file held; the length is now
counted, which is why the number is printed rather than inferred from a warning.

## The echo is captured, not sampled

The 1 µs counter is **reset at the echo's rising edge and read at its falling edge**,
so the answer is whatever accumulated. There is no 16-bit subtract: this machine has
no carry flag, so a 16-bit subtract is a four-case analysis on bit 7 and a *compare*
is the same analysis again. One reset removes both — the same design the
[[protocol-freqmeter]] act arrived at independently, and for the same reason.

The counter is read as a **difference** rather than through its clear-on-read flag,
again as in [[protocol-freqmeter]]: the flag is one bit, so a poll loop longer than a
tick reports several ticks as one, and the loss is invisible in the result. Port 7 is
the 4.33 µs UART half-bit tick and is not a microsecond.

## How the testbench proves it

Each run arms the model for one distance, releases the core, and checks that the
firmware's answer matches the model's expectation — four times, over four distances
chosen to span the interesting cases: 1 160 µs is a small target, 5 816 µs exercises
the ten-bit path and the high byte, and 8 000 µs is the one where the conversion's
truncation is a no-op.

## The mutation coverage that pins the testbench

**There is none, and that is a real gap rather than an omission in the writing.**
`regress/mutate_timing_tb.sh` carries 60 cases across the timing family and **none of
them are `sr04`**; the other six acts in the family are each pinned by several. The act
is wired into `run_all.sh` and green, so it runs every night — but a suite that no
mutant perturbs cannot distinguish "the testbench would notice" from "nothing ever
tries to break this one".

That is exactly the class this branch has been closing all along: a green gate proves
the checks pass, not that they *can* fail. The identity here is strong enough to be
worth pinning — a mutation that broke the `r = 0` case at 8 000 µs, or turned the
`+ 5` in the trigger derivation back into a `+ 4`, would be caught only because a
testbench pins 601 as an equality. Routed rather than written: `regress/` is not this
branch's surface.

## Limits, stated rather than implied

- **No acoustic model.** There is no propagation delay, no reflection, no target
  angle and no noise: the "sensor" presents an echo of a width the testbench chooses.
  The act measures a *counter*, and the `0.343 mm/µs` constant is a property of air
  that this simulation does not model at all.
- **The 40 kHz bursts are not used.** The firmware cannot resynchronise to a burst it
  did not send, so it ignores them; a real ranging front end sometimes uses them for
  exactly that.
- **The 11/64 constant is 0.22 % long.** The arithmetic is exact *for that constant*;
  the ranging inherits the constant's error, and the two claims are kept apart above
  rather than merged into one word.
- **No mutation coverage.** Stated above, with what it would have pinned.

## What changed, and why this page says so

An earlier revision of this page reported the act as **red**: five failing checks, a
second measurement that never ran, and an answer of `X` for an unwritten byte. That
was accurate when written — it was measured, not assumed — and the reason is worth
recording rather than deleting:

- the testbench's failing message printed `600 clocks` as `10000.000 us`, a **factor of
  1000** error, and this page quoted it verbatim with a `SIC` marker;
- `tools/diag/delay_lattice.py` then carried a `SIC` **exemption** justified by that
  quotation, in the same way it exempts a line it is asked to recompute.

Both have moved together, because they have to. The marker is a *self-limiting*
exemption by construction — a marker on a conversion that now recomputes **correctly**
is itself reported as a finding, and a marker on a line with no conversion is reported
as noise — so the moment the quoted defect was fixed upstream, the marker's
justification expired with it. Leaving a marker outliving the defect it marked would
have switched off a real check on a line that had become correct.

The unit error itself was fixed upstream in `tb/tb_pe_soc_sr04.v` (f7ac41b), which
added `CLK_US = CLK_NS / 1000.0`; the act then went green.

## See also

- [[protocol-freqmeter]] — the sibling act that also reads the 1 µs counter as a
  difference, and for the same reason
- [[protocol-ws2812]] — the act whose equalised-branch discipline the old
  600-vs-601 trigger error is the same shape as
- [[physical-layer-gpio]] — the pads, and why `ECHO` is released and read rather than driven
- [[tx-timing-generation]] — why a counted delay is a count of instructions and not a
  number of microseconds
