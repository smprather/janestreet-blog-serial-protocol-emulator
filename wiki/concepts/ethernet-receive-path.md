---
title: 10BASE-T receive, in hardware
created: 2026-09-22
updated: 2026-09-22
type: concept
tags: [protocol, verification, architecture, cdr, signoff]
sources: [rtl/pe_eth_mac.v, tb/tb_pe_eth_mac.v, regress/mutate_eth_mac_tb.sh, rtl/pe_crc.v, rtl/pe_dru.v, rtl/pe_nrzi.v, rtl/pe_manch.v, rtl/pe_bitstuff.v, rtl/pe_fbuf.v, wiki/reference/crc-config.md]
confidence: high
---

# 10BASE-T receive, in hardware

`rtl/pe_eth_mac.v` — the first protocol block in this project that is deliberately
**not** firmware, and the reason is arithmetic rather than taste:
[[concepts/ethernet-scope]] computes that at a 100 ns bit period the single-cycle
core has 48 instructions per byte, and a software CRC-32 alone needs ~240. So the
bit work is hardware and the firmware only sequences frames.

**914 cells**, measured. It is the block where four previously-**orphaned** pieces —
`pe_dru`, `pe_manch`, `pe_crc`, `pe_fbuf` — stop being orphans and become one
signal path. That is the reason to build it at this point in the project: three of
those four had been sitting in `rtl/` passing their own testbenches while driving
nothing, and an orphan block is a claim that has never been exercised inside a
design.

## What it does

```
pe_dru  ──bit_en, rx_first, rx_second──▶  pe_manch ──rx_raw, rx_err──▶  pe_eth_mac
                    │                                                        │
                    └── rx_first/rx_second ──▶ (carrier sense)               │
                                                                             ▼
                                       pe_crc ◀──crc_bit_en, crc_bit_in──  frame
                                       pe_fbuf ◀──fbuf_we, addr, data────  store
```

1. **SFD lock** — shift every valid bit into an 8-bit window; a window of `0xD5`
   is a frame start, if the line has been idle (see the gate below).
2. **Byte assembly** — LSB-first, 14 header bytes then the payload. The MAC
   addresses and the length/type field stay in **registers**, not the buffer: a
   minimum-size frame is mostly header, and storing it would push the payload out
   of a 2 KB ring.
3. **FCS check** — the field is folded exactly as transmitted and compared against
   the RevEng catalogue residue.
4. **Store-and-forward** — payload into `pe_fbuf`; on a bad FCS the write pointer
   rolls back so a bad frame leaves nothing behind.

## The FCS convention is the part that is easy to get wrong

`pe_crc` offers two self-consistent receiver contracts, and only one is checkable
against an outside value. Measured over a 42-byte ARP-shaped frame **before** the
RTL was written:

| Fold the field… | Result | Verdict |
|---|---|---|
| exactly as transmitted | `R == 0xDEBB20E3` | the **catalogue residue** — this project's choice |
| un-complemented | `R == 0`, `crc_zero` asserts | the other reading |

So `crc_field_out` is held **low** (a receiver folds the field as ordinary data;
`pe_crc`'s field mode exists for *emitting* a field so a transmitter's register
drains), and the verdict is `crc_state == CRC_RESIDUE`, never `crc_zero`.

The residue is preferred because it is an **outside** value: it comes from the
RevEng catalogue and `tools/gen/crc_config.py` re-derives it under the drift gate,
so agreeing with it is evidence. Checking `crc_zero` instead would be the engine
marking its own homework — and would reject every valid frame while looking exactly
like a CRC bug. Constants: [[reference/crc-config]].

IEEE 802.3's bit order does not need a reversal here, and that is worth stating
because the obvious reading says otherwise: 3.2.9 transmits the FCS `x^31` first,
but the standard also gives the equivalent right-shifting formulation — octets
LSB-first, FCS emitted LSB-first — in its own words "resulting in identical
transmissions". This project uses that formulation, so there is no bit reversal
anywhere in the receive path.

## Two frame kinds, because ARP is not a length frame

