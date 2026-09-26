---
title: "UART with RTS/CTS hardware flow control"
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, physical-layer, verification, architecture]
sources: [firmware/uart_flow.pe, tb/tb_pe_soc_uart_flow.v, tools/fw/peasm.py, diagrams/proto-uart-flow.puml]
confidence: high
---

# UART with RTS/CTS hardware flow control

`firmware/uart_flow.pe` is a 115200 8N1 software UART with a two-wire
handshake. There is no UART hardware in this chip and there is no flow-control
hardware either: the same 8-bit port, the same free-running timer and the same
16-opcode CPU that `firmware/uart_echo.pe` uses for a bare echo now carry two
extra pins. What "hardware flow control" means here is therefore a **program**,
and the claim worth making is about what the program guarantees on the wire, not
about the name of the protocol.

Figures: `diagrams/proto-uart-flow.puml` (the handshake as firmware, ten cells of
8N1, case 1 end to end, the 400 µs window to scale, and the CTS-low-forever
case), with colocated PNG and SVG renders.

## What flow control is for

```
  RTS (ours)      CTS (the receiver's)      TX
  ------------    ---------------------     ---------------
       1    -----> waiting for permission
  <---------  0    not now
  <---------  1    go
                      ...only now does TX move...
       0    -----> nothing left to send
```

RTS and CTS are the only pins in the port map that no other program in the tree
touches, and this program is their only user. The pin map is the shared one:

| bit | direction | signal |
|---|---|---|
| 0 | out | TX |
| 3 | in | RX |
| 4 | out | RTS |
| 5 | in | CTS |

### Assert before wait

The receiver asserts CTS **in response to** RTS. A driver that waited for CTS
before asserting RTS would wait for ever against a receiver that only raises CTS
when asked — a deadlock that no amount of correct bit-banging fixes, and one that
a testbench driving CTS low-then-high can make look like a hang rather than like
an ordering mistake. So the order is: **assert RTS, then wait for CTS**, and the
second case of the testbench is exactly what a receiver in that state looks like.

RTS is asserted **before the byte is even fetched**, and released only after the
last stop bit has been clocked out. Releasing it early would tell the receiver
"the line is yours" while this program is still driving it, which on a real link
is a collision.

## The wire format

One byte is **ten cells**: a start bit, eight data bits LSB first, and a stop
bit. Two ticks per cell.

The payload is `0x00`, `0xFF`, `0xA5`, and the two extremes are the point. `0x00`
is eight zero bits behind a start bit and `0xFF` is eight one bits, so a bit
period a little long or a little short shows up in one of them and not the
other; and `0xA5` (`1010 0101`) is not a bit palindrome, so a transmitter that
shifted the wrong way is visible rather than accidentally correct. Same reasoning
as the `0x5B` in `spi_xfer.pe`.

## Timing

The bit timing is `uart_echo.pe`'s, unchanged: `TIMER` counts one half-bit every
260 clocks (4.3333 µs at 60 MHz), a bit is two ticks, and the wait is "snapshot
the timer once, poll until it moves". The flow-control pins cost no time: the
handshake is two register writes either side of a poll loop that was going to be
there anyway.

Measured by `tb/tb_pe_soc_uart_flow.v` (reproduced on this worktree):

| event | measured |
|---|---|
| CTS released | 417.225 µs |
| first start bit | 417.53 µs — **0.31 µs after the CTS rising edge** |
| byte 0 decoded (`00`) | 499.874 µs |
| byte 1 decoded (`ff`) | 585.853 µs |
| byte 2 decoded (`a5`) | 672.517 µs |
| frame period | 85.98 µs and 86.66 µs, i.e. **8.598 and 8.666 µs per cell** |
| `dmem[3]` (CTS-wait polls) | 255, saturated |

The 0.31 µs is the honest shape of the guarantee: the first start bit comes a
handful of instructions after CTS reads high, not at the same instant, because
between the wait exiting and the start bit there is the payload fetch. The claim
is "at or after", and the number says by how much.

The `dmem[3]` counter **saturates at `0xFF`, and that is not cosmetic.** The
counter is 8 bits and the loop runs one iteration every six clocks, so a
receiver holding CTS low for a millisecond wraps it several times over and the
testbench reads a number that means nothing. Saturating makes the slot a
statement about "it waited, and at least this long" instead of a residue — which
is the only reason a 16-byte data buffer is worth spending a slot on.

## The invariant, and why it is stated as one

> **The wire is idle for every instant in which CTS is low.**

Not "the program eventually transmits" — a bare echo already satisfies that.
Not even "the program waits for CTS before its first start bit", which a one-shot
test could satisfy by accident if the wait sat after the frame. The invariant is
a statement about **every** instant CTS is low, and it is the only one of the
three that a receiver with a full buffer can rely on.

There is a second invariant, and it is the one a receiver would actually be hurt
by: **RTS must be high for every instant TX is not idle.** TX low means this
program is mid-frame — in the start bit or in a zero data bit — and RTS low at
that instant tells the receiver the line is free while we are driving it. That
is the failure a "release RTS when the buffer is empty" implementation makes,
and it is invisible to a check that only compares the first and last edge of the
handshake.

