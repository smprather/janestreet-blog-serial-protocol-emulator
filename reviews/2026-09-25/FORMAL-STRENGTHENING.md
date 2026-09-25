# Formal strengthening — what became UNBOUNDED, and what the toolchain cannot do

Date: 2026-09-25. Scope: the dispatch's two targets — take the gate-depth-only
claims UNBOUNDED by better instrumentation, mutant-check every newly-inductive
claim, and document exactly what the toolchain lacks for anything that will not
close. **No RTL behaviour changed**: this is proof quality only, and the only
edits to `rtl/` are the mutant text, which the harness restores and verifies.

**Outcome: one claim family closed (pe_soc C2, the set-side guard, now unbounded
and mutant-checked), the four pe_ctrl claims documented as a genuine toolchain
gap with the reason, and the full formal gate + 12-mutant harness green.**

---

## 1. Closed: pe_soc C2 (the F2 set-side guard) is now UNBOUNDED

C2 enforces the manager's F2 fix — a TXCTRL *set* of the codec owner is refused
while the SERDES is transmitting. It was previously proved only at the gate depth
(depth-16 BMC) and labelled "not closed by induction".

**Why it closes now (and why the old label was wrong about this claim).** The
old diagnosis blamed two "separate sampling chains" in yosys's `clk2fflogic`
model. Reading `pe_soc.v` shows the opposite: `fv_set_took` and
`fv_ser_busy_seen` are clocked from the **same edge of the same always block**,
both sampling the same `ser_tx_busy` wire. The claim is a one-step property of the
guard's own update equations — there is no history in it and no snapshot register
to drift — so it closes by k-induction at k=1 from *any* pre-state. Measured:
`pe_soc_owner_guard` PROVED (induct, k=3), alongside C1.

**Mutant-checked (rule 1: a claim proved by induction must have its mutant run by
induction).** New formal mutant `pe_soc_owner_set_guard_removed`
(`formal/mutants.sh` case 14) replaces `if (!ser_tx_busy) tx_path <= 1'b1;` with
the unconditional set — the pre-fix F2 bug. Measured: the mutant makes the target
NOT close (induction step fails → NOTPROVED → `CAUGHT-no-closure`). The claim
is therefore not vacuous: it kills the exact bug it is about. The full harness
now reports **12 caught, 0 survived, 0 inconclusive** (11 prior + this one).

The pre-fix status comment in `formal_pe_soc.v` and the C1-mutant note in
`mutants.sh` are updated: they used to say C2 "never closes on the clean design,"
which is no longer true (and would, if left, make the C1 mutant's differential
unjustified).

## 2. Not closed: the four pe_ctrl claims — the exact toolchain gap

The four claims held out of the inductive `pe_ctrl_r2_induct` target (guarded by
`ifndef FV_INDUCT` in `formal/pe_ctrl/formal_pe_ctrl.v`) are:

1. `r_slot != 0` while a walk is in progress (no response-buffer overrun);
2. the walk sum `r_addr + r_left` is preserved while walking;
3. the slot sum `r_slot + words_left` never grows while walking;
4. the response index advance is bounded by the previous length + 4.

All four are proved by the depth-16 BMC target (`pe_ctrl_r2`, PROVED) and all four
fail by k-induction. Measured individually (each forced on in the inductive set
alone, `FORMAL_INDUCT_MAX` 4–6): **every one reaches "Reached maximum number of
time steps → proof failed" (NOTPROVED).** I also tested the strongest
reformulation I could motivate — excluding a re-accept from claim 2's guard, since
a fresh accept legitimately reloads the sum — and it did **not** close (NOTPROVED).

**The precise reason, stated so a reviewer can act on it.** Each of these claims
relates a **live register** to a **previous-cycle snapshot** (`p_walk_end`,
`p_slot_sum`, `p_resp_len`) or to a value the register history constrains
(`r_slot` is loaded to 1 only at the accept; it is never 0 in a real walk). The
induction step in yosys' `sat -tempinduct` starts from an **arbitrary** state that
satisfies only the *other* claims — not a reachable one. In that arbitrary state
the snapshot register and the live register are independently free, so the solver
can set, e.g., a walking `r_slot = 0` or `p_walk_end` inconsistent with the live
sum: values no reachable state can produce, but that nothing in the induction
hypothesis forbids. The claim is true of the *reachable* design and the step
cannot see reachability.

**What the toolchain lacks, precisely:** yosys' built-in `sat -tempinduct` is a
self-contained k-induction with **no reachability / induction-from-reachable
mode, no relational (k=1) solver, and no SMT backend** (this host has no SymbiYosys
and no SMT solver — the campaign header in `run_formal.sh` records that). Closing
these four needs one of:

* an **inductive auxiliary invariant** that encodes the accept history (r_slot
  starts at 1 and only increments; the sum starts at pay0+pay1 and only
  re-loads at a fresh accept) — but that invariant is itself not obviously
  inductive, and encoding it correctly is the open design question; or
* **reachability-constrained induction** (induct only from states the design can
  actually enter), which `sat -tempinduct` cannot express; or
* an **SMT-based temporal proof** (SymbiYosys/boolector/z3 or yosys-smtbmc),
  which is not installed here.

This is the deliverable the dispatch asked for: **for a tapeout reviewer, the
four pe_ctrl slot/sum/index claims are proven to depth 16 and NOT proven
unbounded; the blocker is the toolchain's lack of reachability-constrained or
relational induction, not a design defect and not a vacuous claim.** C2, by
contrast, is now unbounded with a differential mutant.

## 3. Evidence

* `formal/results/summary.txt` — `pe_soc_owner_guard PROVED induct`,
  `pe_ctrl_r2_induct PROVED induct` (the surviving subset), `pe_ctrl_r2 PROVED
  bmc` (all claims at depth 16).
* `formal/results/mutants.txt` — 12 rows, all `CAUGHT`, including the new
  `pe_soc_owner_set_guard_removed`.
* Full formal gate: 8 proved, 0 failed, 1 reachable-at-depth, 1 vacuous-at-depth,
  0 findings. Full mutant harness: 12 caught, 0 survived, 0 inconclusive.