The 16-bit field after the MAC addresses is a **length** below `0x0600` and an
**EtherType** at or above it. This is easy to miss and decisive: the acceptance
target for this block is an ARP exchange, ARP is EtherType `0x0806`, and reading
`0x0806` as a length demands a 2,054-byte payload that cannot fit — so a
length-only receiver rejects *every ARP frame* while passing any hand-made
length-frame test.

| | length frame (< 0x0600) | type frame (>= 0x0600) |
|---|---|---|
| how it ends | by count, from the field | when the line goes idle |
| size known | at the header | only at the end |
| bounds enforced | at the header, **before any write** | per byte, as the payload arrives |
| FCS | **not** written | written, then the pointer winds back 4 |

That last row is the whole of `is_type`'s effect on storage, and it is why the
wind-back is conditional: a length frame's FCS bytes were never written, so winding
back would corrupt the ring.

## Carrier sense is a detector, not a port

A 10BASE-T line signals a frame purely by the **presence of transitions** — idle is
a held level. The DRU emits `bit_en` on its phase grid whether or not the line is
alive (its header is explicit that `locked` is a confidence indicator, **not** a
gate), so `bit_en` alone says nothing about activity.

The first draft made this a `wire_active` **input port**. That is wrong: nothing in
the design would generate it, so it would be a port driven by the testbench and
nothing else. A receiver that cannot tell a live line from a dead one is not a
receiver, so carrier sense is derived here.

**And the idle signature is not what it looks like.** Measured on a held line
(`tb_idle`), the DRU emits cells whose halves are **equal**, while *both*
`pe_manch`'s `rx_err` **and** `pe_dru`'s `locked` stay **0**. Neither can mark
idleness: `rx_err` is strobe-gated on a committed cell, and `locked` counts
well-formed cells from a counter that equal-half cells do not advance. The only
reliable signal is the equal-halves property itself, taken from the DRU's two
half-cell outputs. A Manchester cell *guarantees* its halves differ, so this is the
codec's own definition of a valid cell read as a level instead of a pulse.

## The hunt is gated by idle, and the gate must be a latch

Without a gate, a receiver that has just **aborted** a frame keeps hunting inside
the abandoned frame, where a payload `0xD5` locks it into a phantom frame.
Measured: it made one rejected frame report `frame_bad` **twice**. IEEE 802.3's
inter-frame gap is 96 bit times, so requiring idle before hunting is the standard's
rule, not a heuristic — and it is what lets a rejected frame's debris stay
unreachable.

The gate must be a **latch** (armed by idle, cleared when a frame locks), not a live
`idle_run >= N` comparison: the preamble is itself 56 **valid** cells, so a live
comparison drops to false exactly when the SFD arrives and no frame would ever
lock. Measured — that is precisely what the live version did.

## Every bit is held one cycle, and the phase is read from `state`

`pe_manch`'s `rx_err` is **registered**: on a cell's strobe cycle it still holds the
*previous* cell's verdict. A receiver that consumed each bit on its own strobe would
take in one idle bit before it could see the error, fold it into the CRC, and then
reject a perfectly good frame — with the residue mismatching, so it would look like
a CRC bug. So each bit is latched and acted on one cycle later, when `rx_err` has
caught up.

The phase of the delayed bit is `state`, **not a saved copy of it**. The invariant:
every state transition is decided on the cycle that consumes a phase's last bit, so
that bit is consumed while the machine is still in that phase's state. An earlier
draft latched a `from` register alongside the bit; that mis-attributes the *first*
bit of every phase — the first body bit after the SFD is strobed on the cycle the
SFD is consumed, so `from` records `S_SEARCH` and the bit would be dropped from the
CRC.

## Bounds: reject, do not clamp

The length is attacker-controlled and the ring is 2 KB. A frame that cannot fit is
**rejected at the header, before a single byte is written**, so nothing of it enters
the ring. Clamping would store a truncated frame that every later stage treats as
complete; writing even one byte before rejecting would leave debris.

A length frame can never overflow the ring on its own (the field is below `0x0600`,
so the legal maximum is 1,535 payload bytes and 1,535 + 4 fits 2,048) — the
reachable overflow is a long **type** frame, which has no ceiling. That is the case
the per-byte `room` check exists for. Note the header check compares the **raw
field** against `room` with no allowance for the FCS: a length frame does not store
its FCS, so adding 4 would reject legal frames that fit exactly.

