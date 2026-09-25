# Closeout hardening — mapped STA refresh + codec mutation harness — 2026-09-24

Task 4 (manager-dispatched, closeout hardening) for the SERDES+codec
integration (STATUS item 7). Time recorded from `date`: 2026-09-24 13:32 CDT
(18:32 UTC). Three parts:

- **(a)** Mapped STA refresh for the integration's new timing classes: the
  recorded screen scripts' source lists extended with the four new modules,
  three corners at 16.667 ns, both `pe_soc` and `tt_um_protocol_emulator`.
- **(b)** `regress/mutate_codec_tb.sh`: the plan's remaining codec unit
  mutation suite, covering the documented CAN preset `0x51`, `ones_only`
  (`cfg[7]`) and run length (`cfg[6:4]`), the registered `clr`/`rx_err`
  contract, and the frame-boundary `clr`; wired into `run_all.sh`.
- **(c)** Final evidence: `./regress/run_all.sh --fast -j8` and
  `./regress/synth_area.sh` on the frozen tree.

No physical flow, DRC or LVS was run. `wiki/plans/demo-host-gui.md` was not
touched; the shared worktree was neither reset nor cleaned.

## (a) Mapped STA refresh

### Method

The recorded per-design screen flow is unchanged: native yosys maps with the
`sg13g2_stdcell_typ` liberty, `flatten`, `check -assert`, `write_verilog
-noattr -noexpr`; OpenSTA then reads the corner stdcell + SRAM liberties and
the same constraint block as `reviews/2026-09-23/eth-soc/sta-*.tcl`
(16.667 ns clock, 1.0 ns setup / 0.25 ns hold uncertainty, 3.3334 ns max /
0 ns min input+output delays, 0.1 ns input transition, 0.02 pF load).

The only script changes are the ones the task requires:

- `synth-pe_soc.ys` extends `reviews/2026-09-23/eth-soc/synth.ys`'s
  `read_verilog` list with `rtl/pe_serdes.v rtl/pe_nrzi.v rtl/pe_bitstuff.v
  rtl/pe_codec_mux.v`.
- `synth-tt_um.ys` uses the `regress/synth_area.sh` top-level list (adds
  `pe_ctrl` and the wrapper), top `tt_um_protocol_emulator`.
- The six `sta-*.tcl` files were generated from the recorded eth-soc tcls by
  `sed`; `diff` against the originals shows only the mapped-netlist path,
  `link_design`, and (for the top) the input-port list
  `{rst_n ena ui_in* uio_in*}` instead of `{rst_n host_* run pin_in*}`.
- `probe-*-*.tcl` are supplementary probes appended before `exit` (screen
  constraint block intact) so the new classes can be named rather than
  inferred from the top-5 paths.

Exact commands (repo root):

```bash
bash reviews/2026-09-24/serdes-sta/run_sta.sh
# runs, in order:
#   yosys -s reviews/2026-09-24/serdes-sta/synth-pe_soc.ys
#   (cd reviews/2026-09-24/serdes-sta && sta sta-pe_soc-slow.tcl  > sta-pe_soc-slow.txt)
#   ... typ, fast; then synth-tt_um.ys and the three top-level STA runs
# supplementary class probes (already run, reports saved):
#   (cd reviews/2026-09-24/serdes-sta && sta probe-<design>-<corner>.tcl > probe-<design>-<corner>.txt)
```

Pre-integration control (HEAD RTL, same flow, pads probed at fast/slow):

```bash
mkdir -p /tmp/preint-sta/rtl/vendor
for f in pe_cpu pe_imem pe_pinmux pe_dru pe_manch pe_crc pe_eth_mac pe_fbuf \
         pe_nrzi pe_bitstuff pe_codec_mux pe_serdes pe_soc; do
  git show HEAD:rtl/$f.v > /tmp/preint-sta/rtl/$f.v
done
git show HEAD:rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v \
  > /tmp/preint-sta/rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v
# /tmp/preint-sta/synth.ys = recorded eth-soc flow, HEAD sources
# (copy kept as reviews/2026-09-24/serdes-sta/preint-synth-pe_soc.ys)
yosys -s synth.ys && sta probe-fast.tcl > probe-fast.txt && sta probe-slow.tcl > probe-slow.txt
```

### Worst setup / hold per corner

