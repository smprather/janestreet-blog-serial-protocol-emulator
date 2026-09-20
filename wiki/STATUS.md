# Project Status — Milestone 2

> **Resume here after a context flush.** Read this first, then `wiki/index.md`.
> Last updated: 2026-09-20 · branch `main` · plan for the next milestone:
> **[[plans/through-i2c]]** — read that second, it is the work list.

## Where we are

Both layers of the thesis now exist and are verified:

- **Milestone 1 — shared hardware layer.** The SERDES, the line codecs and the
  codec mux, all self-checking-TB verified, all synthesized on real IHP sg13g2
  cells, and the SERDES through the full LibreLane place-and-route flow to a
  clean 66 MHz signoff.
- **Milestone 2 — the programmable core.** A CPU, an assembler, a bit-accurate
  emulator, and a **UART written entirely in firmware** running on real RTL.
  There is no UART state machine in the hardware: the framing and bit timing are
  a program (`firmware/uart_echo.pe`) that the CPU executes against one input
  pin, one output pin and a tick counter. That is the competition thesis,
  demonstrated end to end in simulation.

**The repo is now submittable**: `rtl/tt_um_protocol_emulator.v` and `info.yaml`
exist, so there is a `tt_um_*` top level with a real pad interface
(`ui_in`/`uo_out`/`uio_*`), an `ena` that gates nothing, and open-drain SDA/SCL on
`uio[1:0]`. Until 2026-09-20 every pin-budget conclusion in the wiki described an
interface that no RTL in this repo implemented.

Nothing has been taped out. The pin matrix, the DRU, and the SRAM swap do not
exist yet. **[[plans/through-i2c]] has the ordered work list to the next
milestone** (the I2C transaction); the summary is at the bottom of this file.

```
                    +---------------------+
   firmware  --->   |  pe_cpu             |   BUILT (387 cells) — ISA in its header
   (.pe -> .hex)    |  16 opcodes, A/Y/X  |
                    +---------------------+
                              |
                    +---------------------+     +------------------+
                    |   pe_uart_soc       | <-> |  tick timer      |  BUILT
                    |   (CPU + IMEM/DMEM) |     |  173 clk = half  |  (flop memory —
                    +---------------------+     |  a 115200 bit    |   see below)
                              |
              +---------------+---------------+
              |                               |
    +-------------------+           +-------------------+
    |  pe_serdes        |           |  bit-banged pins  |   BOTH PROVEN
    |  539 cells routed |           |  (UART today)     |   SERDES by 10 TBs,
    |  bit_en paced     |           |                   |   bit-bang by UART
    +-------------------+           +-------------------+
              |
    +-------------------+           +-------------------+
    |  pe_codec_mux     |           |  DRU (oversampled |   NOT BUILT
    |  stuff/nrzi/manch |           |  phase picker)    |   spec in wiki
    +-------------------+           +-------------------+
              |                               |
    +-------------------+           +-------------------+
    |  word FIFO        |           |  pin matrix / OE  |   NOT BUILT
    |  (not built)      |           |  / tri-state      |   gates I2C + stretch
    +-------------------+           +-------------------+
                              |
                +---------------------------+
                | tt_um_protocol_emulator   |  BUILT — the deliverable.
                | ui_in / uo_out / uio_oe   |  Pad contract TB: no X on an
                | open-drain SDA+SCL        |  output, ena gates nothing,
                +---------------------------+  uio never drives high.
                              |
                        TT GPIO pins
```

**Two implementation styles now coexist on purpose.** The SERDES is a word
engine: load 8–32 bits, pace with `bit_en`, collect a word — the right shape for
UART/SPI/CAN/USB. The firmware core bit-bangs instead, which is the right shape
when control flow is per-bit (I2C ACK/arbitration/stretch). [[plans/through-i2c]]
states the reasoning; do not "unify" them without reading it.

## What is built and verified

