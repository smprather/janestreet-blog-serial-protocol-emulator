# Handoff — state of the repo (2026-09-23)

> **Latest follow-up (2026-09-23): E1 and E2 (P1) are FIXED.** The review at
> `9a84c6e` found that reclaiming frame 1 during reception of frame 2 could
> publish frame 2 with a corrupt window; the fix splits the ring into a producer
> write pointer and a consumer read pointer (`buf_consume`), so a release never
> touches an in-flight frame. It also found that the flow config placed and
> power-hooked only the instruction SRAM; `flow/pe_soc.json` now configures both
> macro instances with all three supplies each, and
> `tools/checks/macro_flow_config.py` re-derives that from the netlist on every
> regression. Read `reviews/2026-09-23/E1-RESOLUTION.md` and `E2-RESOLUTION.md`;
> the original findings and reproducer are in `ETHERNET-SOC-REVIEW.md`. The user
> requested 15-minute progress checks, and permits periodic synthesis/STA to
> catch RTL that cannot be hardened; physical flow, DRC and LVS remain deferred.

> **pe_ctrl run-transition P1 FIXED and verified (`ef4041d`).** The independent
> test had found a word could write during `run`
> (`writes=1 writes_while_run=1 error=0`) if `run` rose after reception and
> before host-port sampling. The fix masks `host_we`, aborts and flags queued
> words in `W_IDLE`/`W_PULSE`/`W_DONE`, so nothing writes during execution or
> reappears when `run` falls. `tb_pe_ctrl` fails on the pre-fix RTL and passes
> on the fix; `regress/mutate_ctrl_tb.sh` is 11 detected / 0 survived. The full
> regression at `e448c09` was 28/28 RTL, 19/19 firmware, six mutation suites
> and the macro gate, lint clean. The three-corner screen reports 0 synthesis problems,
> +8.71 ns worst setup (slow), and −0.19/−0.16/−0.12 ns hold (fast/typical/slow)
> on the direct `run` input under a 0 ns minimum input-delay assumption, with
> unplaced high-fanout violations. The async SPI first-stage endpoints are
> intentionally unconstrained. Evidence: `PE-CTRL-RESOLUTION.md` and
> `reviews/2026-09-23/pe-ctrl-hardening/`. Physical flow, DRC and LVS deferred.

Written for whoever picks this up next, human or agent. Read this, then
`reviews/2026-09-23/REFACTOR-REVIEW.md`, then `wiki/STATUS.md`. The refactor at
`6de2a6a` was reviewed against `2cc0f03`: no new functional defect found, and
the earlier review findings (including F1/F2/F3) remain closed. The source
comparisons and fresh regression support the functional no-op claim:
`tb/` is testbenches only, `regress/`
holds the harnesses, `tools/{fw,gen,checks}/` the Python, the SoC is
`rtl/pe_soc.v`, the line codecs are one module per file, and the SRAM shell is
under `rtl/vendor/`. Commands in this file use the new paths.

## Resume after refactor review

The user asked to review the large layout refactor. Fresh verification at
`6de2a6a` passed the standard regression, all seven original probes, the
102-case asynchronous Ethernet sweep, and the F1 boundary tests. All 15 RTL
and 26 TB module token streams match the pre-refactor revision after the
intended renames; file-level directives/attributes, firmware tool executable
ASTs and four firmware images are preserved. Relocated generators/checkers
work from outside the repo; submission sources and both staged flow source
sets compile. Only the flow's file-copy block was executed, with outputs under
`/tmp`; no physical tools were run. Evidence and replay scripts are under
`reviews/2026-09-23/refactor/`.

Current branch: `main` (the reviewed CODE revision is `6de2a6a`; the
handoff/docs commit above it only adds this report and its evidence).
`review/fix-invisible-defects` remains at `2cc0f03`.
The implementation and verification state is:

