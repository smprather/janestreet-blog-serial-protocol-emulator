---
title: Clock Doubler
created: 2026-09-17
updated: 2026-09-17
type: concept
tags: [clocking, pvt, sta, process-node]
sources: [raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: medium
---

# Clock Doubler

Fallback if the board/mux cannot deliver a clean external 80 MHz clock (unverified transcript claim — confirm against [[entities/tiny-tapeout]] docs): generate 80 MHz inside the tile from a 40 MHz reference with an XOR edge-detector (one XOR input direct, other through an odd-count inverter/buffer delay chain; each reference edge emits a pulse whose width equals the chain delay).

## Risks in standard-cell form

- Duty-cycle asymmetry: pulse width = chain delay, which drifts with PVT; downstream flops can violate min pulse width.
- PVT spread (~2x delay FF-fast to SS-slow) on plain CMOS chains.
- STA tooling: Yosys/OpenROAD see an unconstrained generated clock; needs `create_generated_clock`, `set_dont_touch` / `(* keep *)` so the chain is not optimized away, plus CRPR enabled for the reconvergent paths.

## Mitigations

- Standard cells + hardened local PDN (preferred first try): dense decap cells around the chain and XOR, upper-metal power straps with via stacks to M1 rails, keep the synchronizer-to-counter path to 4-6 logic levels, use _2/_4 drive strengths. Local VDD sag of ~2-3% removes most transient skew.
- No library recharacterization: instead tighten STA OCV derates on the doubler instances only (e.g. 1-2% vs default 5-10%) and verify min/max pulse width at the slow/low-voltage corner.
- Full custom (if standard cells fail): long-channel symmetric delay stages, explicit MOS/MIM loading caps, current-starved chain with a threshold-tracking bias generator, symmetric transmission-gate XOR. More robust across corners but costs DRC/LVS/LEF/LIB work.
- Cleaner alternative avoiding the doubler entirely: dual-edge 40 MHz sampling — see [[comparisons/clocking-options]] and [[concepts/cdr-oversampling]].
