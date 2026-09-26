---
title: Protocol formal gaps — what is still depth-16 only, and why
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [verification, architecture]
sources: [reviews/2026-09-25/FORMAL-STRENGTHENING.md, reviews/2026-09-25/FORMAL-VERIFICATION.md, reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md, formal/pe_ctrl/formal_pe_ctrl.v]
confidence: high
---

# The protocol formal gaps

The companion to [[concepts/formal-verification]], which carries the campaign's
headline state. This page carries the things a tapeout reviewer most needs and
is most likely to misread: the claims that are **not** unbounded, the
claim-reformulation thread and its mutant-kill bar, the IFG story, and the one
claim that was deleted for being vacuous.

The subjects are the read path and the debug controls of
[[concepts/host-chip-protocol]] and [[concepts/debug-control]].

## The four `pe_ctrl` claims are depth-16 proven, not unbounded

These are held out of the inductive `pe_ctrl_r2_induct` target by `ifndef
FV_INDUCT` in `formal/pe_ctrl/formal_pe_ctrl.v`, and they are **labelled** as
gate-depth-only in the wrapper rather than quietly counted as proofs:

1. `r_slot != 0` while a walk is in progress (no response-buffer overrun)
2. the walk sum `r_addr + r_left` is preserved while walking
3. the slot sum `r_slot + words_left` never grows while walking
4. the response index advance is bounded by the previous length + 4

All four are proved by the depth-16 BMC target and all four fail by
k-induction. Measured individually with each forced on alone, every one reaches
"Reached maximum number of time steps → proof failed" (`NOTPROVED`) — which is
an **induction failure, not a counterexample**, and the two are deliberately
distinguished in the harness so a mutant case wanting "not PROVED" is not
served a claim-shaped message.

The C1 antecedent was **re-verified against the file** rather than inherited:
`r_slot` has exactly four writers in `pe_ctrl.v` — loaded to `16'd1` at both
accepts (`:1009` for READ_IMEM, `:1032` for READ_DMEM) and incremented inside
`R_WAIT` (`:1236`, `:1241`) — and **nothing assigns it 0**. That is the
independent k=1 fact the reformulated claim rests on. Worth noting because the
review document's own line numbers for this (`:994`/`:1017`/`:1201`/`:1205`) are
stale by roughly 15 lines; the structure it describes is correct, the pointers
have drifted, and a reader who trusts them lands on comments.

**The precise reason**, stated so a reviewer can act: each claim relates a
**live register** to a **lagged snapshot** (`p_walk_end`, `p_slot_sum`,
`p_resp_len`), or to a value only the register *history* constrains (`r_slot` is
loaded to 1 at the accept and is never 0 in a real walk). k-induction starts
from an **arbitrary** state satisfying only the other claims, not a reachable
one — so the snapshot and the live register are independently free, and the
solver can set, say, a walking `r_slot = 0`. Those are values no reachable state
can produce and nothing in the induction hypothesis forbids. **The claim is true
of the reachable design; the step cannot see reachability.** That is the whole
gap, and it is a claim-structure problem, not a design defect and not a vacuous
claim.

Each claim does have an independent non-circular justification in the RTL, and
each was checked for circularity before use — the `walk_entry` helper, for
instance, constrains *history* rather than restating the present-state guard the
claim uses. Every helper was then honestly attempted and **failed**, so none was
allowed into the shipped harness: a helper that only holds because of the claim
it serves would have been rejected and recorded as circular.

## Reformulation under the mutant-kill bar

The ruling that made this decidable: the snapshots are real flops with their own
update rules, so binding a claim to its load source is an **RTL fact, not
circular** — and a reformulated claim is accepted only if (1) its antecedent is
an independently k=1-provable RTL fact, (2) it still kills every mutant the old
claim killed, and (3) it kills **new mutants of its own scope**. Weakening a
claim to reach "unbounded" is the one outcome worse than the gap. Engine: the
z3 SMT induction path, whose two-engine validation stands.

**C1, response-buffer slot overrun — ACCEPTED, now unbounded.**

| | |
|---|---|
| old | `if (walking) assert (fv_r_slot != 0)` — compared against an arbitrary pre-state |
| new | `if (fv_rstate == R_START && !fv_r_imm) assert (fv_r_slot != 0)` |
| k=1 fact | an ACCEPTED start loads `r_slot <= 1` (`pe_ctrl.v:1009`, `:1032`), and `R_REQ`/`R_WAIT` are entered only from `R_START` (`pe_ctrl.v:1205`, `:1219`, `:1222`) |

