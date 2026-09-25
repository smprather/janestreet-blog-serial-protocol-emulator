# R3 debug control — the wire contract (FROZEN for implementation)

Status: **draft-for-implementation, manager ruling 2026-09-25.** This document is
the contract: the block below is written to go into `rtl/pe_ctrl.v`'s header
before any RTL changes, and the golden-vector spec at the end is what the
gui-worker turns into vectors in parallel. Nothing here is implemented yet when
this file is written; the implementation and its proofs must match it exactly.

Scope (manager, ruling-bounded): (1) a host command that executes exactly one
instruction and returns to stopped; (2) ONE hardware breakpoint on PC, set and
cleared through the host bus, whose hit stops the core with a distinguishable
STATUS state; (3) readback of the breakpoint address and hit state. New opcodes
live in 0x21-0x2F. No new pads. No ISA changes. Same framed CRC/sequence/target
rules. Same wait-word semantics: these are ready-immediate like READ_CPU — ZERO
wait words.

---

## 1. The contract block (verbatim, for the pe_ctrl header)

```text
// THE R3 DEBUG CONTRACT (landed 2026-09-25; manager dispatch "R3 debug-control
// phase"). R2 made "observe" real; R3 makes "debug" real. These are the wire
// changes a HOST must implement:
//
//   0x21 DEBUG_STEP   -> (OK, state, pc_next, bp_addr, bp_flags)
//                        ONE request payload word is NOT expected: len must be
//                        0. Executes EXACTLY ONE instruction and returns to the
//                        stopped-with-debug-hold state. Allowed when the core is
//                        stopped (run=0) or already held (a breakpoint hit);
//                        NOT_READY while the core is free-running (run=1), with
//                        NO fault. A step from the normal boot stop (PC=0)
//                        executes imem[0]; a step off a breakpoint CLEARS the
//                        hit unless the step LANDS on the breakpoint again.
//                        The response's state and bp_flags are for the state
//                        AFTER the step; pc_next is the address the next step
//                        will execute from.
//   0x22 DEBUG_BP_SET -> (OK, state, pc, bp_addr, bp_flags)
//                        ONE request payload word: the breakpoint address. The
//                        address must be < IMEM_WORDS, else the answer is RANGE
//                        and the breakpoint is NOT armed and NOT changed (a
//                        rejected op has no side effect). Arming clears a stale
//                        hit. Allowed while running: the armed breakpoint then
//                        stops a LIVE core the cycle its PC matches.
//   0x23 DEBUG_BP_CLR -> (OK, state, pc, bp_addr_before, bp_flags)
//                        len must be 0. Disarms the breakpoint, clears the hit,
//                        and RELEASES the debug hold: with run=1 the core
//                        resumes; with run=0 it returns to the normal boot stop
//                        (PC=0). This is also how a host resumes a core that a
//                        breakpoint stopped. Idempotent (safe when disarmed).
//   0x24 DEBUG_STATUS -> (OK, state, pc, bp_addr, bp_flags, run, a, x, y, insn)
//                        len must be 0. The full debug readback: the common
//                        5-word prefix plus the architectural state, same field
//                        meanings and widths as READ_CPU (run is the STRAP
//                        level). Answered while running and while held.
//
// state (2 bits, low half of the word; the upper bits are ZERO):
//   0 STOPPED       the normal boot stop: run=0, no debug hold, PC held at 0
//   1 RUNNING       the strap is high and no debug hold is asserted
//   2 DEBUG_HOLD    held by the debug controls with the PC PRESERVED (single-
//                   stepping); the core is not executing
//   3 BP_HIT        held by the breakpoint: the PC preserved, the hit latched
// R2's STATUS `state` word carries THE SAME encoding: its old values 0/1 keep
// their meaning, and 2/3 are new states that only debug control can enter. No
// R2 field changes shape.
//
// bp_flags (low bits; the rest ZERO): bit0 = breakpoint ARMED, bit1 = HIT
// latched. bp_addr is the armed address, or 0 when disarmed; a breakpoint at
// address 0 is legal and is distinguished from "disarmed" by bit0.
//
// WAIT WORDS: these four ops are READY-IMMEDIATE -- they are answered from
// registers in the request's own CRC cycle, exactly like READ_CPU, so they emit
// ZERO 0xFFFF filler words. The wait-word rule stays what it is for the bounded
// reads (0x13/0x14) only.
//
// TARGETS: the debug ops are TARGET_HOST only; the loopback target answers
// UNSUPPORTED like any other op it does not implement.
//
// FAULTS: no new fault class. A malformed frame (bad CRC, bad length, bad
// header) answers BAD_FRAME and has NO side effect -- no step, no arming. A
// sequencing refusal answers NOT_READY with no fault, exactly like LOAD while
// running and the bounded reads while running.
//
// WHERE THE LOGIC LIVES (no new pads): pe_ctrl owns the opcode decode, the
// breakpoint register and flags, the hit comparison against the core's PC (it
// already receives dbg_pc), and the debug-hold/step outputs. pe_cpu takes two
// new INPUTS and exposes one new OUTPUT:
//   dbg_hold  MASKS the run strap: while high the core does not execute and
//             PRESERVES its PC (unlike the boot stop, which holds it at 0).
//             The execute gate becomes
//               cpu_exec = dbg_step || (run && !dbg_hold)
//             and the PC updates only on `cpu_exec`, is preserved while
//             dbg_hold, and is zeroed only on the boot stop (run=0, no hold).
//   dbg_step  a one-cycle pulse from pe_ctrl: executes EXACTLY one instruction
//             and advances the PC to next_pc.
//   dbg_next_pc  the combinational next PC (the landing address of the step
//             about to execute). pe_ctrl samples it in the dispatch cycle, so
//             the DEBUG_STEP response reports the landing PC even though the
//             instruction commits at the following edge -- the PC and the
//             fetched instruction are frozen in between, by construction.
// pe_soc routes the three wires. tt_um's pin map is unchanged: the run strap
// remains a pad, and the debug controls are host-bus only.
```

