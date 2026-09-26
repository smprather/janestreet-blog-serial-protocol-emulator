---
title: DHT11 — a protocol where the bit value is a width
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, verification, clocking, physical-layer, gpio, architecture]
sources: []
confidence: high
---

# DHT11

The DHT11 is the hardest of the three original timing acts, and it is still just
timing. What makes it hard is that **both sides decide what a bit means by how long
they hold the line**, and the two sides are holding it in opposite directions.

- firmware: `firmware/dht11_read.pe` (134 words)
- testbench: `tb/tb_pe_soc_dht11.v`
- constant: `DHT_DATA` in the timing-constants block of `tools/fw/peasm.py`
- state machine: `diagrams/proto-dht11.puml`
- frame: `diagrams/proto-dht11-frame.puml`
- timing: `diagrams/proto-dht11-timing.puml`

All figures here are measured by the testbench on **real RTL** — `rtl/pe_cpu.v`, the
real SRAM macro, Icarus, 60 MHz.

## What the protocol is

One wire, no clock, and no framing to speak of. What there is, is a handshake:

| who | what | how long |
|---|---|---|
| host | pull low — the start signal, the sensor's reset | ≥ 18 ms |
| host | pull **high** | 20–40 µs |
| host | **release** | — |
| sensor | pull low (acknowledge) | 80 µs |
| sensor | release (acknowledge) | 80 µs |
| sensor | per bit: low, then release | 50 µs low |
| sensor | …the release | 26–28 µs = **0**, ~70 µs = **1** |

There is no other content. The host's job is: make a start signal of the right
*length*, release at the right instant, tolerate an acknowledgement whose timing it
must not assume, and then sample the line once per bit at an instant chosen so that a
0 and a 1 are 17 µs and 25 µs away from it respectively.

## The one decision the whole program turns on: synchronise, do not count

A bit is 50 µs of low followed by a release. The release lasts 26–28 µs for a 0 and
about 70 µs for a 1. So:

- the host **cannot sample inside the release** — a line high 20 µs into the release
  is a 0 *and* a 1;
- it must sample *after a 0's release has ended* — roughly 45 µs after the line went
  high.

And here is the trap that made this act worth doing. **The sensor's bit period is not
fixed.** A 0-bit is 50 + 26…28 = 76…78 µs; a 1-bit is 50 + 70 = 120 µs. A host that
waited a fixed time per bit, computed from the previous bit's value, would track the
sensor exactly for a while and then drift: at the 2 µs spread of the 0-bit, twenty
zero bits is 40 µs of slip, which is **three times the margin**.

That *was* this program's first design, and it decoded the nominal frame perfectly
while failing as soon as the sensor was modelled at the **short end of its own 0-bit
window** — a sensor inside its specification, and the firmware outside its own.

So the host synchronises on the line instead:

1. wait for the line to go **LOW** — the next bit's 50 µs prefix;
2. wait for the line to go **HIGH** — the release, which *is* the bit's value window;
3. wait 45 µs;
4. sample once.

