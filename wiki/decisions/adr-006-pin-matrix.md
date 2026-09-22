---
title: ADR-006 — The pin matrix is a runtime direction file, and it lives inside the SoC
created: 2026-09-23
updated: 2026-09-23
type: decision
tags: [decision, architecture, protocol-emulation, area-budget]
sources: [rtl/pe_pinmux.v, rtl/pe_uart_soc.v, rtl/tt_um_protocol_emulator.v, firmware/i2c_pins.pe, tb/tb_pe_i2c_soc.v]
confidence: high
---

# ADR-006 — The pin matrix is a runtime direction file, and it lives inside the SoC

## Status

**Accepted and implemented.** Supersedes the pin-matrix plan in
[[plans/through-i2c]] on *placement* (the block itself is unchanged), and
corrects the `cfg_prot[i]` idea in the same document. See
[[concepts/pin-matrix]] for the register semantics and
[[concepts/i2c-on-the-matrix]] for how the firmware uses them.

## Context

The plan this project is executing says, of the pin matrix:

> the TT wrapper instantiates the matrix

That sentence cannot be implemented as written, and the reason is structural
rather than an oversight: **the CPU's IO bus never leaves `pe_uart_soc`**. The
`io_port`/`io_wdata`/`io_rdata` signals are internal to the SoC, and the TT
wrapper sees only the SoC's `pin_in`, `pin_out`, `pin_oe` and the host
programming interface. A matrix instantiated at the wrapper boundary would have
its OE and OD registers readable by nobody — no bus connects them to the
processor. I2C needs exactly those registers and nothing else in the project
does, so the consequence would be an I2C implementation that is dead weight.

There is a second, smaller correction. The plan describes the matrix as a mux
of eight protocol wire sets keyed by `cfg_prot[i]` — a *configuration* register
that selects which protocol owns the pins. Measured against what the protocols
actually need, that is the wrong shape: a per-protocol mux means a protocol's
pin behaviour is chosen at configuration time by selecting a wire set, whereas
what is missing from the design is a per-PIN, per-MOMENT direction.

## Decision

**1. The matrix goes inside `pe_uart_soc`,** between the CPU's port decode and
the SoC's `pin_in`/`pin_out`/`pin_oe`. That is the only placement where
firmware can set per-pin direction at runtime. `pe_uart_soc` gains a `pin_oe`
output; `tt_um_protocol_emulator` threads it to the pads. The wrapper is a pad
shell, not a logic layer — which is what a Tiny Tapeout wrapper should be.

**2. The register file is per-pin `{out, oe, od}`, not a protocol mux.**

| Register | Port | Meaning |
|---|---|---|
| `OUT` | 1 `PINOUT` | the level to drive |
| `OE` | 2 `PINOE` | 1 = participate on this pin, 0 = release (high-Z) |
| `OD` | 3 `PINOD` | 1 = open-drain: a pin holding 1 is RELEASED, not driven |
| `IN` | 0 `PIN` (r) | driven pins read back what we wrote; released pins read the pad |

with the drive enable being

```verilog
pad_oe = reg_oe & ~(reg_od & reg_out);      // rtl/pe_pinmux.v
```

**3. The port numbering and the register addressing are deliberately different
schemes.** The SoC's port numbers (`0=PIN, 1=PINOUT, 2=PINOE, 3=PINOD`) do not
match the matrix's register addresses (`0=OUT, 1=OE, 2=IN, 3=OD`). Assuming
they were identical is a bug that was actually written and actually broke the
UART: port 1 is `PINOUT`, whose writes must go to the matrix's OUT register at
address 0, but the identity map sent them to OE (address 1). The UART then
drove with an output enable of 0x08 — one input bit, no outputs — and hung.
The decode is now an explicit `case` with the two schemes written side by side
in a comment.

**4. Reset seeds reproduce the previous fixed-mask behaviour.** `RST_OE = ~PIN_IN_MASK`,
`RST_OD = 0`, `RST_OUT = PIN_OUT_RST`. So a program that never writes PINOE or
PINOD sees a SoC bit-identical to the fixed-mask version — which is what lets
the UART and SPI tests sign off unchanged through the new hardware.

## Consequences

**The safety property is structural, not a convention.** With `od=1`, a pin
holding a 1 has its enable cleared, so the pad *cannot* drive high. Driving
high into another device's low is not expressible in this register file, which
is the failure mode that destroys I2C parts on a bench. The firmware never has
to remember not to do it.

**Arbitration and clock stretching cost one instruction each.** Because a
released pin reads the pad, `IN A, PIN` *is* the arbitration comparison and
*is* the stretch check. No comparator, no status bit, no interrupt.

**Read-back semantics had to generalise, with one honest caveat.** The old
formula was `(pin_out & ~PIN_IN_MASK) | (pin_in & PIN_IN_MASK)`. The new one is
`(pin_out & pin_oe) | (pin_in & ~pin_oe)`, using the *real* drive enable rather
than the OE register. It reduces exactly to the old formula when `od=0`, so SPI's
read-modify-write is unaffected. The caveat: a pin that firmware has released
now reads the pad instead of the last value written. Nothing in the UART or SPI
programs releases a pin, so no existing behaviour changes — but the guarantee
is "identical for firmware that does not write PINOE/PINOD", not "identical,
full stop". The header of `rtl/pe_uart_soc.v` states it that way.

**Programs now own their pins.** `firmware/i2c_pins.pe` writes PINOE with a
literal `SDA|SCL`, which releases TX and bits 1–2 that the reset default had
enabled. That is correct for an I2C-only program and is visible in the file.
A program MIXING protocols must read-modify-write PINOE instead — the same
idiom `spi_xfer.pe` uses on the port.

**The open-drain bit does not make every wrong-moment drive safe.** It prevents
*contention*. The first draft of `i2c_pins.pe` enabled the two pins before
setting their output levels, so SDA went low for two cycles while SCL was
high — a spurious START. The bus was never damaged and every timing interval
still met spec; the sequence was simply wrong. See
[[concepts/i2c-on-the-matrix]] for the init ordering rule.

**Open question, unresolved and recorded as such.** Should `pe_ctrl` also be
an SPI master (so one host interface can both load the CPU and drive a
peripheral bus)? That is a control-plane question this ADR does not decide.

## Alternatives considered

**Matrix at the wrapper (the plan's placement).** Rejected: unreachable from
firmware, as above. Also wrong in kind — it would put protocol logic in the
submission wrapper, where the Tiny Tapeout contract wants pads.

**Per-protocol `cfg_prot[i]` mux (the plan's design).** Rejected: it selects
which wire set owns the pins at configuration time, when the actual missing
capability is per-pin direction at runtime. It would also need a wire set per
protocol, so adding a protocol means adding gates to the mux rather than
adding a program.

**A dedicated I2C controller block.** Rejected on the project's own thesis: the
claim under test is that factored, config-driven hardware plus firmware can
emulate a protocol set. A per-protocol controller is the thing being argued
against.

**Gating the OD term behind a mode bit, so push-pull and open-drain share one
register.** Rejected as more state for no gain: `od=0` already IS push-pull,
so the mode is the register itself.

## Related

- [[concepts/pin-matrix]] — the block's registers, the OD gate, and its own
  mutation-checked testbench.
- [[concepts/i2c-on-the-matrix]] — the protocol that needs this, running on it,
  with the measured timing and the init-ordering trap.
- [[plans/through-i2c]] — the milestone (step 5).
- [[reference/protocol-pin-budget]] — the pad budget.
- [[STATUS]] — what is actually built.
