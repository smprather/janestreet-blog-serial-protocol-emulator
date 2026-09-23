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

**Fixed in `ef4041d`; test coverage corrected and fully verified at `e448c09`.**
`host_we` is masked by `run`, and the write FSM discards and flags a queued
word if `run` rises before the host write is accepted. The permanent
`tb_pe_ctrl` test exercises three transitions: `run` rising in W_PULSE (the
original finding), while a word is queued in W_IDLE, and at W_DONE sampling.
It checks no write while running, no count, `load_error`, and no stale write
after `run` falls.

Independent comparison confirms the regression distinguishes the fix. The
final `tb_pe_ctrl` passes on the fixed RTL and fails on archived pre-fix
`39c0eb4`. I caught a gap in the first version of case 7b: it raised CS_N
before dropping `run`, which cleared `word_ready` and masked the late-write
behavior. At `e448c09`, case 7b keeps CS_N low through `run` falling, waits 16
clocks, verifies no write, then raises CS_N. Running that corrected TB against
`39c0eb4` independently shows the queued word is written after `run` falls;
the fixed RTL passes. Full explanation is in
[the pe_ctrl resolution](PE-CTRL-RESOLUTION.md).

The new mutation suite detects **11/11** injected faults, including the
W_IDLE abort, host write mask, W_DONE accounting, and original protocol cases.
The post-fix full regression at `e448c09` passes **28/28 RTL** and **19/19
firmware** tests, clean lint/elaboration, all six mutation suites, macro-flow
configuration, and generated-doc gates; see `/tmp/run_all_pe_ctrl4.log`.

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

## Readback path evaluation (2026-09-23)

v1 remains write-only by decision (ADR-007). The host/pad mapping for a MISO
response is feasible -- `uio[4]`, driven only while the loader is active -- but
the interface is still an open choice between echoing the completed word, a
status frame (`load_error`/`words_written`), and an imem peek/poke that would
need a read port.

**Timing audit of the echo option (derived from `rtl/pe_ctrl.v`, worst-case
SCLK phase).** Two independent paths set the readback rate. (1) *Per-bit MISO
update*: the synchronizer, edge detector and register put a falling-edge
update ~3 clk (50 ns) plus pad and host setup after the fall, while the host's
next rising sample is one half period later -- at 10 MHz that is also 3 clk, so
a registered falling-edge update cannot meet setup at *any* frame latency.
Computed limit ~7.7 MHz (3 clk + ~5 ns pad + ~10 ns host setup); **A2's
two-frame echo only relaxes the commit path and reaches ~7.7 MHz, not 10 MHz**
(documented 5 MHz). (2) *Echo commit*: the write commits and `W_DONE` runs at
+5..6 clk (83-100 ns); because the echo must be commit-latched (never
`word_ready`; aborted words must never echo), a one-frame echo needs a half
period >= 6 clk -- **computed limit 5.0 MHz, documented 2.5 MHz (2x margin)**.
Combined: A1 = min(5.0, 7.7) = 5.0 MHz; A2 = 7.7 MHz. Reaching 10 MHz needs a
different implementation -- A3, updating MISO on the synchronized **rising**
edge (next sample a full period later: `T >= 3 clk + pad + setup` ≈ 65 ns)
with a two-frame echo, and a documented non-mode-0 change edge. Test
requirements: host SCLK phase sweep at each ceiling, per-bit setup checks,
commit-latch probes, aborted-word-no-echo, one- vs two-frame latency; see
[[plans/pe-ctrl-readback]].

The budget delta (one free `uio`; shortfall 9 -> 10 kept / 3 -> 4 reclaimed) and
the pad mapping remain in [[plans/pe-ctrl-readback]]. No RTL changed; no new
regression or STA was run.