All three bars pass: the antecedent is a register update rule, not a restatement
of the claim; the old-scope mutants `pe_ctrl_len_overflow` and `pe_ctrl_bit14`
still fail to prove; and two **new self-scope** mutants — `pe_ctrl_slot_load_zero`
(accept loads `r_slot<=0`) and `pe_ctrl_r_req_bypass` (`R_IDLE→R_REQ` skips the
accepted `R_START`), the two ways `r_slot` can go wrong in a walk — also fail,
and are now permanent cases. It passes under **both** engines (yosys k=6, z3
k=1).

**C2, C3, C4 — REJECTED, kept depth-16 proven.**

| claim | reformulation tried | z3 | why rejected |
|---|---|---|---|
| C2 walk sum preserved | bound the live sum at accept; drop the free `p_walk_end` compare | FAILED | the bound is already an always-on claim, so this only *removed* content |
| C3 slot sum never grows | live `r_slot + words_left <= 16`, drop the snapshot | FAILED | did not close, and the snapshot form is the **stronger** statement |
| C4 index bounded | compare `fv_resp_idx` to the *current* `fv_resp_len` | FAILED | did not close; the free `fv_resp_idx` observation port is itself an independent state bit |

C4 is the sharpest negative: even with the lagged snapshot removed entirely, the
free observation-port register is still an independent state bit, so the
antecedent can be met with an unreachable value. That is why both engines fail
it the same way.

**Nothing was weakened to reach "unbounded".** One C2 attempt briefly closed —
and was a `|| 1'b1` tautology, caught and discarded before it reached the
harness, by the same reasoning that removed H3 below. The mutant count went
11 → 12 (`pe_soc_owner_set_guard_removed`) → **14** (C1's two new self-scope
mutants), which is why 14 and not 12 is the number on the maps.

## The IFG floor: why induction beat deeper BMC

The counter-style IFG claim was **vacuous at every affordable depth**. A frame
needs ~576 cells and the gap closes ~672, so the shortened-gap mutant
**survives at depth 240** (11 min, 1.7 M variables) and the 700-step run died at
the memory cap. The manager's ruling was the pivot: **a cap-kill is a strategy
signal, so shape the proof to the design instead of deepening it.** Those two
deaths are what turned "prove it deeper" into "prove it inductively".

The floor was restated over the structure that enforces it, tapping `fv_state`,
`fv_fcs_left`, `fv_ifg_cnt`, `fv_abort_pend`: T1 the FCS's last cell opens the
gap with the counter reset; T1b the gap is **mandatory** after an un-aborted
frame end; T2 the engine's counter and the shadow agree while the gap is open;
T3 the gap closes only at the terminal count **or** by the two documented
abandonments; T4 no frame is applied while the gap is open. It closes
**unbounded**, and both gap mutants are caught.

Two modelling facts each cost a real counterexample to find. A `tx_done`-keyed
floor claim is **not inductive** — `tx_done` is a free register in an arbitrary
state — which is why T1/T1b key on the FSM state and the FCS counter instead.
And an **ABORT legitimately cuts the gap short** (the engine's own header says
"does NOT run an IFG"), so a floor that does not name its abandonment exits is
false on the clean RTL. A proof that is false on the clean design is not a
strictly weaker proof; it is a wrong one.

## H3: a claim deleted for being vacuous

"an armed breakpoint address is inside instruction memory" (`fv_bp_addr <
WORDS`) is a **tautology** at the shipping parameterisation — a 10-bit register
against 1,024 words. It was not argued about: the mutant that removes the RANGE
guard **proved** it. A vacuous claim is worse than a missing one, because it is
trusted, and that is the single failure mode the campaign's rules exist to
prevent. The real protection is refusing the **full-width** request, so a
1024..65535 word cannot truncate into a small address — and that transition
claim is owned by a testbench case and its mutation, where it **is**
differential. Deleting H3 made the suite honest and moved the protection to
where it can actually fail.

## What a tapeout reviewer should conclude

The evidence-backed option set for the three surviving claims is closed, and
none of it is mechanical:

1. **Accept them as depth-16 proven** — the shipped state, safe, and backed by
   the golden vectors and testbenches for the boundary behaviour.
2. **Hand-prove a genuinely inductive invariant set** (assume-guarantee) per
   claim. The simple history helper already failed, so this is a real claim and
   design effort.
3. **Reachability-constrained induction** — note that `yosys-smtbmc -i` is
   *still* arbitrary-pre-state k-induction, so the SMT unlock alone does not
   provide this.

Both (2) and (3) are claim-semantics or toolchain decisions for the manager, not
silent solver effort. This section exists so that decision is made on
**measurements** rather than on the hope that a reformulation would help. And the
one thing that is *not* a gap: the C2 tautology incident and the H3 removal are
evidence the bar works, not evidence the campaign is weak.
