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
  emulator, and **two baseline protocols written entirely in firmware** — UART
  and, as of 2026-09-22, **SPI mode 0**. Neither has a state machine in the
  hardware: the framing and bit timing are programs (`firmware/uart_echo.pe`,
  `firmware/spi_xfer.pe`) the CPU executes against the pad interface and a tick
  counter. Both protocols share the **same 8-bit port and the same direction
  mask**, so nothing in the RTL knows which one is running. That is the
  competition thesis, demonstrated end to end in simulation for two of the
  blog's three baseline protocols.

**The full SoC now routes and times clean.** On 2026-09-22 the full-SoC
LibreLane run `RUN_2026-09-22_00-33-59` closed setup and hold at all three
corners with **+1.143 ns setup slack worst-case** and the instruction-fetch path
(SRAM `A_CLK` -> `A_DOUT` -> CPU) measured in context at **7.635 ns**, against a
15.15 ns period. It finished detailed routing with **zero DRC violations** and
reached **step 57 of 80**; the flow's own gates read "Routing DRC errors clear"
and "power grid violations clear", and worst-case IR drop is **0.30%** (3.56 mV
of 1.20 V). See [[reference/sram-budget]] for the numbers and
`flow/pe_uart_soc.json` for the two flow fixes that got it there (the
`GRT_ADJUSTMENT` derate and a custom PDN config for the macro's Metal4 supplies —
[[STATUS]] gotchas 33-34).

