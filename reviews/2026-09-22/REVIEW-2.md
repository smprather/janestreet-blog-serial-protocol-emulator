# Project review, second pass — 2026-09-22

**Reviewed revision:** `628e309`, branch `review/fix-invisible-defects`.
**Result:** seven reproduced open findings: two P1 and five P2. The existing
regression is green. Those results do not cover the failures below.

This pass re-examined the RTL, its integration boundaries, firmware/emulator
behavior, and verification tooling. The first review was used as a regression
checklist. Its nine findings and fixes remain recorded in [REVIEW.md](REVIEW.md);
the findings below are additional defects or remaining boundary cases.

Production RTL, firmware, and tooling were not edited. Changes from this review
are this report, reproduction artifacts, and the handoff/status/log updates.
No physical flow, DRC, or LVS was run, following the standing user instruction.

## Evidence and scope

- A fresh isolated copy of the reviewed revision ran
  `./tb/run_all.sh --fast -j4`: **26/26 RTL testbenches, 17/17 firmware checks**,
  lint/elaboration, parameter guards, generated-document checks, Canvas check,
  I2C timing check, and all four mutation suites reported success. See
  [baseline-regression.log](review2/baseline-regression.log).
- The manifest fixes and the earlier emulator, padding, reclamation, assembler,
  and documentation-gate fixes were checked against the current implementation.
  Nominal Ethernet and padded short-length frames pass directed controls.
- Independent stimuli exercised asynchronous Ethernet timing, malformed frames,
  USB zero runs, CPU restart, memory arbitration, UART sampling, and interrupted
  mutation tests. All seven findings were reproduced against this revision.
- This is functional review evidence. It does not establish silicon timing,
  analog PHY behavior, complete protocol conformance, or physical signoff.

## Findings

### R2-1 — P1: remove the race in the DRU falling-sample capture

**Location:** [`rtl/pe_dru.v:174–175`](../../rtl/pe_dru.v), with the receiving flop
at lines 191–194. **Reproducer:** [dru_async.v](review2/dru_async.v).

The transparent-high latch uses a blocking assignment. At a rising clock edge,
the latch reopens and `rx_nq` samples it in separate active-region processes.
Their ordering can let the receiving flop take the new pin level instead of the
value held since the preceding falling edge. The prepared falling sample stream
then differs from independently recorded falling-edge samples.

A valid 1,500-byte EtherType frame with 49.995 ns half-cells, driven independently
of the DUT clock, is rejected after 155 payload bytes. It folds only 1,358 of the
expected 12,144 bits. The nominal/slower controls succeed. A sweep of 17 starting
phases, three half-cell durations (49.995/50/50.005 ns), and both filter settings
produced **34 failures in 102 trials**: every faster-wire case failed. See
[baseline-dru-sweep.log](review2/baseline-dru-sweep.log). The test clock's half-period
rounds to 8.333 ns at 1 ps simulation precision.

The committed Ethernet driver waits on DUT edges, so it cannot expose this
relative clock drift. A controlled experiment changing only the latch assignment
from `=` to `<=` in a temporary RTL copy removes the sample mismatches and accepts
the directed frame with all 12,144 folds and CRC residue `debb20e3`.

**Required correction:** make the latch/flop capture deterministic and add
independent phase/frequency coverage. The one-line experiment establishes the
simulation cause; it is not a physical timing verification or an applied fix.

### R2-2 — P1: validate the frame structure before accepting its CRC

**Location:** [`rtl/pe_eth_mac.v:513–533`](../../rtl/pe_eth_mac.v), also the
unconditional transition to `S_SETTLE` at lines 584–588.
**Reproducer:** [mac_runt.v](review2/mac_runt.v).

An invalid Manchester cell in any receive state goes to the CRC verdict, which
accepts solely on the residue. The type-frame success path then assumes four
FCS bytes were stored and subtracts four from the payload count and write pointer.
CRC residue does not prove the header/payload/FCS structure was complete.

