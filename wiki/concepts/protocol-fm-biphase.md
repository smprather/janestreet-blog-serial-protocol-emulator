---
title: FM0/FM1 bi-phase — a receiver judged on a receiver
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, verification, clocking, physical-layer, architecture]
sources: []
confidence: medium
---

# FM0/FM1 bi-phase coding

> **This act is a designed WIP and it is RED.** `firmware/bmc_frame.pe` and
> `tb/tb_pe_soc_bmc.v` exist on branch `fw-timing-protocols` (commits `e708e69`
> and `b2cb76c`) and are **not in `main`**. The testbench was written RED-first;
> the first firmware draft assembles and runs, and **all seven of its checks
> fail**. Nothing on this page is a measured result, and every figure says so.

`confidence: medium` is deliberate and it is about *status*, not about the
protocol: the wire rules and the design are certain, the act's behaviour is not
yet demonstrated by anything.

- firmware: `firmware/bmc_frame.pe` (on `fw-timing-protocols`)
- testbench: `tb/tb_pe_soc_bmc.v` (on `fw-timing-protocols`)
- state machine: `diagrams/proto-fm-biphase.puml`
- symbol rules and the map: `diagrams/proto-fm-biphase-frame.puml`
- timing, as design constants: `diagrams/proto-fm-biphase-timing.puml`

## Why this act is not a seventh timing act

Every other act in this block is judged on a **waveform a receiver can decode**.
This one is judged on a **receiver**: the code lives in the *transitions*, not in
the levels, and the only clock in the system is the one the receiver recovers
from the data.

So the claim is not *"the firmware drives a bi-phase stream"* but:

> **the firmware RECOVERS THE CLOCK from a stream it shares no clock with, and
> says which encoding it locked onto.**

That is why this page is mostly about the decoder, and why the transmitter is the
smaller half of the state diagram.

## The wire rules, which are the whole protocol

1. A bit is **two half-intervals**.
2. A **1** has **no transition at the end** of its interval, in *both* encodings.
3. A **0** **has** one, in *both* encodings.
4. **FM0 adds a transition at the start of the interval for a 1; FM1 does not.**

Rule 4 is the **only** difference between the two encodings, and therefore the only
thing a receiver has to establish in order to know which one it is reading.

| symbol | first half-interval | second half-interval |
|---|---|---|
| **0** | a transition | a transition |
| **1** in **FM0** | **a transition** ← FM0's | no transition |
| **1** in **FM1** | no transition | no transition |

There is no packet, no header, no length, no checksum and no acknowledge. The whole
of the protocol is in that table.

## Why a receiver cannot skip rule 4

A sample-based edge detector asks *"did the level move?"*. That question is
answered identically by all three symbols, because all three have a transition
somewhere. **It cannot distinguish FM0 from FM1 at all.**

What distinguishes them is a transition in the **middle** of the first half-interval
— a *data transition inside a bit*, not at its edge. So the decoder has to
accumulate half-intervals and decide **once per bit** rather than once per
transition, and that is why `dmem[8]` counts half-intervals and the bit is
assembled in `dmem[12,13]`.

## The decoder's actual job

A bi-phase receiver does not synchronise on a level. It **timestamps the level** and
compares it with the level recorded at the last **change** — and it is that
comparison which recovers the clock.

### The bounce, and it is forced by the ISA

A transition detector wants a store-forward: `X = ram[X]`. On this machine it
**cannot be written**:

- `OP_LDS` (0xB) is `a <= ram[x]` with **no X destination**, so the idiom is
  inexpressible;
- and the encoding that *looks* like it, `LDM X,addr` with `arg[7]=1`, is a
  **direct** load whose address field is the **top nibble only** — it cannot even
  name byte 8.

So the old level lives in a memory byte, and every access to it costs a load and a
store. **And that byte belongs to this decoder and to nothing else**: a scratch
shared between a routine and its caller is how the DS18B20 act lost a byte counter
to the delay routine.

## The bit period is a whole number of microseconds, and that is not tidiness

The half-interval is **2 µs** (120 clocks), so a bit is **4 µs**. The reason is that
the decoder timestamps on the 1 µs counter and compares with the level at the last
change, and **that comparison is only exact if every transition lands on a tick**. A
bit period that is not a multiple of the counter's unit would make the decoder's own
arithmetic the least accurate thing in the act — and a decoder whose timing is its
weakest part is not one that has been measured, it is one that has been assumed.

