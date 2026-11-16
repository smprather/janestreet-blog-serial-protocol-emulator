---
title: Competition Overview
created: 2026-09-17
updated: 2026-11-10
type: concept
tags: [competition, constraint, area-budget, process-node, verification]
sources: [raw/articles/janestreet-competition-blog-update-2026-11-09.md, raw/articles/janestreet-competition-blog-fulltext.md, raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: high
---

# Competition Overview
> **What you'll learn here:** what the competition actually asks for, and the tile, area and deadline constraints that follow from it
>
> **You can verify this by:** The constraints are enforced as gates, not prose: `bash regress/check_wiki_pages.sh` checks the wiki against [[SCHEMA]], and the area budget behind them is in [[reference/sram-budget]] and [[reference/floorplan-feasibility]]. The plan that executes the baseline scope is [[plans/through-i2c]].


Design an open-source, general-purpose protocol-emulator ASIC: a tiny CPU with an ISA for reading/writing pins, counting cycles, and hitting precise timing so protocols run in firmware, not fixed logic. Reprogrammability after fabrication (within timing/IO limits) is the point — not one UART block plus one SPI block plus one I2C block. Models: RP2040 PIO, TI Sitara PRU.

## Protocol targets

- Baseline: UART, SPI, I2C.
- Stretch: low-speed USB, 10Mbit Ethernet.
- Also suggested: JTAG, SWD, PS/2, CAN. Plus anything novel the architecture enables.
- See [[concepts/physical-layer-gpio]] for what each protocol needs electrically, and [[concepts/factored-hardware-blocks]] for the shared RTL primitives.

## Hard constraints (blog = primary source)

- Process: IHP 130nm CMOS5L via [[entities/tiny-tapeout]]; start from the Tiny Tapeout IHP Verilog template's **main branch**, which now targets CMOS5L (the `cmos5l` branch is retired); **`info.yaml` tile size 8x4**.
- Area: **8x4 = 32 tiles**, ~202x155 um per tile, **~1.0 mm2 nominal**, ~1K logic cells/tile (rough). At 202x155, 8x4 is 1616x620 um = 1.002 mm2, matching the blog's "about 1.0 mm2".
- **8x4 is confirmed and final for the March 2027 shuttle.** The blog's 2026-11-09 update says 8x4 is confirmed and Tiny Tapeout says the tile sizes are final.
- Instruction memory: prefer SRAM over flops for area; TT has SRAM examples on this node.
- Deadline **2027-01-18**; March 2027 CMOS5L shuttle (foundry schedule permitting). Open source, build in public, teams encouraged.
- FAQ answers now cover entry, design and judging: 24 digital pins (8 in, 8 out, 8 bidirectional), ~10 ns pad round trip, ~66 MHz max output, 60 MHz confirmed OK, SRAM macros allowed (including more than one), no analog pads but on-die analog/mixed-signal is fine, and the Tiny Tapeout flow/precheck is the required sign-off. See [[raw/articles/janestreet-competition-blog-update-2026-11-09]].

## Allocation history — 6x4 became 8x4 on 2026-11-09

The original blog post said 6x4 (24 tiles, ~0.7 mm2) and described 8x4 as a
possibility worth ~30% more area. The repo designed to 6x4 from 2026-09-20 until
this update. The 2026-11-09 update confirms 8x4 for the March 2027 shuttle and
says the tile sizes are final, so the current budget is 32 tiles and the old 6x4
figures are historical.

The earlier correction still matters methodologically: the 2026-09-17 ingest had
recorded a hand-written SUMMARY of the blog that said 8x4, then used that
paraphrase to overrule a correct transcript claim. The summary happened to match
the eventual allocation, but the method was still wrong. The full verbatim
original text remains at
[[raw/articles/janestreet-competition-blog-fulltext]], and the update is captured
separately at
[[raw/articles/janestreet-competition-blog-update-2026-11-09]]. The lesson is in
[[SCHEMA]]'s update policy: **a source outranks another only if the capture is
faithful.**

## Verification emphasis

Jane Street explicitly welcomes formal methods, constrained-random tests, and AI-assisted verification, and notes verification grows in importance as AI-assisted design spreads. This rewards investing in the [[concepts/gpio-signoff-corners]] SPICE-to-SDC signoff loop as a demonstrable methodology artifact, not just the RTL.
