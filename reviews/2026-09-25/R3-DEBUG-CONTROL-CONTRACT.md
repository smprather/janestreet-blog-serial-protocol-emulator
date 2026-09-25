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
* **S3 (a hit stops the core, in a distinguishable state).** A breakpoint stops
  BEFORE the instruction at its address executes: while the core is advancing
  and its LANDING address (`dbg_next_pc`) equals an armed `bp_addr`, the core is
  held at that edge, so the PC reads `bp_addr` and the instruction there has NOT
  been executed -- the classic stop-before semantics a debugger expects (it can
  inspect and then step that very instruction). No `imem`/`dmem`/`io` side
  effect of that instruction occurs. The state is observable: state=3 in STATUS
  and DEBUG_STATUS, bit1 in bp_flags. A step that lands on the armed address
  latches the hit the same way (stop-before still holds: the landed instruction
  has not run).
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
| 11 | `debug_bp_clr_while_stopped_is_boot_stop` | debug hold at pc=3, run=0 | `DEBUG_BP_CLR` len=0 | `(OK, 0 /*stopped*/, pc=3, bp_addr_before, flags)` — the `pc` field is the PC **at the request**; the core re-zeroes at that same edge, so a following `DEBUG_STATUS`/`STATUS` reads `pc=0` (documented release semantics) |
| 12 | `debug_bad_crc_no_side_effect` | stopped, disarmed | `DEBUG_BP_SET` len=1 with a corrupt CRC | `(BAD_FRAME, …)`; `DEBUG_STATUS` shows `flags=0x00` (not armed) |
| 13 | `debug_status_common_prefix` | running, pc=4, bp armed at 2 | `DEBUG_STATUS` len=0 | `(OK, 1, pc=4, bp_addr=2, flags=0x01, run=1, a, x, y, insn=<the LANDING word>)`. **CORRECTED (was `insn=imem[4]`)**: `pe_cpu` fetches at `next_pc` while executing, so a free-running readback reports `imem[pc+delta]` — here `imem[2] = 0xF000`, the landing word of the `JMP 2` at 4, not `imem[4]`. A TB that wants `insn = imem[pc]` must hold the core (state 2) or preload the pipeline |
| 14 | `debug_unsupported_target` | loopback target selected | `DEBUG_STEP` len=0 | `(UNSUPPORTED, …)` |

Notes for the vector author: `pc`/`pc_next`/`bp_addr` are 10-bit values held in
the low bits of a 16-bit word. `insn` is the 16-bit instruction the core is
FETCHING, which follows the fetch mode — `imem[next_pc]` while executing,
`imem[pc]` while held, `imem[0]` at the boot stop; it is NOT unconditionally
`imem[pc]`.

**At a freeze, `insn` reports the LATCHED pipeline word** — whatever the fetch
presented last (the fill `0xF000` when the pipeline holds nothing), and NOT a
word re-derived from `pc` or `next_pc` at the instant of the read. A test
harness that synthesises a mid-execution snapshot (pinning `pc` every cycle to
hold a core that is genuinely running) collapses the pipeline, so its `insn` is
the collapsed one; a model must latch the same word rather than recompute
`imem[next_pc]`. **No RTL changes for this** — `pe_cpu` already reports the
latched word; the disagreement was in how the snapshot was synthesised. The `run` strap is a pin, not a host-bus register, so a vector that
needs the core running declares it as pre-state (and the TB drives `ui_in[1]`).

Rows 11 and 13 of this table were WRONG and have been corrected against the
implemented RTL by manager ruling 2026-09-25 (see the changelog at the end).
The RTL was right in both; a doc table is not a reason to change truthful RTL.
The host's golden vectors follow the RTL, and the per-step byte table is
`reviews/2026-09-25/R3-VECTOR-BYTES.md` (gui-worker, generated from the
contract).

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

---

## Implementation record (2026-09-25)

**Where the logic landed.** `pe_cpu` gained `dbg_hold`/`dbg_step` inputs and a
`dbg_next_pc` output; the execute gate became `cpu_exec = dbg_step || (run &&
!dbg_hold)` and the PC update became "advance on `cpu_exec`, preserve while
`dbg_hold`, zero only on the boot stop". The fetch address follows the same three
modes (`next_pc` while executing, `pc` while held so `imem_rdata` stays equal to
`imem[pc]`, zero at the boot stop), preserving the pipeline invariant R2's read
arbitration depends on. `pe_ctrl` owns the opcode decode, the breakpoint register
(`bp_addr`/`bp_en`/`bp_hit`), the hold/step registers, the stop-before hit
comparison on the LANDING address, and the four response shapes; the R3 header
block above is pasted into the file. `pe_soc` routes the three wires and `tt_um`
connects them — **no pad, no ISA change**.

