---
title: Competition Overview
created: 2026-09-17
updated: 2026-09-17
type: concept
tags: [competition, constraint, area-budget, process-node, verification]
sources: [raw/articles/janestreet-protocol-emulator-competition.md, raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: high
---

# Competition Overview

Design an open-source, general-purpose protocol-emulator ASIC: a tiny CPU with an ISA for reading/writing pins, counting cycles, and hitting precise timing so protocols run in firmware, not fixed logic. Reprogrammability after fabrication (within timing/IO limits) is the point — not one UART block plus one SPI block plus one I2C block. Models: RP2040 PIO, TI Sitara PRU.

## Protocol targets

- Baseline: UART, SPI, I2C.
- Stretch: low-speed USB, 10Mbit Ethernet.
- Also suggested: JTAG, SWD, PS/2, CAN. Plus anything novel the architecture enables.
- See [[concepts/physical-layer-gpio]] for what each protocol needs electrically, and [[concepts/factored-hardware-blocks]] for the shared RTL primitives.

## Hard constraints (blog = primary source)

- Process: IHP 130nm CMOS5L via [[entities/tiny-tapeout]]; start from the CMOS5L Verilog template; `info.yaml` tile size 8x4.
- Area: max 8x4 tiles = 32 tiles, ~200x150 um per tile, ~1 mm2 nominal, ~1K logic cells/tile (rough).
- Instruction memory: prefer SRAM over flops for area; TT has SRAM examples on this node.
- Deadline 2026-01-18; March 2027 CMOS5L shuttle (foundry schedule permitting). Open source, build in public, teams encouraged.

## Transcript corrections

The Gemini transcript said "initially 6x4, possibly scaling to 8x4" and "~0.7 mm2 nominal tile area". The blog post supersedes both: it instructs 8x4 directly, with ~1 mm2 nominal for the 32-tile block. Treat transcript area claims as stale.

## Verification emphasis

Jane Street explicitly welcomes formal methods, constrained-random tests, and AI-assisted verification, and notes verification grows in importance as AI-assisted design spreads. This rewards investing in the [[concepts/gpio-signoff-corners]] SPICE-to-SDC signoff loop as a demonstrable methodology artifact, not just the RTL.