Setup uncertainty 1.0 ns, hold 0.25 ns; slow is also a hold corner and hold
is checked at all three corners (`report_worst_slack -min`).

| design | corner | worst setup | worst hold | notes |
|---|---|---|---|---|
| `pe_soc` | slow | **0.0000** (latch time-borrow `pin_in[7]`→`_6145_`) | **−0.8692** (`host_wdata[*]`→SRAM `u_imem...A_DIN`) | worst r2r setup (clk group, excl. latch) **+1.9164** (SRAM `A_DOUT`→CPU) |
| `pe_soc` | typ | **0.0000** | **−0.6065** | setup paths shown are the latch chain (3.7847, 7.0160) |
| `pe_soc` | fast | **0.0000** | **−0.4778** | same class as typ |
| `tt_um_top` | slow | **0.0000** (latch time-borrow `ui_in[2]`→`_6679_`) | **−0.7106** (`ui_in[1]`→SRAM) | worst r2r setup **+1.8080** (SRAM→CPU) |
| `tt_um_top` | typ | **0.0000** | **−0.5234** | — |
| `tt_um_top` | fast | **0.0000** | **−0.4282** | — |

**Comparison with the pre-integration screens.** The old `pe_soc` screen is
setup 0.00 ns, hold −0.87/−0.61/−0.48 ns (slow/typ/fast); the new `pe_soc`
screen is **identical at every corner**. The old `pe_ctrl` screen
(+8.71/+8.80/+8.86 setup, −0.12/−0.16/−0.19 hold) is unchanged too — its
paths are inside the new top-level screen, where the worst hold is the
pre-existing SRAM-load path (−0.43 fast), not the loader.

**New violation class vs the pre-integration screens: none.** The same
classes are present (setup latch time-borrow at 0.00; pre-layout hold
violations; max slew / max capacitance / max fanout violators), and the
summary values are unchanged at `pe_soc`. What changed is the population of
the pre-existing pre-layout violation families:

| class count | old `pe_soc` slow/typ/fast | new `pe_soc` slow/typ/fast |
|---|---|---|
| max slew VIOLATED | 49 / 41 / 1 | 96 / 41 / 1 |
| max capacitance | 1 / 1 / 1 | 1 / 1 / 1 |
| max fanout | 136 / 136 / 136 | 188 / 188 / 188 |
| negative min-slack paths in the printed report | 10 | 10 |

The added slow-corner slew and fanout entries are the extra combinational
depth (stuff→NRZI→Manchester→overlay, the 16×8 window) and the wider flop
population; these are mapped pre-route screens and were already present as
a class. No physical signoff claim is made from them.

### New-class probes (supplementary, worst slack per corner)

| probe | pe_soc slow/typ/fast | tt_um slow/typ/fast |
|---|---|---|
| max → pads (`pin_out*` / `uo_out*`,`uio_out*`) | **+7.9553 / +9.5404 / +10.4888** | **+8.2112 / +9.6795 / +10.5768** |
| min → pads | +0.2686 / +0.0801 / **−0.0308** | +0.0659 / **−0.0523 / −0.1151** |
| max through `half_phase` | +10.8062 / +11.3640 / +11.6895 | +11.2316 / +11.6246 / +11.8582 |
| min through `half_phase` | +0.2303 / +0.0535 / **−0.0474** | +0.2696 / +0.0779 / **−0.0292** |
| max through `win_regs*` (window read mux) | +11.6715 / +13.1225 / +13.9897 | +11.7970 / +13.2007 / +14.0221 |
| min through `win_regs*` | +0.1463 / +0.0013 / **−0.0813** | +0.1859 / +0.0248 / **−0.0640** |
| max through `serdes_tx_bit_en` | +13.9082 / +14.5792 / +14.9395 | +13.9815 / +14.6239 / +14.9678 |
| min through `serdes_rx_bit_en` | +0.7516 / +0.3779 / +0.1697 | +0.7347 / +0.3663 / +0.1626 |

Every new class is **positive slack at slow** (the worst corner):
overlay→pad setup +7.96 ns, half_phase +0.23 ns min / +10.81 ns max, window
read mux +0.15 ns min / +11.67 ns max, split enables +13.9 ns max / +0.75 ns
min. The negative numbers are all at **fast** (pre-layout hold, unplaced
clock trees), and all are shallower than that corner's pre-existing worst
hold (−0.4778 `pe_soc` / −0.4282 `tt_um`). They are new *members* of the
already-recorded pre-layout hold family, not a new class.

