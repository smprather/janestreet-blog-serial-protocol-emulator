# Per-worktree artifacts — state of the fix

**2026-09-26 · branch `main` · handoff for a fresh context**

This is the record to continue from. Written so the next session does not
rederive anything: what is green, what is with the manager, and the findings
that are worth more than the fixes they came from.

---

## The one-line version

Every artifact a run compiles, logs or tails now lands in a **per-worktree
scratch directory** (`CHIP_WT_DIR`), a **lint gates the class** so the next
instance cannot be introduced silently, and the run that proves it is
`MERGE GATE: GREEN — HEAD (47 case(s) run, 16/16 mutation suites run)`,
`VERIFY_MERGE_EXIT=0`.

---

## What is green, and what proves it

| what | status | proven by |
| --- | --- | --- |
| full suite | GREEN, 47 cases, 16/16 mutation suites | `verify_merge.sh`, exit 0 |
| tmp isolation | OK, 0 findings, 2 audited exemptions | `regress/check_tmp_isolation.sh` |
| tmp-isolation **failure path** | reports a NAMED failure, exit 1 | planted-violation test, restore verified |
| run lock | 17/17, holds fd 9, per worktree | `regress/test_run_lock.sh` |
| dep-guard | 13/13, message names both causes | `regress/test_dep_guard.sh` |
| R3 claim | checked rendering of a gated fact | negative control + in-suite |
| `formal/smt_induct.sh` | BMC + INDUCTION pass, model per worktree | run directly at 23:04 |
| tree | clean | `git status` |

Reproduce the gate: `./regress/verify_merge.sh` (~40 min). Reproduce the
isolation property in seconds: `./regress/check_tmp_isolation.sh`.

### What that GREEN still covers (read this before quoting it)

Main moved after the 21:50 run: 18 `wiki/` files from two editorial passes, plus
`WORKLOG.md`, this record, and `formal/results/summary.txt`. So the verdict
decomposes, and the useful thing is to say which half is which rather than
either re-running everything or quoting a stale number.

| leg of the 21:50 run | reads | still valid? | re-verified at 23:4x |
| --- | --- | --- | --- |
| 16 mutation suites, 47 cases | `rtl/`, `tb/`, `firmware/` | **yes** — nothing there moved | — |
| wiki page rules | `wiki/**.md` | no | `check_wiki_pages`: 0 new, 0 stale |
| document links | `wiki/**.md` | no | `check_wiki_links`: 0 new, 0 stale |
| document index | `wiki/index.md` + renders | no | `check_doc_index`: OK |
| diagrams | `diagrams/*.puml` | **yes** — no `.puml` moved | `check_diagrams`: OK (re-run anyway) |
| formal safety / mutants | `formal/*/`, `rtl/` | **yes** — only the *generated* summary moved | — |
| tmp isolation | `regress/`, `tools/`, `formal/` | **yes** | re-run: OK, 0 findings |

Nothing under `rtl/`, `tb/`, `firmware/`, `diagrams/` or `regress/` changed, so
the expensive half of the verdict is untouched and the cheap half was re-checked
in seconds. That is the shape a stale verdict should be decomposed into, rather
than being re-run or asserted.

---

## The four defects, and what each one actually was

| # | defect | commit | the real shape |
| --- | --- | --- | --- |
| 1 | cross-worktree `/tmp` collision | `a04bc7f` | the run lock was **sound** and its scope was **narrower than the resource it protected** |
| 2 | the same class reaching the **main testbench sweep** | `8fea9fc` | `run_all.sh` compiled *every* testbench to `/tmp/${top}.vvp`, `$top` being the module name |
| 3 | a harness declaring a state it never earned | `8fea9fc` | `chip_dep_expect mutated $MUTABLE` after writing **one** file; voided a run and read as interference |
| 4 | a **partial** fix of my own | `837ea17` | `grep "/tmp/mut_"` cannot match `/tmp/mutate_`; a04bc7f missed a whole harness |

---

## With the manager — two items, both needing a decision, not a task

**1. The banked-range claim: four copies, three answers, and the pending merge
covers only one of the two wrong ones.**

Ground truth, re-derived from the `p_us` table and the banking loop
(`seg*3+1`, `seg*3+2`, so `p_us[0]` is an un-banked warm-up):
**100 Hz to 12.5 kHz**.

