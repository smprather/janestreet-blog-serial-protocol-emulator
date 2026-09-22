---
title: I2C on the pin matrix
created: 2026-09-23
updated: 2026-09-23
type: concept
tags: [protocol, gpio, physical-layer, verification, firmware]
sources: [firmware/i2c_pins.pe, rtl/pe_pinmux.v, rtl/pe_uart_soc.v, tb/tb_pe_i2c_soc.v, tools/measure_i2c_timing.py, tools/peasm.py]
confidence: high
---

# I2C on the pin matrix

There is **no I2C controller** in this design, and that is the point. What the
SoC provides is a register file that makes each pin's direction a runtime value
([[concepts/pin-matrix]], [[decisions/adr-006-pin-matrix]]) plus a 1 µs tick.
Everything an I2C bus is — START, STOP, bit cells, ACK, arbitration, clock
stretching — is firmware. This page is what that firmware taught us.

## What the firmware is, and what it deliberately is not

`firmware/i2c_pins.pe` (79 words of 1024) is **one START, one bit cell, one
STOP** — the pin-level grammar. It is not a byte transfer: no shift register, no
ACK slot, no address phase. Those are the transaction layer (plan step 6), and
they are built from exactly these primitives.

Writing the bit cell as one straight-line pass rather than a loop is what makes
the timing assertable: a testbench can measure tLOW, tHIGH and the period on
three edges it can name, instead of measuring a loop.

## Open-drain, and why the OD bit is the whole reason this works

A pin is either **driven low** or **released**. Never driven high. The pull-up
supplies the high level, and a second device may pull the line down at the same
time — which is not a fault, it is arbitration.

To send a 1, the firmware writes `out=1` with `od=1`. The OD gate turns that
into a *release*. The dangerous state — driving high into someone else's low —
is not expressible, so the firmware never has to remember not to do it. That is
the structural safety property, and `tb/tb_pe_i2c_soc.v` checks it on the RTL's
own `pin_oe` output rather than on the pad, so a forgiving bus model cannot mask
it.

The idiom that comes out of this, and which is the project thesis in one line:

```asm
; to send 1 or 0: write out=1 or out=0. Never touch oe or od again.
```

The **same instruction sequence** drives a push-pull bus and an open-drain one.
Only the `od` register differs, and it is written once.

## Arbitration costs one instruction

Because a released pin reads the pad (not the last value written),
`IN A, PIN` **is** the arbitration comparison:

```asm
LDI A, SDA        ; release SDA — it rises, or it does not
OUT TXPIN, A
IN  A, PIN        ; <- this read IS the arbitration check
AND A, SDA
JNZ arb_ok        ; still high => nobody contended
```

No comparator, no status bit, no interrupt. The same read is the clock-stretch
check, which is why releasing SCL and reading it back before relying on it
costs one instruction.

## Timing: three real traps

### 1. The wait idiom had to change, and the reason is worth stating

`uart_echo.pe` and `spi_xfer.pe` wait a tick by watching the counter **change**:

```asm
IN A, TICK ; MOV X, A
w: IN A, TICK ; SUB A, X ; JZ w
```

The counter is free-running, so the first change arrives somewhere in `(0, 1]`
ticks — up to a full tick short. Harmless for SPI (synchronous: the slave times
off our own edges, so jitter costs nothing) and a sampling-margin cost for the
UART. **Not safe for I2C**, where tLOW is measured at the pin against a 4.7 µs
floor. The first draft of `i2c_pins.pe` took 1,384 cycles for 28 µs of nominal
delays — a 0.83× shortfall, and it would have *passed a bench test*.

So I2C waits for an exact **target**:

```asm
IN  A, I2CTICK ; ADD A, T_LOW ; MOV X, A    ; X = the tick we wait for
w:  IN  A, I2CTICK ; SUB A, X ; JNZ w       ; spin until the counter IS X
```

`SUB`'s only second operand is an immediate or `X` — `Y` is not addressable
there — so the target lives in X.

### 2. The phase residual sets the constants, and it is subtle

Firmware cannot see where in the 60-cycle window a read lands. Call that offset
φ. The target tick arrives `60·N − φ` cycles later, so an "N-tick" wait delivers
`(N−1, N]` µs — **still up to a full tick short**. The number that must clear
each floor is `N−1`, not `N`.

That is why `T_LOW` is 7 and `T_HIGH` is 6, not the other way round: the floors
differ (4.7 vs 4.0), so the larger count belongs against the larger floor.
Giving tHIGH the larger share — which the first draft did, reasoning about
pull-up rise time — leaves tLOW with 0.35 µs of margin. The swap is **free**:
the waits chain in target form, so the period is `T_LOW + T_HIGH` either way.

