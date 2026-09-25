# Hold-screen attribution and board-assumption variants — 2026-09-24

Recorded 2026-09-24 14:10 CDT (19:10 UTC), `date`-stamped. Task 5b: make the
mapped STA screens honest about hold. No RTL was changed.

Every number here is a **mapped, pre-CTS screen** — ideal clock, no placement,
no routing, no hold repair — and any "MET" claim is scoped to the stated
constraint variant.

## 1. What changed

- The recorded zero-assumption screens are kept and explicitly labelled
  (`sta-<design>-<corner>.tcl`, header "VARIANT: ZERO-ASSUMPTION").
- A board-assumption variant was added alongside
  (`sta-<design>-<corner>-board.tcl`, header "VARIANT: BOARD-ASSUMPTION"):
  the only difference is `set_input_delay -min` and `set_output_delay -min`
  go from **0.0 ns to 1.0 ns**; every max delay stays at the recorded
  3.3334 ns.
- All 18 screens (3 designs × 3 corners × 2 variants) now end with a full
  **negative-min-slack inventory** (`report_checks -path_delay min
  -slack_max 0 -group_path_count 1000 -endpoint_path_count 4 -format
  summary`), so nothing is hidden in the top-5 path display.
  `analyze_hold.py` classifies the inventory; raw output:
  `reviews/2026-09-24/serdes-sta/hold-attr-analysis.txt`.
- A `pe_ctrl` screen set was added (`synth-pe_ctrl.ys`, `mapped-pe_ctrl.v`)
  so the recorded A1 loader screen is re-runnable under both variants.

Run both variants from the repo root:

```bash
bash reviews/2026-09-24/serdes-sta/run_sta.sh
# zero  -> sta-<design>-<corner>.txt
# board -> sta-<design>-<corner>-board.txt
```

## 2. The 1.0 ns assumption (labelled an assumption, not a spec)

A same-board source-synchronous launch is assumed to arrive at the pad **no
earlier than 1.0 ns** after its reference clock edge, and an external
receiver's hold window is assumed to start no earlier than 1.0 ns after the
edge (the matching output-side treatment). Screening budget floor:

| component | screening estimate |
|---|---|
| driver / level-shifter launch skew | ~0.1–0.2 ns |
| 5–10 cm FR-4 microstrip at ~6.7 ns/m | ~0.33–0.67 ns |
| header / connector / protection | ~0.1–0.3 ns |
| pad-ring input | ~0.1–0.2 ns |
| **floor used** | **1.0 ns** |

This is a floor for the earliest arrival used to keep hold checks meaningful;
it is **not** a measured board flight time and not a datasheet number. The
0.25 ns hold uncertainty and the 3.3334 ns max delays are unchanged screening
numbers. Every board-variant MET claim is conditional on this 1.0 ns floor.

## 3. Attribution rules

The inventory rows are classified by startpoint/endpoint and by the applied
screening uncertainty:

| class | rule | meaning |
|---|---|---|
| external-input assumption artifact (data) | startpoint is a direct input port | 0 ns min input delay makes the launch land at the edge; the board variant fixes it |
| external-input assumption artifact (rst_n removal) | `rst_n → */RESET_B` removal check | same zero-delay artifact on the async reset input |
| external-output assumption artifact | endpoint is an output port | 0 ns min output delay; the matching 1.0 ns output treatment fixes it |
| clock-uncertainty / screening artifact ("internal-within-unc") | internal flop/latch path with `slack + 0.25 >= 0` | the negative slack is entirely inside the applied 0.25 ns hold uncertainty |
| internal reg-reg path ("pre-CTS") | internal flop/latch path beyond the uncertainty | a real mapped/ideal-clock hold path; the routed flow's CTS + hold repair closed these (recorded routed SoC: +0.1209 ns hold, 0 violating paths, all corners) |

## 4. Worst setup / hold, both variants

Slow is also the hold corner; hold is reported at all corners.

| design | corner | ZERO setup | ZERO hold | BOARD setup | BOARD hold |
|---|---|---|---|---|---|
| `pe_soc` | slow | 0.00 | **−0.87** | 0.00 | **−0.54** |
| `pe_soc` | typ | 0.00 | **−0.61** | 0.00 | **−0.41** |
| `pe_soc` | fast | 0.00 | **−0.48** | 0.00 | **−0.36** |
| `tt_um_top` | slow | 0.00 | **−0.71** | 0.00 | **−0.64** |
| `tt_um_top` | typ | 0.00 | **−0.52** | 0.00 | **−0.48** |
| `tt_um_top` | fast | 0.00 | **−0.43** | 0.00 | **−0.40** |
| `pe_ctrl` | slow | 8.71 | **−0.12** | 8.71 | **+0.04** |
| `pe_ctrl` | typ | 8.80 | **−0.16** | 8.80 | **−0.07** |
| `pe_ctrl` | fast | 8.86 | **−0.19** | 8.86 | **−0.13** |

