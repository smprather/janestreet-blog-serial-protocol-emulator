---
title: The Pin Matrix
created: 2026-09-22
updated: 2026-09-22
type: concept
tags: [architecture, gpio, protocol, physical-layer, verification]
sources: [rtl/pe_pinmux.v, tb/tb_pe_pinmux.v, wiki/plans/through-i2c.md, wiki/reference/protocol-pin-budget.md]
confidence: high
---

# The Pin Matrix

`rtl/pe_pinmux.v` is the block that makes a pin's **direction a runtime
property** instead of a build-time constant, and that adds a read-back path so a
bus we are also driving is observable. It is the last piece of hardware the
baseline tier needs: everything after it (I2C, PS/2, SWD, USB) is firmware.

## Why it had to exist

Every protocol before this one assumed direction was fixed. That assumption was
cheap and it was true:

- UART TX is an output for the whole design; UART RX is an input for the whole
  design. `PIN_IN_MASK` in `rtl/pe_uart_soc.v` says which, once, at
  elaboration ([[reference/signal-names]] has the generated port list).
- SPI is the same, with three outputs and one input. Still push-pull, still
  fixed, still a constant.

I2C breaks it, and I2C is the only baseline protocol that does. SDA is driven
low, **released** so the board's pull-up takes it high, and **read back** —
often inside a single bit cell, because arbitration means the master must
compare the level it drove against the level the bus actually has. A pin that
never changes direction cannot express that. See
[[reference/protocol-pin-budget]] for the pin counts and
[[concepts/physical-layer-gpio]] for the electrical side.

## The registers

Four, addressed by 2 bits:

| addr | register | meaning |
|---|---|---|
| 0 | `OUT` | what to drive when driving |
| 1 | `OE` | 1 = this pin may drive, 0 = released (high-Z) |
| 2 | `IN` | the pad level, read-only, whatever the direction |
| 3 | `OD` | open-drain mode: drive low, release on 1 |

`IN` is **not stored**. It is the pad, sampled combinationally. That is a
deliberate choice with a specific failure behind it: a registered copy of the
input reports the *previous* cycle's level, so an arbitration check would
compare this bit cell's drive against last bit cell's bus and report a win while
the bus was being fought. Latency is the whole question in arbitration, so the
read path has none.

## The `OD` bit, which is the interesting one

`pad_oe = reg_oe & ~(reg_od & reg_out)`. In open-drain mode a pin holding a 1 is
**released**, not driven high.

Without that gate, open-drain is a firmware *convention*: the program must
remember to release (`oe=0`) when sending a 1, and if it forgets it writes
`{oe=1, out=1}` and drives the bus high. On a bus where a slave is pulling SDA
low in the same cell, that is a direct short from our pad to the slave's
pull-down transistor. It is a real, destructive contention bug, and it only
appears with a second device on the wire — i.e. never in the single-master
testbench that would have signed it off.

With the gate, the hazardous state is **unreachable**: the gates cannot express
it. That is a stronger statement than "the tests pass", and it is why the bit
earns its area.

The payoff is bigger than the safety. Look at what firmware does to send bits:

| | send a 1 | send a 0 |
|---|---|---|
| push-pull | `out=1, oe=1` | `out=0, oe=1` |
| open-drain | `out=1, oe=1` | `out=0, oe=1` |

Identical. In OD mode `out=1` releases and `out=0` pulls low, so **toggling
`out` sends bits in both modes with the same code**. Without the gate,
open-drain firmware has to toggle `oe` instead of `out`, and every bit-banging
loop is different code in the two modes.

That is the project's thesis — "swap the program and it speaks I2C, with the
gates unchanged" — reduced to one gate. It is worth stating plainly: the reason
`OD` exists is not that open-drain is hard, it is that **the firmware idiom has
to survive the protocol swap**, and without the bit it does not.

## What it replaced

[[plans/through-i2c]] sketches the matrix as a per-pin `cfg_prot[i]` selecting
one of eight protocol wire sets. That version is strictly worse:

- it needs the same per-pin state **plus** a selector;
- the selector would hold a constant per protocol — a build-time map wearing a
  runtime hat, which is exactly the thing this project argues against;
- a bad selector value is a configuration that can disagree with the register
  file, which is a new failure mode for no gain.