*What still stops the flow at 80 steps:* step 57, Magic GDS streamout, cannot
extract a PR boundary from the SRAM's GDSII. The IHP macro ships **no `pblock`
layer** — its GDS has `189/4` (the IHP map's `DIEAREA`) rather than the
`prBoundary` layer LibreLane's `get_bbox.tcl` reads `FIXED_BBOX` from. This is a
PDK-macro-vs-flow-vocabulary mismatch, not a defect in this design, and the die
size it needs is already declared in the LEF (`SIZE 236.8 BY 336.46`). Gotcha 35.

**The repo is now submittable**: `rtl/tt_um_protocol_emulator.v` and `info.yaml`
exist, so there is a `tt_um_*` top level with a real pad interface
(`ui_in`/`uo_out`/`uio_*`), an `ena` that gates nothing, and open-drain SDA/SCL on
`uio[1:0]`. Until 2026-09-20 every pin-budget conclusion in the wiki described an
interface that no RTL in this repo implemented.

Nothing has been taped out. **The block diagram is now generated and drift-gated:
see [[reference/block-diagram]]** — the hand-drawn ASCII version that used to sit
here had rotted in three places at once (it still claimed the pin matrix did not
exist and that the SoC's memory was flops, both superseded, and listed `pe_dru`/
`pe_crc` as unbuilt in one place while citing their cell counts in another). A
diagram is the most-read and least-checked artifact in a repo. **[[plans/through-i2c]]
has the ordered work list to the next milestone** (the I2C transaction); the
summary is at the bottom of this file.

The one-line version, for the reader who wants it before clicking through:

```
  tt_um_protocol_emulator (BUILT, the deliverable)
    └── pe_uart_soc (BUILT) ── pe_cpu ── pe_imem ──[FLOP=0]── SRAM macro
                             └ tick timer (260 clk = half a 115200 bit)
                             └ fixed-mask port (PIN_IN_MASK 8'hF8)

  BUILT, TB-verified, INSTANTIATED NOWHERE (5):
    pe_serdes (539)  pe_dru (121)  pe_crc (209)  pe_pinmux (111)  pe_codec_mux (115)
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
| **CRC / LFSR engine** (5-, 8-, 15-, 16-, 32-bit) | `rtl/pe_crc.v` | 209 | 3,354 | `tb_pe_crc` |
| **DRU** (oversampled Manchester receive) | `rtl/pe_dru.v` | 116 | 2,065 | `tb_pe_dru` |
| **CPU** (16-bit insn, 16 opcodes, PC width from IMEM depth) | `rtl/pe_cpu.v` | 383 | 4,939 | `tb_pe_cpu` |
| **Pin matrix** (per-pin OUT/OE/IN/OD, open-drain, read-back) | `rtl/pe_pinmux.v` | **111** | **2,061** | `tb_pe_pinmux` |
| **Instruction memory** — real SRAM macro + wrapper | `rtl/pe_imem.v` | 12 glue + macro | 187 + LEF | `tb_pe_imem` |
| **Software-UART SoC** (CPU + tick timer + 8-bit pin port) | `rtl/pe_uart_soc.v` | **1,083** | **19,795 total** | `tb_pe_uart_soc`, `tb_pe_tick_status` |
| **TT top level** (the deliverable) | `rtl/tt_um_protocol_emulator.v` | **1,083** | **19,795 total** | `tb_tt_um_protocol_emulator` |

Firmware (no RTL cells — these are programs the CPU runs; see
[[concepts/spi-as-firmware]]):

| Program | Words | Verified by |
|---|---|---|
| `firmware/uart_echo.pe` — 115200 8N1 echo | 118 | `tb_pe_uart_soc.v` (real RTL), `tools/peemu.py` |
| `firmware/tick_count.pe` — STATUS-port exerciser | 8 | `tb_pe_tick_status.v` (real RTL) |
| `firmware/spi_xfer.pe` — SPI mode 0 master | 70 | `tools/peemu.py` (mode-0 slave model) |

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

**DONE 2026-09-20 — the SoC went from 8,744 cells / 182.7k µm² to 1,083 cells /
19.8k µm².** The instruction memory is now the real `1P_1024x16_c2_bm_bist` macro
(`rtl/pe_imem.v`), and the program is 1,024 words instead of 128. Measured both
ways round: 1,024 words in flops is 60,806 cells / 1,300,104 µm², which reproduces
ADR-003's 1,271 µm² per instruction word exactly.

**It did NOT change nothing, and the plan was wrong to say it would.**
[[plans/through-i2c]] Blocker 3 claimed the swap "does not change the CPU's
interface or its cycle model, because the instruction port was written for a
registered ROM from the start". The cycle model was indeed already right — the
macro's read latency is one cycle, which is what the fetch-ahead assumes. But the
CPU had a **fixed 8-bit PC**, so at 1024 words `next_pc[IAW-1:0]` was an
out-of-range part-select and the reachable program stayed 256 words regardless of
depth: 896 words of addressable-by-nothing SRAM for 79,674 µm². **The PC and the
jump-target field had to widen in the same change.** Full reasoning and the
rejected alternatives: [[decisions/adr-004-program-counter-width]].

**Regression: 21/21 testbenches + 13/13 firmware tests pass, and the lint gate is
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

**The CRC block is checked against an outside authority, not against itself.**
`tools/gen_crc_config.py` derives every constant, asserts the RevEng catalogue's
published `check` value for "123456789" for six polynomials, and refuses to write
[[reference/crc-config]] unless the derived constants reproduce it. `tb_pe_crc`
re-checks the same numbers in the RTL, using the TEXTBOOK datapath as the reference
(shift-left for non-reflected CRCs, shift-right for reflected) so agreement means the
"one right-shift register serves both families" claim is measured rather than
asserted. It also folds the DUT's OWN emitted field bits and requires the catalogue's
published `residue` — independent evidence that the wire order is the standard's.

**The DRU's grid is the claim, and it is measured exhaustively.** `tb_pe_dru` drives
every Manchester transition pattern (00, 01, 10, 11 — the complete set of things a
half-cell boundary can look like), 32-bit runs, an Ethernet preamble+SFD frame, and a
random soak, and requires the bits back. It then feeds the DRU into a real `pe_manch`
and requires its `rx_err` to stay quiet, which is what makes the halves a legal
symbol and not merely "some value". Mutation-checked: swapping `rx_first`/`rx_second`
fails the run.

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

## Area budget — where the die actually goes

Measured 2026-09-20. The mapped→die factor is **1.97**, from the only block that has
been through real place-and-route (`pe_serdes`: 11,223 mapped → 17,211 routed cells
→ 29,164 µm² die at 78% utilisation). Macros place as-is and take no inflation.

**The swap is DONE and measured** (2026-09-20, [[decisions/adr-004-program-counter-width]]).
The historical per-word figure stands and the new build confirms it:

| | Cells | Area (µm²) | Note |
|---|---|---|---|
| Instruction memory, 1,024 words in flops | 60,806 | 1,300,104 | the projection ADR-003 was built on |
| Instruction memory, 1,024 words in the macro | 12 + 1 instance | 187 glue + LEF area | measured 2026-09-20 |
| Whole SoC before the swap (128 flop words) | 8,744 | 182,650 | |
| **Whole SoC after the swap (1,024 SRAM words)** | **1,083** | **19,795** | **9.2× smaller, 8× the program** |

The flop figure reproduces ADR-003's 1,271 µm²/word exactly (60,806 cells × 21.4 µm²
/ 1,024 words), which cross-checks two measurements taken months apart. The macro
contributes **no** synthesised cells — its area comes from the LEF, and it is
79,674 µm² per [[reference/sram-budget]].

**The allocation is 6×4 = 24 tiles**, not 8×4. The blog says so three times, and
`info.yaml` now matches. 8×4 is described only as "the possibility of scaling up
… (~30% more area)", to be announced by a page update and an email to sign-ups.
**Design to 24 tiles; treat 32 as headroom that may never arrive.** Verbatim source:
[[raw/articles/janestreet-competition-blog-fulltext]].

| Scenario | Die µm² | of 6×4 (real) | of 8×4 (upside) |
|---|---|---|---|
| Before the swap (flop IMEM, 128 words) | 385,265 | **89%** | 67% |
| **Now: SoC + SERDES + codecs + instruction macro + DRU + CRC** | **154,786** | **36%** | 27% |
| Still to come: pin matrix + 2 KB frame macro | +79,674 | → 54% | → 41% |

The "still to come" row is the two known remaining consumers: the frame buffer is
79,674 µm² of macro, and the pin matrix is estimated in the low hundreds of cells.
**The design is no longer area-constrained**, which is the whole point of the swap:
the remaining risk in this project is now verification, not floorplanning.

Gate count is not the constraint: 1,083 cells for the whole SoC against ~24,000 for
24 tiles at the blog's ~1K cells/tile — about 4.5% of the logic budget, with the
SERDES's 539 and the codecs' 115 on top.

**Shape matters more than tile count**, because a macro has to physically fit the
rectangle. TT notation is WIDTH × HEIGHT:

| Allocation | Die (template tile) | Aspect | Note |
|---|---|---|---|
| **6×4 (real)** | 1002 × 432 µm, 0.433 mm² | 2.32:1 | keeps every macro 8×4 keeps |
| 8×4 (upside) | 1336 × 432 µm, 0.577 mm² | 3.09:1 | +33% area, same height |
| 4×6 (not the offer) | 668 × 648 µm, 0.433 mm² | 1.03:1 | would lose all 64-bit-wide macros |

The 6×4 and 8×4 dice are the same height, so **nothing in the macro analysis
changes if 8×4 arrives** — it is pure extra width. Re-answer the whole SRAM page for
the upside case with `tools/gen_sram_budget.py --tiles 8x4`.


## Design decisions in force

| Decision | Where |
|---|---|
| **12×** oversampling per bit (6 samples per 50 ns half-UI) = 8.33 ns RX grid at the 60 MHz core | `decisions/adr-001-8x-oversampling.md`, `decisions/adr-005-60mhz-turbo.md` |
| Std-cell **latch-pair dual-edge flop** for DDR capture; no custom DET | `decisions/adr-002-latch-pair-det-flop.md` |
| **60 MHz operating point — LOCKED, not a parameter** = exact integers for every hard protocol (50 ns = 3 ticks) | `decisions/adr-005-60mhz-turbo.md`, `reference/clock-arithmetic.md` |
| **Signed off at 60 MHz** (`CLOCK_PERIOD` 16.667 ns) in both flow configs; the 66 MHz STA target is retired | `flow/pe_uart_soc.json`, `flow/pe_serdes.json` |
| SERDES words ≤ 32 b; longer fields chunk (SWD parity, CAN/USB/ETH payloads) | `rtl/pe_serdes.v` header |
| Codec pipeline order fixed (stuff → line-code); cfg selects the **subset** | `rtl/pe_codec_mux.v` header |
| No elasticity FIFO needed (source-sync protocols + per-edge re-lock) | `concepts/cdr-oversampling.md` |
| Two SRAM macros: 1024-word instructions + 2 KB frame buffer, both `1P_1024x16` | `decisions/adr-003-memory-plan.md` |
| **Instruction macro is live; PC width derives from IMEM depth (10 bits at 1024)** | `decisions/adr-004-program-counter-width.md` |
| 10BASE-T is the LINE LAYER only; the stack is off-chip, and firmware never touches Ethernet bits | `concepts/ethernet-scope.md` |
| Every codec stage takes `clr` and reports `rx_err` REGISTERED, one cycle after the strobe | `rtl/pe_line_codec.v` header |
| `ena` must never gate logic; every pad output driven in every state | `rtl/tt_um_protocol_emulator.v` header |

## Timing margin at the 60 MHz operating point (measured, post-route)

From `RUN_2026-09-22_02-58-32`, `55-openroad-stapostpnr` — **the first run signed
off at `CLOCK_PERIOD` 16.667 ns = 60 MHz directly**, so the reported slack IS the
operating-point margin with no conversion:

| | setup (worst = slow corner) | hold (worst = fast corner) |
|---|---|---|
| worst slack **@60 MHz — signed off here** | **+2.6601 ns** | **+0.1209 ns** |
| as a fraction of the 60 MHz period | **16.0%** | — |
| violating paths, all 3 corners | **0** | **0** |
| max cap / max slew violations | **8 / 10 — STILL PRESENT** | |

The 60 MHz figure **+2.6601 ns reproduces the +2.660 ns predicted from the 66 MHz
run's path by hand** (arrival 13.4479 ns, capture clock 0.6419 ns, uncertainty
1.0 ns, library setup 0.2008 ns), which is an independent check on the arithmetic
in that table.

**The relaxed period did NOT clear the slew/cap violations, and it could not
have.** They are unchanged at 8 max-cap / 10 max-slew, identical to the 66 MHz
run. A longer period relaxes *timing* (`setup`/`hold`); it does nothing to a
slew or capacitance limit, which is a driver-strength and fanout property of the
SRAM's pins as our routing drives them. See gotchas 37-38 — the lever is
`DESIGN_REPAIR_MAX_SLEW_PCT` / `MAX_CAP_PCT`, and the IHP reference design hits
the same checkers with no SRAM at all.

**Fmax from the post-route critical path: 71.4 MHz** (slow corner, 1.08 V/125 C,
min period 14.007 ns). That is real headroom over 60 MHz — 19% — and it is the
number that answers "what are we leaving on the table".

**What the critical path IS, and it is not the CPU:** it starts at the SRAM
(`u_imem.g_macro.u_sram/A_DOUT[12]`), takes **7.635 ns** of the 13.448 ns
arrival, then runs through a chain of **hold-fix buffers** — `fanout118`,
`fanout115`, `fanout113`, all `sg13g2_buf_1` — costing a further **1.55 ns**,
before ending in `hold626` (`sg13g2_dlygate4sd3_1`) which alone injects
**0.623 ns** of the path as pure delay. **The hold repair is ~2.2 ns of a
14.0 ns period, i.e. it is costing ~11% of Fmax**; without it the path would
close at ~84 MHz. This is the single cheapest lever on the clock, and it is why
the hold uncertainty value (0.25 ns, the SDC split) is load-bearing.

**The margin is not the same thing as confidence in the number.** The SRAM's
7.635 ns is a `.lib` table lookup taken **outside** the characterised axes (see
gotchas 37-38): input slew presents 1.291 against a table max of 0.5952. The
SRAM read is therefore the one number in this table that OpenROAD extrapolated
rather than interpolated, and it is 57% of the arrival time.

**Also gated, and not clean:** `Checker.MaxSlewViolations` (10) and
`Checker.MaxCapViolations` (8) fire in all three corners, all on SRAM macro
pins as driven by our routing. Setup/hold are clean; these two are not.

## Toolchain — exact commands

```bash
# EVERYTHING: firmware regression (assemble + emulator) then all 22 RTL TBs.
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

17. **A 3-tap majority is not a delay, and the difference is a whole sample.**
    Its output moves one sample later than the centre tap at a level change (it takes
    two agreeing taps to flip). Feeding it straight into `pe_dru`'s edge detector
    shifted EVERY edge by a sample, which moved the phase-6 capture off the half-cell
    centre and captured the wrong LEVEL — for one bit pattern out of four. Fixed by
    resampling the majority before it drives the counter. A test that only asks "does
    the filter remove the glitch" passes in both versions; the defect only shows up as
    wrong data on a pattern the glitch test does not use.
18. **A complement belongs on the wire, not in the feedback.** `pe_crc`'s
    `cfg_out_inv` complements `crc_bit` only. Putting it inside the feedback makes
    `fb == 1` on every field strobe, so the register XORs its mask 32 times while it
    should be draining — and the emitted bits are IDENTICAL either way, so every
    transmit-side check passes. Only the receiver's drain-to-zero distinguishes them.
    When a block feeds its own output back, the output path and the feedback path are
    not interchangeable and must be written as separate expressions.
19. **Error detection is not "the CRC changed".** A payload corrupted BEFORE its CRC
    is computed is a consistent frame and verifies correctly; so is a corrupted frame
    whose CRC field happens to be the corrupted one's. The right test corrupts the
    RECEIVED stream. Asserting the naive version produced 150+ failures that were all
    arithmetic, not defects — the giveaway was that they appeared only in the soak,
    where random payloads made the coincidence common.
20. **An acquisition ambiguity is not a bug when the protocol has a preamble.**
    `pe_dru` cannot label the first captured cell's halves without a transition to
    seed the parity, so the first cell after acquisition may be mislabelled. Every
    Manchester receiver has this property and that is exactly what the 56-bit
    Ethernet preamble is for. The TB drives a lead-in and counts from the payload,
    rather than asserting something no receiver promises.

21. **A hard macro's protocol has traps that a functional test cannot see, and
    its datasheet does not mention them.** `A_BM=0` with `A_WEN=1` is a **silent
    write no-op**: the loader reports success, memory stays blank, and the SoC
    executes NOPs. `A_REN=1` during a write is **write-through** — the read port
    returns the value on `DIN`, not the stored word. Neither is in the datasheet;
    both are visible in the vendor's *behavioural model*, which is the file to read
    before writing a driver. A testbench that only checks "memory remembers a word"
    passes with either bug present, so `tb_pe_imem` asserts the specific protocol
    facts and is mutation-checked against both.
22. **A longer load window is not free, and a test can be passing by accident.**
    Deepening instruction memory from 128 to 1024 words made the loader take 1024
    cycles instead of 128. The timer free-runs from reset, so it now advances ~6
    ticks before the core starts — and `tb_pe_tick_status` began failing, because
    its "observed ticks == free-running timer" comparison had been true only
    because the old load window (128 cycles) was *shorter than one 173-cycle tick*.
    The test was right by luck, not by construction. When a change alters how long
    something takes, re-read every test whose assumption is about *when*, not *what*.
23. **"Widening the memory" and "widening the address" are separate jobs, and
    doing one without the other buys nothing.** The 1024-word macro was useless
    until the PC and the jump-target field widened: with a fixed 8-bit PC the
    reachable program stayed 256 words and `next_pc[IAW-1:0]` was an out-of-range
    part-select. The plan had explicitly claimed the swap would need no CPU change,
    which was true of the cycle model and false of the address width — a claim can
    be right about one axis and wrong about another, and only re-reading the RTL
    against the new size finds it.
24. **A parameterised block is only tested at the values something actually
    instantiates, and a guard with the wrong bound reads as protection while
    providing none.** `pe_dru`'s guard checked `SPB % 4 != 0`, which was true and
    necessary and incomplete: `phase` is 4 bits and the wrap constant is
    `4'(SPB - 1)`, which **truncates above 16**. At SPB=20 the counter wraps at
    phase 3 instead of 19, never reaches either capture phase, and the block
    **emits nothing at all** — no error, no output, no failing signal. Every
    testbench pinned SPB at its default, so a sweep of the parameter boundary
    (8/12/16 pass, 20/24/32 fail) was the only thing that found it. The bound is
    now an elaboration error and `tb/param_guards.sh` (in `run_all.sh`) requires
    both guards to actually *reject* and both boundaries to actually *compile*,
    so a guard that stops firing fails the build.
25. **A gate invoked mid-script must resolve its paths from a captured absolute
    root.** `run_all.sh` cds into `sim/` and then back to the repo root, and `$0`
    may itself be relative (`./tb/run_all.sh`) — so `$(dirname "$0")` after the
    cd resolved to `.` and `/param_guards.sh`, and the new gate failed while
    passing perfectly when run by hand. The script now captures `REPO_ROOT` once
    at the top and every later gate uses it. **A tool that works standalone and
    fails inside the runner is a path bug, not a logic bug.**
26. **"Within spec" is a conformance test, not a budget to nibble.** The 66 MHz
    turbo was justified for months as costing "±3.8 ns = 7.6% of half-UI — eats
    the 10BASE-T TX jitter budget". Solving the actual requirement (crossings at
    8.0/8.5 BT ±11 ns, on a sliding window) proved no edge placement works at
    66 MHz at all, while **60 MHz is exact with no dither and better on every
    axis**. When a timing claim rests on a tolerance, quote the spec's numbers and
    solve for feasibility before pricing the tradeoff. See [[decisions/adr-005-60mhz-turbo]].