**Worst setup is unchanged in every pair** (the min side of the constraints
cannot move a max path). The board variant's remaining negative holds are no
longer external-input artifacts; they are internal paths (below). Under the
board assumption `pe_ctrl` is hold-clean at slow.

## 5. Attribution of the negative min slacks

Zero variant, per design/corner (paths / worst slack; full detail in
`serdes-sta/hold-attr-analysis.txt`):

| design/corner | external-input (data) | external-input (removal) | external-output | internal pre-CTS | internal within-unc |
|---|---|---|---|---|---|
| `pe_soc` slow | 120 / −0.8692 (`host_wdata[0]`→imem `A_DIN[0]`) | 643 / −0.0490 | — | 71 / −0.5353 (`_5324_`→fbuf `A_ADDR[4]`) | 1 / −0.2467 |
| `pe_soc` typ | 126 / −0.6065 (`host_addr[1]`→imem `A_ADDR[1]`) | 643 / −0.1230 | 32 / −0.0521 (`dbg_pc[7]`) | 70 / −0.4133 | 26 / −0.2499 |
| `pe_soc` fast | 126 / −0.4778 | 643 / −0.1637 | 69 / −0.1149 | 70 / −0.3596 | 735 / −0.2467 |
| `tt_um` slow | 95 / −0.7106 (`ui_in[1]`→imem `A_ADDR[4]`) | 739 / −0.0490 | — | 104 / −0.6380 (`_4333_`→imem `A_DIN[10]`) | 0 |
| `tt_um` typ | 109 / −0.5234 | 739 / −0.1230 | 16 / −0.0523 (`uio_out[4]`, the A1 echo) | 104 / −0.4761 | 34 / −0.0664 |
| `tt_um` fast | 111 / −0.4282 | 739 / −0.1637 | 32 / −0.1151 (`uio_out[4]`) | 104 / −0.3951 | 753 / −0.1268 |
| `pe_ctrl` slow | 8 / −0.1153 (`run`→flop `_652_/D`) | 112 / −0.0490 | — | — | — |
| `pe_ctrl` typ | 22 / −0.1569 (`run`→`_652_/D`) | 112 / −0.1230 | 88 / −0.0523 (`spi_miso`) | — | 7 / −0.0664 |
| `pe_ctrl` fast | 50 / −0.1864 | 112 / −0.1637 | 91 / −0.1151 (`spi_miso`) | — | 324 / −0.1268 |

Board variant: **every external-input, removal and external-output class drops
to 0 paths in all nine screens** (they become MET under the 1.0 ns floor).
Only the internal classes remain:

| design/corner | internal pre-CTS (worst) | internal within-unc (worst) |
|---|---|---|
| `pe_soc` slow / typ / fast | −0.5353 / −0.4133 / −0.3596 | −0.2467 / −0.2499 / −0.2467 |
| `tt_um` slow / typ / fast | −0.6380 / −0.4761 / −0.3951 | −0.2057 / −0.2187 / −0.2309 |
| `pe_ctrl` slow / typ / fast | — | — / −0.0664 / −0.1268 |

Two honest notes about the board variant:

- The internal **worst** values are identical across variants (the paths are
  the same); the board run reveals *more* internal paths because the
  zero run's per-endpoint inventory was dominated by external paths at the
  same endpoints. Example: `tt_um` fast within-unc goes from a
  −0.1268 "worst" to −0.2309 once the external paths no longer crowd it out.
  The board inventory is therefore the more honest internal view.
- The internal reg-reg worst at slow is a flop→SRAM-macro pin path
  (`_5324_ → u_eth_fbuf.../A_ADDR[4]`, library hold 0.7767 ns). It is a
  pre-CTS mapped artifact; the routed SoC run (CTS + hold repair) recorded
  +0.1209 ns hold with 0 violating paths at all three corners.