| ID | Priority | Finding | Fix |
|---|---|---|---|
| R2-1 | P1 | DRU latch/flop simulation race rejects an independently timed Ethernet frame | Two-latch (master/slave) DDR capture; async 49.995 ns frame is now a permanent TB case; sweep 102/0 |
| R2-2 | P1 | Valid-CRC runt accepted with length 65,532, corrupting buffer accounting | Structural verdict (`hdr_done`, `fcs_done`, `bit_cnt == 0`, type min 64 bytes) before the residue is trusted; runts and partial bytes are TB frames 10 and 12-15 (F1 closed) |
| R2-3 | P2 | USB stuffing applied to zero runs | Explicit `ones_only` rule (`cfg[7]`, run length `cfg[6:4]`); USB config is `0xE3`; TX/RX zero-run tests; the generated reference now matches (F2 closed) |
| R2-4 | P2 | One-clock CPU stop could resume on a stale instruction | `imem_addr` is zero while stopped; `tb_pe_cpu` test 10 |
| R2-5 | P2 | SRAM fallbacks read during writes while the macro holds | FLOP reads gated on `!we` (fbuf word+lane, imem rdata); TB checks across a changing address |
| R2-6 | P2 | Emulator UART monitor sampled bit boundaries, A5 read as 4A | First data sample at 1.5 bit periods; permanent 519/520/521 case |
| R2-7 | P2 | Interrupted mutation suites left source files changed | EXIT/INT/TERM traps restore pristine sources and image, then exit; probe `changed=[]` |
| F3 | P2 | The CAN example in the new reference (`0x05`) enabled Manchester | Reference says CAN `0x51` (`0x01` equivalent; `0x05` is not a preset); `tb_pe_codec_mux` checks `0x51` on TX and RX |

Earlier finding details and source locations are in
`reviews/2026-09-23/FIX-VERIFICATION.md` and `reviews/2026-09-22/REVIEW-2.md`;
fresh refactor evidence is in `reviews/2026-09-23/REFACTOR-REVIEW.md`.
The second-review runner exits 0, the
asynchronous Ethernet sweep is 102 trials / 0 failures, and the boundary runner
`reviews/2026-09-23/run-boundaries.sh` exits 0.

**Next:** STATUS item 5's read-only floorplan feasibility is documented in
[[reference/floorplan-feasibility]] (generated; no flow launched). The remaining
*physical* work is deferred by standing ruling and listed there as evidence for
a later run — a TT-top flow config, placement inside a real `CORE_AREA` with the
pad ring, both macros' PDN connectivity, congestion/DRC and a confirmed tile
size. The live software candidates now are bringing SPI's MOSI/CS out on the
free `uio` bank and a `pe_ctrl` readback
path. **The I2C review-focus gaps are closed (2026-09-23):** arbitration loss
releases and aborts without a STOP, unexpected NACKs record an outcome and end
with a STOP, and SCL is read back after every release so stretching is waited
on; all three are tested on the emulator (60 phases, with a
transient-contention arbitration case) and real RTL, with
`regress/mutate_i2c_xfer_tb.sh` at 11/11. The remaining I2C limit is that an
abort parks — no STOP-qualified bus-free wait and no retry — plus a real
device/fast mode. See `reviews/2026-09-23/I2C-TRANSACTION-REVIEW.md` for the
original clean path and the limits this work closes. All
review follow-ups (F1/F2/F3) are closed. Continue the functional simulation loop. The user explicitly permits **periodic synthesis
and STA to catch RTL that cannot be hardened** (2026-09-23): check mapped logic,
clock/latch structures, constraints, SRAM timing coverage and timing failures.
The standing restriction is **do not run physical flow, DRC, or LVS**.
The three R2-7 mutation harnesses restored source bytes in
the tested interruptions; the preceding verification report records the scope of
those checks.

## What is verified right now

The standard regression and the directed review probes measure different cases:

```bash
./regress/run_all.sh            # 29/29 TBs + 20/20 firmware + lint + 7 mutation
                           # suites + generated-doc drift, exits 0
./regress/run_all.sh --fast     # same verdicts, parallel TB loop, 4-state iverilog
bash reviews/2026-09-22/review2/run_repros.sh
                           # the seven second-review probes; exits 0
bash reviews/2026-09-23/run-boundaries.sh
                           # F1 Ethernet structure boundaries; exits 0
```

