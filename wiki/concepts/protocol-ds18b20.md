---
title: DS18B20 — 1-Wire, where the device speaks first and the polarity flips
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, verification, clocking, physical-layer, gpio, architecture]
sources: []
confidence: high
---

# DS18B20 on 1-Wire

The DS18B20 inverts the DHT11's problem, and it is the second act to make the
family's central rule unavoidable: **where the wire announces an event, wait for the
event; where it does not, count.**

- firmware: `firmware/ds18b20.pe` (205 words)
- testbench: `tb/tb_pe_soc_ds18b20.v`
- constants: the `OW_DATA`, `OW_RST`, `OW_T5`, `OW_T15`, `OW_T40`, `OW_T55`, `OW_T65`
  block in `tools/fw/peasm.py`
- state machine: `diagrams/proto-ds18b20.puml`
- frame and slot grammar: `diagrams/proto-ds18b20-frame.puml`
- timing: `diagrams/proto-ds18b20-timing.puml`

All figures here are measured by the testbench on **real RTL** — `rtl/pe_cpu.v`, the
real SRAM macro, Icarus, 60 MHz.

## What is different about it

Two things, and both of them break habits carried in from the DHT11.

**It is the only protocol in the family where the device initiates.** After the host's
reset pulse the sensor answers with a presence pulse, so for the second half of the
exchange the firmware is reading a line *the sensor is driving*.

**A read slot is sampled INSIDE the slot, not between two windows.** The DHT11 is
sampled after a 0's window has closed. A DS18B20 read slot is:

- the host pulls low for 1–15 µs (the initiation pulse);
- the sensor responds within `tRDV` (15–60 µs);
- then a **0** leaves the line released for the rest of the slot, and a **1** pulls it
  low again for 1–15 µs and then releases.

So the sample is a plain **level read at a known instant** — no edge needed at all.

## The exchange, and why each step is a different kind of wait

| step | what | kind of wait | why |
|---|---|---|---|
| 1 | **RESET** — host low ≥ 480 µs | **counted** | nothing on the wire says when 480 µs is up |
| 2 | **PRESENCE** — sensor low 60–240 µs | **edge wait, twice** | the pulse's length is the sensor's to choose |
| 3 | **0xCC** SKIP ROM | **counted** × 8 slots | the host sets the timing; the sensor only answers |
| 4 | **0xBE** READ SCRATCHPAD | **counted** × 8 slots | ditto |
| 5 | 2 × 8 **read** slots | **edge wait, then counted, then sample** | the hybrid that makes 1-Wire different from I²C |

That split is the lesson of the DHT11 act, applied honestly: the first DHT11 design
counted its way through the sensor's bit periods and drifted 40 µs over twenty zero
bits. Here the read path *first* spun for the sensor's own falling edge — and it
raced, because the line was still low from the host's own initiation pulse, so the
loop exited at once and every sample landed a whole slot early. **Counting to a fixed
instant cannot race.**

## The bytes

With one sensor on the bus the 64-bit ROM code is never sent:

| on the wire | what |
|---|---|
| reset | 485.7 µs low (floor 480 µs) |
| presence | 120.0 µs sensor-driven (band 60…240 µs) |
| `0xCC` | SKIP ROM, 8 write slots |
| `0xBE` | READ SCRATCHPAD, 8 write slots |
| 16 read slots | scratchpad bytes 0 and 1 → **`2b 01`** |

`0x2B` = 43 is the temperature, LSB byte first. Bytes 2…8 of the scratchpad exist and
are not read: the loop is the same for each, and sixteen slots demonstrate the *slot
timing* as well as seventy-two would, at a third of the simulated time. The byte count
is one number in `dmem[3]`.

**What SKIP ROM costs, stated rather than glossed.** A ROM match is the addressable
case: the host sends all eight ROM bytes, the sensor compares them with its own, and
only the addressed one answers. With one sensor on the bus that is 64 slots to learn
nothing. But with `0xCC` a bus carrying *two* sensors would have **both** answer and
the two read streams would collide. The act claims the single-sensor case and says so.

## Two slot grammars, and the polarity that flips between them

This is the part that is easy to get wrong and hard to see:

| direction | a **0** is | a **1** is | the host's job |
|---|---|---|---|
| **WRITE** (host → sensor) | the line **LOW** for the whole slot, ~60 µs | a **short** low (1–15 µs) then **release** for the rest | drive low — and **claim the pin first** |
| **READ** (sensor → host) | the line **RELEASED** for the rest of the slot | the line **PULLED DOWN** again for 1–15 µs | release, then **sample the level** at a fixed instant |

In the read direction a one is LOW; in the write direction a zero is LOW. The two
directions cannot borrow one sampling idiom from each other, and the read path first
borrowed the write path's.

