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
- rtl/pe_nrzi.v / rtl/pe_manch.v / rtl/pe_bitstuff.v: pe_nrzi (12 cells, separate RX level register, XNOR decode), pe_manch (5 cells, explicit half_phase), pe_bitstuff (84 cells, runtime run_cfg 1-15, pending-stuff handshake)
- rtl/pe_codec_mux.v: cfg byte selects any subset of {stuff, nrzi, manch}; 9 cells glue, 110 total / 1.6k um2
- Real bugs caught: NRZI shared TX/RX level register (invalid receiver) + XOR instead of XNOR decode; bit-stuff replaced the run's last data bit instead of appending after it; yosys PROC_DFF rejects clr OR'd into async reset (made it a sync branch)
- 14/14 TBs pass (serdes + 9 protocols + 3 codecs + mux), lint clean
## [2026-09-18] rtl | post-review rev of pe_serdes: PASS, 539 cells / 11.2k um2
- Bugs fixed: cfg_lsb_first now snapshotted at load/start (was live mid-transfer — core rewrite would corrupt in-flight word); restart-on-final-cell race closed
- Efficiency: RX completion delayed one cycle, deleting the 32b variable-shift forward path (~40 cells); mux2 count 47->17 of 82, area 11.5k->11.2k um2 despite +3 flops
- Contract documented: len>MAXLEN not clamped; MAXLEN>=2 elaboration guard; delayed rx_valid is by design (TB updated)
- (Cell count corrected 2026-09-18 from a derived 583 to the measured 539 via regress/synth_area.sh)
## [2026-09-18] rtl | 9 protocol testbenches, all PASS (bed11b1)
- tb/tb_pe_{uart,spi,i2c,jtag,swd,ps2,can,usb,eth}.v wrap pe_serdes with each protocol's real framing: 8N1/Mode0/7-bit-addr/TAP+BSR/req-ACK-parity/odd-parity+inhibit/stuffing+CRC15/NRZI+stuffing+SE0/Manchester+CRC32
- TB bugs found+fixed en route: sticky flags needed for 1-cycle pulses; >32b fields must chunk (SWD parity, CAN/USB/ETH payloads) — real core contract; JTAG needs 5xTMS TAP reset; CAN destuffer skips bit AFTER the 5-run
- Regression: 9/9 PASS, verilator lint clean; VCDs per protocol in sim/
## [2026-09-18] milestone | Milestone 1: shared hardware layer complete
- Created wiki/STATUS.md (resume-here doc) and regress/run_all.sh + regress/synth_area.sh (one-command regression and area report)
- Verified state: 14/14 TBs pass; pe_serdes 539 cells/11.2k um2 mapped, 17.2k um2 routed, 66 MHz signoff clean; codecs 110 cells total
- Corrected: pe_serdes cell count is 539 (measured), not the 583 previously derived in a commit message
- Not built yet: DRU, SM/sequencer, pin matrix/OE, word FIFO, assembler — next milestone per STATUS.md
## [2026-09-18] concept | strobe + committing edge explained, with real capture
- Created wiki/concepts/strobe-and-committing-edge.md — defines the two terms from the RTL's own contract (pe_serdes.v:12, pe_bitstuff.v (the stuff-bit strobe note)) and the combinational-vs-registered sampling rule (tb_pe_codec_mux.v:10-13)
- Real numbers from sim/tb_pe_uart.vcd: tx_load @206ns, first strobe @217ns, cells 160ns apart (16 clk @ 10ns)
## [2026-09-18] reference | signal-names.md — every RTL port documented
- Created wiki/reference/signal-names.md: all 60 ports across the 5 modules, plus the naming conventions (tx_/rx_, *_en, *_valid, *_raw vs *_wire, *_lvl, *_err, cfg_* snapshots) and the internal signals the RTL comments refer to (tx_rd_idx, rx_pos, rx_fin, tx_pend …)
- Port tables are EXTRACTED from the Verilog by tools/gen/signal_glossary.py, not hand-typed; --check exits 1 on drift, and regress/run_all.sh now runs it, so a renamed port cannot leave the page describing a dead interface. Verified: renaming rx_valid->rx_done made the gate fail, then restored
- Hand-written prose is limited to what the RTL cannot say about itself (meaning, validity, which protocol uses it); a port lacking a note is still listed with a marker so the table can never silently omit a signal
- Added a 'reference' page type + tag to SCHEMA.md; linked the page from each RTL header and from strobe-and-committing-edge
- New section in wiki/index.md (Reference), total pages 16
## [2026-09-18] reference | protocol pin budget — 26 pads, 24 usable, nothing needs more than 4
- Created wiki/reference/protocol-pin-budget.md: per-protocol IO counts with the wires named, the TT pad budget (ui_in 10 + uo_out 8 + uio 8 = 26, of which u_clk and u_rst_n eat 2 input bits, leaving 24 usable), and what the BOARD must add per protocol (pull-ups, transceiver, transformer, USB pull-up)
- Answer: max single protocol = 4 pins (SPI, JTAG). All nine pinned out simultaneously = ~23 of 24, i.e. it fits but is the wrong design — the premise is that protocols are firmware claiming pins at runtime via the programmable matrix, so the real constraint is how many run at once, not the count
- Counts read from the testbenches (wire sets confirmed against tb_pe_*.v declarations); TB presence is checked by the generator so a deleted TB cannot leave the page claiming coverage. Drift-verified by pointing a TB reference at a nonexistent file
- Same generated-doc discipline as signal-names.md: tools/gen/pin_budget.py + --check wired into regress/run_all.sh (now gates both reference pages)
## [2026-09-18] reference | SRAM budget — the die shape, not the area, is the constraint
- Created wiki/reference/sram-budget.md from the PDK LEFs (tools/gen/sram_budget.py): all 30 macros with real W×H, area and bits/µm²
- Key finding: TT tile notation is WIDTH×HEIGHT, so 8x4 at the template's 167x108 um tile is 1336x432 um — a 3.1:1 die, 0.577 mm² (the blog's 200x150 would give 1600x600 / 0.96 mm²). Consequence: the two densest macro classes (8192x32 at 1520x618, 2048x64 at 784x627) DO NOT FIT in either orientation
- Corrected a methodology error mid-task: density×area overestimates capacity because a rectangle packs worse than its area implies. Switched to real 2D grid packing — best packable is 131,072 bits (16 KB) on the template die, 196,608 (24 KB) on the blog die, both ~90% die efficiency with zero logic
- Practical answer: 1 KB = 8% of die, 2 KB = 14%, 4 KB = 24%, 8 KB = 45%, 16 KB = 89%; 32 KB unreachable with a single macro type. 1-2 KB comfortable, 4 KB ceiling for a design that also needs logic
- Also corrected the record: the wiki's "256x16 … 2048x64" macro list was incomplete (4096/8192 classes, 2P variants, non-BIST 64x16/64x32 exist). STATUS open risk updated with the real numbers
- Gate: gen_sram_budget --check joins run_all.sh, skipped loudly if the PDK is absent (external dependency, not repo state). Drift-verified by perturbing the tile size
## [2026-09-20] plan | through-i2c.md — plan to the I2C milestone
- Created wiki/plans/through-i2c.md (new 'plan' page type + tag added to SCHEMA.md, new index section): definition of done, what already exists that it reuses, three blockers with the numbers, firmware design (tick plan, per-bit cost, transaction structure), test strategy, ordered work list, risks
- Key architectural statements: I2C is bit-banged, NOT SERDES-driven (per-bit conditional control flow — ACK, arbitration read-back, stretch — is the shape a word engine cannot express; keeps the SERDES for UART/SPI/CAN/USB where it already works); the pin matrix / open-drain is the real new hardware and the last thing gating the stretch protocols
- Timing worked as arithmetic to be checked at the pin, per the repo's existing exact-integer discipline: 1 us tick = 40 clocks; tLOW/tSU;STA/tBUF 5 ticks, tHIGH 6 (90.9 kbit/s, inside the 100 kHz ceiling); the 300 ns margins are the ones consumed by the pull-up edge, so tLOW is budgeted 4.8 us driven
- Load-bearing number for the read path: tLOW - tVD;DAT - tSU;DAT = 4.7 - 3.45 - 0.25 = 1.0 us = 40 cycles to notice, read, arbitrate and raise SCL (fast mode: 12 cycles). Spec values read from UM10204 Table 10, not recalled
- Instruction memory (Blocker 3): uart_echo is 114/128 words; recommendation is 1P_1024x16 (1024 x 16, 14% of the template die) when the second protocol lands, flops at 256 words as the alternative; the CPU's registered-ROM fetch-ahead means swapping flops for a macro changes nothing in the interface or cycle model
- Also recorded: the ISA has SHR and no shift-left, and a rotate suffices for MSB-first assembly (shift after every bit except the last), so no new opcode for I2C
## [2026-09-20] debug | tb_pe_soc_uart red -> root-caused and fixed (three defects)
- Symptom looked like an RTL/emulator cycle-model divergence (TX decoded d0 for 0x41 and e8 for 0x42; watchdog on 0x00; start bit 4.3 us vs 8.67 us). It was not the CPU
- Dominant bug: the TESTBENCH lost the echo's start edge. @(negedge tx_pin) ran after send_byte() returned, but the firmware echoes as soon as it has the byte and RX/TX are separate pins -- so the echo's start bit was already in flight. The TB synced to the next falling edge (the last data bit) and every decode was shifted one bit: 0x41 = 01000001 read one late = 11010000 = d0
- Fix: latch the edge with always @(negedge tx_pin) and anchor the sample grid to the LATCHED time via the real clock (while ($time < t_edge + BIT_NS*(1.5+k)) @(posedge clk)), re-arming per byte
- Second defect: the TB loaded 112 of the program's 114 words (i < 112); the program's own JMP 0 loop-back is at word 113
- Third defect: firmware/uart_echo.pe's start-bit wait branched JNZ tx_startw (the poll) instead of JNZ tx_start (the snapshot) -- its own comment above says the poll must jump back to the snapshot. A 2-tick wait therefore lasted 1 tick, which is the 4.3 us start bit
- Verified: tb_pe_soc_uart PASS on 41/42/00/FF (cells 8.6-8.7 us measured at the pin); emulator PASS on the same four; regress/run_firmware_tests.sh 5/5. Left standing: the tick is 173 clocks but three comments (pe_soc.v:58, uart_echo.pe, peemu.py:43) say 174 -- real baud 115,607 (+0.35%)
- Lesson (same as the Milestone-1 CAN/USB TB bugs): a testbench that waits for an event it may have already missed tests nothing. Latch the edge, anchor to the latched time
- Also fixed peemu.py's docstring: it pointed at wiki/concepts/firmware-uart.md, a page that does not exist; now points at wiki/plans/through-i2c.md
## [2026-09-20] milestone | Milestone 2 committed + housekeeping (handoff prep)
- STATUS.md rewritten for Milestone 2: both layers of the thesis now exist (shared hardware layer + programmable core); block diagram updated to show pe_cpu/pe_soc, the two coexisting implementation styles (SERDES word engine vs firmware bit-bang), and what is still NOT built (pin matrix, DRU, word FIFO, SRAM swap); reading order now points at plans/through-i2c.md second
- Measured and recorded: pe_cpu 377 cells / 4,805 um2; pe_soc 8,592 cells / 177,328 um2 local (182,133 total incl. the CPU; flop memory, called out explicitly so nobody reads it as a synthesis failure); regression is 16/16 TBs + 5/5 firmware tests
- regress/run_all.sh: now runs run_firmware_tests.sh FIRST (tb_pe_soc_uart $readmemh's the .hex it assembles, so the RTL test can never simulate a stale image), then all 16 TBs (tb_pe_cpu + tb_pe_soc_uart added to CASES), then the three generated-doc drift checks. Exits 0
- regress/synth_area.sh: covers pe_cpu and pe_soc, with a comment explaining the SoC's flop-memory area
- wiki/reference/signal-names.md regenerated (was stale after the new RTL: 22 undocumented ports); gen_signal_glossary --check now green
- Comment fixes: the tick is 173 clocks, not 174 (integer division; baud 115,607, +0.35%) in rtl/pe_soc.v, firmware/uart_echo.pe and tools/fw/peemu.py
- STATUS gotchas 10 and 11 added: (10) a TB that waits for an event it may have already missed tests nothing -- latch the edge, anchor to the latched time; (11) the emulator and the RTL must mirror each other, and a disagreement is a signal -- in this case it correctly localized the bug to the TB, not the CPU
- README.md updated for Milestone 2 (block table, quick start with the firmware loop, layout incl. firmware/ and tools/, the two-styles design paragraph)
- Created HANDOFF.md: verified state, the six traps worth not rediscovering (TB edge latching, flop-memory area, 173 vs 174, the .hex/run order, verilator warnings, the LibreLane PDK flag), the current work list, repo conventions, environment
- Verilator -Wall on the new blocks reports 4 intentional warnings and exits non-zero; lint is deliberately NOT wired into run_all.sh, and STATUS says so rather than claiming "lint clean"

## [2026-09-20] review | project review: four invisible defects, a gate, and the TT top level
- Review pass over design, planning and tooling. Regression was 16/16 green and every headline number in STATUS checked out; all four defects found were ones a passing testbench structurally cannot see
- **tick_flag was driven by TWO always_ff blocks.** Icarus raced it (measured 50 of 100 ticks dropped by a 2-instruction poll loop; 193/1156 in a standalone probe) and yosys reported a driver-driver conflict and resolved it to a CONSTANT 0 — the STATUS port worked in simulation and was dead in the netlist. Merged into one process, set-beats-clear (losing a tick costs a bit period; re-reporting one costs a poll iteration). STATUS.md had called this warning "intentional"
- **dbg_pc/dbg_a were hierarchical references** (`assign dbg_pc = u_cpu.pc`). Icarus accepts them; yosys declared `\u_cpu.pc` implicitly and drove it BACKWARDS, leaving dbg_pc[7:1]/dbg_a[7:1] tied to 0 in the netlist. Now real output ports on pe_cpu
- **The firmware receive-buffer pointer never advanced.** `ADD A,1` then `AND A,0x0E` is 0 for every input, so three bytes all wrote slot 0. Invisible because the echo path reads slot 15. Also the declared buffer range (0..13) overlapped the scratch slots at 12/13 and the pointer at 14. Now `AND 0x07` over a real 0..7 buffer, with the slot map corrected
- **The assembler truncated every out-of-range field silently**: a 129-word program, `JMP 200`, `LDM A, 128` (which re-encoded as `LDM X`) and `STM 20, A` all assembled clean. Five negative tests added; peasm now rejects them with the reason
- Root cause of all four surviving so long: `regress/synth_area.sh` captured yosys's whole output and grepped it only for cell counts, so both synthesis warnings were printed on every run and discarded. It now surfaces them and exits non-zero. Added `regress/lint.sh` (verilator -Wall on 8 tops + a yosys elaboration check for driver conflicts and implicit declarations) and wired it into run_all.sh — a simulator's resolution of illegal RTL is not the synthesiser's
- New tests: `firmware/tick_count.pe` + `tb/tb_pe_soc_tick.v` (the STATUS port had NO firmware exercising it, which is why its flop could be a constant); `--expect-buffer` in peemu (checks state, not just echoed bytes). Both were verified RED against the unfixed code first
- **Built the Tiny Tapeout top level**: `rtl/tt_um_protocol_emulator.v` + `info.yaml` + `tb/tb_tt_um_protocol_emulator.v`. There was no `tt_um_*` module anywhere, so nothing in the repo was submittable and every pin-budget conclusion described an interface no RTL implemented. The TB asserts the pad contract continuously — no X on any output, `ena` gates nothing, open-drain pins never drive high — and was mutation-tested: all three defects it targets were confirmed caught
- **Flow config moved into the repo** (`flow/pe_serdes.json`, `flow/run_librelane.sh`). The 66 MHz / 0 DRC / 0 LVS signoff config lived only in ~/asic-runs, so a clone could not reproduce the one routed result the project claims
- Codec fixes: pe_manch's rx_err was combinational and ungated, so it sat high on an idle line and permanently high whenever Manchester was bypassed — it is OR'd with pe_bitstuff's registered rx_err in pe_codec_mux, and two sampling rules for one output is not a contract. Now registered and strobe-gated in both. Added `clr` to pe_nrzi and pe_manch (only the stuffer had it; a USB packet starts from idle J and the only route there was a chip reset)
- Area reporting corrected: synth_area.sh read yosys's per-module LOCAL area, which is 69 um2 for pe_codec_mux (glue only) and 0 um2 for any wrapper. Now prefers "Chip area for top module". Real totals: pe_cpu 387/4,952; pe_soc 8,744/182,650; tt_um top 8,743/182,652
- Plan corrections in through-i2c.md: (1) the pull-up reasoning was INVERTED — SCL's rise is released and slow, so it is consumed from tHIGH, not tLOW; the 5/6 tick split is right for the opposite reason to the one written, and tLOW should NOT be shortened to 4.8 us; (2) "our write path changes SDA right after SCL falls (hold ~0) which is legal" is wrong — UM10204 Table 10 note 2 requires a transmitter to internally provide >=300 ns of SDA hold to bridge SCL's falling edge; (3) tSU;DAT budgeted as ">=10 cycles" is 250 ns at 40 MHz, exactly the minimum with zero margin — use a full tick
- Documented honestly rather than fixed: the tick-delta wait returns after (0,1] ticks, not 1, so uart_echo's 3-tick alignment lands in (2,3] and the worst case sits on the start-bit/bit-0 boundary. The header had claimed "2 ticks of margin". Inherent to a free-running tick; a sub-tick NOP delay would recentre it, recorded as a follow-up before fast-mode I2C
- Emulator cleanup: removed a dead `branch_a` forwarding variable documented as "mirroring rtl/pe_cpu.v's branch_a" (the RTL has no such signal and needs none — single-cycle), and a `dmem_rdata` that was computed every cycle and never read. Docstring said dmem reads are registered; the RTL says combinational on purpose. Cycle count unchanged at 39,444, confirming the removal was behaviour-preserving
- Removed vestigial `uv init` scaffolding (src/ package with a "Hello from" entry point); the real tools are standalone in tools/
- Regression now 18/18 TBs + 11/11 firmware tests + lint clean + 3 generated-doc drift checks

## [2026-09-20] analysis | area budget, 10BASE-T scoping, and the memory plan
- Measured the area question properly by synthesising pe_soc at four IMEM depths (16/32/64/128 words): dead-linear at **1,271 um2 and 60 cells per instruction word**, with all other SoC logic (CPU, DMEM, timer, pin, glue) at 19,947 um2 / 1,025 cells. **Flop instruction memory is 89% of the current design** — ~80 um2/bit against ~5 for a macro
- Established the mapped->die factor as **1.97** from the only block that has actually been routed (pe_serdes: 11,223 mapped -> 17,211 routed cells -> 29,164 um2 die at 78% util). Macros place as-is with no routing inflation
- Occupancy: the integrated design TODAY (SoC + SERDES + codecs) is 384,500 um2 of die = **89% of a 4x6** / 67% of an 8x4. After the SRAM swap it is 235,116 = 54% / 41%. Gate count is not the constraint at any point (9,397 cells now, ~1,700 after the swap, against ~24,000 for 24 tiles)
- **Tile allocation raised as an open question**: the user reports 4x6 as current; the blog instructs 8x4 and info.yaml says 8x4, with the Gemini transcript's "6x4" already marked superseded. Recorded in STATUS open questions as needing confirmation from Jane Street rather than silently overwriting a sourced figure. The two are 24 vs 32 tiles but, more importantly, 668x648 (1.03:1) vs 1336x432 (3.09:1) — and SHAPE is what decides macro fit
- Made `tools/gen/sram_budget.py` take `--tiles WxH` (default 8x4) so the whole page can be re-answered for another allocation with one command; --tiles and --check are mutually exclusive since the committed page is the 8x4 answer. Confirmed a 4x6 die loses the ENTIRE 64-bit-wide macro family (1P_1024x64, 1P_512x64, 1P_256x64, 1P_64x64 — all 784 um wide against a 668 um die width)
- Fixed a misleading message in the same generator: macros that do not fit were all reported as "too tall in both orientations", which is wrong for the x64 family on a near-square die where WIDTH is the blocker. It now names the actual failing dimension
- **Created wiki/concepts/ethernet-scope.md.** The blog's entire text on the subject is one line ("Stretch goals: low-speed USB and 10Mbit Ethernet") — no TCP, no host, no SPI. Read against the framing (PIO/PRU inspiration, "hardware debugging and reverse engineering"), 10Mbit Ethernet means the LINE LAYER. Key findings: (1) 32 KB was never the requirement — a max Ethernet frame is 1,518 bytes, inside the "comfortable" 1-2 KB band the SRAM page already established, and cdr-oversampling.md already assumed 1518 for its drift maths; (2) the real constraint is TIME, not space — 100 ns/bit is 4 clocks at 40 MHz, so 32 instructions per byte, while CRC-32 in firmware costs ~240/byte, over budget by 7.5x. Ethernet bits MUST be hardware (DRU + Manchester + SERDES + CRC LFSR); firmware only sequences frames; (3) streaming to an SPI host is a CONCURRENCY problem, not an area one — two protocols at once on a core with no interrupts — and store-and-forward into a frame buffer removes it; (4) the demo that proves 10BASE-T without any stack is an ARP request/reply, 42 bytes each way
- Recorded that **no host data path exists at all**: the SoC's host_* port is firmware loading only and the TT wrapper ties it off. Flagged in STATUS as needing a decision record BEFORE the pin matrix fixes pin assignments
- **Created wiki/decisions/adr-003-memory-plan.md**: two `1P_1024x16` macros, one for 1,024 instruction words and one as a 2 KB frame buffer, kept separate because the CPU is Harvard. Supersedes through-i2c Blocker 3 (which considered instruction memory only). Load-bearing finding: **1.5 KB cannot be bought** — both 1 KB candidates (1P_512x16, 1P_1024x8) miss a 1,518-byte frame by 494 bytes, so the practical floor is 2 KB. 1P_1024x16 over 1P_512x32 (within 46 um2 of each other) because it is the same part as the IMEM: one macro type, one timing arc, one set of BIST hooks. Consequence recorded: a 16-bit-wide frame buffer needs byte-select logic
- **Reordered the work list in STATUS with reasoning.** Recommendation is NOT DRU/LFSR next. The blog's baseline is "UART, SPI, and I2C" and only UART exists as a program. Order: (1) SRAM swap — highest leverage, 89%->54% of die and 128->1024 words, and peasm now hard-fails past 128 so the next protocol hits the wall immediately; (2) SPI as firmware — cheapest remaining baseline protocol because SPI is push-pull and needs NO pin matrix, only a wider pin port; (3) pin matrix then I2C; (4) CRC LFSR — ~120 cells, serves three protocols, and tb_pe_can/usb/eth already compute those CRCs in their models so a golden reference exists on day one; (5) DRU last, being the highest-uncertainty block and serving only stretch goals. Documented the one reason to reorder: pulling DRU forward to de-risk, with ~16 months to the 2027-01-18 deadline
- through-i2c.md: the SRAM swap moved from "out of scope for this milestone" to a prerequisite, and Blocker 3 marked superseded by ADR-003
- wiki/index.md: 21 pages, new Concepts and Decisions entries

## [2026-09-20] ingest | blog re-fetched VERBATIM — the allocation is 6x4, not 8x4
- Re-fetched https://blog.janestreet.com/protocol-emulator-asic-competition/ and kept the FULL TEXT as `raw/articles/janestreet-competition-blog-fulltext.md` (sha256 of the fetched HTML in the frontmatter). The repo previously had only a hand-written SUMMARY of the blog, which is a derived work and should never have lived in raw/
- **The blog says 6x4, three times**: "Set the tile size in info.yaml to 6x4"; "The current maximum area is 6x4 tiles per design"; "An 6x4 allocation is 24 tiles. At approximately 200um x 150um per tile, that's about 0.7 mm2". 8x4 appears ONLY as "the possibility of scaling up to 8x4 tiles (~30% more area)", to be announced by a page update and an email to sign-ups
- **The 2026-09-17 summary was wrong and the Gemini transcript was right.** The transcript said "initially 6x4, possibly scaling to 8x4" and "~0.7 mm2 nominal"; the wiki used the bad paraphrase to rule both stale under the "blog outranks transcript" policy. Reversed in competition-overview.md with the old text quoted so the error is visible rather than erased
- **New SCHEMA rules from this**: (1) a source outranks another only if the CAPTURE is faithful — authority of origin does not survive lossy transcription, so check that what you hold of A is A's text before letting A overrule B; (2) keep the full text of any source the wiki's facts depend on, under raw/, with a sha256 of the fetched bytes; a summary is a derived work and belongs in a wiki page; (3) mark living sources as living and re-fetch them — this page says it will change; (4) a superseding capture is a NEW file, never an edit to the old one
- Corrected everywhere: `info.yaml` tiles 8x4 -> **6x4**; competition-overview.md; entities/tiny-tapeout.md; STATUS.md area budget and risks; adr-003-memory-plan.md; README.md; through-i2c.md; tools/gen/pin_budget.py's related-links line
- `tools/gen/sram_budget.py` default is now 6x4 and every hardcoded "8x4"/"32 tiles"/"1336x432"/packing-table label is DERIVED from TILES_W/TILES_H, so the page can never again disagree with the constant. `--tiles 8x4` renders the upside case. Regenerated; page now reads 24-tile, 6x4, 1002x432
- **Geometry, and a correction to yesterday's 4x6 analysis.** 6x4 at the template tile is 1002x432 um (2.32:1); a 4x6 would be 668x648 (1.03:1). Same 24 tiles, different shape. I previously analysed 4x6 and reported that the entire 64-bit-wide macro family drops out — that is true of 4x6 but NOT of the real 6x4, which keeps all four (1P_1024x64, 1P_512x64, 1P_256x64, 1P_64x64). Shape, not tile count, decides macro fit
- **The 8x4 upside changes nothing in the macro analysis**: 6x4 and 8x4 are the same HEIGHT (432 um at the template tile) and differ only in width, so no macro that fits one fails on the other. 8x4 is pure extra width
- Occupancy on the real 6x4 die (432,864 um2): today, integrated, with flop IMEM = 385,265 um2 = **89%**; after the ADR-003 SRAM swap = 235,116 = **54%**; leaner swap (1P_512x16 IMEM) = 200,751 = 46%. ADR-003's decision is unaffected by the allocation change — both chosen macros are 237x336 and fit every candidate shape
- Note the blog's own arithmetic is self-consistent at 6x4: 6x4 at 200x150 = 1200x600 = 0.72 mm2, matching its stated "about 0.7 mm2". The 8x4 reading never was (it implied ~1 mm2, which the old summary duly recorded)
- Regression unchanged and green: 18/18 TBs, 11/11 firmware, lint clean, 3 generated-doc drift checks

## [2026-09-20] rtl | pe_crc + pe_dru implemented: 20/20 TBs, lint clean
- `rtl/pe_crc.v` (209 cells / 3,354 um2) — ONE shift-right datapath serves both CRC
  families, so there is no mode bit and no width port. Constants checked against the
  RevEng catalogue's published values (`tools/gen/crc_config.py`, drift-checked in
  `run_all.sh`); `tb_pe_crc` asserts the catalogue `check` AND `residue` for six
  polynomials, so a transcription error fails the build.
