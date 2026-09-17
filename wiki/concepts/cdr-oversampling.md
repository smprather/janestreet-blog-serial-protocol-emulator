---
title: CDR Oversampling Design
created: 2026-09-17
updated: 2026-09-17
type: concept
tags: [cdr, oversampling, protocol, clocking]
sources: [raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: high
---

# CDR Oversampling Design

10BASE-T is 10 Mbps Manchester: a mid-bit transition every 100 ns bit period, so the shortest pulse is the 50 ns half-bit cell. An 8x oversampling digital data-recovery unit (80 MHz sample clock, 12.5 ns resolution) decodes it with margin to spare. Terminology: "8x" here means 8 samples per 100 ns bit period, i.e. 4 samples per 50 ns minimum UI. True 8-samples-per-minimum-UI would need 160 MHz (16x the bit rate) — beyond the ~66 MHz platform ceiling (see [[entities/tiny-tapeout]]) — so 4 samples per minimum UI is the design point. No DLL, PLL, or analog CDR needed — this collapses the classic multiphase "phase picker" CDR (cf. 480 Mbps USB2 designs) into a single-clock 3-bit phase counter because 80 MHz is directly clockable in this node.

## DRU structure (~50-100 cells)

1. 2-flop synchronizer on the RX pin at the sample clock (metastability).
2. Edge detector + 3-bit modulo-8 phase counter; every transition (rising and falling) re-aligns the counter to phase 0.
3. Preamble lock: 56-bit alternating preamble + SFD aligns the sample window to mid-half-bit-cell.
4. Strobe data near phase 4 (eye center); ignore boundary edges (~8 ticks from mid-bit). Majority-vote / debounce filtering optional.

Manchester guarantees a transition every bit, so unlike USB2 NRZI there is no bit-stuffing or long run-length phase drift to track.

## Why 4x is rejected

4x (40 MHz, 25 ns resolution, 2 samples per half-bit) is the theoretical minimum but has ~+/-6 ns jitter tolerance vs ~+/-18.75 ns at 8x, minimal glitch rejection (one noise sample corrupts a cell), slower preamble lock, and no margin for IEEE 802.3 +/-100 ppm drift over a 1518-byte frame. Recorded in [[decisions/adr-001-8x-oversampling]].

## Getting the 80 MHz-equivalent clock

Options compared in [[comparisons/clocking-options]]: external 80 MHz board clock, dual-edge 40 MHz sampling (same 12.5 ns resolution, STA-friendly, zero PVT risk), or an internal XOR delay-line doubler per [[concepts/clock-doubler]]. The DRU logic is identical in all three cases.
