# Project review — 2026-09-22

A full review of the design, tests and tooling at HEAD `b935cb8`, run against a
`git archive` clone so ignored build artifacts could not mask a missing file.
Every finding below was reproduced before it was fixed; the reproduction scripts
and logs from the review are the other files in this directory.

Baseline measured in the clean clone: **26/26 RTL testbenches, 16/16 firmware
checks and all four mutation suites passed**, while the overall command still
exited non-zero. The failures were in the gates around the tests, not the tests.

The list, with the fix and the test that would catch a regression:

| # | P | Finding | Fix | Coverage |
|---|---|---|---|---|
| 1 | P1 | The Tiny Tapeout `info.yaml` source list omitted `pe_imem`, `pe_pinmux` and the SRAM blackbox, so compiling the listed sources ended in `Unknown module type: RM_IHPSG13_1P_1024x16_c2_bm_bist`. The full-SoC LibreLane config omitted `pe_pinmux` the same way. | Both lists completed; the TT list now compiles under iverilog. | `iverilog -s tt_um_protocol_emulator` over the listed files |
| 2 | P1 | `pe_dru` sampled only RISING clock edges. At the locked 60 MHz core and SPB=12 that is a 200 ns bit — but 10BASE-T is 100 ns/bit, so real-rate receive was missed entirely. The testbenches scaled the wire to the clock and hid it. | Dual-edge (DDR) front end per ADR-002: rising-edge synchronizer + falling-edge latch pair, an interleaved 3-tap majority, and an unrolled two-samples-per-clock grid machine. | `tb_pe_dru` and `tb_pe_eth_mac` now run real 60 MHz / 100 ns/bit; the Ethernet TB is real frames with a real FCS |
| 3 | P1 | One oversized frame could exhaust the receiver permanently: the reclaim was `room + {1'b0, pay_cnt[AW-1:0]}`. A frame that filled the 2,048-byte ring left `pay_cnt = 2048 = 11'h000`, so the reclaim added zero and `room` stayed 0 until a reset. | Full-width reclaim (`pay_cnt[AW:0]`); the sum cannot overflow because every counted byte was charged against `room`. | `tb_pe_eth_mac` frame 9 (oversize from empty, then a valid frame must be accepted); `mutate_eth_mac_tb.sh` `truncated-reclaim` |
| 4 | P2 | Correctly PADDED short length frames were rejected: the receiver jumped from the declared length straight to the FCS, folding the pad bytes as if they were the FCS. | New `S_PAD` state consumes `46 - field` pad bytes (folded, not stored) before the FCS. | `tb_pe_eth_mac` frame 8 (length 20, wire 46); `mutate_eth_mac_tb.sh` `no-pad` |
| 5 | P2 | The emulator advanced the timers BEFORE executing the instruction. On a wrap it returned the new counter to `IN TIMER` and could clear a flag that had just arrived; the RTL reads the pre-edge register with set-beats-clear. | `step()` executes, then ticks; the stopped path still ticks. | `tb_pe_tick_status` directed overlap cases + `emulate: timer wrap semantics` in `run_firmware_tests.sh` |
| 6 | P2 | Starting the emulator after a stop could skip instruction 0: the stopped path returned without refetching the registered ROM word. | The stopped path holds PC=0 and keeps `imem_rdata = imem[0]`, as the RTL does. | same emulator case (stop → run executes `LDI A,0x55`) |
| 7 | P2 | The regression could not pass on a fresh clone: the block-diagram check compared timestamps against SVGs that `.gitignore` excludes, and the Canvas viewer check crashed on the missing SVG. | The mermaid SOURCE HASH is committed as `diagrams/block-diagram.stamp` and is what `--check` compares; the Canvas check uses a built-in fixture SVG. | `git archive` clone with no SVGs: both gates pass; editing the mermaid still fails the check |
| 8 | P2 | The lint gate omitted `pe_eth_mac` and `pe_fbuf`, so the regression said "lint clean" while a direct `verilator -Wall` on the MAC produced five findings (a width expansion and four unused signals — two of them 12 dead `dst`/`src` registers), plus a `TIMESCALEMOD` once it joined the file list. | Both blocks added to the gate; the RTL fixed rather than suppressed (7-bit shift registers, dead registers removed, sized subtraction, timescale removed). | `tb/lint.sh` now covers 13 tops + 11 elaborations |
| 9 | P2 | `peasm.py --rtl-init` silently truncated programs to 128 words and emitted invalid Verilog (`initial $readmemh_unused;` then a bare comma-separated list). | Emits a valid one-word-per-line `initial` block at the real 1,024-word depth; truncation is now an error. | `rtl-init` output compiles under iverilog; a 301-word program emits 301 assignments |

## Findings that changed a documented decision

**#2 is the one that invalidated a claim.** `wiki/concepts/cdr-oversampling.md`
said the DDR front end was implemented; it was not, and the testbenches made the
gap invisible by driving the wire at half rate with a 100 MHz clock. The fix
follows ADR-002's latch-pair form (sg13g2 has no negative-edge flops) and keeps
the single-edge grid algorithm — the phase counter still counts samples and
captures at SPB/4 and 3·SPB/4; only the sample source changed.

One consequence is recorded honestly in `tb_pe_dru`: a 3-tap majority outvotes
an isolated spike on a stable level, but a spike inside the majority's window of
a REAL transition can move the filtered edge by a sample. That is a limitation
of a 3-tap filter, not of the DDR scheme; the end-to-end Ethernet TB (real
frames, real CRC) is the traffic coverage, and the filter test states the
property it can actually guarantee.

## What the review did not change

- The 60 MHz operating point, the SRAM plan, and the pin matrix stayed.
- The four mutation suites keep their criteria; the fbuf harness's restore check
  was moved from `git diff` to a pristine snapshot, because a git-clean check
  also fires on legitimate uncommitted work (measured after finding 8's edit).
- The regression now passes in a fresh clone: `git archive HEAD` → `run_all.sh`
  exits 0 with no ignored files present.