- `rtl/pe_dru.v` (116 cells / 2,065 um2) — oversampled Manchester receive. The whole
  design is: phase counter reset on EVERY edge, captures at phase 2 and 6, and one
  flag. `tb_pe_dru` is the only place the grid claim is measured, against every
  Manchester transition pattern, and it feeds the DRU into a real `pe_manch`.
- Three findings worth keeping, all of which were TB or model bugs before they were
  RTL bugs:
  1. **A 3-tap majority is not a delay.** Its output moves a sample later than the
     centre tap at a level change, so feeding it straight into the edge detector
     shifted every edge by one sample — which moves the phase-6 capture off the
     half-cell centre and returns the WRONG LEVEL. Fixed by resampling the majority
     before it drives the counter: the filter now removes glitches and cannot move an
     edge. This is the kind of defect a "does the filter work" test cannot see.
  2. **`cfg_out_inv` must complement the WIRE BIT, not the feedback.** Routing the
     complement into the CRC's feedback path makes `fb == 1` on every field strobe, so
     the register applies its mask 32 times while it should be emptying and ends
     somewhere meaningless. Every transmit-side check still passes either way — only
     the receiver's drain-to-zero reveals it.
  3. **Error detection is not "the CRC changed".** A corrupt payload with a
     correspondingly corrupt CRC is a CONSISTENT frame and verifies correctly. The TB
     therefore corrupts the RECEIVED stream, and the assertion is unconditional
     because every polynomial here has a non-zero x^0 term.
- The DRU's first cell after acquisition can be mislabelled (the F/S parity needs a
  transition to seed). That is not a defect: it is why Ethernet has a 56-bit preamble
  and why the preamble is defined as the part that gets consumed. The TB models a
  frame boundary with a three-cell lead-in rather than demanding something no
  Manchester receiver promises.
- Regression: 20/20 TBs + 11/11 firmware + lint clean + all four generated-doc drift
  checks green.

## [2026-09-20] rtl | SRAM swap + PC widening: SoC 8,744 -> 1,083 cells
- `rtl/pe_imem.v` added: the instruction memory is now the REAL `1P_1024x16_c2_bm_bist`
  hard macro, behind a wrapper that owns the MEN/WEN/REN/BM protocol. `FLOP=1` gives
  a register-array fallback at any depth for tests and area experiments.
- `rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v` added: an empty port shell so yosys can
  elaborate the instance. It is NOT a model — simulation uses the PDK's real
  behavioural model, located by `regress/sram_model.sh`, and a missing model is a hard
  failure rather than a silent fall back to the flops.
- **Found a blocker the plan had missed.** `pe_cpu` had a fixed 8-bit PC, so 1024
  words were not addressable: `next_pc[IAW-1:0]` became an out-of-range part-select
  and the reachable program stayed 256 words no matter how deep the memory was.
  Blocker 3's claim that the swap "does not change the CPU's interface" was true of
  the cycle model and false of the address width. PC and jump-target field are now
  derived from IMEM_WORDS (8 bits at 128 words, 10 at 1024). Recorded as
  [[decisions/adr-004-program-counter-width]].
- **Measured, from `regress/synth_area.sh`, both ways round:**
  | | cells | um2 |
  |---|---|---|
  | 1024 words in flops | 60,806 | 1,300,104 |
  | 1024 words in the macro | 12 glue + 1 macro instance | 187 + LEF area |
  | SoC total | 8,744 -> **1,083** | 182,650 -> **19,795** |
  The flop figure reproduces ADR-003's measured 1,271 um2/word exactly, which
  cross-checks the two measurements against each other.
- **Three protocol facts read from the vendor model, not guessed.** (1) `A_BM[i]=1`
  means write bit i, so BM=0 with WEN=1 is a SILENT no-op; (2) read latency is one
  cycle, matching the datasheet's "one-cycle data-access", so the CPU's fetch-ahead
  survives unchanged; (3) `A_REN=1` during a write is WRITE-THROUGH. `tb_pe_imem`
  tests all three against the real model and is mutation-checked — `BM` tied low
  fails it, and `REN` tied high reproduces the write-through failure exactly.
- One real behavioural change from the longer load window: `tb_pe_soc_tick` began
  losing ticks because the 1024-cycle loader (~6 ticks) let the free-running timer
  advance before the core started. At 128 words the load was SHORTER than one
  173-cycle tick, so the test's "timer starts at 0" assumption had been true by
  accident. The TB now resets after loading, which is safe because `pe_imem` has no
  reset and the SRAM keeps its contents.
- Regression: 21/21 TBs + 13/13 firmware + lint clean. The firmware suite gained two
  tests: rejection of a jump past the operand field, and a POSITIVE test that word
  300 is now reachable — which the old 8-bit PC could not express.

## [2026-09-21] decide | ADR-005: 60 MHz turbo, not 66 — the 66 MHz turbo claim was wrong

- Question raised: "is there any advantage to going 66 MHz and placing some tx edges
  a little off-grid, but still within protocol spec?" The answer is no, and the
  reason is a proof rather than a preference.
- The 10BASE-T transmit jitter requirement is a **conformance test**, not a budget to
  nibble (IEEE 802.3 §14.3.1.2.3; UNH 10BASE-T MAU suite 14.1.10/14.1.11): crossings
  must land at 8.0 BT ±11 ns and 8.5 BT ±11 ns (with TPM; ±20 ns without).
- A run of identical bits places a crossing on every half-UI, so the 16- and 17-half-UI
  spans are constrained at once. At 66.0 MHz (T = 15.1515 ns) each window admits exactly
  one tick count (800 ns -> 53 ticks; 850 ns -> 56), which forces every inter-edge gap
  to 3 ticks, so span16 = 16×3 = 48 ticks = 727 ns against a required 53 ticks = 803 ns.
  **Contradiction — and dithering cannot escape it**, because the constraint is on the
  sliding window, not the instantaneous edge.
- 66.5 MHz IS feasible (A17 = {56, 57} admits a 16-periodic pattern of 5 gaps of 4 and
  11 of 3) but needs a bespoke dither generator to gain 0.5 MHz over 60.
- The real upgrade is **60 MHz**: f = 20n MHz keeps 50 ns and 100 ns exact, and 60 is
  under the 66.5 ceiling and exactly generatable (RP2040 120/2). Strictly better than 40
  on every axis — USB-LS becomes exact (40.000 vs 26.667 ticks), UART improves (+0.353%
  -> +0.160%), RX grid refines 50% (12.5 -> 8.333 ns, SPB 8 -> 12).
- SPB = 12 satisfies pe_dru's SPB % 4 == 0 guard. Verify by running the DRU testbench at
  SPB=12: PASS.
- 66 MHz retains exactly one role: a conservative STA signoff target (close at 66, run
  at 60 leaves ~10% free margin and covers the "IHP pads top out below 66" hedge).
- Also rejected in the same pass, on separate grounds: DDR on the core clock for an
  "effective 135 MHz". It costs 1.52× area per storage bit (dlhrq_1 + dllrq_1 + mux2_1 =
  74.39 µm² vs dfrbpq_1 = 48.99 µm²), the library has NO negedge flops to build it from
  (all 14 sequential cells declare clocked_on: "CLK"; both latch polarities do exist),
  and the logic already closes at ~2.5 ns reg-to-reg against a 7.58 ns half-cycle.
  Raising the clock is strictly cheaper than adding a second edge.
- The demo board's own default 62.5 MHz = 125/2 is NOT 20n MHz and fails the same way
  66 does — a turbo must be requested explicitly.
- **Measured, not just argued:** tb_pe_soc_uart with CLK_HZ = 60 MHz passes UNCHANGED,
  firmware and all — no RTL or firmware edit. That is the evidence that the turbo is a
  one-parameter change. (Run it from sim/: the TB $readmemh's ../firmware/uart_echo.hex,
  and running from the wrong directory loads nothing and the CPU executes garbage —
  which is exactly how this was first "failed" and then correctly diagnosed.)
- Created: decisions/adr-005-60mhz-turbo.md. Updated: concepts/tx-timing-generation.md
  (the "forced-66 fallback" section is replaced by the proof, and the signoff policy now
  reads "close at 66, run at 60"), wiki/STATUS.md (key-decisions table + gotchas 24-26),
  HANDOFF.md, wiki/index.md. New: regress/param_guards.sh (in run_all.sh).

## [2026-09-21] decide | Switched the project to the 60 MHz operating point
- ADR-005 moved from "60 MHz turbo, 40 default" to **60 MHz is the operating point**.
  User: "yep. redesign everything around 60MHz."
- Switched: pe_soc CLK_HZ default -> 60_000_000; tt_um top instantiation -> 60 MHz;
  pe_dru SPB default -> 12; info.yaml clock_hz -> 60000000; peemu.py CLK_HZ/tick table
  (260, +0.160%); tb_pe_soc_uart, tb_pe_soc_tick, tb_pe_dru, tb_tt_um_protocol_emulator
  clock/grid params; firmware/uart_echo.pe timing comments; flow/pe_serdes.json comment.
- **No RTL restructuring and no firmware edit were needed** — parameters, comments and
  derived tick arithmetic only. 40 MHz still passes if selected by parameter.
- New finding, recorded as STATUS gotcha 27: at 60 MHz the **SRAM macro is the critical
  path, not the logic**. Measured from the shipped .lib: A_CLK -> A_DOUT = 7.25 ns slow /
  4.34 ns typ / 2.67 ns fast. 7.25 ns is 29% of a 25 ns period but 43% of 16.667 ns.
  pe_imem has no output register by design (it would add a cycle and break the CPU's
  fetch-ahead), and the pe_serdes signoff contains no SRAM — so **the SoC needs its own
  STA run at 15.15 ns before tapeout**. Written into reference/sram-budget.md (generated).
- Also corrected while sweeping: ethernet-scope's firmware-CRC budget is 48 clocks/byte
  at 60 MHz (5.0x over budget, was 7.5x at 40) — the higher clock helps here.
