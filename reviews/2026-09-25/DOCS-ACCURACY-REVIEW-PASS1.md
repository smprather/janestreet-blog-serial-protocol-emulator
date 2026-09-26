# Docs accuracy review — pass 1 (2026-09-25)

Author: protocol-worker, acting as the accuracy gate for the docs fleet. Scope:
review every **technical claim** on the documentation branches against the RTL and
the frozen contracts. Corrections are routed to the owning worker **via the
manager**; nothing on anyone's branch was edited.

Reviewed: `docs/diag-proto` (3 commits, `8f37218`/`514399f`/`accc75b`),
`docs/wiki-features` (1 commit, `bdcae3b`). `docs/diag-timing` and
`docs/diag-bus` have no commits yet — nothing to review, and both are noted as
still open rather than passed.

**Summary: 3 corrections, both in `docs/diag-proto`'s two maps; the two NEW
protocol diagrams and the whole feature brainstorm are accurate as written.**
Two of the three corrections are the kind a reader cannot check without opening
two files, which is the whole value of this pass.

---

## 1. Corrections — owner: **pw-diag-proto**

### C1 (medium) — the execute-gate expression is the PRE-repair form, in all three places

The maps state, as current RTL:

```text
cpu_exec = dbg_step || (run && !dbg_hold)
```text

at `diagrams/project-plan.puml:166`, `diagrams/project-progress.puml:175` and
again at `:297`.

**Ground truth today** — `rtl/pe_cpu.v:233`:

```verilog
wire cpu_exec = (dbg_step === 1'b1) || (run && !(dbg_hold === 1'b1));
```text

That is fw-timing's two-layer repair (`3657847`, merged as `b252f0c`): case
equality, so an **undriven** debug input is inactive by default. The *semantics*
the maps attach to the expression are still true — a hold is released only by
`DEBUG_BP_CLR` or reset, and the run strap is ignored in both directions — so this
is not a behaviour claim that has gone false.

It is still worth correcting, for two reasons. The literal expression a reader
checks does not match the file, and the maps state **nowhere** the convention the
repair introduced. That convention is the reason six timing acts sat at reset after
`5b4731f`: a testbench that leaves `dbg_hold` unconnected now reads it as
inactive instead of X, and a document that shows the old expression cannot tell a
reader which behaviour the RTL has. Suggested wording: quote `pe_cpu.v:233` as it
stands, and add one clause — *an undriven debug input reads as inactive, which is
why a testbench that omits the tie-off cannot wedge the core.*

### C2 (low-medium) — the debug-control contract lists 3 of the 4 debug opcodes

`project-plan.puml:107` and `project-progress.puml:174` both read:

```text
Debug-control contract: 0x21 STEP / 0x22 BP_SET / 0x23 BP_CLR
```text

The frozen contract defines **four** (`reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md`):

```text
0x21 DEBUG_STEP   -> (OK, state, pc_next, bp_addr, bp_flags)
0x22 DEBUG_BP_SET -> (OK, state, pc, bp_addr, bp_flags)
0x23 DEBUG_BP_CLR -> (OK, state, pc, bp_addr_before, bp_flags)
0x24 DEBUG_STATUS -> (OK, state, pc, bp_addr, bp_flags, run, a, x, y, insn)
```text

