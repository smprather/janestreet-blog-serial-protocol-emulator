# R2 held-core vectors: the chip reaches states 2 and 3 — 22/22

Date: 2026-09-25. Author: protocol-worker. Task: the chip-side half of the
gui-worker's held-core golden package
(`reviews/2026-09-25/R2-HELD-STATUS-BYTES.md`, their repo) — extend
`tb_pe_ctrl_r2` so the four new steps reporting **debug states 2 and 3** are run
against real RTL, and report any divergence rather than re-deriving bytes.

**Result: 22/22 golden steps pass byte-exactly (CRC included), the four new
ones included, with the held pre-state established by DRIVING THE DEBUG OPCODES
on the testbench's core-side ports — nothing forced hierarchically.** Two
findings came out of it, both of which the host's model abstraction hides.

---

## 1. The ask, and what the chip side actually owed

The four steps are `v09-status_while_step_paused` (2 steps) and
`v10-status_while_bp_hit` (2 steps), all `chip_confirmed: false`, all reporting a
state the previous 18 steps never touched. The chip owed: copy the 8 new `.hex`
files, re-derive the step table and the include, reach the pre-state, re-run,
and report divergence.

## 2. The pre-state: DRIVEN, not forced

The ask allowed either route — drive the debug opcodes on a real core, **or**
force `bp_en`/`bp_hit`/`dbg_hold_r` hierarchically and record it as forced. The
**drive** route turned out to be available, so that is what this uses.

`bp_en`, `bp_hit` and `dbg_hold_r` are internal to `pe_ctrl`, but they are not
unreachable: `pe_ctrl.v:690` latches the hit from the core's own
`dbg_next_pc` port,

```verilog
if (bp_en && !dbg_hold_r && (run || dbg_step_r) && (dbg_next_pc == bp_addr))
     begin bp_hit <= 1'b1; dbg_hold_r <= 1'b1; end
```

and `OP_DBGBPSET` / `OP_DBGSTEP` / `OP_DBGBPCLR` are ordinary framed opcodes the
R2 testbench can send. So the pre-state is built with real traffic and real RTL:

| vector | how the state is built | pre-state asserted on `pe_ctrl`'s own registers |
| --- | --- | --- |
| v09, state 2 | `DEBUG_BP_CLR`, `DEBUG_BP_SET(2)`, then one `DEBUG_STEP` with the strap low and `dbg_next_pc = 1` (the core at 0 landing on 1, so `1 != bp_addr`) | `dbg_state == 2`, `bp_hit == 0`, `bp_en == 1`, `dbg_hold_r == 1` |
| v10, state 3 | `DEBUG_BP_CLR`, `DEBUG_BP_SET(2)`, strap **high**, `dbg_next_pc = 2` → the hit latches on the clock edge | `dbg_state == 3`, `bp_hit == 1`, `bp_en == 1`, `dbg_hold_r == 1` |

### What is REAL and what is MODELLED, stated plainly

* **REAL, under test:** the `DEBUG_BP_SET`/`DEBUG_STEP`/`DEBUG_BP_CLR` decode,
  the arm, the hit detection, the hold, the state encoding, the `STATUS` and
  `DUMP_CORE` response builders including the `if (run)` gate, and the
  `run`-is-the-strap asymmetry. Every bit these four steps read is produced by
  the RTL.
* **MODELLED:** the CPU. `tb_pe_ctrl_r2` has no `pe_cpu` — the read port is
  served from the package's memory image, which is what the 18 shipped steps
  compare against. So the core's `dbg_next_pc` port is driven by the testbench.
* **Why that is not the MEDIUM-2 defect** (the review item about a testbench
  forcing a state the RTL cannot reach): the values on that port are the ones
  the package's **own** `imem.hex` produces — `0x0041 LDI A,0x41` at 0,
  `0x1001 OUT` at 1, `0x4002 JMP 2` at 2 — after executing the address the
  vector says it has, so the pc/a the steps report are the pc/a that program
  really has. And `tb_pe_ctrl_r3_conf` independently demonstrates, on a **real
  `pe_cpu`**, that these same two states are reachable by these same opcodes.
  No register is written from the testbench. The pre-state assertions *read*
  `dut.dbg_state` / `bp_hit` / `bp_en` / `dbg_hold_r`; they never assign them.
  (`fv_dbg_state` & friends would read more cleanly but exist only under
  `ifdef FORMAL`, and a conformance run must exercise the shipping
  configuration.)

## 3. FINDING 1 (chip-side, medium): `BP_SET` does not clear the hold, so a
## fresh hit cannot latch on a DUT that is already held

`DEBUG_BP_CLR` clears `bp_en`, `bp_hit` **and** `dbg_hold_r` (`pe_ctrl.v:1102-1104`).
`DEBUG_BP_SET` clears `bp_en` and `bp_hit` but **not** `dbg_hold_r`
(`pe_ctrl.v:1086-1087`). Since the hit condition requires `!dbg_hold_r`, arming
a core that is *already held* cannot produce a hit — the core sits at state 2
with `bp_hit` clear, forever, and nothing reports an error.

