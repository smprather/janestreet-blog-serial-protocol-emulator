# Handoff — state of the repo (2026-09-20)

Written for whoever picks this up next, human or agent. If you are an agent: read
this, then `wiki/STATUS.md`, then `wiki/plans/through-i2c.md`. That pair is the
orientation, and it is current as of the timestamp above.

## What is verified right now

Run these two and you will see the state, not a claim about it:

```bash
./tb/run_all.sh            # 18/18 TBs + 11/11 firmware tests + lint, exits 0
./tb/synth_area.sh         # mapped cells/area for all 8 blocks; non-zero on
                           # a yosys driver conflict or implicit declaration
```

Measured 2026-09-20: `run_all.sh` → `TOTAL: 18 PASS: 18 FAIL: 0`, `lint clean`, plus
`signal glossary up to date`, `protocol pin budget up to date`,
`sram budget up to date`. The `gen_*` docs are generated from the RTL/PDK and
drift-checked inside the regression, so a renamed port or deleted TB fails the run.

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

## Where the bodies are buried

1. **A TB that "waits for" an event it may have missed tests nothing.** The UART
   SoC TB was red for three defects, the worst being `@(negedge tx_pin)` running
   *after* the echo had already started — it silently anchored on the wrong edge
   and decoded every byte shifted. Fixed by latching the edge in an `always` block
   and sampling on a grid anchored to the latched time. If you write a TB against
   firmware that replies immediately, latch, don't wait. Details: `wiki/log.md`
   2026-09-20 and `wiki/plans/through-i2c.md` Blocker 1.
2. **The SoC's mapped area (177.3k µm² local, 182.1k including the CPU) is flop
   memory, not a bug.** IMEM/DMEM are
   register arrays; yosys emits ~2,215 flops. The fix is an SRAM macro
   (`1P_1024x16`, 14% of the template die) and it is planned, not done. Do not
   "fix" it by rewriting the memory as inferred RAM without reading
   `wiki/reference/sram-budget.md` first — the macros are fixed shapes and the die
   is 3:1 wide-and-short, so most do not fit.
3. **The tick is 173 clocks, not 174** (integer division of 40 MHz/115200/2). Three
   comments were corrected on 2026-09-20; real baud is 115,607 (+0.35%). If you see
   174 anywhere it is stale.
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

## Current work list

`wiki/plans/through-i2c.md` is authoritative — it has the definition of done for
the I2C milestone, three blockers with numbers, the tick plan (1 µs tick = 40
clocks, tLOW 5 ticks / tHIGH 6 → 90.9 kbit/s), the read-path timing budget
(40 cycles to sample and arbitrate), and an 8-step ordered work list whose step 1
is done.

The next unstarted item is **step 4: the pin matrix / OE** (open-drain, read-back,
tri-state) — the real new hardware gating I2C and every stretch protocol. It is
independent of everything else and has its own TB as an acceptance test.

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
