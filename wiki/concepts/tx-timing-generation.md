---
title: TX Timing Generation (No PLL)
created: 2026-09-18
updated: 2026-09-18
type: concept
tags: [clocking, architecture, protocol, decision]
sources: [raw/articles/tinytapeout-clock-spec.md, raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: high
---

# TX Timing Generation (No PLL)

Binding TX constraint across all targets: the 50 ns half-UI of 10BASE-T Manchester. (SPI half-SCLK ties it only if we choose 10 MHz SCK — that rate is ours to pick.) Everything else is >=100 ns.

## The 40 MHz plan (default)

The ~66 MHz figure is the platform's pad ceiling ([[entities/tiny-tapeout]]), NOT our operating point: the demo-board clock is programmable 1 Hz-66.5 MHz. Set it to 40 MHz:

- TX (single-edge, no DDR needed): 50 ns = exactly 2 ticks, 100 ns = exactly 4. Spec-exact Manchester edges, 10 MHz SCK, binary-rate SWD/JTAG. No fractional anything.
- RX (DDR per [[decisions/adr-002-latch-pair-det-flop]]): 40 MHz dual-edge = 12.5 ns grid = exactly 4 samples per 50 ns half-UI — the ADR-001 8-samples-per-bit design point, integer.
- USB-LS (1.5 Mbps): 666.67 ns = 53.33 ticks -> NCO bit-strobe alternating 53/53/54. Quantization ±6.25 ns on a 666 ns bit (<1%) — far inside USB-LS tolerance. The same 4-bit NCO pattern serves UART/CAN/PS2 baud generation.

## Forced-66 MHz fallback (if a higher core clock is ever wanted)

50 ns = 6.6 ticks -> fractional-N NCO in the DDR domain (7.58 ns tick, 6/7 alternation):
- TX edge quantization ±3.8 ns = 7.6% of half-UI — eats 10BASE-T TX jitter budget.
- RX DRU inherits an uneven sample grid (mod-33 across 5 half-UIs); Manchester's guaranteed per-bit transitions let the phase counter re-sync continuously, so it closes, but it is strictly worse than exact-integer 40 MHz.
- USB-LS is exact at 66 MHz (44.0 ticks) — the one protocol that prefers 66.

## Verdict

One programmable 40 MHz board clock; DDR capture for RX only; integer timing for every hard protocol; tiny NCO for the slow fractional ones. No PLL, no DLL, no on-die multiplication anywhere. See [[comparisons/clocking-options]] and [[concepts/cdr-oversampling]].

## Post-fabrication protocol ceiling (the Jane Street "arbitrary protocol" question)

Pulse width sets the SPEED floor: capture needs >=1 grid tick (12.5 ns plan grid / 15.15 ns if 66 MHz single-edge), robust sampling >=2. Run length sets the PROTOCOL-CLASS ceiling for async protocols: (longest transition-free run) x (combined clock tolerance) must stay under 0.5 UI.

- Source-synchronous (clock on wire): unlimited rates, pure firmware, no tracking constraint.
- Async + regular transitions: bounded by tolerance class — 10BASE-T-class (+-100 ppm) tolerates 2500 UI runs; CAN-class (+-0.5%) 100 UI; UART-class (+-4%) only 12.5 UI; typical RC-osc (+-2%) 25 UI.
- Async + long runs + sloppy clocks (e.g. 30-bit preamble from a +-2% RC device): NOT DRU-coverable; falls back to firmware polling at core speed — same wall every PIO/PRU-class machine (RP2040 included) hits.