**The pad hold path is pre-existing, and got shallower.** Pre-integration
HEAD `pe_soc`, same flow, fast corner: `min → pin_out` = **−0.1026**
(VIOLATED, all three worst paths). Post-integration fast: **−0.0308**. At
slow: +0.0937 pre vs +0.2686 post. The overlay mux changes the pad path but
does not introduce its hold violation.

Raw reports: `reviews/2026-09-24/serdes-sta/sta-*.txt`, `probe-*.txt`,
`preint-pe_soc-{fast,slow}-pads.txt`; yosys logs `synth-*.log` show only the
known benign warnings (`win_regs` memory→registers, the intentional DRU
two-latch pair, ABC combinational notes), and `check -assert` passed in both
mappings. Mapped netlists: `mapped-pe_soc.v` / `mapped-tt_um.v`.

## (b) `regress/mutate_codec_tb.sh` (the plan's remaining codec unit suite)

### TDD: the TB gained three directed contract checks first

Written first and run green on the unmutated RTL (then each is proven
non-vacuous by the mutations that hit it):

1. **CAN 0x51 non-complementary stuff bit** (`can51 rx`): five ones then a
   stuff slot with the run's polarity — `rx_raw_valid` low, `rx_err` high at
   the committing strobe, cleared at the next strobe. The positive
   complementary-stuff check could never see this.
2. **NRZI frame-boundary `clr`** (`nrzi clr`): toggle off idle J, assert
   `clr`, then hold raw 1 — the line must be back at idle J (1). This is the
   "`clr` reaches every stage, not just the stuffer" property.
3. **Manchester `clr` wins over a pending error** (`manch clr`): equal
   half-cells with `bit_en=1` and `clr=1` on the same edge — `rx_err` must be
   0 after it.

The TB change is three added `begin` blocks inside the existing sections (no
other edit); final SHA-256
`45d573c8fcbed7e7b60fe513473ca9ec7974d89caba4d7a388a866fa08b5a549`.

### The harness: 13 mutations, all detected, 0 survived

Modelled on `mutate_soc_serdes_tb.sh`: baseline must pass first; four RTL
files are snapshotted with `cp` into one temp dir and restored from it after
**every** mutation, each restore verified with `cmp` (gotcha 63 — never
`git checkout`, which destroys untracked files); `EXIT`/`INT`/`TERM` traps
restore all four and exit.

| # | mutation (file) | what it breaks | result |
|---|---|---|---|
| 1 | `can-default-run-wrong` (mux) | `cfg[6:4]==0 => 5` becomes 6; 0x01/0x51 stop stuffing after five | detected |
| 2 | `can51-explicit-run-ignored` (mux) | `cfg[6:4]` dropped, always run 5; the USB run-6 config stuffs early | detected |
| 3 | `ones-only-ignored` (mux) | `cfg[7]` dropped; a 12-zero run gets a stuff bit | detected |
| 4 | `stuff-clr-dropped` (mux) | run tracking survives the frame boundary | detected |
| 5 | `nrzi-clr-dropped` (mux) | line level does not return to idle J | detected |
| 6 | `manch-clr-dropped` (mux) | a pending cell error survives `clr` | detected |
| 7 | `manch-rx-err-combinational` (pe_manch) | `rx_err` back to the old unregistered idle-line-high expression | detected |
| 8 | `nrzi-always-on` (mux) | bypass subset wrong: stuffing also enables NRZI | detected |
| 9 | `rx-cascade-skips-nrzi` (mux) | stuffer sees raw wire levels, pipeline order broken | detected |
| 10 | `half-phase-inverted` (mux) | Manchester selects the wrong half-cell | detected |
| 11 | `stuff-rx-err-never-set` (pe_bitstuff) | a non-complementary stuff bit is accepted | detected |
| 12 | `stuff-run-off-by-one` (pe_bitstuff) | TX arms the stuff bit one run late | detected |
| 13 | `rx-stuff-run-off-by-one` (pe_bitstuff) | RX flags the stuff slot one wire bit late | detected |

Exact command and result:

