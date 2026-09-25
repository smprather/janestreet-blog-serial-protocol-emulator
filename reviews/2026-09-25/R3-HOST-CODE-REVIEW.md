# R3 host-side code review — independent cross-review (mirror)

Reviewer: protocol-worker. Date: 2026-09-25. Scope: the R3 host-side additions
(`tools/host_gui` + `tools/host_bridge`) against the **frozen chip contract**
(`reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md`), the `chip_confirmed`
citation integrity, and test quality. **Read-only** — no host file was changed.

This is the mirror of the chip review the gui-worker ran on my side. I checked
the three areas the manager named: (1) protocol conformance to my contract, (2) the
25/26 citation arithmetic, (3) test quality. Every claim below is anchored to a
file:line or to a value I computed from the shipped artifact, not to a summary.

---

## Verdict

**Protocol conformance: PASS — no defects found.** The opcodes, the four response
shapes, the state encoding, the `bp_flags` layout, the stop-before + step
semantics, the `BP_CLR` release, the loopback/target handling, and the `READ_CPU`
run-slot all match the frozen contract, and the two host-side defects my
conformance run found (the stale `insn`, the `state`-for-`run` slot) are fixed
**and carry a comment naming the RTL line and the R2 evidence that settles the
shape**. The step-onto-breakpoint fix implements exactly the correction in my
§3b write-up: the step retires the instruction it stepped *from*, and stop-before
protects the instruction *at* the breakpoint.

**Citation integrity: 1 HIGH finding** (a stale, *generated* `notice` that
contradicts the per-step flags) — see F1. The 25/26 arithmetic itself is correct
and **pinned by four tests**.

**Test quality: STRONG.** The suite pins the exact confirmed count, the citation
requirement per step, the package-level flag, and the evidence-name count. The
model is a genuinely independent Python model of the ISA, so passing conformance
is real cross-implementation evidence, not the model agreeing with itself.

---

## F1 — HIGH: the shipped manifest's `notice` is stale and false (it is generated, so it keeps regenerating wrong)

**Where:** `reviews/2026-09-25/r3-hex/manifest.json` → `notice`, and identically
`reviews/2026-09-25/R3-DEBUG-VERIFICATION.json` → `notice`. **Source of the bug**
(so it regenerates): `tools/host_gui/r3_vectors.py:158` `PACKAGE_NOTICE`, wired at
`:201` (`notice=PACKAGE_NOTICE`).

**What it says (verbatim from the shipped manifest):**
> "NOT CHIP-CONFIRMED. … no step here has been run against the chip's
> `tb_pe_ctrl_r3` yet, **so every step is `chip_confirmed=false`**. A passing step
> in this package is the gate the chip must meet, NOT evidence that it does."

**Why it's false:** in that *same file*, 25 of the 26 per-step `chip_confirmed`
flags are `true` (each with a `chip_evidence` citation), and the same file's
`chip_evidence.conformance` reads *"tb_pe_ctrl_r3_conf GREEN: 26/26 steps
byte-exact, and 25 of them with NO divergence."* I verified the per-step count
from the shipped bytes: 25 flagged `true` out of 26 steps.

There is a second, self-contradicting instance of the same stale string in the
generator's obligations list (`r3_vectors.py:232`):
`f"every step is chip_confirmed=False: {CHIP_EVIDENCE['conformance']}"` — which
renders as *"every step is chip_confirmed=False: … 25 of them with NO divergence"*
in one sentence.

**Severity / why it matters:** this is the field a **tapeout reviewer reads
first**, and it flatly asserts the opposite of the per-step data. It is precisely
the "stale claim that reads as truth" failure class this project treats as worse
than a red test. Because it is *generated* (`PACKAGE_NOTICE`), regenerating the
package today reproduces the false claim — so a drift-gate run will not catch it;
the string simply never got updated when the 25/26 flip landed.

**Distinction I verified so this is not overstated:** the top-level
`chip_confirmed: false` is **deliberate and correct** — it means "the package as a
whole is not 26/26 confirmed" (one step is deliberately not), and it is pinned by
`test_r3.py:456`. Only the `notice` **prose** and the obligations string are
stale. I flag the string, not the flag.

**Fix (host side, not mine):** update `PACKAGE_NOTICE` to state the real position
— 25 of 26 confirmed with citations, `status_full_readback` deliberately not, the
run is IN-SIMULATION conformance, not hardware — and regenerate the manifest and
`R3-DEBUG-VERIFICATION.json`.

---

## Protocol conformance — checked and PASS (with credit)