Measured (all 60 phases, worst case):

| interval | worst case | floor | margin |
|---|---|---|---|
| tLOW | 5.917 µs | 4.7 | +1.217 |
| tHIGH | 6.050 µs | 4.0 | +2.050 |
| period | 11.967 µs | 10.0 (100 kHz ceiling) | +1.967 |

→ **83.2–83.6 kHz**, standard mode, deterministic to within 0.05 µs.

### 3. The init order is a real trap, and it is not the one you expect

The bus must be entered in the order **OD → OUT → OE**, not OD → OE → OUT.

At reset the output register holds `0x01`, so bits 4 and 5 are **zero**. Writing
`PINOE` first therefore enables those two pins while they still hold 0 — SDA is
pulled low for two cycles with SCL high, which **is a START condition**. The
first draft did exactly that and the wire trace showed it (both lines low at
cycles 4–5, before anything legitimate had happened).

The OD bit prevents **contention**. It does not prevent driving low at the wrong
moment, and a spurious START is exactly that. Setting the level first means the
pins are never enabled holding the wrong value.

### The STOP sequence is not the mirror of START

A STOP is SDA **rising** while SCL is high. The trap: if SDA is low and you
release it with SCL high, that is a STOP — but *how you got SDA low* matters,
because pulling SDA low while SCL is high is a START.

The order that cannot go wrong, and the one the firmware uses:

1. SCL low — SDA may be anything, no condition is defined
2. SDA low — safe now that SCL is low
3. tSU;STO wait
4. release SCL
5. tHIGH wait
6. release SDA — **this rising edge is the STOP**
7. tBUF wait

The first draft skipped step 1 and emitted a spurious second START before its
STOP. Every timing interval still met spec, which is why it needed a *grammar*
check to catch, not a timing check.

## How it is verified

Two checks in two places, deliberately:

- **`tools/measure_i2c_timing.py`** sweeps all 60 tick phases and reports the
  worst case of each interval against the standard-mode table, and asserts the
  bus *grammar* (exactly one START, one bit cell, one STOP, no SDA move under
  SCL-high).
- **`tb/tb_pe_i2c_soc.v`** runs it on real RTL with an open-drain bus model on
  the TB side, checks the OD property on `pin_oe` itself, and re-runs with
  another device pulling SDA low so the arbitration branch is not dead code
  ([[STATUS]] gotcha 14).

**This testbench was caught being vacuous twice, and both are worth remembering.**

1. The interval checks were **missing entirely** — the RTL TB only counted
   conditions, so a bit cell half the length of spec passed. A mutation test
   caught it.
2. Once added, the edge indices were **wrong**, making both checks unfailable:
   tLOW was computed from the *second* SCL rise, so it measured the idle stretch
   (19 µs, always ≥ 4.7), and tHIGH was a negative difference that **wraps in
   the unsigned `%time` type** to a huge number (always ≥ 4.0). Two `>=` checks
   that could never fail. There is now a plausibility guard (< 20 µs) that fails
   on a wrong index or a wrapped subtraction.

`tb/mutate_i2c_tb.sh` runs six mutations. One is a documented **equivalent
survivor**: on a port-0 read the matrix's `raddr` defaults to `A_IN`, so
`pinmux_rdata` *is* `pin_in` — for firmware that only reads pins it has
released, the read-back mutation is equivalent. The UART test does catch it (its
read-modify-write stops converging and the TB hangs), which is why the survivor
is explained rather than papered over, and why the count is asserted exactly.

## Open work

- **A byte transfer.** No shift register, no ACK, no address phase yet — plan
  step 6. The primitives above are what it is built from.
- **A 7-bit address and a real slave.** The TB models the other device as a
  single pull-down, which is enough for arbitration and not enough for a
  transaction.
- **Pull-up values.** Not modelled at all: the TB's bus is ideal. The real RC is
  what eats into tHIGH on a board, which is why tHIGH carries the larger
  absolute margin.

## Related

- [[concepts/pin-matrix]] — the registers this firmware drives.
- [[decisions/adr-006-pin-matrix]] — why the matrix is inside the SoC.
- [[concepts/spi-as-firmware]] — the same thesis for the second baseline protocol.
- [[concepts/tx-timing-generation]] — how the tick dividers are derived.
- [[reference/clock-arithmetic]] — the generated clock/tick table.
- [[plans/through-i2c]] — the milestone.
- [[STATUS]] — what is actually built.
