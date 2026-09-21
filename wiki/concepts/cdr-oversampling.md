---
title: CDR Oversampling Design
created: 2026-09-17
updated: 2026-09-20
type: concept
tags: [cdr, oversampling, protocol, clocking]
sources: [raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: high
---

# CDR Oversampling Design

10BASE-T is 10 Mbps Manchester: a mid-bit transition every 100 ns bit period, so the
shortest pulse is the 50 ns half-bit cell. A 12x oversampling digital data-recovery
unit (60 MHz sample clock, 16.67 ns sample period, 8.33 ns per sample at SPB = 12)
decodes it with margin to spare. Terminology: "12x" here means 12 samples per 100 ns
bit period, i.e. 6 samples per 50 ns minimum UI. True 8-samples-per-minimum-UI would
need 160 MHz (16x the bit rate) — beyond the ~66 MHz platform ceiling (see
[[entities/tiny-tapeout]]) — so 6 samples per minimum UI is the design point. No DLL,
PLL, or analog CDR needed — this collapses the classic multiphase "phase picker" CDR
(cf. 480 Mbps USB2 designs) into a single-clock 4-bit phase counter because 60 MHz is
directly clockable in this node.

Note on the "x" convention, since the name ADR-001 is still 8x: the DRU captures TWO
samples per bit period per core clock (ADR-002's latch-pair DDR front end doubles the
effective grid), so a 60 MHz core gives a 12-sample-per-bit grid. ADR-005 raised the
core to 60 MHz and the grid from 8 to 12 samples/bit.

**IMPLEMENTED as `rtl/pe_dru.v`** (2026-09-20): **116 cells / 2,065 µm² mapped**
(`tb/synth_area.sh`), against the ~50-100 cell estimate below. Verified by
`tb/tb_pe_dru` and `tb/tb_pe_dru` is registered in `tb/run_all.sh`.

## DRU structure, as built

The spec below was written before the RTL and one item turned out to be unnecessary.
Both are recorded, because "we did not need the thing we thought we needed" is a
finding:

1. 2-flop synchronizer on the RX pin at the sample clock (metastability). Required —
   this is the one place in the design where metastability would actually be sampled.
2. Edge detector + phase counter, reset on **every** transition (rising and falling).
   The counter is free-running (wraps at SPB) when no edge arrives, which is what lets
   a frame be acquired without an explicit start condition.
3. ~~Preamble lock: 56-bit alternating preamble + SFD aligns the sample window to
   mid-half-cell.~~ **NOT NEEDED, and this is the design's main simplification.**
   See "Why the preamble is not needed" below.
4. Strobe data near the eye centre; ignore boundary edges. **Implemented, but not as
   an exception:** boundary edges need no special handling because the counter
   re-aligns on them (see below).
5. Majority-vote / debounce filtering: implemented as an optional 3-tap majority
   (`cfg_filter_en`), off by default. See the filter trap below.

### The sampling grid

`phase <= edge ? 0 : phase + 1` (mod SPB), so `phase` is a sample's distance from the
last transition. Captures at phase SPB/4 and 3·SPB/4 are exactly the half-cell
centres, for every possible transition pattern:

- A half-cell begins at a transition (phase 0) or at a boundary with no transition
  (phase 0 of the free-running counter, SPB/2 after the last edge). Its centre is
  SPB/4 samples later — phase SPB/4 in one case and phase 3·SPB/4 in the other.
- So "capture at SPB/4 and 3·SPB/4" (2 and 6 at SPB=8; 3 and 9 at SPB=12) covers
  both, with no boundary-edge exception logic. A grid that is right for 0101 and
  wrong for 0011 would be a real failure, so `tb_pe_dru` tests all four 2-bit
  patterns exhaustively plus runs, a preamble frame and a soak.

### Why the preamble is not needed

A Manchester cell **always** contains a mid-bit transition (H→L is a 0, L→H is a 1)
and the two halves of a cell always **differ**. Therefore an *absent* transition at a
half-cell boundary can only mean that boundary is a bit boundary — so a phase-3·SPB/4
capture is **always** the first half of a bit cell. That single fact is the framing,
and it needs no preamble, no SFD, and no edge classification.

The **first** captured cell after acquisition is a genuine exception: its F/S parity
cannot be known until a transition seeds it, so it may be mislabelled. This is a
property of every Manchester receiver and is precisely why IEEE 802.3 defines a
56-bit preamble and treats it as the part consumed during acquisition. Firmware (or
the frame layer) discards the preamble; the DRU does not need to understand it.

### `locked` is a confidence indicator, not a gate

A cell is well-formed when its two halves differ — one comparator. `locked` asserts
after `cfg_lock_bits` such cells and clears on the first malformed one (an idle line
produces equal-half cells, which is what "nothing is there" looks like). `bit_en` is
emitted whether or not locked: a consumer that gates on it drops the preamble, and
the preamble is the part every protocol here expects to be dropped.

## The filter trap (measured, not theorised)

A 3-tap majority is **not** a transparent delay. At a level change its output moves one
sample later than the centre tap (two agreeing taps are needed to flip). Feeding that
directly into the edge detector shifted every edge by one sample — and since the phase
counter resets on the *detected* edge, every capture moved with it, putting the
phase-3·SPB/4 capture 3 samples past a half-cell boundary instead of 2, i.e. inside the
**next** half-cell. The result is wrong data on one bit pattern out of four.

Fix: resample the majority output before it drives the counter. The filter then
removes glitches and cannot move an edge, so `cfg_filter_en` needs no separate timing
re-qualification. `tb_pe_dru` asserts both halves of that claim (glitch swallowed;
filtered and unfiltered captures of the same pattern identical).

**A test that only asks "does the filter remove the glitch" passes in both versions.**
The defect only appears as wrong data on a pattern the glitch test does not use.

## Why 4x is rejected

4x (40 MHz, 25 ns resolution, 2 samples per half-bit) is the theoretical minimum but
has ~+/-6 ns jitter tolerance vs ~+/-18.75 ns at 8x, minimal glitch rejection (one
noise sample corrupts a cell), slower preamble lock, and no margin for IEEE 802.3
+/-100 ppm drift over a 1518-byte frame. Recorded in [[decisions/adr-001-8x-oversampling]].
At 4x the capture phase would sit one sample from a cell edge, and the filter trap
above would be a hard failure rather than a fixable one — that is a concrete
consequence of this decision, not a restatement of it.

## Getting the 80 MHz-equivalent clock

Options compared in [[comparisons/clocking-options]]: external 80 MHz board clock,
dual-edge 40 MHz sampling (same 12.5 ns resolution, STA-friendly, zero PVT risk), or
an internal XOR delay-line doubler per [[concepts/clock-doubler]]. The DRU logic is
identical in all three cases — it is single-edge and counts samples, so whatever
delivers the 12.5 ns grid is invisible to it. `SPB` is a parameter for exactly that
reason; a 66 MHz turbo mode gives ~6.6 samples per half-UI and only needs the
parameter changed.

## Related

- [[decisions/adr-001-8x-oversampling]] — the 8x decision and why 4x was rejected.
- [[decisions/adr-002-latch-pair-det-flop]] — the DDR capture flop this block is fed by.
- [[comparisons/clocking-options]] — how the 12.5 ns grid is generated.
- [[concepts/ethernet-scope]] — why 10BASE-T receive has to be hardware at all.
- [[reference/signal-names]] — the `pe_dru` port table.
- [[STATUS]] — what is built and verified.