The recorded `reviews/2026-09-24/manager-a1-sta/` pe_ctrl screen is
reproduced by the new zero screens: its visible negatives are all
external-input artifacts (`run`→flops, `run`→`host_we`/`load_active`,
`rst_n` removal); the new inventory additionally surfaces the `spi_miso`
output min paths and the internal synchronizer paths that the top-5 display
had hidden.

The Task-4 supplementary reports in this directory classify the same way:
in `probe-*-fast.txt` the `min-to-pads` negatives (`pin_out`, `uio_out[4]`,
`uo_out[4]/[7]`) are external-output artifacts, the `half_phase` and
`win_regs` negatives are internal paths inside the 0.25 ns uncertainty, and
the removal/data rows are external-input artifacts; in
`preint-pe_soc-fast-pads.txt` the `min-to-pads` −0.1026 is an external-output
artifact (and pre-dates the integration).

## 6. Input-registration audit (read-only; no RTL changed)

Every direct input, its RTL destination, whether it reaches a flop without a
synchronizer/register, and the options. **No RTL was modified in this task.**

| direct input | screened in | destination in RTL | registered? | option |
|---|---|---|---|---|
| `rst_n` | all three | async `RESET_B` pins across the design | no (reset distribution, by design) | constraint-only today (removal/recovery + board min delay); RTL reset-synchronizer is the registration option |
| `run` | `pe_soc` (`u_cpu.run`), `pe_ctrl` (load FSM / `host_we` mask), `tt_um` via `ui_in[1]` | CPU state flops; loader FSM next-state logic | no synchronizer | board min-delay constraint now; RTL 2FF synchronizer is the option (host strap, static between operations) |
| `host_we`, `host_imem_sel`, `host_addr[14:0]`, `host_wdata[15:0]` | `pe_soc` (at the TT top these are driven by `pe_ctrl` on the same clock) | imem write port (`A_WEN`/`A_ADDR`/`A_DIN`), dmem write, fbuf/CPU data muxes | no register | constraint-only now (board min delay); RTL host-port register stage is the option (costs a load cycle) |
| `pin_in[7:0]` | `pe_soc` (`tt_um`: `ui_in[0]`→pin 3, `ui_in[2]`→pin 7, `uio_in[0:1]`→pins 4/5) | `pe_pinmux` read mux (`A_IN: rdata = pad_in`) → CPU IO read flops | pin 7: 2FF + latch pair in `pe_dru`; pins 0–6: none | plain pins: board min delay now; RTL read-lane registration is the option (adds a read cycle) |
| `spi_sclk`, `spi_mosi`, `spi_cs_n` | `pe_ctrl` (`tt_um`: `ui_in[3:5]`) | 2FF synchronizers `sclk_s0/s1`, `mosi_s0/s1`, `cs_s0/s1` + edge detectors; MOSI is sampled on the re-timed SCLK edge | **yes** | constraint-only is correct: false-pathed (documented in the tcl) because they are not `clk`-synchronous; no RTL change needed |
| `ena` | `tt_um` | gates nothing (documented) | n/a | none |

## 7. Evidence

- `reviews/2026-09-24/serdes-sta/sta-<design>-<corner>{,-board}.tcl` — both
  labelled variants; `-board` differs only in the two `-min` values.
- `reviews/2026-09-24/serdes-sta/sta-<design>-<corner>{,-board}.txt` — the
  18 reports (each with setup/hold worst slacks, check types, and the
  negative-min inventory).
- `reviews/2026-09-24/serdes-sta/hold-attr-analysis.txt` — analyzer output
  for all nine zero/board pairs.
- `reviews/2026-09-24/serdes-sta/analyze_hold.py` — the classifier.
- `reviews/2026-09-24/serdes-sta/synth-pe_ctrl.ys`, `mapped-pe_ctrl.v` — the
  new pe_ctrl netlist.
- `reviews/2026-09-24/serdes-sta/run_sta.sh` — reruns all 3 designs × 3
  corners × 2 variants.

## 8. Limits

- Mapped, pre-CTS, ideal clock; no hold repair, no routing parasitics. Not
  signoff.
- The 0.25 ns hold uncertainty stays in both variants; the
  "internal-within-unc" class exists precisely because of it.
- The 1.0 ns board floor is a screening assumption, not a measured board
  flight time; a board-level characterisation would replace it. All board
  MET claims are conditional on it.
- Removal checks are asynchronous-reset checks; the board min delay is a
  screening treatment, not a reset-synchronizer design.
- No RTL, no regression rerun, no physical flow / DRC / LVS.
  `wiki/plans/demo-host-gui.md` and `/tmp/opencode/` were not touched.
