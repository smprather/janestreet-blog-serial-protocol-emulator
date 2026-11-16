# Full-SoC place-and-route, setup closure — 2026-11-12

Runs (both executed in parallel, 10 jobs each, same staged config):

| Tag | Synthesis | Result |
|---|---|---|
| `area3` | `SYNTH_STRATEGY = AREA 3` | **0 setup violations at all three corners** |
| `dly4` | `SYNTH_STRATEGY = DELAY 4` | −0.690 ns WNS, −1.554 ns TNS, 6 violating paths |

Run dirs: `~/asic-runs/pe_soc/runs/area3`, `~/asic-runs/pe_soc/runs/dly4`
Config: `flow/pe_soc.json` (`ihp-sg13cmos5l` + `sg13cmos5l_stdcell`), 60 MHz
(16.667 ns), 1.0 ns setup uncertainty / 0.25 ns hold uncertainty
Image: `ghcr.io/librelane/librelane:3.1.0.dev3`
Die: 1616 × 620 µm (8×4 tiles at 202 × 155 µm)
Wall time: 46 min 01 s for both runs together (08:18:49 → 09:04:50)

## Why the synthesis strategy was changed

The 2026-11-11 run failed at −1.138 ns / 9 paths on a reg-to-reg cone from the
instruction SRAM's `A_DOUT`. That path is cell-delay-limited: SRAM read 7.689 ns
of a 16.667 ns period, then 19 standard-cell stages, including a `nand4_1` at
1.457 ns driving a 1.649 ns output slew and the following `nor4_2` at 1.182 ns.
Fixing the router or the resizer cannot recover time that is inside those cells,
so the netlist was re-mapped for delay first.

Measured, not guessed: `python3 -m librelane -f synthesisexploration config.json`
(16 s, 9 ABC strategies in parallel, pre-PnR STA at `nom_slow_1p08V_125C`, ideal
nets) ranks the worst reg-to-reg slack each script produces from this RTL:

| Strategy | Gates | Area (µm²) | Worst R2R setup slack |
|---|---:|---:|---:|
| AREA 0 (previous config) | 7,128 | 114,560 | +1.931 |
| AREA 1 | 7,103 | 113,961 | +2.067 |
| AREA 2 | 7,312 | 113,863 | +2.506 |
| **AREA 3** | **9,071** | **122,126** | **+3.683** |
| DELAY 0 | 7,211 | 121,507 | +1.504 |
| DELAY 1 | 7,198 | 119,895 | +0.753 |
| DELAY 2 | 7,181 | 119,591 | +0.660 |
| DELAY 3 | 7,212 | 120,275 | +0.723 |
| DELAY 4 | 8,314 | 125,258 | +3.646 |

The baseline's pre-PnR → post-route gap is ~3.07 ns (1.931 → −1.138), so the
+1.75 ns that AREA 3 buys is the margin the design was missing. Note that
DELAY 0–3 are all *worse* than AREA 0 on this netlist, so the screen is worth
running and not worth assuming.

Both final runs also used the same aggressive fixer settings, so the pair
isolates the strategy:

```json
"PL_RESIZER_SETUP_SLACK_MARGIN": 0.3,      "GRT_RESIZER_SETUP_SLACK_MARGIN": 0.25,
"PL_RESIZER_SETUP_MAX_BUFFER_PCT": 100,    "GRT_RESIZER_SETUP_MAX_BUFFER_PCT": 100,
"PL_RESIZER_SETUP_REPAIR_TNS_PCT": 100,    "GRT_RESIZER_SETUP_REPAIR_TNS_PCT": 100,
"DESIGN_REPAIR_MAX_SLEW_PCT": 30,          "GRT_DESIGN_REPAIR_MAX_SLEW_PCT": 25,
"DESIGN_REPAIR_MAX_CAP_PCT": 30,           "GRT_DESIGN_REPAIR_MAX_CAP_PCT": 25
```

## `area3` signoff (RCX + `OpenROAD.STAPostPNR`, 3 corners)

| Measure | Value |
|---|---:|
| Setup violators (all corners) | **0** |
| Setup WNS / TNS (slow) | 0 / 0 |
| Worst reg-to-reg setup slack (slow) | **+0.628 ns** (`A_DOUT` → `_15291_/D`) |
| Next worst R2R (slow) | +0.719, +0.777, +0.781, +0.799 ns, all `A_DOUT`-sourced |
| Hold violators (all corners) | 0 |
| Hold WS (fast / typ / slow) | +0.109 / +0.288 / +0.607 ns |
| Route DRC (iterations) | **0** (170 → 107 → 121 → 0 → 2 → 0) |
| Antenna violations | 0 nets, 0 pins (24 diodes) |
| KLayout XOR differences | 0 |
| Power-grid violations | 0; worst VPWR drop 0.42 mV |

The only path reported at exactly 0.000 ns is
`pin_in[7] -> _14957_` (positive level-sensitive latch): the ADR-002
latch-pair time-borrowing path, unchanged from every earlier run, not a
violation.

## Cost

| Measure | `area3` | 2026-11-11 (AREA 0) |
|---|---:|---:|
| Standard cells | 11,130 | 9,648 |
| Standard-cell area | 154,110 µm² | 148,881 µm² |
| Standard-cell utilization | 19.59% | 19.04% |
| Total instance area | 924,487 µm² | 924,487 µm² |
| Total utilization | 33.14% | 32.58% |

+15% cells and +3.5% standard-cell area for 1.14 ns of recovered setup slack;
the die has room, so this is the cheap end of the trade.

## What still fails (unchanged, not timing)

| Check | Result |
|---|---|
| KLayout DRC | 2,491 errors, all one rule (`M4.b`) |
| Magic DRC | 256,865 errors |
| Magic illegal overlap | 3,090 errors |
| LVS | FAILED, top-level pin matching |
| Flow exit | aborts in `Netgen.LVS` post-processing (`JSONDecodeError: Invalid \escape`) |

The LVS diff is the SRAM `VDD!`/`VDDARRAY!` power-pin model: the pin tables are
`(no pin, node is VPWR)` vs `VGND` on the macro's supply pins, and the flow's
own report says the devices are equivalent before failing the top-level pin
match. Route DRC being 0 while KLayout/Magic show thousands is the same
macro-rule signature as every prior run in this repo, not new geometry.

## Config of record

`flow/pe_soc.json` now carries `SYNTH_STRATEGY = "AREA 3"` plus the fixer
settings above. Verified: loading the edited file resolves to byte-identical
values in `runs/cfgcheck/resolved.json` and `runs/area3/resolved.json` for every
timing and synthesis key.
