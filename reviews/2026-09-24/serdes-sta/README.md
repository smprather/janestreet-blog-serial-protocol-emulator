# serdes-sta — mapped STA hold-attribution screens (2026-09-24)

Raw reports for the mapped OpenSTA refresh of the SERDES+codec integration
(STATUS item 7, Task 4) and the hold-attribution rework (Task 5b).
**Mapped pre-route screens only — no placement, routing, DRC or LVS.**

Designs: `pe_soc`, `tt_um_protocol_emulator` (adds `pe_ctrl` + the pad
wrapper) and `pe_ctrl` (the recorded A1 loader screen).

Regenerate everything from the repo root:

```bash
bash reviews/2026-09-24/serdes-sta/run_sta.sh
```

## Two labelled constraint variants (both re-runnable)

| variant | tcl | report | min input/output delay |
|---|---|---|---|
| ZERO-ASSUMPTION | `sta-<design>-<corner>.tcl` | `sta-<design>-<corner>.txt` | 0 ns (recorded Task-4 screen) |
| BOARD-ASSUMPTION | `sta-<design>-<corner>-board.tcl` | `sta-<design>-<corner>-board.txt` | 1.0 ns screening floor |

The variants differ **only** in the two `-min` values; max delays, clock,
uncertainty, transition and load are identical. The 1.0 ns floor is a labelled
screening assumption (board/connector/pad skew reasoning), not a spec — see
the header of the `-board` tcl files and
`reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md`.

## Files

| file | meaning |
|---|---|
| `synth-pe_soc.ys`, `synth-tt_um.ys`, `synth-pe_ctrl.ys` | yosys mapping; source lists include `pe_serdes/pe_nrzi/pe_bitstuff/pe_codec_mux` |
| `mapped-<design>.v` | mapped netlists |
| `sta-<design>-<corner>{,-board}.tcl` | the corner × variant constraint files (3 corners × 2 variants per design) |
| `sta-<design>-<corner>{,-board}.txt` | the 18 reports; each ends with the **negative-min-slack inventory** (`report_checks -path_delay min -slack_max 0 -endpoint_path_count 4 -format summary`) |
| `analyze_hold.py` | classifies the inventory (external-input/output, removal, internal pre-CTS, internal-within-uncertainty) |
| `hold-attr-analysis.txt` | analyzer output for all nine zero/board pairs |
| `probe-<design>-<corner>.tcl/.txt` | Task-4 supplementary class probes (overlay→pad, `half_phase`, window, split enables) |
| `preint-*` | pre-integration `pe_soc` control |
| `synth-*.log` | yosys logs (known benign warnings only) |

## Result summary (Task 5b)

Worst setup is unchanged in every zero/board pair; the board variant's min
delays only move min paths.

| design | corner | ZERO setup/hold | BOARD setup/hold |
|---|---|---|---|
| `pe_soc` | slow/typ/fast | 0.00 / −0.87, −0.61, −0.48 | 0.00 / −0.54, −0.41, −0.36 |
| `tt_um_top` | slow/typ/fast | 0.00 / −0.71, −0.52, −0.43 | 0.00 / −0.64, −0.48, −0.40 |
| `pe_ctrl` | slow/typ/fast | 8.71, 8.80, 8.86 / −0.12, −0.16, −0.19 | 8.71, 8.80, 8.86 / +0.04, −0.07, −0.13 |

Under the 1.0 ns board assumption every external-input (data and `rst_n`
removal) and external-output negative min path becomes MET in all nine
screens; the remaining negatives are internal pre-CTS hold paths (worst
−0.5353 `pe_soc` slow, −0.6380 `tt_um` slow) and paths entirely inside the
0.25 ns hold uncertainty. Internal pre-CTS negatives are the class the routed
flow's CTS + hold repair closes (recorded routed SoC: +0.1209 ns hold,
0 violating paths). Full tables and the read-only input-registration audit:
`reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md`.