27. **Raising the clock re-prices the HARD MACROS first, not the logic.** The
    logic had slack to spare (2.5 ns worst reg-to-reg against a 7.58 ns
    half-cycle), but the SRAM is a fixed circuit: `A_CLK` -> `A_DOUT` is **7.25 ns
    at the slow corner**, which was 29% of a 25 ns period at 40 MHz and is **43%
    of a 16.667 ns period at 60 MHz**. `pe_imem` deliberately has no output
    register (it would add a second cycle and break the CPU's fetch-ahead), so
    that path is what the SoC STA run must close. The pe_serdes signoff does not
    cover it — that design has no SRAM. Hard macros do not scale with your clock.
28. **A TB that hardcodes the clock period as an INTEGER silently simulates at
    the wrong frequency.** `localparam int CLK_NS = 17` for a 60 MHz target is
    wrong twice over: 60 MHz is 16.667 ns, and `#(CLK_NS/2)` with an integer 17
    rounds the half-period to 8 ns, i.e. **62.5 MHz**. Always derive the period
    as `real` from `CLK_HZ` (`1e9 / CLK_HZ`), and derive the tick count from the
    same expression the RTL uses, so a clock change cannot leave the TB
    simulating one rate while the SoC thinks it is at another.
29. **Never trust a failing test until you have read the failure's own output.**
    A 60 MHz run of `tb_pe_uart_soc` "failed" during this change, and the cause
    was the harness: `vvp` was invoked from `/tmp`, so the TB's relative
    `$readmemh ../firmware/uart_echo.hex` resolved to nothing, the core executed
    uninitialised memory, and it hung like a firmware bug. The `$readmemh`
    warning was in the very output being read. Before diagnosing a design, check
    the run for warnings about the *inputs* it was supposed to load.
30. **A bit-palindromic test vector cannot catch a bit-order bug.** SPI is
    MSB-first and the UART is LSB-first, so "does this firmware shift the right
    way" is the central question for SPI — and the first version of
    `firmware/spi_xfer.pe` sent `0x5A`, which reversed is still `0x5A`. A master
    that shifted LSB-first would have put the **identical levels on the wire**.
    `0x00`, `0xFF`, `0x0F`, `0x3C`, `0x81` and `0xAA` are the same trap. Check
    the vector: `int('{:08b}'.format(b)[::-1], 2) != b`. This is gotcha 14
    wearing different clothes — a test that cannot fail is not a test.
31. **A mutation that cannot change observable behaviour cannot be caught, and
    demanding that it be caught is demanding a lie.** Three SPI mutations were
    built: flipping the MOSI bit order *was* caught (slave saw `80 80 80 80`),
    and driving MOSI after the clock rise *was* caught (slave saw `2D AD AD AD`,
    the previous bit — the classic CPHA error). Sampling MISO *before* the
    rising edge was **not** caught, and that is correct: a CPHA=0 slave presents
    MISO on the falling edge and holds it through the rise, so the sample point
    can be anywhere in the low phase. Before treating an uncaught mutation as a
    coverage hole, check whether the mutation is observable at all. Record the
    ones that are not, so the next person does not re-derive it.
32. **A free-running tick counter cannot measure a fixed delay, and the error is
    one whole tick — not a rounding error.** The tick wait in both firmwares
    snapshots the count and loops until it changes, so it returns after anywhere
    in (0, 1] ticks. For the **UART** that misalignment is the dominant error
    term (it is why a sample can land on a bit boundary; see
    [[concepts/cdr-oversampling]] and `firmware/uart_echo.pe`'s timing note). For
    **SPI** the same jitter is completely harmless, because the slave times
    itself off the SCLK edges we generate — a synchronous link has no baud rate
    to hit. Same code, same jitter, opposite consequences: the protocol decides
    whether clock jitter is a defect.
33. **A hardware macro's power pins are on the macro's own layers, and the PDN's
    straps may be on different ones — `PDN_MACRO_CONNECTIONS` does NOT fix that.**
    The IHP SRAM's `VDD!`/`VSS!`/`VDDARRAY!` straps are **Metal4** and run the
    full height of the macro; `pdngen`'s generated grid is **TopMetal1/TopMetal2**
    with Metal1 rails. `PDN_MACRO_CONNECTIONS` (format `<inst> <vdd_net>
    <gnd_net> <vdd_pin> <gnd_pin>`, one entry **per power pin** — this macro has
    two power pins, so two entries) connects the pins **logically**, and it does
    work: the log prints `<inst> matched with u_imem.g_macro.u_sram`. But a
    logical connection is not a physical path, so `check_power_grid` still
    reported ~50 unconnected Metal4 shapes and `PSM-0069`, and the router —
    free to use Metal4 for signal — **shorted into them**. The fix is a custom
    `PDN_CFG` that stripes the macro on its own supply layer and steps up:
    `add_pdn_stripe -grid macro -layer Metal4` + `add_pdn_connect -layers "Metal4
    $PDN_VERTICAL_LAYER"`. Result, same input ODB: stock config = `PSM-0069
    FAILED`; custom = **`PSM-0040 All shapes on net VPWR/VGND are connected`**.
    See `flow/pe_uart_soc_pdn.tcl`. **Check the macro's LEF layers before
    believing the grid is wrong — and before believing `PDN_MACRO_CONNECTIONS`
    is enough.**
34. **Global-routing congestion at low utilization is a CONFIG derate, not a
    capacity problem.** The full SoC failed `GRT-0116` with 34 overflowed GCells
    at **4.59% total usage** on the real 6x4 die. The cause was `GRT_ADJUSTMENT`:
    LibreLane's generic default is **0.3** (the log prints `[INFO GRT-0022]
    Global adjustment: 30%`) while the IHP PDK ships `GRT_LAYER_ADJUSTMENTS = 0.00`
    for all 7 routing layers — so the PDK's own stated intent is no derate and
    the 30% was an inherited default fighting it. Setting `GRT_ADJUSTMENT = 0.0`
    took the same design to **0 overflow on every layer at 2.88-3.03% usage**.
    When a router fails at single-digit utilization, read the adjustment numbers
    it prints before doubting the floorplan.
35. **A vendor macro's GDSII may not speak the flow's boundary vocabulary.**
    LibreLane's Magic streamout extracts the macro's placement bbox by reading
    the `FIXED_BBOX` property that Magic derives from a **`pblock`** layer, and
    the IHP SRAM GDS ships none: it has `189/4` (the IHP map's `DIEAREA`)
    instead. The flow therefore aborts at the GDS-streamout step with "Failed to
    extract PR boundary from GDSII view of macro ... Ensure that the GDSII view
    has a PR boundary layer" — after routing, RCX, STA and IR drop have all
    already passed. The size the flow wants is not actually missing: the macro's
    **LEF declares `SIZE 236.8 BY 336.46`**. Check the LEF before believing the
    macro is malformed, and do not edit a vendor GDS to satisfy a flow script's
    layer name.
36. **A negative result is only as good as the SCOPE of the search that produced
    it.** I claimed a config comment quoted an OpenROAD warning (`GRT-0704`) that
    "does not exist in any run log", and replaced it. `GRT-0704` is real: it is in
    `RUN_2026-09-22_00-07-27/warning.log`,
    `[GRT-0704] Try reduce the layer adjustment from 30.000002% to 0%` — the tool
    literally recommending the change that fixed the congestion. The check that
    "proved" it absent was `grep -rl` run from the **repo root**, while the run
    logs live under **`~/asic-runs`**. A negative grep bounded by the wrong
    directory returns nothing, and I read "my search found nothing" as "it does
    not exist". Two consequences: (a) before recording that a quote is fabricated,
    make the search cover where the evidence WOULD be, and say in the writeup
    where you looked; (b) a false fabrication-claim is worse than the original
    quote, because it removes real evidence AND installs a wrong lesson.
37. **"Setup and hold close" is NOT "no violations" — max-cap / max-slew /
    max-fanout are SEPARATE checks, and they do fail here.** `RUN_2026-09-22_00-48-35`
    closes timing (setup WNS +1.143 ns, hold WNS +0.121 ns, 0 setup/hold violating
    paths at all three corners, TNS 0.0) and simultaneously reports **10 max-slew,
    8 max-cap and 7 max-fanout violations**, present in every run since the macro
    landed. An earlier summary of mine said "0 violations" for this run; that was
    true of setup/hold and false of the STA as a whole. Always state which check
    you mean.
38. **Some of those violations sit at slew/cap values the SRAM's .lib was never
    characterised for, and OpenROAD extrapolates SILENTLY.** This touches the path
    signed off as closed. Measured axes in
    `RM_IHPSG13_1P_1024x16_c2_bm_bist_slow_1p08V_125C.lib`:

    | axis | table max | what the design presents |
    |---|---|---|
    | input slew (`index_1`) | **0.5952** | `A_DIN[5]` **1.291** (2.2x over), `A_ADDR[0]` 0.961, `A_REN` 0.644 |
    | output cap (`index_2`) | **0.0640** | `A_DOUT[4]` **0.1169** (+83%), `A_DOUT[12]` 0.0680 (+6%) |

    Consequences and levers:

    - **The macro's internal delay is not trustworthy as characterised** at those
      points — the 7.635 ns `A_DOUT[12]` figure is a table lookup taken outside
      the table. Extrapolation usually over-estimates delay and the +1.143 ns
      margin absorbs a lot, but "probably pessimistic" is not a signoff claim.
    - **It is fixable in the FLOW, not the silicon.** The over-slewed drivers are
      `sg13g2_buf_1` (the smallest buffer IHP makes), and `A_DOUT[4]` presents
      fanout 20 against a limit of 10. `repair_design` runs with
      `-slew_margin 20.0 -cap_margin 20.0` and its own log shows it resizing
      **nothing** ("+0.0% ... Resized 0 ... Remaining 1332" all the way down) —
      the 20% margins tell the resizer these are fine. Raising
      `DESIGN_REPAIR_MAX_SLEW_PCT` / `DESIGN_REPAIR_MAX_CAP_PCT` and buffering
      `A_DOUT` is the way to bring the macro back inside its characterisation.
    - **`A_CLK` is fine, deliberately**: 0.051 ns slew, 11.7x inside the limit,
      because it comes off the delay-buffer chain. The critical path's *clock*
      side is well behaved; the *data* and *output* pins are what is over.
    - **`A_DOUT[4]` is the worst for a reason**: `pe_imem` wires `A_DOUT` straight
      to `imem_rdata`, which the CPU reads as the instruction word, so that net
      fans out to every instruction consumer. See [[reference/sram-budget]].

    Slack on the affected paths is comfortable (`A_DIN[5]` +10.27 ns,
    `A_ADDR[0]` +3.70 ns) so nothing is currently failing timing. The finding is
    that the instruction-fetch STA number rests on extrapolated macro timing, and
    the flow has a lever to remove that caveat.
39. **The flow GATES on max-slew/max-cap, so they are failures, not cosmetics.**
    `RUN_2026-09-22_00-48-35` has steps 72-75 as `Checker.SetupViolations`,
    `Checker.HoldViolations`, `Checker.MaxSlewViolations`,
    `Checker.MaxCapViolations`. The first two report "No setup/hold violations
    found"; the last two report **"Max Slew violations found in the following
    corners: nom_fast / nom_slow / nom_typ"** (same for Max Cap). LibreLane
    collected them as *deferred* errors and quit at the end of the flow. So
    gotcha 37's count is a gated failure with a checker step named after it.
40. **1,113,909 Magic DRC + 2,672 KLayout DRC errors, and 100% of BOTH are inside
    the vendor SRAM macro.** Established by parsing, not assertion: every
    coordinate in `drc.magic.rpt` compared against the macro's placed footprint
    (x 10..246.8, y 10..346.46 µm) gives **1,113,909 inside, 0 outside**, with
    rules that are library-internal artefacts (`Cnt.c` 880,232; `LU.b` 104,724;
    `Gat.c` 104,737; `M2.d` 59,165). KLayout on the PDK's own 174-rule deck fires
    only **4 rules**, dominant pair `Sdiod.d`/`Sdiod.e` — **ContBar inside
    nBuLay, an ESD-diode rule** — in a design that instantiates no diodes. Every
    one of the 2,672 KLayout items names an `RM_IHPSG13_*` or `RSC_IHPSG13_*`
    cell, and `RSC_IHPSG13_*` is in **neither** the design's `sg13g2_stdcell`
    library **nor** the SRAM's LEF, so it exists only inside the SRAM's GDS.
41. **`MAGIC_GDS_FLATGLOB` exists for exactly this and is unset.** LibreLane's
    docstring: "Flatten cells by name pattern on input. **May be used to avoid
    false positive DRC errors.**" With an SRAM-name glob that is the sanctioned
    route, and better than disabling DRC. The other knob is `MAGIC_DRC_USE_GDS`
    (default true; false checks the DEF view, "less accurate as some DEF/LEF
    elements are abstract"). See gotcha 43 before using either.
42. **LVS PASSES on the same layout — "Circuits match uniquely", 1926 devices and
    1939 nets on both sides** (`70-netgen-lvs/reports/lvs.netgen.rpt`; the flow's
    step 71 `Checker.LVS` reports "Check for LVS errors clear"). This is the
    independent evidence that those DRC errors are geometric false positives
    inside the vendor cell rather than a construction defect: netgen compared
    layout against netlist and found them identical device for device, and a
    genuinely mis-built macro would very likely fail LVS too. Note the
    power-grid checker's message is itself conditional — "you may ignore these
    if LVS passes" — and LVS passes.
43. **A DRC failure inside a third-party macro is not automatically real OR
    ignorable — the test that distinguishes them is running the PDK's own deck
    on the macro ALONE.** Fails alone ⇒ the finding is the PDK/vendor's and an
    exclusion list is justified *with evidence*. Passes alone ⇒ the failure is
    introduced by composition and it is ours. **Do not silence DRC merely because
    LVS passed:** LVS checks connectivity and device identity, DRC checks
    geometry, and a cell can be electrically perfect while violating a spacing
    rule.
44. **THE VERDICT ON THE MACRO DRC, and it is not ours.** Ran the PDK's own
    `run_drc.py` on the SRAM macro **ALONE**, `--run_mode deep` (the same mode
    LibreLane uses), and diffed rule-by-rule against the full SoC:

    | rule | macro alone | full SoC | verdict |
    |---|---|---|---|
    | `Sdiod.d` | 1136 | 1136 | **identical** |
    | `Sdiod.e` | 1136 | 1136 | **identical** |
    | `Cnt.c.digibnd` | 400 | 400 | **identical** |
    | `M5.j` / `M5Fil.h` / `TM1.c` / `TM2.c` | 1 each | **0** | our fill/PDN fixed them |
    | **total** | **2676** | **2672** | |

    **2,672 of 2,672 SoC violations are reproduced EXACTLY by the vendor macro
    standalone; ZERO are introduced by assembling the SoC.** The vendor's own
    flow even prints `❌ KLayout DRC Check Failed` on the macro by itself. So the
    finding is the PDK's, and an exclusion is justified **with evidence** rather
    than assumed. Note the SoC is *cleaner* than the macro alone — the four
    1-count BEOL rules the macro fails are fixed by our PDN + fill.
45. **This is a known class, corroborated two ways.** (a) IHP's own
    `ihp-sg13g2-librelane-template` issue #19 reports the vendor's reference
    design — **which contains no SRAM at all** — completing `make librelane`
    with `1697 Magic DRC errors`, `40 KLayout DRC errors`, `[RSZ-0020] found 4
    floating nets`, and **`Checker.MaxSlewViolations` / `Checker.MaxCapViolations`
    firing in the same corners we see**. Those are deferred errors the flow
    collects and reports at the end, exactly as ours are. (b) Tiny Tapeout's
    memory page documents the IHP SRAM macros as supported for IHP shuttles and
    points at a taped-out, tested 1024x8 SRAM project — i.e. the community route
    to using these macros exists and is sanctioned.
46. **What this does NOT license.** The macro DRC being the PDK's does not make
    the *max-slew / max-cap* violations go away — those are on SRAM **pins** as
    driven by *our* routing (`sg13g2_buf_1` drivers, `A_DOUT[4]` at fanout 20),
    and they are gated by steps 74-75. Gotchas 37-39 stand unchanged. Fixing the
    slew/cap means `DESIGN_REPAIR_MAX_SLEW_PCT` / `DESIGN_REPAIR_MAX_CAP_PCT`
    plus buffering `A_DOUT`, which is our work, not the PDK's.

## Open questions / risks

- **IHP-specific max pad clock is unpublished.** The ~66 MHz figure is sky130
  pad-macro-derived. Signing off at 66 gives margin if the real limit is lower.
- **No SRAM compiler for sg13g2** — only fixed macros (30 shapes). Sizing is in
  [[reference/sram-budget]]; the choice is made in [[decisions/adr-003-memory-plan]].
  Note the granularity trap: **1.5 KB cannot be bought.** The two 1 KB parts miss a
  1,518-byte Ethernet frame by 494 bytes, so the practical floor for a frame buffer
  is 2 KB.
- **Tile size discrepancy**: blog says ~200×150 µm/tile, the TT template's
  `info.yaml` says ~167×108 µm. Use the template for layout math; re-check after
  the first real floorplan of the full design.
- **The blog is a LIVING DOCUMENT and must be re-checked.** It states it will be
  updated if 8×4 becomes available, and that sign-ups will be emailed. The repo's
  first capture of it was a summary that got the tile count wrong and stood for
  three days. Re-fetch and diff
  [[raw/articles/janestreet-competition-blog-fulltext]] periodically; its
  frontmatter carries the sha256 of the HTML as fetched on 2026-09-20.
- **No host data path exists.** The SoC's `host_*` port is firmware loading only and
  `rtl/tt_um_protocol_emulator.v` ties it off. If Ethernet or a logic-analyser mode
  wants to stream to a host, that is unbuilt and unplanned, and it needs a decision
  record BEFORE the pin matrix fixes pin assignments ([[concepts/ethernet-scope]]).
- **The `~66 MHz` ceiling and `--docker-no-tty` wrapper bug** are both worth
  confirming with TT/Jane Street (Discord / asic-competition@janestreet.com).

## Next steps (ordered)

**The work list is [[plans/through-i2c]]** — it has the definition of done, the
three blockers with numbers, and an 8-step ordered plan to a real I2C transaction.
Its Blocker 1 (the red UART RTL test) is **fixed as of 2026-09-20**; steps 2 and 3
of that plan are the housekeeping this file just went through.

### The recommended order, and why it is not DRU and LFSR next

The blog's baseline is **"Start with UART, SPI, and I2C"**; USB and 10Mbit Ethernet
are stretch goals. **UART and SPI both exist as firmware today** (steps 1-2 below
are done); I2C is proven at the SERDES level by its testbench but has not been
demonstrated as a *program*, which is the thing the whole submission claims.
**Finish the baseline before the stretch**, and inside the baseline take the cheap
one first.

1. ~~**SRAM swap for instruction memory**~~ **DONE 2026-09-20**
   ([[decisions/adr-003-memory-plan]]). Took the design from 89% of a 4x6 die to
   54%, and from 128 program words to 1,024 via the real `1P_1024x16` macro.
2. ~~**SPI as firmware.**~~ **DONE 2026-09-22** — `firmware/spi_xfer.pe`, a mode-0
   master, verified in `tools/peemu.py` against a modelled slave, with three
   mutations built to prove the test can fail ([[concepts/spi-as-firmware]]).
   It needed no pin matrix, as predicted: the SoC's single in/out pin became an
   8-bit port with a build-time direction mask, and **UART and SPI share that one
   port and mask**. Completes baseline protocol #2.
   *Still open from this step:* `tb_pe_spi_soc.v` does not exist, so SPI firmware
   has no RTL testbench — the emulator is currently its only executable
   specification. UART has the equivalent in `tb_pe_uart_soc.v`.
3. **Pin matrix / OE**, then **I2C** ([[plans/through-i2c]]). The real new hardware:
   open-drain, read-back for arbitration, clock stretching. It replaces the fixed
   mapping in `rtl/tt_um_protocol_emulator.v` and gates every stretch protocol too.
4. **CRC LFSR** (~120 cells). Do this before the DRU. It is small, well understood,
   serves *three* protocols (CRC-15 CAN, CRC-5/16 USB, CRC-32 Ethernet), and
   `tb_pe_can.v`, `tb_pe_usb.v` and `tb_pe_eth.v` already compute these CRCs in
   their models — so a golden reference exists to check the hardware against on day
   one. Lowest risk, immediate payoff.
5. **DRU** (oversampled phase-picker): edge detect, 3-bit phase counter with
   re-lock on every edge, mid-bit strobe, preamble lock, majority-vote filter.
   Spec in [[concepts/cdr-oversampling]]; ~60–100 cells. Needed for 10BASE-T and
   PS/2 receive, not for I2C. **Last of these, because it is the hardest and it
   only serves stretch goals** — phase recovery is where designs of this kind
   actually fail.
6. **Frame buffer + Ethernet framing**, per [[concepts/ethernet-scope]]. The
   acceptance test is an ARP request/reply, 42 bytes each way, no IP stack.
7. **Word FIFO** (16–32 deep) if gapless multi-word streaming is wanted. Size it
   *after* the SRAM swap: 16 words of 32 bits is another 512 flops.
8. **Full-chip floorplan** against the real tile allocation; then the flow end to
   end on the whole design rather than one block.

**The one reason to reorder:** if de-risking matters more than sequencing, pull the
DRU forward to position 2. It is the highest-uncertainty block in the project and
there are ~16 months to the 2027-01-18 deadline. That is a defensible choice; it is
not the default one, because a complete and verified baseline beats a partial
stretch in a competition that says "verification matters" out loud.

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
10. [[decisions/adr-003-memory-plan]] — the two SRAM macros and the measured
    per-word cost of flop memory. Read before touching the SoC's memories.
11. [[concepts/ethernet-scope]] — what the 10BASE-T stretch goal is and is not,
    and the throughput arithmetic that puts Ethernet bits in hardware.
