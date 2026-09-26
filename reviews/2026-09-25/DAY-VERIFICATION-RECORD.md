# Day verification record — 2026-09-25

The single page a submission reader can check. Every number below was **measured
on this tree on this day**, and every row says where its proof lives so a reader
can go and look rather than take a claim. Anything not proven here is in §5, in
the open-items table, and not quietly folded into a green tick.

Author: protocol-worker. Tree: `main` at `5199060` + the two commits this record
ships with. Scope: the chip side of the R2 held-core work, the merge gate and its
mutation narrowing, the harness-edit pre-flight, and the state of everything the
day's work touched.

**What "chip-confirmed" means everywhere in this document: confirmed IN
SIMULATION against real RTL, byte-exact including the CRC word. It is not
evidence about silicon.** No board has been run. That sentence is the one that
matters most on this page and it is repeated wherever a count appears.

---

## 1. The gates, and what each one currently says

| Gate | Current number (2026-09-25) | Where its proof lives |
| --- | --- | --- |
| **RTL regression** | **46/46 cases PASS** | `regress/run_all.sh`; the case table is in that file and is what the merge gate maps onto |
| **Firmware** | **36/36 PASS** | `regress/run_firmware_tests.sh` (assembles every `.pe`, then runs the emulator) |
| **R2 read-path conformance** | **22/22 golden steps byte-exact** | `tb/tb_pe_ctrl_r2.v`; record `reviews/2026-09-25/R2-HELD-CORE-CHIP-SIDE.md`; bytes from the host package `reviews/2026-09-25/r2-hex/` |
| **R3 debug conformance** | **14 vectors / 26 steps; 25 of 26 chip_confirmed** | `tb/tb_pe_ctrl_r3_conf.v`; `reviews/2026-09-25/R3-CONFORMANCE-AND-RUN-LOCK.md`; pinned set in `tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt` |
| **Formal safety** | **8 PROVED**, 1 REACHABLE, **1 VACUOUS** (§4) | `formal/run_formal.sh`; per-target table in `formal/results/summary.txt` |
| **Formal non-vacuity** | every proof kills the mutant that attacks it | `formal/mutants.sh`; per-mutant table in `formal/results/mutants.txt` |
| **Mutation suites** | **16 suites, 0 unexplained survivors**; 1456 s sequential, measured | `regress/mutate_*.sh`, each guarded by `regress/check_mutation_lists.sh`; cost table in `reviews/2026-09-25/MERGE-GATE-MUTATION-NARROWING.md` §6 |
| **Host package (API layer)** | **35 PASS, 0 FAIL, 1 SKIP** (the skip is `micropython`, not installed on this host) | `tools/host_gui/run_host_tests.sh` |
| **Lint / elaboration** | clean, 10 modules | `regress/lint.sh` |
| **STA** | R2 and R3 `pe_soc` screens; **unconstrained endpoints 1 → 0** on M4, worst slack unchanged | `reviews/2026-09-25/r2-sta/`, `r3-sta/` |
| **Merge gate** | demonstrated **RED** on the real merge, **GREEN** on a benign one, and its count cross-check made to disagree and correctly refused | `regress/verify_merge.sh`; `reviews/2026-09-25/MERGE-FORENSICS-5B4731F.md` §6; demo output in `reviews/2026-09-25/merge-gate-demos/` |
| **Harness-edit pre-flight** | 7/7 self-test; **demonstrated firing** (exit 4) on a real mid-run edit | `regress/dep_guard.sh`, `regress/test_dep_guard.sh` |
| **Gate self-tests** | `verify_merge --self-test` **27/27**; `check_shell_syntax` **32 scripts**; `check_harness_preflight` **16/16**; `check_mutation_lists` **16/16** | each in `regress/` and wired into `run_all.sh` |