**The polarity bug, and what it looked like.** The first read sampled with
`JZ rb_was_zero` — it read a *zero* from a line the sensor was *pulling down*. Both
bytes came back **exactly complemented**: `0x2B` as `0xD4` and `0x01` as `0xFE`, bit
for bit. The firmware's own header stated the opposite of its code.

That is the canonical invisible defect in this family: **a sensor that transmits its
data inverted still transmits DATA.** Both bytes still had eight bits and a plausible
number of ones. Nothing in the run looks wrong until the bytes are compared — and the
way to tell a polarity bug from a protocol bug is to look at the *accumulator*, not
the waveform.

**The bit order is LSB first**, the opposite of the DHT11 and of the WS2812. The write
path needs no shift at all: it masks the byte's own bit 0, sends, and rotates the
byte right so the next bit 0 is the next bit of the frame. The read path shifts the
accumulator **right** with the new bit at the top, so the first bit read slides down
to bit 0 by the eighth. Copying the DHT11's shift-left-and-OR-here makes every byte
come back **reversed** — the right bit count and the wrong values.

## The measured result

```text
    reset pulse: line low for 485.7 us (min 480)
    presence pulse: 120.0 us (datasheet 60-240 us)
    write slots: 16 bits   1-low 5.0-5.0 us   0-low 64.8-64.8 us
    command 1: cc (want cc SKIP ROM)   command 2: be (want be READ)
    read slots: 16, sampled: 16, model decoded: 2b 01
    firmware dmem[0..1]: 2b 01 (want 2b 01, LSB first)
    read initiation pulses: 6.2-6.3 us (datasheet 1-15 us)
    sample instant inside the data window: 10.8 us after the response, 19.2 us before the hold ends
    payload bit-transitions: 6 of 14

PASS: all checks
```

| what | datasheet | produced | which side |
|---|---|---|---|
| reset pulse | ≥ 480 µs | **485.7 µs** | host |
| presence pulse | 60…240 µs | **120.0 µs** | sensor |
| write-1 low | 1…15 µs | **5.0 µs** | host |
| write-0 low | ~60 µs | **64.8 µs** | host |
| read initiation | 1…15 µs | **6.2…6.3 µs** | host |
| sensor `tRDV` | 15…60 µs | driven at the **15 µs maximum** | sensor |
| the sample | inside the data window | **+10.8 µs** in, **19.2 µs** before the end | host |

The sample lands 10.8 µs into a window that is 30 µs wide — roughly the middle, with
margin at both ends.

### The reset is a counter, not a microsecond

`OW_RST = 58` on the `(4,40)` pair: `(58-1)*511 + 4 = 29 131` clocks = 485.5 µs, and
485.7 measured.

Writing `480` straight into the outer counter comes out as **1 900 µs**, because 480
wraps to 224 and the routine counts *passes*, not microseconds. That is the mistake
this block exists to prevent, and it is why every one of these fitted numbers is a
`CONSTS` entry in `tools/fw/peasm.py` rather than a literal in the source — which is
also what lets `--const OW_RST=40` perturb it for the mutation suite.

The pair changes once: `(4,40)` gives a 511-clock (8.5 µs) step for the reset, and
`(2,13)` gives a 69-clock (1.22 µs) step for everything after, which is what a 5 µs
write slot needs.

## Why the open-drain bit is deliberately NOT set

`rtl/pe_pinmux.v` has an OD bit, 1-Wire is the open-drain case, and this program leaves
OD clear. That looks like an omission and is a decision, and it costs something:

with OD set, a pin holding 1 **releases** rather than drives high, so **a pin holding
1 reads back as released** — a write of 1 and a write of 0 look identical on the pin,
and the edge-wait loops cannot see the sensor's pulses at all.

OD buys nothing here and costs the one thing the pin read-back is for. The
`i2c_pins.pe` idiom — *"write out=1 or out=0 and never touch oe or od again"* — is
right for a bus where the **level is the data**. 1-Wire is the opposite case: the data
is a *time* and the level is just a carrier for it.

## The dmem collision, which is the single biggest bug the act found

The delay routine and the protocol must have **disjoint `dmem` ownership**. A shared
slot between them is not a warning; it is a lost phase transition.

The read byte counter was initialised with `STM 10, A` — and `dmem[10]` is the **delay
routine's middle-counter target**, the slot the write command counter had been moved
off one commit earlier. The read byte counter now lives in `dmem[8]`, which nothing
else writes.

The consequence is worth recording because of its *shape*. The loop banked the two
**correct** bytes and then, with 255 slots left instead of 1, walked the byte index up
until it banked over `dmem[5]` — its own index — and came back round to overwrite
`dmem[0..1]`. The testbench's "the two temperature bytes came back" check read
`ff ff` against a read path that was **correct for all sixteen slots**, and the model's
own decoded bits were right the whole way.