```bash
bash regress/mutate_codec_tb.sh
# === mutation-testing tb_pe_codec_mux ===
#   [baseline] passes on the unmutated design
#   ... 13 "detected" lines ...
# === 13 detected, 0 survived, 0 harness errors ===
# OK: every codec-pipeline mutation is detected by tb_pe_codec_mux.
# exit 0
```

Log: `/tmp/mutate_codec_final2.log` (frozen-tree rerun after a
no-behaviour change to the snapshot loop). RTL hashes after the run are
identical to
the pre-run hashes (restore verified by `cmp` per mutation and re-checked
above).

### Wiring

`regress/run_all.sh` gained the harness after the SoC-SERDES block, printing
`codec TB mutations: OK (no unexplained survivors)`; the regression now runs
**ten** mutation suites (i2c, spi, fbuf, eth_mac, eth_soc, ctrl, i2c_xfer,
serdes, soc serdes, codec) plus the 26-check macro-flow negatives.

## (c) Final evidence on the frozen tree

| command | result |
|---|---|
| `bash regress/mutate_codec_tb.sh` | **13 detected / 0 survived / 0 harness errors**, exit 0 (`/tmp/mutate_codec_final2.log`) |
| `./regress/run_all.sh --fast -j8` | **exit 0**: `FIRMWARE: 21 PASS: 21 FAIL: 0`; `TOTAL: 30 PASS: 30 FAIL: 0`; lint clean (15 verilator + 12 yosys elaborations); every generated gate OK; macro flow config OK + negatives OK (26); **ten mutation suites OK** (`/tmp/run_all_task4_final.log`) |
| `./regress/synth_area.sh` | **exit 0**, no diagnostics; `pe_soc` **4,961 cells / 82,893.7746 µm²**, `tt_um_top` **5,363 / 91,268.0622 µm²** — matches the post-integration baseline exactly (`/tmp/synth_area_task4_final.log`) |
| `git diff --check` | clean |

## Source SHA-256 (this task's final tree)

| file | sha256 |
|---|---|
| `tb/tb_pe_codec_mux.v` | `45d573c8fcbed7e7b60fe513473ca9ec7974d89caba4d7a388a866fa08b5a549` |
| `regress/mutate_codec_tb.sh` (new) | `3885302928072c940eef6e037cf24f80cf6d7354e6fa1ffb1ee06dfefe86e988` |
| `regress/run_all.sh` | `fd8271d191c7a5cd7296e6f1e891370b48b5f2e95340d4e77ddb8ab0801f85a1` |
| `rtl/pe_codec_mux.v` (untouched) | `5a6c48816b408e61284165783b7d62bf31e5f972ae8c5d90c9d20f7f7ed3ba18` |
| `rtl/pe_bitstuff.v` (untouched) | `ea1afe19580d834155d59d1f4fbf4142c3522d5fa4224c61bb279d970dd77201` |
| `rtl/pe_nrzi.v` (untouched) | `3d4970b1765251c9e7f58c33de18061bc3b4f6e230f9fbfd008d11480abc07fe` |
| `rtl/pe_manch.v` (untouched) | `31f740570ae095afbf9c127f791e19c5545dd4f548440946cf18c76a975c5e5e` |
| `rtl/pe_soc.v` | `37ed4d4e62ea0eb5c96b323013e105db56d7e3b698b97fe47a5252060320c8a9` |
| `rtl/pe_pinmux.v` | `c1fa0cec1cdc2ad04c6b9e97bc8ad4e6fdb0893e3fbda8256121ce7312949aef` |
| `rtl/pe_serdes.v` | `9f71c88c58918a73b1f3223ad5cf71061926d67d3f9ce0040da6a4c363f68a1e` |
| `reviews/2026-09-24/serdes-sta/mapped-pe_soc.v` | `e54e199cc3cc0a4897cc3baead2670d29d2cd712b022e736e5ffc263112b32cc` |
| `reviews/2026-09-24/serdes-sta/mapped-tt_um.v` | `4a2edf6fd8e33c6a34af24159c56e4161f0c71552c18e64960f54ca4096e6aeb` |
| `reviews/2026-09-24/serdes-sta/run_sta.sh` | `6ff810a223139416040d19d843161d0657c37261e802001be3d67aa30b591f61` |
| `reviews/2026-09-24/serdes-sta/synth-pe_soc.ys` | `2c6152a940988bff4d382f61200a8ebb138555eb7a62155f0ec9d4fd76323783` |
| `reviews/2026-09-24/serdes-sta/synth-tt_um.ys` | `b6d6ab96e39d8277b4debdb5d20583d8ae044bba247fbce14ce49db7f2f61c60` |
| `reviews/2026-09-24/serdes-sta/preint-synth-pe_soc.ys` | `50765f850b85577921c2d5f10af5b145b1e01549317f3e5b0529d853330fc971` |

