# SERDES + codec integration into pe_soc — implementation review — 2026-09-24

## Scope and decision

Implemented `wiki/plans/serdes-integration.md` as amended (two codec
instances TX/RX, split `tx_bit_en`/`rx_bit_en` with payload-only gates
`&& !tx_stuffed` / `&& rx_bit_valid`, independent `half_phase` **level**,
codec enables per encoded/decoded cell, latched-phase 16-entry window on the
free IO port `0xF` with separate TXLEN/RXLEN, wire loopback as the first
consumer). Manager decision on **all** open scope choices: adopt the recorded
recommended defaults in `reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`
(milestone scope, plain asynchronous RX scope, topology, CPU access); where
plan and review differ, the review's amended two-codec shape wins.

Required additions from the follow-up review, all included: one-cycle status
events latched for CPU polling; `tx_load`/`rx_start`/`clr` as write-triggered
strobes; the timing block kept active through a possible final stuffed cell;
plain RX asynchronous phase recovery limited to the recommended default scope
(self-timed wire loopback — no phase acquisition), documented as a limit.

Reset default stays **engine-disabled and overlay-off**, so every existing TB
and firmware image is bit-identical (proved: 30/30 RTL, 21/21 firmware with
the engine present).

Process: (1) `diagrams/project-progress.puml` refreshed FIRST to record the
landed A1 readback and the E2-6/R3 closure (gotcha 47); (2) directed tests
written and shown failing on the pre-integration RTL; (3) RTL implemented;
(4) mutation harness extended and shown detecting; (5) diagrams refreshed
again at the end for the integration.

## Source SHA-256 (final)

| file | sha256 |
|---|---|
| `rtl/pe_soc.v` | `37ed4d4e62ea0eb5c96b323013e105db56d7e3b698b97fe47a5252060320c8a9` |
| `rtl/pe_serdes.v` | `9f71c88c58918a73b1f3223ad5cf71061926d67d3f9ce0040da6a4c363f68a1e` |
| `rtl/pe_pinmux.v` | `c1fa0cec1cdc2ad04c6b9e97bc8ad4e6fdb0893e3fbda8256121ce7312949aef` |
| `tb/tb_pe_soc_serdes.v` (new) | `7c33dec8a2bc07575c322af2e6c46742488694828fea09a20747497ef5768bd9` |
| `tb/tb_pe_serdes.v` | `b66e0f275c065a9145d391bb6b22c119462b1d6597cd27ee284cb7f16012524c` |
| `tb/tb_pe_pinmux.v` | `0fdd07a3b0ec69a5ace17da3d956252f2420dbc3e47fea01a2f7e5231d206e33` |
| `regress/mutate_soc_serdes_tb.sh` (new) | `ed3243660f30cdbde1ffb0259be990e1b5793118789a2f931c74a87268a9a48a` |
| `regress/mutate_serdes_tb.sh` (new) | `35097178b97cd38458a861b79eeeb24ea0990ecb61438dc2165f178b74e59b56` |
| `regress/run_all.sh` | `bbdd625c7a8552638627abc62b5a789c6346d3fe4114c70bf7f1d729e2fcc9fd` |
| `firmware/serdes_loop.pe` (new) | `28e4d5bf10ab002a197e12cc813b75209a51450bbaabab5e9867072ee508a654` |
| `tools/fw/peasm.py` (ENGINE port symbol) | `7b655429d2cfc82941b0da23aa815257c0c12f356317335c96eae67cf501eb5c` |
| `tools/gen/block_diagram.py` (orphans retire) | `6d1dcb9a39469e97c314fe2664987cb76c86c87bd28283361d33462b1e8ef19a` |

## What was built

- **`rtl/pe_soc.v` — the engine section** (contract in the section header):
  16-entry latched-phase window on port `0xF` (INDEX phase sets the pointer,
  DATA phase bursts, any read auto-increments and re-arms INDEX); CTRL
  (index 0) splits into stored enables (`engine_en`, `cfg_lsb_first`,
  `tx_pin_sel`) and one-cycle strobes (`tx_load`, `rx_start`, `clr`);
  TXLEN/RXLEN/CFG/TXDATA as stored registers; STATUS (index 6) returns live
  levels plus **latched** `tx_done`/`rx_valid`/`rx_err` with set-beats-clear;
  RXDATA (11-14) returns the serdes word. The timing divider produces one
  `cell_en` pulse per encoded cell and `half_phase` with **two toggles per
  cell** (Manchester only); it free-runs while enabled, so a trailing stuff
  cell still emits after `serdes.tx_busy` falls. `tx_load`/`rx_start` are
  applied at the next cell boundary (grid-aligned load), and Manchester
  `rx_start` is anchored to the **first DRU decode after that load** so the
  stale idle decode in flight cannot become payload bit 0. Payload gates:
  `serdes_tx_bit_en = tx_cell_en && !tx_stuffed`,
  `serdes_rx_bit_en = rx_cell_en && rx_bit_valid` (current-cycle semantics,
  source `rtl/pe_bitstuff.v`). One capture path: the existing `u_eth_dru`
  feeds `u_rx_codec` (Manchester: `eth_bit_en` + halves; plain/NRZI/stuffed:
  divider strobe over `dru.rx_wire`). `u_serdes` (one instance, split
  enables), `u_tx_codec`, `u_rx_codec` (two unmodified instances, cfg
  replicated, `cfg[3]` overridden per direction).
