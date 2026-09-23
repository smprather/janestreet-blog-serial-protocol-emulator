# I²C Transaction Review — 2026-09-23

## Scope and result

Reviewed commit `56ba1a9` and its base firmware/emulator commit `e9b37b1`.
The fixed success path is implemented and independently verified: START,
write address `0xA0`, write `0xA5`, repeated START, read address `0xA1`, read
`0x5A`, master NACK, STOP. No defect was found in that tested path.

The verification evidence is:

- `python3 tools/checks/i2c_xfer_check.py`: PASS for all 60 timer phases;
  decoded bytes and dmem observables match, and tLOW/tHIGH/period floors pass.
- `tb/tb_pe_soc_i2c_xfer.v`: independently compiled and run against the SRAM
  model; PASS, with measured pad minima of 6.000 µs low and 5.983 µs high.
- `regress/mutate_i2c_xfer_tb.sh`: rerun in isolation after the full regression;
  baseline passes, all 7 mutations detected, 0 survived, and both firmware
  source and image restore checks pass.
- Pi's `./regress/run_all.sh --fast -j8`: reported rc 0, 29/29 RTL
  testbenches, 20/20 firmware tests, lint clean, seven mutation suites, and
  generated-document/macro-flow gates passing.

No RTL changed in this milestone, so the existing synthesis/STA screens remain
the current hardening evidence. No physical flow, DRC, or LVS was run.

## Open protocol limits (original review — since closed)

These were the limits of the fixed transaction at `56ba1a9`. They are kept as
the historical baseline; the resolution below supersedes them.

1. **Arbitration loss is counted but the transfer continues.** In
   [the send engine](../../firmware/i2c_xfer.pe), SDA-low while transmitting a
   released `1` increments `dmem[7]`, then the byte engine continues shifting
   and later sends the remaining transaction. The RTL TB explicitly expects
   completion after its contention stimulus. This demonstrates detection, not
   compliant multi-master arbitration. A losing master should release the bus
   and wait for the winning transaction to finish before retrying.

2. **Unexpected ACK-slot NACKs are recorded without recovery.** The firmware
   stores ACK samples in `dmem[0..2]` but dispatches to the next state regardless
   of the value. The emulator model accepts NACK configuration, but the checker
   and RTL TB exercise only ACK-success for address/data bytes. The plan's review
   focus asks for a defined read-address NACK path and a data NACK that records
   the result and stops; neither negative path is verified.

3. **Clock stretching is not handled in the transaction loop.** The firmware
   times SCL high after releasing it and does not wait for pad read-back. The
   handoff records this as excluded from v1, while
   [`through-i2c.md`](../../wiki/plans/through-i2c.md) says to include stretching
   and explains the required read-back loop. Keep the v1 narrowing explicit or
   add SCL-stretch coverage before claiming support for stretching slaves.

These are scope/behavior gaps rather than failures in the fixed transaction.
The review does not silently treat them as supported by the pin-matrix
capability or by the happy-path tests.

## Resolution (2026-09-23)

All three limits are closed, with tests on both models. What is **not** added is
a retry path: an abort releases the bus and parks with an outcome code, and
there is no STOP-qualified bus-free detector.

1. **Arbitration loss** now releases both lines immediately, sets outcome
   `dmem[6]=1` and `dmem[5]=0x55`, and never issues a STOP. The RTL TB's
   contention case asserts the master generated no STOP and recorded no
   complete address/data byte; its stimulus is **transient contention** and
   does not model a winner's continuing clocks or STOP. The emulator checker
   adds a transient-contention arbitration case across all 60 phases
   (`run_arb_phase`; the firmware's dmem and drive state are the contract,
   because the source's own pull/release are wire-visible conditions).
2. **Unexpected NACKs** now map to outcome 2/3/4, issue a STOP and abort. The
   checker runs all three negative cases across all 60 phases; the RTL TB runs
   all three.
3. **Clock stretching** is waited on: the firmware polls SCL after every
   release before timing tHIGH. Both slave models hold SCL low and both tests
   assert the floors still pass.

The earlier single-sample "wait for both lines high" arbitration idle check was
removed rather than fixed: one both-high sample cannot distinguish idle from a
winner's data-1 high phase. A correct STOP-qualified detector (observe a STOP
edge, then tBUF) belongs with a retry policy, which is not implemented.

Evidence: `tools/checks/i2c_xfer_check.py` (5 cases + arbitration, 60 phases),
`tb/tb_pe_soc_i2c_xfer.v` (6 runs), `regress/mutate_i2c_xfer_tb.sh` (11/11).
No physical flow, DRC or LVS was run.

## Regression notes (historical, at `56ba1a9`)

The new RTL TB's `$readmemh` warned that the then-267-word image did not fill
its 1,024-word array. The TB initializes the remaining program array to a NOP
before loading and passed; the warning is harmless, though suppressing it would
make future build output easier to scan. (The image is 311 words now; the
warning is unchanged in kind.)

The review also found that the mutation script's per-simulation log initially
shared `/tmp/mutate_i2c_xfer.log` with `run_all.sh`'s capture of the script's
stdout. The per-simulation output is now `/tmp/mutate_i2c_xfer_case.log`; the
isolated 7/7 mutation run passed again after that change. The full regression
was not rerun for that log-path-only adjustment.

## Current verification (2026-09-23, after the gap fixes)

`./regress/run_all.sh --fast -j8` exit 0: **firmware 20/20, RTL 29/29**, param
guards OK, lint clean, every generated-doc/macro-flow gate current (signal
glossary, pin budget, SRAM budget, floorplan feasibility, macro-flow config, CRC
config, clock arithmetic, block diagram, rendered diagrams, canvas viewer, I2C
pin timing), the I2C transaction checker passing, and **all seven mutation
gates OK** (i2c, spi, fbuf, eth_mac, eth_soc, ctrl, i2c_xfer). Log:
`/tmp/run_all_i2c_v3.log`.

An independent restore of the `TYPE_MIN` mutant in `rtl/pe_eth_mac.v` happened
while a regression may have been active. The source is clean now (`git diff`
empty), and after the restore `regress/mutate_eth_mac_tb.sh` was rerun
standalone: **16 detected, 0 survived**, source verified pristine. The full
rerun also started from a pristine tree and reports the eth_mac suite green.
