---
title: Protocol Pin Budget
created: 2026-09-18
updated: 2026-09-18
type: reference
tags: [physical-layer, gpio, protocol, constraint]
sources: [raw/articles/tinytapeout-multiplexer.md, wiki/concepts/physical-layer-gpio.md]
confidence: high
---

# Protocol Pin Budget

How many IO pins each target protocol needs, and whether the Tiny Tapeout
pad budget covers them. Counts are per-protocol in isolation (the
interesting case — see *Worst case* below).

## The budget

| Bus | Bits | Notes |
|---|---|---|
| `ui_in` | 10 | inputs. **`u_clk` and `u_rst_n` are two of these** in the mux, so 8 are free for design use |
| `uo_out` | 8 | outputs |
| `uio` | 8 | bidirectional, each with its own output-enable (`uio_oe`) |
| **total** | **26** | of which **24** are usable (clk/rst_n are not negotiable) |

The mux doc is explicit that `u_clk`, `u_rst_n` and `ui` are all just bits
in the `pad_ui_in` bus — there is no difference internally. Only the naming
distinguishes them, which is why two input bits are spoken for.

## Per protocol

| Protocol | Tier | Pins | Wires | Board must add |
|---|---|---|---|---|
| **UART** | baseline | **2** | `tx`(out), `rx`(in) | — |
| **SPI** | baseline | **4** | `sclk`(out), `mosi`(out), `miso`(in), `cs_n`(out) | — |
| **I2C** | baseline | **2** | `scl`(bidir), `sda`(bidir) | pull-ups (board) |
| **JTAG** | also-suggested | **4** | `tck`(out), `tms`(out), `tdi`(out), `tdo`(in) | — |
| **SWD** | also-suggested | **2** | `swclk`(out), `swdio`(bidir) | — |
| **PS/2** | also-suggested | **2** | `ps2_clk`(bidir), `ps2_data`(bidir) | pull-ups (board) |
| **CAN (classic)** | also-suggested | **2** | `can_tx`(out), `can_rx`(in) | transceiver, e.g. SN65HVD230-class |
| **USB 1.1 low-speed** | stretch | **2** | `d_plus`(bidir), `d_minus`(bidir) | series resistors + pull-up |
| **10BASE-T** | stretch | **2** | `eth_tx`(out), `eth_rx`(in) | transformer / resistor ladder, or a PHY (LAN8720-class) |

### Notes per protocol

**UART** — Two independent protocols on 2 pins. Loopback (TX→RX in firmware) needs 1.  
<sub>proven by `tb_pe_uart.v`</sub>

**SPI** — Full duplex. The TB models master only; slave mode needs `sclk` and `cs_n` as INPUTS, so roles are config, not wiring.  
<sub>proven by `tb_pe_spi.v`</sub>

**I2C** — Bidirectional needs the pin-direction register (open-drain emulation); the TB models it as logic level.  
<sub>proven by `tb_pe_i2c.v`</sub>

**JTAG** — `tck` must be a GPIO output — the chip generates the debug clock. That is why the TAP lives on `uio`.  
<sub>proven by `tb_pe_jtag.v`</sub>

**SWD** — `swdio` is bidirectional with a turnaround phase (the TB models `host_drives`); `swclk` is chip-driven in the TB but is an input in a real target.  
<sub>proven by `tb_pe_swd.v`</sub>

**PS/2** — Open-drain on both lines — the device may hold the clock low (inhibit). Same OE trick as I2C.  
<sub>proven by `tb_pe_ps2.v`</sub>

**CAN (classic)** — Two pins are enough because the differential layer is the transceiver's job. The TB models only `can_rx` (it stands in for the wire).  
<sub>proven by `tb_pe_can.v`</sub>

**USB 1.1 low-speed** — D+/D- driven as two single-ended CMOS outputs. Idle state is FS-only (D- pulled up); a real LS device needs the 1.5 kΩ pull-up on D-. SE0 (both low) and J/K are directly expressible — see the TB.  
<sub>proven by `tb_pe_usb.v`</sub>

**10BASE-T** — Manchester is single-ended here, so 2 pins carry it; the ±2.5 V differential into 100 Ω is the board's problem, not the pad's. The TB models one `wire_lvl`.  
<sub>proven by `tb_pe_eth.v`</sub>

## The answer

- **Any single protocol: 4 pins maximum** (SPI), out of 24 usable. The budget is not the constraint.
- **All nine at once: ~20 pins of 24 usable** if every wire is pinned out. Still fits — but see below, because that is the wrong way to build it.

### Worst case — and why it does not happen

The naive reading is "pin every protocol out permanently", which needs roughly:

| Group | Pins |
|---|---|
| UART + SPI (7 wires) | 7 |
| I2C + PS/2 (4 bidirectional) | 4 |
| JTAG + SWD (6 wires) | 6 |
| CAN + USB + ETH (6 wires) | 6 |
| **sum** | 23 |

That is 23 of 24 — technically inside the budget and completely the wrong
design. **The whole premise of the project is that protocols are firmware,
not pin assignments.** A programmable pin matrix means a protocol claims
pins at *runtime*:

- Only one or two protocols are live at a time, chosen by firmware.
- `uio` pins are bidirectional with per-pin output-enable, so a single pin
  serves I2C SDA, PS/2 DATA, SWDIO and USB D+ depending on what is running.
- Concurrent protocols need disjoint pins, and *that* is a firmware/placement
  decision, not an RTL one — the matrix just has to be flexible enough.

So the real constraint is not "24 pins or 23 pins" but **how many protocols
must run simultaneously**. Two (e.g. UART console + SPI target) is trivial;
a bus-converter persona running four at once is the case worth designing the
matrix around.

## Pins are not the hard part

Everything above counts digital wires. The genuinely awkward items are
electrical, and they are on the board:

- **Open-drain** (I2C, PS/2) needs external pull-ups *and* the chip must
  never drive high — output-enable toggling only. Getting this wrong is a
  bus-contention bug, not a pin-count one.
- **USB LS** needs the 1.5 kΩ pull-up on D- to look like a device, and
  series resistors for impedance.
- **10BASE-T** needs a transformer or PHY; true ±2.5 V differential into
  100 Ω cannot come from a GPIO. See [[concepts/physical-layer-gpio]].
- **CAN** needs a transceiver; the chip only sees logic-level TX/RX.

See [[concepts/gpio-signoff-corners]] for the rise/fall asymmetry that
thins these pulses at skewed corners.

## Related

- [[concepts/physical-layer-gpio]] — what each protocol needs electrically.
- [[reference/signal-names]] — the RTL port list.
- [[concepts/competition-overview]] — the 8×4 tile budget this sits inside.
- [[STATUS]] — what is actually built.