- Two traps hit and recorded (STATUS gotchas 28-29): a TB hardcoding the clock period as
  an INTEGER (`int CLK_NS = 17` -> #(17/2) -> 62.5 MHz, not 60) now derives it as `real`
  from CLK_HZ; and a 60 MHz "failure" that was the harness running vvp from the wrong
  directory, so the TB's relative $readmemh loaded nothing and the core executed garbage.
  Read the failure's own warnings before diagnosing the design.
- Verified: 21/21 RTL TBs, 13/13 firmware, param guards OK, lint clean, 4/4 drift gates,
  and RTL/emulator tick arithmetic agree (both 60 MHz -> 260 ticks/bit).
- Updated: ADR-005, tx-timing-generation.md, cdr-oversampling.md, STATUS.md, HANDOFF.md,
  index.md, ethernet-scope.md, tiny-tapeout.md, clocking-options.md,
  strobe-and-committing-edge.md, README.md, through-i2c.md, plan-through-i2c.json.

## [2026-09-22] build | SPI as firmware — the second baseline protocol, and two flow fixes
- **SPI mode 0 as pure software** (`firmware/spi_xfer.pe`, 70 words): no shift
  register, no baud generator, no bit counter in RTL. SCLK/MOSI/CS_N are driven
  by read-modify-write on the shared 8-bit port; MISO is read from it. Built on
  the port that ADR-004's widening enabled.
- **Emulator gained an SPI wire model** (`tools/fw/peemu.py`): `poll_spi_slave`
  models a mode-0 slave and `--spi-slave` selects it instead of the UART model.
  The two directions are checked independently — the master's view from its
  rolling buffer, the slave's view assembled from the MOSI PIN. A master that
  drives the wrong edge is caught by the second even when its own receive path
  looks fine.
- **A bit-palindrome in the test vector made the first test unfalsifiable.**
  `0x5A` reversed is still `0x5A`, so an LSB-first master would put identical
  levels on MOSI. Firmware now sends `0x5B`, slave answers `0xA7 E5 96 C1`;
  every byte checked `reverse != self`. Recorded as STATUS gotcha 30.
- **Three mutations built, two caught, one correctly not:** bit-order flip caught
  (`80 80 80 80`), MOSI-after-rise/CPHA error caught (`2D AD AD AD`), sampling
  MISO before the rise **not** caught — because a CPHA=0 slave holds MISO from
  the falling edge, so that mutation is not observable. Recorded as gotcha 31.
- **Same tick jitter, opposite verdicts** (gotcha 32): the free-running tick wait
  returns in (0,1] ticks; fatal for the UART's free-running receiver, invisible
  for SPI's synchronous slave.
- **Full-SoC flow fixes, both diagnosed to root cause:**
  - **Global routing congestion was the `GRT_ADJUSTMENT` derate, not capacity.**
    LibreLane's generic default is 0.3 while the IHP PDK ships per-layer
    `GRT_LAYER_ADJUSTMENTS = 0.00`; the run log says `[INFO GRT-0022] Global
    adjustment: 30%`. At the real 6x4 die (1002x432, ADR-003) with logic at 7.6%
    utilization, 0.3 still overflowed 34 GCells across Metal2-5 and TopMetal1.
    Set to **0.0** — global routing now finishes with **0 overflow on every
    layer, 2.88% usage**.
  - **SRAM macro power: `PDN_MACRO_CONNECTIONS` needs one entry PER POWER PIN**
    (the macro has `VDD!` AND `VDDARRAY!`), and the macro's supply straps are
    **Metal4** while pdngen's grid is TopMetal1/TopMetal2 — so ~50 Metal4 shapes
    are still reported unconnected. Gotcha 33. `PSM-0069` connectivity failures
    are still open; the flow defers them ("you may ignore these if LVS passes").
- **CORRECTED 2026-09-22 (the entry above was WRONG).** It claimed a config
  comment quoted an OpenROAD warning (`GRT-0704`) "that does not exist in any run
  log", and I replaced it. **`GRT-0704` is real.** It is in
  `RUN_2026-09-22_00-07-27/warning.log`, and its text is
  `[GRT-0704] Try reduce the layer adjustment from 30.000002% to 0%` -- the tool
  literally recommending the change that fixed the congestion. The check that
  "proved" it absent was a `grep -rl` run from the REPO root, while the run logs
  live under `~/asic-runs`; a negative grep bounded by the wrong directory
  returned nothing, and I read "my search found nothing" as "it does not exist".
  **A negative result is only as good as the scope of the search that produced
  it** -- see STATUS gotcha 36.
- Verified: **21/21 RTL TBs, 15/15 firmware** (was 13 — the two SPI cases are
  new), param guards OK, lint clean, 4/4 drift gates.
- New: `wiki/concepts/spi-as-firmware.md`. Updated: STATUS.md (gotchas 30-33),
  index.md, firmware/spi_xfer.pe, tools/fw/peemu.py, regress/run_firmware_tests.sh,
  flow/pe_soc.json.

## [2026-09-22] build | Full SoC routed and timed clean — two flow fixes, both root-caused
   (**superseded numbers below**: the authoritative run is `RUN_2026-09-22_00-33-59`,
   which has BOTH fixes and reads setup +1.143 ns / SRAM in-context 7.635 ns /
   IR drop 0.30%; the +1.234 ns figure in this entry is from the pre-PDN run.)
- **The full-SoC flow now closes.** `RUN_2026-09-22_00-33-59` reached
  detailed routing with **0 DRC violations**, then post-PnR STA signed off
  **setup WNS +1.234 ns / hold WNS +0.127 ns / 0 violating paths at all three
  corners**. The instruction-fetch path this run existed to measure:
  - SRAM `A_CLK` -> `A_DOUT` in context: **7.639 ns** (vs 7.25 ns in the .lib
    table -- the 0.39 ns is clock-tree + placement overhead, and it is why the
    table figure was labelled an estimate)
  - path arrival 13.356 ns vs 14.590 ns required at 15.15 ns period
  - slow corner hold +0.654 ns
  Written into [[reference/sram-budget]] (generated; the estimate paragraph is
  now replaced by the measured table).
- **Flow fix 1 -- global routing congestion was a config derate, not capacity.**
  The run failed `GRT-0116` with 34 overflowed GCells at **4.59% total usage**.
  Cause: `GRT_ADJUSTMENT` defaults to **0.3** (log: `[INFO GRT-0022] Global
  adjustment: 30%`) while the IHP PDK ships `GRT_LAYER_ADJUSTMENTS = 0.00` for
  all 7 layers. Setting it to 0.0 gave **0 overflow, 2.88% usage**. Gotcha 34.
- **Flow fix 2 -- the SRAM's supplies are Metal4 and the PDN grid is
  TopMetal1/TopMetal2, so `PDN_MACRO_CONNECTIONS` was never enough.** It connects
  the pins *logically* (the log confirms the instance matches) but creates no
  physical path: `check_power_grid` kept reporting ~50 unconnected Metal4 shapes
  and `PSM-0069`, and the router shorted into them. Fixed with a custom
  `PDN_CFG` (`flow/pe_soc_pdn.tcl`) that stripes the macro on **Metal4** and
  connects Metal4 -> TopMetal1. **Verified with a standalone pdngen harness
  against the identical step-19 ODB** so the config could be A/B'd in ~1 minute
  instead of a 30-minute flow run: stock = `PSM-0069 FAILED`, custom =
  `PSM-0040 All shapes on net VPWR/VGND are connected`. Then confirmed in the
  real flow (2x PSM-0040, 0x PSM-0038/0069). Gotcha 33, rewritten now that it is
  solved rather than open.
- **CORRECTED 2026-09-22: the "fabricated quote" this entry describes was NOT
  fabricated.** `GRT-0704` is real and is the single best piece of evidence for
  this change -- see the correction further up this log. The config comment now
  cites it again, with the run and the date. What was actually wrong was my
  verification, not the quote. STATUS gotcha 36.
- Verified: **21/21 RTL TBs, 15/15 firmware**, param guards OK, lint clean,
  4/4 drift gates.
- Updated: flow/pe_soc.json (GRT_ADJUSTMENT, PDN_CFG), new
  flow/pe_soc_pdn.tcl, flow/run_librelane.sh (stages PDN_CFG),
  tools/gen/sram_budget.py + wiki/reference/sram-budget.md, STATUS.md
  (milestone header, firmware table, gotchas 33-34, next-steps 1-2 marked done),
  index.md.

## [2026-09-22] build | Final flow state: 57/80 steps, third blocker is a PDK GDS layer name
- **`RUN_2026-09-22_00-33-59` (both fixes) got the flow from 44/80 to 57/80.**
  Detailed routing: **0 DRC violations** (from 1160 at the first iteration).
  Post-PnR STA: setup **+1.143 ns**, hold **+0.121 ns**, **0 violating paths** at
  all three corners. SRAM in-context access **7.635 ns**. IR drop **0.30%**
  (3.56 mV of 1.20 V). The flow's own gates: "Routing DRC errors clear",
  "power grid violations clear", "critical disconnected pins clear",
  "Lint warnings clear".
- **The PDN fix is confirmed end to end.** `PSM-0040 All shapes on net
  VPWR/VGND are connected` now appears in BOTH the pdngen step and the IR-drop
  step, and `PSM-0069` appears nowhere. The step that previously aborted the
  whole flow (IR drop, `PSM-0069` -> `LibreLane will now quit`) now completes.
- **Third blocker, new, and NOT a defect in this design: Magic cannot find a PR
  boundary in the vendor macro's GDSII.** `get_bbox.tcl` reads the `FIXED_BBOX`
  property Magic derives from a **`pblock`** layer; the IHP SRAM GDS has
  **`189/4`** (the IHP map's `DIEAREA`) and no pblock. Error: "Failed to extract
  PR boundary from GDSII view of macro 'RM_IHPSG13_1P_1024x16_c2_bm_bist'". The
  size is not actually missing — the macro's LEF says `SIZE 236.8 BY 336.46`.
  A PDK-vocabulary mismatch, recorded as STATUS gotcha 35. Steps 0-56 all pass.
- **Numbers discipline:** a measured post-route slack moves ~0.1 ns between
  runs as placement changes (the pre-PDN run read +1.234 ns, this one +1.143 ns
  for the same design). [[reference/sram-budget]] and STATUS now carry the run ID
  with the number and say explicitly that it is a measured figure that moves.
- Verified: 21/21 RTL TBs, 15/15 firmware, param guards OK, lint clean,
  4/4 drift gates. Committed: 36f88cb, fd13b02, c70cf70.

## [2026-09-22] build | Pin matrix (plan step 4) — the I2C gate, 111 cells
- **`rtl/pe_pinmux.v` (111 cells / 2,061 µm²) is the last hardware the baseline
  tier needs.** Four registers per pin: OUT, OE, IN (read-only), OD. Everything
  after this (I2C, PS/2, SWD, USB) is firmware. The plan predicted "low hundreds
  of cells" and smaller than the SERDES (539) because it has no datapath; both
  hold. Table in [[STATUS]].
- **The `OD` bit is the load-bearing decision, and it is about the FIRMWARE
  IDIOM, not just safety.** `pad_oe = oe & ~(od & out)` makes open-drain
  bus contention *unreachable* rather than merely discouraged -- but the payoff
  is that `out=1`/`out=0` sends a 1/a 0 in BOTH push-pull and open-drain modes,
  so the same bit-banging loop drives either. Without it open-drain firmware
  toggles `oe` instead of `out` and every loop differs per mode, which would
  falsify "swap the program, gates unchanged" for I2C specifically.
- **`IN` is the pad, sampled combinationally, not a register.** A registered copy
  reports the PREVIOUS bit cell, so an arbitration check would compare this
  cell's drive against last cell's bus and report a win while the bus was being
  fought. Arbitration is entirely a question of latency, so the read path has
  none.
- **Rejected the plan's own "mux of 8 protocol wire sets" (`cfg_prot[i]`).**
  The selector would hold a constant per protocol -- a build-time map wearing a
  runtime hat -- and a bad selector value is a configuration that can disagree
  with the register file. Per-pin `{out,oe,od}` is smaller and cannot be
  self-inconsistent. Recorded in the RTL header and [[concepts/pin-matrix]].
- **`tb/tb_pe_pinmux.v` proves six properties, mutation-checked 7/7.** The
  interesting ones: the OD safety property is checked on `pad_oe` (the
  mechanism), NOT on the level, because a released pin and a driven-high pin
  both read 1 on an idle bus -- a level-only check passes for a design that
  shorts out on a busy one. And the wire model **reports contention as X rather
  than resolving it to a level**: a model that picked a winner would hide the
  fault it exists to expose. Mutations caught: drop OD gate (6), OD ignores OE
  (8), OUT/OE share a register (18), IN reads reg_out (1), write to IN clobbers
  OUT (1), reset does not clear OD (1), reset does not release (3).
- **Two traps found and recorded.** (1) `$error` takes ONE string at
  elaboration in Icarus; a `%0d` argument makes the tool emit "sorry:
  Elaboration tasks currently only support a single string argument" INSTEAD of
  the message, so the guard fires but the reader gets a parser complaint about
  the guard. Same trap as `pe_dru.v:117`. (2) The first wire model resolved all
  8 pins with one bus-wide ternary, so a single low pin dragged the whole byte
  low and two "other pins stay high" checks failed for a reason with nothing to
  do with the DUT -- a model wrong in the same direction as a plausible DUT bug
  is worse than no model.
- **`tb/*.vcd` is now gitignored.** `tb/tb_pe_pinmux.vcd` (40 KB) got committed
  with this change because the existing rules named only `pe_serdes.vcd` and
  `sim/*.vcd`; one glob covers the class. A VCD is an artifact of a run.
- Updated: `rtl/pe_pinmux.v`, `tb/tb_pe_pinmux.v`, `regress/run_all.sh`, `regress/lint.sh`,
  `regress/param_guards.sh` (PINS guard: 0 and 9 rejected, 1 and 8 accepted),
  `regress/synth_area.sh`, `tools/gen/signal_glossary.py` + regenerated
  `wiki/reference/signal-names.md`, `wiki/concepts/pin-matrix.md` (new),
  `wiki/index.md` (26 pages), `wiki/plans/through-i2c.md` (step 4 done),
  `wiki/STATUS.md`, `.gitignore`.
- Verified: 22/22 RTL TBs, 15/15 firmware, param guards OK, lint clean,
  4/4 drift gates. Committed: 19e4b2c, 1509c65.

## [2026-09-22] build | Flow reaches 76/80 — and the last two blockers are both inside the vendor macro
- **`RUN_2026-09-22_00-48-35` ran 76 of 80 steps.** It got past step 57 (the
  Magic PR-boundary abort) and past everything else, through GDS streamout,
  KLayout XOR ("Check for XOR differences clear"), Magic DRC, KLayout DRC, LVS,
  and all four timing checkers, to `76-misc-reportmanufacturability`. It then
  quit on **deferred** errors — the flow collects errors and reports at the end
  rather than stopping at the step.
- **Deferred errors: 1,113,909 Magic DRC + 2,672 KLayout DRC.** Investigated
  rather than assumed, because the repo's own [[entities/tiny-tapeout]] says TT
  accepts custom macros only when "DRC/LVS-clean":
  - **Magic: 1,113,909 of 1,113,909 are inside the macro footprint** (parsed
    every coordinate against the macro's placed bbox; 0 outside). Rules are
    library-internal artefacts: `Cnt.c` contact overlap (880,232), `LU.b`
    N-diff-to-P-tap (104,724), `Gat.c` poly overhang (104,737), `M2.d` minimum
    area (59,165).
  - **KLayout (PDK's own 174-rule deck): only 4 rules fire.** Dominant pair
    `Sdiod.d`/`Sdiod.e` — **ContBar inside nBuLay, an ESD-diode rule**; this
    design has no diodes, so those are the SRAM's own structures. Plus
    `Cnt.c.digibnd`.
  - **Every one of the 2,672 KLayout items names an `RM_IHPSG13_*` or
    `RSC_IHPSG13_*` cell.** `RSC_IHPSG13_*` is in **neither** the design's
    stdcell library **nor** the SRAM's LEF — it exists only inside the SRAM GDS.
  - The macro has a proper top cell (`0,-0.225 .. 236.8,336.46`), so not a
    malformed-GDS problem. **Decisive follow-up running: the PDK deck on the
    macro ALONE.** If it fails there, the finding is the PDK's, not ours.
- **`MAGIC_GDS_FLATGLOB` is the sanctioned route** and is unset. LibreLane's
  docstring: "Flatten cells by name pattern on input. May be used to avoid false
  positive DRC errors." Better than disabling DRC, which must not be done before
  the macro-alone test says the finding is not ours.
- **The flow GATES on max-slew/max-cap** — steps 72-75 are
  `Checker.{Setup,Hold,MaxSlew,MaxCap}Violations`. Setup/hold: "No violations
  found". Max-slew and max-cap: **"violations found" in all three corners.**
  So yesterday's gotcha-37 finding is a gated failure with a checker step named
  after it, not a passing-with-warnings. Gotchas 39-41.
- Verified: 22/22 RTL TBs, 15/15 firmware, param guards OK, lint clean,
  4/4 drift gates.

## [2026-09-22] build | The macro DRC is the PDK's, not ours — proved by the macro-alone diff
- **Ran the PDK's own `run_drc.py` on the SRAM macro ALONE** (`--run_mode deep`,
  the mode LibreLane uses) and diffed rule-by-rule against the full SoC:

  | rule | macro alone | full SoC | verdict |
  |---|---|---|---|
  | `Sdiod.d` | 1136 | 1136 | identical |
  | `Sdiod.e` | 1136 | 1136 | identical |
  | `Cnt.c.digibnd` | 400 | 400 | identical |
  | `M5.j`/`M5Fil.h`/`TM1.c`/`TM2.c` | 1 each | **0** | our PDN/fill fixed them |
  | **total** | **2676** | **2672** | |

  **2,672 of 2,672 SoC violations reproduce EXACTLY from the vendor macro alone;
  zero are introduced by assembling the SoC.** The vendor's own runner prints
  `KLayout DRC Check Failed` on the macro by itself. The SoC is *cleaner* than
  the macro standalone — the four 1-count BEOL rules are fixed by our PDN + fill.
- **Corroborated two ways.** IHP's own `ihp-sg13g2-librelane-template` issue #19:
  the vendor's reference design — **no SRAM in it** — completes `make librelane`
  with `1697 Magic DRC`, `40 KLayout DRC`, `[RSZ-0020] found 4 floating nets`,
  and **MaxSlew/MaxCap violations in the same corners**, all as deferred errors.
  And Tiny Tapeout's memory page documents the IHP SRAM macros as supported and
  points at a taped-out, tested 1024x8 SRAM project.
- **LVS independently agrees**: "Circuits match uniquely", 1926 devices / 1939
  nets both sides; step 71 `Checker.LVS` clear.
- **What this does NOT fix:** max-slew/max-cap are on SRAM *pins as driven by our
  routing* (`sg13g2_buf_1`, `A_DOUT[4]` fanout 20) and are gated by steps 74-75.
  That is our work. Gotchas 37-46.
- One process note: an earlier STATUS edit silently no-op'd because its anchor
  did not match, and it printed success anyway — I reported gotchas 39-41 as
  written when they were not. Rewritten with assertions that the text is present
  after writing, and re-verified.
- Verified: 22/22 RTL TBs, 15/15 firmware, param guards OK, lint clean,
  4/4 drift gates.


## [2026-09-22] build | Timing margin at 60 MHz: 16% setup, Fmax 71.4 MHz, and the hold fix costs 11% of it
- Extracted the margin from `RUN_2026-09-22_00-48-35` / `55-openroad-stapostpnr`.
  **Signoff is at 66 MHz (15.15 ns); the operating point is 60 MHz (16.667 ns)** —
  two different margins, not to be conflated.
  | | setup (slow corner) | hold (fast corner) |
  |---|---|---|
  | worst slack @66 MHz | **+1.143 ns** | **+0.121 ns** |
  | same path @60 MHz | **+2.660 ns** | +0.121 ns |
  | fraction of the 60 MHz period | **16.0%** | — |
  | violating paths | **0** | **0** |
- **Fmax (post-route, slow corner) = 71.4 MHz**, min period 14.007 ns — 19% over
  the operating point.
- **The critical path is not the CPU.** It starts at the SRAM
  (`A_DOUT[12]`, **7.635 ns** = 57% of the 13.448 ns arrival), then a chain of
  **hold-fix buffers** (`fanout118/115/113`, `sg13g2_buf_1`, 1.55 ns) and
  `hold626` (`sg13g2_dlygate4sd3_1`, **0.623 ns** of pure delay). **The hold
  repair is ~2.2 ns of a 14.0 ns period — ~11% of Fmax.** Drop it and the path
  closes at ~84 MHz. Cheapest lever on the clock; it is why the SDC hold/setup
  split (hold 0.25 ns) is load-bearing.
- **The margin is not the same as confidence in the number.** The SRAM's 7.635 ns
  is a `.lib` lookup taken OUTSIDE the characterised axes (gotchas 37-38): input
  slew presents 1.291 vs a table max of 0.5952. It is the one figure here that was
  extrapolated, not interpolated — and it is the majority of the path.
- Also fixed: two stale 40-clock I2C tick figures (§ 1 µs = 60 clocks at 60 MHz)
  in `HANDOFF.md` and the plan flowchart JSON, and STATUS's "all 16 RTL TBs" → 22.
- Verified: 22/22 RTL, 15/15 firmware, guards OK, lint clean, 4/4 drift gates.


## [2026-09-22] build | The clock is locked at 60 MHz, and pe_serdes closes there CLEAN
- **`CLK_HZ` is a `localparam`, not a parameter.** Nothing ever instantiated
  `pe_soc` at another rate: the TT top passed `60_000_000` — the same value
  as the default it was overriding — and every TB passed `60_000_000`. A
  parameter nobody varies is not a knob, it is a second place for the derived
  arithmetic to disagree with the first, which this project has paid for twice
  (the 173 tick, the 40-clock I2C µs). **Proven netlist-neutral**: `synth_area.sh`
  reports `pe_soc` at **1121 cells / 19,905.7824 um2** and `tt_um_top` at
  **1126 / 19,922.0742** before AND after — a refactor that changes no cell.
- **The 66 MHz STA signoff target is RETIRED.** Both flow configs moved
  `CLOCK_PERIOD` 15.15 -> **16.667**. Closing at 66 made every reported slack
  number require a conversion by the reader, and a longer period is strictly
  easier for setup — a design that closes at 66 has already closed at 60. The
  pad-ceiling hedge is honestly gone (no IHP-specific pad figure is published
  either way).
- **New drift-gated page: [[reference/clock-arithmetic]]** —
  `tools/gen/clock_arithmetic.py` READS `CLK_HZ` OUT OF THE RTL and derives every
  protocol constant from it. Exact at 60 MHz: 10BASE-T half-UI 50 ns = **3**
  ticks, 10BASE-T bit = 6, USB-FS 83.33 ns = **5**, USB-LS 666.67 ns = **40**,
  I2C µs = **60**, SPI 100 ns = **6**. Not exact: **UART 115200 half-bit = 260.417**
  -> 260, the one approximation (+0.160% baud). It asserts `SPB=12` and
  `TICKS_PER_BIT=260` and warns if either moves. Wired into `run_all.sh` as the
  fifth gate, which is what makes the lock stick.
- **`pe_serdes` re-signed at 60 MHz and it is CLEAN — every gate:**
  `No setup violations found` / `No hold violations found` / `No max slew
  violations found` / `No max cap violations found`, plus Magic DRC clear,
  KLayout DRC clear, LVS clear, XOR clear, 0-byte `error.log`. Setup worst
  **+8.816 ns** (was +7.6023 at 66), hold **+0.116 ns** (unchanged). `Flow
  complete.` at 80/80, GDS written (1.34 MB), die 29,163.7 µm², 78% util.
- **BUT: the 60 MHz signoff fixed NOTHING here, and saying otherwise would be a
  false cause.** The old run at `CLOCK_PERIOD` 15.15 (`~/asic-runs/pe-serdes/
  RUN_2026-09-18_16-53-07`) reports **max slew 0 / max cap 0 too** — identical on
  every checker. pe_serdes was already clean; closing at 60 only makes the
  reported slack BE the operating point. The two violations that fire are on the
  **SoC's SRAM pins**, and whether the relaxed period clears them is the question
  the SoC run answers, not this one.
- Verified: 22/22 RTL, 15/15 firmware, guards OK, lint clean, **5/5 drift gates**.


## [2026-09-22] build | The 60 MHz full-SoC signoff lands: 76/80, timing closed, only DRC defers
- **`RUN_2026-09-22_02-58-32`** — the first full-SoC run signed off at
  `CLOCK_PERIOD` 16.667 ns = **60 MHz directly**. Reached **76/80**.
  | | value |
  |---|---|
  | setup WNS (slow, 1.08 V/125 C) | **+2.6601 ns** |
  | hold WNS (fast, 1.32 V/-40 C) | **+0.1209 ns** |
  | setup / hold violating paths | **0 / 0**, all three corners |
  | max cap / max slew / max fanout | 8 / 10 / 7 — **warn only, do not gate** |
  | die | 1002 x 432 um2 = **432,864 um2**, 27.44% utilisation, 1,921 stdcells |
- **Every non-DRC checker is clear**: lint (errors, warnings, timing), unmapped
  Yosys instances, power grid, routing DRC, disconnected pins, XOR, illegal
  overlap, **LVS**, setup, hold. Plus IR drop 0.30% and `PSM-0040`.
- **The +2.6601 ns reproduces, to four significant figures, the +2.660 ns
  predicted by hand** from the 66 MHz run's critical path (arrival 13.4479 +
  capture clock 0.6419 - uncertainty 1.0 - library setup 0.2008). Independent
  check on the margin arithmetic.
- **The die is exactly the 6x4 allocation** (6 x 167 x 4 x 108 = 1002 x 432), so
  the routed result sits inside the confirmed tile budget with no scaling
  assumption. The SRAM macro alone is 79,674 um2 = 18.4% of the die.
- **The DRC counts are BYTE-IDENTICAL to the 66 MHz run** — 1113909 Magic / 2672
  KLayout both times, and `error.log` is the same 85 bytes in both. Cleanest
  evidence yet that they are macro-internal geometry, independent of the design's
  timing. Combined with the macro-alone diff (gotcha 44) and IHP's own template
  hitting the same class with no SRAM at all (gotcha 45), the finding is the
  PDK's.
- **What defers, exactly, and nothing else:** the 85-byte `error.log` holds two
  lines — `1113909 Magic DRC errors found. - deferred` and `2672 KLayout DRC
  errors found. - deferred`. That is the whole failure list. (An earlier reading
  of "0-byte error.log" was taken mid-run, before the flow wrote it; corrected.)
- **Also corrected:** gotcha 39 said the flow GATES on max-slew/max-cap. It does
  not — `MAX_SLEW_VIOLATION_CORNERS`/`MAX_CAP_VIOLATION_CORNERS` default to `[""]`
  and the empty string matches no corner, so those checkers can only warn. Read
  the mechanism out of `librelane/steps/checker.py` and confirmed in
  `resolved.json`. To make them gates: set both to `["*"]`.
- Verified: 22/22 RTL, 15/15 firmware, guards OK, lint clean, 7/7 drift gates.

## [2026-09-22] build | The matrix moves inside the SoC, and I2C runs on it

- **The plan had the pin matrix in the wrong place.** It said "the TT wrapper
  instantiates the matrix". Unimplementable: the CPU's IO bus never leaves
  `pe_soc`, so a matrix at the wrapper could not have its OE/OD registers
  reached by any program -- and I2C, the only protocol needing them, would be
  hardware nothing drives. It now sits between the port decode and the SoC's
  `pin_in`/`pin_out`/`pin_oe`. [[decisions/adr-006-pin-matrix]]
- **Two numbering schemes, not one.** The SoC's ports (0=PIN 1=PINOUT 2=PINOE
  3=PINOD) and the matrix's addresses (0=OUT 1=OE 2=IN 3=OD) differ. An identity
  map sends PINOUT writes into the OE register; written, and it hung
  `tb_pe_soc_uart` with an output enable of `0x08`. Now an explicit `case`.
- **`pin_rd` generalised** from `(pin_out & ~PIN_IN_MASK) | (pin_in & PIN_IN_MASK)`
  to `(pin_out & pin_oe) | (pin_in & ~pin_oe)` -- the real drive enable, so a
  pin released by the OD gate reads the pad. Reduces exactly to the old formula
  when `od=0`, which is why UART and SPI still pass *through* the matrix.
- **`firmware/i2c_pins.pe`** (79 words): START, one bit cell, STOP. Sends 1 by
  releasing, reads the pad back for arbitration (one `IN`, one branch).
- **THREE TIMING TRAPS, all of which cost real rework:**
  1. The `uart_echo`/`spi_xfer` "wait for the tick to CHANGE" idiom delivers
     `(0,1]` ticks. Fine for SPI, margin cost for UART, **spec violation for
     I2C**: the first draft took 1,384 cycles for 28 us of nominal delays
     (0.83x) and would have passed a bench test. Now an exact-target wait.
  2. **The phase residual sets the constants.** Firmware cannot see where in the
     60-cycle window a read lands, so an N-tick wait delivers `(N-1, N]` us --
     the number that must clear the floor is **N-1**. tLOW gets 7 and tHIGH 6
     (not the reverse): the floors differ, and the period is `tLOW+tHIGH` either
     way, so the swap is free.
  3. **Init order is OD, then OUT, then OE.** Enabling the pins before setting
     the level drove SDA low for two cycles with SCL high -- **a spurious
     START**. The OD bit prevents contention, not a wrong-moment drive. Also:
     pulling SDA low while SCL is high on the way into a STOP is a second START;
     the STOP order that cannot go wrong is in the concept page.
- **Measured (all 60 tick phases, worst case):** tLOW **5.917 us** (floor 4.7),
  tHIGH **6.050 us** (floor 4.0), period **11.967 us** (floor 10.0 for the
  100 kHz ceiling) => **83.2-83.6 kHz**, deterministic to 0.05 us.
- **THE TB WAS CAUGHT VACUOUS TWICE.** (a) The RTL TB had **no interval checks
  at all** -- a bit cell half the length of spec passed it. (b) Once added, the
  edge indices were wrong, making both checks unfailable: tLOW measured the idle
  stretch (19 us) and tHIGH was a negative difference that **wraps in the
  unsigned `%time` type** to a huge number. Both `>=` checks could never fail.
  There is now a plausibility guard that stops exactly that.
- **`regress/mutate_i2c_tb.sh`**: 6 mutations, **1 documented equivalent survivor**.
  On a port-0 read the matrix's raddr defaults to `A_IN`, so `pinmux_rdata` IS
  `pin_in` -- for firmware that only reads pins it has released, the read-back
  mutation is equivalent. The UART test does catch it (read-modify-write stops
  converging and the TB hangs), which is why the survivor is explained and the
  count asserted exactly. A compile failure reports **INCONCLUSIVE**, never
  "survived" -- the first version of that script reported 5 mutations DETECTED
  with byte-identical failures, which was a missing `$readmemh` path, not a
  good test.
- **Files:** `rtl/pe_soc.v`, `rtl/tt_um_protocol_emulator.v`,
  `firmware/i2c_pins.pe`, `tools/fw/peasm.py` (OE/OD/I2CTICK/I2CSTAT, `A|B`
  immediates), `tools/fw/peemu.py` (mirrors the matrix), `tb/tb_pe_soc_i2c.v`,
  `regress/mutate_i2c_tb.sh`, `tools/checks/i2c_timing.py`,
  [[decisions/adr-006-pin-matrix]], [[concepts/i2c-on-the-matrix]],
  [[concepts/pin-matrix]] (placement corrected), [[plans/through-i2c]].
- **Regression:** RTL 23/23, firmware 16/16, two new gates in `regress/run_all.sh`.
  Commit `4ea345a`.

## [2026-09-22] build | SPI mode 0 on real RTL, and a measured simulator bake-off
- **`tb_pe_soc_spi.v`** closes the gap `plans/through-i2c` step 4b left open: SPI
  firmware had only the emulator as its executable specification. The TB models a
  **real mode-0 slave** that decodes MOSI on the SCLK rise, so the byte it checks
  is the byte a real slave captured -- the emulator alone shared the firmware's own
  assumptions. Buffer matches the emulator byte-for-byte: `A7 E5 96 C1 3D 7B D2 4F`.
- **Three TB bugs, all recorded as gotchas.** (a) A `posedge clk` trace mixed old
  and new state because `pc` and the registered ROM `A_DOUT` update on the SAME
  edge. (b) The TB released `run` before the registered ROM had loaded `imem[0]`,
  so `LDI A,4` at pc 0 never executed -- `tb_pe_soc_uart`'s undocumented 4-clock gap
  is the requirement, not a quirk. (c) The slave armed on the CS_N **edge** while
  the SoC drives CS_N low from reset, so it never armed; model selection as a
  **level**.
- **A wrong assertion, caught by the emulator.** The TB asserted `dmem[15]` against
  the last response byte; the emulator agreed with the RTL on `00`, proving the
  ASSERTION wrong rather than the design. `dmem[15]` is cleared at the start of
  every frame -- the assertion compared the wrong window.
- **`regress/mutate_spi_tb.sh`**: 5 mutations (wrong sample edge, LSB-first shift, CS_N
  never deasserted, pin read ignoring inputs, no idle pattern), **5 detected, 0
  survived**, with a `verify_restore` guard.
- **BAKE-OFF (Icarus 13.0 vs Verilator 5.050)**, both verified PASS on the same TB
  first: SPI TB **110.3 ms vs 8.7 ms = 12.7x**; I2C TB **283.3 ms vs 15.0 ms =
  18.9x**; build **9 ms vs 2773 ms**; **break-even ~27 runs**. Verilator is
  **2-state** and Icarus **4-state** -- an unassigned signal becomes `0` silently
  under Verilator -- but all 5 SPI mutations give **identical FAIL counts** under
  both, so no detection power is lost today.
- **Files:** `tb/tb_pe_soc_spi.v`, `regress/mutate_spi_tb.sh`, `wiki/reference/simulator-bakeoff.md`.
- **Regression:** RTL 24/24, firmware 16/16. Commit `ecfd480`.

## [2026-09-22] build | `--fast`: parallelism, not a simulator swap
- `regress/run_all.sh --fast` runs the TB list through `regress/run_one_tb.sh` in parallel.
  **It is parallel Icarus, NOT a Verilator swap**, and that is a measured decision:
  Verilator builds per `--top-module` with no shared cache (~2.8 s each), so a naive
  per-TB swap makes the suite **69.6x SLOWER** (2.4 s -> 167 s) even though each
  run is 12-19x faster. The per-run win only pays back after ~27 runs of the SAME
  testbench -- the iteration loop, not the regression suite.
- **`tb_pe_pinmux` cannot run under Verilator at all** (`DIDNOTCONVERGE`): it models
  the bus at strength levels (pull-up vs strong 0/1) to test the OD bit's contention
  property, and 2-state has no weak/strong distinction. A survey of all TBs under
  both simulators: **21 agree, 1 differs, 3 use X-dependent constructs** -- so the
  2-state risk is real but now measured rather than assumed.
- Suite 10.7 -> 9.4 s; verdicts byte-identical serial vs `--fast`; an injected
  `pin_rd` break is caught identically by both paths.
- **Mutation contamination, found and fixed.** `firmware/spi_xfer.pe` was left
  mutated -- traced to an ad-hoc cross-check loop, NOT the committed harness -- after
  which every later test silently measured the mutant. Both harnesses now verify
  `git diff --quiet` after every restore. The first `verify_restore` guard was
  **fake** (it exited 0 with the restore sabotaged): the main success path called
  `restore` without it, because an earlier regex edit matched nothing.
- **Files:** `regress/run_one_tb.sh`, `regress/run_all.sh`, `wiki/reference/simulator-bakeoff.md`.
  Commit `4ce5632`.

## [2026-09-22] build | `pe_fbuf`: the 2 KB frame buffer
- `rtl/pe_fbuf.v` -- 2 KB behind a byte interface on the SAME `1P_1024x16` macro as
  the instruction memory, per [[decisions/adr-003-memory-plan]]. This was the last
  unbuilt hardware block for 10BASE-T: a maximum Ethernet frame is 1,518 bytes and
  the CPU's data memory is **16**, so a frame has nowhere to go without it.
- **The design is asymmetric, and that is the finding.** Writes are free -- the
  macro's bit-mask port IS byte-select in hardware, so there is no
  read-modify-write. Reads cost a **lane register**, because `A_DOUT` has no
  byte-select and the lane must be captured WITH the address.
- **Mutation testing earned its keep twice.** (a) Every read check held its address
  stable, so replacing the registered lane with the **live** lane passed all of
  them; real frame walks change the address every cycle. Added a pipelined-read
  check -- 5/5 mutations now detected. (b) The harness first demanded BOTH
  implementations fail per mutation, which misreported three genuine detects as
  "survived": a mutation to one path can only be caught by that path.
- TB runs BOTH the macro and the `FLOP=1` fallback, because a fallback that can
  silently diverge is worse than none. Measured area: **48 cells** for the macro
  build (glue only -- the macro's area is in its LEF) vs **45,368** for flops.
- **Files:** `rtl/pe_fbuf.v`, `tb/tb_pe_fbuf.v`, `regress/mutate_fbuf_tb.sh`,
  `regress/synth_area.sh`, `tools/gen/block_diagram.py`. Commit `8e30cb8`.

## [2026-09-22] build | `pe_eth_mac`: the 10BASE-T receive path
- **`rtl/pe_eth_mac.v`, 914 cells** -- the first protocol block deliberately NOT
  firmware, and the reason is arithmetic: 48 instructions per byte at 10BASE-T's
  100 ns bit period against ~240 for a software CRC-32 alone. Full write-up:
  [[concepts/ethernet-receive-path]].
- **It retires three orphans.** `pe_dru`, `pe_manch`, `pe_crc` and `pe_fbuf` are
  instantiated together for the first time; three of them had been in `rtl/` passing
  their own TBs while driving nothing.
- **Four real defects, each found by measuring rather than reasoning.** (a) The FCS
  convention: `pe_crc` has two self-consistent receiver contracts and only the
  catalogue residue (0xDEBB20E3) is an OUTSIDE value; `crc_zero` would reject every
  valid frame while looking like a CRC bug. (b) Carrier sense cannot come from
  `rx_err` OR `locked` -- measured, BOTH stay 0 on a held line; only the
  equal-halves property reports idle. (c) Without an inter-frame gate the receiver
  hunts inside an aborted frame and a payload `0xD5` locks a phantom frame --
  measured, one rejected frame reported `frame_bad` twice. (d) Two width bugs: an
  out-of-range part-select (`FCS_BYTES[AW:0]` on a 3-bit constant -> X in Icarus)
  and an unsized `'0` in a ternary that truncated the subtractor.
- **The cheapest lesson cost the most time: a preamble is a WIRE BIT PATTERN, not
  an octet.** 802.3 says "seven octets of the pattern 10101010", which reads as
  `0xAA` -- but a byte helper sends LSB-first, so `send_byte(8'hAA)` puts `01010101`
  on the wire, the inverted phase, and the junction with the SFD creates a SECOND
  false `0xD5` window seven bits early. Hand-deriving the window set gave the wrong
  answer twice; enumerating the 64-bit prelude in code settled it immediately
  (`0xD5` occurs exactly once, and an alternating preamble can only produce
  `0x55`/`0xAA`). That also showed an "alternating run must exceed N" guard was
  HARMFUL, not merely redundant.
- **The mutation harness destroyed its own target.** It restored with
  `git checkout` while `rtl/pe_eth_mac.v` was **untracked**, so every restore failed,
  all eight mutations stacked, and it reported "8 detected, 0 survived" -- a perfect
  score that meant nothing. Rebuilt from the mutation list, committed first, and the
  harness now snapshots with `cp` and verifies with `cmp` after every mutation.
  Honest result afterwards: **8 mutations, 7 detected, 1 survived** -- and the
  survivor (`no-bounds-check`) was a REAL gap, since the payload's own `room == 0`
  check produces the same `frame_bad` count. Closing it needed a `0xEE` guard
  pattern planted past every legitimate frame to assert the buffer was untouched,
  because the FLOP array starts as `x` and a zero-check fails on a correctly
  untouched buffer.
- **Files:** `rtl/pe_eth_mac.v`, `tb/tb_pe_eth_mac.v`, `regress/mutate_eth_mac_tb.sh`,
  `regress/run_all.sh`, `regress/synth_area.sh`, `tools/gen/block_diagram.py`,
  [[concepts/ethernet-receive-path]]. Commits `be4511f`, `76d54f8`.
- **Regression:** RTL **26/26**, firmware 16/16, all four mutation gates green,
  serial and `--fast` identical.

## [2026-09-22] lint | Wiki drift swept, and it was real
- **The wiki carried FUTURE DATES.** Several pages said `2026-09-23` and one said
  `2026-09-24`; `date` reports 2026-09-22 and every commit is 09-21/09-22. Corrected
  repo-wide. Cause: entries written at the end of a long session, dated by
  assumption instead of by `date`.
- **`index.md` was 10 pages stale** (said 30, disk had 40 files including raw). Now
  32 non-raw pages, counted programmatically rather than by hand.
- **`STATUS.md` header said branch `main`** while the branch is
  `review/fix-invisible-defects`, and titled itself "Milestone 2" while Milestone 3
  had landed. Both corrected.
- **Four work items were UNLOGGED** -- SPI-on-RTL, the bake-off, `--fast`, `pe_fbuf`,
  and `pe_eth_mac` -- which is what generated the four entries above. The log now
  covers the full path from `4ea345a` to `76d54f8`.
- **Added [[concepts/ethernet-receive-path]]** and put it in the index.
- **Lesson:** the log is the one artifact that cannot be reconstructed from the
  code, so it is the first thing to rot. Four commits had landed with no entry
  because each felt like "still in progress".

## [2026-09-22] review | nine findings worked: sources, DDR receive, framing, tools, gates

- **A full project review found 9 defects** (3×P1, 6×P2) on a `git archive` clone
  where the testbenches, firmware and mutation suites were all green. The report
  and the reproduction artifacts are `reviews/2026-09-22/REVIEW.md` and its
  neighbours; this entry is the log of the work.
- **[P1] The Tiny Tapeout `info.yaml` source list did not compile.** It omitted
  `pe_imem`, `pe_pinmux` and the SRAM shell; `iverilog` ended in `Unknown module
  type: RM_IHPSG13_1P_1024x16_c2_bm_bist`. The LibreLane SoC config omitted
  `pe_pinmux` the same way. Both lists completed and the TT list verified by
  compiling it.
- **[P1] The DRU sampled RISING EDGES ONLY.** At 60 MHz and SPB=12 it decoded a
  200 ns bit; 10BASE-T is 100 ns/bit, so a real-rate stimulus was missed
  entirely. The TBs drove the wire at half rate and hid it — a grid claim its
  test could not reach. Built ADR-002's latch-pair DDR front end (rising 2-flop
  synchronizer + falling transparent-high latch and flop), an interleaved 3-tap
  majority with the latency match that keeps the filter from moving the grid, and
  a task-based two-samples-per-clock grid machine. Both `tb_pe_dru` and
  `tb_pe_eth_mac` now drive real 60 MHz / 100 ns bits; the Ethernet TB's real
  frames + FCS pass end to end.
- **[P1] One oversize frame exhausted the receiver permanently.** The reclaim
  `{1'b0, pay_cnt[AW-1:0]}` truncates: a frame that fills 2,048 bytes leaves
  `pay_cnt = 2048 = 11'h000`, so the reclaim added zero and `room` stayed 0 until
  reset. Full-width reclaim; test = oversize from empty followed by a valid frame.
- **[P2] Correctly PADDED short length frames were rejected** — the receiver
  jumped from the declared length to the FCS, folding pad bytes as if they were
  the FCS. New `S_PAD` consumes `46 - field` pad bytes (folded, not stored).
- **[P2] The emulator ticked BEFORE executing**, so a wrap-cycle read returned
  the new counter and could clear a flag the RTL preserves (set-beats-clear). It
  now executes then ticks; the stopped path still ticks and now keeps
  `imem_rdata = imem[0]`, so stop→run cannot skip instruction 0. Directed RTL
  cases in `tb_pe_soc_tick` and a new `emulate: timer wrap semantics` case.
- **[P2] The diagram gate depended on ignored render files.** A clean clone had
  no generated images to compare. The current reference is a checked RTL
  inventory, and the project diagrams are editable PlantUML source files.
- **[P2] The lint gate omitted `pe_eth_mac` and `pe_fbuf`.** Direct `verilator
  -Wall` on the MAC produced five findings, two of them 12 dead `dst`/`src`
  registers; joining the file list surfaced a `TIMESCALEMOD` too. Fixed in RTL
  (7-bit shift registers, dead registers removed, sized subtraction, timescale
  removed), not suppressed. **The gate also ignored yosys `ERROR:`** — it listed
  three expected diagnostics, so the DDR draft's struct-returning function that
  yosys 0.68 cannot parse sailed through as "elaborate OK". Now any `ERROR` fails.
- **[P2] `peasm.py --rtl-init` silently truncated to 128 words and emitted
  invalid Verilog** (`initial $readmemh_unused;` plus a bare list). It now emits a
  valid one-word-per-line `initial` block at the real 1,024-word depth and errors
  on truncation.
- **Files:** `rtl/pe_dru.v`, `rtl/pe_eth_mac.v`, `rtl/pe_fbuf.v`, `tb/tb_pe_dru.v`,
  `tb/tb_pe_eth_mac.v`, `tb/tb_pe_soc_tick.v`, `regress/mutate_eth_mac_tb.sh`,
  `regress/mutate_fbuf_tb.sh`, `regress/lint.sh`, `regress/run_all.sh`,
  `regress/run_firmware_tests.sh`, `tools/fw/peasm.py`, `tools/fw/peemu.py`,
  `info.yaml`, `flow/pe_soc.json`, `.gitignore`, `reviews/2026-09-22/`.
- **Regression:** RTL 26/26, firmware **17/17**, 13 lint tops + 11 elaborations
  clean (14 verilator tops + 11 yosys elaborations), all four mutation suites
  green, generated-doc drift checks green, and
  `regress/run_all.sh --fast` exits 0 in a `git archive` clone with no ignored files.


## [2026-09-22] review | second pass: seven open findings after the first fixes

- Reviewed `628e309` (`review/fix-invisible-defects`) with the first review used
  as a regression checklist. The fresh isolated regression reports 26/26 RTL,
  17/17 firmware, lint/elaboration, documentation gates, and four mutation suites
  green. Independent directed probes reproduce seven additional defects.
- **P1:** DDR latch/flop simulation race rejects asynchronous Ethernet traffic;
  34/102 phase/frequency/filter trials fail. A temporary nonblocking latch
  assignment removes the sample mismatch and passes the directed frame.
- **P1:** a valid-CRC fourteen-byte runt is accepted with length 65,532 and makes
  free space exceed the buffer's capacity; the next valid frame inherits the
  corrupted accounting.
- **P2:** USB mode stuffs zero runs; one-clock CPU stop/restart skips instruction
  zero; SRAM fallback reads differ from the macros during writes; the emulator
  UART monitor samples too early; interrupted I2C/SPI/fbuf mutation suites leave
  modified source files behind.
- Full findings, locations, correction criteria, and commands:
  `reviews/2026-09-22/REVIEW-2.md`. Reproducers and logs are in its `review2/`
  directory. The saved runner returns nonzero with seven failed probes at this
  revision; the temporary DRU experiment passes separately.
- Updated `HANDOFF.md` and `wiki/STATUS.md` for the context flush. All seven
  findings remain open. Production RTL, firmware, and tooling were unchanged.
  No physical flow, DRC, or LVS was run.

## [2026-09-22] review | second-pass findings fixed: DDR capture, frame structure, USB, restart, fallbacks, monitor, traps

- **All seven findings in `REVIEW-2.md` are fixed, each with a permanent test,**
  and the review's own probe suite now exits 0. The resolution table is appended
  to `REVIEW-2.md`.
- **R2-1 (P1):** the falling-edge capture is a two-latch pair now -- the
  transparent-high master closes at the falling edge and a transparent-low slave
  holds through the high phase, so the receiving flop samples a closed latch and
  cannot race the master reopening. `tb_pe_eth_mac` frame 11 drives a real frame
  with fixed 49.995 ns half-cells, independent of the DUT clock; the review
  sweep is **102 trials / 0 failures** (it was 34/102).
- **R2-2 (P1):** `S_SETTLE` requires frame STRUCTURE as well as the CRC residue
  (`hdr_done`, `fcs_done` for length frames, `pay_cnt >= 4` for type frames).
  The review's 14-byte runt had a valid residue and no payload: it was accepted
  with length 65,532 and wound the pointer back 4 bytes that were never stored.
  Now rejected with `room` and `pointer` untouched; TB frame 10, mutation
  `crc-only-verdict` (11/11 detected).
- **R2-3 (P2):** `pe_bitstuff` takes an explicit `ones_only` rule (`cfg[7]`;
  run length `cfg[6:4]`). USB stuffs only after six ONES, so the USB config byte
  is `0xE3`; CAN stays symmetric. Counters saturate on non-stuffable runs.
  Directed TX/RX zero-run tests in `tb_pe_line_codec` and `tb_pe_codec_mux`.
- **R2-4 (P2):** while `run` is low the fetch address is ZERO, not `pc`, so the
  registered ROM has `imem[0]` ready after the first stopped edge. A one-clock
  stop now resumes at instruction 0 (`tb_pe_cpu` test 10).
- **R2-5 (P2):** both FLOP fallbacks gate their registered read on `!we`
  (`pe_fbuf` holds word AND lane; `pe_imem` holds `imem_rdata`), matching the
  macro's deasserted REN. Directed changing-address-across-write checks in both
  TBs.
- **R2-6 (P2):** the emulator's UART monitor samples the CENTRE of each bit
  (1.5 bit periods after the start edge), so an 8N1 A5 at 519/520/521 clocks per
  bit decodes correctly; `emulate: UART monitor periods` is in the firmware
  regression (now 18/18).
- **R2-7 (P2):** the mutation harnesses restore pristine sources and the
  committed firmware image on EXIT/INT/TERM and exit immediately on a signal.
  `review2/mutation_interrupt.py` reports `changed=[]` for all three.
- **Files:** `rtl/pe_dru.v`, `rtl/pe_eth_mac.v`, `rtl/pe_nrzi.v`, `rtl/pe_manch.v`, `rtl/pe_bitstuff.v`,
  `rtl/pe_codec_mux.v`, `rtl/pe_cpu.v`, `rtl/pe_imem.v`, `rtl/pe_fbuf.v`,
  `tools/fw/peemu.py`, `tb/tb_pe_eth_mac.v`, `tb/tb_pe_line_codec.v`,
  `tb/tb_pe_codec_mux.v`, `tb/tb_pe_cpu.v`, `tb/tb_pe_imem.v`, `tb/tb_pe_fbuf.v`,
  `regress/run_firmware_tests.sh`, the four `regress/mutate_*_tb.sh`,
  `wiki/reference/signal-names.md`, `reviews/2026-09-22/REVIEW-2.md`,
  `HANDOFF.md`.
- **Regression:** RTL 26/26, firmware **18/18**, lint 14 tops + 11 elaborations,
  all four mutation suites green, generated-doc drift green, and the review
  probe suite exits 0.


## [2026-09-23] review | verify second-review fixes at bdd7728

- Fresh isolated regression: exit 0, 26/26 RTL, 18/18 firmware, lint and all
  supporting gates green. Original review probes plus the asynchronous Ethernet
  sweep: exit 0, seven probes pass, 102/102 sweep trials pass.
- The original P1 MAC underflow is fixed. **F1 (P2) remains:** CRC-valid type
  frames below 64 bytes or ending in partial bytes are still accepted. A valid
  64-byte control passes; nine independent rejection assertions fail.
- **F2 (P2) remains:** the codec glossary generator and generated reference
  still describe cfg[7:4] as run length. RTL uses cfg[7] for ones_only and
  cfg[6:4] for run length; the USB configuration is now 0xE3.
- Independent USB/CAN model: 524 streams, 4,822 cells, zero errors. Additional
  UART checks cover valid/invalid stop bits and consecutive frames at nearby
  periods. R2-7's three harnesses restore source bytes under tested interruptions.
- Report and persistent evidence: `reviews/2026-09-23/FIX-VERIFICATION.md`.
  Added `run-boundaries.sh` and its failing fixture, saved fresh output as `.txt`,
  and rescued earlier review logs from the global `*.log` ignore rule by copying
  them to `.txt` and updating the report links.
- Updated HANDOFF/STATUS for the two remaining follow-ups. Production RTL,
  firmware, harnesses, and generators were unchanged. No physical flow, DRC,
  or LVS ran.

## [2026-09-23] build | fix verification follow-ups F1 and F2

- **F1 (Ethernet structure):** the verdict now requires a complete-byte ending
  (`bit_cnt == 0`) and, for type frames, the 64-byte 802.3 minimum (46 data/pad
  + the 4 stored FCS). The valid 64-byte control passes; the 18-byte and
  63-byte valid-residue runts and the 1–7 extra-bit partial frames are rejected
  with room 2048 and pointer 0. The committed ARP acceptance test is now a
  conformant padded 64-byte frame (frame 2), and frames 12–15 hold the
  boundary cases. New mutations `no-type-min-size` and `no-byte-align`; 13
  detected, 0 survived. `reviews/2026-09-23/run-boundaries.sh` exits 0.
- **F2 (codec config reference):** `tools/gen/signal_glossary.py` now documents
  `cfg[6:4]` as run length, `cfg[7]` as `ones_only`, the USB byte `0xE3`, and
  the `ones_only` port; `wiki/reference/signal-names.md` regenerated.
- **Files:** `rtl/pe_eth_mac.v`, `tb/tb_pe_eth_mac.v`,
  `regress/mutate_eth_mac_tb.sh`, `tools/gen/signal_glossary.py`,
  `wiki/reference/signal-names.md`, `reviews/2026-09-23/`.
- **Regression:** RTL 26/26, firmware 18/18, lint clean (14 tops + 11
  elaborations), all four mutation suites green with the eth harness at 13/13,
  the boundary runner exits 0, and the second-review probe suite exits 0.


## [2026-09-23] review | recheck F1/F2 fixes at 655c5b7

- F1 passes the valid 64-byte control and all nine malformed-frame rejection
  assertions. Independent scoped review found no issue in the verdict change.
- F2 correctly documents the USB bit layout and 0xE3 preset. **F3 (P2):** its
  new CAN example is 0x05, enabling Manchester. A directed raw-one test produces
  TX=0/RX=0/error=1; 0x01 and 0x51 both produce TX=1/RX=1/error=0.
- Fresh isolated regression exits 0: 26/26 RTL, 18/18 firmware, lint and all
  supporting gates pass. Original seven probes and the 102-trial Ethernet sweep
  also exit 0. Report and evidence: `reviews/2026-09-23/F1-F2-RECHECK.md`.
- Updated handoff/status for the one remaining documentation finding. Only review
  records, evidence, and the CAN reproducer changed; implementation files were
  untouched. No physical flow, DRC, or LVS ran.


## [2026-09-23] build | F3 fixed: the CAN preset is 0x51, not 0x05

- The recheck's one remaining finding was documentation, not RTL: the F2 note
  added "CAN is `0x05`", and `0x05` sets `cfg[2]` (Manchester) as well as
  `cfg[0]` (stuffing). A directed raw-one test shows TX=0/RX=0/error=1 at
  `0x05`, and TX=1/RX=1/error=0 at `0x01` and `0x51`.
- `tools/gen/signal_glossary.py` now gives CAN as `0x51` (stuff + explicit run
  5), notes `0x01` as the default-run equivalent, and says plainly that `0x05`
  is not a CAN preset. `wiki/reference/signal-names.md` regenerated.
- `tb_pe_codec_mux` adds permanent TX and RX checks for the documented `0x51`
  preset, so the value the reference recommends is exercised, not just prose.
- **Files:** `tools/gen/signal_glossary.py`, `wiki/reference/signal-names.md`,
  `tb/tb_pe_codec_mux.v`, `reviews/2026-09-23/F1-F2-RECHECK.md`,
  `reviews/2026-09-23/FIX-VERIFICATION.md`, `HANDOFF.md`, `wiki/STATUS.md`.
- **Regression:** RTL 26/26, firmware 18/18, lint clean, four mutation suites
  green, F1 boundary runner and the second-review probe suite exit 0.


## [2026-09-23] reorg | one module per file, harnesses out of tb/, tools by function

- **Functional no-op layout rework.** No RTL logic, firmware byte or check
  changed; the full regression, the three review probe suites and a fresh
  `git archive` clone all pass on the new layout, and the firmware hex outputs
  are byte-identical.
- **RTL:** `pe_uart_soc.v` → `pe_soc.v` (the module never had UART hardware —
  the name was the milestone it was born in); `pe_line_codec.v` split into one
  module per file, `pe_nrzi.v` / `pe_manch.v` / `pe_bitstuff.v` (module bodies
  byte-identical, shared header redistributed); the IHP SRAM port shell moved to
  `rtl/vendor/`, so `rtl/*.v` is now the design's own RTL.
- **Tests:** `tb/` holds testbenches only; the eleven harnesses (`run_all`,
  `run_one_tb`, `run_firmware_tests`, `lint`, `synth_area`, `param_guards`,
  `sram_model`, four `mutate_*`) moved to `regress/`.
- **Tools:** `tools/fw/peasm.py` + `peemu.py`; `tools/gen/` for the seven
  generators (prefixes dropped inside the directory); `tools/checks/` for
  repository and I2C-timing checks.
- **Flow/metadata:** `flow/pe_soc.json` / `pe_soc.sdc` / `pe_soc_pdn.tcl`,
  `DESIGN_NAME: pe_soc`; the LibreLane stager resolves staged sources under
  `rtl/` recursively so `rtl/vendor/` works. `info.yaml` lists the new paths.
- **Docs:** all generated pages regenerated (block diagram, clock arithmetic,
  CRC config, pin budget, signal glossary, SRAM budget), the block-diagram
  stamps/SVGs re-rendered, and current-guidance pages updated. The historical
  review reports keep their text and now carry a layout note; their probe
  scripts were path-updated and still run.
- **Regression:** RTL 26/26, firmware 18/18, lint clean (14 tops + 11
  elaborations), four mutation suites green, doc drift green, review probes and
  boundary checks exit 0.

## [2026-09-23] review | verify the layout refactor at 6de2a6a

- Reviewed `6de2a6a` against its parent `2cc0f03`. **No new functional defect
  found.** All 15 RTL and 26 TB module token streams match after the intended
  renames; file-level directives/attributes, executable assembler/emulator
  ASTs, and all four firmware images are preserved.
- Fresh `git archive` regression: **26/26 RTL, 18/18 firmware**, 14 Verilator
  tops, 11 Yosys elaborations, all four mutation suites, generated-doc gates,
  and I2C timing pass. All seven previous probes pass; Ethernet
  sweep **102 trials / 0 failures**; F1 boundary runner exits 0. Prior F1/F2/F3
  fixes remain covered by the regression and directed checks.
- All seven relocated generators and both checkers also pass from `/tmp`.
  The six submission sources compile; the actual Python staging block from
  `flow/run_librelane.sh` stages both configs, including the renamed SDC/PDN
  files and vendor macro collateral, and both staged designs compile. This
  exercises file copying and Verilog compilation only; **no physical flow,
  DRC, or LVS** was run.
- Added `reviews/2026-09-23/REFACTOR-REVIEW.md`, five evidence transcripts and
  two replay scripts in `reviews/2026-09-23/refactor/`. Updated `HANDOFF.md`
  and `wiki/STATUS.md` with the review result, fresh revision and resume path;
  corrected the stale branch note (`main` at `6de2a6a`, review branch at
  `2cc0f03`). No production source changes were needed.

## [2026-09-23] correct | README signoff target is 60 MHz

- The user caught stale README prose after the refactor review: it still
  claimed a 66 MHz signoff target. Both flow configs already use **16.667 ns
  (60 MHz)**, matching the locked RTL clock and ADR-005's amendment.
- Corrected the README target and flow instructions, identified the old SERDES
  measurements as historical, and synchronized matching metadata comments,
  clock notes, status and handoff guidance. Added the missed documentation
  issue and its correction to `reviews/2026-09-23/REFACTOR-REVIEW.md`.
- Checked both JSON clock periods, RTL/metadata clock values and SoC setup/hold
  uncertainty against the documentation. `tools/gen/clock_arithmetic.py --check`
  and `git diff --check` pass. Documentation/comments only; no physical flow,
  DRC or LVS run.

## [2026-09-23] correct | README uses the programmable protocol SoC name

- Replaced the pre-refactor "Software-UART SoC" label with "Programmable
  protocol SoC" after user feedback. The status now describes UART, SPI mode 0
  and I2C pin-level firmware, and points to STATUS for the live work list.
- Corrected nearby claims that the pin matrix and frame buffer were unbuilt.
  Added the missed documentation issue to the refactor review. Checked the
  README's implementation references and `git diff --check`; no RTL changes
  were made for this correction.

## [2026-09-23] integration | the 10BASE-T receive chain is in the SoC

- **`pe_eth_mac` is no longer an orphan.** `pe_soc` instantiates `pe_dru` ->
  `pe_manch` -> `pe_eth_mac` with `pe_crc` and `pe_fbuf`; the RX pin is port
  bit 7 (the TT wrapper maps `ui_in[2]` to it); the last two unwired blocks are
  `pe_serdes` and `pe_codec_mux`.
- **The frame window is firmware-visible on IO `0x8-0xE`:** `ETHSTAT`
  ({is_type,bad,valid}, clear-on-read, set beats clear), `ETHLEN`/`ETHLENH`,
  `ETHFLD`/`ETHFLDH`, `BUFBYTE` (a read advances the window through
  `pe_fbuf`'s registered read port) and `BUFCTRL` (bit0 pulses the MAC's
  `buf_reset`). `firmware/eth_rx.pe` (42 words) polls the window, records the
  header in dmem, sums every payload byte, counts rejected frames and reclaims
  the ring.
- **SoC-level proof:** `tb/tb_pe_soc_eth.v` drives a real 56-bit preamble + SFD
  and two 64-byte ARP frames (plus one bad-FCS frame) as raw Manchester levels
  on the pin, and checks what the firmware leaves in dmem: len 46, EtherType
  0x0806, a checksum over every walked byte, and the rejected-frame count.
  `regress/mutate_eth_soc_tb.sh` breaks the window seven ways; 7 detected,
  0 survived.
- **Traps found and fixed:** the firmware must initialise its dmem counters
  (x survives ADD); the TB must delay `run` release by `#1` or the CPU's PC flop
  and the imem fetch flop resolve that edge differently and skip the program's
  first STM; every `pe_soc`-elaborating case and the i2c/spi mutation harnesses
  needed the chain's source list; empty output connections are Verilator
  PINCONNECTEMPTY under the no-waiver lint gate.
- **Regression:** RTL 27/27, firmware 19/19, lint clean (14 tops / 11
  elaborations), five mutation suites green, generated-doc gates green.
- **Files:** `rtl/pe_soc.v`, `rtl/tt_um_protocol_emulator.v`,
  `firmware/eth_rx.pe`, `tb/tb_pe_soc_eth.v`,
  `regress/mutate_eth_soc_tb.sh`, `regress/run_all.sh`,
  `regress/run_firmware_tests.sh`, `regress/synth_area.sh`,
  `regress/mutate_{i2c,spi}_tb.sh`, `tools/fw/peasm.py`,
  `tools/gen/block_diagram.py`, `flow/pe_soc.json`, `info.yaml`,
  `wiki/plans/ethernet-soc.md`, `wiki/STATUS.md`,
  `wiki/concepts/ethernet-receive-path.md`, `HANDOFF.md`.

## [2026-09-23] decision | pe_ctrl is a passive SPI slave (ADR-007)

- The user ruled the loader's role: **passive SPI slave**, not an SPI master.
  Recorded as [[decisions/adr-007-pe-ctrl-passive-slave]]; resolves the open
  question left at the end of ADR-006.
- Decisive argument: there is no ROM and instruction memory is volatile SRAM,
  so a master would need a hardwired bootstrap FSM plus a board flash — while
  every environment this chip runs in has a host. The slave is host-clocked
  hardware at the TT wrapper boundary, driving the SoC's existing `host_*`
  port.
- v1 interface recorded: SPI mode 0, MSB-first, 16-bit words; `CS_N` low resets
  and enables; one word per 16 rising SCLK edges into `imem[addr++]`; accepted
  only while `run=0`; pads `ui_in[3:5]`; `run` stays `ui_in[1]`; imem only.
- Next: the `pe_ctrl` implementation plan (`wiki/plans/pe-ctrl.md`).

## [2026-09-23] review | Ethernet reclaim race and periodic hardening checks

- The user requested 15-minute checks of Pi in tmux pane `%46` and independent
  reviews. The first check found Pi working on the SPI loader plan.
- New **E1 (P1), open** at `9a84c6e`: two accepted 200-byte frames with a
  96-cell gap yield a corrupt second firmware checksum (`xx`); a 600-cell gap
  and 46-byte payload controls pass. Ring reclaim resets the write pointer
  while the next frame is already in its payload. Sent the finding and
  reproducer to Pi; recorded it in `ETHERNET-SOC-REVIEW.md` and the handoff.
- Fresh isolated regression: 27/27 RTL, 19/19 firmware, all five mutation
  suites and the lint/doc gates pass. The permanent test misses this schedule.
- User clarified that periodic synthesis and STA are allowed to detect RTL
  that cannot be hardened. Native mapped synthesis and three-corner OpenSTA
  were run in isolation: mapped logic/SRAM timing coverage present, setup
  nonnegative under screening assumptions, hold/electrical violations remain
  before physical repair. Full evidence and limits are in the new report.
  No physical flow, DRC or LVS ran.

## [2026-09-23] fix | E1: consumer-owned ring reclaim

- **E1 resolved.** `pe_eth_mac` gained a consumer read pointer (`rptr`) and
  `buf_consume`/`buf_consume_addr`; `buf_reset` is retained but demoted to a
  whole-ring testbench/debug control and wired to `1'b0` in `pe_soc`. BUFCTRL
  now releases the bytes firmware has walked (the BUFBYTE window position) by
  advancing `rptr`, never by touching `wptr` — so a reclaim that lands during
  the next frame's `S_PAYLOAD` cannot rebase it. A consume is accepted only as
  a forward step within the allocated bytes; duplicates are no-ops and backward
  addresses are ignored.
- **Permanent regression:** `tb/tb_pe_soc_eth.v` drives two 200-byte frames
  with a 96-cell gap and does not wait for consumption; it failed before the
  fix (`sum=xx want=bc`) and passes now. `tb_pe_eth_mac.v` checks the block
  contract: consume moves only `rptr`, duplicates free nothing, backward
  addresses are ignored, and a mid-payload consume leaves the frame intact.
- **Mutation gates:** eth_mac 16/16, eth_soc 8/8, including
  `consume-rebases-wptr`, `consume-ignored`, `consume-no-guard` and
  `destructive-reclaim` (the E1 wiring).
- **The review's reproducer** passes all three cases (200-byte/96-gap,
  200-byte/600-gap, 46-byte/96-gap); the fixed trace keeps `wptr=212` while
  frame B is in `S_PAYLOAD`.
