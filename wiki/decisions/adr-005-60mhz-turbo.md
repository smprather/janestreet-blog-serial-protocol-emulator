---
title: "ADR-005: 60 MHz Turbo, Not 66"
created: 2026-09-21
updated: 2026-09-21
type: decision
tags: [decision, clocking, protocol, verification]
sources: [raw/articles/tinytapeout-clock-spec.md, https://iol.unh.edu/sites/default/files/testsuites/ethernet/CL14_MAU/MAU_Test_Suite_v5.4.pdf]
confidence: high
---

# ADR-005: 60 MHz Turbo, Not 66

- Status: accepted
- Date: 2026-09-21

## Context

[[concepts/tx-timing-generation]] named a "forced-66 MHz fallback" and called
66 MHz a documented turbo worth "+65% core cycles", with the cost written as
"TX edge quantization ±3.8 ns = 7.6% of half-UI — eats 10BASE-T TX jitter
budget". Two things were wrong with that.

First, it treated the 10BASE-T transmit jitter requirement as a vague budget to
be nibbled rather than a **conformance test with a stated tolerance**. Second, it
never checked whether the 66 MHz grid could satisfy that test at all, or whether
another clock could.

The requirement (IEEE 802.3 §14.3.1.2.3, as implemented by the UNH 10BASE-T MAU
conformance suite tests 14.1.10/14.1.11): after a triggering zero crossing, the
next crossings must occur at **8.0 BT ±11 ns and 8.5 BT ±11 ns** with the
twisted-pair model (±20 ns without). 1 BT = 100 ns, so the two spans are 800 ns
(16 half-UIs) and 850 ns (17 half-UIs).

## Decision

**The operating point is 60 MHz, not 40 and not 66.** `f = 20n MHz` makes both
the 50 ns half-UI and the 100 ns bit exact integers. Under the demo board's
66.5 MHz ceiling that admits n = 1 (20), n = 2 (40), and **n = 3 (60)**. 60 MHz
is generated exactly by the demo board (RP2040 120 MHz / even divisor 2), and it
is exact for every hard protocol at once.

The repo was switched over on 2026-09-21: `CLK_HZ` defaults to 60 MHz in
`pe_uart_soc` and the TT top level, `pe_dru`'s default grid is SPB = 12,
`info.yaml` declares 60000000 and the emulator/assembler tick tables follow.
The switch required **no RTL restructuring and no firmware edit** — only
parameters, comments, and the derived tick arithmetic.

## Why 66 MHz is not merely worse — it is impossible

A run of identical bits places a crossing on **every** half-UI, so the 16- and
17-half-UI spans are constrained simultaneously. With `d_k` the integer gap
between consecutive crossings:

```
span16(k) = sum(d_k .. d_(k+15))     must be within +/-11 ns of 800 ns
span17(k) = span16(k) + d_(k+16)     must be within +/-11 ns of 850 ns
```

At 66.0 MHz (T = 15.1515 ns) each window admits **exactly one** tick count:

| span | ideal ticks | only admissible | error |
|---|---|---|---|
| 800 ns | 52.80 | 53 | +3.03 ns |
| 850 ns | 56.10 | 56 | −1.52 ns |

Subtracting the two pins every gap to `d = 56 − 53 = 3`, so
`span16 = 16 × 3 = 48` ticks = 727 ns. The window demands 53 ticks = 803 ns.
**Contradiction, and it is not escapable by dithering**: the constraint is on the
sliding 16-span, so an instantaneous-edge argument cannot relax it.

At 66.5 MHz the window is `A16 = {53}`, `A17 = {56, 57}` — one extra admissible
17-span is exactly enough for a 16-periodic pattern of **5 gaps of 4 and 11 gaps
of 3**. So 66.5 works **only with a purpose-built dither generator**, buying
0.5 MHz over 60 MHz for that whole mechanism. Not worth it.

## Consequences

- **60 MHz is strictly better than 40 on every axis**, not just faster:
  every hard protocol stays exact, USB-LS becomes exact (40.000 ticks) instead of
  26.667, UART's quantization improves (+0.353% → +0.160%), and the receive grid
  refines by 50% (12.5 ns → 8.333 ns, SPB 8 → 12).
- **The switch is verified end to end, not argued.** `tb_pe_uart_soc` at
  `CLK_HZ = 60_000_000` passes with no RTL or firmware change, `tb_pe_dru` passes
  at SPB = 12, and the full regression is 21/21 RTL + 13/13 firmware with the
  drift gates and `tb/param_guards.sh` green.
- **The SRAM macro is now the tightest path in the design, and it is worth
  stating because it changes what the flow must check.** At the slow corner
  (1.08 V, 125 °C) the 1024x16 `_c2_bm_bist` macro's clock-to-output is
  **~7.25 ns** (measured from the shipped `.lib`: 7.25 ns slow / 4.34 ns typ /
  2.67 ns fast) — 29% of a 25 ns period at 40 MHz but **43% of a 16.667 ns period
  at 60 MHz**. The read path is `A_CLK → A_DOUT → CPU` with no wrapper register
  (deliberately: a register would add a second cycle and break the CPU's
  fetch-ahead). The pe_serdes STA signoff above does not cover it — that run
  has no SRAM. **The SoC needs its own STA run at 15.15 ns before tapeout**, and
  this is the number it must close against.
- **SPB 12 satisfies `pe_dru`'s constraints.** Verified by running the DRU
  testbench at SPB = 12: `PASS: tb_pe_dru`.
- **The `SPB % 4 == 0` guard was incomplete, and the gap was silent.** Checking
  the boundary (SPB 8/12/16 pass, 20+ fail) exposed a second constraint the RTL
  never stated: `phase` is 4 bits and the wrap constant is `4'(SPB - 1)`, which
  **truncates above 16**. At SPB=20 the counter wraps at phase 3 instead of 19,
  never reaches either capture phase, and the block emits *nothing* — no error,
  no output, no failing signal. `pe_dru` now raises an elaboration error for
  `SPB > 16`, and `tb/param_guards.sh` (wired into `run_all.sh`) requires both
  guards to actually reject and both boundaries (16, and the SPB=12 turbo grid)
  to actually compile, so a guard that stops firing fails the build.
- **66 MHz keeps exactly one role: a conservative STA signoff target.** Closing
  at 66 and running at 60 leaves ~10% of the period as free margin, and covers
  the "real IHP pads might top out below 66" hedge without re-signoff.
- The demo board's own default, 62.5 MHz = 125/2, is **not** 20n MHz and fails
  the same way 66 does. A turbo must be requested explicitly.
- 10BASE-T **receive** is unaffected either way: the DRU re-locks phase on every
  Manchester edge, so it tolerates an uneven grid — it just closes with more
  margin on an even one.

## Rejected

- **66 MHz as a turbo.** Provably fails the TX jitter conformance window at every
  edge placement, and breaks SPI's 10 MHz SCK integer relation. The prior page's
  "+65% core cycles" claim was written without solving the constraint.
- **66.5 MHz with a designed dither.** Feasible, but spends a bespoke pattern
  generator to gain 0.5 MHz over 60, which is already exact without one.
- **DDR on the core clock (the "effective 135 MHz" proposal, 2026-09-21).**
  Rejected on separate grounds recorded in the same session: it costs 1.52× area
  per storage bit (`dlhrq_1`+`dllrq_1`+`mux2_1` = 74.4 µm² vs `dfrbpq_1`
  48.99 µm²), the library has **no negative-edge flops to build it from** (all 14
  sequential cells declare `clocked_on: "CLK"`), and the existing logic already
  closes at 2.5 ns reg-to-reg against a 7.58 ns half-cycle — so DDR would re-price
  every storage element in the design to buy throughput the logic does not need.
  Raising the clock is strictly cheaper than adding a second edge.

## Related

- [[concepts/tx-timing-generation]] — the timing plan this amends.
- [[comparisons/clocking-options]] — the four ways to get a 12.5 ns grid.
- [[decisions/adr-001-8x-oversampling]] — the SPB = 8 design point; SPB = 12 extends it.
- [[concepts/cdr-oversampling]] — why an uneven RX grid is tolerable and an even one is better.
- [[entities/tiny-tapeout]] — the 1 Hz–66.5 MHz board generator and its 125 MHz default.