**TDD and gates.** `tb/tb_pe_ctrl_r3.v` (real `pe_ctrl` + real `pe_cpu` + a
registered imem model) was written first and run RED against the RTL with the
ports but no decode: every debug op answered `UNSUPPORTED` (42 failures), then
GREEN. `regress/mutate_ctrl_r3_tb.sh` runs **7 mutants** — step-no-hold,
step-stuck-pulse, bp-hit-no-hold, bp-stop-after (the wrong comparison),
bp-set-no-range, bp-clr-no-release, and status-state-old — and **all 7 are
DETECTED**. Wired into `run_all.sh`.
Formal: `formal/pe_cpu/formal_pe_cpu.v` proves S1–S4 (one instruction per step,
the hold preserves the PC, the PC changes only by executing or the boot stop)
**unbounded** by temporal induction; `formal/pe_ctrl/formal_pe_ctrl.v` adds H1
(a hit implies the hold) and H2 (a hit implies state 3), proved in the inductive
subset. Formal mutants: `pe_ctrl_bp_hit_no_hold` CAUGHT; 11/11 formal mutants
caught overall.

**Two findings from the verification, both recorded honestly.**

* **H3 was VACUOUS and was removed.** "An armed address is inside instruction
  memory" (`fv_bp_addr < WORDS`) is a tautology at the shipping parameterisation
  (10-bit register, 1024 words) — the mutant that removes the RANGE guard PROVED
  it. The real protection is refusing the **full-width** request so a
  1024..65535 word cannot truncate into a small address; that transition claim
  is owned by the TB (case C2) and its mutation, where it **is** differential.
  A vacuous claim in the proof would have been trusted, and that is the one
  failure mode the campaign's rules exist to prevent.
* **Unconnected debug inputs float to X.** TBs that instantiate `pe_cpu`/`pe_soc`
  directly left `dbg_hold`/`dbg_step` unconnected, so the execute gate went X and
  the core froze: the full suite caught it immediately (`tb_pe_soc_tick`'s first
  three failures). All 13 TBs now tie the debug inputs low with a comment, and
  the suite is green again. The port addition is exactly the kind of change that
  no unit TB can find on its own — the integration suite is what found it.

**Known limits.** The breakpoint is ONE address, PC-only, and the ISA is
unchanged. `DEBUG_STEP` refuses a free-running core (`NOT_READY`, no side
effect). `DEBUG_BP_CLR` is the only release, so continuing with the breakpoint
armed uses the step-off → clear → re-arm recipe above. The response `pc` in a
`DEBUG_BP_CLR` is the PC at the request; with run=0 the core re-zeroes at the
same edge, so the next op reads 0.

## Changelog

**2026-09-25 — manager ruling: §3 table rows 11 and 13 were WRONG, the RTL is
RIGHT.** The gui-worker flagged the disagreement while reconciling its golden
vectors against this contract and declined to guess. Ruling: never change
truthful RTL to match a doc table, so the TABLE was corrected and no RTL moved.
This is also why the host vectors are trustworthy — they were generated from
the implemented contract, and the chip is what has to pass them.

* **Row 11 (`debug_bp_clr_while_stopped_is_boot_stop`)** expected `pc=0` in the
  `DEBUG_BP_CLR` response. The RTL answers the PC **at the request** (3) and
  re-zeroes the core at that same edge, so the *following* read reports 0. The
  RTL's own comment and this file's `Known limits` already said so; only the
  table row disagreed. Corrected, with the "same edge" explanation kept.
* **Row 13 (`debug_status_common_prefix`)** expected `insn=imem[4]` while
  free-running. `pe_cpu` fetches at `next_pc` while executing (`pc` while held,
  0 at the boot stop), so a free-running readback reports the **landing** word:
  `imem[2] = 0xF000`, the target of the `JMP 2` at address 4. The table's
  `imem[4]` was a stale-numbering error. Corrected, and the general
  "instruction at the reported PC" wording in the author notes was corrected with
  it — `insn` follows the fetch mode.

**2026-09-25 (later) — the one line the model boundary needed.** The conformance
run measured one step whose `insn` disagreed because its pre-state is a
mid-execution *snapshot* and the harness's freeze collapses the fetch pipeline.
The rule is now stated above (`insn` is the latched word at a freeze), the
divergence is pinned in `tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt`, and the RTL is
unchanged. If the host's model adopts the rule the package regenerates and the
step becomes confirmable; nothing in the chip moves either way.

The reference for the per-step bytes is the gui-worker's
`reviews/2026-09-25/R3-VECTOR-BYTES.md` (14 vectors / 26 steps, generated from
the implemented contract). `tb_pe_ctrl_r3` consumes its `r3-hex/` package
byte-exactly; `chip_confirmed` flips only when that TB passes those bytes.