The six timing acts that were red at `5b4731f` are green on this tree
(`rtl/pe_cpu.v`'s case-equality consumption plus an explicit tie-off in each act
TB, fw-timing's `3657847`). That repair is the reason the merge gate exists; the
gate is what stops the next one going out red.

## 2. R2 held-core: 22 of 22, and what that 22 is

The four steps added today (`status_reports_the_hold`,
`dump_core_answers_the_same_header`, `status_reports_the_hit`,
`dump_core_refused_the_strap_is_high`) exercise debug **states 2 and 3** — the
surface the original 18 never touched, and the compatibility risk the chip review
raised as MEDIUM 3. The host package now carries all four as
`chip_confirmed: true` (**22 of 22**), which was their side to flip and is
recorded here as state, not as chip-side work.

What makes those four worth more than a byte comparison: the held pre-state is
established by **driving the debug opcodes** — `DEBUG_BP_SET`, `DEBUG_STEP`,
`DEBUG_BP_CLR` — with the core-side ports supplying what a core would supply.
**Nothing is forced hierarchically.** `pe_ctrl.v:692` latches a free-running hit
from the core's own `dbg_next_pc`, and `pe_ctrl.v:1067` latches it on the step
path, so both states are reachable through the real decode. `tb_pe_ctrl_r3_conf`
independently shows a **real `pe_cpu`** reaching both states by these same
opcodes, which is what distinguishes this from the review's MEDIUM 2 (a testbench
forcing a state the RTL cannot reach).

The steps are **load-bearing, and proved so by mutation**: swapping the 2/3 state
encoding gives 18/22 with exactly the four new steps failing — i.e. the shipped
18 were blind to it, which is the whole reason the vectors exist — and gating
`OP_DUMPCOR` on the hold instead of the run strap fails
`dump_core_refused_the_strap_is_high`, pinning the asymmetry a debugger has to
code around.

## 3. The pinned divergences — one step, two words, and it is a model boundary

`tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt`, the machine-readable part:

```text
status_full_readback word 13: chip 0000, package f000
status_full_readback word 14: chip 2efc, package 3d3d
```text

Both words are the `insn` field, and both are a **testbench model boundary, not a
disagreement about the contract**. The package's `insn` is a mid-execution
snapshot at `pc=4` with `a=0`; the contract's ruled landing word is `0xF000`.
R3.1 measured what the chip produces at `pc=4` in *every* regime it can be put
into and none of them yields `0xF000` — held it reports `imem[pc]`, and
free-running it either collapses the fetch pipeline onto the fill word or leaves
the address entirely, because the `JMP` at 4 targets 2. The vector's whole
pre-state is additionally unreachable: reaching address 4 executes address 3, so
`a` would be `0x0F`. The gate compares the observed **set** against this list, so
a divergence that changes, or any new one, turns it red.

**This list used to hold seven words across three steps, and it shrank on
evidence.** The other two were host-side vector defects, proved by the chip's own
conformance run and fixed host-side in the gui-worker's `b9d4eb2`
(`read_cpu_shows_a_55` carried a stale `insn` and the host's debug `state` in the
slot the contract gives to `run`; `status_reports_the_hit` carried a stale `a` for
an LDI the step really does execute). Nothing was edited to make the list smaller
— it is regenerated from the evidence, which is the point of pinning a set rather
than hard-coding an expectation.

## 4. The two formal results that are NOT clean, stated plainly

A table of green ticks is worth nothing if the exceptions are hidden, so:

* **`eth_tx_reach_tx_done` is VACUOUS at depth 16.** The claim does not fail and
  does not pass: the state it is about is not reached within the bound, so the
  proof says nothing. It is reported as `VACUOUS`, not as `PROVED`.
* **`eth_tx_reach_busy` is REACHABLE**, with a truncated result line
  (`killed while printing the model`) — a harness artefact, not a verdict about
  the design.
* The remaining **8 targets are PROVED**, and each is mutant-checked: a proof that
  survived the mutant attacking its own claim would be reported, and none did.

The R3.2 toolchain question is a **backend** gap, not a claim gap: `z3-solver`
5.1.0.0 is installed user-space and `yosys-smtbmc` is present, so SMT induction
runs; four `pe_ctrl` claims remain at their bounded depth because each relates a
live register to a free lagged snapshot no induction hypothesis constrains. That
is a claim-authoring decision, recorded, not an unproved claim presented as proved.

## 5. Open items — none of these is a green tick in disguise

