---
title: SRAM Budget
created: 2026-09-18
updated: 2026-09-18
type: reference
tags: [area-budget, process-node, architecture]
sources: [raw/articles/janestreet-protocol-emulator-competition.md]
confidence: medium
---

# SRAM Budget

How much SRAM fits on the 24-tile die. Macro geometry is parsed from the
PDK LEFs by `tools/gen_sram_budget.py`
(`pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram`), so the numbers are the real
macros, not the datasheet's bit counts in isolation.

## The die is wide and short — this decides everything

TT tile notation is **width × height in tiles**, not a count. The ttihp
template's own comment says *"A single tile is about 167x108 uM"*, and the
competition is 6×4, so:

| Source | Tile | Die (6×4) | Area |
|---|---|---|---|
| **ttihp-verilog-template** (authoritative) | 167×108 µm | **1002 × 432 µm** | **432,864 µm² (0.433 mm²)** |
| Jane Street blog (optimistic) | 200×150 µm | 1200 × 600 µm | 720,000 µm² (0.720 mm²) |

Aspect ratio is ~2.3:1. That matters more than total area:
**a macro has to physically fit the rectangle**, and most of the larger
macros are taller than the die is.

## Every macro in the PDK

`fit` = can it be placed in the 6×4 die at the template's tile size
(`rotated` means only at 90°, which the flow supports).

| Macro | Bits | W×H (µm) | Area (µm²) | bits/µm² | P | fit |
|---|---|---|---|---|---|---|
| `1P_8192x32_c4` | 262,144 | 1520×618 | 939,915 | 0.2789 | 1P | no |
| `1P_2048x64_c2_bm_bist` | 131,072 | 784×627 | 491,634 | 0.2666 | 1P | no |
| `1P_4096x16_c3_bm_bist` | 65,536 | 417×618 | 257,609 | 0.2544 | 1P | rotated |
| `1P_2048x32_c2_bm_bist` | 65,536 | 417×627 | 261,108 | 0.2510 | 1P | rotated |
| `1P_1024x64_c2_bm_bist` | 65,536 | 784×336 | 263,946 | 0.2483 | 1P | yes |
| `1P_1024x32_c2_bm_bist` | 32,768 | 417×336 | 140,183 | 0.2338 | 1P | yes |
| `1P_4096x8_c3_bm_bist` | 32,768 | 237×618 | 146,413 | 0.2238 | 1P | rotated |
| `1P_512x64_c2_bm_bist` | 32,768 | 784×191 | 150,102 | 0.2183 | 1P | yes |
| `1P_1024x16_c2_bm_bist` | 16,384 | 237×336 | 79,674 | 0.2056 | 1P | yes |
| `1P_512x32_c2_bm_bist` | 16,384 | 417×191 | 79,720 | 0.2055 | 1P | yes |
| `1P_512x16_c2_bm_bist` | 8,192 | 237×191 | 45,309 | 0.1808 | 1P | yes |
| `1P_256x64_c2_bm_bist` | 16,384 | 784×119 | 93,181 | 0.1758 | 1P | yes |
| `1P_256x48_c2_bm_bist` | 12,288 | 596×119 | 70,850 | 0.1734 | 1P | yes |
| `1P_1024x8_c2_bm_bist` | 8,192 | 147×336 | 49,419 | 0.1658 | 1P | yes |
| `1P_256x32_c2_bm_bist` | 8,192 | 417×119 | 49,488 | 0.1655 | 1P | yes |
| `1P_512x8_c3_bm_bist` | 4,096 | 237×110 | 26,138 | 0.1567 | 1P | yes |
| `1P_256x16_c2_bm_bist` | 4,096 | 237×119 | 28,127 | 0.1456 | 1P | yes |
| `2P_1024x32_c2_bm_bist` | 32,768 | 685×385 | 264,167 | 0.1240 | 2P | yes |
| `1P_256x8_c3_bm_bist` | 2,048 | 237×74 | 17,547 | 0.1167 | 1P | yes |
| `2P_512x32_c2_bm_bist` | 16,384 | 685×220 | 150,650 | 0.1088 | 2P | yes |
| `2P_1024x16_c2_bm_bist` | 16,384 | 403×385 | 155,154 | 0.1056 | 2P | yes |
| `2P_512x16_c2_bm_bist` | 8,192 | 403×220 | 88,482 | 0.0926 | 2P | yes |
| `2P_256x32_c2_bm_bist` | 8,192 | 703×137 | 96,267 | 0.0851 | 2P | yes |
| `1P_64x64_c2_bm_bist` | 4,096 | 784×64 | 50,489 | 0.0811 | 1P | yes |
| `2P_512x8_c2_bm_bist` | 4,096 | 261×220 | 57,397 | 0.0714 | 2P | yes |
| `2P_256x16_c2_bm_bist` | 4,096 | 420×137 | 57,521 | 0.0712 | 2P | yes |
| `1P_64x16_c2` | 1,024 | 237×64 | 15,240 | 0.0672 | 1P | yes |
| `2P_256x8_c2_bm_bist` | 2,048 | 279×137 | 38,148 | 0.0537 | 2P | yes |
| `2P_64x32_c2` | 2,048 | 703×75 | 52,621 | 0.0389 | 2P | yes |
| `2P_64x22_c2_bm_bist` | 1,408 | 526×75 | 39,384 | 0.0358 | 2P | yes |

