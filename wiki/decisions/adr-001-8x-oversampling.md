---
title: "ADR-001: 8x Oversampling for 10BASE-T Receive"
created: 2026-09-17
updated: 2026-09-17
type: decision
tags: [decision, oversampling, cdr, clocking]
sources: [raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: high
---

# ADR-001: 8x Oversampling for 10BASE-T Receive

- Status: accepted
- Date: 2026-09-17

## Context

10BASE-T receive needs Manchester decode of 50 ns half-bit cells (see [[concepts/cdr-oversampling]]). Prior USB2 CDR experience used 8x oversampling via a multiphase PLL phase picker; the question was whether 4x suffices here or a DLL is required.

## Decision

Target 8x oversampling relative to the 10 Mbps bit rate (12.5 ns resolution, 4 samples per 50 ns minimum half-bit UI). No DLL/PLL; a synchronous digital DRU (edge-triggered 3-bit phase counter, preamble lock, center strobe) suffices. 4x is rejected: ~+/-6 ns jitter tolerance, single-sample glitch vulnerability, slow preamble lock, no drift margin.

## Consequences

- Need an 80 MHz-equivalent sample clock: see [[comparisons/clocking-options]] for the ordered fallback chain.
- GPIO pulse thinning at FS/SF corners must be budgeted in SDC: see [[concepts/gpio-signoff-corners]].
- DRU cost is ~50-100 cells; fits easily in the [[concepts/competition-overview]] area budget.
