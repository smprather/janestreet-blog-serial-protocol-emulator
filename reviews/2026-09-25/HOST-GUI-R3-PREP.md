# R3 host-side prep — the host half of the debug-control contract

**Date:** 2026-09-25 · **Worker:** `gui-worker` · **Branch:** `host-controller-gui`

## What this is

The host side of R3, the debug-control phase: opcodes `0x21 DEBUG_STEP`,
`0x22 DEBUG_BP_SET`, `0x23 DEBUG_BP_CLR`, `0x24 DEBUG_STATUS` in the framed
host bus, ready-immediate, same CRC/sequence/target/wait-word rules. R2 made
*observe* real; R3 makes *debug* real.

R3 is **implemented chip-side** (chip repo, 2026-09-25): `pe_cpu` gained
`dbg_hold`/`dbg_step`/`dbg_next_pc`, `pe_ctrl` owns the decode, the breakpoint
register and the stop-before hit, and the header block is in `rtl/pe_ctrl.v`.
The chip ran its own `tb_pe_ctrl_r3` (RED-first, 42 failures → GREEN), a
7-mutant gate (all caught) and formal proofs for S1–S4. **This document covers
the host half only, and the host's own evidence is separate from all of that.**

## THE ONE THING TO READ FIRST: chip_confirmed is false everywhere

Every R3 step in the golden package is `chip_confirmed: false`, and that is
the *correct* state today — not an oversight. The chip's evidence is the chip's
`tb_pe_ctrl_r3` plus its mutants and formal claims; the host's golden vectors
are the host's *expectations* for the same contract. They become
chip-confirmed only when the chip's TB runs **these** vectors byte-exactly
(CRC included) with the shipped model image preloaded, and the citations are
added to `r3_vectors.CHIP_EVIDENCE`. A test pins that a confirmed step must
carry a citation, so confirmation can never be asserted by hand.

## The contract the host implements

Transcribed from `rtl/pe_ctrl.v`'s response builders, not read off the prose:

| opcode | request | response |
|---|---|---|
| `0x21 DEBUG_STEP` | len 0 | `(OK, state, pc_next, bp_addr, bp_flags)` |
| `0x22 DEBUG_BP_SET` | len 1 (address) | `(OK, state, pc, bp_addr, bp_flags)` |
| `0x23 DEBUG_BP_CLR` | len 0 | `(OK, state, pc, bp_addr_before, bp_flags)` |
| `0x24 DEBUG_STATUS` | len 0 | `(OK, state, pc, bp_addr, bp_flags, run, a, x, y, insn)` |

- **state** (2 bits, upper bits zero):
  `0 STOPPED` (boot stop, PC held at 0) · `1 RUNNING` (strap high, no hold) ·
  `2 DEBUG_HOLD` (PC preserved) · `3 BP_HIT` (PC preserved, hit latched).
  R2's `STATUS` state word carries the **same** encoding, so 0/1 keep their
  R1/R2 meaning.
- **bp_flags**: bit0 armed, bit1 hit. `bp_addr` is the armed address or 0 when
  disarmed — a breakpoint at address 0 is legal and is told apart from
  "disarmed" by **bit0, never by the address value**.
- **Zero wait words** on all four ops.
- **Stop-before**: the hit compares the core's *landing* address, so the
  instruction at the breakpoint has not executed. That is what lets a debugger
  inspect the landing instruction and then step that very instruction.
- **`DEBUG_BP_CLR` is the only release** of the debug hold, and it also
  disarms: with `run=1` the core resumes, with `run=0` it falls to the boot
  stop and the PC re-zeroes. Continuing *with* the breakpoint armed therefore
  costs **step → clear → re-arm**, which `session.resume_with_breakpoint()`
  wraps so the GUI cannot strand the core on a hold.
- **Rejected ops have no side effect**: a wrong payload length is a 1-word
  `BAD_FRAME` (and latches the pre-existing `FAULT_PROTOCOL`); a `BP_SET` past
  `IMEM_WORDS` is `RANGE` and latches **no** fault — R3 adds no fault class.

