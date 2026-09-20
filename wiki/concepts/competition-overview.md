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

- Process: IHP 130nm CMOS5L via [[entities/tiny-tapeout]]; start from the CMOS5L Verilog template; **`info.yaml` tile size 6x4** ("Set the tile size in info.yaml to 6x4").
- Area: **current maximum 6x4 tiles = 24 tiles**, ~200x150 um per tile, **~0.7 mm2 nominal**, ~1K logic cells/tile (rough). The blog's own arithmetic is self-consistent: 6x4 at 200x150 is 1200x600 um = 0.72 mm2.
- **8x4 is an upside, not the allocation.** The blog says they are "working on the possibility of scaling up to 8x4 tiles (~30% more area)" and will update the page and email sign-ups if it happens. Design to 24 tiles; treat 32 as headroom that may never arrive.
- Instruction memory: prefer SRAM over flops for area; TT has SRAM examples on this node.
- Deadline 2026-01-18; March 2027 CMOS5L shuttle (foundry schedule permitting). Open source, build in public, teams encouraged.

## Transcript corrections — REVERSED 2026-09-20

An earlier revision of this page said:

> The Gemini transcript said "initially 6x4, possibly scaling to 8x4" and "~0.7 mm2 nominal tile area". The blog post supersedes both: it instructs 8x4 directly, with ~1 mm2 nominal for the 32-tile block. Treat transcript area claims as stale.

**That was wrong, and the transcript was right on both counts.** The blog says 6x4
three times, gives ~0.7 mm2, and describes 8x4 only as a possibility. The error came
from the 2026-09-17 ingest, which recorded a hand-written SUMMARY of the blog rather
than its text, and got the tile count wrong; the wiki then used that paraphrase to
overrule a correct primary-adjacent source.

The full verbatim blog text is now kept at
[[raw/articles/janestreet-competition-blog-fulltext]] so this cannot recur. The
lesson is in [[SCHEMA]]'s update policy: **a source outranks another only if the
capture is faithful.** Authority of origin does not survive a lossy transcription.

## Verification emphasis

Jane Street explicitly welcomes formal methods, constrained-random tests, and AI-assisted verification, and notes verification grows in importance as AI-assisted design spreads. This rewards investing in the [[concepts/gpio-signoff-corners]] SPICE-to-SDC signoff loop as a demonstrable methodology artifact, not just the RTL.