Historical refactor baseline at `6de2a6a`, verified in a `git archive` copy:
`run_all.sh --fast -j4` →
`TOTAL: 26 PASS: 26 FAIL: 0`, `FIRMWARE: 18 PASS: 18 FAIL: 0`, `lint clean`
(14 verilator tops + 11 yosys elaborations), all four mutation suites green, plus
`signal glossary up to date`, `protocol pin budget up to date`,
`sram budget up to date`, `crc config up to date`, `clock arithmetic up to date`,
`block diagram up to date`, `canvas viewer: OK`. The reference docs are generated
from the RTL/PDK and drift-checked inside the regression, so a renamed port or
deleted TB fails the run. A `git archive` clone with none of the ignored diagrams
present also exits 0 (the diagram gate is a committed source hash now; see
`reviews/2026-09-22/REVIEW.md` finding 7).

**Current regression (2026-09-23, after the I2C gap fixes and the pin-budget
correction):** `run_all.sh --fast -j8` exit 0 — **29/29 RTL, 20/20 firmware**,
param guards OK, lint clean, every generated-doc/macro-flow gate current, the
I2C transaction checker passing, and **all seven mutation suites OK** (i2c,
spi, fbuf, eth_mac, eth_soc, ctrl, i2c_xfer). I2C gap evidence is in
`reviews/2026-09-23/I2C-TRANSACTION-REVIEW.md`'s resolution section. The
earlier `56ba1a9` numbers below are the historical baseline for that commit.

An independent restore of the `TYPE_MIN` mutant in `rtl/pe_eth_mac.v` happened
while a regression may have been active: the source is clean now, and after the
restore `regress/mutate_eth_mac_tb.sh` was rerun standalone (**16 detected, 0
survived**, source pristine); the full rerun also started pristine and reports
eth_mac green.

## The thing that actually works

`firmware/uart_echo.pe` is a complete 115200 8N1 half-duplex UART. It is not RTL.
It runs on `rtl/pe_cpu.v` inside `rtl/pe_soc.v` (one input pin, one output
pin, a tick counter). `tb/tb_pe_soc_uart.v` drives a real waveform on RX and
decodes TX, and passes on 41/42/00/FF with 8.6–8.7 µs bit cells measured at the
pin. `tools/fw/peemu.py` reproduces the same tested bytes, which is the fast loop for
firmware work (2 s, no iverilog). The R2-4 restart and R2-6 UART-monitor probes
now pass; their fixes and additional independent checks are recorded in the
2026-09-23 verification report.

If you change anything in the firmware timing path, run **both** the TB and the
emulator. They disagreed once and that disagreement is how the real bug was found
(see below).

## The first 2026-09-22 review and fixes