## What was built

- `tools/host_gui/vectors.py` — the golden-vector **framework** extracted from
  R2 so both phases share one generator, one manifest schema and one hex
  export. R2 is chip-confirmed and its TB consumes its hex export, so the
  extraction had to leave R2 **byte-identical**; `r2_vectors --check` proves it
  on every gate run, and R2's `Spec` passes `schema=None` so the new
  schema/phase keys are emitted for R3 only.
- `tools/host_gui/r3_reads.py` — 20 obligations (S1–S6 and the wire shapes),
  each a probe with `chip_confirmed=False`.
- `tools/host_gui/r3_vectors.py` — the package: **14 vectors / 26 steps** in
  the R2 package shape, plus `reviews/2026-09-25/r3-hex/` for
  `$readmemh`, and the schema/phase stamp R2 predates.
- `fake_pe.py` — the debug state machine and an ISA execution model
  (`LDI/MOV/ALU/INCX/DECX/SHR/LDS/STS/LDM/STM/JMP/JZ/JNZ/NOP`; `IN`/`OUT` are
  no-ops because the host model has no port space). R3's contract is stated
  over real instructions — "a step executes `imem[0]`", "`a=0xAA`" — so the
  model has to execute them for the vectors to mean anything.
- `session.py` / `server.py` / `web/` — `debug_status`, `debug_step`,
  `bp_set`, `bp_clr`, `resume_with_breakpoint`, five routes, and a Debug panel
  that renders the chip's own state word and `bp_flags`.
- `tools/host_bridge/main.py` — the Pico implements the four debug ops against
  the real frames, so the debug path is not a host-only fiction; on a chip
  without R3 the PE answers `UNSUPPORTED` and the host says so.
- Acceptance: six R3 cases in `acceptance.py --fake`, each tagged so the
  evidence status is explicit on the line.

## TWO PLACES THE VECTOR SPEC AND THE RTL DISAGREE

Reported rather than smoothed over; the vectors follow the **RTL**, because the
chip is the thing that has to pass. Recorded in `r3_reads.DISCREPANCIES` and
published in the package under `spec_vs_rtl_discrepancies`.

1. **Vector 11** (`debug_bp_clr_while_stopped_is_boot_stop`) — the §3 table
   expects `pc=0`, but the RTL answers with the PC **at the request** and
   re-zeroes the core at the same edge, so a following read sees 0. The RTL's
   own comment *and* the contract's "Known limits" section both state the RTL
   behaviour; only the table row disagrees.
2. **Vector 13** (`debug_status_common_prefix`) — the table expects
   `insn=imem[4]` while free-running, but `pe_cpu` fetches at `next_pc` while
   executing, so a free-running readback reports the word at the **landing**
   address. A TB that wants `insn=imem[pc]` must hold the core (state 2) or
   preload the pipeline.

## Two obligations have no framed step