- **`rtl/pe_serdes.v`**: `bit_en` port split into `tx_bit_en`/`rx_bit_en`
  (the two internal enable networks already existed; no flops moved). The
  nine protocol TBs alias their existing `bit_en` signal to both ports at the
  instantiation; `tb_pe_serdes` drives them separately and gained a directed
  split-enables case.
- **`rtl/pe_pinmux.v`**: new `ov_en[7:0]`/`ov_bit` level override feeding
  BOTH outputs (`pad_out` and the od term of `pad_oe`) before the open-drain
  gate, exactly as the plan requires; reset and `ov_en=0` are bit-identical
  to the old matrix. `tb_pe_pinmux` gained overlay/od-gate cases;
  `regress/param_guards.sh`'s inline elaboration harness updated.
- **`firmware/serdes_loop.pe`** (70 words): the window's first consumer —
  configures CFG/DIV/TXLEN/RXLEN/TXDATA from dmem, conditionally polls the
  DRU lock (Manchester only), pulses the start strobes, polls the latched
  `rx_valid`, and stores RXDATA + a done flag to dmem. `peasm` gained the
  `ENGINE = 0xF` port symbol.
- **`tb/tb_pe_soc_serdes.v`** (new): loads the firmware once, then runs four
  configs (plain LSB `0x96C3`, plain MSB `0x4E7B`, Manchester `0xA5C3`,
  **stuffed Manchester `0x07E0`**) over a pin-7 wire loopback, each after a
  fresh reset with dmem config written through the host port. Monitors check:
  cell pulses never closer than one cell period (doubled-enable), `tx_ser`
  stable across every inserted stuff cell (TX hold), no serdes advance while
  `rx_bit_valid` is low (RX skip), the RX cell strobe is the DRU's in
  Manchester (cross-wire), `half_phase` quiet when Manchester is off, exactly
  `tx_len`/`rx_len` advances, ≥2 stuff cells + a **trailing** stuff cell
  after `tx_done` for the stuffed config, and bit-exact words everywhere.
  The stuffed word `0x07E0` is derived, not decorative: with run=5 the stuff
  bits arm after payload 5 and payload 9, and payload 12..16 being five
  identical zeros arms the FINAL stuff bit on payload 16.
- **Source lists**: every list that elaborates `pe_soc` gained
  `pe_serdes/pe_nrzi/pe_bitstuff/pe_codec_mux` — `flow/pe_soc.json`
  (VERILOG_FILES), `info.yaml`, `regress/synth_area.sh` (both report lines),
  `tools/checks/macro_flow_config.py` (RTL list), and five mutation
  harnesses. Missed lists surfaced as gate/suite failures and are part of the
  evidence trail below.

## RED — the tests failed before the RTL

