# Full-SoC place-and-route — 2026-11-10

Run: `~/asic-runs/pe_soc/runs/RUN_2026-11-10_19-21-35`
Config: `flow/pe_soc.json` (`ihp-sg13cmos5l` + `sg13cmos5l_stdcell`)
Image: `ghcr.io/librelane/librelane:3.1.0.dev3`
Die: 1616 × 620 µm (8×4 at 202×155 µm/tile)
Wall time: 2456.78 s (~41 min)
Flow result: exit 1 at the Netgen LVS step (73/80)

## What completed

| Stage | Result |
|---|---|
| Synthesis / placement / CTS | completed |
| Global + detailed routing | **0 route DRC**, 0 antenna violations |
| KLayout streamout | `58-klayout-streamout/pe_soc.gds` |
| KLayout XOR | 0 differences |
| Power grid | 0 violations; VPWR/VGND fully connected (`PSM-0040`) |
| KLayout DRC | 2,491 errors, all one rule: `M4.b` |
| Magic DRC | 256,864 errors |
| Magic illegal overlap | 3,090 errors |
| LVS | **FAILED** — top-level pin matching |

The KLayout count is a single rule (`M4.b`); the detailed router itself reports
zero DRC. These are consistent with the vendor SRAM macro's known geometric
false positives, not with unrouted signal geometry, but this run did not rerun
the macro-alone DRC comparison.

## Area

| Measure | Value |
|---|---:|
| Die | 1,001,920 µm² |
| Core | 945,941 µm² |
| Instance area | 924,487 µm² |
| Standard-cell area | 149,739 µm² |
| Macro area (2 × 1 KB SRAM) | 159,347 µm² |
| Fill area | 615,401 µm² |
| Utilization | 32.675% |
| Standard-cell utilization | 19.036% |
| Standard cells | 9,648 |
| Sequential cells | 1,118 |
| Macros | 2 |

## Timing (post-route, SPEF)

| Corner | Setup WNS | Setup TNS | Hold WNS |
|---|---:|---:|---:|
| `nom_slow_1p08V_125C` | **−2.296 ns** | **−74.224 ns** | +0.625 ns |
| `nom_typ_1p20V_25C` | 0 | 0 | +0.291 ns |
| `nom_fast_1p32V_m40C` | 0 | 0 | +0.103 ns |

Slow-corner setup violations: **105 paths**. The worst paths are all the
instruction SRAM read path:

- `u_imem.g_macro.u_sram/A_DOUT[14] -> dbg_next_pc[5]`: **−2.296 ns**
- `A_DOUT[14] -> dbg_next_pc[4..0]`: −2.258 to −1.992 ns
- `A_DOUT[0] -> _11105_/D`: −1.374 ns (reg-to-reg)

Hold is clean at all three corners. The slow corner also reports 15 max-slew,
4 max-cap and 95 max-fanout violations; typ/fast report 7 max-slew, 4 max-cap,
95 max-fanout. The flow also reports 74 unannotated nets.

## LVS

Netgen compared 9,654 devices on both sides, but:

- Circuit 1 (netlist): **9,730 nets**
- Circuit 2 (layout): **9,731 nets**
- 6 disconnected pins on each side
- Final result: **`Top level cell failed pin matching.`**

The net diff is on the SRAM power pins: the layout's `VPWR` net carries
`RM_IHPSG13_1P_1024x16_c2_bm_bist/\VDD!` and `\VDDARRAY!`, while the netlist side
does not represent those power pins. Signal nets otherwise line up in the report.
This is a macro power-pin/LVS-model issue to resolve, not evidence of a signal
short.

After LVS, LibreLane aborted while parsing netgen's stats JSON:

```
json.decoder.JSONDecodeError: Invalid \escape: line 1245 column 54
```

That is a flow/tool parser failure after the LVS verdict, not the LVS failure
itself.

## Power

| Measure | Value |
|---|---:|
| Internal | 4.353 mW |
| Switching | 0.953 mW |
| Leakage | 0.0397 mW |
| **Total** | **5.346 mW** |

## Where this leaves the design

1. **Area is comfortable.** The full SoC, both SRAM macros and fill use 32.7% of
   the confirmed 8×4 die; standard cells alone use 19.0%.
2. **Routing is clean.** Detailed routing, antenna and XOR all pass.
3. **Timing is the main functional blocker at 60 MHz.** The SRAM read path
   (`A_DOUT -> next-PC/debug logic`) misses slow-corner setup by 2.3 ns. The
   previous SG13G2 full-SoC signoff did not exercise this exact CMOS5L macro +
   netlist combination.
4. **LVS needs the macro power-pin model fixed.** The layout/netlist net-count
   difference is on `VDD!`/`VDDARRAY!`, not on a signal net.
5. **DRC is still a macro-geometry question.** KLayout's 2,491 `M4.b` errors
   should be compared against the macro alone before treating them as ours; the
   router itself is clean.

No RTL, SDC or flow config was changed by this run.

## Targeted post-CTS ECO — 2026-11-10

Run: `~/asic-runs/pe_soc/runs/eco_failpaths` and
`~/asic-runs/pe_soc/runs/eco_failpaths_sta`.

