# E2 resolution — both SRAM macros placed and power-hooked; gate added

**Finding:** E2 (P1) in `reviews/2026-09-23/ETHERNET-SOC-REVIEW.md`, static
config review at `9a84c6e` (unchanged by the E1 fix).
**Status:** fixed at the config level. `flow/pe_soc.json` now places both SRAM
instances and hooks all supplies of both, and a regression gate re-derives the
requirement from the netlist so the omission cannot return. Physical flow, DRC
and LVS were not run (standing restriction).

## Root cause

The synthesized SoC contains two macro instances —
`u_imem.g_macro.u_sram` and `u_eth_fbuf.g_macro.u_sram` — but the flow config
listed only the instruction macro:

- `MACROS.RM_IHPSG13_1P_1024x16_c2_bm_bist.instances` named only `u_imem`, and
  LibreLane's manual macro placement consumes configured instances only, so the
  frame buffer had no legal location;
- `PDN_MACRO_CONNECTIONS` had two entries, both for `u_imem`;
- the macro's supplies (`VDD!`, `VSS!`, `VDDARRAY!`) are on Metal4 and are not
  covered by the standard-cell `VPWR`/`VGND` defaults, so the frame buffer
  would also have been left without global connections (PDN-0189 / PSM-0069).

Simulation cannot see any of this; it would have surfaced as an unplaced,
unpowered macro only when the physical flow ran.

## Fix (static configuration)

**Placement.** `MACROS...instances` now lists both, orientation `N`:

| instance | location (µm) | footprint (µm) |
|---|---|---|
| `u_imem.g_macro.u_sram` | (10, 10) | 236.8 × 336.46 → x 10–246.8, y 10–346.46 |
| `u_eth_fbuf.g_macro.u_sram` | (256.8, 10) | 236.8 × 336.46 → x 256.8–493.6, y 10–346.46 |

Both fit entirely inside the configured 1002 × 432 die with a 10 µm horizontal
gap; the flow's `PDN_CFG` macro grid is `-macro -default`, so its Metal4 stripe
set and Metal4 → TopMetal1 → TopMetal2 ladder are generated for every macro
instance, and the offsets are relative to each instance's origin.

**Supply hooks.** `PDN_MACRO_CONNECTIONS` now has four entries — `VDD!/VSS!` and
`VDDARRAY!/VSS!` for each instance:

```
u_imem\.g_macro\.u_sram      VPWR VGND VDD!       VSS!
u_imem\.g_macro\.u_sram      VPWR VGND VDDARRAY!  VSS!
u_eth_fbuf\.g_macro\.u_sram  VPWR VGND VDD!       VSS!
u_eth_fbuf\.g_macro\.u_sram  VPWR VGND VDDARRAY!  VSS!
```

`VDDARRAY!` is the array rail, on its own Metal4 stripes; it is physical-only
(absent from the Liberty pin list) and is bonded to the same 1.20 V domain here,
as the existing comments explain.

**Gate.** New `tools/checks/macro_flow_config.py`, run by `run_all.sh`, checks:

1. every hard-macro cell in the **flattened, elaborated** `pe_soc` netlist is
   named in `MACROS[type].instances`, and every configured instance exists in
   the netlist (both directions, so a rename cannot linger);
2. every instance has `VDD!`, `VDDARRAY!` and `VSS!` in its
   `PDN_MACRO_CONNECTIONS` entries;
3. every placement fits inside `DIE_AREA` and macros are at least 10 µm apart
   (using the vendor LEF's `SIZE`; the check is skipped loudly if the PDK LEF
   is absent);
4. `PDN_CFG` exists and still stripes/connects Metal4.

It found the defect and now guards it: deleting the new fbuf placement makes it
exit 1 with `u_eth_fbuf.g_macro.u_sram: no placement in ...instances`; restoring
the config makes it exit 0 with `OK (placements and supply hooks complete)`.
Yosys reports both macro cells by their config-facing names
(`u_eth_fbuf.g_macro.u_sram`, `u_imem.g_macro.u_sram`), which is exactly the key
format `MACROS.instances` uses.

## Remaining before physical signoff (deferred; not run here)

- Run the full SoC flow with the two-macro layout and confirm: both macros
  placed at the configured locations, `PSM-0040 All shapes ... connected`,
  no `PDN-0189`/`PSM-0069`, and the custom Metal4 straps actually meet the
  frame buffer's supply geometry.
- Re-check spacing, core/die budget and global-routing congestion with the
  second macro (the die is far from area-limited: two macros are ~38 % of
  1002 × 432, but only the flow's own checkers settle the geometry).
- The review's host-path hold/electrical screen failures (worst — slow
  −0.87 ns) still require constraint/interface review and physical repair;
  the SPI loader's host path should be re-screened once it lands.

## Files

- `flow/pe_soc.json` (both instances, four supply hooks, comments)
- `tools/checks/macro_flow_config.py` (new gate)
- `regress/run_all.sh` (gate wired in)