Nine defects were found on a `git archive` clone where every test passed; the
report is `reviews/2026-09-22/REVIEW.md`. Two change how you should read the
RTL. (1) **The DRU sampled rising edges only**, so the advertised 60 MHz /
100 ns 10BASE-T grid did not exist — the testbenches scaled the wire to the
clock. It is dual-edge now (ADR-002's latch pair), and both `tb_pe_dru` and
`tb_pe_eth_mac` drive real bit timing; the Ethernet TB is real frames with a real
FCS. (2) **One oversized frame could zero the receiver's `room` permanently**
(the reclaim truncated `pay_cnt` to 11 bits, and a full 2,048-byte frame is
`11'h000`). The rest were the submission source lists, the emulator's timer
order and stop→run prefetch, Ethernet padding, fresh-clone diagram/Canvas gates,
`peasm --rtl-init`, and the lint gate's coverage — which now includes
`pe_eth_mac`/`pe_fbuf` and fails on ANY yosys `ERROR:`, because the old gate
grepped for three known diagnostics and passed a file yosys could not parse.

## Where the bodies are buried

1. **A TB that "waits for" an event it may have missed tests nothing.** The UART
   SoC TB was red for three defects, the worst being `@(negedge tx_pin)` running
   *after* the echo had already started — it silently anchored on the wrong edge
   and decoded every byte shifted. Fixed by latching the edge in an `always` block
   and sampling on a grid anchored to the latched time. If you write a TB against
   firmware that replies immediately, latch, don't wait. Details: `wiki/log.md`
   2026-09-20 and `wiki/plans/through-i2c.md` Blocker 1.
2. **FIXED 2026-09-20: the instruction memory is a real SRAM macro.**
   `rtl/pe_imem.v` instantiates `1P_1024x16_c2_bm_bist`; the SoC went 8,744 cells
   / 182,650 µm² → **1,083 cells / 19,795 µm²** with 8× the program. Two things
   about it are easy to get wrong and are worth knowing before touching it:
   - **The macro's protocol has two silent traps.** `A_BM[i]=1` means *write bit
     i*, so tying BM low makes every write a no-op that reports success; and
     `A_REN=1` during a write is **write-through**, so REN must be deasserted for
     the whole write cycle. Both are read from the vendor model, both are tested
     by `tb_pe_imem`, and both are mutation-checked. Do not "simplify" the
     wrapper's `re = ~host_we` without re-reading `rtl/pe_imem.v`'s header.
   - **Simulation needs the PDK's behavioural model, which lives outside the
     repo.** `regress/sram_model.sh` locates it and FAILS LOUDLY if absent — never fall
     back to `pe_imem`'s `FLOP=1` array silently, because a testbench that runs
     against the fallback has verified nothing about the memory that will ship.
3. **The tick is 260 clocks, not 173** (integer division of 60 MHz/115200/2).
   The 173 figure was the 40 MHz operating point; ADR-005 moved the core to
   60 MHz on 2026-09-21 and the real baud is 115,385 (+0.16%). If you see 173
   or 174 in a *current* claim it is stale — 173 survives only inside historical
   narration (the ADR-004 load-window story), where it is accurate.
4. **`tb_pe_soc_uart.v` `$readmemh`s an assembled `.hex`.** `run_all.sh` now runs
   `run_firmware_tests.sh` first so it can never simulate a stale image. If you add
   another SoC TB that loads firmware, keep that ordering.
5. **The lint gate is load-bearing; do not route around it.** `regress/lint.sh` runs
   Verilator `-Wall` and a yosys elaboration check on every top, and `run_all.sh`
   fails if either finds anything. An earlier revision of this file called those
   warnings "intentional". Two of them were real defects that NO testbench can
   reach, because a testbench only sees the simulator's resolution of illegal RTL:
   `tick_flag` had two `always_ff` drivers (Icarus raced it, losing half the ticks
   a poll loop should have seen; yosys tied it to a constant 0, so the STATUS port
   was dead in silicon), and `assign dbg_pc = u_cpu.pc` was a hierarchical
   reference that yosys drove backwards into an implicit wire. Both were printed
   on every run and discarded, because `synth_area.sh` captured yosys's output and
   grepped it only for numbers. If you add RTL and the gate complains, the gate is
   right.
5b. **Hardware that no firmware exercises is untested hardware.** The STATUS port
   had no program reading it for an entire milestone, which is exactly why its
   flop could be a constant and the regression stayed green.
   `firmware/tick_count.pe` + `tb/tb_pe_soc_tick.v` exist to close that.
   When you add a peripheral, add the program that uses it in the same change.
6. **The LibreLane `--dockerized` wrapper cannot auto-enable ihp-sg13g2.** Invoke
   the container with explicit `-p ihp-sg13g2 -s sg13g2_stdcell`. Command is in
   `wiki/STATUS.md` and `README.md`. This cost hours once; do not rediscover it.
7. **Check a test vector is not a bit palindrome before trusting a bit-order
   test.** `0x5A` reverses to itself, so an SPI master that shifted LSB-first
   instead of MSB-first would put the *identical levels on the wire* and no
   assertion could tell. Same for `0x00`, `0xFF`, `0x0F`, `0x3C`, `0x81`, `0xAA`.
   `int('{:08b}'.format(b)[::-1], 2) != b` is the check. STATUS gotcha 30.
8. **Not every mutation is catchable, and an uncaught one is not automatically a
   hole.** Sampling MISO before rather than after the SCLK rise is *equivalent*
   for a CPHA=0 slave (MISO is held from the falling edge), so that mutation
   cannot change observable behaviour and no test can fail on it. The catchable
   SPI mutations were the bit-order flip and driving MOSI after the rise (the
   classic CPHA error). Check whether a mutation is observable before treating
   its survival as a coverage gap. STATUS gotcha 31.
9. **The flow's PDN and global-routing knobs are in `flow/pe_soc.json`, with
   the reasoning inline — read those comments before changing them.** The two
   that were needed: `GRT_ADJUSTMENT: 0.0` (the generic 30% derate caused
   `GRT-0116` congestion at 4.59% utilization on a design that was 7.6% full) and
   a custom `PDN_CFG` for the SRAM's **Metal4** supplies, which
   `PDN_MACRO_CONNECTIONS` alone cannot reach. Both are STATUS gotchas 33-34.
   The standalone pdngen harness used to A/B the PDN config in ~1 minute instead
   of a 30-minute flow run is `/home/mylesp/.hermes/cache/scratch/pdn_standalone.sh`
   (scratch, not repo — but the technique is worth reusing).

10. **A watcher that greps for its own pattern waits forever.** `while pgrep -f
   "run_librelane|librelane"; do sleep 30; done` never exits: `pgrep -f` matches
   against the **full command line of every process, including the waiting
   shell**, whose cmdline literally contains the pattern. Three of these piled up
   and looked like hung flow runs. `pgrep -x <tool>` (process name only) showed 0
   — the work was done. Poll a **completion artifact** (`[ -f "$RUN/.../summary.rpt" ]`)
   rather than a process; if you must match a process, bracket the pattern
   (`[o]penroad`) or exclude `$$`; and always cap the loop. Recorded globally as
   the `background-job-watchers` skill.

## Current work list

The ordered live backlog is **`wiki/STATUS.md`, "Next steps (ordered)"**.
The review findings are closed, the passive SPI loader (`pe_ctrl`) is
implemented, tested and recorded, and the **I2C transaction layer is built**
(as of 2026-09-23): `firmware/i2c_xfer.pe` (311 words) runs START, address+W,
ACK, data, ACK, repeated START, address+R, ACK, read, NACK, STOP — verified on
the emulator across all 60 tick phases and on real RTL against an independent
Verilog slave FSM. **Item 4 is decided: the six `uo_out[7:2]` pads stay
`dbg_pc[5:0]` for now** (no readback path; 14 pads free; revisit trigger in
STATUS). **Item 5's read-only feasibility is documented in
[[reference/floorplan-feasibility]]**: the two macros plus logic fit the
template 6×4 die at ~60% occupancy, the open question is the pad ring
(`CORE_AREA` vs `DIE_AREA`), and the physical-flow evidence is deferred and
listed. `wiki/plans/through-i2c.md` is kept for its timing analysis;
`wiki/plans/i2c-transaction.md` is the completed transaction plan.

**I2C review baseline (historical, at `56ba1a9`):** the first review verified
the fixed ACK-success transaction and left three limits open — arbitration loss
recorded but continued, unexpected NACKs recorded without recovery, and SCL
stretching unhandled. **All three are closed (2026-09-23)**; the concept page
and the review's resolution section carry the evidence. What remains open is
not a recovery path but the absence of one: an abort releases and parks with an
outcome code, with **no STOP-qualified bus-free wait and no retry**. No RTL
changed in this milestone, so no new synthesis/STA
screen was needed; the previous hardening screens remain the latest evidence.

The pin matrix is already inside `pe_soc`. UART, mode-0 SPI and I2C all run as
firmware through it; `i2c_xfer.pe` exercises the full transaction (byte
transfer, ACK/NACK, addressing, repeated START, read path). The
Ethernet receive chain and frame buffer are integrated into the SoC as of
2026-09-23 (port bit 7, IO window `0x8-0xE`, `firmware/eth_rx.pe`,
`tb/tb_pe_soc_eth.v` plus its mutation suite). R2-1/R2-2 qualify the block-level
Ethernet results.

The physical results below are historical records, not checks repeated during
this review. Follow `wiki/STATUS.md` for their limitations and the standing
instruction to defer physical flow, DRC, and LVS.

If you touch `pe_crc`: its constants are generated and catalogue-checked
(`tools/gen/crc_config.py`) — never hand-edit [[reference/crc-config]]. The traps are
STATUS gotchas 17-19, and they are all of the kind that pass every obvious test.

**If you touch `pe_dru`'s `SPB`:** the ceiling is **16**, not "any multiple of 4".
`phase` is 4 bits and `4'(SPB-1)` truncates above it, which kills all capture
silently. Both guards are elaboration errors now, and `regress/param_guards.sh` (run by
`run_all.sh`) requires them to actually reject. SPB=12 is the 60 MHz grid and
passes the existing nominal-grid tests; R2-1 covers the asynchronous failure.

**Clock plan (ADR-005, 2026-09-21; LOCKED 2026-09-22):** **60 MHz operating
point** — 66 MHz is *not* usable. It provably fails the 10BASE-T TX jitter
conformance window (8.0/8.5 BT ±11 ns) at any edge placement, dithered or not;
60 MHz keeps every hard protocol exact and refines the RX grid 50% (SPB 8 -> 12).
**The 66 MHz STA signoff target is retired** (both flow configs now close at
`CLOCK_PERIOD` 16.667 ns) and **60 MHz is no longer a parameter** — `CLK_HZ` is a
`localparam` in `pe_soc`, because nothing ever instantiated the SoC at any
other rate. `reference/clock-arithmetic.md` is the generated constant table.

**The SRAM WAS the critical path, and the SoC now has the signoff that covers it.**
The 1024x16 macro's `A_CLK` -> `A_DOUT` is 7.25 ns at the slow corner = 43% of a
16.667 ns period. `pe_imem` has no output register by design (it would add a cycle
and break the CPU's fetch-ahead). The pe_serdes STA run has no SRAM in it, so the
SoC needed its own timing run. The recorded post-route result at the current
**60 MHz / 16.667 ns** target (`RUN_2026-09-22_02-58-32`) has worst-case setup
slack **+2.6601 ns** and hold slack **+0.1209 ns**, with zero violating timing
paths across three corners. See `wiki/STATUS.md`, "Timing margin at the 60 MHz
operating point", for the measured results and remaining slew/cap limitations.
Two flow settings were needed and both are documented in `flow/pe_soc.json`
with the reasoning inline: **`GRT_ADJUSTMENT: 0.0`** (the generic 30% derate was
causing `GRT-0116` congestion at 4.59% utilization) and a custom **`PDN_CFG`**
(`flow/pe_soc_pdn.tcl`) because the macro's supplies are on **Metal4** while
the PDN grid is TopMetal1/TopMetal2 — `PDN_MACRO_CONNECTIONS` connects them
logically but builds no physical path, so the grid check failed with `PSM-0069`.
STATUS gotchas 33-34.

It now has a top level to plug into. `rtl/tt_um_protocol_emulator.v` (added
2026-09-20) is the Tiny Tapeout deliverable: before it there was no `tt_um_*`
module anywhere, so nothing in the repo was submittable and every pin-budget
conclusion in the wiki described a pad interface no RTL implemented. It wires
`uio_oe[1:0]` to open-drain SDA/SCL with a fixed mapping that the pin matrix
replaces. Read its header before writing the matrix: it states the two Tiny
Tapeout rules that are expensive to get wrong (`ena` must gate nothing, and every
output must be driven in every state), and `tb/tb_tt_um_protocol_emulator.v`
enforces both continuously.

## Conventions this repo expects

- Verilog under `rtl/`, one header comment per module stating the contract and the
  reason for each non-obvious choice. Read `rtl/pe_serdes.v` and `rtl/pe_cpu.v`
  before writing new RTL — the house style is "explain the trap you avoided".
- Every TB is self-checking and prints `PASS: <name>` on success; `run_all.sh`
  greps for that. Add new TBs to its `CASES` array or they are not in the
  regression.
- Numbers in wiki pages are generated where possible (`tools/gen/*.py --check` is
  in the regression). Hand-typed numbers rot; generated ones cannot.
- The wiki is the design record, not documentation-by-afterthought:
  `wiki/STATUS.md` + `wiki/log.md` are updated as work lands. Keep them current or
  the next agent starts from a lie.

## Environment

PDK `~/pdk/IHP-Open-PDK`; Ciel `~/.ciel` (`ihp-sg13g2` enabled); EDA venv
`~/venvs/asic`; LibreLane run dirs under `~/asic-runs` (outside git). Tools needed
for the regression: `iverilog` (≥11), `yosys`, `python3`. `verilator` and
`rsvg-convert` are used by lint/diagram tooling only.
