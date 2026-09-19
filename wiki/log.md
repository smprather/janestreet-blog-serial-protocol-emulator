# Wiki Log

> Chronological record of all wiki actions. Append-only.
> Format: `## [YYYY-MM-DD] action | subject`

## [2026-09-17] create | Wiki initialized
- Domain: protocol-emulator ASIC competition entry (Tiny Tapeout, IHP 130nm CMOS5L)
- Structure: SCHEMA.md, index.md, log.md, raw/, entities/, concepts/, comparisons/, decisions/, queries/
- Raw transcript ingested earlier: raw/transcripts/gemini-asic-competition-discussion-2026-09.md

## [2026-09-17] ingest | Jane Street competition blog post + transcript synthesis
- Created: raw/articles/janestreet-protocol-emulator-competition.md
- Created: entities/tiny-tapeout.md, 6 concept pages, comparisons/clocking-options.md, decisions/adr-001-8x-oversampling.md
- Key correction: blog specifies 8x4 tiles (not transcript's "6x4 scaling to 8x4"); ~200x150 um/tile, ~1 mm2 nominal, ~1K cells/tile
## [2026-09-17] ingest | Tiny Tapeout platform docs
- Created: raw/articles/tinytapeout-clock-spec.md, raw/articles/ttihp0p2-loopback-skew-project.md, raw/articles/tinytapeout-multiplexer.md
- Updated: entities/tiny-tapeout.md (clock ceiling, mux behavior, tile-size discrepancy, open questions), concepts/gpio-signoff-corners.md (silicon precedent), comparisons/clocking-options.md (external 80 MHz off the table; dual-edge 40 MHz is default)
- Headline finding: official clock spec caps input at ~66 MHz (sky130 pad-macro figure); transcript's "~50-60 MHz mux limit" was directionally right but for the wrong reason — the limit is the pad macro + demo-board generator, not the mux
## [2026-09-17] setup | PDK + toolchain installed
- Cloned IHP-Open-PDK (1.2 GB depth-1) to ~/pdk; stdcell/sram/io/pr all present with lib+lef+gds
- Verified: 6 liberty corners (no FS/SF), ngspice mos_fs/mos_sf corners present, fixed 1P SRAM macros 256x16-2048x64 (no compiler; OpenRAM lacks sg13g2)
- Created: concepts/pdk-toolchain.md; venv ~/venvs/asic, magic/netgen installs in flight
## [2026-09-17] setup | Toolchain verified end to end
- Dockerized LibreLane 3.0.14 smoke test PASSES on ihp-sg13g2 (volare build ddb601a4); magic/netgen installed from AUR
- Key lessons: pip-only LibreLane unsupported (needs Nix/Docker); --docker-no-tty in headless shells; volare family is ihp_sg13g2 + explicit version
## [2026-09-17] setup | spm example passes full flow on ihp-sg13g2
- ~/asic-runs/spm (kept out of repo): route/magic/klayout DRC 0, XOR 0, LVS 0, setup/hold violations 0 at fast+slow corners; ~9.8k area units; final GDS+netlist emitted
## [2026-09-17] decide | ADR-002 latch-pair dual-edge flop
- Lib has no negedge flops; DDR capture = dlh+dll latch-pair + mux, pure stdcell; custom static/dynamic DET rejected
## [2026-09-17] rtl | pe_serdes implemented, verified, pushed (94bf44e)
- rtl/pe_serdes.v + tb/tb_pe_serdes.v + sim/pe_serdes.vcd; iverilog PASS, verilator clean
- Real bug caught by TB: LSB-first RX stranded payload in top bits; rewrote RX as bit-placer, payload always in [len-1:0]
## [2026-09-17] synth | pe_serdes = 623 cells / ~11.5k um2 (typ corner)
- 129 flops (54.9% of area), rest mux/combo; ~2% of the 32-tile cell budget; estimate in factored-hardware-blocks replaced with silicon number
## [2026-09-18] pnr | pe_serdes routed: 17.2k um2 cells / 29.2k um2 die, 66 MHz closes
- Full LibreLane Classic on ihp-sg13g2: die 161.7x180.4 um, 78% util, route overhead 1.54x over synth (11.2k->17.2k um2); ~1-2 tiles of 32
- Clean: DRC 0, LVS 0, setup WS +7.6 ns slow corner, hold WS +0.116 ns fast corner
- Toolchain lesson: `librelane --dockerized` wrapper's PDK auto-enable fails for ihp-sg13g2 ("PDK not found" even when ~/.ciel symlink resolves); direct container invocation with explicit `-p ihp-sg13g2 -s sg13g2_stdcell` works. Config must not assume SCL default
## [2026-09-18] concept | TX timing without PLL: 40 MHz exact-integer plan
- Binding TX constraint = 50 ns half-UI (10BASE-T). Resolution: 40 MHz clock (66 is pad ceiling, not operating point); 50 ns = 2 ticks exact; DDR is RX-only (12.5 ns grid, 4 samples/half-UI); USB-LS via 53/53/54 NCO (<1% jitter); forced-66 fallback = 6/7 NCO ±3.8 ns + uneven DRU grid, worse
- Created: concepts/tx-timing-generation.md
## [2026-09-18] rtl | Tier-1 codecs + config mux implemented (84c6c9f)
- rtl/pe_line_codec.v: pe_nrzi (12 cells, separate RX level register, XNOR decode), pe_manch (5 cells, explicit half_phase), pe_bitstuff (84 cells, runtime run_cfg 1-15, pending-stuff handshake)
- rtl/pe_codec_mux.v: cfg byte selects any subset of {stuff, nrzi, manch}; 9 cells glue, 110 total / 1.6k um2
- Real bugs caught: NRZI shared TX/RX level register (invalid receiver) + XOR instead of XNOR decode; bit-stuff replaced the run's last data bit instead of appending after it; yosys PROC_DFF rejects clr OR'd into async reset (made it a sync branch)
- 14/14 TBs pass (serdes + 9 protocols + 3 codecs + mux), lint clean
## [2026-09-18] rtl | post-review rev of pe_serdes: PASS, 539 cells / 11.2k um2
- Bugs fixed: cfg_lsb_first now snapshotted at load/start (was live mid-transfer — core rewrite would corrupt in-flight word); restart-on-final-cell race closed
- Efficiency: RX completion delayed one cycle, deleting the 32b variable-shift forward path (~40 cells); mux2 count 47->17 of 82, area 11.5k->11.2k um2 despite +3 flops
- Contract documented: len>MAXLEN not clamped; MAXLEN>=2 elaboration guard; delayed rx_valid is by design (TB updated)
- (Cell count corrected 2026-09-18 from a derived 583 to the measured 539 via tb/synth_area.sh)
## [2026-09-18] rtl | 9 protocol testbenches, all PASS (bed11b1)
- tb/tb_pe_{uart,spi,i2c,jtag,swd,ps2,can,usb,eth}.v wrap pe_serdes with each protocol's real framing: 8N1/Mode0/7-bit-addr/TAP+BSR/req-ACK-parity/odd-parity+inhibit/stuffing+CRC15/NRZI+stuffing+SE0/Manchester+CRC32
- TB bugs found+fixed en route: sticky flags needed for 1-cycle pulses; >32b fields must chunk (SWD parity, CAN/USB/ETH payloads) — real core contract; JTAG needs 5xTMS TAP reset; CAN destuffer skips bit AFTER the 5-run
- Regression: 9/9 PASS, verilator lint clean; VCDs per protocol in sim/
## [2026-09-18] milestone | Milestone 1: shared hardware layer complete
- Created wiki/STATUS.md (resume-here doc) and tb/run_all.sh + tb/synth_area.sh (one-command regression and area report)
- Verified state: 14/14 TBs pass; pe_serdes 539 cells/11.2k um2 mapped, 17.2k um2 routed, 66 MHz signoff clean; codecs 110 cells total
- Corrected: pe_serdes cell count is 539 (measured), not the 583 previously derived in a commit message
- Not built yet: DRU, SM/sequencer, pin matrix/OE, word FIFO, assembler — next milestone per STATUS.md
