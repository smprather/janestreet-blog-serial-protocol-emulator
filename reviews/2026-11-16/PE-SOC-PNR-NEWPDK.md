# Full-SoC PnR on the pulled PDK (e73adb40) — 2026-11-16

Run: `~/asic-runs/pe_soc/runs/RUN_2026-11-16_03-59-01`
Config: `flow/pe_soc.json` (`SYNTH_STRATEGY=AREA 3` + the 2026-11-12 fixer set)
PDK: IHP-Open-PDK **`e73adb40`** (`v0.3.0-1151-g`, `main` after the 2026-11-15
pull) — **not** the shuttle pin `2bbec755`
Image: `ghcr.io/librelane/librelane:3.1.0.dev3`
Wall time: 45 min 49 s (21:59:02 → 22:44:51)
Flow result: exit 1 at the Netgen LVS step (72/80), same as every prior run

This run answers one question: does the design still sign off when the PDK
tree moves 1,151 commits past the Tiny Tapeout pin? It is compatibility
evidence, not shuttle signoff — the shuttle installer
(`docs/tt-shared-silicon/sources/tt-gds-action-install-sg13cmos5l.sh`) hardcodes
`IHP_PDK_REV=2bbec755…`.

## What the pull changed for this flow

| PDK path | Changed? | Effect here |
|---|---|---|
| `libs.ref/sg13cmos5l_stdcell/lib/*.lib` | no | cell Liberty identical; synthesis table reproduced to 6 decimals |
| `libs.ref/sg13cmos5l_sram` (→ `sg13g2_sram`) | no | SRAM timing model identical |
| `libs.ref/…/lef/sg13cmos5l_tech.lef` | 1 line | `Via1_DC2L` Metal1 RECT x0 −0.1 → −0.105 |
| Magic DRC/tech decks, KLayout DRC/LVS decks | yes | see counts below |
| `libs.tech/librelane/*/config.tcl` | yes | newer LibreLane vocabulary; CTS + KLayout-DRC option deltas |

Resolved differences on `3.1.0.dev3`: `CTS_ROOT_BUFFER` `buf_8` → `buf_16`,
`CTS_CLK_BUFFERS` loses `buf_1`, `TIMING_VIOLATION_CORNERS` `*typ*` → `*`,
`KLAYOUT_DRC_OPTIONS` unset (the new PDK's `KLAYOUT_DRC_DEFINES` is not
implemented by this image), `DIODE_CELL` gains `/A`. Full table:
`wiki/concepts/pdk-toolchain.md`.

## Timing (RCX + `OpenROAD.STAPostPNR`, 3 corners)

| Measure | `e73adb40` | `2bbec755` (2026-11-12) |
|---|---:|---:|
| Setup violators, slow / typ / fast | **0 / 0 / 0** | 0 / 0 / 0 |
| Setup WNS / TNS (slow) | 0 / 0 | 0 / 0 |
| Worst reg-to-reg setup (slow) | **+0.651 ns** | +0.628 ns |
| Reg-to-reg setup (fast) | +3.954 ns | +3.971 ns |
| Hold WS fast / typ / slow | **+0.101 / +0.278 / +0.594 ns** | +0.109 / +0.288 / +0.607 |
| Route DRC (final iteration) | **0** | 0 |

The gain is traceable to the clock tree: `clkbuf_*` are now `buf_16`, the
`A_CLK` edge arrives at 0.977 ns with a cleaner slew, and the SRAM read itself
measures 7.540 ns instead of 7.689 ns. The macro's substitution table did not
change; only the input transition did.

## Physical

| Measure | `e73adb40` | `2bbec755` |
|---|---:|---:|
| Standard cells | 11,131 | 11,130 |
| Standard-cell area | 154,739 µm² | 154,110 µm² |
| Total utilization | 33.20% | 33.14% |
| KLayout DRC | 2,491 with the pinned options (49 without — see below) | 2,491 |
| Magic DRC | 256,865 | 256,865 |
| Magic illegal overlap | 3,090 | 3,090 |
| KLayout XOR | 0 | 0 |
| Antenna | 0 nets / 0 pins | 0 / 0 |
| PSM violations | 0 (worst VPWR drop 0.41 mV) | 0 |
| Total power | 5.73 mW | 5.60 mW |

The KLayout drop is **not** a design or deck improvement — it is the run mode.
The new PDK writes its DRC options as `KLAYOUT_DRC_DEFINES`, a name
`librelane:3.1.0.dev3` does not implement, so this run passed **no options** to
the deck, and the deck then never reaches `deep` mode. A/B on the same streamed
GDS and the same image:

| Options passed | `M4.b` count | Raw |
|---|---:|---|
| none (what this run did) | **49** | `runs/drc_ctl` |
| `no_recommended=false` | 49 | `runs/drc_nr` |
| `no_recommended=true` | 49 | `runs/drc_nrtrue` |
| `run_mode=deep` | **2,491** | `runs/drc_rm` |
| `no_recommended=true run_mode=deep` (the old PDK's values) | **2,491** | `runs/drc_deep3` |

`no_recommended` is irrelevant to this rule; `run_mode=deep` is the whole
difference, and the deck's own log shows it — "`deep` mode is enabled" versus
" mode is enabled" with the empty value. 2,491 is the number every earlier run
reported. All 49 in the no-option run sit on the macro edges (24 on each SRAM,
1 outside the die), so neither number is evidence about the standard-cell
routing — `route__drc_errors = 0` is. `flow/pe_soc.json` now pins
`KLAYOUT_DRC_OPTIONS`, so the checked rule set no longer depends on which PDK
key the image happens to understand.

## LVS

Still fails top-level pin matching with the identical signature: the pin tables
differ on the SRAM `VDD!`/`VDDARRAY!` power pins, netgen itself reports the two
device classes equivalent, and the flow then aborts in its netgen-stats JSON
parser (`Invalid \escape`). The PDK bump changed nothing about this failure.

## Verdict

The PDK update is **timing- and routing-compatible**: setup closes at 60 MHz on
all three corners, hold is clean, route DRC and XOR are zero. Its KLayout DRC
number is 50× smaller only because the image dropped the PDK's DRC options —
a rule-set artifact, not an improvement, now pinned in `flow/pe_soc.json`.
Two follow-ups if the tree is ever adopted forward of the pin: bump the
LibreLane image so `KLAYOUT_DRC_DEFINES` is read natively (the design-config
pin already covers the count), and re-check the CTS defaults deliberately
rather than inheriting them.