The closest supported operation to "rip up placement and route except the clock
tree, then target only the failing paths" is a post-CTS ECO: start from
`35-openroad-cts/state_out.json`, keep the clock tree and placement, rerun
`OpenROAD.ResizerTimingPostCTS` with `PL_RESIZER_SETUP_MAX_BUFFER_PCT=100` and
`PL_RESIZER_SETUP_SLACK_MARGIN=0.0`, then global route and detailed route, then
RCX and post-route STA. OpenROAD has no selective placement rip-up primitive.

Result: **no timing change.**

| Measure | Original run | Post-CTS ECO |
|---|---:|---:|
| Slow setup WNS | −2.296 ns | **−2.296 ns** |
| Slow setup TNS | −74.224 ns | **−74.224 ns** |
| Setup violations | 105 | **105** |
| Hold WNS (worst) | +0.103 ns | +0.103 ns |
| Route DRC | 0 | 0 |
| Stdcell area | 149,739 µm² | 149,739 µm² |
| Hold buffers | 1,582 | 1,582 |

The resizer found 8 setup endpoints and inserted 3 buffers, then 1,120 hold
endpoints and 1,582 hold buffers. The resulting netlist and route reproduced the
original cell counts and the identical worst path. That is the controlled result:
the failing paths are not routing-limited, and re-running placement/route/repair
on the same netlist does not recover the 2.296 ns. The interconnect on the worst
path is ~0.05 ns of a 14.63 ns arrival.

The next real lever is the path itself: a registered SRAM-read stage, a reduced
clock, or a relaxed debug-output constraint. Rerouting cannot do it.

## Path-only what-if — 2026-11-10

Question: if the failing paths were the only paths in the world, can they meet
timing?

Two sandboxes were built from the failing-path cell set (the union of instances
in the 105 slow-corner paths), keeping the SRAM macros and CTS cells fixed,
deleting every other cell, unplacing the path cells, and re-placing/re-routing
them:

- `~/asic-runs/pe_soc/path_only` — post-CTS netlist (`35-openroad-cts`).
- `~/asic-runs/pe_soc/path_only5` — post-route netlist (`52-openroad-fillinsertion`),
  which includes the resizer-inserted buffers on the real failing path.

The post-CTS sandbox met the SRAM read path with **+3.02 ns** slack:

```
A_DOUT[14]       7.52 ns
_07081_/Y        0.33 ns
place1879/X      0.31 ns
_07130_/Y        0.17 ns
output82/X       0.15 ns
arrival          9.31 ns
required        12.33 ns
slack           +3.02 ns
```

The full design's same endpoint had 14.63 ns arrival because the resizer's
buffer chain added `fanout475` (0.859 ns), `fanout357` (1.077 ns), `fanout355`
(0.422 ns), and the NAND4 input slew reached 3.316 ns. The isolated path has no
such load/slew. This is the what-if answer: the SRAM read path is not inherently
a 60 MHz path; the full design's fanout and buffer chain make it one.

Caveat: the post-CTS sandbox does not include the resizer buffers that the real
failing path has, so it is not a like-for-like comparison. The fair version
starts from the post-route ODB (`52-openroad-fillinsertion`), keeps the
instruction SRAM macro, the clock tree and every clock sink fixed, deletes all
other cells, unplaces the path combinational cells, and re-places/re-routes
them. That sandbox is **inconclusive**: the attempts that cleared clock guides
failed detailed-route connectivity on dangling clock nets (`DRT-0206`,
`DRT-0222`), and the version that kept every clock sink (`path_only9`) reached
detailed routing but failed pin access (`DRT-1231`, `_10815_/A1` has no access
point). The post-CTS sandbox is the only completed what-if.

Neither sandbox is a valid chip or signoff.

## Pure STA with average net delay and observed skew — 2026-11-10

Script and reports: `~/asic-runs/pe_soc/pure_sta/`.

Method: post-route netlist (`52-openroad-fillinsertion/pe_soc.nl.v`), slow
corner liberty, no SPEF. Every non-clock net gets the measured average net
delay from the first run's slow-corner paths: **5.65 ps** (26,523 net arcs,
median 1.58 ps, max 1.83 ns). The first run's observed clock skew was
**0.3227 ns** (rise) / 0.3130 ns (fall); it is added to the existing
uncertainty split, giving setup 1.323 ns and hold 0.573 ns.

Results:

| Check | Worst | Endpoint |
|---|---:|---|
| Setup | **0.00 ns** | `pin_in[7] -> _11071_/D` |
| SRAM read `A_DOUT[14] -> dbg_next_pc[5]` | **+2.27 ns** | output |
| SRAM read `A_DOUT[12] -> _11105_/D` | **+2.03 ns** | register |
| Hold | **−0.82 ns** | `_11050_/Q -> u_imem.../A_ADDR[1]` |

The failing setup paths close in this model: cell delay plus 5.65 ps per net
plus 0.323 ns skew leaves ~2 ns on the SRAM read. The hold result is not
directly comparable to the PnR run: with an ideal clock and a uniform 0.573 ns
hold uncertainty, the SRAM input hold paths are over-penalized; the real
propagated-clock run had +0.625 ns hold slack. Treat the pure-STA hold number
as a conservative skew-budget screen, not a signoff result.