1. **Elaboration RED on the pre-integration RTL** (the `git show HEAD:`
   versions of `pe_soc.v`/`pe_serdes.v`/`pe_pinmux.v` — all three were
   unmodified vs HEAD before this task):

   ```text
   iverilog ... /tmp/pre-integration/{pe_soc,pe_serdes,pe_pinmux}.v \
     tb/tb_pe_soc_serdes.v
   tb_pe_soc_serdes.v:93: error: Unable to bind ... `dut.u_tx_codec.bit_en'
   tb_pe_soc_serdes.v:115: error: Unable to bind ... `dut.u_serdes.tx_bit_en'
   tb_pe_soc_serdes.v:119: error: Unable to bind ... `dut.u_rx_codec.rx_bit_valid'
   ... (u_serdes/rx_cell_en/half_phase all unbound) — exit 20
   ```

   The window/engine simply does not exist yet; the firmware's `OUT` to port
   `0xF` would be a no-op on that RTL.
2. **Behavioral RED during bring-up** (integration present, defects present):
   the first runs of the directed TB failed — plain LSB/MSB passed, but the
   Manchester configs returned wrong words (`0x1ED2`, `0x6294`) because
   (a) `half_phase` toggled only at the mid-cell boundary, so the wire ran at
   cell rate and the DRU decoded garbage, and (b) even after that fix
   (`0x4B87`, `0x0FC1`) the first DRU decode after the load — the stale idle
   cell in flight — was captured as payload bit 0, shifting the word by one.
   Both were fixed (two toggles per cell; `rx_start` anchored to the first
   decode after the grid-aligned load) and then frozen as mutations
   `half-rate-half-phase` and `rx-start-no-anchor`.
3. **Mutation RED (the plan's spec)**: `regress/mutate_soc_serdes_tb.sh`
   requires the TB to fail on the plan's four mutations; each was written
   against the implemented RTL and detected on first run (see table below).

## Mutation evidence (all detected, 0 survivors)

`regress/mutate_soc_serdes_tb.sh` (measured by `tb_pe_soc_serdes`, 7):

| mutation | what it breaks | result |
|---|---|---|
| `tx-hold-removed` (plan (a)) | serdes consumes a payload bit per wire cell | detected |
| `rx-skip-removed` (plan (b)) | received stuff cells captured as payload | detected |
| `doubled-cell-enable` (plan (c)) | TX codec strobe at half-cell rate (spacing check) | detected |
| `strobe-cross-wire` (plan (d)) | RX codec strobe from the TX cadence | detected |
| `rx-start-no-anchor` | stale idle decode becomes payload bit 0 | detected |
| `half-rate-half-phase` | wire runs at cell rate | detected |
| `no-grid-load` | bit0 truncated to a fraction of the first cell | detected |

`regress/mutate_serdes_tb.sh` (measured by `tb_pe_serdes`, 7 — the port
split affected this TB): `tx-on-rx-en`, `rx-on-tx-en`, `lsb-snapshot`,
`rx-pos-init`, `rx-data-copy`, `len0-load`, `tx-idle-low` — all detected.

Baseline restores are byte-verified after every mutation in both harnesses
(and `mutate_ctrl_tb.sh`'s snapshot/restore covers its wrapper half).

## Exact commands and results (final tree)

| command | result |
|---|---|
| `python3 tools/fw/peasm.py firmware/serdes_loop.pe -o firmware/serdes_loop.hex` | OK (70 words); also gated in `run_firmware_tests.sh` |
| `iverilog … tb_pe_soc_serdes && vvp` (4 configs) | `PASS: tb_pe_soc_serdes`; per-config: `plain-lsb word=96c3 txadv=16 rxadv=16`, `plain-msb word=4e7b`, `manch word=a5c3`, `manch-stuffed word=07e0 stuff=4 trailing=1` |
| `iverilog … tb_pe_serdes && vvp` | `PASS: all pe_serdes checks` (incl. the directed split case) |
| `iverilog … tb_pe_pinmux && vvp` | `PASS: tb_pe_pinmux` (incl. overlay/od cases) |
| `bash regress/mutate_serdes_tb.sh` | `=== 7 detected, 0 survived, 0 harness errors ===`, exit 0 |
| `bash regress/mutate_soc_serdes_tb.sh` | `=== 7 detected, 0 survived, 0 harness errors ===`, exit 0, `[baseline] passes on the unmutated design` |
| `./regress/lint.sh` | exit 0, `lint clean` (after sinking the deliberately-overridden `cfg[3]`) |
| `python3 tools/gen/{signal_glossary,pin_budget,sram_budget,floorplan_feasibility,crc_config,clock_arithmetic,block_diagram}.py --check` | all seven OK (glossary + block diagram regenerated: `pe_serdes`/`pe_codec_mux` orphans retire, `PLANNED` table now empty; floorplan cache refreshed) |
| `python3 tools/checks/macro_flow_config.py` | exit 0 (after adding the new modules to the gate's RTL list) |
| `bash regress/mutate_macro_flow_config.sh` | `=== 26 passed, 0 failed ===` (Task 1 baseline preserved) |
| `./regress/synth_area.sh` | exit 0, no diagnostics — see delta below |
| `./regress/run_all.sh --fast -j8` (three runs: `/tmp/run_all_s3.log` failed on the stale source lists, `/tmp/run_all_s3_final.log` green, and the **final run on the complete tree incl. all docs/diagrams** `/tmp/run_all_s3_FINAL.log`) | **exit 0**: `FIRMWARE: 21 PASS: 21 FAIL: 0`, `TOTAL: 30 PASS: 30 FAIL: 0`, `lint clean`, `canvas viewer: OK`, all seven gates, macro gate + negatives OK, **all nine mutation suites OK** |
| `bash diagrams` render (`plantuml -tpng/-tsvg`, `PLANTUML_LIMIT_SIZE=8192`) | both progress renders regenerated (the first attempt failed on a top-level `//` comment and a `;` in a package name — both fixed) |

