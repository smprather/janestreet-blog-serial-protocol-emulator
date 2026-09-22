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
## [2026-09-18] create | Live Canvas: agent -> browser diagram channel (side-quest)
- Built tools/live-canvas/ — a Hermes dashboard plugin (user plugin, symlinked at ~/.hermes/plugins/live-canvas) that watches diagram dirs and pushes HTML/SVG to a Canvas tab over a WebSocket; publishing is just a file write (no credentials)
- Verified live against dashboard 0.21.3 on :9119: write -> push in ~1s with no reload, in-place edit -> re-render in ~1s, unauthenticated /state 401, /slide outside roots 404, sandbox escape probe blocked (SecurityError, no token leak)
- Surfaced two Hermes contracts worth remembering: user plugin backends only import when the plugin is in plugins.enabled, and pane code must use SDK.buildWsUrl/SDK.fetchJSON (loopback token is absent in gated OAuth mode)
- Created: wiki/concepts/live-canvas.md, tools/live-canvas/ (plugin + README + canvas-publish.sh), diagrams/ (git-ignored publish target + README)
- Alternatives considered and not chosen: Hermes Desktop preview rail (needs Electron build), tldraw-offline optional skill (AUR, complementary), community browser extension (Chromium side panel)
- Added tools/live-canvas/gen_block_status.py: renders the STATUS.md "what is built and verified" table as an SVG into diagrams/ (single source of truth; atomic write). Verified live in the pane.
- Fixed live-canvas contrast bug (reported from a screenshot): text slides inherited the dashboard's dark-theme foreground on the paper-white stage — light-on-light, unreadable. Pinned explicit colors on .lc-stage pre / .lc-empty / .lc-warn (15.8:1, 6.4:1, 4.9:1 vs #fff). Pitfall recorded in tools/live-canvas/README.md.
## [2026-09-18] tooling | flowchart generator + three layout bugs it exposed
- Added tools/live-canvas/gen_flowchart.py: JSON spec -> SVG flowchart (grid layout, geometry-routed edges) + flowcharts/rx-path.json; pushed to the Canvas pane as diagrams/serdes-rx-flow.svg
- Rasterized with rsvg-convert and inspected at full size, which caught what the pane preview hid: (1) loop-back edge drawn as one line straight across the chart, (2) a self-loop reaching for the far gutter lane, (3) side-branch arrows entering the FAR vertex so the arrowhead crossed its target box, (4) em-dash mojibake from srcdoc delivery
- Fixes: self-loops become local hooks; cross-row edges enter the facing vertex; every text emission goes through esc() (non-ASCII -> numeric refs); added find_crossings() so a segment through a shape fails the build (exit 3) instead of shipping. Checker negative-tested: caught 5 crossings in a deliberately bad spec
- Pane change: SVG slides now fit width and scroll vertically (letterboxing made a tall chart's labels unreadable)
- Logged pitfalls in tools/live-canvas/README.md (contrast, encoding, rasterize-to-verify, routing)
## [2026-09-18] concept | strobe + committing edge explained, with real capture
- Created wiki/concepts/strobe-and-committing-edge.md — defines the two terms from the RTL's own contract (pe_serdes.v:12, pe_line_codec.v:16) and the combinational-vs-registered sampling rule (tb_pe_codec_mux.v:10-13)
- Added tools/live-canvas/gen_vcd_view.py: renders a VCD window as a labelled timing diagram (per-signal sampling at each rising edge; clock drawn as real transitions, not sampled)
- Three teaching diagrams pushed to the pane: diagrams/bitcell-anatomy.svg (one bit cell, strobe marked), diagrams/uart-byte.svg (all 8 bits of 0x55), diagrams/strobe-flow.svg (control flow, spec in flowcharts/strobe-flow.json)
- Real numbers from sim/tb_pe_uart.vcd: tx_load @206ns, first strobe @217ns, cells 160ns apart (16 clk @ 10ns)
- Generator bugs caught by rasterizing: clk row drew flat (sampling a clock at its own edges always reads 1), a tick label clipped at the canvas edge, and the loop-back label landed on the diamond text (moved to the source end of the lane). find_crossings() caught 8 spec errors across three layout attempts before any were drawn
- Note: the flowchart checker rejected the first two layouts I wrote — worth the 3 exits
- Added zoom/pan to the live-canvas viewer (wide diagrams were unreadable at fit): +/- steps 25-800%, 100% = authored pixel size, Fit, Ctrl/Cmd+wheel, drag-to-pan; text slides zoom by font size. Two bugs found and fixed while building it: (1) an SVG with width+height+viewBox scales its CONTENT to fit the box, so setting only style.width left the height pinned and "150%" rendered at 100% — must set width+height+attributes together; (2) driving zoom by remounting the iframe (a key that changed with zoom) blanked the stage and dropped scroll — the frame doc is now memoised on the slide only and view changes go over postMessage. Sandbox unchanged (allow-scripts, no same-origin); viewer talks to the pane only via postMessage, source-checked.
## [2026-09-18] reference | signal-names.md — every RTL port documented
- Created wiki/reference/signal-names.md: all 60 ports across the 5 modules, plus the naming conventions (tx_/rx_, *_en, *_valid, *_raw vs *_wire, *_lvl, *_err, cfg_* snapshots) and the internal signals the RTL comments refer to (tx_rd_idx, rx_pos, rx_fin, tx_pend …)
- Port tables are EXTRACTED from the Verilog by tools/gen_signal_glossary.py, not hand-typed; --check exits 1 on drift, and tb/run_all.sh now runs it, so a renamed port cannot leave the page describing a dead interface. Verified: renaming rx_valid->rx_done made the gate fail, then restored
- Hand-written prose is limited to what the RTL cannot say about itself (meaning, validity, which protocol uses it); a port lacking a note is still listed with a marker so the table can never silently omit a signal
- Added a 'reference' page type + tag to SCHEMA.md; linked the page from each RTL header and from strobe-and-committing-edge
- New section in wiki/index.md (Reference), total pages 16
## [2026-09-18] reference | protocol pin budget — 26 pads, 24 usable, nothing needs more than 4
- Created wiki/reference/protocol-pin-budget.md: per-protocol IO counts with the wires named, the TT pad budget (ui_in 10 + uo_out 8 + uio 8 = 26, of which u_clk and u_rst_n eat 2 input bits, leaving 24 usable), and what the BOARD must add per protocol (pull-ups, transceiver, transformer, USB pull-up)
- Answer: max single protocol = 4 pins (SPI, JTAG). All nine pinned out simultaneously = ~23 of 24, i.e. it fits but is the wrong design — the premise is that protocols are firmware claiming pins at runtime via the programmable matrix, so the real constraint is how many run at once, not the count
- Counts read from the testbenches (wire sets confirmed against tb_pe_*.v declarations); TB presence is checked by the generator so a deleted TB cannot leave the page claiming coverage. Drift-verified by pointing a TB reference at a nonexistent file
- Same generated-doc discipline as signal-names.md: tools/gen_pin_budget.py + --check wired into tb/run_all.sh (now gates both reference pages)
## [2026-09-18] reference | SRAM budget — the die shape, not the area, is the constraint
- Created wiki/reference/sram-budget.md from the PDK LEFs (tools/gen_sram_budget.py): all 30 macros with real W×H, area and bits/µm²
- Key finding: TT tile notation is WIDTH×HEIGHT, so 8x4 at the template's 167x108 um tile is 1336x432 um — a 3.1:1 die, 0.577 mm² (the blog's 200x150 would give 1600x600 / 0.96 mm²). Consequence: the two densest macro classes (8192x32 at 1520x618, 2048x64 at 784x627) DO NOT FIT in either orientation
- Corrected a methodology error mid-task: density×area overestimates capacity because a rectangle packs worse than its area implies. Switched to real 2D grid packing — best packable is 131,072 bits (16 KB) on the template die, 196,608 (24 KB) on the blog die, both ~90% die efficiency with zero logic
- Practical answer: 1 KB = 8% of die, 2 KB = 14%, 4 KB = 24%, 8 KB = 45%, 16 KB = 89%; 32 KB unreachable with a single macro type. 1-2 KB comfortable, 4 KB ceiling for a design that also needs logic
- Also corrected the record: the wiki's "256x16 … 2048x64" macro list was incomplete (4096/8192 classes, 2P variants, non-BIST 64x16/64x32 exist). STATUS open risk updated with the real numbers
- Gate: gen_sram_budget --check joins run_all.sh, skipped loudly if the PDK is absent (external dependency, not repo state). Drift-verified by perturbing the tile size
## [2026-09-19] tooling | layout renders in the Canvas pane (+ raster slide support)
- Extracted the routed pe_serdes GDS: /raw only knew how to serve TEXT, so a KLayout PNG was invisible to the pane. Added a raster slide kind (png/jpg/jpeg/gif/webp), a /raw byte endpoint, and an <img> viewer path with the same zoom model as SVG
- Two subtleties worth keeping: (1) /raw stays behind normal dashboard auth and the pane fetches it with SDK.authedFetch into a blob URL, because an <img src> cannot carry the session header and the alternative would be punching a hole in core's PUBLIC_API_PATHS allowlist; (2) the 4 MB slide cap rejected the first montage at 10 MB — images got their own 32 MB ceiling since /raw streams them rather than pushing them down a WS frame
- Image compression lesson: magick montage emitted 16-bit RGBA (10.3 MB) for a lossless-looking layout render; -depth 8 PNG24 took it to 3.4 MB with no visible change. Check bit depth before blaming resolution
- Verified: /raw with token -> 200 image/png, bytes identical to source; without token -> 401; with token but a non-slide path -> 404. Pane shows blob: URL, natural 1800x1920, fit-scaled to the stage
- diagrams/pe_serdes-layouts.png: 2x2 contact sheet (placement / upper-stack PDN / detailed-routing zoom / full stack). Renders generated with a KLayout batch script (layer-separated views; the LibreLane default render stacks every layer opaquely and is unreadable)
## [2026-09-20] plan | through-i2c.md — plan to the I2C milestone
- Created wiki/plans/through-i2c.md (new 'plan' page type + tag added to SCHEMA.md, new index section): definition of done, what already exists that it reuses, three blockers with the numbers, firmware design (tick plan, per-bit cost, transaction structure), test strategy, ordered work list, risks
- Key architectural statements: I2C is bit-banged, NOT SERDES-driven (per-bit conditional control flow — ACK, arbitration read-back, stretch — is the shape a word engine cannot express; keeps the SERDES for UART/SPI/CAN/USB where it already works); the pin matrix / open-drain is the real new hardware and the last thing gating the stretch protocols
- Timing worked as arithmetic to be checked at the pin, per the repo's existing exact-integer discipline: 1 us tick = 40 clocks; tLOW/tSU;STA/tBUF 5 ticks, tHIGH 6 (90.9 kbit/s, inside the 100 kHz ceiling); the 300 ns margins are the ones consumed by the pull-up edge, so tLOW is budgeted 4.8 us driven
- Load-bearing number for the read path: tLOW - tVD;DAT - tSU;DAT = 4.7 - 3.45 - 0.25 = 1.0 us = 40 cycles to notice, read, arbitrate and raise SCL (fast mode: 12 cycles). Spec values read from UM10204 Table 10, not recalled
- Instruction memory (Blocker 3): uart_echo is 114/128 words; recommendation is 1P_1024x16 (1024 x 16, 14% of the template die) when the second protocol lands, flops at 256 words as the alternative; the CPU's registered-ROM fetch-ahead means swapping flops for a macro changes nothing in the interface or cycle model
- Also recorded: the ISA has SHR and no shift-left, and a rotate suffices for MSB-first assembly (shift after every bit except the last), so no new opcode for I2C
## [2026-09-20] debug | tb_pe_uart_soc red -> root-caused and fixed (three defects)
- Symptom looked like an RTL/emulator cycle-model divergence (TX decoded d0 for 0x41 and e8 for 0x42; watchdog on 0x00; start bit 4.3 us vs 8.67 us). It was not the CPU
- Dominant bug: the TESTBENCH lost the echo's start edge. @(negedge tx_pin) ran after send_byte() returned, but the firmware echoes as soon as it has the byte and RX/TX are separate pins -- so the echo's start bit was already in flight. The TB synced to the next falling edge (the last data bit) and every decode was shifted one bit: 0x41 = 01000001 read one late = 11010000 = d0
- Fix: latch the edge with always @(negedge tx_pin) and anchor the sample grid to the LATCHED time via the real clock (while ($time < t_edge + BIT_NS*(1.5+k)) @(posedge clk)), re-arming per byte
- Second defect: the TB loaded 112 of the program's 114 words (i < 112); the program's own JMP 0 loop-back is at word 113
- Third defect: firmware/uart_echo.pe's start-bit wait branched JNZ tx_startw (the poll) instead of JNZ tx_start (the snapshot) -- its own comment above says the poll must jump back to the snapshot. A 2-tick wait therefore lasted 1 tick, which is the 4.3 us start bit
- Verified: tb_pe_uart_soc PASS on 41/42/00/FF (cells 8.6-8.7 us measured at the pin); emulator PASS on the same four; tb/run_firmware_tests.sh 5/5. Left standing: the tick is 173 clocks but three comments (pe_uart_soc.v:58, uart_echo.pe, peemu.py:43) say 174 -- real baud 115,607 (+0.35%)
- Lesson (same as the Milestone-1 CAN/USB TB bugs): a testbench that waits for an event it may have already missed tests nothing. Latch the edge, anchor to the latched time
- Also fixed peemu.py's docstring: it pointed at wiki/concepts/firmware-uart.md, a page that does not exist; now points at wiki/plans/through-i2c.md
## [2026-09-20] milestone | Milestone 2 committed + housekeeping (handoff prep)
- STATUS.md rewritten for Milestone 2: both layers of the thesis now exist (shared hardware layer + programmable core); block diagram updated to show pe_cpu/pe_uart_soc, the two coexisting implementation styles (SERDES word engine vs firmware bit-bang), and what is still NOT built (pin matrix, DRU, word FIFO, SRAM swap); reading order now points at plans/through-i2c.md second
- Measured and recorded: pe_cpu 377 cells / 4,805 um2; pe_uart_soc 8,592 cells / 177,328 um2 local (182,133 total incl. the CPU; flop memory, called out explicitly so nobody reads it as a synthesis failure); regression is 16/16 TBs + 5/5 firmware tests
- tb/run_all.sh: now runs run_firmware_tests.sh FIRST (tb_pe_uart_soc $readmemh's the .hex it assembles, so the RTL test can never simulate a stale image), then all 16 TBs (tb_pe_cpu + tb_pe_uart_soc added to CASES), then the three generated-doc drift checks. Exits 0
- tb/synth_area.sh: covers pe_cpu and pe_uart_soc, with a comment explaining the SoC's flop-memory area
- wiki/reference/signal-names.md regenerated (was stale after the new RTL: 22 undocumented ports); gen_signal_glossary --check now green
- Comment fixes: the tick is 173 clocks, not 174 (integer division; baud 115,607, +0.35%) in rtl/pe_uart_soc.v, firmware/uart_echo.pe and tools/peemu.py
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
- Root cause of all four surviving so long: `tb/synth_area.sh` captured yosys's whole output and grepped it only for cell counts, so both synthesis warnings were printed on every run and discarded. It now surfaces them and exits non-zero. Added `tb/lint.sh` (verilator -Wall on 8 tops + a yosys elaboration check for driver conflicts and implicit declarations) and wired it into run_all.sh — a simulator's resolution of illegal RTL is not the synthesiser's
- New tests: `firmware/tick_count.pe` + `tb/tb_pe_tick_status.v` (the STATUS port had NO firmware exercising it, which is why its flop could be a constant); `--expect-buffer` in peemu (checks state, not just echoed bytes). Both were verified RED against the unfixed code first
- **Built the Tiny Tapeout top level**: `rtl/tt_um_protocol_emulator.v` + `info.yaml` + `tb/tb_tt_um_protocol_emulator.v`. There was no `tt_um_*` module anywhere, so nothing in the repo was submittable and every pin-budget conclusion described an interface no RTL implemented. The TB asserts the pad contract continuously — no X on any output, `ena` gates nothing, open-drain pins never drive high — and was mutation-tested: all three defects it targets were confirmed caught
- **Flow config moved into the repo** (`flow/pe_serdes.json`, `flow/run_librelane.sh`). The 66 MHz / 0 DRC / 0 LVS signoff config lived only in ~/asic-runs, so a clone could not reproduce the one routed result the project claims
- Codec fixes: pe_manch's rx_err was combinational and ungated, so it sat high on an idle line and permanently high whenever Manchester was bypassed — it is OR'd with pe_bitstuff's registered rx_err in pe_codec_mux, and two sampling rules for one output is not a contract. Now registered and strobe-gated in both. Added `clr` to pe_nrzi and pe_manch (only the stuffer had it; a USB packet starts from idle J and the only route there was a chip reset)
- Area reporting corrected: synth_area.sh read yosys's per-module LOCAL area, which is 69 um2 for pe_codec_mux (glue only) and 0 um2 for any wrapper. Now prefers "Chip area for top module". Real totals: pe_cpu 387/4,952; pe_uart_soc 8,744/182,650; tt_um top 8,743/182,652
- Plan corrections in through-i2c.md: (1) the pull-up reasoning was INVERTED — SCL's rise is released and slow, so it is consumed from tHIGH, not tLOW; the 5/6 tick split is right for the opposite reason to the one written, and tLOW should NOT be shortened to 4.8 us; (2) "our write path changes SDA right after SCL falls (hold ~0) which is legal" is wrong — UM10204 Table 10 note 2 requires a transmitter to internally provide >=300 ns of SDA hold to bridge SCL's falling edge; (3) tSU;DAT budgeted as ">=10 cycles" is 250 ns at 40 MHz, exactly the minimum with zero margin — use a full tick
- Documented honestly rather than fixed: the tick-delta wait returns after (0,1] ticks, not 1, so uart_echo's 3-tick alignment lands in (2,3] and the worst case sits on the start-bit/bit-0 boundary. The header had claimed "2 ticks of margin". Inherent to a free-running tick; a sub-tick NOP delay would recentre it, recorded as a follow-up before fast-mode I2C
- Emulator cleanup: removed a dead `branch_a` forwarding variable documented as "mirroring rtl/pe_cpu.v's branch_a" (the RTL has no such signal and needs none — single-cycle), and a `dmem_rdata` that was computed every cycle and never read. Docstring said dmem reads are registered; the RTL says combinational on purpose. Cycle count unchanged at 39,444, confirming the removal was behaviour-preserving
- Removed vestigial `uv init` scaffolding (src/ package with a "Hello from" entry point); the real tools are standalone in tools/
- Regression now 18/18 TBs + 11/11 firmware tests + lint clean + 3 generated-doc drift checks

## [2026-09-20] analysis | area budget, 10BASE-T scoping, and the memory plan
- Measured the area question properly by synthesising pe_uart_soc at four IMEM depths (16/32/64/128 words): dead-linear at **1,271 um2 and 60 cells per instruction word**, with all other SoC logic (CPU, DMEM, timer, pin, glue) at 19,947 um2 / 1,025 cells. **Flop instruction memory is 89% of the current design** — ~80 um2/bit against ~5 for a macro
- Established the mapped->die factor as **1.97** from the only block that has actually been routed (pe_serdes: 11,223 mapped -> 17,211 routed cells -> 29,164 um2 die at 78% util). Macros place as-is with no routing inflation
- Occupancy: the integrated design TODAY (SoC + SERDES + codecs) is 384,500 um2 of die = **89% of a 4x6** / 67% of an 8x4. After the SRAM swap it is 235,116 = 54% / 41%. Gate count is not the constraint at any point (9,397 cells now, ~1,700 after the swap, against ~24,000 for 24 tiles)
- **Tile allocation raised as an open question**: the user reports 4x6 as current; the blog instructs 8x4 and info.yaml says 8x4, with the Gemini transcript's "6x4" already marked superseded. Recorded in STATUS open questions as needing confirmation from Jane Street rather than silently overwriting a sourced figure. The two are 24 vs 32 tiles but, more importantly, 668x648 (1.03:1) vs 1336x432 (3.09:1) — and SHAPE is what decides macro fit
- Made `tools/gen_sram_budget.py` take `--tiles WxH` (default 8x4) so the whole page can be re-answered for another allocation with one command; --tiles and --check are mutually exclusive since the committed page is the 8x4 answer. Confirmed a 4x6 die loses the ENTIRE 64-bit-wide macro family (1P_1024x64, 1P_512x64, 1P_256x64, 1P_64x64 — all 784 um wide against a 668 um die width)
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
- Corrected everywhere: `info.yaml` tiles 8x4 -> **6x4**; competition-overview.md; entities/tiny-tapeout.md; STATUS.md area budget and risks; adr-003-memory-plan.md; README.md; through-i2c.md; gen_pin_budget.py's related-links line
- `tools/gen_sram_budget.py` default is now 6x4 and every hardcoded "8x4"/"32 tiles"/"1336x432"/packing-table label is DERIVED from TILES_W/TILES_H, so the page can never again disagree with the constant. `--tiles 8x4` renders the upside case. Regenerated; page now reads 24-tile, 6x4, 1002x432
- **Geometry, and a correction to yesterday's 4x6 analysis.** 6x4 at the template tile is 1002x432 um (2.32:1); a 4x6 would be 668x648 (1.03:1). Same 24 tiles, different shape. I previously analysed 4x6 and reported that the entire 64-bit-wide macro family drops out — that is true of 4x6 but NOT of the real 6x4, which keeps all four (1P_1024x64, 1P_512x64, 1P_256x64, 1P_64x64). Shape, not tile count, decides macro fit
- **The 8x4 upside changes nothing in the macro analysis**: 6x4 and 8x4 are the same HEIGHT (432 um at the template tile) and differ only in width, so no macro that fits one fails on the other. 8x4 is pure extra width
- Occupancy on the real 6x4 die (432,864 um2): today, integrated, with flop IMEM = 385,265 um2 = **89%**; after the ADR-003 SRAM swap = 235,116 = **54%**; leaner swap (1P_512x16 IMEM) = 200,751 = 46%. ADR-003's decision is unaffected by the allocation change — both chosen macros are 237x336 and fit every candidate shape
- Note the blog's own arithmetic is self-consistent at 6x4: 6x4 at 200x150 = 1200x600 = 0.72 mm2, matching its stated "about 0.7 mm2". The 8x4 reading never was (it implied ~1 mm2, which the old summary duly recorded)
- Regression unchanged and green: 18/18 TBs, 11/11 firmware, lint clean, 3 generated-doc drift checks

## [2026-09-20] rtl | pe_crc + pe_dru implemented: 20/20 TBs, lint clean
- `rtl/pe_crc.v` (209 cells / 3,354 um2) — ONE shift-right datapath serves both CRC
  families, so there is no mode bit and no width port. Constants checked against the
  RevEng catalogue's published values (`tools/gen_crc_config.py`, drift-checked in
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
- `rtl/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v` added: an empty port shell so yosys can
  elaborate the instance. It is NOT a model — simulation uses the PDK's real
  behavioural model, located by `tb/sram_model.sh`, and a missing model is a hard
  failure rather than a silent fall back to the flops.
- **Found a blocker the plan had missed.** `pe_cpu` had a fixed 8-bit PC, so 1024
  words were not addressable: `next_pc[IAW-1:0]` became an out-of-range part-select
  and the reachable program stayed 256 words no matter how deep the memory was.
  Blocker 3's claim that the swap "does not change the CPU's interface" was true of
  the cycle model and false of the address width. PC and jump-target field are now
  derived from IMEM_WORDS (8 bits at 128 words, 10 at 1024). Recorded as
  [[decisions/adr-004-program-counter-width]].
- **Measured, from `tb/synth_area.sh`, both ways round:**
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
- One real behavioural change from the longer load window: `tb_pe_tick_status` began
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
- **Measured, not just argued:** tb_pe_uart_soc with CLK_HZ = 60 MHz passes UNCHANGED,
  firmware and all — no RTL or firmware edit. That is the evidence that the turbo is a
  one-parameter change. (Run it from sim/: the TB $readmemh's ../firmware/uart_echo.hex,
  and running from the wrong directory loads nothing and the CPU executes garbage —
  which is exactly how this was first "failed" and then correctly diagnosed.)
- Created: decisions/adr-005-60mhz-turbo.md. Updated: concepts/tx-timing-generation.md
  (the "forced-66 fallback" section is replaced by the proof, and the signoff policy now
  reads "close at 66, run at 60"), wiki/STATUS.md (key-decisions table + gotchas 24-26),
  HANDOFF.md, wiki/index.md. New: tb/param_guards.sh (in run_all.sh).

## [2026-09-21] decide | Switched the project to the 60 MHz operating point
- ADR-005 moved from "60 MHz turbo, 40 default" to **60 MHz is the operating point**.
  User: "yep. redesign everything around 60MHz."
- Switched: pe_uart_soc CLK_HZ default -> 60_000_000; tt_um top instantiation -> 60 MHz;
  pe_dru SPB default -> 12; info.yaml clock_hz -> 60000000; peemu.py CLK_HZ/tick table
  (260, +0.160%); tb_pe_uart_soc, tb_pe_tick_status, tb_pe_dru, tb_tt_um_protocol_emulator
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
- **Emulator gained an SPI wire model** (`tools/peemu.py`): `poll_spi_slave`
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
  index.md, firmware/spi_xfer.pe, tools/peemu.py, tb/run_firmware_tests.sh,
  flow/pe_uart_soc.json.

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
  `PDN_CFG` (`flow/pe_uart_soc_pdn.tcl`) that stripes the macro on **Metal4** and
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
- Updated: flow/pe_uart_soc.json (GRT_ADJUSTMENT, PDN_CFG), new
  flow/pe_uart_soc_pdn.tcl, flow/run_librelane.sh (stages PDN_CFG),
  tools/gen_sram_budget.py + wiki/reference/sram-budget.md, STATUS.md
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
- Updated: `rtl/pe_pinmux.v`, `tb/tb_pe_pinmux.v`, `tb/run_all.sh`, `tb/lint.sh`,
  `tb/param_guards.sh` (PINS guard: 0 and 9 rejected, 1 and 8 accepted),
  `tb/synth_area.sh`, `tools/gen_signal_glossary.py` + regenerated
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
  `pe_uart_soc` at another rate: the TT top passed `60_000_000` — the same value
  as the default it was overriding — and every TB passed `60_000_000`. A
  parameter nobody varies is not a knob, it is a second place for the derived
  arithmetic to disagree with the first, which this project has paid for twice
  (the 173 tick, the 40-clock I2C µs). **Proven netlist-neutral**: `synth_area.sh`
  reports `pe_uart_soc` at **1121 cells / 19,905.7824 um2** and `tt_um_top` at
  **1126 / 19,922.0742** before AND after — a refactor that changes no cell.
- **The 66 MHz STA signoff target is RETIRED.** Both flow configs moved
  `CLOCK_PERIOD` 15.15 -> **16.667**. Closing at 66 made every reported slack
  number require a conversion by the reader, and a longer period is strictly
  easier for setup — a design that closes at 66 has already closed at 60. The
  pad-ceiling hedge is honestly gone (no IHP-specific pad figure is published
  either way).
- **New drift-gated page: [[reference/clock-arithmetic]]** —
  `tools/gen_clock_arithmetic.py` READS `CLK_HZ` OUT OF THE RTL and derives every
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