The important caveat remains: this model adds net delay as a constant and does
not model the net-load/slew degradation that made the full-design NAND4 3.06 ns
instead of 0.33 ns. It answers the cell-delay question, not the full physical
question.

## `fanout475` buf_1 → buf_8 — 2026-11-10

Netlist ECO only, no placement/routing change: `fanout475` in
`~/asic-runs/pe_soc/buf8/pe_soc_buf8.nl.v` changed from
`sg13cmos5l_buf_1` to `sg13cmos5l_buf_8`; same SPEF, same SDC, slow corner.

| Measure | buf_1 | buf_8 |
|---|---:|---:|
| Slow setup WNS | −2.296 ns | **−1.300 ns** |
| `fanout475` delay | 0.859 ns | **0.260 ns** |
| NAND4 input slew | 1.007 ns | **0.150 ns** |
| NAND4 delay | 3.057 ns | **2.650 ns** |
| NAND4 output slew | 3.316 ns | 3.300 ns |
| Path arrival | 14.630 ns | **13.640 ns** |

The swap recovers **0.996 ns**. The next limiter is the NAND4 `_07081_` itself:
its output still slews at 3.30 ns into `fanout357`/`fanout355`. A legal physical
swap also needs a footprint/legalization check; this was STA-only.

### NAND4 drive variants

The CMOS5L standard-cell library has only **one** 4-input NAND drive:
`sg13cmos5l_nand4_1`. There is no `nand4_2` or `nand4_4` in the Liberty or LEF,
so the requested direct drive swap is unavailable.

Closest valid experiment: keep `nand4_1` and insert a `buf_2` / `buf_4` after
it, moving the three loads (`_07109_/B`, `_07112_/A1`, `fanout357/A`) to the
buffer output. Same SPEF/SDC:

| Variant | Slow setup WNS | NAND4 delay | NAND4 output slew | Buffer delay |
|---|---:|---:|---:|---:|
| `buf_1` (baseline) | **−1.300 ns** | 2.650 ns | 3.300 ns | — |
| NAND4 + `buf_2` | −1.490 ns | 2.640 ns | 3.290 ns | 0.600 ns |
| NAND4 + `buf_4` | −1.480 ns | 2.640 ns | 3.290 ns | 0.590 ns |

Both proxies are **worse** than the direct path. The NAND4 output slew barely
moves because the cell itself is the weak driver; the extra buffer adds a
0.6 ns stage. A real fix needs a stronger NAND4 (not in this library), a logic
restructure, or splitting the NAND4's fanout differently.

## All timing fixers enabled — 2026-11-11

Run: `~/asic-runs/pe_soc/runs/RUN_2026-11-11_17-01-21` (~38 min).
Config: `flow/pe_soc.json` with

```text
PL_TIMING_DRIVEN               = true
RUN_POST_CTS_RESIZER_TIMING    = true
RUN_POST_GPL_DESIGN_REPAIR     = true
RUN_POST_GRT_DESIGN_REPAIR     = true
RUN_POST_GRT_RESIZER_TIMING    = true
```

Both previously skipped post-GRT stages ran. The post-GRT resizer found 2 setup
endpoints, inserted 3 buffers and swapped pins on 2 instances, but still
reported “Unable to repair all setup violations.”

| Measure | 2026-11-10 (post-CTS only) | 2026-11-11 (all fixers) |
|---|---:|---:|
| Slow setup WNS | −2.296 ns | **−1.138 ns** |
| Slow setup TNS | −74.224 ns | **−5.049 ns** |
| Setup violations | 105 | **9** |
| Hold | clean | clean |
| Route DRC | 0 | **0** |
| Stdcell area | 149,739 µm² | 148,881 µm² |

The original worst path is fixed: `A_DOUT[14] -> dbg_next_pc[5]` is no longer
on the violator list; the worst output path is now `dbg_next_pc[7]` at
−0.088 ns.

The remaining worst path is a different one:

```text
A_DOUT[1] -> _11105_/D : -1.138039
A_DOUT[1] -> _11091_/D : -0.930571
A_DOUT[1] -> _11104_/D : -0.778510
A_DOUT[1] -> _11090_/D : -0.619979
...
```

It is a long reg-to-reg combinational cone from `A_DOUT[1]`: SRAM read 7.689 ns,
then buffer chain, NAND4 `_06249_` 1.457 ns, NOR4 `_06311_` 1.182 ns, and eight
more logic stages; arrival 17.528 ns against required 16.390 ns. The fixers
recovered 1.158 ns of WNS and 92% of the violating paths, but the remaining
9 paths still need a logic/drive change. A custom higher-drive NAND4/NOR4 is now
a plausible next step; no custom cell was required to get this far.

LVS is unchanged: top-level pin matching fails on the SRAM power pins and
LibreLane aborts in the netgen-stats JSON parser. KLayout DRC remains 2,491
(`M4.b`), Magic 256,866, route DRC 0.
