# Host controller acceptance checklist (plan Task 7)

The runner is `tools/host_bridge/acceptance.py`. It never synthesizes a PASS:
a step the current contract cannot observe is reported SKIP with the reason.

## Dry run (no hardware; current evidence)

```bash
python3 tools/host_bridge/acceptance.py --fake
```

Expected: `RESULT: PASS (22 PASS, 0 FAIL, 1 SKIP)`. The PASS steps cover the
`hello` clock/pads/SCLK cap, `prepare` (reset + host SPI), assembly of
`firmware/uart_echo.pe`, load plus 118-word readback, start/STATUS/heartbeat,
stop, register dump, scripted IRQ -> FAULTED -> CLEAR_FAULT, disconnect and a
fresh reconnect (session id 2), plus six R2 read-path checks
(`r2_read_cpu`, `r2_read_imem`, `r2_read_dmem`, `r2_range`,
`r2_range_fault_lifecycle`, `r2_dump_header`) that are explicitly
**not chip-confirmed** — they are the end-to-end gate the chip read path must
meet when R2 lands. Per manager ruling, a bad read latches sticky
`FAULT_RANGE` and `CLEAR_FAULT` clears it; `r2_range_fault_lifecycle` proves
that whole cycle over the session. The SKIP is `uart`: the Task 2 bridge
contract has no op that reports UART bytes, so observing `uo_out[0]` needs a
bridge op or operator scope.

## Hardware run (Pico + PE board; not yet executed)

```bash
python3 tools/host_bridge/acceptance.py --device /dev/ttyACM0 --board <rev>
```

Prerequisites: pyserial (`pip install .[host-gui]`), the bridge deployed to the
Pico (`main.py`, `pe_frame.py`, `tt_adapter.py`), the desktop user in
`dialout`/`plugdev`, the shuttle project selected, and - for readback, IRQ and
faults - the chip-side RTL phases R1/R2 (plan Tasks 3-5, under the chip-repo
manager). Record in the acceptance output:

- board revision (RP2040 vs RP2350) and the shuttle project name;
- project clock (60 MHz) and the negotiated SCLK (first-pass cap 5 MHz);
- image digest and declared word count, and the readback match;
- run/stop and STATUS timer movement (heartbeat);
- `IRQ_N` assertion -> exactly one `chip.irq` event, fault sticky until
  `CLEAR_FAULT`;
- observed UART bytes (needs the missing bridge op);
- reconnect opens a fresh session; an unreadable device reports the `dialout`
  hint instead of a traceback.
