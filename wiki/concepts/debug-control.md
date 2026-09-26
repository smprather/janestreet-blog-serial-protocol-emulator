---
title: Debug control — the four-state machine and the traps a debugger must code around
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [protocol, architecture, verification]
sources: [rtl/pe_ctrl.v, rtl/pe_cpu.v, rtl/pe_soc.v, reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md, reviews/2026-09-25/R2-HELD-CORE-CHIP-SIDE.md, reviews/2026-09-25/R3-CONFORMANCE-AND-RUN-LOCK.md, diagrams/proto-r3-debug-control.puml]
confidence: high
---

# Debug control

R2 made "observe" real; R3 makes "debug" real. Four opcodes, one hardware
breakpoint on PC, no new pads, no ISA change. The contract is the block in
`rtl/pe_ctrl.v`'s header; the frozen document that specified it is
`reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md`. Frame and opcode details are
in [[concepts/host-chip-protocol]]; drawn in
`diagrams/proto-r3-debug-control.puml`.

## The four states

One wire, at `rtl/pe_ctrl.v:553`:

```verilog
dbg_state = dbg_hold_r ? (bp_hit ? 3 : 2) : (run ? 1 : 0)
bp_flags  = {bp_hit, bp_en}     // bit0 armed, bit1 hit latched
```

| state | meaning |
|---|---|
| 0 STOPPED | the normal boot stop: `run=0`, no hold, **PC held at 0** |
| 1 RUNNING | the strap is high and no debug hold is asserted |
| 2 DEBUG_HOLD | held by the debug controls, **PC preserved**; the core is not executing |
| 3 BP_HIT | held by the breakpoint: PC preserved, hit latched |

`state` is 2 bits in the low half of its word, upper 14 zero. R2's old 0 and 1
keep their meaning — no R2 field changes shape — and 2 and 3 are new states
only a debug hold can enter.

Because the encoding is a small integer, a **swapped 2/3 is still a
valid-looking word**. That is exactly why it needed a vector: a mutant swapping
the two passes all 18 shipped R2 steps and fails only the four held-core ones,
18/22. The encoding is not self-checking; the test is.

## The opcodes

`0x21 DEBUG_STEP` (len 0) executes **exactly one** instruction and returns to
held. It answers `NOT_READY` with **no fault and no side effect** while the
core is *free-running*, and the response's `state` and `bp_flags` describe the
state **after** the step, not before — `pc_next` is where the next step will
execute from. `0x22 DEBUG_BP_SET` (len 1) takes one address word; an address
`>= IMEM_WORDS` is RANGE and the breakpoint is **not armed and not changed**,
which is what makes "a rejected op has no side effect" true. `0x23
DEBUG_BP_CLR` (len 0) disarms, clears the hit, and **releases the hold**; it is
idempotent. `0x24 DEBUG_STATUS` (len 0) is the 10-word readback: the common
5-word prefix plus `run, a, x, y, insn`, answered **while running and while
held**.

All four are **ready-immediate** — answered from registers in the request's own
CRC cycle, exactly like READ_CPU — so they emit **zero** `0xFFFF` filler words.
They are `TARGET_HOST` only; the loopback target answers UNSUPPORTED. No new
fault class.

## Gotcha 1 — the run strap is masked BOTH ways under a hold

This is the single most useful thing on the contract, and it is invisible from
the response words.

```verilog
cpu_exec = (dbg_step === 1'b1) || (run && !(dbg_hold === 1'b1))   // pe_cpu.v:233
```

`dbg_hold_r` is cleared at **exactly two places** — reset, and the
DEBUG_BP_CLR branch — and set by a step or by a hit. Nowhere else. So once the
core is held, the run strap does nothing **in either direction**: dropping it
does not resume, and *raising* it does not either. A host that single-steps or
stops on a breakpoint and then "re-asserts run=1 to carry on" finds the core
**still held, with no fault and nothing in the response to explain it.** The
only resume is DEBUG_BP_CLR — which also disarms — or a reset.

**To continue with the breakpoint still wanted:** `DEBUG_STEP` (step off; the
hit clears, the core stays held) → `DEBUG_BP_CLR` (release; with `run=1` it
resumes) → `DEBUG_BP_SET` (re-arm while it runs). The core cannot instantly
re-hit: it left `bp_addr` when it stepped, and the strap resumes it from the
step's landing address. Because BP_SET while running clears any stale hit, the
recipe is idempotent. A host that does not care about the breakpoint just
issues DEBUG_BP_CLR once.

## Gotcha 2 — BP_SET does not clear the hold, and the two hit paths differ

DEBUG_BP_CLR clears `bp_en`, `bp_hit` **and** `dbg_hold_r`. DEBUG_BP_SET
clears `bp_en` and `bp_hit` but **not** `dbg_hold_r`. Arming a core that is
already held therefore does not release it, and nothing reports an error.

The consequence is *not* the general one it first looks like, and this is worth
being exact about. The free-running hit latch is
`if (bp_en && !dbg_hold_r && (run || dbg_step) && (dbg_next_pc == bp_addr))`,
so an armed breakpoint cannot produce a hit on a core that is held and
therefore not advancing. But **the step path is not gated on `!dbg_hold_r`** —
DEBUG_STEP sets `bp_hit` directly from the comparison. So **arming a held core
is legal**, and stepping onto the armed address *does* latch state 2 → 3. A
guard written from the over-broad reading refuses to arm a held core and
breaks legal operation; the host's own conformance run is what caught that.