| Block | File | Cells | Area (µm²) | TBs |
|---|---|---|---|---|
| SERDES (bit engine, 1–32 b, runtime order) | `rtl/pe_serdes.v` | 539 | 11,223 synth → **17,211 routed** | `tb_pe_serdes.v` + 9 protocol TBs |
| NRZI codec | `rtl/pe_line_codec.v` | 15 | 212 | `tb_pe_nrzi` |
| Manchester codec | `rtl/pe_line_codec.v` | 7 | 120 | `tb_pe_manch` |
| Bit stuffer/unstuffer | `rtl/pe_line_codec.v` | 84 | 1,290 | `tb_pe_bitstuff` |
| Codec pipeline mux | `rtl/pe_codec_mux.v` | 115 | 1,691 (whole pipeline) | `tb_pe_codec_mux` |
| **CPU** (16-bit insn, 16 opcodes, 8-bit PC) | `rtl/pe_cpu.v` | 387 | 4,952 | `tb_pe_cpu` |
| **Software-UART SoC** (CPU + tick timer + 2 pins) | `rtl/pe_uart_soc.v` | 8,744 | 182,650 total | `tb_pe_uart_soc`, `tb_pe_tick_status` |
| **TT top level** (the deliverable) | `rtl/tt_um_protocol_emulator.v` | 8,743 | 182,652 total | `tb_tt_um_protocol_emulator` |

Numbers from `tb/synth_area.sh` (sg13g2 typ corner, mapped pre-route). The routed
figure for the SERDES comes from the full LibreLane flow (route+CTS+PDN inflate
area ~1.54× over mapped), reproducible from a clean clone with
`flow/run_librelane.sh flow/pe_serdes.json`.

Two reporting changes on 2026-09-20, so these do not look like regressions against
the previous revision of this table:

- **Areas are now whole-design totals.** `synth_area.sh` read yosys's "Chip area for
  module 'X'", which is X's *local* area excluding submodules — 69 µm² for the codec
  mux (the glue only) and 0 µm² for any wrapper. It now prefers "Chip area for top
  module", so the codec mux reads 1,691 and the SoC reads one number instead of
  needing the reader to add the CPU back in.
- **A few blocks genuinely grew**, all of it fixes: NRZI and Manchester gained a
  frame-boundary `clr` and a registered error, the CPU gained real `dbg_pc`/`dbg_a`
  ports (they were hierarchical references that did not synthesise), and the SoC's
  `tick_flag` became an actual flop instead of a driver conflict yosys was tying to
  a constant.

**The SoC's 182.7k µm² figure is flop memory, not a synthesis failure**: its IMEM
(128×16) and DMEM (16×8) are register arrays, so yosys emits ~2,215 flops at
48.9 µm² each. The `ram_style` attributes on those arrays are FPGA pragmas and do
nothing in this flow — sg13g2 has no inferable block RAM and no SRAM compiler,
only fixed macros. For comparison a `1P_256x16` SRAM macro holds 4,096 bits in
28,127 µm². Replacing flops with a macro is the documented next step (see
[[plans/through-i2c]] Blocker 3 and [[reference/sram-budget]]), and it changes
nothing in the CPU's interface or cycle model — the instruction port was written
for a registered ROM from the start.

**Regression: 18/18 testbenches + 11/11 firmware tests pass, and the lint gate is
clean** (`tb/run_all.sh` runs the firmware regression first, then every TB, then
`tb/lint.sh`, then the generated-doc drift checks).

**`tb/lint.sh` is not optional, and the reason is the most useful thing in this
file.** A previous revision said the Verilator warnings were "intentional". They
were not. Two of them were real defects that no testbench could ever have caught,
because a testbench only ever sees the *simulator's* resolution of illegal RTL:

- `tick_flag` was driven by two `always_ff` blocks. Icarus raced it (measured: 50 of
  100 ticks silently dropped by a two-instruction poll loop) and **yosys resolved the
  driver-driver conflict to a constant 0**, so the STATUS port worked in simulation
  and was dead in the netlist. Nothing caught it because no firmware read the port —
  `firmware/tick_count.pe` and `tb/tb_pe_tick_status.v` now do.
- `assign dbg_pc = u_cpu.pc` is a cross-module reference. Icarus accepts it; yosys
  declared an implicit wire and drove it *backwards*, leaving `dbg_pc[7:1]` tied low
  in the netlist. They are real ports on `pe_cpu` now.

Both were printed by the tools on every run and discarded: `tb/synth_area.sh`
captured yosys's output and grepped it only for numbers. It now surfaces them and
exits non-zero. **An area report that hides correctness warnings looks like a check
and is not one.**