| contract item | host implementation | verdict |
|---|---|---|
| opcodes `0x21`–`0x24` | `r3_reads.py:18-21`, `pe_frame.py:38-41` | exact match |
| `DEBUG_STEP` → `(OK,state,pc_next,bp_addr,bp_flags)`, len 0 | `r3_reads.py:18`, test `test_r3.py:69` | match |
| `DEBUG_BP_SET` → `(OK,state,pc,bp_addr,bp_flags)`, len 1 | `r3_reads.py:19`, test `:92` | match |
| `DEBUG_BP_CLR` → `(OK,state,pc,bp_addr_before,bp_flags)`, len 0 | `r3_reads.py:20`, test `:104-119` | match, and reflects **my corrected row 11** (pc=3 at request, re-zero on the next read) |
| `DEBUG_STATUS` → 10 words, `run` in slot 5 | `r3_reads.py:21`, test `test_r3.py:121-124` | match |
| state `hold?(hit?3:2):(run?1:0)` | `fake_pe.py:245-256` (`self.state`) | match (mirrors the RTL expression) |
| `bp_flags = {bp_hit, bp_en}` | `fake_pe.py:257-260` | match |
| step retires the instruction stepped FROM | `fake_pe.py:371-394` (`_execute_one()` then `bp_hit = landing==bp_addr`) | **correct** — the old bug (skipping the execute on a hit) is named and credited to my conformance catch |
| stop-before (live core) | `fake_pe.py:399-417` | correct — stops before executing the instruction at the bp |
| `READ_CPU` last word = `run`, not `state` | `fake_pe.py:566-574` | **correct**, with the RTL line + the R2 18/18 evidence cited |
| loopback / non-host target | `fake_pe.py:456-459, 488-495` | `UNSUPPORTED`, no fault — matches |
| bridge wires all four ops to the real frame | `main.py:156-159, 541-586`; `pe_frame.py` strips wait words + decodes generically | present |

The two host-side defects my conformance run caught (`read_cpu_shows_a_55`'s
stale `insn`/state-slot and `status_reports_the_hit`'s withheld execute) are both
fixed, and both fixes carry a comment naming the RTL source of truth. That is the
behaviour I want from a mirror side.

---

## Citation integrity — 25/26 arithmetic is correct and pinned

I computed from the shipped manifest: **25 of 26 steps flagged `chip_confirmed=true`,
each with a non-null `chip_evidence` citation** (0 uncited). The one unconfirmed
step is `status_full_readback` (my model-boundary step), which is correct. The
package-level `chip_confirmed: false` is deliberate (see F1). The arithmetic
honours the manager's ruling exactly: 23 clean + the 2 host-defect steps that
regressed the model to match the chip = 25, the model-boundary step held back.

**Test discipline (credit, and it's what makes the arithmetic trustworthy):**
- `test_exactly_the_confirmed_steps_are_confirmed` (`test_r3.py:436`) pins
  `len(confirmed)==25` and `unconfirmed==[boundary]`.
- `test_a_confirmed_step_must_cite_the_evidence` (`:481`) requires every confirmed
  step to carry a citation, asserts 24 distinct names, and asserts
  `status_full_readback` is NOT in the evidence list.
- `test_obligations_stay_unconfirmed_even_though_the_steps_do_not` (`:385`) keeps
  the host-side *obligations* unconfirmed while the *steps* are confirmed — a
  subtle and correct distinction between "the chip ran this" and "the host probed
  its own model".
- `test_simplifying_the_rule_would_break_the_chip_confirmed_r2_package` (`:225`)
  guards the R2 package from perturbation.

**Observation (handled, not a defect):** the evidence is keyed by step NAME, and
`step_one` names two distinct steps (`debug_step_sequence/step_one` and
`debug_step_lands_on_bp/step_one`), so 25 flagged steps map to 24 names. This is
**disclosed and pinned** — the docstring at `test_r3.py:459` explains it and the
test asserts the 24 count — so today it is right (both are confirmed). I note it
only because a future step that is confirmed under one meaning and not the other
would be masked by the shared name; the framework is honest about the limitation.

---

## Test quality — STRONG

- The suite pins the arithmetic, the per-step citation, the package flag, and the
  evidence-name count; it would fail on an unearned confirmation.
- The model is an independent Python ISA model, so the 26-step byte-exact
  conformance against the Verilog chip is real cross-implementation evidence, not
  a model compared against itself.
- R2 non-perturbation is explicitly tested (`:543`, `:365`).

**No demo-act file was found in the merged tree or the gui worktree** (`ls` for
`demo|act|judge` returns none in either), so I could not review the "demo act
beats" the manager listed. If it lives under a different name or was not merged,
point me at it and I will review it; I am flagging the gap rather than implying I
covered it.

---

## Summary

One substantive finding (**F1**, HIGH: a generated, stale, false `notice` in the
shipped manifest + verification JSON + obligations string — the only chip-confirmed
integrity issue, and it regenerates wrong until the host constant is updated).
Everything else I checked conforms to the frozen contract, and the citation
arithmetic and test discipline are stronger than I expected — the two host-side
defects my conformance run found were fixed with citations back to the RTL. The
demo act was not locatable and is unreviewed.

**No host file was modified.** The single fix (F1) is a text change in the host's
`r3_vectors.py` `PACKAGE_NOTICE` + regenerating the two artifacts; it is the
gui-worker's to make.
