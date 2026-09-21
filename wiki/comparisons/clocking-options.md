---
title: Clocking Options for 8x Oversampling
created: 2026-09-17
updated: 2026-09-17
type: comparison
tags: [clocking, oversampling, pvt, sta]
sources: [raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: medium
---

# Clocking Options for 8x Oversampling

Goal: 12.5 ns sample resolution for the [[concepts/cdr-oversampling]] DRU. Four ways to get there. (A 6.25 ns grid — 160 MHz, true 8-samples-per-minimum-UI — was considered and rejected: nothing on this platform can deliver or synthesize it. See [[entities/tiny-tapeout]] ceiling.)

| Option | How | Pros | Cons |
|---|---|---|---|
| External 80 MHz | Board delivers the sample clock | Simplest STA; single clock tree | LIKELY UNAVAILABLE: official spec caps input at ~66 MHz (sky130 pad-macro figure; IHP max unconfirmed — see [[entities/tiny-tapeout]]) |
| Dual-edge 40 MHz | Sample on both edges of 40 MHz | Same 12.5 ns resolution; STA-friendly; zero PVT risk; no extra cells | Requires ~50% external duty cycle. Construction: lib has NO negedge flops (all dfr/sdfr are rising-edge), so use flop-on-clk + flop-on-inverted-clk (generated-clock-invert constraint) or a latch-pair DET from dlh*+dll* cells — both pure stdcell, no custom DDR flop needed (custom DET not worth char effort at these speeds). |
| Internal XOR doubler, std cells | 40 MHz in, 80 MHz pulse train out ([[concepts/clock-doubler]]) | Keeps single-edge RTL; automated flow intact | PVT-sensitive pulse width; needs PDN hardening + derate tuning + generated-clock constraints |
| Full-custom doubler | Current-starved delay line, custom XOR | Flat pulse width across corners | DRC/LVS/LEF/LIB effort; black-box STA |

## Verdict

Try in order: dual-edge at the core clock (**the plan** — comfortably under the ~66 MHz platform ceiling; at the 60 MHz operating point this is an 8.33 ns grid, ADR-005), else std-cell doubler with hardened PDN and tightened derates. External 80 MHz is off the table unless the competition confirms a higher IHP clock limit. Full custom is the last resort. The DRU logic is unchanged in all four cases, so the choice does not ripple into [[concepts/factored-hardware-blocks]].

Note: this page was written when 40 MHz was the intended core clock, so the
"dual-edge 40 MHz" rows quote a 12.5 ns grid. The mechanism is identical and the
table is kept as the decision record; only the clock it is applied to changed
(ADR-005, 60 MHz -> 8.33 ns). The conclusion — dual-edge beats a doubler — is
unchanged.
