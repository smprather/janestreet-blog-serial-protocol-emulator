---
title: ADR-003 — Two SRAM macros, instruction and frame buffer
created: 2026-09-20
updated: 2026-09-20
type: decision
tags: [decision, area-budget, architecture, process-node]
sources: [raw/articles/janestreet-competition-blog-fulltext.md]
confidence: medium
---

# ADR-003 — Two SRAM macros: instruction memory and a frame buffer

## Status

Accepted as the plan of record. **The instruction half is IMPLEMENTED** (2026-09-20,
`rtl/pe_imem.v`); the frame buffer is not. Supersedes the single-macro
recommendation in [[plans/through-i2c]] Blocker 3, which considered instruction
memory only.

**Read [[decisions/adr-004-program-counter-width]] before acting on this page.** The
macro choice below stands unchanged, but the swap turned out NOT to be free: the CPU
had a fixed 8-bit PC, so 1024 words were not addressable until the PC and the
jump-target field widened in the same change. This page's projection was computed
from flop memory and its "does not change the CPU's interface" implication was
wrong.

## Context

Two facts arrived together on 2026-09-20 and they decide this jointly.

**1. Flop instruction memory is 89% of the current design.** Measured by
synthesising `pe_uart_soc` at four depths:

| IMEM depth | Cells | Area (µm²) |
|---|---|---|
| 16 words | 1,990 | 40,285 |
| 32 words | 2,968 | 60,605 |
| 64 words | 4,792 | 101,267 |
| 128 words | 8,743 | 182,652 |

Dead linear: **1,271 µm² and 60 cells per instruction word.** Everything else in
the SoC — CPU, data memory, timer, pin, glue — is 19,947 µm² and 1,025 cells.
Storing 2,048 bits of program in flip-flops costs roughly 80 µm²/bit where a macro
costs about 5.

**2. 10BASE-T needs a frame buffer, and it is small.** A maximum Ethernet frame is
1,518 bytes ([[concepts/ethernet-scope]]). Data memory is 16 bytes today and cannot
hold even a 64-byte minimum frame.

## Decision

Two macros, kept separate. The CPU is Harvard with independent instruction and data
ports, so sharing one macro would mean arbitration the architecture does not
currently need.

| Role | Macro | Capacity | Area (µm²) |
|---|---|---|---|
| Instruction memory | `1P_1024x16_c2_bm_bist` | 1,024 words × 16 b | 79,674 |
| Frame / data buffer | `1P_1024x16_c2_bm_bist` | 2,048 bytes | 79,674 |

**You cannot buy 1.5 KB.** The macro granularity does not offer it, and this is the
single most useful number on this page:

| Candidate | Bytes | Holds a 1,518 B frame? | Area (µm²) |
|---|---|---|---|
| `1P_512x16_c2_bm_bist` | 1,024 | **no** | 45,309 |
| `1P_1024x8_c2_bm_bist` | 1,024 | **no** | 49,419 |
| `1P_1024x16_c2_bm_bist` | 2,048 | yes | 79,674 |
| `1P_512x32_c2_bm_bist` | 2,048 | yes | 79,720 |
| `1P_4096x8_c3_bm_bist` | 4,096 | yes | 146,413 |

The two 1 KB parts miss a full frame by 494 bytes, so the practical floor is **2 KB**.
`1P_1024x16` and `1P_512x32` are within 46 µm² of each other; pick `1P_1024x16`
because it is the same part as the instruction memory, which means one macro type to
integrate, one timing arc to characterise and one set of BIST hooks.

The 8-bit-wide `1P_4096x8` avoids byte-packing entirely but costs 84% more area for
capacity nothing needs.

### Consequence: the frame buffer is 16 bits wide and frames are bytes

Packing two bytes per word needs byte-select logic on the data port. That is the
price of the area saving and it belongs in the block's header when written. The
alternative (`1P_4096x8`) trades 67,000 µm² to avoid a mux.

## Area outcome

Measured mapped→die factor is **1.97**, from the one block that has been through
real place-and-route (`pe_serdes`: 11,223 mapped → 17,211 routed cells → 29,164 µm²
die at 78% utilisation). Macros place as-is and take no routing inflation.

Projected full design: SoC logic + SERDES + codec pipeline + DRU + CRC LFSR + pin
matrix, plus both macros.

| Allocation | Die (µm²) | Design | Occupancy |
|---|---|---|---|
| **6×4 = 1002 × 432 µm (the real budget)** | 432,864 | 235,116 | **54%** |
| 8×4 = 1336 × 432 µm (upside, if offered) | 577,152 | 235,116 | 41% |

For comparison, the design **today** (flop IMEM, SoC + SERDES + codecs) is 385,265
µm² of die, which is **89% of the 6×4** and 67% of an 8×4. The swap is what turns
"will not fit once the pin matrix and DRU land" into "roomy either way."

Dropping instruction memory to `1P_512x16` (512 words) saves 34,365 µm² and lands at
46% of the 6×4. Take that only if the floorplan demands it: `uart_echo` is already
114 words, and two or three resident protocol programs will approach 512.

## The allocation, settled

**6×4 = 24 tiles.** The blog says "Set the tile size in info.yaml to 6x4" and "The
current maximum area is 6x4 tiles per design", and describes 8×4 only as a
possibility worth ~30% more area that would be announced by a page update and an
email. `info.yaml` matches. Verbatim source:
[[raw/articles/janestreet-competition-blog-fulltext]].

**This decision survives the upside intact.** 6×4 and 8×4 are the same *height*
(432 µm at the template tile) and differ only in width, so no macro that fits one
fails on the other. `tools/gen_sram_budget.py --tiles 8x4` re-answers
[[reference/sram-budget]] for the larger die; the committed page is the 6×4 answer.

Worth recording because it nearly went the other way: a **4×6** die — the same 24
tiles, rotated — would be 668 × 648 µm and would lose the entire 64-bit-wide macro
family (`1P_1024x64`, `1P_512x64`, `1P_256x64`, `1P_64x64`), all 784 µm wide. Both
macros chosen here are 237 × 336 µm and fit any of the three shapes, but a future
move to wide fetch would not. **Shape, not tile count, is what decides macro fit.**

## Alternatives rejected

- **Flops at 256 words.** ~4 k cells and it does nothing for the frame buffer. The
  measured per-word cost makes this 325,000 µm² of die for instructions alone.
- **One larger shared macro.** `1P_2048x32` holds 8 KB in 261,108 µm², more than both
  chosen macros together, and forces port arbitration on a Harvard core.
- **No frame buffer, stream to a host instead.** Rejected on concurrency, not area:
  it requires servicing two protocols at once on a core with no interrupts. See
  [[concepts/ethernet-scope]].

## Related

- [[concepts/ethernet-scope]] — why 1,518 bytes and not 32 KB.
- [[reference/sram-budget]] — every macro's real geometry, and what fits.
- [[plans/through-i2c]] — Blocker 3, which this supersedes.
- [[STATUS]] — the measured area table this is projected from.