- **Full regression:** RTL 27/27, firmware 19/19, lint clean, five mutation
  suites and all doc gates green. **Hardening recheck:** yosys 0 problems;
  worst hold slack unchanged (slow −0.87 / typ −0.61 / fast −0.48) with the
  same pre-repair electrical failures; ownership logic costs ~2.9k µm².
- **Files:** `rtl/pe_eth_mac.v`, `rtl/pe_soc.v`, `firmware/eth_rx.pe`,
  `tb/tb_pe_eth_mac.v`, `tb/tb_pe_soc_eth.v`,
  `regress/mutate_eth_{mac,soc}_tb.sh`, `wiki/reference/signal-names.md`,
  `reviews/2026-09-23/E1-RESOLUTION.md`, `reviews/2026-09-23/e1-recheck/`.

## [2026-09-23] fix | E2: both SRAM macros placed and power-hooked, with a gate

- **E2 resolved at the config level.** The SoC instantiates two SRAM macros
  (`u_imem` and `u_eth_fbuf`), but `flow/pe_soc.json` listed only the
  instruction one: no placement for the frame buffer, and no
  `PDN_MACRO_CONNECTIONS` for its `VDD!`/`VSS!`/`VDDARRAY!` Metal4 supplies
  (the standard-cell `VPWR`/`VGND` defaults do not cover them). LibreLane would
  have left the frame-buffer macro unplaced and unpowered; simulation could not
  see it.
