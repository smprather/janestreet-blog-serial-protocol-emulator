# pe_ctrl readback (option A1) — implementation review — 2026-09-24

## Scope and decision

Manager decision (2026-09-24): implement `wiki/plans/pe-ctrl-readback.md`
**option A1** — one-frame word echo on MISO (`uio[4]`, free pad), strict
mode 0, host guard rate **2.5 MHz** (computed limit ~7.5 MHz at the A1
commit latch; 2.5 MHz is the chosen guard). Manager rulings on the open
host-contract items from `reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`:

- **(a) Every committed word gets an echo frame**, including the final word
  of a full 1,024-word image even when the oversize guard (or a run-abort)
  has latched `load_error`.
- **(b) Numeric SCLK low time and duty bounds** specified in the `pe_ctrl`
  header and the plan.
- **(c) The readback rate ceiling applies to every echoed frame.**
- **(d) Numeric `CS_N`→first-clock setup bound.**

TDD: directed TB cases written first and shown failing on the current RTL,
then the implementation, then the extended mutation harness. No other RTL
was touched; no physical flow, DRC or LVS was run. `wiki/plans/demo-host-gui.md`
was not touched.

## Source SHA-256 (post-implementation)

| file | sha256 |
|---|---|
| `rtl/pe_ctrl.v` | `5d37a358650859a235a94f0063a8ac87016bfc0afc08122bbd754990020163fc` |
| `rtl/tt_um_protocol_emulator.v` | `94ccbccb1ee66489da4b59a1a74c8f6ad08f2144ce98cd42f91ad7cb8384f230` |
| `tb/tb_pe_ctrl.v` | `1189464cc7af7a95a5dbed0c7a62f314308923aa24e27aff86aa818091a379c5` |
| `tb/tb_tt_um_protocol_emulator.v` | `946014219b8c6131ced06a877c17328f0a03e6f8a8eda0eb37be1c81e3af68e7` |
| `regress/mutate_ctrl_tb.sh` | `9b582a78579e19abbd4c06437b5b843bbbc5280c61c2c5764d332e24d3020233` |
| `tools/gen/pin_budget.py` | `b5488c19722134df119173b0bb5f745d814557417eb6d00a28b7e3edffb16b2e` |
| `tools/gen/signal_glossary.py` | `17079e51050b97e9c401c8374fe92ac4c69e362aca51c93800cced3a020b29fe` |
| `flow/pe_soc.json` (untouched) | `640c761e3167c4ddc0c42fcde4823e72896385bafa08b4377bf5fd2d611db653` |
| `flow/pe_soc_pdn.tcl` (untouched) | `9dc80c11aeaef816799a23ba712c0defe9b07afbeb2a18928735a00acf62992d` |

## The contract as implemented (all four rulings, numeric)

Ruling (b)/(d) — the numbers now in the `pe_ctrl` header and the plan:

