---
title: Formal verification — what is proved, what is only tested, and how to tell
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [verification, architecture, tooling]
sources: [reviews/2026-09-25/FORMAL-VERIFICATION.md, reviews/2026-09-25/FORMAL-STRENGTHENING.md, formal/results/summary.txt, formal/results/mutants.txt, formal/fv_run.sh, formal/smt_induct.sh, formal/run_formal.sh]
confidence: high
---

# Formal verification

The deep-reading page for the chip-side formal campaign. Its subject is a
distinction this project had to learn the hard way, so that distinction is the
spine: **a property that is TESTED is not a property that is PROVED.** Testing
can observe a violation on the stimuli it happened to run; a proof either
closes the property for all reachable states or produces a counterexample. The
campaign started because the queue looked empty while the design's safety
properties were only ever tested. The repo already had a live example of the
gap: the 18:43 unrestored `m1` mutant (`pad_oe = reg_oe`) reddened three
testbenches for a whole session, and nothing in the suite could have *proven*
the open-drain invariant that would have caught it where it was written.

The subjects are the hardware named in [[concepts/host-chip-protocol]] and
[[concepts/debug-control]]; the structural context is
[[concepts/factored-hardware-blocks]]. The open items, the claim-reformulation
thread and the IFG deep-dive live in the companion page,
[[concepts/protocol-formal-gaps]].

## The denominators — three numbers that are not interchangeable

This is where a reader most easily goes wrong, so it comes first.

| number | what it counts | where it is recorded |
|---|---|---|
| **5 modules** | the five proof subjects: `pe_pinmux`, `pe_eth_tx`, `pe_ctrl`, `pe_soc`, `pe_cpu` | the `formal/<mod>/` directories |
| **10** | the ten **gate target rows**: 8 PROVED, 1 REACHABLE, 1 VACUOUS (6 `bmc`, 4 `induct`) | `formal/results/summary.txt` |
| **11 targets** | those same ten **plus the SMT unlock** | ten `run_target` entries in `formal/run_formal.sh` + `formal/smt_induct.sh` |
| **14 mutants** | fourteen injected defects, all `CAUGHT` (4 `bmc`, 10 `induct`) | `formal/results/mutants.txt` |

The maps print **"10 properties / 5 modules / 14 mutants"** and a dispatch may
call the toolchain total **"11 targets"**. Both are right and neither replaces
the other: the 11 is *targets* and the 10 is *properties-as-gate-rows*. The one
honest caveat is that the 10 is a count of **targets, not of assertions** — the
`pe_ctrl` target alone carries twelve claims (eight unbounded, four at gate
depth) and `pe_cpu_debug_hold` adds S1–S4, so the assertion-level property
count is considerably larger than ten. Read "10" as "ten gate targets", never
as "ten properties exist".

Final gate state: **8 proved, 0 failed, 1 reachable-at-depth, 1
vacuous-at-depth, 0 findings**; mutant harness **14 caught, 0 survived**.

## Three outcomes, and only one of them is a pass

A `reach` target inverts the claim — it asserts a state is *never* reached — so
a model is the **good** answer (the claim is live) and a proof is a **warning**
(vacuous at that depth). A `refute` target is a claim the RTL is *expected* to
violate, so `NOTPROVED` confirms a recorded finding and `PROVED` would mean the
finding is closed. This is why one row of `summary.txt` reads `VACUOUS` and
another reads `REACHABLE` and neither is a failure of the harness: one of the
eth_tx reachability claims is genuinely not exercised at the gate depth, and
saying so is the honest outcome. A future cleanup could distinguish "ended at a
model" from "hit the memory cap" in the summary labels, which is currently
cosmetically wrong for the two cheapest runs.

## The two engines, and what the second one bought

Campaign I ran on yosys' **built-in `sat`** because there was no alternative:
SymbiYosys could not be installed, and decisively **there was no SMT solver on
the host at all** — boolector, yices, z3, cvc4, cvc5, bitwuzla and mathsat were
all absent, so `sby` could not have run even if present.

Campaign II closed that gap with one user-space install:

```sh
PIP_REQUIRE_VIRTUALENV=0 pip3 install --user --break-system-packages z3-solver
```

`z3-solver` 5.1.0.0 landed `~/.local/bin/z3`; `sby` was cloned but is only a
wrapper (the real driver, `yosys-smtbmc`, already ships with yosys), and
`symbiyosys` has no PyPI package. The only obstacle was pip's
`require-virtualenv` config — this is the "one pip from closed" gap.

