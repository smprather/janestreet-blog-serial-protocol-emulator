---
title: ADR-003 — Two SRAM macros, instruction and frame buffer
created: 2026-09-20
updated: 2026-09-20
type: decision
tags: [decision, area-budget, architecture, process-node]
sources: [raw/articles/janestreet-protocol-emulator-competition.md]
confidence: medium
---

# ADR-003 — Two SRAM macros: instruction memory and a frame buffer

## Status

Accepted as the plan of record. **Not implemented.** Supersedes the single-macro
recommendation in [[plans/through-i2c]] Blocker 3, which considered instruction
memory only.

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
| 4×6 = 668 × 648 µm | 432,864 | 235,116 | **54%** |
| 8×4 = 1336 × 432 µm | 577,152 | 235,116 | **41%** |

For comparison, the design **today** (flop IMEM, SoC + SERDES + codecs) is 384,500
µm² of die, which is **89% of a 4×6** and 67% of an 8×4. The swap is what turns "will
not fit once the pin matrix and DRU land" into "roomy on either allocation."

Dropping instruction memory to `1P_512x16` (512 words) saves 34,365 µm² and lands at
46% of a 4×6. Take that only if the floorplan demands it: `uart_echo` is already 114
words, and two or three resident protocol programs will approach 512.

## The allocation is a live question

[[entities/tiny-tapeout]] records **8×4** from the blog, and marks the transcript's
"6×4" as superseded. If the offer is now 4×6, `info.yaml` needs changing and this
page's occupancy column shifts to the 4×6 row. Both are 24–32 tiles but they are
completely different *shapes*, and shape is what decides macro fit.

`tools/gen_sram_budget.py --tiles 4x6` re-answers [[reference/sram-budget]] for the
other allocation without editing anything. The committed page is the 8×4 answer.

**A 4×6 die loses the entire 64-bit-wide macro family** — `1P_1024x64`,
`1P_512x64`, `1P_256x64` and `1P_64x64` are all 784 µm wide against a 668 µm die
width, and none fit in either orientation. This decision is unaffected (both chosen
macros are 237 × 336 µm and fit comfortably either way), but a future move to wide
fetch would be.

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