- **Fix:** both instances are now placed (`(10,10)` and `(256.8,10)`, `N`, a
  10 um gap, both inside the 1002x432 die), and all four supply hooks are
  present (VDD!/VSS! and VDDARRAY!/VSS! per instance). The `-macro -default`
  PDN grid and its Metal4 ladder apply per instance.
- **New permanent gate:** `tools/checks/macro_flow_config.py`, run by
  `run_all.sh`. It flattens the elaborated `pe_soc`, requires every macro cell
  and only macro cells to be configured, requires all three supply pins per
  instance, checks placement inside the die with a 10 um gap (exits 2/incomplete if
  the PDK LEF or its geometry is unavailable), and requires `PDN_CFG` to build the Metal4
  ladder. It fails on the pre-fix config and passes on the fixed one.
- **Deferred:** the full flow run must confirm both macros place, PSM-0040
  connectivity, no PDN-0189/PSM-0069, spacing and the host-path hold/screen
  findings. No physical flow, DRC or LVS ran.
- **Files:** `flow/pe_soc.json`, `tools/checks/macro_flow_config.py`,
  `regress/run_all.sh`, `reviews/2026-09-23/E2-RESOLUTION.md`.

## [2026-09-23] review recheck | Ethernet SoC fixes and macro gate

- Re-ran `tools/checks/macro_flow_config.py` on the current tree: both flattened
  SRAM macro instances, placement geometry, die bounds, gap, three supplies
  per macro, and the Metal4 PDN config pass with the installed PDK LEF.
- Independent temporary-copy mutations all fail the gate as intended:
  missing frame-buffer placement, missing `VDDARRAY!`, overlapping locations,
  out-of-die location, and missing `PDN_CFG`; restored baseline passes.
- Review found one gate contract hole: a missing/malformed vendor LEF printed
  “SKIPPED” but still returned success although legal placement could not be
  established. The checker now returns 2 (incomplete) in that case. Verified
  the normal gate still passes and the forced-missing-LEF probe returns 2.
- E1 is independently reproduced against `c9f8e1a`; the isolated full
  regression passes 27/27 RTL and 19/19 firmware. E1 and E2 are recorded as
  resolved at the RTL and static-config levels. Two-macro physical flow, DRC,
  and LVS remain deferred; no physical signoff is claimed.

## [2026-09-23] review | pe_ctrl run-transition write race

- Independent review of the in-progress SPI loader found that `run` is checked
  when the write pipeline starts, but the `W_PULSE` state raises `host_we`
  without a run check. Raising `run` after a complete word queues and before
  the pulse is sampled produced `writes=1 writes_while_run=1 error=0` in an
  isolated Icarus test. This is distinct from the existing test that begins a
  transaction with `run=1`.
- The finding and required regression are recorded in
  `reviews/2026-09-23/PE-CTRL-REVIEW.md` and `HANDOFF.md`. Pi was active in the
  full regression at the 15:13 UTC pane check; no nudge was sent at that time.
- The first full run had 28/28 RTL and 19/19 firmware tests passing but exposed
  unused `shreg[15]` in the lint gate. A 15-bit shift-register correction
  removed the warning; the repeat run at `39c0eb4` passed 28/28 RTL and 19/19
  firmware tests, clean lint/elaboration, generated-doc checks and all five
  mutation gates. Pi has received the open race finding and is reviewing it.
- Independently mapped `pe_ctrl` (Yosys: 0 problems, ~5,649.8 µm²) and
  screened it with OpenSTA at 60 MHz: setup passes under the stated assumptions;
  `run` has −0.158 ns hold slack under a zero-min input assumption, and
  unplaced high-fanout nets exceed limits. Async SPI synchronizer inputs are
  intentionally false-pathed. See `reviews/2026-09-23/pe-ctrl-hardening/`.

## [2026-09-23] fix | pe_ctrl aborts a queued word when run rises

- `ef4041d` fixes the independent P1: `host_we` is masked by `run`; W_IDLE,
  W_PULSE and W_DONE discard/flag a pending word when execution starts so it
  cannot write during run or reappear after run falls.
- The permanent `tb_pe_ctrl` test exercises the W_PULSE transition, verifies no
  host write/count, expects `load_error`, then checks no stale write after run
  falls. I independently verified it passes on the fix and fails against
  `39c0eb4` with six assertions; standalone lint is clean. Mutation harness and
  full post-fix regression are in progress.
- Fresh mapped Yosys/OpenSTA recheck on `ef4041d`: 0 synthesis problems,
  ~5,791.1 µm² area, +8.71 ns worst setup slack across three corners. Hold
  remains −0.19/−0.16/−0.12 ns (fast/typical/slow) on the direct `run` input
  under a zero-min-delay screen assumption; pre-layout
  high-fanout violations remain. No physical flow, DRC or LVS ran.

## [2026-09-23] finalize | pe_ctrl mutation guard and full post-fix regression

- `regress/mutate_ctrl_tb.sh` added: 11 mutations, **11 detected, 0 survived**.
  Beyond the eight protocol mutations it guards the three run-transition
  windows (`idle-abort`, `host-we-mask`, `done-run-check`); the W_PULSE abort
  itself is documented as defence-in-depth with no independently observable
  mutation. The `run-gate` mutation exposed one missing assertion (an attempted
  load while running must be *ignored*, not flagged); case 5 now checks it.
- Full post-fix `./regress/run_all.sh --fast -j8`: **RTL 28/28, firmware
  19/19**, lint clean (15 Verilator tops / 12 Yosys elaborations), **six**
  mutation suites green (i2c, spi, fbuf, eth_mac, eth_soc, ctrl), the new
  macro-flow gate and every generated-doc gate green.
- The loader is therefore complete at the plan's Task 1+2 boundary:
  `PE-CTRL-RESOLUTION.md` records the semantics and evidence.

## [2026-09-23] review correction | 7b must hold CS_N low

- The independent review found that case 7b raised `CS_N` before its stale-write
  check; the CS rising edge clears `word_ready`, so the case proved only the
  `load_error` flag, not that a deferred word never writes. Against pre-fix
  `39c0eb4` it reported 7b as a flag-only failure.
- Corrected: `CS_N` stays low; `run` falls; 16 clocks (a 3-cycle write pipeline)
  elapse; `cap_n == 0` is asserted; only then is `CS_N` raised. Pre-fix RTL and
  the `idle-abort` mutant now both fail on `7b: queued word written after run
  fell (CS still low)`.
- `mutate_ctrl_tb.sh` remains 11 detected / 0 survived against the corrected
  TB. `PE-CTRL-RESOLUTION.md` carries the corrected claim.

## [2026-09-23] i2c | the transaction layer runs in the emulator

- `firmware/i2c_xfer.pe` (267 words): START, 0xA0, ACK, 0xA5, ACK, repeated
  START, 0xA1, ACK, read 0x5A, NACK, STOP — written as a state dispatcher over
  one shared send engine and one shared read engine, because the ISA has no
  call and no rotate (left shift is `MOV X,A; ADD A,X`). All 60 tick phases
  decode identically and clear the standard-mode floors: tLOW 6.00 us,
  tHIGH 5.98 us, period 11.98 us, 52.5–83.5 kHz.
- `tools/fw/peemu.py` gains `I2CSlaveModel`: a byte-level open-drain slave that
  decodes the wire independently (START/STOP, bits on SCL rises, ACK on the
  9th clock) and holds SDA for tHD;DAT after each falling edge. The checker
  caught two model bugs: the post-START SCL fall was counted as a data bit
  (addresses decoded 0x50), and pull changes landed on the falling edge
  (grammar violations).
- `tools/checks/i2c_xfer_check.py` asserts the slave's decode, the firmware's
  dmem observables, the timing floors and the grammar across all 60 phases.
  Registered in `run_all.sh`; the assemble step is in `run_firmware_tests.sh`
  (now 20/20).
- Two firmware traps fixed on the way: releasing SCL must HOLD SDA (`SDA|SCL`
  released a driven 0 together with the clock), and the repeated START must
  wait tLOW before raising SCL (the ACK clock's low phase measured 0.37 us).
- Next: the RTL TB with its own Verilog slave model, then docs + screen.

## [2026-09-23] i2c | the transaction layer on real RTL

- `tb/tb_pe_soc_i2c_xfer.v` runs `firmware/i2c_xfer.pe` against a Verilog I2C
  slave FSM that decodes the wire (START/STOP, bits on SCL rises, ACK on the
  9th clock, a tHD;DAT hold after every fall) and asserts the slave's records,
  the firmware's dmem observables, the bus grammar and the standard-mode floors
  measured on the pads: tLOW 6.00 us, tHIGH 5.98 us. A second run pulls SDA low
  through a transmitted 1 so the arbitration branch is exercised (dmem[7] > 0).
- `regress/mutate_i2c_xfer_tb.sh`: 7 firmware mutations (bit order, repeated
  START, tLOW, STOP, arbitration, the hold, the read accumulator), **7 detected,
  0 survived**; it restores and cmp-verifies BOTH the `.pe` and the `.hex`.
- Registry: the TB case in `run_all.sh`, the transaction checker as a spec gate,
  the assemble step in `run_firmware_tests.sh`. Full regression: **RTL 29/29,
  firmware 20/20**, lint clean, **seven** mutation suites, all doc gates.
- The TB found its own trap: releasing `run` immediately after the loader left
  the SRAM macro with no read at word 0, so the CPU executed an X instruction
  and skipped `LDI A,0x30`; the OD register stayed 0 and every ACK read back as
  a NACK. The TB now waits four clocks before `run`, as the UART SoC TBs do.
- No RTL changed in this milestone (firmware, TBs, emulator and docs only), so
  the recorded synthesis/STA screens remain the current ones.

## [2026-09-23] decision | item 4: the debug PC keeps its six pads

- STATUS item 4 is decided: `uo_out[7:2]` stay `dbg_pc[5:0]`. The pad budget is
  not the constraint (after UART, the loader and I2C, 14 pads are free — enough
  for the remaining protocol wires even with all nine running at once);
  `pe_ctrl` has no readback, so the visible PC is the only live observability on
  silicon; and reclaiming has no consumer yet (the free `uio` bank already gives
  the matrix six runtime-direction pads).
- Revisit trigger recorded in the wrapper header and STATUS: reclaim when a
  protocol needs the pads and the free `ui_in`/`uio` pins are exhausted, when a
  `pe_ctrl` readback path lands, or at submission pinout freeze. Separately:
  SPI firmware's MOSI/CS have no pads today; the free `uio` bank is the natural
  home for them (bidir, per-pin OE).
- The independent I2C review's open limits are kept visible in STATUS item 3 and
  the concept page: arbitration loss is counted but the transfer continues;
  unexpected NACKs are recorded without recovery or negative-path tests; the
  transaction loop does not wait on a stretched SCL.
- No RTL logic changed (a wrapper comment only), so the recorded synthesis/STA
  screens remain current.

## [2026-09-23] planning | item 5: floorplan feasibility, read-only

- STATUS item 5 is documented in the generated
  [[reference/floorplan-feasibility]]: two `1P_1024x16` macros (236.8×336.46 µm
  each, 159,347 µm² total) plus `tt_um_top`'s 59,548 µm² of logic (3,613 cells)
  fit the template 6×4 die at ~60% occupancy (36% at the blog tile; 45% on the
  8×4 upside). **Area is not the risk.**
- The finding that matters: the existing signoff is a PADLESS core (`DIE_AREA`
  only, no `CORE_AREA`), while the TT deliverable's pad ring shrinks the usable
  core. The recorded macro placements are proven against the die, not a padded
  floorplan; macro `y=10` may sit under the ring.
- Assumption differences tabulated: blog tile 200×150 vs template 167×108 µm
  (+66% area), die 1200×600 vs 1002×432, and the blog's ~24k-cell logic figure
  against the template's own ~8k; this design's 3,613 cells clears both, so the
  tile size decides the macro rectangle, not the budget.
- Evidence deferred and listed there: a TT-top flow config, `CORE_AREA`
  placement with the ring, both macros' PDN connectivity, congestion and
  detailed-route DRC, a routed utilisation report, macro-alone DRC provenance,
  a confirmed tile size, and the full-chip hold/high-fanout items.
- `tools/gen/floorplan_feasibility.py` generates the page from the LEF,
  `flow/pe_soc.json` and `wiki/reference/.floorplan-areas` (measured mapped
  areas), drift-gated in `run_all.sh`. No LibreLane/OpenROAD, DRC or LVS was
  launched.

## [2026-09-23] i2c | the review-focus gaps: abort, NACK, stretch

- Arbitration loss now **releases and aborts**: outcome `dmem[6]=1`, both lines
  released immediately, **no STOP** (the winner owns the bus), park with
  `dmem[5]=0x55`. There is no STOP-qualified bus-free wait and no retry: a
  single both-high sample cannot prove idle, so the earlier idle check was
  removed. The RTL contention case asserts no master STOP and that no
  complete address/data byte was recorded; its stimulus is transient contention
  and the testbench says so. The emulator checker adds a transient-contention
  arbitration case across all 60 phases.
- Unexpected NACKs are defined and tested: a write-address/data/read-address
  NACK maps to outcome 2/3/4, issues a STOP and aborts. The emulator checker
  runs all three negative cases across all 60 phases; the RTL TB runs all three.
- SCL stretching is waited on: after every SCL release the firmware polls the
  pad until it reads high before timing tHIGH. Both slave models can hold SCL
  low; the checker and the TB run a stretched transaction (~10 µs held) and
  assert the floors still pass.
- `firmware/i2c_xfer.pe` is 311 words (was 267). The checker runs 5 cases × 60
  phases in ~9 s; `regress/mutate_i2c_xfer_tb.sh` is **11/11** with four new
  mutations (`arb-continues`, `nack-ignored`, `nack-no-stop`,
  `no-stretch-wait`).
- Same-day pin-budget correction: the all-nine analysis is direction-aware now
  — 22 protocol wires (10 out, 5 in, 7 bidir) do not fit; debug kept is short 9
  and debug reclaimed short 3 (the third input takes the last free `uio`). The
  wrapper header, STATUS and the generated page agree.

## [2026-09-23] spi | MOSI and CS_N exposed on the free uio bank

- `rtl/tt_um_protocol_emulator.v` maps port bit 1 -> `uio[2]` (MOSI) and bit 2
  -> `uio[3]` (CS_N), gated by the matrix's per-pin enable and push-pull. SCLK
  stays on `uo_out[0]` (shared with UART TX) and MISO on `ui_in[0]` (shared
  with UART RX); no SCLK mirror is added, and there is no input mux, so a
  dedicated MISO pad would need a new route plus a firmware pin-contract
  change -- documented in [[plans/spi-pads]]. `uio[7:4]` stay released.
- `info.yaml` labels the shared pad `uo[0]` as "UART TX / SPI SCLK (shared port
  bit 0)"; `tools/gen/pin_budget.py`'s `DESIGN_PINOUT` matches and still
  counts one physical pad. Budget: **18 of 24** committed, 6 free; short 9
  (debug kept) / 3 (reclaimed), direction mix recomputed by the generator.
