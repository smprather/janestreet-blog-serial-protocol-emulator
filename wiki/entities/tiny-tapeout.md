---
title: Tiny Tapeout
created: 2026-09-17
updated: 2026-09-17
type: entity
tags: [process-node, constraint, area-budget, clocking]
sources: [raw/articles/janestreet-protocol-emulator-competition.md, raw/articles/tinytapeout-clock-spec.md, raw/articles/tinytapeout-multiplexer.md, raw/articles/ttihp0p2-loopback-skew-project.md, raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: medium
---

# Tiny Tapeout

Shared-shuttle tapeout platform; this competition targets its IHP 130 nm CMOS5L (sg13g2) flow, LibreLane + Yosys/OpenROAD, starting from the CMOS5L Verilog template (RTL to GDS). IHP PDK support was SwissChips-funded; ttihp0p2 silicon was BMBF-funded.

## What constrains this design

- **Tile allocation 6x4 = 24 tiles** (set in `info.yaml`), per the blog's "Set the tile size in info.yaml to 6x4" and "The current maximum area is 6x4 tiles per design". 8x4 (~30% more) is described as a possibility being worked on, to be announced by a page update and an email to sign-ups — so it is headroom, not the budget. Corrected 2026-09-20 from a wrong 8x4; see [[raw/articles/janestreet-competition-blog-fulltext]]. The mux supports designs up to 16 tiles each, 512 designs per chip. See [[concepts/competition-overview]].
- **Shape, not just tile count.** TT notation is WIDTH x HEIGHT. At the template tile, 6x4 is 1002x432 um (2.32:1). The same 24 tiles as 4x6 would be 668x648 (near square) and would lose every 64-bit-wide SRAM macro, which are 784 um wide. See [[reference/sram-budget]].
- Tile size discrepancy: blog says ~200x150 um/tile; the ttihp-verilog-template `info.yaml` says a single tile is ~167x108 um. Use the template figure for layout math, the blog's ~1K cells/tile for budget math, and re-check after first synthesis.
- Custom GDS macros allowed if DRC/LVS-clean, grid-aligned, with LEF/LIB — relevant to the [[concepts/clock-doubler]] full-custom fallback.
- SRAM examples exist on this node for area-efficient instruction memory.

## Clock ceiling (headline finding)

- Official clock spec: max input frequency ~66 MHz, set by the IO pad macro; demo board generates 1 Hz-66.5 MHz from an RP2040 (PWM/PIO); newer demo PCBs use an RP2350. Expect up to ~10 ns pad-to-project insertion delay.
- Consequence: external 80 MHz is off the table; **dual-edge at the core clock is the plan** (8.33 ns grid at 60 MHz — see [[comparisons/clocking-options]] and [[decisions/adr-005-60mhz-turbo]]). The "dual-edge 40 MHz" figures elsewhere on this page date from when 40 MHz was the operating point.
- The transcript's "~50-60 MHz mux limit" was directionally right but misattributed: the mux passes clk through a buffer like any other bus bit; the limit is pad macro + board generator, not the mux.

## Mux behavior (tt-multiplexer INFO.md)

- The active design receives clk, rst_n, ui_in, uio_in through a buffer; ALL inactive designs get zeros on those lines and their outputs are tristated off the spine.
- clk/rst_n are plain bits of the pad bus — no dedicated clock tree, no balanced insertion. Duty-cycle and skew budgets must assume a plain routed net.

## Silicon precedent for skew work

- TT05 project 132 / ttihp0p2 project 619 (`tt_um_dlmiles_loopback`): loopback tile measuring input skew / FF capture reliability with an external skewable clock+data source (10 MHz). Direct precedent for [[concepts/gpio-signoff-corners]].

## Open questions (ask TT Discord / asic-competition@janestreet.com)

1. IHP/sg13g2-specific max input clock (66 MHz figure is sky130 pad-macro-based)?
2. Which demo board + generator limits apply to the March 2027 CMOS5L shuttle (RP2040 vs RP2350, 66.5 MHz cap)?
3. IHP pad insertion delay figure (10 ns is the sky130 number)?
