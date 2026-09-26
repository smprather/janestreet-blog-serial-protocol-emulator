---
title: Host-chip protocol — framing, opcodes and the contracts a host must honour
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, architecture, verification]
sources: [rtl/pe_ctrl.v, rtl/pe_cpu.v, rtl/pe_soc.v, reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md, reviews/2026-09-25/R2-READ-PATH-REVIEW.md, reviews/2026-09-25/R2-HELD-CORE-CHIP-SIDE.md, reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md, diagrams/proto-spi-framing.puml, diagrams/proto-r2-read-path.puml]
confidence: high
---

# The host-chip protocol

`pe_ctrl` is the chip's side of the host bus. The host — a Pico bridge on the
Tiny Tapeout demo board — drives CS_N/MOSI/SCK and reads MISO; the chip decodes
framed commands, loads instruction SRAM, and reports status and faults. The
wrapper maps the row to `uio[4:7]`, with IRQ_N on `uo_out[1]`. There is no ROM
on this chip, so instruction memory powers up holding whatever the SRAM macro
happens to contain — the host bus is the only way to get a program in.

The contract lives in the header comment of `rtl/pe_ctrl.v`, written to be
read by whoever writes a host. It is the primary source for this page; the
frozen review documents named in `sources:` are the evidence behind it. See
[[concepts/spi-as-firmware]] for the *other* SPI in this project, the firmware
master, which shares nothing with this bus but the name.

Drawn: `diagrams/proto-spi-framing.puml` and `diagrams/proto-r2-read-path.puml`.

## The frame

SPI mode 0, MSB-first, 16-bit words. **CS_N low spans one complete
transaction** — the request frame and the response frame together, not one
frame each. A host that raises CS_N between them gets a second transaction and
a second response.

| word | request | response |
|---|---|---|
| 0 | `sync = 16'hA55A` | `sync = 16'hA55A` |
| 1 | `{version[3:0], opcode[7:0], target[3:0]}` | same shape, **opcode bit 7 set**, target echoed |
| 2 | `sequence` | `sequence` **echoed** |
| 3 | payload length, **in 16-bit words** | payload length |
| 4..N | payload | status code, then payload |
| N+1 | CRC-16/CCITT-FALSE | CRC-16/CCITT-FALSE |

Version is 1. The CRC covers **every preceding word including the sync word**;
poly `16'h1021`, init `16'hFFFF`, no reflection in or out, no final XOR. The
constants are catalogue-checked by `tools/gen/crc_config.py` and should not be
retyped.

Two details earn their keep. **Opcode bit 7 is what makes the two directions
asymmetric**: a request never has it set, so a response is distinguishable from
a request by that bit alone — `0x01` PING asks, `0x81` PING answers. A request
arriving with bit 7 already set is not a request; it answers UNSUPPORTED with
no fault. And **length is counted in words, not bytes and not frames**:
`"len must be 0"` for DEBUG_STEP is a real constraint, because the wrong length
is a BAD_FRAME, which is what makes "a rejected op has no side effect" true.

The first response payload word is always a status code: `0` OK, `1` BUSY,
`2` BAD_FRAME, `3` RANGE, `4` FAULT, `5` UNSUPPORTED, `6` NOT_READY. A
sequencing refusal is NOT_READY and latches nothing; a malformed frame is
BAD_FRAME and latches `FAULT_CRC` / `FAULT_PROTOCOL`.

## The wait-word rule

A bounded read cannot answer inside the request's own bit times. The chip must
*fetch* first, and each fetched word is a round trip. So during the fetch the
chip **drives `0xFFFF` filler words on MISO** — the pad is OE-on and driven,
not floated, so the level is deterministic on silicon — and the real frame
begins at the first non-`0xFFFF` word. The host skips **leading** fillers and
then validates the frame exactly as it always would.

Three things make the rule safe rather than heuristic:

* **A filler can never be a header.** Every response sets opcode bit 7, and
  version and target are bounded, so no header word is all ones.
* **The skip is leading-only**, so a `0xFFFF` *inside* a payload is data.
* **Worst case is 15 filler words** — a read returns at most 15 data words (16
  response-buffer slots minus the status word), one round trip each.