- `tb/tb_tt_um_protocol_emulator.v` loads `firmware/spi_xfer.hex` through the
  loader pads and models a mode-0 slave on the pads (SCLK `uo_out[0]`, MOSI
  `uio_out[2]`/`uio_oe[2]`, CS_N `uio_out[3]`/`uio_oe[3]`, MISO `ui_in[0]`):
  8 frames, `0x5B` captured per frame, exactly 8 clocks each, and the rolling
  buffer `dut.u_soc.dmem[0..7]` == A7 E5 96 C1 3D 7B D2 4F. The unclaimed-pin
  monitors narrow to `uio[7:4]`; `uio[3:2]` must be driven during the run.
- Mutation evidence: four probes (MOSI source -> bit 0; `uio_oe[2]` low; CS_N
  source -> bit 1; `uio_oe[3]` low) each fail the pad-level phase; the wrapper
  was restored byte-identically after every probe.
- Regression: RTL 29/29, firmware 20/20, lint clean, every gate current, seven
  mutation suites OK (`/tmp/run_all_spi_pads.log`). `regress/synth_area.sh`:
  `tt_um_top` 3613 cells / 59,547.852 um2; HEAD-vs-current Yosys `stat` output
  is identical apart from the log path/hash -- **wire-only, zero gates, zero
  state**, so no sequential path is added. No wrapper-level SDC exists
  (`flow/pe_soc.sdc` is the pe_soc core), so there is no pad timing for OpenSTA
  to sign off; the recorded screens stay pe_ctrl/E1/E2. No physical flow, DRC
  or LVS was run.

## [2026-09-23] loader | pe_ctrl readback evaluation planned (choice open)

- ADR-007 left the loader write-only in v1; the read path it calls "a later
  additive change" now has an evaluation: [[plans/pe-ctrl-readback]]. MISO is a
  chip output, so it must be a `uio` pad (`uo_out` is full, `ui_in` cannot
  drive, the matrix SPI pads are chip-owned at reset); recommended `uio[4]`,
  driven only while `load_active`, released otherwise.
- Recommended minimal contract: mode-0 echo -- frame k shifts out the word
  completed at frame k-1, MSB-first on falling edges; frame 0 is zero. The host
  verifies the write path one frame late; the last word costs one trailing
  frame, which writes `0x0000` to `imem[N]` in the already-undefined tail.
- Open: echo vs a status frame (`load_error`/`words_written`) vs an imem
  peek/poke with a read mux (much larger; a command bit would break "16 rises
  = a write"); plus the last-word and release-condition policies.
- Budget if implemented: committed 18 -> 19, free `uio` 4 -> 3, all-nine
  shortfall 9 -> 10 (kept) / 3 -> 4 (reclaimed) -- the readback is loader
  overhead, not one of the nine protocols. No RTL changed, so no regression or
  synthesis/STA screen was warranted.

## [2026-09-23] loader | readback timing audit: commit latch and the SCLK ceiling

- Derived from `rtl/pe_ctrl.v` at the worst-case SCLK phase: the synchronizer
  and edge detector register the completed word at +3 clk; the imem write
  commits and `W_DONE` runs at +5..6 clk (83-100 ns at 60 MHz); a registered
  falling-edge MISO update appears at +3 clk after the fall. At 10 MHz the half
  period is 3 clk, so strict mode-0 readback cannot meet setup (even a
  combinational fall-gated update leaves only ~17 ns for pad + host setup).
- The echo must be commit-latched (never `word_ready`; an aborted word must not
  echo), so a one-frame echo is bounded by the commit: ~4 MHz computed,
  **2.5 MHz recommended** (A1); a two-frame echo fits **10 MHz** (A2, one more
  trailing frame). Load-only transactions keep the existing 10 MHz ceiling.
- Updated [[plans/pe-ctrl-readback]] with the derivation, the A1/A2 contract,
  the commit/abort/trailing-frame semantics, and the phase-sweep and
  commit-latch probes; [[reviews/2026-09-23/PE-CTRL-REVIEW]] with the audit
  evidence. No RTL changed; no new regression or STA was run.

## [2026-09-23] loader | readback audit correction: two ceilings, A2 is not 10 MHz

- The per-bit MISO path binds at every frame latency: synchronizer + fall
  detect + register is ~3 clk (50 ns), and the falling-to-next-rising half
  period at 10 MHz is also 3 clk, so A2's frame delay does not fix it.
- Computed limits: per-bit ~7.7 MHz (3 clk + ~5 ns pad + ~10 ns host setup);
  the commit path at one frame is 5.0 MHz (`T/2 >= 6 clk`). Combined: A1
  5.0 MHz (documented 2.5 MHz, 2x margin), A2 7.7 MHz (documented 5 MHz).
  Neither reaches 10 MHz. A3 (update on the synchronized *rising* edge, two
  frames, `T >= 3 clk + pad + setup`) is the safe 10 MHz variant, with a
  documented non-mode-0 change edge.
- The 2.5/5 MHz figures are deliberate margins, not computed limits.
  Corrected [[plans/pe-ctrl-readback]] and
  [[reviews/2026-09-23/PE-CTRL-REVIEW]]. Plan-only: no RTL changed, no
  regression or STA run.

## [2026-09-23] loader | readback audit arithmetic: A1 and A2 share the ~7.5 MHz limit

- The earlier A1 "T/2 >= 6 clk / computed 5.0 MHz" bound wrongly required the
  MISO response by the raw falling pad edge. The chosen architecture updates
  MISO after the synchronized fall detector, so the data is needed before the
  next rising sample, not before the fall.
- Exact worst-phase discrete bound: fall response at H + 3 clk; commit and
  `W_DONE` at +5..6 clk; next sample at 2H. The first echo bit needs the
  commit before the H+3 update (H >= 4 clk) and pad/setup before 2H -- the
  same ~7.5 MHz limit as the per-bit path (A2 ~7.7 MHz). At H = 4 clk the
  margin is ~1 clk for pad+setup, essentially zero.
- Corrected labeling: computed limits A1 ~7.5 MHz / A2 ~7.7 MHz; the
  documented 2.5 MHz (A1) and 5 MHz (A2) are chosen guard margins. A3 is
  unchanged (rising-edge update, two frames, 10 MHz with margin).
  [[plans/pe-ctrl-readback]] and [[reviews/2026-09-23/PE-CTRL-REVIEW]] updated.
  Plan-only: no RTL, no regression/STA.

## [2026-09-23] soc | serdes + codec integration plan (awaiting review)

- The last two orphan blocks are planned into `pe_soc`: TX
  `serdes.tx_ser -> codec.tx_bit -> codec.tx_wire` through a per-pin overlay
  mux ahead of the matrix's OE/OD; RX through the existing `pe_dru` capture
  (`rx_wire` for plain/NRZI/stuff, half-cells for Manchester); a programmable
  bit-strobe divider (bit cadence, doubled with `half_phase` for Manchester);
  and a 16-entry indexed window on the one free IO port (`0xF`, index write +
  auto-increment data accesses, no ISA change). Reset default: engine
  disabled, so every existing TB/firmware is bit-identical.
- Position recorded: the SoC gains a generic, config-driven word engine, not
  protocol-specific hardware -- protocol semantics stay firmware; the pe_soc
  header's "no protocol hardware" claim becomes "no protocol-specific
  hardware" in the same change.
- Evidence and gaps: unit TBs exist (`tb_pe_serdes`, `tb_pe_codec_mux`) but
  there is **no mutation suite for either block** -- the plan adds them, a
  plain+Manchester loopback SoC TB, and a first-consumer TX test; every
  existing TB must stay green with the engine disabled.
- Hardening: `pe_serdes` already has a routed LibreLane signoff (66 MHz: 0
  DRC/LVS, setup +7.6 ns slow, hold +0.116 ns fast), but the integration's
  mux/divider/fanout needs the SoC-level yosys+OpenSTA screen; the
  Manchester cascade has 3 clk/half-cell at 60 MHz.
- Options and open decisions (scope, IO window vs ISA widening, RX capture,
  first consumer, registered Manchester stage) are in
  [[plans/serdes-integration]]. Plan-only: no RTL, no physical flow/DRC/LVS.

## [2026-09-23] soc | serdes integration plan amended: five review findings

- Window encoding fixed: a latched INDEX/DATA phase preserves all 8 data bits
  (writes switch on phase; any read auto-increments and re-arms index), with
  explicit firmware sequences.
- `TXLEN`/`RXLEN` are separate six-bit registers (`LENW = 6`, 1..32); one byte
  cannot hold two lengths.
- Strobe split: `serdes_bit_en` per logical bit, `codec_bit_en` per cell
  (Manchester TX twice per bit with `half_phase`, `tx_ser` held across halves);
  Manchester RX uses `dru.bit_en` + `rx_first/rx_second` (the earlier
  "half-cell cadence" claim was wrong).
- Overlay moved to `pe_pinmux`'s level input before the OD gate
  (`pad_oe = reg_oe && (!reg_od || !reg_out)`); the post-matrix mux would have
  keyed OE to the un-overridden level.
- First consumer split: wire loopback in this plan; the full 10BASE-T TX frame
  path is separate (`pe_eth_mac` is RX-only, `pe_fbuf` is the RX store).
- Evidence: reviews/2026-09-23/SERDES-INTEGRATION-REVIEW.md. Plan-only: no RTL,
  no regression, no physical flow/DRC/LVS.

## [2026-09-23] docs | project block diagrams use editable PlantUML

- Simplified `diagrams/` to two tracked text sources: `project-plan.puml` for
  planned topology and `project-progress.puml` for implementation state.
- Updated both diagrams against the amended SERDES integration plan: the first
  consumer is wire loopback, while a complete 10BASE-T TX frame path stays a
  separate future block. The progress view keeps standalone engines amber and
  open integration work red.
- Removed the retired viewer setup material and updated the handoff, wiki index,
  and diagram README. PlantUML syntax/render, generated RTL inventory, and
  `git diff --check` pass.

## [2026-09-23] soc | serdes topology amended again: per-direction enables and payload handshake

- The loopback follow-up corrected two shared-enable errors in the amended
  plan. `pe_codec_mux`'s single `bit_en` gates TX and RX state in every stage
  (`pe_bitstuff`'s one `always_ff`, `pe_nrzi`'s one block, `pe_manch`'s
  `rx_err`), and `pe_manch` TX is purely combinational: the first amendment's
  "codec strobe twice per bit for Manchester" was wrong twice over. The codec
  strobe is now one per **encoded cell** (payload or inserted stuff), with
  `half_phase` an independent 2x half-cell **level**.
- `pe_serdes` also has one `bit_en` for both sides. The plan splits it into
  `tx_bit_en`/`rx_bit_en` and defines the payload-only gates from the RTL:
  `serdes.tx_bit_en = tx_codec_cell_en && !tx_stuffed` (hold across the
  stuffed cell; `tx_stuffed` is the combinational output of the registered
  `tx_pend`, current-cycle) and
  `serdes.rx_bit_en = rx_codec_cell_en && rx_bit_valid` (skip received stuff
  cells). Source-grounded against `rtl/pe_bitstuff.v` and
  `tb_pe_codec_mux.tx_step_comb`.
- Topology: two `pe_codec_mux` instances (TX/RX) because one instance cannot
  carry both directions' encoded-cell cadences; alternatives (one instance
  with a split interface; two `pe_serdes` instances; one shared serdes enable
  with lockstep scope) are open decisions.
- Tests: the SoC loopback must run a **stuffed Manchester** configuration
  (`cfg = 0x05` or `0x07`) with both directions concurrent and check the TX
  hold and RX skip end to end; the SoC mutation harness must fail on TX-hold
  removed, RX-skip removed, doubled cell enable, and the strobe cross-wire.
  Area: the serdes split is a port change (no expected cell delta); the second
  codec instance is the only material add.
- Diagrams updated to the two codec instances and the split enables; the wider
  project-diagram docs rework remains unstaged.
- Evidence: `reviews/2026-09-23/SERDES-INTEGRATION-REVIEW.md` (findings 6-7);
  plan confidence `medium` until the topology and scope decisions are
  accepted. Plan-only: no RTL, no regression, no physical flow/DRC/LVS.

## [2026-09-23] plan | pe_ctrl readback audit: guard label and A2 frame event corrected

- Independent plan-only audit of [[plans/pe-ctrl-readback]] and
  [[reviews/2026-09-23/PE-CTRL-REVIEW]] against `rtl/pe_ctrl.v` and
  `tb/tb_pe_ctrl.v`: mode-0 sampling, CS/frame boundaries, exact per-bit vs
  discrete limits, guard rates, and hold/readback pipeline.
- Corrected in the plan: `H = 8 clk` is 3.75 MHz at 60 MHz, not 2.5 MHz
  (2.5 MHz is `H = 12 clk`, ~9 clk of pre-pad margin); A2's first echo bit is
  the fall after the next frame's 16th rise (33 half-periods = 16.5*T_sclk),
  not "the 16th fall of the following frame" (31H = 15.5*T_sclk); the A2
  commit bound is written discretely; the A3 hold bullet now says
  `2 clk - t_pad - t_hold`, not "~2 clk".
- Added to the contract: a CS falling edge starts a session (address 0,
  `words_written` 0, `load_error` clear, echo clear), and A1/A2 trailing
  readback frames must stay in that same CS-low session (a CS toggle
  re-addresses to 0).
- Re-checked and unchanged: mode-0 rise-sample/fall-update ordering, the
  commit latch at the `W_DONE`/`words_written` edge (worst +6 clk), A1's
  discrete `H >= 4 clk` (~7.5 MHz), A2's per-bit ~7.7 MHz, the 2.5/5/10 MHz
  guards and A3's ~15 MHz computed / hold analysis. Review and HANDOFF/STATUS
  wording corrected to match. Plan-only: no RTL, tests, synthesis/STA,
  physical flow, DRC or LVS.

## [2026-09-23] synth | mapped hardening screen refreshed

- `./regress/synth_area.sh` with Yosys 0.69+post: exit 0, no surfaced Yosys
  diagnostics, all 17 hierarchy checks passed. Current key counts: `pe_eth_mac`
  1,402; `pe_imem` flop fallback 61,057 cells / 1,300,811.665 µm²; `pe_soc`
  3,298 / 53,730.697 µm²; TT top 3,613 / 59,547.852 µm².
- Corrected the current Ethernet MAC count in STATUS and made the generated
  block inventory take the instruction-memory flop count from the mapped-count
  cache. The 2026-09-20 SRAM figures remain historical and are labeled by date.
- Full output: `/tmp/synth_area_run.log`. Pure synthesis only; no STA, physical
  flow, DRC, or LVS.

## [2026-09-23] sta | pe_ctrl three-corner hardening screen repeated

- Re-ran `reviews/2026-09-23/pe-ctrl-hardening/synth.ys` and its slow/typical/fast
  OpenSTA TCLs with Yosys 0.69+post and OpenSTA 3.1.0. Synthesis: zero problems,
  292 cells / 75 flops, 5,791.149 µm².
- Setup slack slow/typical/fast: +8.71/+8.80/+8.86 ns; hold:
  −0.12/−0.16/−0.19 ns. All three fresh OpenSTA logs are byte-identical to
  the committed reports; asynchronous SPI input paths and unplaced fanout
  violations are unchanged.
- Fresh logs and netlist: `/tmp/pe-ctrl-hardening-check/`. Mapped STA only; no
  physical flow, DRC, or LVS.

## [2026-09-23] review | follow-up audit of deferred interface plans

- A read-only audit of `wiki/plans/pe-ctrl-readback.md` and
  `wiki/plans/serdes-integration.md` against current RTL, tests, earlier reviews,
  and hardening evidence found unresolved CPU status/strobe semantics, a
  possible trailing stuffed cell after `tx_busy` drops, and no asynchronous
  phase acquisition in the proposed plain RX path. Readback also needs a
  defined first MISO bit for each session and a CS-to-first-clock setup
  requirement for the synchronized output enable.
- Corrected two stale plan claims (diagram edges and live SoC input bit 7) and
  clarified that the Manchester half-cell phase is a level with a 50 ns
  half-cell interval at 60 MHz. Details: `reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`.
  No RTL or tests changed; no physical flow, DRC, or LVS.

## [2026-09-23] review | E1/E2 fix follow-up

- Independent source review found two remaining E1 buffer-accounting issues:
  wrapped consumer releases are rejected by the AW+1-bit difference, and a
  same-cycle consumer release plus producer room update drops one delta. Both
  are reproduced with directed temporary simulations; the current regression
  misses these alignments.
- The current E2 config passes the static macro gate, but its checks do not
  validate mapped power/ground nets or require the Metal4-to-grid connect
  clause; other lower-priority coverage gaps are documented. No source/config
  fix or physical flow was run. Details:
  `reviews/2026-09-23/E1-E2-FOLLOWUP-REVIEW.md`.

## [2026-09-23] fix | E1 ring-release wrap and consume-collision accounting

- Fixed `rtl/pe_eth_mac.v` for the E1-1/E1-2 follow-up findings: `freed` is now
  the forward distance modulo `BUF_BYTES` (AW-bit subtraction, zero-extended),
  and the validated `consume_credit` is summed into every producer `room`
  update (consume branch, `S_PAYLOAD`, `S_SETTLE`, `S_ERR`) instead of being
  overwritten by the later state-machine assignment.
- Tests first: `tb/tb_pe_eth_mac.v` gained a wrapped-release case (rptr 1996 to
  144 frees exactly 196) and a simultaneous consume + payload-write case
  (`room` moves by +freed-1). Both failed on the pre-fix RTL and pass after.
- The mutation harness was corrected while validating: the directed waits in
  `tb_pe_eth_mac.v` are bounded and `run_tb` counts only a printed FAIL as a
  detection (timeout/compile/crash is a harness error). Two mutants were added
  for this fix, so `mutate_eth_mac_tb.sh` is 18/18 with 0 survivors and 0
  harness errors; `mutate_eth_soc_tb.sh` 8/8; `run_all.sh --fast -j8` exit 0
  (29/29 RTL, 20/20 firmware, lint and all gates). Pure Yosys/OpenSTA SoC
  screen: 2 x 0 problems, setup 0.00 all corners, hold -0.87/-0.61/-0.48 ns
  (slow/typ/fast), unchanged from the post-E1 screen; canonical mapped counts:
  `pe_eth_mac` 1,354 cells / 19,789.74 um2, `pe_soc` 3,306 / 53,615.56 um2.
- E1-3 (full-ring release == duplicate) stays documented in the RTL. No
  physical flow, DRC or LVS.

## [2026-09-23] fix | E2 macro gate: pin-to-net mapping and ordered PDN ladder