## How it is verified

`tb/tb_pe_eth_mac.v` drives **raw Manchester levels** into the real DRU and checks
the bytes that come out the far end — so every byte asserted is one a receiver
knowing nothing about this design would recover. Six frames: a length frame, an ARP
reply, a bad FCS, a single flipped payload bit, an oversize length frame, and a long
type frame.

The FCS is computed by a **left-shifting** reference straight from the reflected
definition, while the RTL shifts **right** from a reversed polynomial, so agreement
is a cross-check rather than the same arithmetic twice.

`tb_pe_eth.v` already covered `pe_serdes`' Manchester framing, but it builds the
preamble, header and FCS **in the testbench** and its "preamble" is 58 bits rather
than 802.3's 64. It is a serdes unit test, not a wire-format reference, and nothing
in the new TB copies its conventions.

`regress/mutate_eth_mac_tb.sh` breaks the RTL in eight ways — FCS convention, wind-back,
the settling delay, byte assembly, the type/length split, the bounds check, the idle
gate, the abort — and requires the TB to catch all eight. Two findings from it are
worth carrying forward:

- **`no-bounds-check` survived the first version.** The gap was real: the payload's
  own `room == 0` check produces the same `frame_bad` count, so removing the header
  check was invisible. Catching its *distinct* contribution needed a test that the
  buffer was **untouched** — done with a `0xEE` guard pattern planted past every
  legitimate frame, because the FLOP array starts as `x` and a zero-check would fail
  on a correctly-untouched buffer.
- **The harness itself was a bug.** Its first version restored with
  `git checkout`, and `rtl/pe_eth_mac.v` was **untracked** — so every restore failed,
  all eight mutations stacked, and it printed "8 detected, 0 survived": a perfect
  score that meant nothing. It now snapshots with `cp` and verifies with `cmp` after
  every mutation.

## The trap that cost the most time: a preamble is not an octet

IEEE 802.3 describes the preamble as "seven octets of the pattern 10101010", which
reads as `0xAA`. But a byte helper sends **LSB-first**, so `send_byte(8'hAA)` puts
`01010101` on the wire — the **inverted phase**. The junction with the SFD then
creates a *second*, false `0xD5` window seven bits early; the receiver locks there
and every byte comes out as a mash of its neighbours, which looks exactly like a
broken receiver.

The preamble is a **wire bit pattern**: `1010…` starting with 1, and it must be
driven as bits, not through a byte helper. The SFD (`0xD5`) is the one everyone
remembers, which is why only the SFD gets the treatment.

Related, and the reason the SFD logic is now minimal: **0xD5 is unreachable in a
well-formed preamble**. Enumerating the 64-bit prelude, the only window that
assembles to `0xD5` is the SFD itself, and every earlier window is `0x55` or `0xAA`.
An earlier draft carried an "alternating run must exceed N bits" guard on the theory
that the window alone was ambiguous; it was not merely redundant but **harmful** —
a receiver that started listening a few bits into the preamble would see a short run
and drop the frame. Hand-deriving the window set gave the wrong answer twice;
enumerating it in code settled it immediately.

## Where it stands

Wired, as of 2026-09-23. `pe_soc` instantiates the whole chain on port bit 7 and
exposes the frame window on IO `0x8-0xE`; `firmware/eth_rx.pe` consumes an ARP
frame through it; `tb/tb_pe_soc_eth.v` drives the wire into the SoC and checks
the dmem evidence, and `regress/mutate_eth_soc_tb.sh` proves that TB's checks
can fail (7/7). The block diagram no longer marks any of `pe_eth_mac`, `pe_dru`,
`pe_crc` or `pe_fbuf` as an orphan.

Related: [[concepts/ethernet-scope]] (why this is hardware at all),
[[concepts/cdr-oversampling]] (the DRU), [[concepts/strobe-and-committing-edge]] (the
strobe contract this block depends on), [[reference/crc-config]],
[[decisions/adr-003-memory-plan]] (the frame buffer),
[[concepts/factored-hardware-blocks]] (the shared-primitive thesis),
[[reference/simulator-bakeoff]] (the simulators this is verified on).