and `0x24` is implemented: `pe_ctrl.v:1110-1119`, `resp_len = 10`, ten payload
words. The dispatch for this worker names "R3 debug control
(STEP/BP/**DEBUG_STATUS**)" explicitly, so the omission is a gap against the
brief as well as against the contract. `0x24` is also the one that reports `run`,
which is the asymmetry the held-core steps pin.

### C3 (low, but it inverts a conclusion) — "the tick" is ambiguous, and the ambiguity flips the claim

`project-progress.puml:184` and `:198` call the acts' timebase "**one 260-clock
tick**"; `:257-258` says "a 32 us bit is 7.38 ticks and 4.3333 us cannot express a
fraction"; `:267-268` says "a 4 us bit is 0.923 of a tick, so DMX is the rate the
tick cannot express **AT ALL**".

The arithmetic is correct **for the 260-clock UART half-bit**: 260/60 MHz =
4.3333 us, 32/4.3333 = 7.38, 4/4.3333 = 0.923. But `pe_soc` has **two**
timebases:

* `TICKS_PER_BIT = 260` — the 4.3333 us UART half-bit (`pe_soc.v:279`)
* `I2C_TICKS = CLK_HZ / 1_000_000` — the **exact 1 us tick** (`pe_soc.v:560`)

So a reader who takes "the tick" to mean the project's 1 us tick — the one the I2C
and timing work is built on, and the one `docs/demo-walkthrough.md` calls "exact" —
draws the opposite conclusion: **4 us is exactly 4 ticks of the 1 us tick**, so
"the rate the tick cannot express AT ALL" is false for it. The claim is only true
of the 260-clock half-bit, and the maps never name which one they mean. Fix by
naming it ("the 260-clock UART half-bit, 4.3333 us") wherever the tick is load-
bearing, and by not letting "the tick" stand alone next to a conclusion.

## 2. Verified CORRECT — no correction

**`diagrams/proto-spi-framing.puml` and `diagrams/proto-r2-read-path.puml`** (the
two new protocol diagrams). Every falsifiable claim was checked against
`rtl/pe_ctrl.v`, and all 29 claim-bearing lines hold:

| claim | ground truth |
| --- | --- |
| response = opcode with bit 7 set; `0x01` asks, `0x81` answers | `RESP_BIT = 8'h80` (`pe_ctrl.v:360`) |
| CRC poly `16'h1021`, init `16'hFFFF`, no reflect, no final XOR | `pe_ctrl.v:26-28, 441-450` |
| filler is emitted **only** by 0x13/0x14; 0x12 and 0x21-0x24 emit zero | `r_is_read = (OP_RDIMEM \|\| OP_RDMEM)` only (`pe_ctrl.v:508`) |
| the 11-word header, field for field | `pe_ctrl.v:889-900` (STATUS) and `:911-922` (DUMP_CORE) — status, state, run, target, pc, a, x, y, timer, faults, words_written |
| `A` stays 8 bits | `{8'b0, dbg_a}`; the ISA is the source of truth |
| fault bits `0x0001` LOAD, `0x0002` CRC, `0x0004` RANGE | `pe_ctrl.v:369-371` |
| READ_CPU is 7 words: status, pc, a, x, y, **insn**, run | `pe_ctrl.v:929-936`, `resp_len = 7` |
| "16 slots minus the status word is 15 data words" | `MAX_READ_WORDS = 15` (`:394`), `resp_buf[0:15]` (`:570`) |
| "30 bytes for READ_DMEM" | the dmem ceiling is `2 * MAX_READ_WORDS` = 30 bytes (`:1019`), which is 15 data words — the units are right |
| "R2 grew the response buffer from 8 to 16 slots" | `29d32c4`: `resp_buf[0:7]` → `resp_buf[0:15]` |
| RANGE latches the sticky bit, never wraps | `:996-1000`, `:1018-1022` |
| imem address = word index / dmem = byte index, 2 bytes per word, high byte first | `:988`, `:1016-1017`, `:1255` |

One note for the record, because it is the sort of thing that *looks* wrong and is
not: I twice suspected a unit error in the "30 bytes for READ_DMEM" figure, on the
reading that a 15-count ceiling meant 15 bytes. It does not — the dmem ceiling is
`2 *` the word ceiling. The diagram is right and my arithmetic was the thing at
fault. Recorded because the same reflex, applied to a real error, is worth having.

**`wiki/plans/feature-brainstorm.md`** (33 ideas, 1183 lines). The ideas are
proposals; the **grounding table** at the top makes factual claims about what
exists, and every one checked out:

| claim | ground truth |
| --- | --- |
| 16-opcode core | 16 opcode constants, `0x0`-`0xF` |
| `A`/`X`/`Y` 8-bit; `PCW` = 10 bits at 1,024 words | `pe_ctrl.v:895-898`; `clog2(1024)` |
| `I2CTICK` at port `0x4`, the exact 1 us tick | `I2C_TICKS = CLK_HZ/1_000_000` (`pe_soc.v:560`); `firmware/i2c_pins.pe`: "I2CTICK (port 4) increments once per microsecond (60 clocks exactly)" |
| `TIMER` at port `0x5` | `firmware/uart_echo.pe`: "TIMER (port 5) is an 8-bit counter incrementing once per HALF bit period" |
| `A55A` sync, CRC-16/CCITT-FALSE, sticky faults, `IRQ_N` | `pe_ctrl.v:26-28`; `fr[0] = 16'hA55A` in every frame builder |
| "a breakpoint is one PC address — no watchpoint, no data breakpoint" | single `bp_addr`/`bp_en`/`bp_hit`; no data compare exists |
| a hold is released only by `BP_CLR` or reset | `pe_ctrl.v:1102-1104` |
| `READ_IMEM`: 15 words per round trip, ~69 frames | `MAX_READ_WORDS = 15`; 1024/15 = 68.3 |
| "a 250 ns `half_phase` edge" is not visible to a 1 us sample | consistent with the 1 us tick claim and the word-engine timing |

## 3. Method, and what this pass does not claim

Each claim was taken from the document, turned into a checkable statement about
the RTL or the frozen contract, and answered with a line cite. Where my own first
reading disagreed with a document, the document was re-read before it was called
wrong — twice, and both times the document was right (the dmem ceiling; the
`16`-opcode and port greps, which missed because the RTL uses named constants and
the firmware comments, not literals).

**Not covered by pass 1:** `docs/diag-timing` and `docs/diag-bus` (no commits yet);
the claim that the NEC half-period spread of 787.95-794.95 clocks is consistent
with `demo-walkthrough.md`'s "789 clocks a half period" was noted as consistent but
**not** independently re-measured; and the MIDI/DMX measured rates
(31,998.7 ns, 3,999.8 ns, 88.06 us) are fw-bus's own measurements, quoted rather
than re-measured. This is a rolling pass: the next one picks up whatever has
landed since.
