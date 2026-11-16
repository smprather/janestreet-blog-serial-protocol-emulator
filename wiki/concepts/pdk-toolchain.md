---
title: PDK and Toolchain Setup
created: 2026-09-17
updated: 2026-10-18
type: concept
tags: [process-node, signoff, sta, spice]
sources: [https://github.com/IHP-GmbH/IHP-Open-PDK, https://github.com/TinyTapeout/tt-gds-action/tree/ihp-cmos5l]
confidence: high
---

# PDK and Toolchain Setup
> **What you'll learn here:** which PDK and EDA tools this project builds against, and where the SRAM macros and corner definitions come from
>
> **You can verify this by:** `python3 tools/checks/macro_flow_config.py` validates the flow's macro geometry and pin mapping against the PDK, and fails loudly rather than skipping quietly when the PDK is absent.

The competition target is **IHP SG13CMOS5L** (130 nm, 5-metal stack
M1-M4-TopMetal1), through the March 2027 Tiny Tapeout CMOS5L shuttle. It is
**not** the full SG13G2 SiGe BiCMOS process. The two PDKs share the SRAM macro
GDS/LEF/Liberty views but have different standard-cell libraries, technology
LEFs, metal stacks and routing layers.

## PDK revision in use

Tiny Tapeout pins the `ihp-sg13cmos5l` tree to IHP-Open-PDK commit
`2bbec755dc67ca3db0261c3d6163e15735d66710` (2026-09-08). That pin is not a
local choice: `docs/tt-shared-silicon/sources/tt-gds-action-install-sg13cmos5l.sh`
is the captured shuttle installer and it hardcodes `IHP_PDK_REV=2bbec755…`.
The 2026-11-12 full-SoC signoff was produced on that commit.

On 2026-11-15 the local tree was pulled to `main` (`e73adb40`, described as
`v0.3.0-1151-ge73adb40`), i.e. **1,151 commits ahead of the shuttle pin**. Check
which commit a run used before believing its numbers:

```bash
git -C ~/pdk/IHP-Open-PDK rev-parse --short HEAD
```

Measured deltas between those two commits (only what this flow consumes):

| PDK path | Changed? | Effect |
|---|---|---|
| `libs.ref/sg13cmos5l_stdcell/lib/*.lib` | **no** | cell Liberty identical — cell-delay numbers carry over |
| `libs.ref/sg13cmos5l_sram` (symlink to `ihp-sg13g2_sram`) | **no** | SRAM A_CLK→A_DOUT model identical |
| `libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_tech.lef` | 1 line | `Via1_DC2L` Metal1 RECT x0 −0.1 → −0.105 |
| `libs.ref/sg13cmos5l_stdcell/gds`, `sg13cmos5l_io/{lib,gds,cdl}` | yes | pad library only (0 padcells instantiated here) |
| `libs.tech/magic/*.tech`, `generate_fill.py` | yes | Magic DRC/extract deck changed |
| `libs.tech/klayout/tech/drc/*`, `lvs/sg13cmos5l.lvs` | yes | KLayout DRC/LVS decks changed |
| `libs.tech/librelane/*/config.tcl` | yes | interface renames, below |

The `libs.tech/librelane` files were rewritten for a **newer LibreLane variable
vocabulary**: `LIB`→`CELL_LIBS`, `TECH_LEF`→`TECH_LEFS`, `*_OPTIONS`→
`*_DEFINES`, `SYNTH_MIN_BUF_PORT`→`SYNTH_BUFFER_CELL` (with pin), `DIODE_CELL`
now carries the pin (`sg13cmos5l_antennanp/A`), and `mux2_map.v`/`mux4_map.v`
were deleted. The pinned image `librelane:3.1.0.dev3` reads both generations for
most keys, but not all — resolved differences that matter on dev3:

| Variable | 2bbec755 | e73adb40 | Consequence on dev3 |
|---|---|---|---|
| `CTS_ROOT_BUFFER` | `sg13cmos5l_buf_8` | `sg13cmos5l_buf_16` | different clock tree; needs re-signoff |
| `CTS_CLK_BUFFERS` | incl. `buf_1` | `buf_8 buf_4 buf_2` | as above |
| `TIMING_VIOLATION_CORNERS` | `*typ*` | `*` | violation metrics across all corners |
| `KLAYOUT_DRC_OPTIONS` | `{no_recommended: 1, run_mode: deep}` | **unset** (PDK writes `KLAYOUT_DRC_DEFINES`, unread by dev3) | the deck never enables `deep` mode, which changes the reported count (measured on one GDS: 49 with no options, 2,491 with `run_mode=deep`; `no_recommended` alone makes no difference). `flow/pe_soc.json` now pins the options, so the design's checked rule set is the same on both trees |
| `DIODE_CELL` | `sg13cmos5l_antennanp` | `sg13cmos5l_antennanp/A` | pin-explicit, accepted by dev3 |

Synthesis is provably unaffected: `synthesisexploration` on the new tree
reproduces the old tree's table to six decimals (AREA 0 +1.931, AREA 3 +3.683,
DELAY 4 +3.646 ns), so the netlist and its timing are identical and only the
physical/back-end defaults moved.