The first version of the v10 prep did exactly that (the v09 prep had just left
the core held), and the failure arrived as a **word mismatch inside a golden
response** — `word 5 = 0002, want 0003` — rather than as "the pre-state was not
reached". That is a bad failure shape: it points at the STATUS builder when the
cause was two opcodes earlier. Both preps now open with `DEBUG_BP_CLR` and
assert the release, and the pre-state assertions name the state rather than
letting it surface as a byte.

**This is a fact about the debug interface that the host's model cannot show**,
because `model_image[].debug` simply declares `debug_hold: true`. A host-driven
model reaches the state by fiat; the chip reaches it by traffic, and the traffic
needs a release first. Worth a line in the frozen contract, because a real host
that re-arms without clearing will see the same silent non-hit.

## 4. FINDING 2 (chip-side, low): the pre-state is established once per VECTOR,
## not once per step

`DEBUG_BP_SET` clears the latched `bp_hit`, so re-running the prep before the
vector's second step would turn state 3 back into state 2. The include therefore
emits the prep before each vector's **first** step only; a golden read does not
disturb the debug state, so one call per vector is sufficient. (This is why the
`r2_prep_*` calls are generated per vector rather than per step, and it is the
reason the generated include is not a hand-written list.)

## 5. The steps are load-bearing — RED proofs, not assertions of faith

Two mutants of `pe_ctrl.v`, each run through the full 22-step conformance and
each applied with a `cmp` guard so "the mutant did not apply" could never read
as a pass:

| mutant | result | what it shows |
| --- | --- | --- |
| `dbg_state = dbg_hold_r ? (bp_hit ? 2 : 3) ...` (2 and 3 swapped) | **18/22** — exactly the four held steps fail | the new steps are what catch a swapped state encoding, and the shipped 18 were blind to it — which is the entire reason the vectors exist |
| `OP_DUMPCOR` gated on `if (dbg_hold_r)` instead of `if (run)` | **6/22** — `dump_core_refused_the_strap_is_high` fails among them | the "a refusal is not a hold" asymmetry is genuinely pinned: with the strap high the core is stopped *and* `DUMP_CORE` must still refuse |

Plus the pre-state assertions, which fired on their own during development: the
run that produced FINDING 1 printed `prep v10 bp hit: dbg_state = 2, want 3`
rather than letting the divergence hide inside the response bytes.

The RTL was restored and byte-compared after both runs (`pe_ctrl.v` identical to
its pre-mutation copy); the mutants lived only in `/tmp`.

## 6. What was NOT touched

* **No host file was modified.** `tools/host_gui/r2_vectors.py` (where
  `CHIP_EVIDENCE` and the four `chip_confirmed` flags live),
  `reviews/2026-09-25/r2-hex/*` and the gui tests are the gui-worker's. The
  bytes were copied *out* of their package and every line of the step table was
  checked against their new `manifest.json` before being appended — the four
  lines this repo now carries are byte-identical to the ones their doc quotes,
  and the shipped 18 are untouched (`r2_steps.txt`: +4 lines, pure addition).
* **No RTL change.** `rtl/pe_ctrl.v` is unmodified; `git status rtl/` is clean.
* `dbg_next_pc` was **unconnected** in `tb_pe_ctrl_r2` before this — a pre-existing
  loose end that went unnoticed because no R2 step read a state derived from it.
  It is now driven. That is a testbench fix, not a behaviour change.

## 7. The evidence the host side needs to flip the four flags

`tb_pe_ctrl_r2` reports **`R2 conformance: 22/22 golden steps pass on the chip`**
and `PASS: tb_pe_ctrl_r2` on the current tree, including
`status_reports_the_hold`, `dump_core_answers_the_same_header`,
`status_reports_the_hit` and `dump_core_refused_the_strap_is_high`. The three
pre-existing companion testbenches (`tb_pe_ctrl`, `tb_pe_ctrl_r3`,
`tb_pe_ctrl_r3_conf`) were re-run unchanged and pass.

Citation text for `r2_vectors.CHIP_EVIDENCE`, in the shape the R3 block uses:

> `tb_pe_ctrl_r2` (reviews/2026-09-25/R2-HELD-STATUS-BYTES.md, chip side,
> 2026-09-25): 22/22 golden steps byte-exact including the four held-core
> steps; the state-2 and state-3 pre-states are reached by DEBUG_BP_SET /
> DEBUG_STEP / DEBUG_BP_CLR on a real pe_ctrl, not forced; mutants swapping the
> 2/3 encoding and gating DUMP_CORE on the hold are each caught by these steps.
> NOT HARDWARE-CONFIRMED: no board has been run.

The `chip_confirmed` flags are the host's to flip (the standing boundary: I do
not modify host files), and `test_r2_vectors` will object if the notice is left
behind — which is the R3 review's F1 applied to R2.