Send a preamble/SFD, ten bytes `31 32 33 34 35 36 37 38 39 3a`, and their correct
FCS (`fb 47 c8 c6` on the wire), then idle. These fourteen bytes are consumed as
a header; the final two become EtherType `c8c6`. No payload bytes were stored,
but the receiver asserts `frame_valid`, reports **length 65,532**, moves the write
pointer to **2,044**, and increases free space to **2,052 in a 2,048-byte buffer**.
The following valid 46-byte frame ends at pointer 42 with room 2,006, confirming
that the malformed frame changes subsequent buffer accounting.

**Required correction:** require a complete frame structure and valid byte/length
bounds before asserting success or removing FCS bytes. Reject malformed frames
while restoring the exact pre-frame allocation. Include a valid-CRC runt in the
regression; truncated frames do not necessarily have an invalid CRC residue.

### R2-3 — P2: distinguish USB stuffing from CAN stuffing

**Location:** [`rtl/pe_line_codec.v:138–158`](../../rtl/pe_line_codec.v), RX run
handling at lines 169–178; USB configuration is `8'h63` in `pe_codec_mux`.
**Reproducer:** [usb_zeros.v](review2/usb_zeros.v).

`pe_bitstuff` counts identical bits of either polarity. Selecting run length six
therefore inserts/deletes a complementary bit after six zeroes as well as six
ones. USB inserts a zero only after six consecutive ones, before NRZI encoding.
See [USB 1.1 specification, §7.1.9](https://www.bitsavers.org/components/usb/USB_1.1_199809.pdf).

In the actual codec mux's USB configuration, eight valid raw zeroes become seven
received bits plus a stuffing error, while TX requests an unwanted stuffed bit
on the seventh strobe. USB's `00000001` SYNC sequence also contains this zero run.
The mux TB builds its expected stream with the same symmetric rule as the RTL;
the separate USB protocol TB implements stuffing in the testbench rather than
exercising this codec pipeline.

**Required correction:** represent the protocol's stuffing rule explicitly for
both TX and RX. Check zero runs, one runs, SYNC, and mixed data against an
independent USB wire model while retaining CAN's symmetric rule.

### R2-4 — P2: prefetch instruction zero on the first stopped clock

**Location:** [`rtl/pe_cpu.v:184`](../../rtl/pe_cpu.v).
**Reproducer:** [cpu_restart.v](review2/cpu_restart.v).

When `run` is low, `imem_addr` selects the current `pc`. On the first stopped
edge, the CPU changes PC to zero but synchronous instruction memory samples the
old address. Raising `run` after that one edge executes the stale fetched word.
There is no documented requirement to hold `run` low for two clocks.

The program `LDI A,55; LDI A,AA; JMP 2`, stopped for one clock after the two loads,
resumes at `JMP 2`: A remains `AA` and PC returns to 2. It should execute the boot
instruction `LDI A,55`. The newly corrected emulator immediately fetches word
zero when stopped, so this also leaves an RTL/emulator discrepancy.

**Required correction:** make the stopped fetch address select zero immediately,
or implement an explicit restart/prefetch contract. Test the minimum one-clock
stop with registered memory in both RTL and emulator.

### R2-5 — P2: match fallback read arbitration to the SRAM macro

**Location:** [`rtl/pe_fbuf.v:128–132`](../../rtl/pe_fbuf.v) and
[`rtl/pe_imem.v:95–97`](../../rtl/pe_imem.v).
**Reproducer:** [memory_contract.v](review2/memory_contract.v), using the real
IHP behavioral macro model alongside each fallback instance.

The macro path disables reads during writes and holds its output. Both `FLOP=1`
paths continue reading a new address during a write. In `pe_fbuf`, the lane
register is held while the word register changes, so it is not even a consistent
read of the presented byte address. Both wrappers describe their implementations
as having identical behavior.

After reading address zero containing `11`, change the read address to a word
containing `22` while writing another location. The macro retains `11`; the
fallback returns `22`. The instruction wrapper similarly returns `0011` versus
`0022`. Existing hold tests keep the read address unchanged and miss this case.

**Required correction:** align the fallback's read-enable behavior with the macro
and test changing word and lane addresses across write cycles. The demonstrated
difference is in read outputs during writes; persistent memory corruption was
not observed. It matters to the promised interchangeable simulation contract and
to future simultaneous receive/buffer-consumption integration.

### R2-6 — P2: sample UART data at the center of each bit

**Location:** [`tools/peemu.py:488–498`](../../tools/peemu.py).
**Reproducer:** [uart_monitor.py](review2/uart_monitor.py).

The TX monitor schedules its first data sample one bit period after the start
edge, at the start/data boundary. The center of data bit zero is 1.5 periods
after that edge. A slightly longer wire period therefore makes every sample
read the preceding bit, including the start bit.

An independent 8N1 waveform carrying `A5` at 521 clocks per bit is decoded as
`4A`; the same byte at 520 or 519 clocks per bit succeeds. At the project's
60 MHz clock, 521 clocks is approximately 115,163 baud. This is a small timing
change from the monitor's 520-clock assumption, not a different framing mode.
The monitor also samples its stop bit too early and can accept the last data bit
as the stop bit, undermining its use as a firmware verification oracle.

**Required correction:** anchor the first data sample at 1.5 bit periods and the
stop sample at its center. Verify the decoder independently with nearby periods,
non-palindromic bytes, and malformed stop bits.

### R2-7 — P2: restore mutated sources on interrupted test runs

**Location:** [`tb/mutate_i2c_tb.sh:145–146`](../../tb/mutate_i2c_tb.sh),
[`tb/mutate_spi_tb.sh:147–148`](../../tb/mutate_spi_tb.sh), and
[`tb/mutate_fbuf_tb.sh:153–154`](../../tb/mutate_fbuf_tb.sh).
**Reproducer:** [mutation_interrupt.py](review2/mutation_interrupt.py).

These scripts restore sources only on their normal per-case paths. Their EXIT
traps delete temporary files and pristine snapshots without restoring the source.
Interrupting a simulation leaves the current mutation in the checkout, so a
cancelled regression can change the design or firmware used by subsequent work.

In separate archived copies, the probe waits until the first mutated design has
compiled and entered simulation, then sends SIGTERM only to the process group
it created. I2C leaves `rtl/pe_pinmux.v` changed; SPI leaves `firmware/spi_xfer.pe`
and its hex image changed; fbuf leaves `rtl/pe_fbuf.v` changed. Normal completion's
snapshot comparisons do not protect these paths.

**Required correction:** restore and verify original source bytes before deleting
snapshots on exit/signals, and regenerate any affected firmware image. Exercise
interruption in isolated copies. The review probe never mutates the main checkout.

## Reproduction commands

From the repository root:

```bash
bash reviews/2026-09-22/review2/run_repros.sh
# Optional: add the 102-trial Ethernet phase/frequency/filter sweep.
bash reviews/2026-09-22/review2/run_repros.sh --sweep
```

Requirements are the existing Icarus/Python toolchain and the IHP SRAM behavioral
model located by `tb/sram_model.sh`. The interruption probe also uses `git archive`
and `tar`; it tests the committed **HEAD** scripts in temporary copies. Commit or
otherwise snapshot a proposed harness fix before using that probe to verify it.

The runner returns nonzero while findings remain. At `628e309`, its seven main
probes fail their behavioral assertions, and the separate temporary DRU
nonblocking-assignment experiment passes. See
[directed-results.log](review2/directed-results.log). A compilation failure is
reported separately and is not evidence for a finding. The earlier full-sweep log
predates the addition of fatal assertions to the archived probe; its explicit
`trials=102 failures=34` result is the evidence, not its process exit status.

## Handoff and next work

1. Fix R2-1 and R2-2 before connecting Ethernet receive to the SoC.
2. Correct the USB codec, CPU restart, and SRAM fallback contracts (R2-3–R2-5).
3. Correct the UART monitor and interruption cleanup (R2-6–R2-7); keep mutation
   work isolated until cleanup is reliable.
4. Promote the directed cases into the relevant permanent tests as fixes land,
   then run the existing full regression and the asynchronous Ethernet sweep.
5. Resume the existing integration/loader/I2C transaction backlog in
   `wiki/STATUS.md`. Physical flows remain deferred under the standing ruling.

No implementation fix was applied during this review. All seven findings are
open at the reviewed revision; the DRU experiment exists only in a temporary copy.

---

## Resolution — all seven findings fixed

Worked after the review; every fix has a permanent test, and the review's own
probe suite (`review2/run_repros.sh`) now exits 0.

| ID | Resolution | Permanent coverage |
|---|---|---|
| R2-1 | The falling-edge capture is now a TWO-latch pair: the transparent-high master closes at the falling edge, a transparent-low slave holds through the high phase, and the receiving flop takes the slave, which is closed at the rising edge — nothing left to race. | `tb_pe_eth_mac` frame 11 drives a frame with fixed 49.995 ns half-cells (independent of the DUT clock); the review sweep is **102 trials, 0 failures**. |
| R2-2 | `S_SETTLE` now requires structure as well as the residue: `hdr_done` (the 14-byte header completed), `fcs_done` for length frames, and `pay_cnt >= 4` for type frames (the four stored FCS bytes the wind-back assumes). A rejected frame restores `wptr = frame_start` and `room += pay_cnt` exactly. | `tb_pe_eth_mac` frame 10 (valid-residue 14-byte runt: rejected, `room = 2048`, `ptr = 0`); mutation `crc-only-verdict` (11/11 detected). |
| R2-3 | `pe_bitstuff` takes an explicit `ones_only` input; `pe_codec_mux` maps it to `cfg[7]` and the run length to `cfg[6:4]`. The USB configuration byte is `0xE3` (CAN stays symmetric at `0x05`). Counters saturate on non-stuffable runs. | `tb_pe_line_codec` (USB one-run stuffs; a 10-zero run neither stuffs nor errors on RX), `tb_pe_codec_mux` (`0xE1` direct TX/RX zero-run checks; `0xE3` round trip with a 12-zero run); the probe uses `0xE3`. |
| R2-4 | `imem_addr` selects zero — not `pc` — while `run` is low, so the registered ROM has `imem[0]` ready after the FIRST stopped edge. | `tb_pe_cpu` test 10: stop for one clock after `LDI 55; LDI AA; JMP 2`, resume, require A=0x55 and pc=1. |
| R2-5 | Both FLOP fallbacks gate their registered read on the write being inactive: `pe_fbuf` holds word AND lane during a write, `pe_imem` holds `imem_rdata`. | `tb_pe_fbuf` 6b and `tb_pe_imem` 3b change the read/fetch address across a write and require the old output to hold. |
| R2-6 | The TX monitor's first data sample is 1.5 bit periods after the start edge, so data and stop samples land at bit centres. | `emulate: UART monitor periods` in `run_firmware_tests.sh` decodes 8N1 A5 at 519/520/521 clocks per bit; firmware is 18/18. |
| R2-7 | I2C/SPI/fbuf traps restore the pristine sources (and the committed image) and exit 143 on INT/TERM; the eth harness trap also fires on signals. | `reviews/2026-09-22/review2/mutation_interrupt.py`: all three harnesses `changed=[]`, exit 0. |

The DRU NBA experiment is no longer needed: the two-latch capture is the
checked-in fix, and the review sweep passes without modifying the RTL.

Files changed: `rtl/pe_dru.v`, `rtl/pe_eth_mac.v`, `rtl/pe_line_codec.v`,
`rtl/pe_codec_mux.v`, `rtl/pe_cpu.v`, `rtl/pe_imem.v`, `rtl/pe_fbuf.v`,
`tools/peemu.py`, `tb/tb_pe_eth_mac.v`, `tb/tb_pe_line_codec.v`,
`tb/tb_pe_codec_mux.v`, `tb/tb_pe_cpu.v`, `tb/tb_pe_imem.v`, `tb/tb_pe_fbuf.v`,
`tb/mutate_eth_mac_tb.sh`, `tb/mutate_i2c_tb.sh`, `tb/mutate_spi_tb.sh`,
`tb/mutate_fbuf_tb.sh`, `tb/run_firmware_tests.sh`,
`wiki/reference/signal-names.md` (regenerated for the new port), and the
`usb_zeros.v` probe (new config bit).