The half-interval is therefore **counted, not waited on**. A loop waiting on the
free-running tick would inherit the phase residual the WS2812 act documented: up to a
full microsecond, which here is *half a half-interval*.

## The one input the act must be able to fail on

**Every** bit of a well-formed frame carries a transition in its middle, because
"bi-phase" means the level changes *within* the interval. So a line held **constant** —
which is what a disconnected, shorted or dead sensor looks like on the wire — has no
transitions at all, carries no clock, and a receiver that locked on to it has locked
on to nothing.

That is the stream the last check presents, and the firmware's answer to it must be a
**declared failure** (`dmem[3] = 0xFF`) rather than a byte it invented.

**A decoder that cannot fail is not a decoder.**

## The instrument was wrong first, and it is the most useful thing on this page

The first version of `tb_pe_soc_bmc.v` claimed that **a run of ones in FM1 was the
"no transitions" stream**, and therefore not a decodable frame.

It is not. A run of ones is a **clean square wave** — one transition per bit, in the
middle — and the decoder recovers its clock from exactly those transitions. The claim
was in the **testbench header, in the encoder, and in two WORKLOG lines**, and it was
wrong in all four.

It was the **instrument** that was wrong, which is the pattern this whole block exists
to demonstrate. And it is why the act was written with **two decoders from the wire
rules** rather than one decoder and one encoder that agree by construction: **a pair
that agrees by construction agrees even when both are wrong.**

## The enable trap, and it is the sixth of its kind

`PINOE = 0x00` releases every pad, **and in particular the input**. A pad the
firmware *drives* reads back its own register through `PIN`, not the wire, so
**claiming the input pad means the firmware never sees the stream at all.**

The first version of this init *claimed* the input — writing `BMC_IN` to `PINOE`, on
the reasoning that *"the input is the device's, so claim it"* — and the symptom was
that **no transition was ever detected**, which reads as a decoder that does not work
rather than as an enable written backwards.

**It is the sixth time in this block that a level and an enable have been confused**,
and the only reason it was found at all is that the testbench's check *names the flag*
and the flag was `0xFF`.

## The sixteen bytes, and why the map is the design

| bytes | what |
|---|---|
| 0,1,2 | the three bytes recovered from the input pad |
| 3 | the **encoding flag**: 0 = FM0, 1 = FM1, 0xFF = no transitions — the observable |
| 4 | the level at the last **change** (the bounce) |
| 5 | the microsecond timestamp of the last change |
| 6 | the byte the program **encodes** onto the output pad |
| 7, 8, 9 | bit counter; half-intervals accumulated in the current bit; byte index |
| 10, 11 | previous 1 µs reading for the elapsed difference; phase (0 = decode, 1 = encode) |
| 12, 13 | the bit under construction, then the byte being shifted out |
| 14, 15 | scratch for the elapsed time and the shift |

**Three bytes per direction, and the limit is the machine.** A receiver's state — the
transition timestamp, the previous level, the bit counter, the phase flag and the frame
being assembled — is most of sixteen bytes, and the bounce byte is most of the rest.
The limit is stated here rather than discovered later, because a receiver that runs out
of memory mid-frame produces a plausible wrong answer and nothing else.

## Both directions, and neither side is told what the other sent

The testbench encodes a byte on `IN_PAD` and the firmware must recover it; the
firmware encodes on `OUT_PAD` and the testbench's decoder — **written from the same
wire rules, not from the firmware** — must recover it. That is the loopback, and it is
the only way either half is checked against something other than itself.

## What is *not* modelled

One inter-frame gap, and **no noise, no jitter and no line-length limit**. Those are
the things a real receiver's worst case lives in, and pretending otherwise would be
claiming a robustness this act does not test.

## Where it has to go next

The act is RED on a first draft. The shape of the work is the same as every other act
in this block and is stated here so the next session does not have to re-derive it:

1. the seven checks are the **reference**, not a description of them;
2. the flag is the first thing to read on a failure — `0xFF` means the decoder never
   saw a transition, which is the enable trap, not a decoding bug;
3. a receiver that returns a byte for the constant-line stream is worse than one that
   returns nothing, so that check must stay.

## See also

- [[protocol-freqmeter]] — the sibling act that also *listens* and also recovers a
  quantity rather than a waveform
- [[protocol-ws2812]] — the other clockless act, and the phase-residual argument for
  counting rather than waiting
- [[physical-layer-gpio]] — the pads, and why claiming an input pad means reading your
  own register back
- [[protocol-ds18b20]] — the act that lost a byte counter to a shared scratch, which is
  why the bounce byte here belongs to nobody else