**A runaway loop is a bug in the counter, not in the data, and only the counter was
wrong.**

The same act produced a third instance of a different recurring defect: **a dispatch
is a function over every phase the program uses.** The delay's return is chosen by a
subtract chain on `dmem[12]`, and two bugs lived in it, both from patching one dispatch
for two different loops — it first handled 0–3 and sent everything ≥ 4 to `ph4`, which
dropped a write-1's high period into the read path; and when the read loop was given
phases 4 and 5 it collided with the write loop's 4 and 5. Adding a phase means
extending the chain, not reusing a number.

## How the testbench proves it

Eight checks. Two of them are the measuring-instrument decisions:

**The model is written from the datasheet, not from the firmware** — and it was right
when the firmware was wrong, twice. That is the outcome one wants from a testbench
whose model is written from the specification.

**The model drives `tRDV` at the datasheet's maximum (15 µs).** It could have used the
typical and made the test easier. It uses the maximum so that *"the firmware sampled
too early"* is **falsifiable** — which is what makes the sample-margin check worth
running at all.

**The model's read edges come off the pads, not off its own state.** That is what
stopped it losing the master's next release while still inside the previous bit's hold
— a bug that silently ended the run at 8 slots.

And the checks: the reset is > 480 µs; the presence is inside 60…240 µs **and** the
host's `pin_oe` is released on every clock of it; every write slot's low period is
inside its own band (1–15 µs for a 1, 60–120 µs for a 0); exactly 16 read slots;
every read slot's initiation pulse is inside 1–15 µs; the **sample instant is inside
the sensor's data window with ≥ 2 µs of margin at both ends**; `dmem[0..1] == 2b 01`
LSB first; `dmem[14] == 1`.

## The mutation coverage that pins the testbench

Seven cases in `regress/mutate_timing_tb.sh`, two of which are counted-delay-constant
mutations reached through `peasm --const` — a text edit of the `.pe` cannot touch
`CONSTS`, which is precisely why `--const` exists.

| case | the change | what catches it |
|---|---|---|
| `ow-reset-count` | `--const OW_RST=40` | the reset pulse: 332 µs, under the 480 µs floor |
| `ow-sample-early` | `--const OW_T40=2` | the decode: 1.2 µs in, still inside the sensor's 15 µs response, so the line is high and **every bit reads as a zero** |
| `ow-sample-late` | `--const OW_T40=45` | **the sample margin and nothing else** — 51.2 µs, past a 0's hold, and *the decode still comes out right* |
| `ow-write1-width` | `--const OW_T5=30` | the write-1 band: 34 µs, past the 15 µs maximum — and **the commands still decode**, because the model's own 30 µs decoder still calls it a one. Only the band check sees this |
| `ow-write0-width` | `--const OW_T65=2` | the write-0 band: 1.2 µs, which the model reads as a ONE, so the commands come back shifted as well as mis-banded |
| `ow-presence-edge` | one of the two presence spin loops | the read never starts |
| `ow-polarity` | the read's sample test inverted | the decode: both bytes exactly complemented |
| `ow-byte-counter` / `ow-bit-order` / `ow-skip-rom` / `ow-read-cmd` / `ow-read-count` | the structural cases | respectively: a runaway counter, a reversed byte, a wrong address, a wrong command, and a short read |

**`ow-sample-late` and `ow-write1-width` are the cases that justify the two non-obvious
checks.** Both **decode correctly** and are caught by the margin and the band alone.
Neither would be caught by a byte comparison — which is exactly why those checks exist,
and why a family that only compared bytes would have shipped both defects.

## Limits, stated rather than implied

- **`tLOW` is mid-band and deliberately *not* worst case.** With `tLOW` ∈ 15–60 µs and
  `tHIGH` ∈ 1–15 µs the two windows **overlap**, and no single instant is correct for
  every legal sensor timing — the guaranteed window is one microsecond wide. Claiming
  the worst case there would be a stronger-sounding and false statement.
- **Two scratchpad bytes, not nine.** The claim is about slot timing, and sixteen slots
  demonstrate that as well as seventy-two would.
- **One sensor, addressed by SKIP ROM.** With two on the bus both would answer.
- **The bus hold is modelled after the sixteenth slot.** The scratchpad is not read to
  the end, and a driver that continued would keep clocking slots the model does not
  present.

## See also

- [[protocol-dht11]] — the sibling act whose rule this one inverts, and the
  synchronise-don't-count lesson that comes from it
- [[i2c-on-the-matrix]] — the same pad doing a clocked bus, and why its write idiom
  ("never touch oe or od again") is the wrong one here
- [[physical-layer-gpio]] — the pads, and why `IN A, PIN` reads the pad rather than
  the output register
- [[tx-timing-generation]] — the delay routine, its reload trap, and why a delay and
  its caller must never share a data slot
