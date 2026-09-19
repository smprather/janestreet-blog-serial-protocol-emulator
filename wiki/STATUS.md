# Project Status — Milestone 1

> **Resume here after a context flush.** Read this first, then `wiki/index.md`.
> Last updated: 2026-09-18 · commit `1c6df0c` · branch `main` (pushed)

## Where we are

The **shared hardware layer** of the protocol emulator is built, simulated, and
sized. Three RTL blocks exist, all self-checking-TB verified, all synthesized on
the real IHP sg13g2 standard cells, and one of them (the SERDES) has been through
the complete LibreLane place-and-route flow to a clean signoff.

Nothing has been taped out. The programmable core (state machine / microsequencer)
does **not** exist yet — that is the next major work item.

```
                    +---------------------+
   firmware  --->   |  SM / sequencer     |   NOT BUILT (next milestone)
                    +---------------------+
                              |
                    +---------------------+     +------------------+
                    |   pe_serdes         | <-> |  TX/RX word FIFO |  (not built)
                    |  583 cells routed   |     +------------------+
                    +---------------------+
                              |
                    +---------------------+
                    |  pe_codec_mux       |   BUILT (cfg-selectable stages)
                    |  stuff / nrzi / man |   (manch half_phase from timing)
                    +---------------------+
                              |
                    +---------------------+
                    |  DRU (oversampled   |   NOT BUILT (spec'd in wiki)
                    |  phase picker)      |
                    +---------------------+
                              |
                          pin matrix / OE / tri-state   (not built)
                              |
                        TT GPIO pins
```

## What is built and verified

| Block | File | Cells | Area (µm²) | TBs |
|---|---|---|---|---|
| SERDES (bit engine, 1–32 b, runtime order) | `rtl/pe_serdes.v` | 539 | 11,223 synth → **17,211 routed** | `tb_pe_serdes.v` + 9 protocol TBs |
| NRZI codec | `rtl/pe_line_codec.v` | 12 | 189 | `tb_pe_nrzi` |
| Manchester codec | `rtl/pe_line_codec.v` | 5 | 62 | `tb_pe_manch` |
| Bit stuffer/unstuffer | `rtl/pe_line_codec.v` | 84 | 1,290 | `tb_pe_bitstuff` |
| Codec pipeline mux | `rtl/pe_codec_mux.v` | 110 total (9 glue) | 69 glue (+ sub-blocks above) | `tb_pe_codec_mux` |

Numbers from `tb/synth_area.sh` (sg13g2 typ corner, mapped pre-route). The routed
figure for the SERDES comes from the full LibreLane flow (route+CTS+PDN inflate
area ~1.54× over mapped).

**Regression: 14/14 testbenches pass** (`tb/run_all.sh`). Verilator lint clean on
all RTL.

Protocol testbenches (one per target, each wrapping the same SERDES with that
protocol's real framing): UART 8N1 · SPI mode 0 full duplex · I2C 7-bit
addr/RW/repeated-start · JTAG TAP walk + BSR · SWD req/ACK/data/parity ·
PS/2 11-bit odd-parity · CAN classic + stuffing + CRC-15 · USB-LS NRZI+stuffing ·
10BASE-T Manchester + CRC-32.

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

## Toolchain — exact commands

```bash
# regression (all 14 TBs; ~1 min)
cd ~/janestreet-blog-serial-protocol-emulator && ./tb/run_all.sh

# mapped area per block (native yosys + IHP liberty)
./tb/synth_area.sh

# full place & route (dockerized LibreLane) — NOTE the explicit -p / -s flags,
# the wrapper's PDK auto-enable fails for ihp-sg13g2 (see gotchas)
cd ~/asic-runs/pe-serdes && docker run --rm -i --user 1000:1000 \
  -v /home/mylesp:/home/mylesp -v /home/mylesp/.ciel:/home/mylesp/.ciel \
  -e PDK_ROOT=/home/mylesp/.ciel -w /home/mylesp/asic-runs/pe-serdes \
  ghcr.io/librelane/librelane:3.0.14 \
  python3 -m librelane -p ihp-sg13g2 -s sg13g2_stdcell config.json
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

## Open questions / risks

- **IHP-specific max pad clock is unpublished.** The ~66 MHz figure is sky130
  pad-macro-derived. Signing off at 66 gives margin if the real limit is lower.
- **No SRAM compiler for sg13g2** — only fixed 1P macros (256×16 … 2048×64).
  Instruction memory sizing must use those macros (or flops).
- **Tile size discrepancy**: blog says ~200×150 µm/tile, the TT template's
  `info.yaml` says ~167×108 µm. Use the template for layout math; re-check after
  the first real floorplan of the full design.
- **The `~66 MHz` ceiling and `--docker-no-tty` wrapper bug** are both worth
  confirming with TT/Jane Street (Discord / asic-competition@janestreet.com).

## Next steps (ordered)

1. **DRU** (oversampled phase-picker): edge detect, 3-bit phase counter with
   re-lock on every edge, mid-bit strobe, preamble lock, majority-vote filter.
   Spec is in `concepts/cdr-oversampling.md`; ~60–100 cells.
2. **SM / microsequencer**: PIO-derived ISA (out/in/set/mov/jmp/wait/pull/push +
   word ops that drive the SERDES), 2 instances, tiny config/CSR block. Decision
   recorded as a recommendation; no ADR file yet.
3. **Pin matrix / OE / tri-state** (open-drain emulation for I2C, SE0 for USB).
4. **Word FIFO** (16–32 deep) if gapless multi-word streaming is wanted.
5. **Assembler + simulator** for the SM ISA (firmware toolchain).
6. **Full-chip floorplan** against the 32-tile budget; then the flow end to end.

## Reading order for a fresh session

1. This file.
2. `wiki/index.md` → then `concepts/competition-overview.md` (rules, budget).
3. `concepts/factored-hardware-blocks.md` (what exists / what's planned) and
   `concepts/tx-timing-generation.md` (timing + signoff policy).
4. `concepts/cdr-oversampling.md` (the DRU spec) — next block to build.
5. `wiki/log.md` (last ~15 entries) for recent activity.
6. `rtl/pe_serdes.v` header comment for the SERDES contract.