It is also backward compatible: an R1 response is ready immediately and carries
**zero** wait words, so an unchanged R1 host needs no change at all. The
response *bytes* are unchanged; wait words are transport-level only. And the
rule is **scoped to `0x13` READ_IMEM and `0x14` READ_DMEM** — the only ops that
must fetch. READ_CPU and the four debug ops answer from registers in the
request's own CRC cycle and emit no filler, so a host must tolerate fillers
without assuming every op has them.

## The opcodes

R1: `0x01` PING, `0x10` LOAD, `0x11` STATUS, `0x16` CLEAR_FAULT, `0x20` TARGET.
R2: `0x12` READ_CPU, `0x13` READ_IMEM, `0x14` READ_DMEM, `0x15` DUMP_CORE.
R3: `0x21` DEBUG_STEP, `0x22` DEBUG_BP_SET, `0x23` DEBUG_BP_CLR, `0x24`
DEBUG_STATUS — see [[concepts/debug-control]], which is where the debug half of
this lives.

**READ_CPU is the only non-halting read.** It answers while `run=1`, which is
the entire point: a debugger must be able to see a running program. Registers
are reported at their **native** widths — `pc` at the full PCW (10 bits in a
1,024-word machine, which is why the old 8-bit `dbg_pc` truncation had to go),
`a`/`x`/`y` 8 bits, `insn` 16. A stays 8 bits: the ISA is the source of truth
and no field is invented. The host's own model had a 13-bit A, and that was a
model bug, not a chip bug.

**READ_IMEM** takes `(address, count)` in **words**, ascending. **READ_DMEM**
takes `(byte address, byte count)` in **bytes**, two bytes per response word,
**high byte first**. **DUMP_CORE** returns the STATUS header word for word
while stopped, and is NOT_READY while running — with *no* fault.

## The 11-word core header

STATUS and DUMP_CORE return the same eleven words: `status, state, run, target,
pc, a, x, y, timer, faults, words_written`. `state` is 2 bits in the low half
with the upper 14 zero. `run` is the **strap level**, not a host-bus register.
`faults` is sticky and read back in the same header: `0x0001` FAULT_LOAD,
`0x0002` FAULT_CRC, `0x0004` FAULT_RANGE, `0x0008` FAULT_PROTOCOL, cleared by
CLEAR_FAULT.

The `run`-is-the-strap asymmetry is the one that bites. DUMP_CORE is gated on
`if (run)`, **not** on `if (dbg_hold_r)`. With the strap high the core is
stopped in the debug sense *and* DUMP_CORE must still refuse. Re-gating it on
the hold instead drops the conformance run to 6/22 — the vector catches it, not
an assertion.

## The read-count ceiling

One response frame carries 15 data words. READ_IMEM accepts 1..15 words,
READ_DMEM 1..30 bytes. Beyond that is **RANGE so the host splits the
transfer** — never a silent truncation and never a wrap. An out-of-range
`address+count` is RANGE, **never a wrapped read**, and latches sticky
FAULT_RANGE exactly like a write.

`count == 0` is RANGE *deliberately*, not a zero-length OK frame: an empty read
is a host bug, and answering OK with no words would leave the host unable to
tell "nothing requested" from "read refused". The bounds are checked **before
any read is issued**, so a rejected read never touches memory.

This area earned its keep as a bug surface: of the three real defects R2 found,
one dropped the trailing byte of an odd DMEM count, one never fired the
response launch at all, and one left an X on the MISO pad before the first
frame. None was visible from a spec.

## How this is proved

`tb_pe_ctrl_r2` runs the golden vector package byte-exactly — 22/22 steps
including the four held-core ones, with the held pre-states *reached by driving
the debug opcodes* on a real `pe_ctrl` rather than forced (`reviews/2026-09-25/
R2-HELD-CORE-CHIP-SIDE.md`). The chip side is simulated and mapped-pre-layout
only: **no board has been run, and hardware is not claimed.**

For the formal side, the counts are deliberately two different kinds of number
and must not be conflated: `formal/results/summary.txt` records **10 properties
across 5 modules**, and that stays 10. The **11th target** is the SMT unlock —
`formal/smt_induct.sh` re-runs the same claims through `write_smt2` +
`yosys-smtbmc`/z3, where a register has *one* next-value function instead of one
per sampling domain, and it is what proved the `pe_soc` C2 owner-set guard
under a second, independent engine. A target count must never overwrite a
property count. See [[concepts/factored-hardware-blocks]] for how `pe_ctrl`
relates to the rest of the chip, and [[concepts/pin-matrix]] for the pads this
bus is mapped onto.