### What does not fit

- `1P_2048x64_c2_bm_bist` (131,072 bits, 784×627 µm) — its 627 µm short side exceeds the die's 432 µm short side.
- `1P_8192x32_c4` (262,144 bits, 1520×618 µm) — exceeds the die in both axes (1520 > 1002 and 618 > 432 µm).

**The highest-density macros in the PDK are unusable here.** The whole
8192×32 and 2048×64 classes are excluded by the die's shape, not by the
area budget. If the tile figure turns out to be the blog's 200×150,
the die becomes 1200×600 and that changes — re-run this
page if the tile size is confirmed.

## So how much actually fits

This is the number that matters, and it is **smaller than density × area
suggests**. A rectangle packs worse than its area implies, and a 3:1 die
punishes tall macros: `1024x64` is the densest macro that fits the template
die, yet only one instance fits — whereas `2048x32` packs two and
`1024x16` packs five.

Largest **practically packable** capacity, one macro type, grid packing:

| Die | Best macro | Layout | Total | Occupied area | Die efficiency |
|---|---|---|---|---|---|
| Template (1002×432) | `1P_512x32_c2_bm_bist` | 5×1 @ 191×417 µm | **81,920 bits (10 KB)** | 398,599 µm² | 92% |
| Blog (1200×600) | `1P_256x48_c2_bm_bist` | 10×1 @ 119×596 µm | **122,880 bits (15 KB)** | 708,499 µm² | 98% |

*That 100%-occupied figure is the theoretical roof with no logic at all.*
Real capacity is what you get after reserving logic, and the honest way to
state it is per size class:

### Area cost of a given SRAM size

Smallest single-macro-type area reaching each size, on the **template** die
(conservative) and the blog die (optimistic):

| SRAM | Bits | Template die: macro × n | Area | % of die | Blog die: area | % of die |
|---|---|---|---|---|---|---|
| 1 KB | 8,192 | `1P_512x16_c2_bm_bist` × 1 | 45,309 µm² | 10% | 45,309 µm² | 6% |
| 2 KB | 16,384 | `1P_1024x16_c2_bm_bist` × 1 | 79,674 µm² | 18% | 79,674 µm² | 11% |
| 4 KB | 32,768 | `1P_1024x32_c2_bm_bist` × 1 | 140,183 µm² | 32% | 140,183 µm² | 19% |
| 8 KB | 65,536 | `1P_4096x16_c3_bm_bist` × 1 | 257,609 µm² | 60% | 257,609 µm² | 36% |
| 16 KB | 131,072 | *not reachable* | — | — | — | — |
| 32 KB | 262,144 | *not reachable* | — | — | — | — |

*(Single macro type. A mixed floorplan can do somewhat better; this is the
conservative direction for a budget.)*

### And what is left for logic

The measured SERDES run gives ~31.9 µm² of standard cell per
logic cell, inflating ×1.69 once routing, clock tree and fill cells are
included (die ÷ stdcell area on that run). Applying that to the template die:

- Whole die, no SRAM: **≈ 8,000 logic cells**
- With 4 KB of SRAM (140,183 µm²): ≈ 5,409 logic cells
- With 8 KB of SRAM (257,609 µm²): ≈ 3,239 logic cells

**These are well under the blog's "~1K cells per tile" (≈24,000
cells for 24 tiles).** The two published tile figures are inconsistent with
each other, and the template's tile size is what the flow will actually
enforce. See [[STATUS]] open risks — worth confirming with TT/Jane Street
before committing to an SRAM-heavy architecture.

## Recommendation

- **1–2 KB (8192–16384 bits) is comfortable** — single-digit percent of the
  die, leaving the logic budget essentially intact. That is a realistic
  instruction memory for a PIO-style microsequencer (the RP2040's PIO has
  32 instructions × 2 SMs, so even 256 instructions is generous).
- **4 KB is the practical ceiling** if the design also needs real logic.
- **8 KB+ turns the chip into a memory chip** with a little logic attached.
- **Width beats depth here.** The die is wide and short, so favour macros
  that are wide and flat (e.g. `2048x32` at 417×627 does *not* pack well;
  `1024x16` at 237×336 packs five across). Check the layout column before
  choosing a shape.
