# pe_ctrl review — 2026-09-23

**Reviewed:** `rtl/pe_ctrl.v` at `39c0eb4`, its unit test `tb/tb_pe_ctrl.v`,
and wrapper integration in `rtl/tt_um_protocol_emulator.v`.

## P1 — run can rise while a queued word still writes instruction memory

`pe_ctrl` documents and claims that every receive and write path is gated by
`run`. Receive shifting is gated, and `W_IDLE` will only start a write while
`run == 0`, but `W_PULSE` unconditionally raises `we_r`. If `run` rises after
`word_ready` has moved the state machine into `W_PULSE`, the next host write
still occurs while the core is running. The existing unit test only raises
`run` before it starts a load, so it does not exercise this boundary.

### Reproduction

An isolated Icarus test sent one complete `16'hA55A` word, waited until
`dut.wstate == W_PULSE`, then raised `run` before the next `clk` edge. A
host-port monitor counted write pulses and pulses sampled while `run` was high.
Observed:

```
writes=1 writes_while_run=1 error=0
```

Thus the instruction-memory host port can be written during execution if the
run strap changes in this one-cycle pipeline window. The throwaway test is at
`/tmp/tb_pe_ctrl_run_race.v`; it is intentionally not part of the repository.

### Required correction

Define and enforce the behavior when `run` rises during an active/queued load.
At minimum, `host_we` must never be accepted while `run` is high, and a queued
write must not silently reappear later as stale program data. Add a permanent
unit test that raises `run` after word reception but before the host-port write
is sampled, and assert that no write is accepted while the core runs.

## Coverage noted

- The current unit TB covers mode-0, MSB-first ordering, sequential addresses,
  CS restart, partial-word error, reload, a load attempted while already
  running, and overflow.
- The TT-level wrapper TB demonstrates a program loaded through the pads and
  executed after `run` rises.
- The transition race above is a distinct functional edge case and was not
  covered by those tests.

No physical flow, DRC or LVS was run.

## Regression gate — initial Verilator lint failure corrected

The initial full-run log (`/tmp/run_all_pe_ctrl.log`) reported **28/28 RTL
testbenches pass** and **19/19 firmware tests pass**, but `regress/lint.sh`
failed for both `pe_ctrl` and `tt_um_protocol_emulator` because
`rtl/pe_ctrl.v:101` leaves `shreg[15]` unused. The same warning appears in the
standalone and wrapper lint tops. Since the project gate accepts no warnings,
the full regression is not green until the shift register width/use is
corrected by making `shreg` 15 bits. The subsequent standalone
`./regress/lint.sh` run passes cleanly. A repeated full regression completed
green: **28/28 RTL**, **19/19 firmware**, clean lint/elaboration, generated-doc
checks and all five mutation gates. See `/tmp/run_all_pe_ctrl2.log` for full
output.

### Run-transition race resolution recheck

**Fixed at `ef4041d`.** `host_we` is now masked by `run`, and the write FSM
discards and flags a queued word if `run` rises before the host write is
accepted. The permanent `tb_pe_ctrl` case raises `run` in the W_PULSE window,
checks that the word is not written or counted, checks `load_error`, then drops
`run` and verifies the stale word does not reappear.

I independently confirmed the permanent regression distinguishes the fix:
the new `tb_pe_ctrl` passes against the current RTL, while running the same TB
against archived `39c0eb4` reports six run-race assertion failures (write
while running, count/flag errors, and stale reappearance). My original
standalone reproduction against the fixed design also observes zero writes;
the zero-write result is expected, so its old “must reproduce” assertion
trips. Standalone lint is clean. The mutation guard and full post-fix
regression were still being added/run at this review update.

## Preliminary synthesis and STA screen

Mapped the fixed `pe_ctrl` RTL to the installed sg13g2 typical standard-cell
library. Yosys `check -assert` found **0 problems**; the mapped logic area is
about **5,791.1 µm²**. OpenSTA linked the mapped top at fast, typical and slow
standard-cell corners. Under a 16.667 ns core clock, 1.0 ns setup / 0.25 ns
hold uncertainty, 3.3334 ns max and 0 ns min input/output delays for the
synchronous `run`/reset and output assumptions, the worst setup slack is
positive (**+8.71 ns**, slow corner). The `run` input hold screen is negative
at all three corners: **−0.19 ns** fast, **−0.16 ns** typical, **−0.12 ns**
slow under the 0 ns minimum input-delay assumption. Several unplaced
high-fanout nets also exceed library fanout limits.

The asynchronous SPI inputs were false-pathed as synchronizer inputs, and STA
reports their first-stage endpoints unconstrained, as expected for this
screen; synchronizer MTBF and physical repair are not established. These are
pre-layout checks, not hardening signoff. Scripts and full logs are in
[`pe-ctrl-hardening/`](pe-ctrl-hardening/). No physical flow, DRC or LVS ran.
