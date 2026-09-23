---
title: SPI Pads (MOSI and CS_N on uio[2:3])
created: 2026-09-23
updated: 2026-09-23
type: plan
tags: [spi, pinout, wrapper, physical-layer, status]
sources: [wiki/reference/protocol-pin-budget.md, wiki/decisions/adr-006-pin-matrix.md]
confidence: high
---

# SPI pads: MOSI on uio[2], CS_N on uio[3]

## The gap

The SPI firmware (`firmware/spi_xfer.pe`) drives port bits 0-2 and reads bit 3
on the SoC's 8-bit pin port (`PIN_IN_MASK = 8'hF8`). The wrapper only routes
port bit 0 (`uo_out[0]`, shared with UART TX) and input bit 3 (`ui_in[0]`,
shared with UART RX). MOSI (bit 1) and CS_N (bit 2) are outputs with **no pad**
-- the SPI persona runs in simulation but cannot be wired on silicon.

## The mapping

| SPI wire | Port bit | Pad | Why |
|---|---|---|---|
| SCLK | 0 out | `uo_out[0]` | already there (UART TX pad; one firmware at a time, so the port-bit sharing is deliberate) |
| MOSI | 1 out | **`uio[2]`** | new: `uio_out[2] = pin_out_bus[1]`, `uio_oe[2] = pin_oe_bus[1]` |
| CS_N | 2 out | **`uio[3]`** | new: `uio_out[3] = pin_out_bus[2]`, `uio_oe[3] = pin_oe_bus[2]` |
| MISO | 3 in | `ui_in[0]` | already there (UART RX pad; `pin_in_bus[3] = ui_in[0]` is a hardwire) |
| -- | -- | `uio[7:4]` | stay released (`oe = 0`) |

Only two pads are added. The matrix keeps ownership of the drive enable: the
per-pin `pin_oe_bus[1]`/`[2]` gates `uio_oe[2]`/`[3]`, so a firmware that
releases bits 1/2 releases the pads, exactly like the I2C pair on uio[0:1].

## Alternatives considered and rejected

- **Mirror SCLK onto a `uio` pad.** `uo_out[0] = pin_out_bus[0]` is
  unconditional, so mapping bit 0 to `uio[2]` as well would put the same SCLK
  on two pads. `uo_out[0]` is also UART TX and cannot be dropped. Rejected: one
  pad per port bit, no duplicates.
- **Dedicated MISO on `uio[4]`.** `pin_in_bus[3] = ui_in[0]` is a hardwire;
  there is no input mux or mode selector in the wrapper. A dedicated MISO would
  need a new route (the free bit 6, `pin_in_bus[6]`) *plus* a firmware pin
  contract change (MISO bit 3 -> 6) and re-verification of the emulator/TB.
  It also spends a scarce `uio` pad on an input when the dedicated `ui_in` bank
  has the pad already, against the direction-aware rule in
  `wiki/reference/protocol-pin-budget.md`. Rejected: keep the shared bit 3.

## Reset state

The matrix reset marks bits 0-2 as outputs, so `uio[2]`/`uio[3]` are driven low
out of reset (MOSI low, CS_N low) until the SPI firmware's first `OUT` raises
CS_N and states the idle pattern. This is the SoC's documented "outputs low"
rule, not a new glitch; a mode-0 slave armed on a falling edge of CS_N sees no
edge (the line starts low, exactly as `tb_pe_soc_spi.v` documents at the SoC
level). Outside the SPI persona the two pads follow whatever the running
firmware puts on bits 1/2 -- low under the current UART/I2C images, same as any
unclaimed output.

## Budget impact

Committed pads go 16 -> 18 of 24; free `uio` 6 -> 4 (`uio[7:4]`). SPI's MOSI
and CS_N become pinned wires, so the remaining all-nine demand drops to 7 out /
3 in / 5 bidir. The shortfalls recomputed by `tools/gen/pin_budget.py`:
9 (debug kept) / 3 (debug reclaimed), direction mix updated on the page. The
debug pins and the I2C pair are untouched.

## Verification

1. `tb/tb_tt_um_protocol_emulator.v` gains a pin-level SPI phase: load
   `firmware/spi_xfer.hex` through the loader pads, then model a mode-0 slave
   on the *pads* -- SCLK = `uo_out[0]`, MOSI = `uio_out[2]` gated by
   `uio_oe[2]`, CS_N = `uio_out[3]` gated by `uio_oe[3]`, MISO driving
   `ui_in[0]` -- and check the same contract as `tb_pe_soc_spi.v`: 8 frames,
   0x5B captured per frame, exactly 8 clocks per CS_N frame, and the firmware's
   rolling buffer (`dut.u_soc.dmem[0..7]`) holds A7 E5 96 C1 3D 7B D2 4F.
   Alias checks: `uio_out[2] === pin_out_bus[1]`, `uio_out[3] ===
   pin_out_bus[2]`, `pin_in_bus[3] === ui_in[0]`, `uo_out[0] ===
   pin_out_bus[0]`.
2. The TB's "unclaimed pin" monitors narrow from `uio[7:2]` to `uio[7:4]`;
   `uio_oe[3:2]` must be driven during the SPI run.
3. Mutation probes, one per new output, all four recompiled and run (each must
   fail the pad-level phase, so neither route has a silent twin): MOSI source ->
   bit 0 (SCLK); `uio_oe[2]` forced low; CS_N source -> bit 1 (MOSI);
   `uio_oe[3]` forced low. Restore from a saved copy and confirm `git diff`
   matches the intended change.
4. Full `regress/run_all.sh`, `regress/lint.sh`, and the allowed
   synthesis-area screen for the wrapper change. No physical flow/DRC/LVS.

## Verification results (2026-09-23)

- `regress/run_all.sh --fast -j8`: RTL **29/29**, firmware **20/20**, param
  guards OK, `regress/lint.sh` clean (including the wrapper), every
  generated-doc/macro-flow gate current, and all seven mutation suites OK
  (i2c, spi, fbuf, eth_mac, eth_soc, ctrl, i2c_xfer). Log:
  `/tmp/run_all_spi_pads.log`.
- Pad-level TB: PASS, and all four probes fail it -- MOSI source -> bit 0
  (captured `00`), `uio_oe[2]` low (captured `00`), CS_N source -> bit 1
  (1 clock per frame), `uio_oe[3]` low (no frame, watchdog). The wrapper was
  restored byte-identically after each probe.
- `regress/synth_area.sh` (rc 0, no diagnostics): `tt_um_top` **3613 cells /
  59,547.852 um2**. Synthesising the HEAD wrapper and this one with the same
  RTL list and script gives **byte-identical `stat -liberty` output** apart
  from the log path/hash: the change adds **zero gates and zero state**. It is
  two continuous assignments from the pin-matrix registers to pads, the same
  startpoint/endpoint class as the existing `uo_out[0]`/`uio[0:1]` aliases, so
  no sequential timing path is added and there is nothing new for OpenSTA to
  sign off. No wrapper-level SDC exists (`flow/pe_soc.sdc` constrains the
  pe_soc core, not the TT pads); the recorded STA screens cover pe_ctrl/E1/E2.
  No physical flow/DRC/LVS was run.
