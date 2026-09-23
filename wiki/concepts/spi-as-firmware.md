---
title: SPI as firmware — mode 0 on the shared port
created: 2026-09-22
updated: 2026-09-22
type: concept
tags: [protocol, architecture, verification]
sources: [rtl/pe_soc.v, firmware/spi_xfer.pe, tools/fw/peemu.py]
confidence: high
---

# SPI as firmware

There is no SPI hardware in this chip. `firmware/spi_xfer.pe` is a **mode 0
(CPOL=0, CPHA=0) SPI master** implemented entirely in `pe_cpu` software: SCLK
and MOSI are driven by read-modify-write on the output port, MISO is read from
the input port, and the frame is a loop.

SPI is the second of the competition blog's baseline protocols ("UART, SPI, and
I2C"); see [[concepts/competition-overview]]. UART came first
(`firmware/uart_echo.pe`) and I2C is next — [[plans/through-i2c]] is the plan
that ordered them.

## Why SPI needed a port change and I2C will need more

UART needs one input pin and one output pin. SPI needs **three outputs** (SCLK,
MOSI, CS_N) and one input (MISO). The SoC's port was a single bit, so before any
SPI firmware could exist the port had to become a multi-bit one.

That change is in `rtl/pe_soc.v`, and the rule it settled on is stated
there in full: **outputs low, inputs high**. Outputs start at bit 0; inputs are
the contiguous high run; the build-time parameter `PIN_IN_MASK` (currently
`8'hF8`) records where the split falls. The shared UART/SPI map is:

| bit | out | in |
|-----|-----|----|
| 0 | UART TX | SPI SCLK |
| 1 | (spare) | SPI MOSI |
| 2 | (spare) | SPI CS_N |
| 3 | — | UART RX / SPI MISO |

**One port, one mask, two protocols.** Nothing in the RTL knows which protocol
is running; the difference is entirely the program. That is the thesis of the
project showing up in the pin map, and it is why the SPI firmware lives in the
same SoC as the UART one rather than needing a mode select.

Bit 3 is ONE pad. In UART mode a host drives it; in SPI mode the slave does.
`tools/fw/peemu.py` models it as a single wire level for exactly that reason (see
Testing below) — two separate levels could disagree with each other, which is
the class of bug the emulator exists to catch.

**SPI is push-pull on dedicated pins, so it needs NO pin matrix.** I2C, being
open-drain and multi-drop, does — and it needs the direction to change at
runtime, which this build-time mask deliberately does not do. The pin matrix
ADR is still unwritten ([[plans/through-i2c]] open questions).

## Mode 0 is the mode software likes

| | |
|---|---|
| SCLK idle | low |
| MOSI valid | **before** the rising edge |
| slave samples MOSI | on the **rising** edge |
| master samples MISO | on/just after the **rising** edge |
| slave changes MISO | on the **falling** edge |

So the loop is: set MOSI while SCLK is low, raise SCLK, sample MISO, lower SCLK,
next bit. One pin change and one sample per half period, and **no edge is ever
shared between driving and sampling** — which is exactly what would need real
hardware. Mode 0 is what makes a fully-software master possible; the other three
modes put a drive and a sample on the same edge.

Because SPI is **synchronous**, the slave times itself off our SCLK. There is no
baud rate to hit and no jitter budget to spend — unlike the UART, whose receiver
free-runs and therefore cares about the master's clock accuracy to a fraction of
a bit. The firmware's clock rate is set by the same shared tick counter
`uart_echo.pe` uses (260 clocks at 60 MHz), giving an SCK of ~115 kHz. The
**duty-cycle jitter costs nothing here** and that is worth stating plainly: the
tick wait returns after anywhere in (0, 1] ticks, so the half period varies
between ~1 and ~2 ticks. For a UART receiver that would be fatal; for a
synchronous slave it is invisible.

## The bit-order asymmetry is the interesting part

**The UART is LSB-first. SPI is MSB-first.** The ISA has `SHR` and no
shift-left, so `uart_echo.pe`'s receive loop (shift the accumulator right,
insert at the top) is exactly backwards for SPI. Two consequences:

- **Sending** bit 7: test with `AND 0x80`, then shift the working copy **left**.
- **Receiving** into bit 7 after 8 bits: shift the accumulator left the same way
  and OR the new bit in at bit 0.

