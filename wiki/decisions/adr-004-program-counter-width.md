---
title: ADR-004 — SRAM instruction memory, and the PC width it requires
created: 2026-09-20
updated: 2026-09-20
type: decision
tags: [decision, area-budget, architecture, process-node]
sources: [rtl/pe_cpu.v, pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v]
confidence: high
---

# ADR-004 — SRAM instruction memory, and the PC width it requires

## Status

Accepted as the plan of record. **Not implemented.** Supersedes
[[decisions/adr-003-memory-plan]] on the *implementation path* (the macro choice
stands); corrects a claim in [[plans/through-i2c]] Blocker 3.

## Context

Two things arrived on 2026-09-20 that decide this together: the vendor SRAM
behavioral model turned out to be shipped in the PDK (so the macro can be
simulated, not guessed at), and reading the CPU against a 1024-word memory
exposed a contradiction the memory plan had not noticed.

### The macro's real contract (read from the PDK, not recalled)

From `RM_IHPSG13_1P_core_behavioral_bm_bist.v`, the vendor's own model:

```verilog
always @(posedge CLK_MUX) begin
   if(MEN_MUX==1'b1 && WEN_MUX==1'b1) begin
        memory[ADDR_MUX] <= (memory[ADDR_MUX] & ~BM_MUX) | (DIN_MUX & BM_MUX);
        if (REN_MUX==1'b1) dr_r <= (memory[ADDR_MUX] & ~BM_MUX) | (DIN_MUX & BM_MUX);
    end
    else if(MEN_MUX==1'b1 && REN_MUX==1'b1) begin
        dr_r<=memory[ADDR_MUX];
    end
end
```

Three facts, each of which a driver can get wrong silently:

1. **`A_BM[i] = 1` means "write bit i"** — the model's own comment says
   *"write bit mask, write enabled on bit [i] if BM[i]=1'b1"*. Tying `A_BM` to
   zero does NOT write; tying it to all-ones writes every bit.
2. **Read latency is one cycle**, matching the datasheet's "one-cycle
   data-access". `A_DOUT` follows the address by one clock.
3. **`A_REN=1` during a write means WRITE-THROUGH** — the read port returns the
   *new* value, not the stored one. Harmless for a pure write, but it means
   `REN` is not free to leave asserted; a driver that ties `REN` high gets
   read-data that is a function of whatever was on `DIN`, not of memory.

`A_DLY` must be tied to 1 (the wrapper's own simulation guard `$stop`s
otherwise). BIST is unused: `A_BIST_EN=0` muxes the whole BIST port away.

### The contradiction the memory plan missed

[[plans/through-i2c]] Blocker 3 says the swap *"does not change the CPU's
interface or its cycle model, because the instruction port was written for a
registered ROM from the start."* That is true of the **cycle model** and false
of the **address width**:

| IMEM_WORDS | IAW | `imem_addr` vs the CPU's 8-bit PC |
|---|---|---|
| 128 | 7 | fine — `pc` is 8 bits, memory is shallower |
| 256 | 8 | exactly fits |
| **1024** | **10** | **`next_pc[IAW-1:0]` = `next_pc[9:0]` on an 8-bit vector** |

`pe_cpu.v` declares `logic [7:0] a, y, x, pc;` and encodes jump targets as
`arg[7:0]`. So:

- The reachable program is **256 words no matter how deep the memory is**.
- At `IMEM_WORDS=1024` the expression `next_pc[IAW-1:0]` is an out-of-range
  part-select, which is exactly the class of defect [[STATUS]] gotchas 12 and 16
  are about: it may simulate, and it will not mean what it looks like.

**So the memory swap alone does not deliver 1024 usable words.** It delivers 128
usable words and 896 words of addressable-by-nothing SRAM, at 79,674 µm². The
PC and the jump-target field have to widen in the same change or the area is
spent for nothing.

## Decision

Widen the program counter and the jump-target field, then swap the memory. The
two are one change, not two.

The operand field has room, which is why this is cheap:

```
instruction = [15:12] opcode | [11:0] operand
JMP / JZ / JNZ currently use arg[7:0]  ->  arg[11:8] are UNUSED (four spare bits)
```

