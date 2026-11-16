---
title: Tiny Tapeout
created: 2026-09-17
updated: 2026-11-10
type: entity
tags: [process-node, constraint, area-budget, clocking]
sources: [raw/articles/janestreet-competition-blog-update-2026-11-09.md, raw/articles/janestreet-competition-blog-fulltext.md, raw/articles/tinytapeout-clock-spec.md, raw/articles/tinytapeout-multiplexer.md, raw/articles/ttihp0p2-loopback-skew-project.md]
confidence: medium
---

# Tiny Tapeout

Shared-shuttle tapeout platform; this competition targets its IHP 130 nm **SG13CMOS5L** flow, LibreLane + Yosys/OpenROAD, starting from the CMOS5L Verilog template (RTL to GDS). CMOS5L is the 5-metal stack (M1-M4-TopMetal1) and uses the `sg13cmos5l_stdcell` library; it is not the full SG13G2 BiCMOS PDK. IHP PDK support was SwissChips-funded; ttihp0p2 silicon was BMBF-funded.

## What constrains this design

- **Tile allocation 8x4 = 32 tiles** (set in `info.yaml`). The blog's 2026-11-09 update confirms 8x4 for the March 2027 CMOS5L shuttle and says Tiny Tapeout's tile sizes are final; the `ttihp-verilog-template` main branch now targets CMOS5L (the `cmos5l` branch is retired) and lists 8x4. See [[raw/articles/janestreet-competition-blog-update-2026-11-09]]. The mux supports designs up to 16 tiles each, 512 designs per chip. See [[concepts/competition-overview]].
- **Shape, not just tile count.** TT notation is WIDTH x HEIGHT. At 202x155 um per tile, 8x4 is 1616x620 um (2.61:1, 1.002 mm2). The same 32 tiles as 4x8 would be 808x1240 (near square) and would lose the wide SRAM macro family. See [[reference/sram-budget]].
- **Tile size is 202x155 um** in both the blog's 2026-11-09 update and the template's main branch; the old 167x108 um figure is retired. Use 202x155 for layout math and the blog's ~1K cells/tile for budget math.
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

1. IHP/CMOS5L-specific max input clock (66 MHz figure is sky130 pad-macro-based)?
2. Which demo board + generator limits apply to the March 2027 CMOS5L shuttle (RP2040 vs RP2350, 66.5 MHz cap)?
3. IHP pad insertion delay figure (10 ns is the sky130 number)?
