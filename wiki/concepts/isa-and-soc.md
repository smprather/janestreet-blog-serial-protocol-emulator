---
title: The ISA — 16 opcodes, the single-cycle choice, and the budget it creates
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [architecture, protocol, constraint]
sources: [rtl/pe_cpu.v, rtl/pe_eth_mac.v, rtl/pe_crc.v, wiki/concepts/ethernet-scope.md]
confidence: high
---

# The ISA

The thesis is one sentence, and it is the project's: **protocol logic belongs
in software.** `pe_cpu` is the smallest thing that can run a protocol, so a
protocol becomes a *program* — patchable, reloadable, shareable — instead of a
state machine in gates. This page is the shape of that core and the rules the
firmware is allowed to rely on. For orientation, start at
[[concepts/overview]]; the wiring underneath this core is
[[concepts/soc-wiring-and-memory]], the framing the host sees is
[[concepts/host-chip-protocol]], and the competition framing is
[[concepts/competition-overview]].

## The 16 opcodes

Encoding is `[15:12]` opcode, `[11:0]` operand — 16-bit fixed width, no
addressing modes.

| op | mnemonic | effect | op | mnemonic | effect |
|---|---|---|---|---|---|
| 0x0 | LDI a,imm8 | `a = imm8` | 0x8 | INCX | `x = x + 1` |
| 0x1 | OUT port,a | `io[port] = a` | 0x9 | DECX | `x = x - 1` |
| 0x2 | IN a,port | `a = io[port]` | 0xA | SHR a | `a = a >> 1` |
| 0x3 | MOV sel | 0 `a<-y`, 1 `y<-a`, 2 `x<-a`, 3 `a<-x` | 0xB | LDS a,[x] | `a = ram[x]` |
| 0x4 | JMP addr8 | `pc = addr8` | 0xC | STS [x],a | `ram[x] = a` |
| 0x5 | JZ addr8 | `if (a == 0) pc = addr8` | 0xD | LDM a,addr8 | `a = ram[addr8]` |
| 0x6 | JNZ addr8 | `if (a != 0) pc = addr8` | 0xE | STM addr8,a | `ram[addr8] = a` |
| 0x7 | ALU sub,imm8 | sub: 0 add, 1 sub, 2 and, 3 or | 0xF | NOP | — |

**Registers.** One 8-bit accumulator `A`, one 8-bit scratch `Y`, one 8-bit
pointer `X`. PC width is *derived* from instruction-memory depth — 8 bits at 128
words, **10 at 1024** — because it must be able to name every word it can fetch;
the old fixed `logic [7:0] pc` silently capped the address space and had to go.

**Flags: only `a == 0`**, tested by JZ/JNZ — no carry, no overflow. `ALU sub` is
only ever "subtract an immediate and branch if the result hit zero", which is how
every loop and every byte comparison in the firmware is written; the cost is that
firmware needing carry does subtraction itself.

**Register discipline:** `X` is the long-lived index (a line-buffer pointer)
addressed through with no offset, so never a scratch counter; `Y` is transient
scratch; the 16 data bytes hold loop counters and fixed slots. That split is
*why* the ISA carries both X-indexed (LDS/STS) and immediate-addressed (LDM/STM)
memory ops: one register cannot be both pointer and counter.

Also absent, deliberately: no stack, no interrupts, no subroutine call, no
multiply, Harvard organisation (separate instruction port and data buffer).

## Single cycle, and what it buys

**Instruction fetch and IO read are combinational** — one instruction, one clock.
Two consequences, both load-bearing.

**Cycle-exact timing.** Every instruction boundary *is* a clock boundary, so a
delay expressed in instructions is a delay in clocks with no pipeline depth to
reason about. The firmware-protocols work leans on this: measured bit cells come
from counted instructions, not a timer, because a timer cannot express a
fraction of its own period ([[concepts/tx-timing-generation]]).

**Reverse-execution feasibility.** With no pipeline and no multi-cycle state,
any instruction boundary is a reachable, deterministic state — the precondition
for stepping a core backwards, and why the blog's "hardware debugging and reverse
engineering" goal is reachable on hardware this small. It is also the property
R3's debug control consumes ([[concepts/debug-control]]).

**The budget this creates, and the three styles it picks between.** A
single-cycle core at 10BASE-T's rate gets **48 clocks per byte, so 48
instructions per byte for everything** — framing, the whole path, and any CRC. A
software CRC-32 costs ~240 per byte, **over budget by 5×**. So Ethernet's bits
must be hardware and firmware may only *sequence* frames.

That arithmetic is what chooses between the project's three implementation
styles, which `concepts/overview.md` tabulates and this page does not repeat:
**firmware bit-bang** where control flow is per-bit, a **word engine** where
firmware cannot reach the rate but the line code can be a register, and
**dedicated hardware** where the bit work provably exceeds the core's
arithmetic — 10BASE-T being the third case. The instruction budget is the whole
justification for the third, so the styles are *consequences* of this core's
arithmetic rather than an independent taxonomy
([[concepts/ethernet-scope]]). The project's standing instruction is not to
"unify" them.

⚠ **A number still drifting.** That budget was 40 MHz once: 32 clocks/byte and
**7.5×**. At 60 MHz it is 48 and **5×** (240/48 = 5 exactly). `rtl/pe_eth_mac.v`
has the current 5×; `rtl/pe_crc.v` and `concepts/factored-hardware-blocks.md`
still say 7.5× — both outside this worker's ownership, so recorded not fixed. A
reader meeting both without this note will assume a contradiction.