Protocol testbenches (one per target, each wrapping the same SERDES with that
protocol's real framing): UART 8N1 · SPI mode 0 full duplex · I2C 7-bit
addr/RW/repeated-start · JTAG TAP walk + BSR · SWD req/ACK/data/parity ·
PS/2 11-bit odd-parity · CAN classic + stuffing + CRC-15 · USB-LS NRZI+stuffing ·
10BASE-T Manchester + CRC-32.

**The software-UART demonstration** (Milestone 2's headline): `firmware/uart_echo.pe`
is a half-duplex 115200 8N1 echo, assembled by `tools/peasm.py` to 114 words,
executed by `rtl/pe_cpu.v` inside `rtl/pe_uart_soc.v`. `tb/tb_pe_uart_soc.v`
drives a real 8N1 waveform on the RX pin and decodes the TX pin: **PASS on
41/42/00/FF**, TX cell width 8.6–8.7 µs measured at the pin against the nominal
8.68 µs. `tools/peemu.py` reproduces the same four bytes cycle-accurately, which
is the fast firmware-development loop (2 s vs a 1 min RTL build).

**Routed signoff of pe_serdes** (full LibreLane Classic on ihp-sg13g2, 66 MHz):
0 DRC, 0 LVS, setup WS +7.6 ns (slow corner), hold WS +0.116 ns (fast corner),
die 161.7 × 180.4 µm, 78 % utilization. Run dir: `~/asic-runs/pe-serdes`.

## Design decisions in force

| Decision | Where |
|---|---|
| 8× oversampling per bit (4 samples per 50 ns half-UI) = 12.5 ns RX grid | `decisions/adr-001-8x-oversampling.md` |
| Std-cell **latch-pair dual-edge flop** for DDR capture; no custom DET | `decisions/adr-002-latch-pair-det-flop.md` |
| **40 MHz board clock, DDR** = exact integers for every hard protocol (50 ns = 2 ticks) | `concepts/tx-timing-generation.md` |
| **Sign off at 66 MHz, run at 40** (turbo mode); 1.0 ns clock uncertainty | `concepts/tx-timing-generation.md` |
| SERDES words ≤ 32 b; longer fields chunk (SWD parity, CAN/USB/ETH payloads) | `rtl/pe_serdes.v` header |
| Codec pipeline order fixed (stuff → line-code); cfg selects the **subset** | `rtl/pe_codec_mux.v` header |
| No elasticity FIFO needed (source-sync protocols + per-edge re-lock) | `concepts/cdr-oversampling.md` |
| Every codec stage takes `clr` and reports `rx_err` REGISTERED, one cycle after the strobe | `rtl/pe_line_codec.v` header |
| `ena` must never gate logic; every pad output driven in every state | `rtl/tt_um_protocol_emulator.v` header |

## Toolchain — exact commands

```bash
# EVERYTHING: firmware regression (assemble + emulator) then all 16 RTL TBs.
# Runs the firmware first because tb_pe_uart_soc $readmemh's the .hex it builds.
cd ~/janestreet-blog-serial-protocol-emulator && ./tb/run_all.sh

# firmware only (assemble firmware/*.pe -> .hex, run the emulator cases)
./tb/run_firmware_tests.sh

# one program by hand, with a cycle trace
python3 tools/peasm.py firmware/uart_echo.pe -o firmware/uart_echo.hex
python3 tools/peemu.py firmware/uart_echo.hex --send "41 42" --max-cycles 900000

# mapped area per block (native yosys + IHP liberty). Exits non-zero if yosys
# reports a driver conflict or an implicit declaration -- it used to swallow them.
./tb/synth_area.sh

# the static gate on its own: verilator -Wall + a yosys elaboration check.
# run_all.sh runs this; there are no accepted warnings in this RTL.
./tb/lint.sh

# live diagram pane (side-quest): start the dashboard once, write SVG/HTML into
# diagrams/ and it renders live in the Canvas tab (~1s, no reload)
hermes dashboard                                   # http://127.0.0.1:9119/canvas
tools/live-canvas/canvas-publish.sh scratch.svg    # or just cp
# flowchart from a spec (fails with exit 3 if an edge crosses a shape, which is
# how the layout bugs get caught before they ship):
tools/live-canvas/gen_flowchart.py tools/live-canvas/flowcharts/plan-through-i2c.json

# full place & route. The config now lives IN THE REPO (flow/), so the signoff
# result is reproducible from a clean clone; it used to exist only in
# ~/asic-runs, which meant the one routed number the project claims could not be
# regenerated by anyone else. The script handles the explicit -p / -s flags the
# dockerized wrapper needs (see gotcha 1) and stages sources into the run dir.
flow/run_librelane.sh flow/pe_serdes.json
```

Environment: PDK clone `~/pdk/IHP-Open-PDK`; Ciel PDK `~/.ciel` (enabled
`ihp-sg13g2` c4b8b4e); venv `~/venvs/asic` (volare + LibreLane 3.0.14); run dirs
`~/asic-runs` (outside git). Details: `concepts/pdk-toolchain.md`.

Waveforms: every TB writes a VCD into `sim/` (untracked — they churn on each
run; `git add -f sim/*.vcd` restores them to the repo if wanted).

## Gotchas learned the hard way

1. **LibreLane's `--dockerized` wrapper cannot auto-enable the IHP PDK** — it
   reports "PDK ihp-sg13g2 was not found" even when `~/.ciel/ihp-sg13g2` resolves
   and `config.tcl` exists. Workaround: invoke the container directly with
   explicit `-p ihp-sg13g2 -s sg13g2_stdcell` (command above). The smoke test and
   `--run-example` paths work, plain config runs do not.
2. **pip-only LibreLane is unsupported** (needs Nix or Docker); `--docker-no-tty`
   is required in headless shells.
3. **volare family name uses an underscore** (`--pdk ihp_sg13g2`) and needs an
   explicit version from `volare ls-remote`.
4. **GCC 16 breaks the stock volare/librelane pip install** (pybind11 C++ level
   probe): `pip install --upgrade pybind11 setuptools wheel`, then
   `CXX=g++ pip install --no-build-isolation volare librelane`.
5. **yosys `PROC_DFF` rejects `if (!rst_n || clr)`** — an async reset OR'd with a
   level signal ("multiple edge sensitive events"). Use a separate synchronous
   clear branch.
6. **Single-cycle event pulses get missed** in TBs behind trailing protocol
   timing (stop bits, EOF, ACK slots) — use sticky flags, exactly as the core's
   interrupt logic will.
7. **TB sampling order**: combinational stages (stuff/manch) are valid *before*
   the committing strobe; a registered stage (NRZI line level) only *after* it.
8. **A TB model must mirror the DUT's state machine** — the CAN/USB destuffer
   resets its run counter after the stuff bit, not on the 5th identical bit.
9. Non-interactive shells emit `stty`/`tcsetattr` noise and a bashrc `sort -hn`
   error — cosmetic; check the payload's real exit status.
10. **A testbench that "waits for" an event it may have already missed tests
    nothing.** `tb_pe_uart_soc.v` sat red for hours because `@(negedge tx_pin)`
    ran after the echo was already in flight (the firmware answers the moment it
    has the byte, and RX/TX are separate pins), so it anchored on the *last data
    bit* and every byte decoded shifted. Latch the edge in an `always` monitor,
    then anchor the sample grid to the latched time. Same class of bug as the
    sticky-flag lesson (gotcha 6) from Milestone 1.
11. **The emulator is the fast loop, and it must mirror the RTL's cycle model —
    including when they disagree.** `tools/peemu.py` reproduced the UART byte
    correctly while the RTL TB failed; that asymmetry was the clue that the bug
    was in the TB/firmware, not the CPU. Keep both, and treat a disagreement as
    a signal, not an inconvenience.
12. **A simulator's resolution of illegal RTL is not the synthesiser's, so a
    green testbench says NOTHING about the netlist.** Two drivers on one flop
    raced in Icarus and became a constant 0 in yosys. A hierarchical reference
    (`assign dbg_pc = u_cpu.pc`) simulated fine and was driven backwards into an
    implicit wire by yosys. Neither is reachable by any testbench. `tb/lint.sh`
    is the only thing that can catch this class, which is why it is in
    `run_all.sh` and not a thing you remember to run.
13. **A tool whose warnings you discard is not a check.** `synth_area.sh`
    captured yosys's entire output and grepped it for numbers, so both defects
    above were printed on every single run for a whole milestone and never read.
    If a script captures output, it owes the reader a decision about the parts
    it did not use.
14. **Hardware nothing exercises is hardware you have not tested.** The STATUS
    port had no firmware reading it, so its flop could be a constant and the
    regression stayed green. When you add a peripheral, add the program that
    uses it (`firmware/tick_count.pe`) in the same change.
15. **A test that only checks the output cannot see broken bookkeeping.** The
    UART echo path reads slot 15, so a receive-buffer write pointer that never
    advanced (`AND 0x0E` applied to ptr+1 is always 0) passed every byte-level
    test for a milestone. `--expect-buffer` now checks the state, not just the
    bytes.
16. **Silent truncation is the assembler's worst failure mode.** Every field in
    this ISA is narrower than the immediate that fits in it, so `JMP 200`,
    `LDM A, 128` (which re-encoded as `LDM X`) and a 129-word program all
    assembled clean and ran wrong. `tools/peasm.py` now rejects all of them.

## Open questions / risks

- **IHP-specific max pad clock is unpublished.** The ~66 MHz figure is sky130
  pad-macro-derived. Signing off at 66 gives margin if the real limit is lower.
- **No SRAM compiler for sg13g2** — only fixed macros (30 shapes; the wiki's
  earlier "256×16 … 2048×64" understated the set, there are also 4096 and 8192
  classes, 2P variants, and 64×16/64×32 without BIST). Sizing is analysed in
  [[reference/sram-budget]]: 1–2 KB is comfortable, 4 KB is the practical
  ceiling, and the densest macros in the PDK **do not fit** the 3:1 die.
- **Tile size discrepancy**: blog says ~200×150 µm/tile, the TT template's
  `info.yaml` says ~167×108 µm. Use the template for layout math; re-check after
  the first real floorplan of the full design.
- **The `~66 MHz` ceiling and `--docker-no-tty` wrapper bug** are both worth
  confirming with TT/Jane Street (Discord / asic-competition@janestreet.com).

## Next steps (ordered)

**The work list is [[plans/through-i2c]]** — it has the definition of done, the
three blockers with numbers, and an 8-step ordered plan to a real I2C transaction.
Its Blocker 1 (the red UART RTL test) is **fixed as of 2026-09-20**; steps 2 and 3
of that plan are the housekeeping this file just went through.

Beyond I2C, in rough order:
0. **Pin matrix**, which now has a real top level to plug into
   (`rtl/tt_um_protocol_emulator.v` wires `uio_oe` to pads and its TB asserts the
   open-drain property). It replaces the wrapper's fixed pin mapping.
1. **DRU** (oversampled phase-picker): edge detect, 3-bit phase counter with
   re-lock on every edge, mid-bit strobe, preamble lock, majority-vote filter.
   Spec is in `concepts/cdr-oversampling.md`; ~60–100 cells. Needed for 10BASE-T
   and PS/2 receive, not for I2C.
2. **Word FIFO** (16–32 deep) if gapless multi-word streaming is wanted.
3. **Full-chip floorplan** against the 32-tile budget; then the flow end to end.
4. **SRAM swap** for instruction memory once a second protocol lands
   ([[plans/through-i2c]] Blocker 3 has the macro choice and the area numbers).

Done since the last revision of this list: the programmable core exists
(`rtl/pe_cpu.v`), the assembler and emulator exist (`tools/peasm.py`,
`tools/peemu.py`), and a UART runs in firmware on real RTL. Then a review pass on
2026-09-20 fixed four defects that the green regression could not see (the
two-driver `tick_flag`, the unsynthesisable debug ports, the stuck receive-buffer
pointer, and the assembler's silent truncation), added the gate that catches that
class, and built the Tiny Tapeout top level the repo had been reasoning about
without ever writing.

## Reading order for a fresh session

1. This file.
2. `wiki/plans/through-i2c.md` — **the work list for the next milestone.**
3. `wiki/index.md` → then `concepts/competition-overview.md` (rules, budget).
4. `concepts/factored-hardware-blocks.md` (what exists / what's planned) and
   `concepts/tx-timing-generation.md` (timing + signoff policy).
5. `rtl/pe_cpu.v` header (the ISA) and `firmware/uart_echo.pe` header (how
   firmware actually uses it — the polling idiom and the timing model).
6. `concepts/cdr-oversampling.md` (the DRU spec, still unbuilt).
7. `wiki/log.md` (last ~15 entries) for recent activity.
8. `rtl/pe_serdes.v` header comment for the SERDES contract.
9. `rtl/tt_um_protocol_emulator.v` header — the pad contract, the two TT rules
   that are expensive to get wrong (`ena` gates nothing; every output driven),
   and why open-drain is native to `uio_oe`.