## 2. Semantics, stated as the properties the implementation must have

* **S1 (one instruction per step).** A `DEBUG_STEP` commits exactly one PC
  update and exactly one set of instruction side effects (`io_we`, `io_re`,
  `dmem_we` are asserted for that one cycle at most). While held and not
  stepping, the PC is stable and no side effect is asserted.
* **S2 (the PC is preserved in a debug hold).** In `DEBUG_HOLD`/`BP_HIT` the PC
  keeps its value across arbitrarily many cycles; only the normal boot stop
  (run=0, no hold) re-zeroes it, exactly as R2's read arbitration requires.
* **S3 (a hit stops the core, in a distinguishable state).** If the breakpoint
  is armed and the core is executing with `pc == bp_addr`, then on the next
  cycle the core is held (`BP_HIT`) and no further instruction executes. The
  state is observable: state=3 in STATUS and DEBUG_STATUS, bit1 in bp_flags.
* **S4 (a step off the breakpoint clears the hit).** From `BP_HIT`, a
  `DEBUG_STEP` that does not land on the armed address clears the hit; if the
  executed instruction lands on the armed address again, the hit stays latched.
* **S5 (rejected ops have no side effect).** A frame that fails CRC/length/
  header validation, or a `DEBUG_BP_SET` past `IMEM_WORDS`, changes no debug
  register and executes no instruction.
* **S6 (no waits, no faults).** The four ops emit zero filler words and add no
  fault class; refusals are `NOT_READY`, bad frames are `BAD_FRAME`.

## 3. Golden-vector spec (the gui-worker's input; extend the R2 package shape)

Reuse the R2 package conventions (`reviews/2026-09-25/r2-hex/`): one directory
per vector set, `manifest.json` with per-step `request_file`/`response_file`,
the preloaded `imem.hex`/`dmem.hex`, and per-step register state
(pc/a/x/y/insn/run/faults/words_written — plus, for R3, `bp_addr`, `bp_en`,
`bp_hit`, `debug_hold`). Responses are compared word for word, wait words
skipped (there are none for these ops).

Program image for the stepping vectors (word address : instruction):

```text
  0 : LDI A,0x55
  1 : LDI A,0xAA
  2 : NOP
  3 : LDI A,0x0F
  4 : JMP 2
```