| Open item | What it is | Why it is open |
| --- | --- | --- |
| **Hardware acceptance run** | the real Pico/USB acceptance run over a physical shuttle | **not executed.** Everything in this document is simulation. This is the one item that separates "chip-confirmed in simulation" from "works on a board", and no amount of gate output substitutes for it |
| **HC-SR04 TB is RED and UNWIRED — and the green suite is silent about it** | `tb/tb_pe_soc_sr04.v` fails (**6 failing checks** measured 2026-09-26, first: "the firmware banked both measurements (dmem[10] = 01)") and is **the only act testbench not in `run_all.sh`'s case list** | **fw-timing's WIP.** This is the claim-hazard class rather than an open item: `run_all.sh` reports **46/46 PASS** and says nothing about an act that exists, fails, and is absent from the list. `verify_merge.sh`'s same-list check *does* report it — as a **warning on a merge**, not a failure — so it is a line nobody reads until a merge happens. Reproduce from **`tb/`**, not the repo root: `cd tb && vvp <compiled>`; from the root the TB's `$readmemh("../firmware/…hex")` cannot open the file and prints a **false red** (`dmem[6] = xx`), which is how a passing testbench gets reported as failing. **CORRECTED 2026-09-26:** this row previously named the **freqmeter** act as RED and unwired. That was wrong twice over — `tb_pe_soc_freqmeter` is wired into `run_all.sh` and **passes** (0 failing checks) when run from `tb/`. The root cause is the reviewer's own: the claim came from a merge-gate run ~50 minutes earlier that correctly flagged freqmeter as unwired, and the fact moved when fw-bus wired it. A number re-derived from a gate run and not re-derived before shipping a record is the same failure as the R3 24/25 near-miss recorded in §7. |
| **R3.2 toolchain-gap closure** | four `pe_ctrl` claims bounded rather than unbounded | the SMT unlock landed (`z3-solver` + `yosys-smtbmc`, one `pip --user` away from where it was); the remainder needs a **claim reformulation**, which is a decision about what the claim means, not a solver-strength question |
| **Mapping the mutation suites by RTL** | `verify_merge.sh` narrows mutation suites by their published `MUTABLE` lists (implemented) | done — recorded here so the earlier note in the merge-gate review is not read as outstanding |

## 6. Case study: the race that a green gate cannot see

**The incident.** At 21:10 a gate run hit a `FATAL` **mid-edit** of harness work
and, on re-run, went **GREEN**. The run that failed and the run that passed were
minutes apart, and the difference was not the RTL: it was that a script had moved
underneath a running bash. Bash reads a script **incrementally**, so a harness
edited while it executes can execute fragments of whatever the editor wrote.

**Why the dangerous direction is the other one.** A broken run that says so is
merely embarrassing. The same race can make a harness report **PASS**: the
mutation loops, the survivor counts and the exit code are all decided by the very
text that just moved. A false pass is believed, and that is the worst thing a gate
in this project can do — worse than a crash, worse than a red.

**What closed it.** `regress/dep_guard.sh` stamps the **content** of the scripts a
run executes and re-checks them on the way out; a changed, or vanished,
dependency makes the run exit **4 = INCONCLUSIVE** and
`regress/verify_merge.sh` reports it as such **even if the run exited 0**. It is
checked over the whole `regress/` dependency set at the run's exit and again
around every mutation suite, and every one of the sixteen harnesses is covered on
its own exit path — asserted by `regress/check_harness_preflight.sh`, so the next
harness cannot arrive unprotected.

**Demonstrated, not asserted.** A **standalone** `mutate_i2c_tb.sh` that genuinely
passed — "all mutations accounted for" — was appended-to 200 ms into its run and
**exited 4** with `CHIP-DEP-CHANGED`, rather than reporting the pass it had just
earned. The guard's own test (`regress/test_dep_guard.sh`, 7 cases, a gate inside
the full suite) includes the negative control: with the comparison disabled it
fails 3 of 7, so the test is proven capable of failing.

**A note on the incident's own record.** A second race bit during the same day's
work, and it is the reason the fix above needed its own gate. A scripted edit broke
`regress/run_lock.sh`, and the verification said "all parse" — because
`bash -n regress/*.sh` parses **only the first file** and passes the rest as
positional parameters. The one-liner every shell project reaches for silently
checks 1 file of 31. `regress/check_shell_syntax.sh` now runs one `bash -n` per
file, prints the count, and refuses fewer than five.

## 7. A caution about this document's own numbers

While assembling §1, `chip_evidence.confirmed_steps` appeared one entry short of
the package's own `chip_confirmed` flags — 24 against 25 — which is the exact
stale-prose failure class this project has already fixed once, in a shipped,
reader-facing artifact. **It is not a defect.** Two vectors both contain a step
named `step_one`, so there are 25 (vector, step) pairs and 24 unique names, and
both manifests' lists are complete and correct. The count was wrong in the
analysis, not in the artifact.

It is recorded here because a verification record is the worst possible place to
publish a number derived with a `Set` instead of counting what the `Set` was
counting, and because the rule that caught it is the rule this whole project runs
on: **a count is an assertion.** A number that has never been derived twice, by two
ways, is a claim.
