---
title: GPIO Signoff Corners
created: 2026-09-17
updated: 2026-09-17
type: concept
tags: [signoff, sta, spice, gpio, pvt]
sources: [raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: medium
---

# GPIO Signoff Corners

Internal logic signs off at SS/FF, but the pad ring needs FS (fast-N/slow-P) and SF (slow-N/fast-P): unequal pull-up/pull-down strength skews tplh vs tphl, causing duty-cycle distortion that thins 50 ns half-bit pulses (e.g. 5 ns imbalance turns 50 ns into 45 ns before board capacitance adds more). The 8x CDR in [[concepts/cdr-oversampling]] absorbs this by re-syncing phase on every edge, but the margin must be quantified, not assumed.

## Signoff loop

1. ngspice the sg13g2 GPIO buffer across FF/SS/FS/SF driving a realistic PCB load (15-30 pF + pin inductance) with a 10 Mbps Manchester train; also capture input-threshold skew on receive.
2. Extract worst-case thinning: dt_skew = max|tplh(corner) - tphl(corner)|.
3. Inject into OpenROAD SDC without custom multi-corner IO libs:
   - asymmetric `set_input_delay -rise/-fall` (and output equivalents) on the RX/TX GPIOs, or
   - `set_input_transition -rise/-fall` plus `set_clock_uncertainty -setup dt_skew` as a guardband.
4. Budget check at 80 MHz: 50 ns nominal = 4.0 ticks; 4.2 ns thinning leaves ~45.8 ns = 3.66 ticks, still >8 ns margin around a center strobe.

This SPICE-to-SDC loop doubles as a verification-methodology artifact for [[concepts/competition-overview]] judging.

## Measured precedent on Tiny Tapeout silicon

TT05 project 132 and its IHP port (ttihp0p2 project 619, `tt_um_dlmiles_loopback`) are loopback tiles built exactly for this: an external skewable clock+data source sweeps timing while on-chip flip-flop capture reliability is observed (10 MHz declared clock). Docs are thin, but the methodology is validated on the platform — our signoff loop can be closed the same way in silicon after tapeout, and the loopback RTL is a reference for the test harness.
