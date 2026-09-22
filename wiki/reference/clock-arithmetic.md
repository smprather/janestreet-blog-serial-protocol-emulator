---
title: "Clock arithmetic at 60 MHz"
created: 2026-09-22
updated: 2026-09-22
type: reference
tags: [clocking, protocol, reference, verification]
sources: [rtl/pe_uart_soc.v, wiki/decisions/adr-005-60mhz-turbo.md]
confidence: high
---

# Clock arithmetic at 60 MHz

> **Generated** by `tools/gen_clock_arithmetic.py` from `rtl/pe_uart_soc.v`.
> `CLK_HZ` is read from the RTL, not restated here — if the RTL's clock
> changes and this page is not regenerated, `--check` fails.

The operating point is **locked at 60 MHz**. It is a `localparam` in
`pe_uart_soc`, not a parameter: nothing ever instantiated the SoC at any
other rate, so the parameter was a second place for the arithmetic to be
wrong rather than a knob (see the header of `rtl/pe_uart_soc.v`).

    CLK_HZ   = 60,000,000 Hz
    period   = 16.667 ns

## What 60 MHz makes exact

| protocol constant | ns | ticks | exact? |
|---|---|---|---|
| 10BASE-T half-UI | 50.000 | 3.000 | **EXACT** |
| 10BASE-T bit time | 100.000 | 6.000 | **EXACT** |
| USB full-speed bit | 83.333 | 5.000 | **EXACT** |
| USB low-speed bit | 666.667 | 40.000 | **EXACT** |
| I2C Standard-mode 1 us tick | 1000.000 | 60.000 | **EXACT** |
| I2C Fast-mode 0.5 us tick | 500.000 | 30.000 | **EXACT** |
| SPI SCK (10 MHz target) | 100.000 | 6.000 | **EXACT** |
| UART 115200 half-bit | 4340.278 | 260.417 | approx |

Every row marked EXACT is a protocol requirement that lands on an integer
clock count. That is the property that chose 60 MHz, and the reason a
different rate cannot be substituted without re-doing the protocol
timing (ADR-005).

## Derived constants in the RTL

| constant | expression | value |
|---|---|---|
| `SPB` (DRU samples/bit, dual-edge) | `2 * CLK_HZ / 10 Mbps` | **12** |
| `TICKS_PER_BIT` (UART half-bit timer) | `CLK_HZ / BAUD / 2` | **260** |
| `CNTW` (timer counter width) | `$clog2(TICKS_PER_BIT)` | **9** |
| I2C microsecond tick (plan step 5) | `CLK_HZ / 1e6` | **60** |

Delivered UART baud: `60000000 / (260 * 2)` = **115,384.6** (+0.160%).

## What is NOT exact, and why that is acceptable

| protocol | error | why it is fine |
|---|---|---|
| UART 115200 | +0.160% baud error | The only protocol constant at 60 MHz that is an approximation. Inside the ~2% UART budget, and half the error the 40 MHz point had (+0.353%). |

The distinction matters for the competition's timing emphasis: a protocol
that must be *bit-exact* (10BASE-T, USB) has an integer tick at 60 MHz, and
one that tolerates a few percent (UART, ±2-4%) does not need one.

## The retired 66 MHz signoff target

Blocks used to be signed off at `CLOCK_PERIOD` 15.15 ns = 66 MHz (the
pad-macro ceiling) on the reasoning that closing at 66 and running at 60
leaves free margin. **That target is retired.** It made every reported
slack number require a conversion by the reader, and a longer period is
strictly easier for setup — so a design that closes at 66 has already
closed at 60, and saying so directly is the clearer statement.

Both flow configs now carry `CLOCK_PERIOD` 16.667 ns, so the number in the
STA report IS the operating point.

## Related

- [[decisions/adr-005-60mhz-turbo.md]] — why 60 and not 40 or 66.
- [[concepts/tx-timing-generation.md]] — the jitter proof against 66.
- [[concepts/cdr-oversampling.md]] — the SPB grid this arithmetic feeds.
- [[plans/through-i2c.md]] — the I2C tick plan that uses the 60-clock µs.
- [[STATUS]] — the timing margin actually measured at this point.
