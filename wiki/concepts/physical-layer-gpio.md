---
title: Physical Layer via GPIO
created: 2026-09-17
updated: 2026-09-18
type: concept
tags: [physical-layer, gpio, protocol, constraint]
sources: [raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: medium
---

# Physical Layer via GPIO

Tiles reach the outside world through standard digital IO cells (3.3 V IO domain on the breakout board, ~1.2 V core). So the physical layer is restricted to GPIO state changes: drive high, drive low, high-Z/input. The contest is timing precision and state-machine flexibility, not PHY synthesis — voltage/differential conversion happens in passives or external transceivers on the dev board.

Pin counts per protocol (how many pads each needs, and whether the TT budget
covers all of them at once): [[reference/protocol-pin-budget]].

## Native CMOS-swing protocols

- UART, SPI, JTAG, SWD: direct digital IO.
- I2C and PS/2: emulate open-drain by toggling the pin-direction (output-enable) register between drive-low and high-Z, with external pull-ups.
- CAN (controller level): emit logic-level CAN-TX / accept CAN-RX; an external transceiver (e.g. SN65HVD230-class) does the differential Vdiff conversion.

## Stretch goals need workarounds

- Low-speed USB 1.1 (1.5 Mbps): 3.3 V levels match the IO rail. D+/D- are driven as two single-ended CMOS outputs (plus series resistors for impedance matching); single-ended states like SE0 are directly expressible.
- 10BASE-T: true differential Manchester at ~+/-2.5 V into 100 ohms cannot come from a GPIO. Drive digital Manchester out to an external network (resistor ladder/transformer) or external PHY (ENC28J60/LAN8720-class). On receive, see [[concepts/cdr-oversampling]].
- GPIO rise/fall asymmetry at skewed corners thins these pulses; see [[concepts/gpio-signoff-corners]] for the FS/SF analysis plan.