- Prefer **fewer, wider macros** — fixed overhead (decoders, BIST, bitmask,
  IO) is per instance, not per bit.

### Caveats worth carrying

- No SRAM compiler for sg13g2 (OpenRAM does not support it), so you get
  exactly the 30 shapes above. Depth/width are not free parameters.
- The macros here include BIST and bitmask (`_bm_bist`) and the 2P variants
  are true two-port. Check which you actually need — and note that
  `64x16_c2` and `64x32_c2` have **no** `_bm_bist` suffix, so they are the
  plain parts.
- Macro timing comes with the macros (fast/typ/slow .lib), so SRAM access
  time is fixed and must be budgeted against the 60 MHz system clock
  (16.667 ns period). **This is the tightest path in the SoC, not the logic.**
  From the `.lib` shipped with the PDK, for the instantiated
  `RM_IHPSG13_1P_1024x16_c2_bm_bist`: the `A_CLK` -> `A_DOUT` clock-to-output
  is **7.25 ns at the slow corner** (1.08 V, 125 C), 4.34 ns at typ and
  2.67 ns at fast. That is 43% of a 60 MHz period. `pe_imem` deliberately has
  NO output register (it would add a second cycle of latency and break the
  CPU's fetch-ahead, which assumes exactly one), so the whole
  `A_CLK -> A_DOUT -> CPU` path is combinational after the macro.

**Now MEASURED in the full SoC, post-route** (this replaces the estimate the
paragraph above used to end on). The full-SoC LibreLane run
(`RUN_2026-09-22_00-33-59`, the one with the working PDN) reported:

| quantity | value |
|---|---|
| SRAM in-context `A_CLK` -> `A_DOUT` | **7.635 ns** (vs 7.25 ns from the .lib table) |
| total path arrival | 13.448 ns |
| total path required | 14.591 ns |
| **setup slack, slow corner** | **+1.143 ns** |
| hold slack, slow corner | +0.656 ns |
| worst-case IR drop on VPWR | 0.30% (3.56 mV of 1.20 V) |

**One caveat on that 7.635 ns, measured 2026-09-22 and not obvious from
the summary:** the macro's own `.lib` characterises its input slew axis only
up to **0.5952** and its output cap axis only up to **0.0640**, and this
design presents **1.291** slew on `A_DIN[5]` and **0.1169** cap on
`A_DOUT[4]`. OpenROAD **extrapolates silently** there -- it emits no warning
-- so the macro's internal delay is a table lookup taken outside the table.
That is why STA reports 10 max-slew / 8 max-cap / 7 max-fanout violations on
the macro's pins alongside the clean setup/hold result; those checks are
separate from setup/hold and an earlier note here wrongly read the clean
setup/hold as 'zero violations'. The slack on the affected paths is large
(`A_DIN[5]` +10.27 ns, `A_ADDR[0]` +3.70 ns) and extrapolation usually
over-estimates delay, so the signoff is not in danger -- but the fix belongs
in the FLOW (`repair_design` resizes nothing here because it runs with
`-slew_margin 20 -cap_margin 20`; raising
`DESIGN_REPAIR_MAX_SLEW_PCT`/`DESIGN_REPAIR_MAX_CAP_PCT` is the lever).
STATUS gotchas 37-38.

The in-context access is 0.39 ns worse than the standalone .lib table figure,
which is the clock-tree and routing overhead of actually placing the macro --
and it is the reason the .lib figure was labelled an estimate. Setup and hold
both close at all three corners with zero SETUP/HOLD violating paths (the
separate max-slew/max-cap checks on the macro do fail -- see the caveat
result. Note the slack is a *measured post-route* number, so it moves by
~0.1 ns between runs as placement changes; an earlier run without the PDN
fix read +1.234 ns. Quote the run ID with the number.
- Floorplanning matters: a rotated macro has its pins on a different edge,
  which constrains where the logic around it can go.
- The macro's power pins are on **Metal4** while the PDN grid is built on
  TopMetal1/TopMetal2, so the stock PDN config leaves the macro's supplies
  unconnected (`PSM-0069`). The SoC's flow uses a custom `PDN_CFG` that
  stripes Metal4 and steps up to the grid; see `flow/pe_uart_soc_pdn.tcl`.

## Related

- [[concepts/pdk-toolchain]] — where the macros live and how to use them.
- [[concepts/competition-overview]] — the area budget this sits inside.
- [[reference/protocol-pin-budget]] — the other hard budget (IO).
- [[STATUS]] — the tile-size discrepancy is an open risk there.