## How the emulator implements it

The program is a flat loop, because the ISA has no CALL/RET and the only thing
worth sharing is the poll:

1. `main` — if three bytes are sent, park with `dmem[12] = 0xA5`.
2. **Assert RTS first** — `LDI A, RTS|UTX / OUT TXPIN`, and `dmem[4] = 0x10`.
3. **`wait_cts` — a poll, not a timeout.** Read `PIN`, mask `CTS`, and while it
   is low increment `dmem[3]` and saturate. A real driver bounds this wait and
   gives up on a dead receiver; there is no retry policy here, and the count in
   `dmem[3]` is the evidence that the loop ran.
4. **Fetch the payload by dispatch.** `LDS A, [X]` is X-indexed with *no
   offset*, so `dmem[8+index]` is not addressable: X can only *be* the address.
   A table lookup at a variable index is three compares and three loads. The
   first version wrote `LDS A, [X]` with X holding the index, which fetched
   `dmem[index]` — and for index 0 that is `dmem[0]` itself, the register the
   fetched byte is about to be stored into, so the first byte was whatever the
   data buffer held at reset (`x`), driven with RTS on the wire for a whole
   frame. The symptom was a first byte that decoded as `xx` while the second and
   third were perfect, which is a shape no bit-timing bug produces.
5. **Ten cells** with RTS re-asserted inside *every* `OUT`
   (`LDI A, RTS` for the start bit, `AND A,1 / OR A,RTS` for each data bit,
   `LDI A, RTS|UTX` for the stop bit), so it cannot be dropped by a refactor of
   the bit loop.
6. **Release RTS, and only now** — after the last stop bit.

## How the testbench proves it

`tb/tb_pe_soc_uart_flow.v` is a per-clock sample of the **line**, not a poll of
a counter, which is what makes it a claim about the wire: a program that drives
a start bit while CTS is low is caught on the very clock it happens, whatever
its internal state says afterwards.

Two cases, and **the pair is what makes the wait non-vacuous**:

1. **CTS low for 400 µs, then released.** 400 µs covers more than three whole
   frames, so a transmitter that ignored CTS would have finished the whole
   payload inside the window — that is what makes the window a real test rather
   than a formality. Checked: CTS really was low for a while; TX never left idle
   while CTS was low; RTS was asserted **before** CTS was read; every CTS rising
   edge was seen with RTS already asserted; the first start bit is at or after
   the CTS rise; RTS was released once per frame; RTS stayed high for every
   instant TX was not idle; the three bytes decode; `dmem[2] == 3`;
   `dmem[3] > 0`; `dmem[4] == 0x00`; `dmem[12] == 0xA5`.
2. **CTS low for ever.** Checked: TX never left idle; **no byte was transmitted
   at all**; no start bit was ever seen; `dmem[2] == 0`; the firmware did not
   finish; `dmem[3] > 0x10` (the wait is a loop, still spinning); RTS **stays**
   asserted while the receiver says no.

Case 1 alone would be satisfied by a program that checks CTS once at a fixed
point and then ignores it. Case 2 is the direction that catches that.

The 8N1 receiver decodes the pins, sampling at **1.5** bit periods after the
falling edge — the 1.5, not the 0.5. The first version waited half a bit period,
which is the middle of the *start* bit, so every byte came back as the start
bit's own value with the rest shifted: `0x00` decoded as `0x02` and `0xFF` as
`0x04`, which is exactly a one-bit rotation of the payload and looks like a
bit-order bug in the transmitter, which was fine.

## Mutation coverage

Four mutations in `regress/mutate_fwbus_tb.sh`, all detected:

| mutation | what it breaks | caught by |
|---|---|---|
| `uart-cts-ignored` | reads CTS and then ignores it | the invariant (7756 clocks of TX low while CTS was low) and the ordering (a start at 251 µs against a CTS rise at 417 µs) |
| `uart-rts-never-asserted` | RTS is simply absent | every byte still arrives intact and every bit is still correctly timed — only the handshake-order checks can see this |
| `uart-rts-dropped-mid-frame` | `OR A, RTS` removed from the data-bit `OUT` | the `rts_low_while_tx_low` monitor |
| `uart-payload-dispatch` | `pay1: LDM A, 9` → `LDM A, 10` | the wrong payload byte, with nothing else disturbed |

The third deserves its note, because an earlier version of it **survived**: the
mutation "release RTS at the start of the stop bit" survives, and that is correct
— it is not a defect. The stop bit is HIGH, so the line looks idle for its whole
duration and a receiver cannot distinguish "released during the stop bit" from
"released after it". Several real drivers do release RTS there. The monitor is
scoped to instants TX is **low**, which is exactly that distinction.

## See also

- [[concepts/physical-layer-gpio]] — the open-drain and direction rules the pin
  map rests on
- [[concepts/spi-as-firmware]] — the other protocol that reuses this port, and
  what its bit loop costs
- [[concepts/factored-hardware-blocks]] — why the same port carries five
  protocols and nothing in the RTL knows which is running
- [[concepts/protocol-midi]] — the same 10-cell UART frame at a rate this one
  cannot express from ticks