Listed in the package as `model_only_obligations` so a testbench reader learns
what is *not* covered: "the instruction at the breakpoint did not run" is
proven across a step (and by the chip's formal claim), and reaching a live-core
hit takes **clocking**, which is not a framed op — vector 8 therefore ships the
post-hit held state as its model image and reads it back with one
`DEBUG_STATUS`.

## Corrected against the chip's conformance run (2026-09-25)

`tb_pe_ctrl_r3_conf` is GREEN 26/26 with three pinned divergences in which the
CHIP was right. Two were host-side vector defects, fixed here:

- **`read_cpu_shows_a_55`** — the host's READ_CPU builder put the debug *state*
  in the slot the contract gives to *run* (`resp_buf[6] <= {15'b0, run}`), and
  reported the last-executed word as `insn` instead of the fetched one. It now
  reports `run` and, while a hold is asserted, `imem[pc]` — the contract's fetch
  mode. Scoped to the hold on purpose: R2's READ_CPU vectors preload `insn` and
  the chip passes them 18/18, so the register must survive there, and R2's
  byte-identity is asserted by a test after the change.
- **`status_reports_the_hit`** — the host model *skipped the execute* whenever
  the landing address matched the breakpoint, which withheld the wrong
  instruction. A step is exactly one instruction and it RUNS; the hold is what
  keeps the instruction *at* the breakpoint from running. So a step from 1 to 2
  does retire the `LDI A,0xAA` at address 1.

One is a TB model boundary and is deliberately **left alone**:
`status_full_readback` expects the ruled landing word 0xF000 where the chip's
freeze-snapshot model reports 0x0000, because a model that pins `pc` every cycle
collapses the fetch pipeline onto the fill word. The chip's own doc calls this
"not a disagreement about the contract; not proven here, and not claimed", so
bending a contract value to match a testbench artefact would be the wrong fix.
It is recorded in the package as `model_boundaries`, `chip_confirmed` stays
false, and the note records that holding the core would make the word
deterministic and therefore provable.

Exactly 2 of 26 steps moved; the other 24 are byte-identical, and R2's
chip-confirmed package is untouched.

## Defects found and fixed while building this

Not cosmetics; each was found by a gate, not by reading:

- **`debug_step_once` never advanced the PC on a stop-before hit.** It skipped
  the execute and left `self.pc` untouched, so the core stayed behind the
  landing address. The RTL's `dbg_pc` must read `bp_addr`.
- **`run_all_probes` shared one model across all probes.** Inherited from R2,
  but R3 state persists (breakpoint, hold, run strap), so the suite was
  **order-dependent** — two probes passed alone and failed in sequence. Each
  probe now gets its own model, and a test asserts the suite is
  order-independent.
- **`_debug_bp_set` answered the pre-update prefix**, reporting `bp_addr=0` and
  `flags=0x00` for an arm that succeeded. The RTL builds the prefix in the
  same cycle it latches the new address.
- **The request-length check was declared and never wired** into `_dispatch`,
  so a wrong-length debug frame produced a full response instead of a 1-word
  `BAD_FRAME`.
- **A hostile bridge field escaped as a 500.** `int(result.get(...))` in
  `session.py` and `int(args.get(...))` in `FakeBridge` raised
  `ValueError`/`TypeError` past `guarded()`, which catches only
  `ApiError`/`SessionError`. Both now coerce strictly into a typed
  `SessionError` (→409) / `FakeBridgeError`.
- **Two API routes would have raised `TypeError` at runtime** — an extra `()`
  after `guarded(fn)(arg)` calls the returned `dict`.
- **`Link` typed every field as `object`**, so `first.transport.request(...)`,
  `first.pe.faults` and `first.adapter.set_irq(...)` were entirely unchecked.
  Now structural Protocols.

## Evidence (this is the host's evidence, not the chip's)

- `tools/host_gui/tests/test_r3.py` — 34 tests: the state/flag encodings
  against the RTL expression, each handler against its response builder,
  stop-before, the ISA execution, the obligations and their order-independence,
  the package shape, the byte-identity of R2, and the chip_confirmed
  discipline.
- **20/20 obligations pass**, order-independent.
- **27 assertions transcribed from the contract's own §3 table pass** against
  the generated package.
- `acceptance.py --fake` → **28 PASS / 0 FAIL / 1 SKIP**, including the six R3
  cases.
- Per-vector request/response bytes for the chip side, as a durable artifact:
  **`reviews/2026-09-25/R3-VECTOR-BYTES.md`** (regenerate the underlying
  package and hex export with `python3 -m tools.host_gui.r3_vectors --write`
  and `--hex`).

## Still open, and not host work

- The chip's `tb_pe_ctrl_r3` must run **these** vectors byte-exactly; until
  then `chip_confirmed` stays false and the two spec-vs-RTL rows above want a
  ruling.
- The **real Pico/USB acceptance run** is hardware-gated and unexecuted. No R3
  line claims otherwise — every one of them is tagged host-side.
