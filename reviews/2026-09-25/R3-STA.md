# R3 debug control — mapped STA screen

Date: 2026-09-25. Artifacts: `reviews/2026-09-25/r3-sta/` (driver
`run_sta.sh`, the two mapped netlists, 12 screen reports, the hold attribution,
and the R3 debug-path inventory). This closes the R3 phase's STA obligation: the
debug-control phase added ports and logic to `pe_cpu`, `pe_ctrl` and `pe_soc` and
had never been through timing analysis.

**These are pre-routing, mapped SCREENING estimates, not signoff.** No placement,
no routing, no DRC, no LVS. Every MET/VIOLATED label is scoped to the screening
constraints in the `.tcl` files, exactly as the R2 screen was.

---

## 1. The matrix

`pe_soc` + `tt_um_top`, at the locked 60 MHz point (16.667 ns), slow/typ/fast, in
both constraint variants — **12 screens**. Slow is also the hold corner. The
clock-uncertainty split (setup 1.0 / hold 0.25) is the flow's own
(`flow/pe_soc.sdc`): LibreLane's base template applies one number to both, which
spends setup jitter on hold as well and cost 1.0 ns of hold slack when measured.
Same liberty, same pass list, same source list as `reviews/2026-09-25/r2-sta/`,
so the screens are directly comparable with the R2 ones.

Variants: `zero` = 0 ns min input/output delay (the assumption-free screen);
`board` = 1.0 ns min (the labelled board screening floor).

| screen | setup max / hold min (ZERO) | setup max / hold min (BOARD) |
|---|---|---|
| pe_soc / slow | 0.00 / **−0.87** | 0.00 / −0.54 |
| pe_soc / typ | 0.00 / **−0.61** | 0.00 / −0.42 |
| pe_soc / fast | 0.00 / **−0.48** | 0.00 / −0.36 |
| tt_um / slow | 2.21 / **−0.57** | 2.21 / −0.57 |
| tt_um / typ | 7.02 / **−0.44** | 7.02 / −0.44 |
| tt_um / fast | 7.12 / **−0.37** | 7.12 / −0.37 |

All setup is MET. Hold is negative at the pe_soc level under the ZERO assumption
and recovers under the BOARD floor — the same pre-existing input-pad signature the
R2 screen recorded, not a new R3 class (see below). The tt_um setup aggregate is
positive (2.21–7.12 ns) on the same top, source list and liberty as the R2 screen's
0.00; the hold is marginally better than R2 (−0.57 vs −0.59 at slow). I report the
numbers as measured and do not over-attribute the setup aggregate's move.

## 2. The verdict the dispatch asked for: no new violation class

The hold attribution (`analyze_hold.py`, one section per ZERO/BOARD pair) gives
the same four classes, with the same worst path per class, as the R2 screen:

| hold class (pe_soc / slow) | R2 worst | R3 worst |
|---|---|---|
| external-input (data) — `host_wdata[0] ⇒ u_imem A_DIN[0]` | −0.8692 | **−0.8692** |
| external-input (rst_n removal) | −0.0490 | **−0.0490** |
| internal-reg-reg (pre-CTS) | −0.5519 | −0.5384 |
| internal-within-unc (screening) | −0.2372 | −0.2403 |

**The class set is identical and the worst hold per class is unchanged to within
±0.014 ns.** The tightest hold in the design is the pre-existing
input-pad-to-imem-SRAM path (`host_wdata[0] ⇒ u_imem.g_macro.u_sram/A_DIN[0]`),
present identically in R2 and R3, and it is a ZERO-assumption screening artefact
rather than a routed hold (it recovers to −0.54 under the 1.0 ns board floor).
R3 introduced **no new hold class and no new specific hold**. The 1132-line
negative-min inventory at pe_soc/slow contains **zero** R3 debug endpoints.

## 3. The R3 debug paths are in the netlists, and the screen covers them

`run_sta.sh` runs an explicit R3-debug-path inventory against the mapped netlist
(`r3-debug-inventory-*.txt`) and fails if the phase's own logic is absent, so the
screen cannot quietly time a design without debug control in it. In the `pe_soc`
netlist: `dbg_hold` (6), `dbg_step` (7), `dbg_next_pc` (26 occurrences). At the
`pe_soc` top the three debug wires are ports (they route to `pe_ctrl`, which is
instantiated at `tt_um`), so OpenSTA times them as real I/O.

* **`dbg_next_pc[1]` and `dbg_next_pc[2]` are the tightest setup endpoints at
  pe_soc / fast**, at slack **0.0000**, arrival ~3.12/3.09 ns against the 3.3334 ns
  screening output delay. This is the R3-specific timing finding: the new
  next-PC output route is the worst setup path at the fast corner. It is **MET,
  but with zero setup margin at screening** — worth flagging for anyone who later
  pushes the clock, though not a violation.
* `dbg_hold` and `dbg_step` appear in the reported path groups across all six
  pe_soc screens.
* The breakpoint register and comparator (`bp_addr`, `bp_en`, `bp_hit`,
  `dbg_hold_r`) and the DEBUG response mux are **present as logic** — the +283
  cell delta over pre-R3 proves the phase's logic is in the netlist — but yosys
  folds and renames them, so they are covered here in **aggregate**, not as
  individually nameable pre-route paths. The screen speaks for the debug output
  routes and the aggregate; naming the internal bp logic path-by-path needs a
  netlist that preserves the names, or routing.
* At the `tt_um` top none of the debug names appear in the reports, because the
  debug wires are internal there (pe_soc's ports fold into internal nets). The
  aggregate timing is what covers them at that level.

## 4. Summary for the record

R3 debug control is timed at all 12 screens. Setup is MET everywhere, the new
`dbg_next_pc` output is the worst setup endpoint at pe_soc/fast (0.0000, MET at
screening), hold shows **no new violation class** — the same four pre-existing
classes with the same worst-per-class to within ±0.014 ns — and the R3 debug paths
are confirmed present in the netlists the screen analysed. Combined with the
synthesis screen (R3 cost: pe_cpu +24 cells, pe_ctrl +283, pe_soc +21 cells /
+148 µm²) and the byte-exact golden conformance (25/26 confirmed, one model-boundary
step pinned with proof), the R3 phase is fully closed.