| bound | value | why |
|---|---|---|
| readback SCLK, **every** echoed frame (c) | ≤ **2.5 MHz** (period ≥ 400 ns) | guard; computed A1 limits ~65 ns per-bit low phase, `H ≥ 4 clk` commit latch (~7.5 MHz) |
| minimum SCLK low phase | ≥ **100 ns (6 clk @ 60 MHz)** | detected-fall register updates ≤ 3 clk after the pad edge; host needs 3 clk + t_pad + t_setup (~65 ns) before its next sample; the commit-latched frame-boundary load needs the commit (≤ 6 clk after the 16th rise) to land first |
| `CS_N` → first rising edge (d) | ≥ **100 ns** | OE follows the synchronized CS by 2 clk; the frame-0 bit preloads at the detected `cs_fall` (+3 clk) |
| duty cycle | the computed limits assume 50%; the hard requirements are the rate ceiling and the low-phase minimum | a frequency ceiling alone cannot guarantee a low phase (the plan's 5 MHz @ 30% counterexample) |

Ruling (a) — **commit-latched echo semantics**, implemented as one rule:
`echo_word` is written at exactly one non-reset site (plus the `cs_fall`
session clear): the `W_DONE` edge where `words_written` increments. Both the
normal commit and the oversize final-word commit reach it; the `W_IDLE`,
`W_PULSE` and `W_DONE` run-abort branches never do. The serializer
(`sclk_fall`-driven, 16 falls per frame, frame boundary parallel-loads
`echo_word`) is deliberately **not** gated by `load_error` or `run`: after a
full image the receive side is locked out but the retained final word still
shifts; the electrical release is `uio_oe[4] = load_active`. Frame 0 presents
`0x0000`, preloaded at `cs_fall` so a previous session's last bit cannot leak
into the first sampled bit.

## RED — the tests failed on the current RTL first

1. **Tests written first, RTL untouched.**
   - `iverilog -g2012 -s tb_pe_ctrl ../rtl/pe_ctrl.v ../tb/tb_pe_ctrl.v` →
     `tb_pe_ctrl.v:46: error: port "spi_miso" is not a port of dut.`
     (the readback output does not exist yet — feature missing).
   - The pad-level TB (pads only, so it compiles against the old wrapper):
     `vvp` → **121 failures** (`FAILURES: 121`, log `/tmp/red1_tt.log`) —
     `uio[4]` never driven, `ffff` on every echo sample, oe never asserted.
2. **A tie-off port stub** (`assign spi_miso = 1'b0;`) made the block TB
   compile and fail **behaviorally**: 28 failures, every echo-content case
   (`/tmp/red2_ctrl.log`). Two of those failures were a bug in my own TB
   (the readback bit task did not drive MOSI — found and fixed immediately);
   to isolate RTL failure from that artifact, a clean re-probe against an
   `/tmp` copy of the RTL with only the serializer disabled
   (`sed 's/if (sclk_fall ...)/if (1'b0)/'`, log `/tmp/red3.log`) gives
   **26 failures, all echo-content, 0 write-path failures** — tests 1–7 pass
   unchanged (non-vacuity of the old loader behavior).
3. **Wrapper stage RED** (pe_ctrl implemented, wrapper not yet wired):
   `FAILURES: 120` (`/tmp/red4_tt.log`), all pad-echo/oe cases.

## GREEN — implementation

- `rtl/pe_ctrl.v`: `spi_miso` output; `sclk_fall` detector; `echo_word`
  (commit-latched payload), `echo_shreg`, `echo_falls`; frame-0 preload and
  session clear at `cs_fall`; the 16-fall frame serializer placed before the
  write engine (so a same-cycle commit wins, exactly as it does for
  `words_written`); the commit capture beside `words_written <= +1`; header
  documents the full contract with the numbers above.
- `rtl/tt_um_protocol_emulator.v`: `uio_out[4] = ctrl_spi_miso`,
  `uio_oe[4] = ctrl_load_active`, `uio[7:5]` released (was `[7:4]`);
  `ctrl_load_active` removed from the unused sink; header pin map, pad count
  (18 → **19** committed, free `uio` 4 → **3**) and the "no readback path"
  paragraph corrected; STATUS item 4's revisit trigger now noted as fired.
- `tb/tb_pe_ctrl.v`: readback tasks with the two mode-0 stability checks
  (≥ 20 ns stable before every sampling edge; no movement in the first 100 ns
  of the high phase) and cases 8–12: multi-word echo content/bit order,
  repeated-session leak + duty/rate variants (200/200, 160/240, 100/900 ns),
  full-image trailing frame through the receive lockout, run-abort in both
  the idle and `W_PULSE` windows (an aborted word must never echo), and the
  three numeric bounds hit exactly at once (first rise 100 ns after `CS_N`,
  low phase 100 ns, period 400 ns = 2.5 MHz).
- `tb/tb_tt_um_protocol_emulator.v`: pad model
  (`uio_oe[4] ? uio_out[4] : 1'b1`, pull-up), oe checks (released with
  `CS_N` high, driven when selected/stopped, released with `run` high),
  the 5-word load through the pads with per-frame echo sampling at 2.5 MHz,
  a **full 1,024-word image** followed by a trailing frame that reads word
  1023 (`0xF000`) back while `load_error` is set and `words_written` stays
  1024; unclaimed-pin monitors narrowed to `uio[7:5]`.

## Mutation harness — `regress/mutate_ctrl_tb.sh`

Extended from **11 to 20 block mutations** (all measured by `tb_pe_ctrl`)
plus **3 wrapper pad mutations** (measured by `tb_tt_um_protocol_emulator`,
with its own snapshot/restore and byte-verify, and a firmware-image guard
for standalone runs):

| # | mutation | property it breaks |
|---|---|---|
| 12 | `echo-at-word-ready` | echo latched one strobe early → an aborted word echoes |
| 13 | `echo-on-abort` | the `W_PULSE` run-abort path commits the echo |
| 14 | `echo-wrong-source` | payload from `shreg` (LSB lost) |
| 15 | `echo-reversed` | frame boundary presents LSB first |
| 16 | `no-frame0-preload` | previous session's last bit leaks into frame 0 |
| 17 | `miso-change-on-rise` | strict mode 0 violated (change in the high phase) |
| 18 | `echo-stale` | frame boundary never reloads → echo never refreshes |
| 19 | `load-active-stuck` | pad never releases |
| 20 | `load-active-no-run` | `run` high does not release the pad |
| 21 | `uio-oe4-stuck-driven` | wrapper: oe tied 1 |
| 22 | `uio-oe4-stuck-released` | wrapper: oe tied 0 |
| 23 | `uio-out4-tied-low` | wrapper: echo value never reaches the pad |

Echo **content** checks bind the latency: any one-frame-late (or -early)
implementation presents the wrong word at frame 1 or at the trailing frame
and fails, so a dedicated latency mutant adds nothing observable (recorded
in the harness header).

## Exact commands and results (final tree)

| command | result |
|---|---|
| `iverilog -g2012 -s tb_pe_ctrl ../rtl/pe_ctrl.v ../tb/tb_pe_ctrl.v && vvp …` | **`PASS: tb_pe_ctrl`** (0 failures; cases 1–12) |
| wrapper compile with the SRAM model + `vvp` | **`PASS: tb_tt_um_protocol_emulator`**, `loaded 1024 words (image + NOP fill) through the loader pads`; runtime 6.4 s |
| `bash regress/mutate_ctrl_tb.sh` | **`=== 23 detected, 0 survived, 0 harness errors ===`**, exit 0 (baseline 11/11 → 23/23, including both baselines passing first) |
| `./regress/run_all.sh --fast -j8` | **exit 0**: `FIRMWARE: 20 PASS: 20 FAIL: 0`, `TOTAL: 29 PASS: 29 FAIL: 0`, `lint clean`, all seven generated gates current (`signal glossary`, `protocol pin budget`, `sram budget`, `floorplan feasibility`, `crc config`, `clock arithmetic`, `block diagram`), `macro flow config: OK` + `negatives: OK` (26/26), all seven mutation suites OK. Log: `/tmp/run_all_a1.log` |
| `./regress/lint.sh` | exit 0, `lint clean` (14 verilator tops + 11 yosys elaborations) |
| `./regress/synth_area.sh` | **exit 0**, no diagnostics surfaced: `pe_ctrl` **463 cells / 8,661.303000 µm²** (was 292 / 5,791.149), `pe_soc` **3,571 / 56,816.877600 µm²** (unchanged), `tt_um_top` **4,038 / 65,686.269600 µm²** (was 3,888 / 62,745.4296). Log: `/tmp/e26_synth_area.log` |
| `python3 tools/gen/{signal_glossary,pin_budget,sram_budget,floorplan_feasibility,crc_config,clock_arithmetic,block_diagram}.py --check` | all seven **OK** (`signal_glossary` and `pin_budget` were regenerated for the new port/pad; the floorplan area cache and page refreshed to `tt_um_top 4038 65686.2696`) |
| `git diff --check` | clean |

## Budget note (kept visible)

Committed pads **18 → 19** of 24; free `uio` **4 → 3**; the all-nine
shortfall **9 → 10** (debug kept) / **3 → 4** (reclaimed), because the
readback is loader overhead, not one of the nine protocols. Recorded in the
plan, STATUS item 6, the wrapper header, and the regenerated
`wiki/reference/protocol-pin-budget.md` (total committed 19, `uio` free 3).

## Limits

- The area screen is mapped pre-route synthesis only. **No STA refresh was
  run** (the manager schedules it); the new `echo_*`/`spi_miso` register →
  pad path class should be covered by that refresh, like the earlier SPI pad
  aliases.
- No physical flow, DRC or LVS. No firmware, SERDES, GUI or bridge changes.
- The computed timing bounds rest on the plan's stated assumptions
  (`t_pad ≈ 5 ns`, `t_setup ≈ 10 ns`, `t_hold ≈ 5 ns`); the formulas, not
  the numbers, are the record.
- `diagrams/project-progress.puml` was not refreshed (not in this task's
  scope); STATUS item 4's dbg-pin revisit trigger now fires but the item-4
  decision itself is unchanged.
- E2-6/R3 from Task 1 were **manager-verified and closed on 2026-09-24**
  (macro harness 26/26, identity-logic code review, full regression exit 0).
- Manager verification of this task (2026-09-24): `./regress/run_all.sh --fast
  -j8` exit 0 (`/tmp/run_all_mgr_verify_20260924.log`); mapped `pe_ctrl` STA
  screen: worst setup +8.71/+8.80/+8.86 ns, worst hold -0.12/-0.16/-0.19 ns
  (unchanged from the pre-A1 screen), new echo/`spi_miso` max-path groups
  +12.09/+12.19/+12.23 ns. Reports: `reviews/2026-09-24/manager-a1-sta/`.
