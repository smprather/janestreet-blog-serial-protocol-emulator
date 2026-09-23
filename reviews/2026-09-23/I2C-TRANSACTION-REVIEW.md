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

## Open protocol limits

These do not invalidate the tested ACK-success transaction. They limit what the
current firmware can claim to support and should stay visible in the backlog.

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

## Regression notes

The new RTL TB's `$readmemh` warns that the 267-word image does not fill its
1,024-word array. It initializes the remaining program array to a NOP before
loading the image and passes; the warning is harmless, though suppressing it
would make future build output easier to scan.

The review also found that the mutation script's per-simulation log initially
shared `/tmp/mutate_i2c_xfer.log` with `run_all.sh`'s capture of the script's
stdout. I changed the per-simulation output to
`/tmp/mutate_i2c_xfer_case.log`; the isolated 7/7 mutation run passed again
after that change. The full regression was not rerun for this log-path-only
adjustment.