The second engine is `formal/smt_induct.sh`: `write_smt2` → `yosys-smtbmc -s
z3`. The reason it can do things the built-in engine cannot is structural — in
yosys' `sat -tempinduct` a register's next-value is **duplicated per sampling
domain**, whereas the SMT encoding gives each register **one** next-value
function.

It was **validated before it was trusted**, which is the part that matters: a
sanity design finds a planted counterexample, the known-inductive `pe_ctrl`
subset (`-DFV_INDUCT`) passes, and the `pe_soc` C1+C2 target passes under this
second, independent backend. So a failure on a hard claim means the *claim*, not
the tool. What it bought: the `pe_soc` **C2** owner-**set** guard is now proved
unbounded by two independent engines, and `pinmux_od_invariant` was promoted
from depth-16 BMC to **unbounded**. Four claims ended the campaign unbounded —
`pe_soc` C1, `pe_soc` C2, `pe_pinmux` `od_invariant`, and `pe_ctrl` C1 — each
mutant-checked.

## The mutant bar is the anti-vacuity device

A "PROVED" that never reaches the interesting states is worse than no proof,
because it is trusted. So every claim is attacked by injecting a mutant that
targets *that* claim, and the claim is only worth its proof if the mutant dies.
This found the campaign's most important result: the eth_tx IFG claim passed at
depth 16 and was **vacuous** there, because no frame can complete in 16 cycles.
Full detail in [[concepts/protocol-formal-gaps]].

The same reasoning removed a formal claim outright. **H3** — "an armed
breakpoint address is inside instruction memory" — is a **tautology** at the
shipping parameterisation (a 10-bit register against 1,024 words), and the
mutant that removes the RANGE guard *proved* it rather than failing it. A
vacuous claim in a proof is worse than a missing one, because it is trusted;
the real protection turned out to be refusing the full-width request, which is
owned by a testbench case and its mutation where it is differential. The same
judgement caught a reformulation that "closed" a claim only because it had
degenerated to a `|| 1'b1` tautology, before it reached the harness.

Two mechanical lessons are now encoded in the scripts rather than in prose.
**`-set-init-zero` is mandatory** — without it flip-flops start unconstrained,
the solver may begin mid-frame, and every safety property fails for harness
reasons; three of the first four counterexamples were exactly this. And
**hierarchical references do not become connections in yosys**, even under
`-flatten`: `dut.reg_od` floats, so a tap-based wrapper compares the DUT against
noise and reports a confident, meaningless FAIL. The wrappers use reference
models built from observable ports, which also makes each claim stronger.

## What a reviewer should re-run first

In this order, cheapest and most diagnostic first:

```sh
# 1. the machine-recorded state, free and instant
cat formal/results/summary.txt      # 8 proved / 1 reachable / 1 vacuous
cat formal/results/mutants.txt      # 14 mutants, all CAUGHT

# 2. the full gate (every target, bounded depths) — minutes to ~1 h
bash formal/run_formal.sh

# 3. the non-vacuity evidence — this is the part that is not a gate
bash formal/mutants.sh

# 4. one proof in the strong shape, to see the unbounded spelling
FORMAL_SAT_MODE=induct bash formal/fv_run.sh /tmp/probe.log \
    formal_pe_eth_tx_ifg 1 formal/pe_eth_tx/formal_pe_eth_tx_ifg.v \
    rtl/pe_eth_tx.v rtl/pe_crc.v

# 5. the second engine (needs the pip install above)
bash formal/smt_induct.sh formal_pe_soc 3 \
    formal/pe_soc/formal_pe_soc.v formal/pe_soc/sram_model_formal.v rtl/pe_soc.v
```

Two operational notes a reviewer should inherit. Every proof runs under
`ulimit -v` 6 GB **and** a one-yosys-at-a-time `flock`, because two yosys runs
once diverged at 6+ GB and tripped the RAM runaway brake — a run that dies there
exits as `ERROR` with a truncated log and is a **strategy signal, never a
reason to retry deeper**. And the lock protects files, not a hand edit: during
the F2 work a concurrent mutation harness restored `rtl/pe_soc.v` from a
pre-edit snapshot and silently deleted the guard. **Never edit RTL while a
suite or mutation harness is in flight.**

## Limits

Simulation and mapped pre-layout screening only. There is no physical flow, no
place-and-route, no DRC and no LVS in any of this, and **no board has been
run** — nothing here is hardware-confirmed. The `eth_tx` runt/jabber guard was
recorded as proved only *weakly* at one point, and that framing is the honest
one to carry forward. Everything on this page is bounded by the reachability
limits of the two engines: see [[concepts/protocol-formal-gaps]] for the four
claims that remain depth-16 only, and why the blocker is claim structure rather
than a toolchain or effort gap.