## PDK: `~/pdk/IHP-Open-PDK`

The installed tree (revision history and deltas in the section above) contains:

- `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell`: Liberty, LEF, GDS, Verilog,
  CDL and SPICE for the `sg13cmos5l_*` cells.
- `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram`: a symlink to
  `../../ihp-sg13g2/libs.ref/sg13g2_sram`. The SRAM macro views are shared;
  `RM_IHPSG13_1P_1024x16_c2_bm_bist` is the part used by `pe_imem` and
  `pe_fbuf`. Capacity and geometry: [[reference/sram-budget]].
- `ihp-sg13cmos5l/libs.ref/sg13cmos5l_io`: the CMOS5L pad library.
- `ihp-sg13cmos5l/libs.tech/librelane`: the LibreLane integration. Its
  `sg13cmos5l_stdcell/config.tcl` is the corner/cell source of truth and its
  top-level `config.tcl` sets the 5-layer routing stack
  (`RT_MIN_LAYER=Metal2`, `RT_MAX_LAYER=TopMetal1`, PDN on
  Metal4/TopMetal1).
- `ihp-sg13cmos5l/libs.tech/{klayout,magic,netgen,...}`: tool decks. The PDK
  selects KLayout for GDS streamout; check the offered Magic/KLayout DRC/LVS
  support before claiming physical signoff.

Do not point the flow at `~/.ciel/ihp-sg13g2` or at
`~/pdk/IHP-Open-PDK/ihp-sg13g2`. Those are the SG13G2 PDK and produce a
7-metal design with `sg13g2_stdcell` cells.

## Corners

- Liberty: six PVT corners, same naming scheme as SG13G2: fast
  (1.32 V/-40 C, 1.65 V/-40 C), typ (1.20 V/25 C, 1.50 V/25 C), slow
  (1.08 V/125 C, 1.35 V/125 C). No FS/SF Liberty models.
- The flow uses `nom_typ_1p20V_25C`, `nom_fast_1p32V_m40C` and
  `nom_slow_1p08V_125C`. The SRAM's fast corner is 1p32V/m55C and is bound to
  the stdcell fast corner 1p32V/m40C in `flow/pe_soc.json`'s `MACROS.lib` keys.
- SPICE corner models live under `ihp-sg13cmos5l/libs.tech`; the SG13G2
  `cornerMOSlv.lib` survey does not automatically apply to CMOS5L.

## Flow tooling (~/venvs/asic + Docker)

- `flow/run_librelane.sh` invokes
  `ghcr.io/librelane/librelane:3.1.0.dev3` directly with
  `-p ihp-sg13cmos5l -s sg13cmos5l_stdcell`, mounting
  `PDK_ROOT=$HOME/pdk/IHP-Open-PDK`.
- The container image is not optional decoration: the CMOS5L PDK is written
  against the LibreLane 3.1 development line. SG13G2-era 3.0.x images must not
  be used for CMOS5L signoff.
- Native tools on PATH (yosys, openroad, klayout, magic, ngspice, verilator,
  iverilog) cover the standalone synthesis/STA/SPICE side-quests.
  `regress/synth_area.sh` and `regress/sram_model.sh` resolve the CMOS5L tree
  under `~/pdk/IHP-Open-PDK`. Current mapped counts are in
  [[reference/block-diagram]]; signoff state is in [[STATUS]].
  `regress/synth_area.sh --out DIR` writes per-block JSON, Verilog and Yosys
  logs under `DIR`; it refuses a `DIR` inside the repo, so synthesis artifacts
  never enter git.
- **Host `netgen` is not LVS.** `/usr/bin/netgen` on this host is Schoeberl's
  3D tetrahedral mesher and hangs on `-batch`; the LVS netgen is inside the
  LibreLane container (1.5.320). Do not point the flow at host netgen.
- `volare` still has the SG13G2 family (`ihp_sg13g2`); the CMOS5L installation
  path is the Tiny Tapeout git pin, not a volare family install.

## Historical SG13G2 results

Every routed/STA number recorded before 2026-10-18 in `reviews/` and
`wiki/STATUS.md` was produced against `ihp-sg13g2` + `sg13g2_stdcell`. Those
numbers are evidence about the SG13G2 proxy, not about the CMOS5L shuttle.
They are retained as history; the CMOS5L reruns supersede them.

## Lessons

- AUR installs must run as the user; passwordless sudo covers paru's internal
  sudo calls.
- Non-interactive shells emit `stty`/`tcsetattr` noise and bashrc `sort -hn`
  errors — cosmetic; check the real exit state of the payload command.
- The PDK's `libs.ref` paths and `libs.tech` config both carry the process name
  (`sg13cmos5l_*`). A `sg13g2_*` cell name in a netlist, script or report is a
  signal that a stale library was used.