- `tools/checks/macro_flow_config.py` (E2-1/E2-2): every
  `PDN_MACRO_CONNECTIONS` entry is validated field-by-field (power pins on the
  flow's power net, `VSS!` on the ground net, correct slots), and the PDN
  script must carry the macro grid's `add_pdn_stripe -layer Metal4` plus its
  ordered `Metal4 -> vertical` and `vertical -> horizontal` `add_pdn_connect`
  layers, matched inside the same command. `--flow` points the gate at a copy.
- `regress/mutate_macro_flow_config.sh` mutates copies of the flow config and
  PDN script and requires rejection of wrong-net,
  missing-metal4-to-vertical, missing-vertical-to-horizontal,
  missing-metal4-stripe, wrong-layer and reversed-layers (7/7, tracked files
  byte-compared); wired into `run_all.sh` beside the macro gate.
- `./regress/run_all.sh --fast -j8` on the final tree: exit 0, 29/29 RTL, 20/20
  firmware, lint clean, every gate and all seven TB mutation suites green.
  E2-3/4/5 remain documented. No physical flow, DRC or LVS.

## [2026-09-23] fix | E2-3: missing-PDK policy for the macro flow gate

- `tools/checks/macro_flow_config.py` exit taxonomy: 0 = complete and legal;
  1 = findings (including a Yosys elaboration failure); 2 = INCOMPLETE, only
  when the required macro LEF geometry is unavailable and there are no other
  findings. A finding with the geometry missing still exits 1, and a `--lef`
  testhook lets the policy be tested without the installed PDK.
- `regress/run_all.sh` reports exit 2 as `macro flow config: SKIPPED ...` and
  every other non-zero as FAILED. `regress/mutate_macro_flow_config.sh` now
  runs 10 checks: clean pass; the six E2-1/E2-2 mutations as exit 1; clean +
  missing LEF as exit 2 + INCOMPLETE; wrong-net + missing LEF as exit 1; and a
  forced Yosys failure as exit 1; it prints a clean SKIPPED (exit 0) when its
  own baseline is incomplete (verified with a PDK-less `HOME`).
- Full `./regress/run_all.sh --fast -j8` on the final tree: exit 0, 29/29 RTL,
  20/20 firmware, lint clean, every gate and all seven TB mutation suites
  green. E2-4/5 remain documented. No physical flow, DRC or LVS.
- Missing-LEF full regression: `HOME=/tmp/nopdk
  IHP_PDK=/home/mylesp/pdk/IHP-Open-PDK ./regress/run_all.sh --fast -j8`
  exits 0 (29/29 RTL, 20/20 firmware); macro geometry and macro-flow negatives
  both report SKIPPED. `IHP_PDK` supplies the SRAM simulation models while the
  temporary `HOME` hides the LEF used by the geometry check.

## [2026-09-23] fix | E2-4: macro view validation

- `tools/checks/macro_flow_config.py`: every configured macro type must have
  nonempty `gds`/`lef`/`lib` views; every `./src/<name>` view must resolve to
  exactly one file of the matching class and extension in the PDK
  `sg13g2_sram` tree `run_librelane.sh` stages from (a `.gds` under `gds/`, a
  `.lef` under `lef/`, a `.lib` under `lib/`; basename matching, not the repo
  cwd); and the `lib` keys must cover the flow's required
  `DEFAULT_CORNER`/`STA_CORNERS` list, derived from the flow config or the
  PDK's LibreLane `config.tcl`. The class/extension check is structural and
  runs even when the view tree is unavailable. `--pdk-root` mirrors
  `run_librelane.sh` (`PDK_ROOT`/`~/.ciel`).
- Test-first: the pre-fix checker accepted missing-GDS, missing-LEF,
  missing-corner and nonexistent-path configs with exit 0; each now exits 1,
  as does a LEF entry naming an existing `.lib` file (including with the view
  tree and the geometry LEF unavailable). The negative harness adds those five
  mutations plus view-finding-without-geometry and PDK-less wrong-type checks:
  17/17 with the PDK present at that step (20/20 after E2-5's synthetic
  checks), clean SKIPPED with a PDK-less baseline. The E2-3 exit policy is
  preserved (exit 2 only for unavailable geometry/views with no other
  findings).
- Full `./regress/run_all.sh --fast -j8` on the final tree: exit 0, 29/29 RTL,
  20/20 firmware, lint clean, every gate and all seven TB mutation suites
  green. E2-5 is closed in the next entry. No physical flow, DRC or LVS.

## [2026-09-23] fix | E2-5: per-type macro geometry

- **Finding.** The placement gate measured every configured macro type with one
  hard-coded LEF (`--lef`, default the git-clone 1P path), so a second type
  with a different footprint would have been checked against the wrong SIZE.
- `tools/checks/macro_flow_config.py`: each configured type's own `./src` lef
  view is resolved under the PDK sg13g2_sram tree (the E2-4 resolution) and its
  own SIZE drives that type's DIE_AREA fit and pairwise placement-gap checks;
  the pairwise test now uses each instance's own width/height. A type whose LEF
  cannot be resolved is reported unchecked on top of its E2-4 finding. `--lef`
  stays as the every-type override so the E2-3 exit taxonomy is unchanged
  (exit 2 only for unavailable geometry with no other findings), and `--rtl`
  was added as an isolated-test hook for synthetic netlists.
- Test-first: RED was an isolated two-type flow (two blackbox macros, fake PDK;
  A's LEF says 10x10, B's says 100x100 in a 50x50 die) accepted at exit 0 with
  `--lef A.lef`; after the fix it exits 1 with `u_b: 100.0x100.0 (type
  RM_IHPSG_FAKE_B) at (20.0,0.0) is not inside DIE_AREA [0, 0, 50, 50]`. The
  negative harness adds three synthetic checks (die fit, per-type overlap,
  missing type LEF): 20/20 with the PDK present, clean SKIPPED with a PDK-less
  baseline. Full `./regress/run_all.sh --fast -j8`: exit 0, 29/29 RTL, 20/20
  firmware, lint clean, every gate and all seven TB mutation suites green.
  E2-1..E2-5 are fully closed. No physical flow, DRC or LVS.

## [2026-09-23] test | E1 consume-credit collision coverage

- A fresh independent review traced release validation and all `room` updates;
  it found no RTL defect. It found the regression tested a same-edge consume
  only at `S_PAYLOAD`, leaving type-success settle, bad-frame settle and `S_ERR`
  folds unguarded by tests.
- Added directed consume collisions at all three room-update sites and one
  matching mutation for each. The pristine MAC TB passes; each targeted mutant
  produces the expected room assertion. `regress/mutate_eth_mac_tb.sh` now
  reports 21 detected, 0 survived, 0 harness errors.
- No RTL behavior changed. `./regress/run_all.sh --fast -j8` passes with the
  added tests: 29/29 RTL, 20/20 firmware, lint/elaboration, generated gates and
  all seven TB mutation suites. No physical flow, DRC or LVS.

## [2026-09-23] test | E1 full-ring bad-settle reclaim

- A second read-only pass found the bad-frame `S_SETTLE` reclaim width was not
  tested at `pay_cnt == 2048`; the existing full-ring reclaim test reached
  `S_ERR`, a distinct assignment. With a temporary truncated-width mutant, the
  shipped TB passed; the directed full-size bad-FCS case failed room reclaim
  and recovery checks as intended.
- The permanent TB now rejects a 2,044-byte TYPE payload with corrupted FCS,
  checks full ring reclaim and rollback, then accepts a 46-byte recovery frame.
  The `S_ERR` collision test also now proves a nonzero partial allocation is
  reclaimed with a simultaneous consumer release. MAC mutations: 22 detected,
  0 survived, 0 harness errors.
- Fresh `./regress/run_all.sh --fast -j8`: 29/29 RTL, 20/20 firmware, lint and
  elaboration clean, generated gates current, all seven TB mutation suites
  passed. No RTL change or physical flow/DRC/LVS.

## [2026-09-23] review | pe_ctrl readback host contract

- A source-grounded read-only audit confirmed the `uio[4]` mapping and A1/A2/A3
  timing arithmetic. It identified missing host-contract decisions before RTL:
  the final word of a full 1,024-word image needs an echo frame after receive
  lockout; A1/A2 require an explicit minimum SCLK low phase or duty cycle;
  per-word verification requires the readback rate on every echoed frame; and
  the CS-to-first-clock setup needs a numeric limit.
- The computed A1/A2 limits are ~7.5/~7.7 MHz, so A2's extra frame needs an
  explicit robustness rationale. No interface was selected and no RTL changed.
  Findings: `reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`; choices remain open in
  `wiki/plans/pe-ctrl-readback.md`. No physical flow, DRC or LVS.

## [2026-09-23] review | SERDES decision readiness

- A source-grounded read-only audit found the planned integration consistent
  with the current SERDES, codecs, DRU, pinmux, SoC and unit tests. It grouped
  user choices into milestone scope, plain asynchronous RX scope, topology, and
  access, and recorded evidence-backed defaults without selecting them.
- Sticky status semantics, write-triggered control strobes, final stuffed-cell
  completion, and other register/timing details remain engineering follow-ups
  after scope acceptance. The plan's 3,298-cell `pe_soc` estimate is stale
  against the current 3,306-cell result; refresh before an implementation
  comparison. No RTL changed. Full audit: `reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`.

## [2026-09-23] docs | PlantUML map source audit

- A read-only comparison of the diagrams with the current plans and RTL found
  six wording/edge issues: the timing label conflated a half-cell level with a
  strobe, CPU-to-timing edges bypassed the `0xF` window, the loopback implied
  physical pads instead of a simulation wire model, and readback omitted
  unresolved host-contract choices. Corrected the plan and progress maps; no
  completion-color changes were needed.
- `diagrams/` contains only its README and two editable PlantUML sources, with
  no rendered output. Both sources rendered headlessly to `/tmp`; no RTL or
  physical work was run. Detailed review: `reviews/2026-09-23/PROJECT-REVIEW.md`.

## [2026-09-23] verify | mapped synthesis baseline refresh

- `./regress/synth_area.sh` exited 0 on the current tree. It reports
  `pe_eth_mac` 1,354 cells / 19,789.7364 µm², `pe_soc` 3,306 /
  53,615.5578 µm², and `tt_um_top` 3,579 / 59,286.8052 µm². The script
  surfaced no diagnostics. Full output: `/tmp/synth_area_diagram_followup.log`.
- Updated the SERDES plan's area baseline. This is mapped, pre-route synthesis;
  no STA, physical flow, DRC or LVS ran.

## [2026-09-23] docs | floorplan feasibility synthesis refresh

- The floorplan review found `wiki/reference/.floorplan-areas` still held the
  SPI-pad-screen synthesis numbers. Updated the cache from the fresh mapped
  screen and regenerated `wiki/reference/floorplan-feasibility.md` with the
  current 3,306-cell SoC and 3,579-cell TT-top counts.
- The arithmetic updates to 259,805 µm² macro-plus-inflated-logic area and
  60.0% / 36.1% / 45.0% occupancy for the three die scenarios. The
  generator's shorthand “×2” wording is now the precise “stdcell-to-die
  inflation factor.” Its prose now describes the configured placements and
  PDN script clauses, separating static checks from physical results.
  `python3 tools/gen/floorplan_feasibility.py --check` passes. No flow, STA,
  DRC or LVS was run.

## [2026-09-23] fix | E1 committed-byte ownership guard

- Pi's independent MAC accounting audit found that `used` counts the current
  uncommitted frame. A forward consume into those bytes could then be credited
  again by bad-frame reclaim or TYPE FCS windback, exceeding ring capacity.
- Added `published_used` to track committed storage. Consume validation now
  requires `freed <= used` and `freed <= published_used`; successful length
  and TYPE settlement publish their actual stored data bytes. Reclaim and
  `S_ERR` do not publish the failing frame.
- Added directed bad-FCS and successful TYPE over-read cases. Both failed on
  pre-fix RTL (room 2,098 and 2,052) and pass after the guard. The concurrent
  producer-pointer test now releases only part of a prior frame, making the
  producer/consumer addresses differ and allowing the rebase mutant to be
  detected.
- Added publication assertions for same-edge length and TYPE completion,
  consume-credit subtraction, and exclusion of the four TYPE FCS bytes.
  Bad-FCS rollback and `S_ERR` collision cases now partially consume prior
  committed frames and assert their unconsumed published-byte remainder. The
  harness has separate mutants for each missing term and for clearing earlier
  published-byte ownership during either reclaim path.
- `regress/mutate_eth_mac_tb.sh`: 30/30 detected, 0 survivors, 0 harness
  errors. `./regress/run_all.sh --fast -j8`: 29/29 RTL, 20/20 firmware, lint,
  elaboration, generated gates and all seven mutation suites pass.
- Fresh Yosys mapping: `pe_eth_mac` 1,681 cells / 23,749.6266 µm², `pe_soc`
  3,571 / 56,816.8776 µm², `tt_um_top` 3,888 / 62,745.4296 µm². The refreshed
  floorplan cache/page now estimates 265,666 µm² macro-plus-inflated logic and
  61.4% / 36.9% / 46.0% occupancy; both generated checks pass. Three-corner
  mapped OpenSTA setup stays at 0.00 ns, hold at −0.87/−0.61/−0.48 ns
  (slow/typ/fast); no new Yosys
  check problems. The prior unplaced hold/electrical violations remain.
- Full review: `reviews/2026-09-23/E1-PUBLISHED-OWNERSHIP-REVIEW.md`. No physical
  flow, DRC or LVS.

## [2026-09-23] plan | Linux demo-host GUI and board path

- Clarified the intended three-layer interface: connected Linux PC GUI
  (planned) → RP2040/Raspberry Pi Pico on the Tiny Tapeout demo board → ASIC
  passive SPI loader. PC-to-board transport/control API, clock control, and
  load-status/readback strategy remain open. Added GUI planning as item 8 in
  the ordered STATUS backlog; no GUI or bridge firmware has started.
- Updated the plan and progress maps to show the PC, demo board controller,
  and chip loader. Kept both PNG and SVG renders alongside the PlantUML files;
  PNG rendering uses `PLANTUML_LIMIT_SIZE=8192` to avoid the default dimension
  cap. Current planned/progress PNG sizes: 4180×2520 and 4189×1956.
- Pi's read-only screenshot investigation matched the supplied 1393×269 image
  to `/tmp/plantuml-view/project-plan.png`, a pre-`cc00c58` uncommitted draft
  render. No committed `.puml` source matches it. The original draft source is
  absent; render provenance and the next near-square layout proposal are in
  `reviews/2026-09-23/PROJECT-REVIEW.md`. Pi pane `%46` is idle.

## [2026-09-23] plan | demo host GUI draft (STATUS item 8)

- Drafted `wiki/plans/demo-host-gui.md` from existing sources only: ADR-007's
  loader contract (mode-0, MSB-first, 16-bit words into IMEM, `run == 0` gate,
  <=10 MHz SCLK, no MISO/readback in v1), the wrapper pin map
  (`ui_in[3:5]` loader pads, `ui_in[1]` `run`, `uo_out[1]` heartbeat,
  `uo_out[7:2]` debug PC), the TT clock spec (RP2040-generated 1 Hz-66.5 MHz,
  MicroPython Commander `set_clock_hz`), and the pin budget.
- Records that `pe_ctrl`'s `load_active`/`load_error`/`words_written` are sunk
  in the wrapper's `_unused` bundle, so the GUI cannot verify a load today;
  status is tiered (pads/host-side now, board-side sampling open, pad or MISO
  readback = future user-gated change).
- PC-to-board transport/API, image container, clock surface, status strategy
  and Linux packaging are all marked **[OPEN]** with evidence-backed options
  (reuse MicroPython/Commander vs custom board firmware vs later/networked).
- Planning/documentation only: no GUI code, bridge firmware, RTL or pinout
  change. STATUS item 8 remains **TODO** until the user accepts the plan.

## [2026-09-24] fix | macro-flow gate E2-6 + R3 (checker identity)
- `tools/checks/macro_flow_config.py`: each type's resolved `lef` view must declare `MACRO <type>` (fail-closed: no MACRO = finding) and a `lib` view declaring cells must declare one for the type; R3 closed — no single `lib` file may serve two required corners (config-only, PDK-less paths unchanged)
- `regress/mutate_macro_flow_config.sh`: 20 -> 26 checks, adding the required `type-b-wrong-lef` mutation on the synthetic two-type fixture (type B with A's 10x10 LEF in a 50x50 die), `type-b-wrong-lib`, `type-no-macro-lef`, `corner-file-shared`, `corner-key-wildcard`, `synth-identity-clean`; false pass demonstrated on a /tmp copy first (wrong-LEF exit 0 vs own-LEF exit 1), pre-fix harness 21/5, post-fix 26/0
- Evidence: `reviews/2026-09-23/PROJECT-REVIEW.md` "E2-6 resolution"; status **fixed-pending-manager-verification** (E2 not yet closed); R1/R4/R5 remain observations
## [2026-09-24] feature | pe_ctrl readback — option A1 (STATUS item 6 DONE)
- `uio[4]` now carries a commit-latched word echo: frame 0 = 0x0000, frame k = the word committed at frame k-1, one trailing frame in the same CS-low session; the payload updates only where `words_written` increments (aborted words never echo) and the serializer is not gated by `load_error`, so the final word of a full 1,024-word image echoes through the receive lockout
- Numeric host contract in the `pe_ctrl` header and [[plans/pe-ctrl-readback]]: every echoed frame <= 2.5 MHz, SCLK low >= 100 ns (6 clk), CS_N -> first rise >= 100 ns; mode-0 change on the detected falling edge; `uio_oe[4] = load_active`
- Budget: committed pads 18 -> 19, free uio 4 -> 3 (pin-budget page regenerated); `pe_ctrl` 292 -> 463 cells, `tt_um_top` 3,888 -> 4,038 (floorplan cache/page refreshed)
- Verified: `tb_pe_ctrl` (new cases 8-12) PASS, pad-level `tb_tt_um_protocol_emulator` PASS (full 1,024-word image + echo), `regress/mutate_ctrl_tb.sh` 23/23 (was 11/11, +3 wrapper pad mutations), `run_all.sh --fast -j8` green, `synth_area.sh` clean; no STA refresh yet (manager-scheduled), no physical flow/DRC/LVS
- Review: `reviews/2026-09-24/PE-CTRL-READBACK-REVIEW.md`

## [2026-09-24] feature | SERDES + codec integration into pe_soc (STATUS item 7 DONE)
- Implemented wiki/plans/serdes-integration.md per the manager decision adopting every recommended default in reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md (additive engine disabled at reset, self-timed wire-loopback first consumer, plain RX without phase acquisition as the documented limit, 0xF indexed window access; the review's two-codec shape wins over the plan where they differ)
- RTL: pe_serdes `bit_en` split into tx_bit_en/rx_bit_en (mechanical; nine protocol TBs alias their strobe, tb_pe_serdes gains a directed split case); pe_pinmux gained the ov_en/ov_bit level overlay feeding BOTH pad outputs before the open-drain gate (tb_pe_pinmux gains overlay/od cases); pe_soc gained the engine section — 16-entry latched-phase window on port 0xF (INDEX/DATA phases, any read re-arms), CTRL strobes tx_load/rx_start/clr as one-cycle write-triggered pulses, latched tx_done/rx_valid/rx_err (set-beats-clear on STATUS), a divider producing one cell strobe per encoded cell + half_phase with TWO toggles per cell, grid-aligned load/start with the Manchester rx_start anchored to the first DRU decode after load, payload-only gates (!tx_stuffed / rx_bit_valid), two unmodified pe_codec_mux instances, RX off the existing DRU (one capture path)
- First consumer: firmware/serdes_loop.pe (70 words, peasm ENGINE=0xF) + tb_pe_soc_serdes — plain LSB/MSB, Manchester, and the directed stuffed Manchester loopback (0x07E0, trailing-stuff guaranteed by construction); PASS, with monitors for cell spacing, TX hold, RX skip, DRU-strobe source and exact advance counts
- Mutation harnesses: NEW regress/mutate_soc_serdes_tb.sh 7/7 (plan's four required: TX-hold removed, RX-skip removed, doubled cell enable, strobe cross-wire, plus rx-start-no-anchor, half-rate-half-phase, no-grid-load) and NEW regress/mutate_serdes_tb.sh 7/7 (split enables, bit order, len0, idle level); all nine suites green with 0 unexplained survivors (i2c 6+1 documented-equivalent, spi 5, fbuf 5, eth_mac 30, eth_soc 8, i2c_xfer 11, ctrl 23, macro 26)
- Two bring-up defects the directed tests caught and fixed: half_phase toggled once per cell (wire ran at cell rate), and a stale idle DRU decode captured as payload bit0 (rx_start anchor)
- Source lists that elaborate pe_soc gained pe_serdes/pe_nrzi/pe_bitstuff/pe_codec_mux: flow/pe_soc.json, info.yaml, synth_area, the macro gate, five mutation harnesses (the first full run failed exactly there — all green after)
- Evidence: ./regress/run_all.sh --fast -j8 exit 0 (30/30 RTL, 21/21 firmware, lint, gates, nine suites); ./regress/synth_area.sh clean — pe_soc 3,571 → 4,961 cells / 56,816.88 → 82,893.77 µm² (+1,390), tt_um_top 4,038 → 5,363 / 65,686.27 → 91,268.06 µm² (+1,325); floorplan cache/page and block-diagram/glossary regenerated (serdes+codec orphans retire). No STA refresh (manager-scheduled), no physical flow/DRC/LVS. Review: reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md; diagrams/project-progress.puml refreshed twice (gotcha 47)

## [2026-09-24] hardening | Task 4 closeout — mapped STA refresh + codec mutation suite
- (a) Mapped STA refresh for the SERDES integration's new timing classes. The recorded screen scripts were extended (source lists gain `pe_serdes`/`pe_nrzi`/`pe_bitstuff`/`pe_codec_mux`) and three corners at 16.667 ns run on BOTH `pe_soc` and `tt_um_protocol_emulator` (slow is also the hold corner; hold checked at all corners). `pe_soc`: setup 0.00/0.00/0.00 ns, hold −0.87/−0.61/−0.48 ns — **identical to the pre-integration screen at every corner**; `tt_um_top`: setup 0.00 ns, hold −0.71/−0.52/−0.43 ns. **No new violation class**: overlay→pad (max +7.96 ns slow), `half_phase` (min +0.23 ns slow), window read mux (min +0.15 ns slow) and the split enables (min +0.75 ns) are all MET at slow; fast-corner negative holds are shallower members of the pre-existing pre-layout family, and the pad hold violation pre-existed (pre-integration HEAD fast −0.1026 ns → post −0.0308 ns). Slow-corner max-slew/fanout violator counts grew (49→96 / 136→188) in the same classes, all pre-route/non-gating. Reports + scripts: `reviews/2026-09-24/serdes-sta/` (incl. the pre-integration control netlist).
- (b) NEW `regress/mutate_codec_tb.sh`: 13 mutations across `pe_codec_mux`/`pe_bitstuff`/`pe_nrzi`/`pe_manch` covering the documented CAN preset `0x51`, `ones_only` (`cfg[7]`) and run length (`cfg[6:4]`), the registered `clr`/`rx_err` contract, and the frame-boundary `clr`, plus pipeline order, bypass subsets and `half_phase`; all **13 detected / 0 survived / 0 harness errors** with per-mutation `cmp`-verified restore (gotcha 63). The unit TB gained three directed checks first: a non-complementary CAN stuff bit sets the registered `rx_err`, NRZI `clr` restores idle J, and Manchester `clr` beats a pending error on the same edge. Wired into `run_all.sh` as the tenth mutation suite.
- (c) `./regress/run_all.sh --fast -j8` exit 0 (30/30 RTL, 21/21 firmware, lint clean, every generated gate + macro negatives, **ten mutation suites**); `./regress/synth_area.sh` clean at the baseline (`pe_soc` 4,961 / 82,893.7746 µm², `tt_um_top` 5,363 / 91,268.0622 µm²).
- Hashes, exact commands and the full result tables: `reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md`. Mapped screens only — no physical flow, DRC or LVS. `wiki/plans/demo-host-gui.md` untouched.

## [2026-09-24] layout | Task 5a — squarer diagram layout (both maps)
- Re-laid out both PlantUML maps to the approved squarer targets and checked in the winning sources plus re-rendered PNG/SVG sidecars: `project-plan.puml` 4180×2520 (1.6587) → **3194×2476 (1.2900)**; `project-progress.puml` 6195×1354 (4.5753) → **3681×2493 (1.4765)** (the progress map had sprawled during the Task-3 end refresh); both targets met (≤1.4:1 / ≤2.0:1)
- Plan: all four notes anchored `note bottom of pads` as one compact block below the architecture (packages/edges untouched; intermediate 3304×2458). Progress: `left to right` → `top to bottom`, five packages now vertical status lanes (direction-only intermediate 3681×2440)
- Sanctioned status-label changes only: plan readback package/component/edge labels and readback/serdes notes now record A1 landed and the integrated engine; progress macro gate `E2-6 + R3 fixed (26 checks) / manager verification pending` → `closed / manager-verified 2026-09-24` (amber → green class, note CLOSED), readback note records the mapped STA refresh and the loopback note the 13/13 codec suite
- Independent pre/post parse: plan 7/7 packages, 26/26 components, 36/36 edges, 4/4 notes; progress 5/5, 24/24, 26/26, 4/4; only the sanctioned labels/notes differ; `plantuml --check-syntax` rc=0 and `--check-graphviz` OK (PlantUML 1.2026.8, GraphViz 16.1.0)
- Evidence: `reviews/2026-09-24/DIAGRAM-SQUARER-LAYOUT.md`. Limit: Graphviz auto-placement — re-measure after future content changes. No RTL, tests or scripts changed.

## [2026-09-24] hardening | Task 5b — hold-screen attribution + BOARD-assumption STA variants
- All 18 recorded mapped STA screens (3 designs × 3 corners) now exist in two labelled variants: `VARIANT: ZERO-ASSUMPTION` (the recorded 0.0 ns min delays) and `VARIANT: BOARD-ASSUMPTION` (min input/output delay 1.0 ns; max delays unchanged at 3.3334 ns). A `pe_ctrl` mapping/netlist was added so the A1 loader screen is re-runnable under both variants; run both with `bash reviews/2026-09-24/serdes-sta/run_sta.sh`
- Every screen ends with a full negative-min-slack inventory (1000 groups × 4 endpoints) so nothing hides in the top-5 display; new `reviews/2026-09-24/serdes-sta/analyze_hold.py` classifies external-input (data + `rst_n` removal), external-output, internal pre-CTS and internal-within-0.25 ns-uncertainty classes (`hold-attr-analysis.txt`)
- Attribution: zero-variant negatives are external-input assumption artifacts (`host_*`/`run`, `rst_n` removal), external-output artifacts (`pin_out`/`dbg_*`/`spi_miso`/`uio_out[4]`) or internal/within-uncertainty; the board variant drops **every external class to 0 paths in all nine screens**. Worst setup unchanged in every pair; board worst hold `pe_soc` −0.54/−0.41/−0.36, `tt_um_top` −0.64/−0.48/−0.40, `pe_ctrl` **+0.04**/−0.07/−0.13 ns (slow/typ/fast — `pe_ctrl` hold-clean at slow). Internal reg-reg slow worst is a flop→fbuf SRAM-pin path; the routed SoC's CTS+hold repair closed the family (+0.1209 ns, 0 violating paths)
- The 1.0 ns min-delay floor is a labelled screening assumption (launch/level-shifter + short FR-4 run + connector/protection + pad ring), **not** a measured board flight time; all BOARD MET claims are conditional on it, and the 0.25 ns hold uncertainty stays in both variants
- Read-only input-registration audit (no RTL changed): `spi_sclk`/`spi_mosi`/`spi_cs_n` already 2FF-synchronized and false-pathed; `rst_n`, `run`, `host_*` and the plain `pin_in` lanes are unregistered — constraint-only today, RTL register stages recorded as options
- Evidence: `reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md` + `reviews/2026-09-24/serdes-sta/`; the Task-4 hold interpretation is refined by the post-update block at the end of `reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md`. Mapped pre-CTS screens only — no physical flow, DRC or LVS; no regression rerun (no RTL changed)

## [2026-09-24] plan | 10BASE-T TX frame path (`eth_tx`) — STATUS item 9

- Authored `wiki/plans/eth-tx-frame-path.md` in the `ethernet-soc` plan style (goal, architecture, global constraints, Review Focus, task-by-task checkbox steps) with eight scope groups, each carrying an evidence-backed recommended default plus alternatives and costs, for manager adoption at review
- Defaults recommended: firmware-streamed frame bytes through an 8-byte staging FIFO in the `0xF` window extended to 32 entries (16-23 push-and-wrap, 24/25 TXLEN, 26 TXCTRL, 27 TXSTAT) with no frame-sized TX buffer (G1/G2); hardware-owned 56-bit preamble + SFD `0xD5` LSB-first, CRC cleared at the prelude (G3); a TX-dedicated `pe_crc #(.W(32))` with the generated RevEng-checked constants — FCS emitted from the field-mode pure shift, receiver verdict remains the catalogue residue `0xDEBB20E3`, never `crc_zero` (G4); reuse of `u_tx_codec` + divider (`DIV = 6` = 100 ns cells, 3 clk half-cells) + the verified pad overlay via an exclusive owner mux, with the idle trap pinned (`tx_bit = half_phase` between frames) (G5); `uo_out[2]` (`dbg_pc[0]`) reclaimed as `eth_tx` behind a `pin_oe_bus[7]` mux so reset stays bit-identical, RX stays `ui_in[2]` (G6); first consumer `firmware/eth_tx_arp.pe` (42-byte ARP request, hardware pad to 64 + FCS) with a pad-level Manchester decode and a TX→RX loopback through `firmware/eth_rx.pe` (G7); mutation suites `mutate_eth_tx_tb.sh` + `mutate_eth_tx_loop_tb.sh` (G8)
- Coverage: preamble/SFD insertion, FCS append semantics (never `crc_zero`; residue), 64-byte minimum pad and max-length refusal (>1,514 stored), runt-pad/jabber-refuse policy, IFG = 96 bit times (576 clk), and the exact 100 ns bit at the locked 60 MHz / SPB=12 grid; acceptance decodes real frames with a real FCS at the pin like `tb_pe_eth_mac`
- Registered in `wiki/index.md`; STATUS gains item 9 and item 4 gets the post-A1 counts (19 of 24 committed, `uio[7:5]` free, revisit trigger fired) plus the plan's pad recommendation. Planning only: no RTL, tests, scripts or firmware changed; `wiki/plans/demo-host-gui.md` untouched
- Observed at plan-writing time (noted in the plan's baseline block and flagged for the manager): the shared worktree carries an uncommitted, unrecorded "phase R1" host-bus change to `rtl/pe_ctrl.v`/`rtl/tt_um_protocol_emulator.v` (`uio[4:7]`, referencing a missing `wiki/plans/host-controller-gui.md`), which would consume the free `uio` pads; the recommended `uo_out[2]` reclaim is baseline-independent and the free-`uio` alternative is marked as depending on the reconciliation

## [2026-09-24] hardening | R1 framed host bus — reconcile, fix, verify

- Attribution: the chip-side host protocol landed unrecorded at 14:33 (pe_ctrl/wrapper/both TBs/mutate_ctrl_tb.sh/crc_config) before the OOM; audited against the host-controller plan and `HOST-CONTROLLER-PLAN-REVIEW` in the read-only `/tmp/opencode/host-controller-gui` session repo; the R0 pad ruling is adopted (framed protocol wins; A1 `uio[4]` echo retired, its commit-latched/abort semantics moved into the framed LOAD response)
- Contract verified: frame = `A55A` sync, `{version,opcode,target}`, sequence, length, payload, CRC-16/CCITT-FALSE (`0x1021`/`FFFF`, RevEng check `0x29B1`); responses set opcode bit 7 and echo sequence/target, status-first (`0 OK … 6 NOT_READY`); R1 opcodes PING/LOAD/STATUS/CLEAR_FAULT/TARGET + target-1 loopback; `IRQ_N` = `~|faults` with mask clear; LOAD while `run=1` -> NOT_READY (no fault); no trailing frames
- Pads: `uio[4:7]` = host CS_N/MOSI/MISO/SCK (lower PMOD), `uo_out[1]` = IRQ_N, `ui_in[3:5]` freed; 19/24 committed, 5 free `ui_in`, 0 free `uio`
- Authorized behavior-preserving RTL fixes (`rtl/pe_ctrl.v` only): old-style `crc16_byte`/`crc16_word` (yosys 0.69+post cannot parse `return`); fixed 3-bit response payload slot case (removes Verilator WIDTHTRUNC). `regress/synth_area.sh` now fails loudly on a yosys ERROR (gotcha 13; failure path tested with a throwaway broken file). P21 CS-to-first-clock sweep added to `tb_tt_um_protocol_emulator` (40/60/150/400 ns, all PASS)
- Evidence: `bash regress/lint.sh` exit 0 (15 verilator + 12 yosys elaborations); `./regress/run_all.sh --fast -j8` exit 0 (30/30 RTL, 21/21 firmware, ten mutation suites); `bash regress/mutate_ctrl_tb.sh` **29 detected / 0 survived / 0 harness errors**; `./regress/synth_area.sh` exit 0 — `pe_ctrl` **1,731 cells / 30,662.1126 µm²**, `tt_um_top` **6,633 / 113,254.8858 µm²** (`pe_soc` unchanged); seven generator `--check`s OK after regenerating `signal-names.md` and `protocol-pin-budget.md`; `info.yaml` duplicate `ui[3:5]` keys fixed and the map moved to R1
- Hashes: `rtl/pe_ctrl.v` `aea1a765ab060ab7e806f9d7c37785f0856e81bf2ceef11b36d7501e390b0bc7`; `tb/tb_tt_um_protocol_emulator.v` `84c71a72125ba6d3a8094061191bf92db5c3781e8f531d2071c6dfa6bfd8f49f`; `regress/synth_area.sh` `84c3cf401f0e846a3acdf513979f1dbb93bea82c36cdb6fe470dd44cea3a28e2`
- **OPEN FINDING (a):** P3 liveness gap — `uo_out[1]` is IRQ_N, the heartbeat pad is retired, and the R1 STATUS layout deliberately omits timer/pc/a/x/y, so no scope-visible liveness until the R2 read path. **(b) P21 sweep closed** by the new directed case. No physical flow, DRC or LVS

## [2026-09-24] rtl | Manager Task 10 — 10BASE-T TX frame path plan Tasks 1-3 landed

- Task 1: `tb/tb_pe_eth_tx.v` written RED-first; the pre-change-tree run fails to elaborate (`pe_eth_tx` missing). Directed set: 42-byte ARP request padded to 60 stored bytes, exactly-64 (no pad), the 1,514-byte maximum, refused 1,515-byte jabber and 13-byte runt, mid-frame abort, FIFO underrun (10 of 42 bytes), a 200-cell constant idle stretch, and two frames separated by ≥96 idle cells. The TB decodes the raw Manchester wire from ph2/ph5 half-cell samples and checks the FCS with an independent left-shifting model; it also checks the CRC register's drain-to-zero (the pe_crc field-mode trap), not just the emitted bits.
- Task 2: new `rtl/pe_eth_tx.v` — hardware 56+8 prelude/SFD (wire pattern, never 0xAA through a byte helper), octets LSB-first, zero pad to 64 bytes folded into the FCS, TX-dedicated `pe_crc #(.W(32))` with the generated RevEng-checked constants, 8-byte staging FIFO, runt/jabber refusal, 96-cell IFG, `tx_bit = half_phase` idle (constant wire, not a square wave). Registered in `run_all.sh` CASES + `synth_area.sh` + `lint.sh`. `PASS: tb_pe_eth_tx`; lint clean; standalone mapped 892 cells / 16,040.0898 µm².
- Task 3: `rtl/pe_soc.v` — 32-entry `0xF` window (5-bit index; 16-23 push+wrap, 24/25 TXLEN, 26 TXCTRL, 27 TXSTAT set-beats-clear), owner mux on `u_tx_codec.tx_bit` (`eth_start` gated on `!ser_tx_busy`, `tx_path` clear refused while `tx_busy`, `enable = eng_en && tx_path`), DIV=6; `tb/tb_pe_soc_eth_tx.v` written first (RED on the pre-change window: aliased writes, `CFG=ff`, engine never enabled, 734 FAILs) then GREEN. NEW `firmware/eth_tx_arp.pe` (502 words; the first consumer runs the window phase machine and TXSTAT `fifo_ready` backpressure) + committed `.hex`, assembled in `run_firmware_tests.sh`. Two integration defects caught and fixed: TXCTRL is a level register so `frame_start` must write bit2=1; and the firmware must claim `tx_path` before `eng_en` or the idling SERDES drives a Manchester square wave on the shared codec.
- Same-list updates in one pass: `run_all.sh` (8 `pe_soc` CASES + the new SoC TX case), `flow/pe_soc.json`, `info.yaml`, `tools/checks/macro_flow_config.py`, `synth_area.sh` (`pe_soc`/`tt_um_top` + a standalone `pe_eth_tx` line), `lint.sh` (RTL_ALL + both top lists), and all eight `pe_soc`-elaborating mutation-harness source lists; `wiki/reference/signal-names.md` regenerated (16 modules / 205 ports).
- Evidence: `./regress/run_all.sh --fast -j8` exit 0 — **32/32 RTL (the 30 existing intact), 22/22 firmware (the 21 existing + the new assemble), lint clean, every generated gate, all ten mutation suites**; `./regress/synth_area.sh` exit 0 — `pe_eth_tx` 892 / 16,040.0898 µm², `pe_soc` 4,961 → **6,191** / 82,893.7746 → **107,939.6388 µm²**, `tt_um_top` 6,633 → **7,980** / 113,254.8858 → **138,746.7144 µm²**. Hashes and the RED/GREEN transcripts: the 2026-09-24 top block in `HANDOFF.md` and `wiki/STATUS.md` item 9. No physical flow, DRC or LVS.
- Limits: plan Task 4 (wrapper `uo_out[2]` mux + pad-level decode), Task 5 (loopback consumer + two-frame acceptance), Task 6 (two mutation suites) and Task 7 (mapped STA screen + closeout) remain. `wiki/plans/demo-host-gui.md`, `reviews/2026-09-23/PROJECT-REVIEW.md`, `COLD-START.md` and `MANAGER-COLD-START.md` untouched.

## [2026-09-25] eth-tx plan Tasks 4-7 | diagram refresh, mutation suites, STA screen, close-out

- Diagram refresh (manager dispatch): both PlantUML maps updated to the verified post-Task-5 state — the TX frame path and its loopback acceptance GREEN in `project-progress`, the mutation suites (Task 6) and STA/close-out (Task 7) RED until they landed, the G6 `uo_out[2]` reclaim and the 32-entry window on both maps, and the A1 readback note brought up to the R1 framed host bus. Re-rendered colocated PNG/SVG with the README commands. `project-plan` 3385x2706 (1.25:1, was 1.29; target <= 1.4) and `project-progress` 3947x2477 (1.59:1, target <= 2.0). Structural audit before/after: zero packages, components or notes lost in either map (2 sanctioned package-title changes, 1 edge deliberately retargeted through the new owner mux). The squarer plan came from folding the TX status into the existing SERDES note, dropping a separate FIFO node and putting the owner mux inside the word-engine package.
- Manager Task 11 close-out: the red tree was the UNRESTORED `mutate_i2c_tb.sh` mutation m1 (a kernel OOM at 18:43 SIGKILLed the suite before its restore step), not a hand edit; `rtl/pe_pinmux.v` restored byte-exactly from the harness's surviving pristine snapshot and `cmp`-verified against both copies; `firmware/i2c_pins.*` already pristine-identical. Recorded in the ledger, STATUS and HANDOFF.
- Plan Task 6: `regress/mutate_eth_tx_tb.sh` (unit, 18 mutations over `pe_eth_tx.v` — the prelude/SFD traps, the CRC field-mode traps, pad as data, the IFG, runt/jabber, the underrun fault, constant idle, octet order, the done pulse) and `regress/mutate_eth_tx_loop_tb.sh` (integration, 7 mutations over `pe_soc.v` / `pe_eth_mac.v` / the wrapper — owner mux, overlay, G6 pad mapping, cell-boundary pacing, RX capture, FCS verdict convention, push wrap). **18/18 and 7/7, 0 survivors.** The suite found two real gaps in its own TB and both were fixed in the TB: a 60-byte pad-boundary case (no case had exactly 60 stored bytes) and an engine-side `ifg_active` cell count (the wire-gap measure hid a 95-cell engine IFG). An earlier draft of the integration suite also found the RX-capture mutation must target the MAC's `.bit_en`, not the RX codec's (that one feeds the SERDES). Both suites wired into `run_all.sh` as suites 11 and 12.
- Plan Task 7: mapped 16.667 ns OpenSTA screen of the new classes (`reviews/2026-09-25/eth-tx-sta/`, source lists gain `pe_eth_tx.v`, 2 designs x 3 corners x ZERO/BOARD, runner exit 0). **No new violation class** vs the 2026-09-24 control: the same four negative-min classes with the same worst endpoints; the pre-CTS internal family deepened 16 ps and the rst_n-removal count rose with the flop count. The class that leaves the chip, the G6 pad `uo_out[2]`, measures MET at **+7.6330 ns setup / +0.2964 ns hold** (slow). Two documented harness workarounds: the screen copy strips `signed` from wire declarations (pe_ctrl function locals this OpenSTA build rejects) and the probe runs on a non-flattened netlist. Close-out review written: `reviews/2026-09-25/ETH-TX-FRAME-PATH-REVIEW.md`; plan Status updated; both project diagrams and the index refreshed.
- Final verification: `run_all.sh --fast -j8` exit 0 — RTL 33/33, firmware 26/26, lint clean, 12 gates, 12 mutation suites (`/tmp/run_all_t6.log`). `synth_area.sh` exit 0 — `pe_eth_tx` 892 / 16,040.0898 um2, `pe_pinmux` 127 / 2,191.1904, `pe_soc` 6,219 / 108,084.8286, `tt_um_top` 7,960 / 138,817.4004 (`/tmp/synth_t7.log`). Mapped/simulation evidence only — no physical flow, DRC or LVS.
- Formal campaign Campaign II (manager ruling: instrumented targets + the memory/strategy ruling). **Target 1** re-proved and its `m1` mutant caught; **target 3a**'s modelling gap closed at a SMALL depth — the shadow now samples `frame_len` where the engine applies it, so the runt and jabber mutants both die at depth 16 (the runt mutant previously survived even at 240); **target 3b**'s IFG floor is now proved INDUCTIVELY and UNBOUNDED (the old claim was vacuous at every affordable depth: the shortened-gap mutant survives at 240 and the 700-step run died at the memory cap), with the skip-the-gap mutant caught as well; **target 2** has 8 claims proved unbounded and 4 proved at gate depth only, LABELLED as such in the wrapper; **target 4**'s existing owner guard is proved unbounded and its missing SET-side guard is recorded as finding **F2**. Two harness bugs were found and fixed on the way: `sat` IGNORES `$assume` unless `-set-assumes` is passed (the first campaign's reset assumption was decoration), and clocked assertions after `clk2fflogic` read sampled COPIES that an arbitrary induction state can set inconsistently (combinational asserts + explicit snapshots are the provable shape). `tools/check_formal_ifdef.sh` (FORMAL never defined on a synthesis path; 0 `fv_*` wires in a synthesis elaboration) and `formal/mutants.sh` (10 mutants, each in its claim's own proof shape; 10 caught, 0 survived) are now `run_all.sh` steps. Record: `reviews/2026-09-25/FORMAL-VERIFICATION.md` Campaign II.
- Wiki index refreshed: the page count was stale (32 -> 42), four plan pages were missing from the Plans list (`plans/ethernet-soc`, `plans/pe-ctrl`, `plans/i2c-transaction`, `plans/host-controller-gui`), and a **Reviews and evidence** section now routes to the review record — including `reviews/2026-09-25/R2-READ-PATH-REVIEW.md`, which the host-controller-gui merge brought into this repo, so the R2 record is no longer reachable only across a repo boundary. The signal glossary was regenerated for the new formal-only taps and now labels every `fv_*` port FORMAL ONLY.

## [2026-09-25] create | plans/feature-brainstorm.md — 33 novel features, grounded in the blocks that exist
- Created: `plans/feature-brainstorm.md` (type `plan`, 1183 lines)
- Scope: seven themes — time-as-resource (A1 reverse execution, A2 protocol flight recorder, A3 R4 watchpoints/counters/conditions, A4 hardware coverage harvest, A5 self-certifying persona), wire-as-data (B1 browser waveform, B2 golden waveforms as a gate, B3 60-phase margin maps, B4 the chip as analyzer, B5 self-timing), breaking-things (C1 the adversary target, C2 fault playground, C3 margin hunting, C4 mutant firmware as a shipped demo mode, C5 live chaos), writing-protocols (D1 one description three consumers, D2 NL→persona gated by measurement, D3 datasheet tables as a conformance matrix, D4 the chip assembling itself), conformance-as-the-product (E1 golden WIRE corpus, E2 differential conformance, E3 in-chip self-conformance, E4 the claim ledger, E5 formal→simulation), lab-and-room (F1 remote node, F2 classroom, F3 demo stream, F4 the protocol chord), and a wildcard tier (G1–G6).
- Every idea answers: what it is / what it beats (a NAMED incumbent plus the mechanism of the beating) / how it lands on the six blocks that exist (`pe_ctrl` debug control, the framed SPI link, the firmware persona model, the pin matrix, the word engine, the golden packages) / effort shape / what it proves for the competition. Marks are C (creativity), F (feasibility at the tapeout milestone) and F∞ (feasibility in simulation), 1–5 each.
- Also: a 33-row ranking, three tiers (no new silicon / small RTL / shape-of-the-thing experiments), a 15-row **demo-versus-commitment self-audit** separating what a judge sees from what the repo must be able to fail at, and a "what I would NOT build, and why" section.
- **Strongest finding:** `pe_ctrl`'s `target` field already selects target 1, a deterministic loopback on the same MISO that consumes no pad, clock or external MISO. The feature a fault-injection target needs — a peer the host cannot predict — is half already built and unused, which is why C1 ranks where it does.
- Self-correction after landing: I had written that the NEC act's half-periods were "measured to 0.05 clocks". They are a 787.95–794.95 range around a nominal 788.95. Corrected in the same branch; recorded because "a count is an assertion" failing the author is the failure mode this rule exists for.

## [2026-09-25] create | concepts/overview.md — the cold-start on-ramp
- Created: `concepts/overview.md` (type `concept`, 672 lines)
- Purpose: how the five layers fit (chip, host bus, firmware personas, host stack, verification culture) for an engineer landing cold, with the pad map, the 4-bit port map and the three rules that exist because the obvious alternative was tried, why the ISA is 16 opcodes, and the three implementation styles with the 48-instructions-per-byte arithmetic that forces 10BASE-T into hardware.
- Records the relationships a newcomer otherwise has to reverse-engineer: single-cycle is what makes cycle-exact timing AND replay possible; the ISA's missing shift-*left* is why the port-numbering rule exists; the pin matrix being inside the SoC is an architectural win and not a workaround.
- The R1/R2/R3 phase table carries the wait-word rule and the **debug-hold trap** (once held, the run strap is ignored in BOTH directions; only `DEBUG_BP_CLR` or reset releases) with the reason it is written down anywhere at all.
- Closes with the six verification mechanisms each paired with the lie it closes, an hour-long reading order, and an explicit **"what is not true yet"** (nothing taped out; no real-board run; mapped STA is not signoff; 8×4 may never happen; 5 of 24 pads free).
- Verification performed: every wikilink resolves; every tag is inside the `SCHEMA` taxonomy; LSP clean.

## [2026-09-25] restructure | index.md — from a catalogue to a map
- Rewrote `index.md` as the map of the whole wiki rather than a flat page list.
- Added: a **Start here** section with six reading paths (whole-thing-in-an-hour, why-a-protocol-is-a-file, the-silicon, the-verification-story, the-host-bus, what-to-build-next); concepts split into architecture / timing-and-physical-layer / 10BASE-T / protocol deep-dives; a generated-versus-handwritten split in Reference with the reason each page is drift-checked; diagrams moved to their own note because `diagrams/*.puml` are repo files, not wiki pages; and 31 review links grouped project / verification-and-formal / host / layout-and-process, each checked against a real file at the repo root.
- Wired in the two new pages with one-line descriptions, and added an **In flight** section so the sibling workers' remaining pages have a landing place and their absence is not read as a decision not to write them. The section is deleted when the families are complete.
- **In flight #1:** `concepts/protocol-ws2812` (from `docs/diag-timing`) — 800 kHz one-wire with no clock on the wire, the 48-clock high, the 75-cycle grid, and why a 74/76-clock cell passes every datasheet window in the world and is still wrong.
- **In flight #2:** `concepts/protocol-servo` (from `docs/diag-timing`) — servo PWM as a protocol with nothing in it but a number, and the cleanest demonstration that cycle accuracy is a property of the **program** rather than of the gates.
- Verification performed: every wikilink in the three files resolves; the one deliberately forward-referenced link (the siblings' pages) is labelled with the branch it lands from.

## [2026-09-25] finding | the R2 golden package under-reports its own coverage
- Found while writing `concepts/overview.md` and recorded there as a worked example of the project's own "a count is an assertion" rule. Phrased as a question with the command to check it, not as a verdict.
- `tb/r2-vectors/manifest.json` contains 18 steps of which 15 carry `chip_confirmed: true`; the three that do not are `read_imem_at_ceiling_15`, `read_imem_over_ceiling` and `read_dmem_zero_count`. The package-level flag is correctly `false`.
- But the evidence block has **no `not_confirmed_steps` key**, so the three are named nowhere; the `notice` reads "**every** golden step in this package passes byte-exactly … 15/15", which describes the confirmed subset as though it were the whole package; and the sibling artifact `reviews/2026-09-25/R2-READ-VERIFICATION.json` says `chip_confirmed: true` with 18 confirmed steps citing "18/18".
- `python3 -m tools.host_gui.r2_vectors --check` reports UP TO DATE, so this is what the generator itself emits, not a stale checked-in file.
- R3 does it correctly: it names its one unconfirmed step with a reason, and `tb_pe_ctrl_r3_conf` fails if the observed divergence set ever changes. So either the R2 evidence set should grow to 18, or the three should be enumerated with reasons the way R3 enumerates its one.
- Manager ruling 2026-09-25: routed to the gui-worker as the package owner. No change made to any golden package from this branch.
