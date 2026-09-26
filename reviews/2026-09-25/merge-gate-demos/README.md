# Merge-gate demonstrations — the gate's own output, trimmed

Generated 2026-09-25 by the runs described in
reviews/2026-09-25/MERGE-FORENSICS-5B4731F.md section 6.1. These are
EXCERPTS, not a summary: the point of keeping them is that a reader can
check my account against the gate's own words.

## RED — the real merge 5b4731f (worktree checked out AT the merge, gate copied in)
```text
MERGE GATE — HEAD (merge: fw-timing-protocols (Blocks 1-2: six timing + input-c)
  base:     HEAD^1 (first parent);  merge base dcdf63d6
  changed:  27 path(s) merged in | behind: 226 path(s) main gained while it was away
  FAIL: the data pin moved at all (edges=0 -- the firmware never drove bit 6) @683881000
  FAIL: exactly 5 pulses (0 rising edges, 0 falling edges, one of which is the initial drive to the idle level) @55015041000
  FAIL: two rising edges far enough apart to measure a frame period @55015041000
  FAIL: the firmware finished the ramp (dmem[14] = xx) @18349841000
TOTAL: 45   PASS: 39   FAIL: 6
failed: tb_pe_soc_ws2812 tb_pe_soc_servo tb_pe_soc_dht11 tb_pe_soc_ds18b20 tb_pe_soc_ir_nec tb_pe_soc_stepper_ramp
MERGE GATE: RED — DO NOT PUSH HEAD
    failed: tb_pe_soc_ws2812 tb_pe_soc_servo tb_pe_soc_dht11 tb_pe_soc_ds18b20 tb_pe_soc_ir_nec tb_pe_soc_stepper_ramp
```text

## GREEN — a benign merge on the last green main (6da4100)
```text
MERGE GATE — HEAD (merge: benign2 (GREEN demo of the gate's narrow path))
  base:     HEAD^1 (first parent);  merge base 6da4100e
  changed:  2 path(s) merged in | behind: 0 path(s) main gained while it was away
  -> 14 of 39 cases selected; run_all.sh runs the rest of the gate unfiltered
(--cases ^(tb_pe_codec_mux|tb_pe_soc_eth|tb_pe_soc_eth_loop|tb_pe_soc_eth_tx|tb_pe_soc_i2c|tb_pe_soc_i2c_adv|tb_pe_soc_i2c_xfer|tb_pe_soc_serdes|tb_pe_soc_spi|tb_pe_soc_spi3|tb_pe_soc_tick|tb_pe_soc_uart|tb_pe_soc_uart_flow|tb_tt_um_protocol_emulator)$: 14 selected, 25 skipped)
TOTAL: 14   PASS: 14   FAIL: 0
param guards: OK
lint clean
signal glossary up to date
protocol pin budget up to date
formal safety proofs: OK (see formal/results/summary.txt for per-property status)
formal mutant checks: OK (see formal/results/mutants.txt for the per-mutant table)
wait-word cross-check: OK (chip filler <-> host stripper, 0..15)
i2c TB mutations: OK (no unexplained survivors)
spi TB mutations: OK (no unexplained survivors)
fbuf TB mutations: OK (no unexplained survivors)
eth_mac TB mutations: OK (no unexplained survivors)
eth_soc TB mutations: OK (no unexplained survivors)
ctrl TB mutations: OK (no unexplained survivors)
i2c_xfer TB mutations: OK (no unexplained survivors)
serdes TB mutations: OK (no unexplained survivors)
soc serdes TB mutations: OK (no unexplained survivors)
codec TB mutations: OK (no unexplained survivors)
ctrl R3 debug mutations: OK (no unexplained survivors)
eth_tx TB mutations: OK (no unexplained survivors)
eth_tx loopback TB mutations: OK (no unexplained survivors)
fw-bus TB mutations: OK (no unexplained survivors)
MERGE GATE: GREEN — HEAD (14 case(s) run, the affected set among them)
```text
