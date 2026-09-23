---
title: "ADR-002: Latch-Pair Dual-Edge Flop"
created: 2026-09-17
updated: 2026-09-17
type: decision
tags: [decision, clocking, architecture]
sources: []
confidence: high
---

# ADR-002: Latch-Pair Dual-Edge Flop

- Status: accepted
- Date: 2026-09-17

## Context

Dual-edge sampling needs a flop that captures on both clock edges (see [[comparisons/clocking-options]]). Verified in `sg13g2_stdcell_typ_1p20V_25C.lib`: all flops (dfr/sdfr families) are rising-edge only — no negedge flops. Both latch polarities exist (dlh*, dll*).

## Decision

Build the DDR capture flop from standard cells: transparent-high latch + transparent-low latch in parallel with an output mux on clock level. Pure stdcell, fully characterized, STA-clean.

## Rejected

- Flop-on-inverted-clock: workable but adds inverter skew between the two sample grids and a generated-clock constraint; latch-pair keeps one clock net.
- Full-custom static DET: saves area/power, costs LEF/LIB char + DRC/LVS — not worth it at 66 MHz.
- Full-custom dynamic DET: same costs plus leakage/charge-share/noise signoff. Most fun, least justified.

## Consequences

- SERDES/DRU capture path uses the latch-pair cell; the current 60 MHz operating point gives 8.33 ns per half-cycle (ADR-005).
- Board-clock duty error still lands as uneven sample spacing; absorbed by per-edge phase re-sync per [[concepts/cdr-oversampling]].
