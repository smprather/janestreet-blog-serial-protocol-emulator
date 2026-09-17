---
source_url: https://tinytapeout.com/runs/ttihp0p2/tt_um_dlmiles_loopback
ingested: 2026-09-17
sha256: 70bcf425dc48ead3c439cd0d627fd37833ee6eeb9f0de0921c3c1bf72d638de3
---

# Project 619: IHP loopback tile with input skew measurement (ttihp0p2)

- Author: Darryl Miles, ported from Eric Smith's sky130 original (ericsmi/tt05-loopback-with-skew, TT05 project 132).
- Declared clock: 10 MHz.
- Method: clock the project while sweeping timing from external hardware ("skewable clock and data source") and examine flip-flop capture reliability (compare-bit inputs vs second-counter loopback, results on 7-seg outputs).
- Status: thin documentation ("How it works" is one line pointing at the original; "How to test: clock the project and modify the timing and examine FF capture reliability"), but it establishes precedent that input skew / FF capture margin is measured on the Tiny Tapeout platform itself with external delay hardware — the same empirical approach as the gpio-signoff-corners SPICE-to-SDC loop, closed in silicon.