### Mutation-suite baselines (recorded for comparison)

| suite | before this task | after |
|---|---|---|
| i2c | 6 detected + 1 documented-equivalent survivor | unchanged |
| spi | 5/0 | unchanged |
| fbuf | 5/0 | unchanged |
| eth_mac | 30/0 | unchanged |
| eth_soc | 8/0 | unchanged |
| i2c_xfer | 11/0 | unchanged |
| ctrl | 23/0 (Task 1/2 baseline) | unchanged |
| **serdes (new)** | — | **7/0** |
| **soc serdes (new)** | — | **7/0** |
| macro-flow negatives | 26/0 (Task 1) | unchanged |

The first full-regression attempt (`/tmp/run_all_s3.log`) failed in five
places for ONE reason — every source list that elaborates `pe_soc` still
lacked the four new modules (`ERROR: Module pe_codec_mux … is not part of the
design` in the macro gate; `Unknown module type` in the i2c/spi/eth_soc/
i2c_xfer/ctrl harnesses). Fixed by updating all lists in one pass; the reruns
above are green.

### Synthesis delta (manager's baselines: pe_soc 3,571 / 56,816.88 µm²,
tt_um_top 4,038 / 65,686.27 µm² after A1)

| block | before | after | delta |
|---|---|---|---|
| `pe_soc` | 3,571 cells / 56,816.8776 µm² | **4,961 cells / 82,893.7746 µm²** | **+1,390 cells / +26,076.90 µm²** |
| `tt_um_top` | 4,038 cells / 65,686.2696 µm² | **5,363 cells / 91,268.0622 µm²** | **+1,325 cells / +25,581.79 µm²** |
| `pe_serdes` (standalone report) | 539 (prior record) | 529 / 11,216.205 µm² | rerun variance; block unchanged |
| `pe_ctrl`, `pe_codec_mux`, `pe_soc`-external | unchanged | 463 / 130 | — |

The delta covers the serdes instance, two codec instances (minus dead-coded
unused directions), the 16×8 window, the divider, status latches and the
overlay/mux glue. `wiki/reference/.floorplan-areas` and the generated
floorplan page were refreshed from this run (occupancy now derived from
5,363 cells). Log: `/tmp/synth_area_s3.log`.

## Contract, limits and remaining work

- **Plain RX has no phase acquisition** (recommended default scope): it is
  self-timed wire-loopback only; an arbitrarily phased asynchronous sender is
  out of scope for v1. Recorded in `pe_soc`'s engine header, the plan's
  Status, and STATUS item 7.
- **No STA refresh run** — manager-scheduled. New timing classes: the
  window's read mux (`REG[INDEX]` + the RXDATA/status views) and the
  overlay→pad path (combinational cascade stuff→NRZI→Manchester into the
  matrix), plus `half_phase` fanout. The unit-TB 100 MHz sims prove function,
  not silicon timing.
- **Remaining plan item**: `regress/mutate_codec_tb.sh` (unit suite for
  `pe_codec_mux`) was not written; the codec itself is unmodified by this
  task, so no suite was affected — recorded as remaining, not skipped
  silently.
- The full 10BASE-T TX frame path (preamble/SFD/FCS/IFG/source) remains a
  separate block and plan; `eth_tx` and the USB persona stay open on the
  progress map.
- No physical flow, DRC or LVS was run; `flow/pe_soc.json` gained the four
  sources for correctness but was never executed. `wiki/plans/demo-host-gui.md`
  untouched.

## Post-completion update — Task 4 closeout (2026-09-24)

Both items this review recorded as remaining have landed:
`regress/mutate_codec_tb.sh` (13 mutations over the codec pipeline, 13
detected / 0 survived, `cmp`-verified restore; the tenth suite in
`run_all.sh`) and the manager-scheduled mapped STA refresh (slow/typ/fast at
16.667 ns on `pe_soc` and `tt_um_protocol_emulator`; the new overlay→pad,
`half_phase`, window read-mux and split-enable paths are all positive slack
at slow, and the `pe_soc` setup/hold summary is identical to the
pre-integration screen). Final evidence: `./regress/run_all.sh --fast -j8`
exit 0 (30/30 RTL, 21/21 firmware, ten mutation suites),
`./regress/synth_area.sh` clean at the same counts. Full record:
`reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md`; raw reports:
`reviews/2026-09-24/serdes-sta/`. No physical flow, DRC or LVS.