Shift-left is `MOV X, A ; ADD A, X` — A + A. Register-register `ADD` is not in
the ISA and `tools/fw/peasm.py` rejects it, but **X is addressable as the ALU's
second operand** (operand bit 9), which is why this is two instructions and not
one. That was already true for the timer-delta idiom; SPI is the first place it
is used for arithmetic rather than address bookkeeping.

## The reset-value trap

`pin_out` resets to `8'h01`, which is bit 0 high — the **UART TX idle level**.
For SPI that is **SCLK high**, an active-edge level, not an idle one. And bit 2
(CS_N) is low out of reset, so **CS_N is asserted for the first few cycles of
every power-up**.

Neither is a firmware bug, and the CS_N case is not harmless by accident: a
mode-0 slave changes state only on SCLK edges, and there are none in that
window, so nothing shifts. The firmware therefore **states its idle pattern as
its first instruction** rather than assuming the reset value is the SPI idle
state. Any second protocol on this port inherits the same rule.

## Testing: a master with no slave is not a protocol

`tb_pe_spi.v` already existed, but it exercises **`pe_serdes`** — a different SPI
that shifts under hardware `bit_en` strobes. The firmware master talks to the
port, so it needed a different counterpart: `tools/fw/peemu.py` now models a mode-0
slave (`poll_spi_slave`), and `--spi-slave` selects that wire model instead of
the UART one.

Both directions are checked, and they are **independent**:

- the **master's** view comes from its rolling buffer in dmem;
- the **slave's** view is assembled from the **MOSI pin**, not from the
  firmware's transmit shift register.

So a master that presents bits on the wrong edge is caught by the second check
even though its own receive path looks fine.

### Bit-palindromic test bytes test nothing

`0x5A` was the firmware's original transmit byte and it is a **bit palindrome**
(`01011010` reversed is still `01011010`). A master that shifted LSB-first would
put the *identical* levels on MOSI and no test could tell the difference. The
same trap applies to `0x00`, `0xFF`, `0x0F`, `0x3C`, `0x81` and `0xAA`.

Every byte in the regression is now checked to not be a palindrome: the master
sends `0x5B` (-> `0xDA`) and the slave answers `0xA7 E5 96 C1`
(-> `0xE5 A7 69 83`). Choosing a test vector that cannot fail is the same class
of error as a guard that never fires ([[STATUS]] gotcha 14).

### Mutation results

Three mutations were built and run; two were caught, one was **not** — and the
one that was not is a design fact worth keeping:

| mutation | result | what it means |
|---|---|---|
| isolate bit 0 instead of bit 7 (shift LSB-first) | **caught** — slave captured `80 80 80 80` | the non-palindrome byte earned its place |
| sample MISO before the rising edge | **not caught** | see below |
| raise SCLK *before* changing MOSI (CPHA error) | **caught** — slave captured `2D AD AD AD` | the previous bit, exactly the CPHA failure |

The second mutation passing is not a hole. A CPHA=0 slave presents MISO on the
falling edge and holds it through the rise, so "sample before vs after the rise"
puts the master's sample point anywhere in the **low phase** and returns the same
bit. Sampling before the rise is *equivalent*, not defective; a mutation that
cannot change observable behaviour cannot be caught, and demanding that it be
caught would be demanding a lie. What *is* distinguishable is sampling MISO
**after the falling edge**, when the slave has already advanced — that is
mutation 3's territory on the output side.

## Follow-ups

- `tb_pe_soc_spi.v` does not exist. SPI firmware is verified **only** in the
  emulator and by the `run_firmware_tests.sh` assemble check — there is no RTL
  testbench driving the port as a slave. UART has `tb_pe_soc_uart.v`; SPI
  should get the equivalent, and until it does the emulator is the sole
  executable specification of the pin timing. (The emulator mirrors the RTL's
  cycle model, but a mirror is not the thing.)
- The tick-wait half-period jitter (~1-2 ticks) is harmless for SPI and is left
  alone deliberately. If a future protocol on this port cares, the fix is the
  sub-tick delay already recorded in [[plans/through-i2c]] for the UART.

## Related

- [[concepts/tx-timing-generation]] — the tick arithmetic both protocols share.
- [[concepts/factored-hardware-blocks]] — what is shared RTL vs what is program.
- [[plans/through-i2c]] — the ordered plan this milestone sits in.
- [[STATUS]] — milestone state and the gotchas referenced above.
