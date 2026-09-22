# Handoff — state of the repo (2026-09-22)

Written for whoever picks this up next, human or agent. If you are an agent: read
this, then `wiki/STATUS.md`, then `reviews/2026-09-22/REVIEW.md` (the nine-finding
review and how each one was worked). The pair is the orientation, and it is
current as of the timestamp above.

## What is verified right now

Run these two and you will see the state, not a claim about it:

```bash
./tb/run_all.sh            # 26/26 TBs + 17/17 firmware + lint + 4 mutation
                           # suites + generated-doc drift, exits 0
./tb/run_all.sh --fast     # same verdicts, parallel TB loop, 4-state iverilog
./tb/synth_area.sh         # mapped cells/area for all blocks; non-zero on
                           # a yosys driver conflict, ERROR or implicit declaration
```

Measured 2026-09-22 after the review work: `run_all.sh --fast` →
`TOTAL: 26 PASS: 26 FAIL: 0`, `FIRMWARE: 17 PASS: 17 FAIL: 0`, `lint clean`
(13 verilator tops + 11 yosys elaborations), all four mutation suites green, plus
`signal glossary up to date`, `protocol pin budget up to date`,
`sram budget up to date`, `crc config up to date`, `clock arithmetic up to date`,
`block diagram up to date`, `canvas viewer: OK`. The `gen_*` docs are generated
from the RTL/PDK and drift-checked inside the regression, so a renamed port or
deleted TB fails the run. A `git archive` clone with none of the ignored diagrams
present also exits 0 (the diagram gate is a committed source hash now; see
`reviews/2026-09-22/REVIEW.md` finding 7).

## The thing that actually works

`firmware/uart_echo.pe` is a complete 115200 8N1 half-duplex UART. It is not RTL.
It runs on `rtl/pe_cpu.v` inside `rtl/pe_uart_soc.v` (one input pin, one output
pin, a tick counter). `tb/tb_pe_uart_soc.v` drives a real waveform on RX and
decodes TX, and passes on 41/42/00/FF with 8.6–8.7 µs bit cells measured at the
pin. `tools/peemu.py` reproduces the same bytes cycle-accurately, which is the
fast loop for firmware work (2 s, no iverilog).

If you change anything in the firmware timing path, run **both** the TB and the
emulator. They disagreed once and that disagreement is how the real bug was found
(see below).

## The 2026-09-22 review, in one paragraph

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
     repo.** `tb/sram_model.sh` locates it and FAILS LOUDLY if absent — never fall
     back to `pe_imem`'s `FLOP=1` array silently, because a testbench that runs
     against the fallback has verified nothing about the memory that will ship.
3. **The tick is 260 clocks, not 173** (integer division of 60 MHz/115200/2).
   The 173 figure was the 40 MHz operating point; ADR-005 moved the core to
   60 MHz on 2026-09-21 and the real baud is 115,385 (+0.16%). If you see 173
   or 174 in a *current* claim it is stale — 173 survives only inside historical
   narration (the ADR-004 load-window story), where it is accurate.
4. **`tb_pe_uart_soc.v` `$readmemh`s an assembled `.hex`.** `run_all.sh` now runs
   `run_firmware_tests.sh` first so it can never simulate a stale image. If you add
   another SoC TB that loads firmware, keep that ordering.
5. **The lint gate is load-bearing; do not route around it.** `tb/lint.sh` runs
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
   `firmware/tick_count.pe` + `tb/tb_pe_tick_status.v` exist to close that.
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
9. **The flow's PDN and global-routing knobs are in `flow/pe_uart_soc.json`, with
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

`wiki/plans/through-i2c.md` is authoritative — it has the definition of done for
the I2C milestone, three blockers with numbers, the tick plan (1 µs tick = 60
clocks, tLOW 5 ticks / tHIGH 6 → 90.9 kbit/s), the read-path timing budget
(40 cycles to sample and arbitrate), and an 8-step ordered work list whose step 1
is done.