The RTL hashes match the SERDES integration review's final set, so this
screen is exact-source for the integrated design; the four codec modules
are unchanged from HEAD.

## Docs updated (task d)

`HANDOFF.md`, `wiki/STATUS.md`, `wiki/log.md`, and the Status block of
`wiki/plans/serdes-integration.md`; a pointer added at the end of
`reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md`. `wiki/plans/demo-host-gui.md`
untouched.

## Limits

- Mapped pre-route screen only: ideal clock, pre-layout I/O delays, no
  parasitic or placed-clock effects, no physical flow / DRC / LVS. Not
  signoff.
- The 0.00 ns setup summary is the DRU's transparent-latch time-borrow path
  (`pin_in[7]`/`ui_in[2]`), present in the pre-integration screens; the worst
  register-to-register setup at slow is +1.9164 ns (`pe_soc`) / +1.8080 ns
  (`tt_um`).
- Fast-corner negative holds are unplaced pre-layout members of a family the
  old screen already had; the worst hold is the pre-existing SRAM-load path
  in both old and new `pe_soc` screens (−0.8692 slow).
- The probe set covers the named new classes at named nets; it is not an
  exhaustive per-path audit of the 5,363-cell top.

## Manager verification (2026-09-24, post-Task-4)

Independent re-run on the frozen tree: `bash regress/mutate_codec_tb.sh` -> 13
detected / 0 survived / 0 harness errors; `./regress/run_all.sh --fast -j8` ->
exit 0 (FIRMWARE 21/21, TOTAL 30/30, ten mutation suites OK; log
`/tmp/run_all_mgr_t4verify.log`). Spot-checked `reviews/2026-09-24/serdes-sta/`:
worst setup/hold per corner match this review's table (pe_soc 0.00 /
-0.87/-0.61/-0.48 ns; tt_um_top 0.00 / -0.71/-0.52/-0.43 ns), and the per-path
probe scripts plus the pre-integration control substantiate the
no-new-violation-class claim. Task 4 verified.

Follow-up queued: the negative hold values are mapped, unplaced, ideal-clock
screening artifacts (same family as all prior screens). The recorded routed SoC
run closed hold at +0.1209 ns with 0 violating paths at all corners, so CTS +
hold repair is the demonstrated fix mechanism. A constraints task (realistic
min-input-delay assumptions for direct-input hold paths + input-registration
audit) is queued to make the screens honest about that assumption.

## Post-update — hold attribution and board-assumption screens (Task 5b, 2026-09-24)

The hold interpretation recorded above ("fast-corner negative holds are
shallower members of the pre-existing pre-layout family") is refined by the
Task-5b attribution. Every negative min slack separates into external-input
assumption artifacts (0 ns min input delay: `host_*`/`run` data paths and
`rst_n` removal checks), external-output artifacts (0 ns min output delay:
`pin_out`/`dbg_*`/`spi_miso`/`uio_out[4]`), internal pre-CTS reg→reg paths,
and paths entirely inside the 0.25 ns hold uncertainty. Labelled
ZERO-ASSUMPTION and BOARD-ASSUMPTION (1.0 ns screening floor) variants plus a
full negative-min-slack inventory were added under
`reviews/2026-09-24/serdes-sta/`. Under the board assumption every external
class drops to 0 paths in all nine screens and the remaining negatives are
internal or within the uncertainty; **worst setup is unchanged in every
pair**. Board worst hold: `pe_soc` −0.54/−0.41/−0.36, `tt_um_top`
−0.64/−0.48/−0.40, `pe_ctrl` +0.04/−0.07/−0.13 (slow/typ/fast). Full tables,
the 1.0 ns assumption justification and the read-only input-registration
audit: `reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md`. No RTL changed.