| file | says | status |
| --- | --- | --- |
| `regress/run_all.sh:234` | 100 Hz – 12.5 kHz | correct (mine) |
| `tb_pe_soc_freqmeter.v`, the line containing **"twelve points from 80 Hz"** (line 57 as of `8397c5b`) | 80 Hz – 10 kHz | wrong; `7fe4a1f` replaces it, **unmerged** |
| `protocol-freqmeter.md`, the sentence containing **"twelve points spanning 158 Hz"** (line 257 as of `4066c8e`) | 158 Hz – 10 kHz | wrong, and **nothing pending covers it** |
| `protocol-freqmeter.md`, the sentence containing **"sweeps the input over 158 Hz"** (line 38 as of `4066c8e`) | 158 Hz – 10 kHz | **CORRECT — do not "fix" this one** |
| `protocol-freqmeter.md`, the sentence containing **"twelve points spanning 158 Hz"** (line 257 as of `4066c8e`) | 158 Hz – 10 kHz | wrong, and **nothing pending covers it** |
| `protocol-freqmeter.md`, the sentence containing **"sweeps the input over 158 Hz"** (line 38 as of `4066c8e`) | 158 Hz – 10 kHz | **CORRECT — do not "fix" this one** |
| `tb_pe_soc_freqmeter.v`, the line containing **`N_BANK   = N_SEG * (N_PER_SEG - 1)`** (line 116) | "12 banked points" (count only) | fine |

> **Anchor on the words, not the line.** An earlier version of this record cited
> `:252` and `:33`. Commit `4066c8e` (23:14) added lines to that page and both
> references now point 5 lines early — `:252` lands on a blank line. The line
> numbers above are dated to `4066c8e`; the quoted phrases will not expire.

**Checked across every ref, 00:30:** the wrong sentence is present on **all 12**
local branches and remotes, and a search for a correction
(`twelve points spanning 100 Hz`, `12.5 kHz`) in that page returns **nothing on
any ref**. So the wiki copy is wrong everywhere and fixed nowhere — which is a
stronger statement than "nothing pending covers it", and it is the one to act on.
`7fe4a1f` touches `WORKLOG.md`, `firmware/freqmeter.pe` and the TB — **not the
wiki**. So the obvious merge fixes one wrong copy and leaves the other.

**2. `fwbus/block3-land` merge — a trap in the resolution.** Merge tested in a
throwaway worktree: `run_all.sh` **auto-merges**; the conflict is
`regress/mutate_fwbus_tb.sh`, **3 hunks**. If their `LOG=/tmp/mutate_fwbus_case.${_wt}.log`
wins, the tmp-isolation lint **reds the suite** — not because their fix is wrong,
but because the lint exempts `CHIP_WT_DIR` and `_diag_wt` and not `_wt`.
Resolution is two lines and *simpler* than theirs: their harness already sources
`run_lock.sh` at `:40`, so `CHIP_WT_DIR` is exported there — delete their three
local `_wt` lines.

---

## The findings worth more than the fixes

**1. A guard can be correct and still blind.** In defect 1, the per-worktree run
lock did its job exactly as designed and the dep-guard was *provably* clean
(`.hit` absent, `.uncovered` empty, `.sample.done` present) while the run was
still wrong. The interference was in `/tmp`, which **no guard in this
repository watched**. `run_lock.sh` had documented the false premise in its own
comment. Fix the scope, not just the instance.

**2. Coverage, not correctness, is the recurring disease.** Three times in one
evening, a record was true about what it covered and silent about what it did
not: a RULING that fixed one of two instances of an error; the same error living
in a `run_all.sh` comment and a testbench comment, one fixed and one orphaned;
and the R3 README claim, checked for self-consistency while a **jointly** stale
claim in both copies would have passed every gate. A reader cannot tell the
difference by looking. The R3 check (`annotate_r3_confirmations.py`) is the
pattern: **make prose a checked rendering of a gated fact.**

**3. Extract and RUN; never extract and READ.** Three times tonight a test of my
own work passed or failed for the wrong reason: a render harness that held a
*hardcoded copy* of the line under test; an advice test that asserted on a
half-remembered phrase; and worst, a harness that `sed`-**printed** a block
instead of executing it, so the variable held the block's *text* and the first
assertion **passed spuriously** — because the text contains the string it was
searching for, while the code never ran. Treat any assertion that passes first
time as suspect until you have watched it fail on a known-bad input.

**4. Three workers, one convention, three independent proofs.** The
`git rev-parse --show-toplevel | md5sum | cut -c1-8` worktree discriminator was
independently arrived at by three people for the same defect class — `_diag_wt`
(diagrams), `_wt` (fwbus), `CHIP_WT_DIR` (here). One reached it by reading
`"detected: 12"` in its own **green** log and realising it was another worktree's.
That convergence is better evidence than any argument in this document.

**5. Cheap proxies, published as measurements.** Eight of my own claims were
wrong tonight and every one came from the same move: reporting a grep's reach, a
variable's file count, a coincidence, or an intuition as if it were a
measurement. The rule that survives: **never transcribe what a tool can print,
and when a dispatch and a measurement disagree, the measurement decides and the
dispatch gets told.**

---

## If you pick this up

Nothing here is unfinished. The two open items are **decisions**: the wiki copy
of the banked range (item 1) and the merge resolution (item 2). Everything else
is green, proven, and — where it could be proven without a 40-minute run —
exercised, including the two paths that had never executed before tonight: an
unrun change in the **formal** lane, where a silent break is a false `PROVED`,
and a gate's **failure** path, which a green run can never demonstrate.