**Updated 2026-09-22: SPI-as-firmware is DONE, and the full SoC routes and times
clean.** `firmware/spi_xfer.pe` is a mode-0 SPI master running on the same 8-bit
port (and the same `PIN_IN_MASK`) as the UART; `tools/peemu.py` models a mode-0
slave so the firmware is exercised end to end ([[concepts/spi-as-firmware]]).
`RUN_2026-09-22_00-33-59` finished detailed routing with **0 DRC violations** and
signed off **setup WNS +1.234 ns / hold +0.127 ns / 0 violations at all three
corners**; the SRAM in-context access is **7.639 ns** against the 16.667 ns
period (it was signed against 15.15 ns; the target is now 60 MHz — see
[[reference/clock-arithmetic]])
([[reference/sram-budget]]). That closes the "SRAM is the critical path and no
signoff covers it" risk below. What remains of the ordered list is **step 4: the
pin matrix / OE** (open-drain, read-back, tri-state) for I2C. **Update
2026-09-20: the CRC LFSR and the DRU were already BUILT** (`rtl/pe_crc.v` 209
cells, `rtl/pe_dru.v` 116 cells, both with self-checking TBs and both in
`run_all.sh`), and the SRAM swap landed on 2026-09-20.

If you touch `pe_crc`: its constants are generated and catalogue-checked
(`tools/gen_crc_config.py`) — never hand-edit [[reference/crc-config]]. The traps are
STATUS gotchas 17-19, and they are all of the kind that pass every obvious test.

**If you touch `pe_dru`'s `SPB`:** the ceiling is **16**, not "any multiple of 4".
`phase` is 4 bits and `4'(SPB-1)` truncates above it, which kills all capture
silently. Both guards are elaboration errors now, and `tb/param_guards.sh` (run by
`run_all.sh`) requires them to actually reject. SPB=12 is the 60 MHz grid and
is verified passing.

**Clock plan (ADR-005, 2026-09-21; LOCKED 2026-09-22):** **60 MHz operating
point** — 66 MHz is *not* usable. It provably fails the 10BASE-T TX jitter
conformance window (8.0/8.5 BT ±11 ns) at any edge placement, dithered or not;
60 MHz keeps every hard protocol exact and refines the RX grid 50% (SPB 8 -> 12).
**The 66 MHz STA signoff target is retired** (both flow configs now close at
`CLOCK_PERIOD` 16.667 ns) and **60 MHz is no longer a parameter** — `CLK_HZ` is a
`localparam` in `pe_uart_soc`, because nothing ever instantiated the SoC at any
other rate. `reference/clock-arithmetic.md` is the generated constant table.

**The SRAM WAS the critical path, and the SoC now has the signoff that covers it.**
The 1024x16 macro's `A_CLK` -> `A_DOUT` is 7.25 ns at the slow corner = 43% of a
16.667 ns period. `pe_imem` has no output register by design (it would add a cycle
and break the CPU's fetch-ahead). The pe_serdes STA run has no SRAM in it, so the
SoC needed its own run at 15.15 ns — and that run now exists: the full-SoC
LibreLane flow closed setup at **+1.234 ns** and hold at **+0.127 ns** worst-case
with zero violating paths at all three corners, and measured the SRAM access
**in context** at **7.639 ns**. Numbers and method: [[reference/sram-budget]].
Two flow settings were needed and both are documented in `flow/pe_uart_soc.json`
with the reasoning inline: **`GRT_ADJUSTMENT: 0.0`** (the generic 30% derate was
causing `GRT-0116` congestion at 4.59% utilization) and a custom **`PDN_CFG`**
(`flow/pe_uart_soc_pdn.tcl`) because the macro's supplies are on **Metal4** while
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
- Numbers in wiki pages are generated where possible (`tools/gen_*.py --check` is
  in the regression). Hand-typed numbers rot; generated ones cannot.
- The wiki is the design record, not documentation-by-afterthought:
  `wiki/STATUS.md` + `wiki/log.md` are updated as work lands. Keep them current or
  the next agent starts from a lie.

## Environment

PDK `~/pdk/IHP-Open-PDK`; Ciel `~/.ciel` (`ihp-sg13g2` enabled); EDA venv
`~/venvs/asic`; LibreLane run dirs under `~/asic-runs` (outside git). Tools needed
for the regression: `iverilog` (≥11), `yosys`, `python3`. `verilator` and
`rsvg-convert` are used by lint/diagram tooling only.