Per-pin `{out, oe, od}` with firmware composing the assignment is smaller, cannot
be inconsistent with itself, and lets a protocol use pins that no protocol table
would have allocated to it. The cost is that firmware must know its own pin map
— which it must anyway, since it writes the values.

## How it relates to the SoC's port

`pe_uart_soc` keeps its own fixed-mask port. It is the degenerate case of this
block (`oe = ~PIN_IN_MASK` constant, `od = 0`), and it stays separate on
purpose: it is what `tb_pe_uart_soc` and `tb_pe_tick_status` sign off, and
swapping the mechanism underneath a verified path to serve a protocol that path
does not implement is how a green regression quietly stops meaning anything.

The TT wrapper instantiates the matrix **in front of** the SoC's port, so the
UART keeps its own regression and the matrix is proved by its own testbench.

## How it is verified

`tb/tb_pe_pinmux.v` proves six properties, and the two that matter most are the
ones a naive test would miss:

1. **drive low / release** — the I2C primitive.
2. **the pad cannot drive high in OD mode**, checked on the *mechanism*
   (`pad_oe`) and not just the level, because a released pin and a driven-high
   pin both read 1 on an idle bus. A level-only check passes for a design that
   would short out on a busy one.
3. **read-back during transmit** — release to send a 1, read the bus, find 0
   because another master is pulling down. That is arbitration.
4. **push-pull drives high for real** — checked with a `driven_high` signal that
   distinguishes a strong drive from the pull-up, plus a contention case that
   shows what open-drain mode forbids.
5. **the same firmware idiom works in both modes** — the thesis, as an assertion.
6. **the register file is total** — mutual independence of the three writable
   registers, `IN` read-only, reset reachable from a driven state.

The testbench's wire model is not one line, and that is the point. Modelling the
bus as "released = 1, driven low = 0" — which is what `tb_pe_i2c.v` does, and is
correct for a single-master test — **cannot** catch the failures here, because a
released pin and a driven-high pin both read 1. So this model tracks strong
drive separately, reports **contention as X** rather than picking a winner, and
asserts that contention never occurs outside the one test that deliberately
provokes it. A model that resolved contention to a level would be hiding the
fault it exists to expose.

**Mutation-checked, 7/7 caught.** The full battery, each of which must fail:

| mutation | caught by |
|---|---|
| drop the OD gate (`pad_oe = reg_oe`) | 6 failures |
| OD ignores OE (`pad_oe = ~(od & out)`) | 8 |
| OUT and OE share a register | 18 |
| IN reads `reg_out` instead of the pad | 1 |
| a write to IN clobbers OUT | 1 |
| reset does not clear OD | 1 |
| reset does not release pins | 3 |

The `pe_dru` lesson applies to the PINS guard: a guard that never fires is
indistinguishable from one that passes, so `tb/param_guards.sh` compiles the
module at `PINS=0` (reversed vector range) and `PINS=9` and requires a hard
failure, and at `PINS=1`/`PINS=8` and requires acceptance. See
[[STATUS]] gotcha 14.

## Traps worth remembering

- **`$error` takes ONE string at elaboration in Icarus.** A `%0d` argument makes
  the tool emit `sorry: Elaboration tasks currently only support a single string
  argument` *instead of* the message — the guard still fires, but the text a
  reader needs is replaced by a parser complaint about the guard. Same trap as
  `pe_dru.v:117`.
- **A bus-wide ternary in a wire model is a bug, not a shortcut.** The first
  version of `pad_in` resolved all 8 pins together, so one pin pulling low
  dragged the whole byte low and two "other pins stay high" checks failed for a
  reason with nothing to do with the DUT. A model wrong in the same direction as
  a plausible DUT bug is worse than no model.
- **Reset is release + idle-high on every pin.** Safe on every bus in
  [[reference/protocol-pin-budget]], but deliberately **not** right for a UART
  TX line, where a low line reads to a peer as a start bit. That is the SoC
  port's own reset value to choose, because the SoC is what knows a UART is
  resident. This block does not guess a protocol from its pins.

## Related

- [[plans/through-i2c]] — the milestone this unblocks (step 4).
- [[concepts/physical-layer-gpio]] — what each protocol needs electrically.
- [[reference/protocol-pin-budget]] — the pad budget this fits inside.
- [[reference/signal-names]] — the generated port glossary.
- [[STATUS]] — what is actually built.