A 10-bit target fits in `arg[9:0]` with no encoding conflict. `LDM`'s `arg[7]`
destination-select trick is a different opcode, so it cannot collide. `arg[8]`
is currently sunk as `_unused_arg8`; it becomes part of the target.

| Item | From | To |
|---|---|---|
| PC / `next_pc` | 8 bits | 10 bits (IAW, parameterised) |
| Jump target field | `arg[7:0]` | `arg[9:0]` |
| `dbg_pc` port | 8 bits | PCW bits |
| IMEM depth | 128 | 1,024 (`1P_1024x16_c2_bm_bist`) |
| `peasm` IMEM_WORDS | 128 | 1,024 |

**Do not widen past what the memory can hold.** The assembler already rejects an
over-long program, and it must keep doing so — the PC width is now a second way
to silently alias, so `peasm`'s range check on jump targets becomes load-bearing
rather than belt-and-braces (gotcha 16).

## Why 1,024 and not 512

512 words (`1P_512x16`) saves 34,365 µm² and lands the design at 46% of the 6×4
die instead of 54%. It also fits an 8-bit PC exactly, so it needs NO CPU change
at all — which is a genuinely cheaper option and worth stating plainly.

Rejected on program budget, not area: `uart_echo` is already 114 words, an I2C
master with per-bit arbitration is more, and [[STATUS]]'s plan wants two or three
resident protocol programs. 512 is reachable with the preamble/loop overhead of
three protocols but not comfortable. 1,024 also makes `peasm`'s hard failure
recede as a design pressure, which matters more than 34,000 µm² on a die that is
54% full either way.

**If the floorplan struggles, 512 is the documented fallback and it is strictly
easier** — no PC change. That is the reason to record the alternative.

## Consequences

- The CPU change is small but touches the ISA's encoding, so **every testbench
  that hand-assembles instructions must be re-checked**. The `JMP/JZ/JNZ`
  encoders in `tb_pe_cpu.v`, `tb_pe_soc_uart.v` and `tb_pe_soc_tick.v` write
  targets into `arg[7:0]`; they keep working (targets < 256 are unchanged) but the
  fixtures stop demonstrating the wider field.
- `tools/fw/peasm.py`'s `IMEM_WORDS` must move with the RTL, or the assembler and
  the memory disagree about the limit and the wrong one wins silently.
- `tools/fw/peemu.py` mirrors the ISA, so it changes in the same commit or the
  emulator stops being the fast loop (gotcha 11).
- The SoC's load path has to write through `A_BM` with `A_REN=0`, one word per
  cycle. That is 1,024 cycles of load, which is fine for a bench and worth
  recording as a bring-up cost.
- **The flop-memory area claim gets its first measurement.** `pe_soc`'s
  182,650 µm² and the projected 54% occupancy were computed from a flop array;
  this is where the projection becomes a synthesis number.

## Alternatives rejected

- **Swap the macro and leave the PC at 8 bits.** 896 words of dead SRAM for
  79,674 µm², and `next_pc[9:0]` on an 8-bit vector is an out-of-range
  part-select. This is the option the plan accidentally described; it is the one
  to avoid.
- **512 words to avoid touching the CPU.** Documented above as the fallback, not
  rejected outright — it is a real option with a real saving.
- **`1P_1024x32` (2,048 words).** 140,183 µm² and a 12-bit PC. Width beyond any
  program this project can write; the ISA would need a second opcode nibble
  before it was useful.
- **Keep flops and just deepen the array.** Measured at 1,271 µm² and 60 cells
  *per instruction word*, so 1,024 words is ~1.3 mm² of die — three times the
  whole 6×4 budget. This is the measurement that motivated ADR-003.

## Related

- [[decisions/adr-003-memory-plan]] — the macro choice, which stands. This ADR
  supersedes only its implied "and nothing else changes".
- [[plans/through-i2c]] — Blocker 3, whose interface claim this corrects.
- [[reference/sram-budget]] — macro geometry; `1P_1024x16` is 237×336 µm.
- [[concepts/pdk-toolchain]] — where the macro models and liberty live.
- [[STATUS]] — the area table this move is measured against.