| # | vector | pre-state | request | expected response (payload words, opcode byte) |
|---|---|---|---|---|
| 1 | `debug_bp_set_readback` | stopped (run=0, pc=0) | `DEBUG_BP_SET` len=1, payload `0x0002` | opcode `0xA2`, `(OK, 0 /*stopped*/, pc=0, bp_addr=2, flags=0x01)` |
| 2 | `debug_bp_set_out_of_range` | stopped | `DEBUG_BP_SET` len=1, payload `0x0400` (=1024) | `(RANGE, 0, pc=0, bp_addr=<unchanged>, flags=<unchanged>)`; imem/registers untouched |
| 3 | `debug_bp_set_wrong_length` | stopped | `DEBUG_BP_SET` len=0 | `(BAD_FRAME, …)`; no arming |
| 4 | `debug_step_executes_one` | stopped, pc=0 | `DEBUG_STEP` len=0 | `(OK, 2 /*debug hold*/, pc_next=1, bp_addr, flags)`; then `DEBUG_STATUS` shows `pc=1`; `READ_CPU` shows `a=0x55` |
| 5 | `debug_step_sequence` | stopped | `DEBUG_STEP` ×2 | second response `pc_next=2`, and `DEBUG_STATUS` shows `a=0xAA` (the LDI at 1 executed exactly once) |
| 6 | `debug_step_while_running` | run=1, pc=7 | `DEBUG_STEP` len=0 | `(NOT_READY, …)`, no PC change, no hold |
| 7 | `debug_step_lands_on_bp` | stopped, pc=0, bp armed at 2 | `DEBUG_STEP` ×2 | second response: `state=3 /*BP_HIT*/`, `pc_next=2`, `flags=0x03` |
| 8 | `debug_bp_hit_stops_live_core` | run=1, pc=0, bp armed at 2 | (clock the core to the bp) | `DEBUG_STATUS` after the hit: `state=3`, `pc=2`, `flags=0x03`, `run=1` (the STRAP is still high); a second STATUS shows `pc=2` unchanged |
| 9 | `debug_step_off_bp_clears_hit` | hit state from 8 | `DEBUG_STEP` len=0 | `state=2`, `flags=0x01`, `pc_next=3` |
| 10 | `debug_bp_clr_resumes` | hit state from 8 | `DEBUG_BP_CLR` len=0 | `(OK, 1 /*running — the strap is high*/, pc=2, bp_addr_before=2, flags=0x00)`; the core then runs |
| 11 | `debug_bp_clr_while_stopped_is_boot_stop` | debug hold at pc=3, run=0 | `DEBUG_BP_CLR` len=0 | `(OK, 0 /*stopped*/, pc=0, …)`; the PC is re-zeroed (documented release semantics) |
| 12 | `debug_bad_crc_no_side_effect` | stopped, disarmed | `DEBUG_BP_SET` len=1 with a corrupt CRC | `(BAD_FRAME, …)`; `DEBUG_STATUS` shows `flags=0x00` (not armed) |
| 13 | `debug_status_common_prefix` | running, pc=4, bp armed at 2 | `DEBUG_STATUS` len=0 | `(OK, 1, pc=4, bp_addr=2, flags=0x01, run=1, a, x, y, insn=imem[4])` |
| 14 | `debug_unsupported_target` | loopback target selected | `DEBUG_STEP` len=0 | `(UNSUPPORTED, …)` |

Notes for the vector author: `pc`/`pc_next`/`bp_addr` are 10-bit values held in
the low bits of a 16-bit word. `insn` is the 16-bit instruction at the reported
PC. The `run` strap is a pin, not a host-bus register, so a vector that needs
the core running declares it as pre-state (and the TB drives `ui_in[1]`).

**The resume recipe, stated because a debugger needs it.** `DEBUG_BP_CLR` is
the only op that releases the debug hold, and it also disarms. To CONTINUE a
core whose breakpoint is still wanted, a host does: `DEBUG_STEP` (step off the
breakpoint; the hit clears, the core stays held) → `DEBUG_BP_CLR` (release; with
run=1 the core resumes) → `DEBUG_BP_SET(addr)` (re-arm while it runs). The core
cannot instantly re-hit: it left `bp_addr` when it stepped, and the strap
resumes it from the step's landing address. `DEBUG_BP_SET` while running clears
any stale hit, so the recipe is idempotent. A host that does not care about the
breakpoint just issues `DEBUG_BP_CLR` once.

## 4. Verification plan (chip side, RED-first)

1. **Golden vectors first** → `tb_pe_ctrl_r3.v`, RED on the unmodified RTL (the
   opcodes answer UNSUPPORTED), then GREEN.
2. **Directed TB cases** (in the same TB, RED-first per case as it is written):
   one-step PC/register effects, the hit-stop, step-off-bp, the no-side-effect
   on a bad frame, and the STATUS state encoding (2/3).
3. **Mutation gates**: `regress/mutate_ctrl_r3_tb.sh` (or extend the existing
   ctrl mutation harness) with mutants such as: step pulses twice; step does not
   hold (PC not preserved); hit does not stop; hit does not set the state;
   bp_set past the bound arms anyway; bad-CRC arming; bp_clr does not release.
   Every mutant must be CAUGHT by the TB.
4. **Formal claims** (`formal/pe_cpu/`, `formal/pe_ctrl/`):
   * pe_cpu: S1+S2 — while `dbg_hold && !dbg_step && !run`: the PC and all side
     effects are frozen; a `dbg_step` commits exactly one PC update
     (`pc' == next_pc` and no more than one update between holds).
   * pe_ctrl: S3+S5 — `bp_hit → state == BP_HIT and dbg_hold`; a `DEBUG_BP_SET`
     past `IMEM_WORDS` cannot arm; the hit latch only sets from a comparison
     while the core is executing.
   Claims go through the campaign's `formal/fv_run.sh` (cap + flock + the
   shape-matched mutant rule), with per-claim status in the formal review.
5. **Full suite** (`regress/run_all.sh`) including the new TB, the mutation
   suite and the formal gate, with the glossary regenerated if any port changes
   (none is expected: no new pads and no new module ports except the three
   internal debug wires, which ARE ports on pe_cpu/pe_soc/pe_ctrl — regenerate
   and note them).