This is also why the held-core vectors open with `DEBUG_BP_CLR` and **assert**
the release. The first attempt re-armed a core the previous step had just left
held, the hit never latched, and the failure surfaced as a **word mismatch
inside a golden response** — pointing at the STATUS builder when the cause was
two opcodes earlier.

## Gotcha 3 — stop-before, and why a step is still not a no-op

The hit compares `dbg_next_pc`, the **landing** address. So the core is held at
that edge with `PC == bp_addr` and **the instruction there has not run** — no
`io_we`, no `dmem_we`, no `a`/`x`/`y` effect. That is the stop-before a
debugger expects: inspect it, then step that very instruction.

But stop-before is not a no-op step. Stepping 1 → 2 with the breakpoint armed
at 2 **does** execute the LDI at 1, because a step retires the instruction it
stepped *from*, as a step always does — and leaves the instruction *at* 2
untouched. It protects the one you are about to inspect; that is the entire
distinction.

Under a hold the PC is **preserved**, not re-zeroed, across arbitrarily many
cycles. Only the boot stop (`run=0`, no hold) re-zeroes it, exactly as R2's
read arbitration requires.

## Gotcha 4 — `insn` follows the fetch mode

`insn` is **not** unconditionally `imem[pc]`. `pe_cpu` fetches at `next_pc`
while executing, at `pc` while held, and at 0 at the boot stop. So a
free-running readback reports the **landing** word. A test harness that
synthesises a mid-execution snapshot — pinning `pc` every cycle to hold a
genuinely running core — **collapses the fetch pipeline**, so the `insn` it
reports is the collapsed one. At a freeze the chip reports the *latched*
pipeline word, whatever the fetch presented last, and no RTL change is
involved: the disagreement is in how the snapshot was synthesised. Treat an
`insn` mismatch in a synthesised-running vector as a harness artefact until
measured otherwise.

## Gotcha 5 — DEBUG_BP_CLR reports the PC *at the request*

`BP_CLR`'s `pc` field is the PC when the request arrived. With `run=0` the core
re-zeroes at **that same edge**, so the *following* STATUS reports `pc=0`. This
is documented release semantics, not a stale value — and it was a genuine
disagreement: the contract's own vector table originally expected `pc=0` in the
response, and the manager's ruling was to correct the **table**, never truthful
RTL to match a doc.

Related: `bp_flags` bit0 is what distinguishes "disarmed" from "armed at
address 0". A breakpoint at 0 is legal, and `bp_addr` alone cannot tell you.

## Gotcha 6 — an undriven debug input must read as inactive

The `=== 1'b1` comparisons in the execute gate are load-bearing, not style.
With a debug input floating at x or z, the plain `!dbg_hold` form makes the
gate x and **the core freezes at reset**. The `===` form makes an undriven
debug input read as *inactive*. The convention is enforced **where the input is
consumed** rather than at every call site, because that is the only place a new
call site cannot forget it; in synthesis the forms are identical, since x and z
do not exist in hardware.

This is not theoretical here. Leaving the debug inputs unconnected in
testbenches that instantiate `pe_cpu`/`pe_soc` directly took **six acts to their
reset** after the `5b4731f` merge, and only the full integration suite caught
it — no unit TB finds a port addition on its own. All 13 TBs now tie the debug
inputs low, with a comment.

## Why a host's own model cannot show most of this

A host model reaches a held state by *declaring* `debug_hold: true`. The chip
reaches it by traffic, and the traffic has to be legal. So gotchas 1 and 2 are
structurally invisible to a model-driven debugger: the model is right about
the state and wrong about the path. When the two disagree, the chip is the
authority — and `tb_pe_ctrl_r2` builds its state-2 and state-3 pre-states by
**driving the debug opcodes on a real `pe_ctrl`**, asserting the registers
rather than assigning them, precisely so the vectors test a reachable state.

## How this is proved

Golden vectors first (RED against unmodified RTL — every debug op answered
UNSUPPORTED, 42 failures — then GREEN), then directed cases, then mutation:
`regress/mutate_ctrl_r3_tb.sh` runs 7 mutants and all 7 are detected, wired
into `run_all.sh`. Formally, `formal/pe_cpu/formal_pe_cpu.v` proves S1–S4
(one instruction per step, the hold preserves the PC) **unbounded** by temporal
induction; `formal/pe_ctrl` adds H1 (a hit implies the hold) and H2 (a hit
implies state 3).

One claim was found **vacuous and removed**: "an armed address is inside
instruction memory" is a tautology at the shipping parameterisation. The real
protection is refusing the *full-width* request so a 1024..65535 word cannot
truncate into a small address, and that transition is owned by the TB and its
mutation, where it is differential. A vacuous claim in the proof would have
been trusted, and that is the one failure mode the campaign's rules exist to
prevent. The bring-up trap has both a proof and a mutant (`pe_ctrl_bp_hit_no_
hold`) that dies without it.

Simulation and mapped pre-layout screening only: **no board has been run, and
hardware is not claimed.**