Both waits are spin loops on the pin, which is the one thing the pin matrix is *for*:
`IN A, PIN` reads the **pad**, not the output register, and a released pin reads the
pad (see the matrix's read-port note in `rtl/pe_pinmux.v`). The loops poll every three
instructions, so an edge is caught within 50 ns against a 26 µs window — four
thousand times finer than anything here needs.

**The result is the point:** the 26–28 µs and 70 µs figures enter the firmware
*once*, as the 45 µs sample instant, and the sensor's tolerance stops being the
firmware's problem. That is the whole difference between a bit-banger that works on
the bench and one that works on a shelf.

The two timed intervals that remain — the 18 ms start and the 30 µs host window — are
genuinely timed, because nothing on the wire announces when they are over. The
acknowledgement is neither timed nor waited for by a constant: the firmware falls
into the same edge-wait loop it uses for bits, and the first round happens to wait
out the 80/80 µs acknowledge while the second one is bit 0. One loop, two uses.

## The sample bit, and the instruction that moves it

The data line is pin 6, so `IN A, PIN` masked with the pin's bit leaves the sample in
bit 6. A DHT11 byte is MSB first and the byte is built by shifting the accumulator
*right* and dropping the new bit in at the top — so the sample has to arrive in bit 7.
There is no shift-left in this ISA, so it is doubled instead:

```text
IN  A, PIN
AND A, DHT        ; 0x00 or 0x40
MOV X, A
ADD A, X          ; 0x00 or 0x80   <- the doubling, 2 instructions
```

`MOV X,A` followed by `ADD A,X` is the only shift-left this machine has, and it is
exact for a single bit because `0x40 + 0x40 = 0x80` does not carry out of the byte.

The alternative — using pin 7, where the sample already lands in bit 7 — was
rejected: bit 7 is the Ethernet DRU's input, and a program that silently claims it
takes a documented pad away from a documented protocol.

## Two delay pairs, and why one cannot do

The routine is the family one:

```text
total(n1,n2,n3) = (n1-1) * (10 + (n2-1) * (4*n3+7)) + 4   clocks
```

with the same reload trap: **both inner counters are destroyed by their own loops**,
so the caller's count is copied into a working slot at the top of every pass. And
because the ISA has no indirect jump and the routine cannot return to five addresses,
`dmem[7]` carries the phase and a subtract chain dispatches it.

The ratio between the shortest and the longest delay here is **34 000 : 1** — 30 µs
against 1.08 million clocks — so there are two `(n2,n3)` pairs:

| pair | one outer step | used for |
|---|---|---|
| `(6,255)` | 5 145 clocks = 85.8 µs | the 18 ms start |
| `(2,6)` | 41 clocks = 0.68 µs | the 30 µs, 45 µs and 170 µs delays |

A single pair cannot do both. With the fine step the 18 ms start would need an outer
counter of 11 900. With the coarse step the 30 µs window could not be *aimed at*:
20.7 µs would be inside the 20–40 µs window and 34 µs would be outside it. Two pairs,
chosen so each phase is aimed rather than merely inside its window.

The 18 ms start is the **longest single timed interval in the project** — 1.08 million
clocks, 6.4× the WS2812 reset and 900× the WS2812 bit cell — and it is what forces a
three-level routine rather than a NOP sled: as NOPs it would not fit in 1 024 words
of instruction memory.

## The frame

Five bytes, MSB first, no header and no length:

| byte | meaning | value on the wire |
|---|---|---|
| 0 | humidity, integer part | `0x2C` = 44 → 40 % RH |
| 1 | humidity, decimal part | `0x01` |
| 2 | temperature, integer part | `0x01` = 1 → 40.0 °C |
| 3 | temperature, decimal part | `0xAA` |
| 4 | **checksum** = (b0+b1+b2+b3) & 0xFF | `0x2C` |

`0x2C + 0x01 + 0xAA + 0x55 = 0x12C`, and `0x12C & 0xFF = 0x2C`.

**The firmware records the checksum and does not check it**, and that is deliberate. A
program that silently drops a bad frame is a program whose failure is invisible — it
looks like a sensor that has gone quiet. So the byte is banked in `dmem[4]` and the
check is left to whoever reads it, here the testbench. The firmware's job is to be
faithful to the wire.

## The measured result

```text
    start signal: line low for 18093.0 us
    host-high window: 30.0 us, then released (pin_oe)
    40 samples (spin-loop reads filtered), 40 bits sent by the sensor
    bytes: 2c 01 aa 55 2c   (humidity, temperature, checksum)
    sample margin: 17.0 us past the longest 0-release, 25.0 us before the 1-release ends
    bit-transitions in the frame: 24 of 39

PASS: all checks
```

| what | required | produced | which side |
|---|---|---|---|
| start signal | > 18 000 µs | **18 093.0 µs** | host |
| host high window | 20 … 40 µs | **30.0 µs** | host |
| the release | — | measured on **`pin_oe`** | host |
| acknowledge | 80 / 80 µs | **not timed** | sensor |
| a 0's release | 26 … 28 µs | 28 µs driven | sensor |
| a 1's release | ~70 µs | 70 µs driven | sensor |
| the sample | inside the gap | **+45 µs** | host |

The start signal is 0.5 % long, which is the **right direction for a minimum**: a start
signal that is too short is a reset the sensor ignores.

### Why the margins are asymmetric, and why that is the sensor's doing

17 µs on the 0 side, 25 µs on the 1 side. The 0's release is 26–28 µs and the 1's is
~70 µs, so a sample aimed at the *middle* of the gap would sit at 49 µs — 21 µs of
margin on each side. 45 µs trades the 0's margin for the 1's, which is the right trade:
the 0's window is 14× tighter than the sample's precision, and the 1's is not.

## The 30 µs host window is not optional

The DHT11 pulls its own line low to answer, so the host cannot simply stop driving and
let the pull-up win: the sensor would see a line that never went high and would not
start converting. Pulling it high for 30 µs guarantees a clean high-to-low transition
to answer with, and only then does the host become a reader.

It is also the one place this program drives the line high push-pull into a device
that may pull it low — safe only because the host has already stopped driving by the
time the sensor answers. The open-drain bit is deliberately **not** set: the 30 µs
high is a driven high, not a release.

## How the testbench proves it

Eight checks, and two of them are the ones worth reading twice.

**The host's release is measured on `pin_oe`, not on the line.** The host drives high
and then releases, and the pull-up holds the line high throughout — so on the *wire*
the release moves nothing at all. This was a real defect in the measuring instrument:
a TB that looks for a falling edge here waits forever, or measures the window from a
transition that is not one.

**The sensor model drives the worst case of each window**, and says so. A 0's release
is driven at 28 µs — the short end of the datasheet's 26–28 µs — so "sampled too
early" is falsifiable and the margin measured is the margin against a sensor at the
edge of its own specification.

The rest: the start signal is > 18 000 µs; the host window is inside 20…40 µs; the pin
is released; `dmem[15] == 1`; `dmem[0..4] == 2c 01 aa 55 2c`; the checksum sums; every
one of the 40 samples is inside its window; and the frame carries **≥ 20 of the 39
bit-transitions** — a frame of all-0s or all-1s would make a width-based decoder
trivially correct and the check would prove nothing.

## The mutation coverage that pins the testbench

Five cases in `regress/mutate_timing_tb.sh`:

| case | the change | what catches it |
|---|---|---|
| `dh-start-signal` | the long counts: 212 → 4 passes | the start signal — 0.26 ms of low instead of 18 ms |
| `dh-host-window` | the fine count 45 → 250 | the 20–40 µs window: 170 µs is outside it |
| `dh-sample-instant` | the sample at 45 µs → 14 µs | the decode: 14 µs into a release is *inside* a 0's window, so every 0 reads as a 1 |
| `dh-bit-order` | the accumulator shifts **right** instead of doubling | the decode — a **reversed byte**: the right number of bits and the right number of ones, so nothing looks broken |
| `dh-edge-wait` | the `w_hi` spin loop deleted | the decode: without the wait for the release the sample lands at a random point in the bit |

`dh-bit-order` is the one to remember. A reversed byte is the canonical invisible
defect in this whole family: it has the right length, the right population count, and
a waveform that looks exactly like the protocol. It is caught only by a testbench
that **reconstructs the data from the wire and compares it against what was sent**.

## The cost, and the two things done about it

The DHT11 testbench simulates **22 ms** of 60 MHz — 1.33 million clocks, about 29
seconds of wall time. The frame rate is measured on the two full slots rather than
five; the two long testbenches in the family dump a **narrow** signal set rather than
`$dumpvars(0, tb)` (99 s → 66 s on the servo alone — the waveform, not the design, was
the bottleneck); and the edge recorders are edge-triggered with `$realtime` rather than
per-clock with a counter, worth another ~40 %.

## Limits, stated rather than implied

- **The DHT11 is modelled**, and the model reproduces the bus hold after the fortieth
  bit. That is not bending the test to the firmware: the host's sample method (after
  a 0's release ends) is the only method in use, so a sensor that released the bus
  immediately would make the last bit unreadable by any of them.
- **One read, then park.** A real driver loops; the DHT11 needs about a second between
  conversions, which is not this simulation's timescale, and a looping program would
  be indistinguishable from a stuck one here. The loop version is the same code with a
  jump back to `start`.
- **The checksum is recorded, not enforced**, for the reason given above.

## See also

- [[protocol-ws2812]] — the act where the whole frame is one straight-line cell, and
  the contrast with 40 edge-synchronised samples
- [[i2c-on-the-matrix]] — the sibling bit-bang on the same pad, and what "synchronise
  on the wire" looks like when the peer announces its own edges
- [[physical-layer-gpio]] — why `IN A, PIN` reads the pad, which is what makes the
  edge-wait loops possible at all
- [[tx-timing-generation]] — the delay routine every act in this family shares, and
  the reload trap it carries
