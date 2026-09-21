---
title: 10BASE-T Scope — Where the Chip Stops
created: 2026-09-20
updated: 2026-09-20
type: concept
tags: [protocol, architecture, area-budget, constraint]
sources: [raw/articles/janestreet-competition-blog-fulltext.md]
confidence: medium
---

# 10BASE-T Scope — Where the Chip Stops

What "10Mbit Ethernet" as a stretch goal actually asks for, and what it does not.
Written because the obvious reading ("we cannot fit a TCP/IP stack, so Ethernet is
out") rests on a memory figure that was never the requirement.

## What the blog actually says

One line, in full:

> Stretch goals: low-speed USB and 10Mbit Ethernet.

That is the entire primary source on the subject. No mention of TCP, IP, a host
processor, or an off-chip interface. Anything more specific is inference, and this
page is explicit about which parts are inference.

The framing around it is what carries the meaning. The blog describes the device as
a chip that "bit-bangs protocols in firmware rather than fixed logic," useful for
"hardware debugging and reverse engineering," explicitly inspired by RP2040 PIO
state machines and TI PRU cores. Nobody expects a PIO block to terminate TCP. On
that reading **"10Mbit Ethernet" means the line layer**: Manchester coding,
preamble and start-of-frame delimiter, frame structure, CRC-32, link test pulses.

## The 32 KB figure was never the requirement

| | |
|---|---|
| Maximum standard Ethernet frame | 1,518 bytes (1,522 with a VLAN tag) |
| Minimum legal frame | 64 bytes |
| One max frame, stored | **1.5 KB** |
| [[reference/sram-budget]]'s "comfortable" band | 1–2 KB, 8–14% of die |

A whole maximum-size frame fits inside the range the SRAM analysis already called
comfortable. 32 KB belongs to a TCP/IP stack with socket buffers, retransmit queues
and an ARP cache — which is the part that lives off-chip under any reading. Dropping
it does not buy the PHY, because the PHY never cost it.

[[concepts/cdr-oversampling]] already assumes the 1,518-byte figure when it computes
±100 ppm drift tolerance across a frame, so this is consistent with the existing
design record rather than new.

What *does* need to grow is the **data** memory. It is 16 bytes today, which cannot
hold even a minimum-size frame. See [[decisions/adr-003-memory-plan]].

## The real constraint is time, not space

This is the part that decides the architecture.

| Quantity | Value |
|---|---|
| 10BASE-T bit period | 100 ns |
| Clocks per bit at 60 MHz | 6 |
| Clocks per byte | 48 |
| CRC-32 in firmware ([[concepts/factored-hardware-blocks]]) | ~30 instructions/bit = 240/byte |
| Over budget by | 5.0× |

The core is single-cycle, so 48 clocks per byte is 48 instructions per byte for
*everything*. Software CRC is not merely slow here, it is impossible by a factor of
five. (60 MHz improves this from 7.5x at 40 MHz — one of the smaller ways the
higher clock pays off — but it is still out of reach, which is the actual
conclusion.) The consequence:

**For 10BASE-T the firmware sequences frames; it never touches bits.** The DRU, the
Manchester codec, the SERDES and the CRC LFSR all have to be hardware. This is not a
retreat from the "protocols are firmware" thesis — it is the same split
[[STATUS]] already records between the SERDES word engine and the bit-banged core,
applied at the one bit rate where the core cannot participate at all.

## On an SPI-connected host

A reasonable proposal is that the chip streams the bitstream and a host does the
stack. The split is right. The *streaming* is the part to be careful about.

- **Pins are not the problem.** SPI (4) + 10BASE-T (2) = 6 of 24 usable
  ([[reference/protocol-pin-budget]]).
- **Concurrency is.** Streaming the wire straight out means servicing two protocols
  at once on a core with no interrupts. [[plans/through-i2c]]'s risk list already
  flags that as the reason the architecture eventually wants two cores or an event
  path.
- **Store-and-forward removes it.** Receive one frame into SRAM at line rate with
  hardware doing the bit work, then ship it to a host at any speed. That is what the
  frame buffer buys, and it is the strongest argument for the buffer.

**There is no host data path in the design today.** The SoC's `host_*` port is
firmware loading only, and `rtl/tt_um_protocol_emulator.v` ties it off. If a host
port is part of the architecture it is unbuilt, unplanned, and wants a decision
record before the pin matrix fixes the pin assignments.

## The demo that proves it without a stack

A protocol emulator demonstrates 10BASE-T by exchanging one frame and validating the
CRC. It does not need to terminate anything.

**An ARP request/reply is 42 bytes each way and involves no IP stack.** It makes a
real switch or a real host talk to the chip, it fits in the memory planned here, and
it is a far better competition artifact than a partial TCP implementation. An ICMP
echo responder is the next step up and still small.

This is the recommended acceptance test for the stretch goal.

## Status

Nothing on this page is built. `tb/tb_pe_eth.v` passes and proves the Manchester
framing around the SERDES, with CRC-32 computed in the testbench model — which is
precisely the piece the LFSR block has to take over. Unbuilt and required: the DRU
([[concepts/cdr-oversampling]]), the CRC LFSR, the frame buffer, and a host path if
one is wanted.

## Related

- [[concepts/cdr-oversampling]] — the DRU spec; 12× oversampling (SPB=12), 8.33 ns grid at the 60 MHz core.
- [[concepts/factored-hardware-blocks]] — the CRC LFSR (~120 cells) and why no 8b/10b.
- [[decisions/adr-003-memory-plan]] — the two macros that serve this.
- [[reference/sram-budget]] — macro geometry and what fits the die.
- [[reference/protocol-pin-budget]] — 2 pins, plus a transformer on the board.
- [[STATUS]] — where this sits against the rest of the work.
