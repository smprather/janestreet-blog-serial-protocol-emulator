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
| **wiki gate negative control** | `regress/test_check_wiki_pages.sh` | **was green VACUOUSLY — see below** | re-run after `587b425`: 46/0 |
| tmp isolation | `regress/`, `tools/`, `formal/` | **yes** | re-run: OK, 0 findings |

Nothing under `rtl/`, `tb/` or `firmware/` has changed, so the expensive half of
the verdict is untouched and the cheap half was re-checked in seconds. That is
the shape a stale verdict should be decomposed into, rather than being re-run or
asserted.

> **One correction to this section, found 00:45 — and it is about my own change.**
> The earlier version of this table said *nothing* under `regress/` had changed.
> That was true when written and **false within fifty minutes**: `587b425` at
> 23:19 changed `regress/test_check_wiki_pages.sh`. It is not a nit — see the
> row above and the finding below. The lesson is the one this document keeps
> teaching: **a decomposition has a shelf life too.** Decomposing a stale verdict
> is not a one-time act of honesty; the decomposition is itself a claim about
> the present, and it expires at the same rate everything else does.

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

#### The anchors, in a form a check can read

Prose tables are for people; these five claims are load-bearing, so they are also
written out as `file<TAB>phrase`. A phrase that no longer appears in its file is
a drifted record — which is not hypothetical: this record's references expired
**three times in two hours** (line numbers, then a directory-level claim, then a
whole row that was green for the wrong reason).

```text
file<TAB>phrase<TAB>meaning
wiki/concepts/protocol-freqmeter.md	twelve points spanning 158 Hz	PRESENT = the defect; its disappearance means someone fixed it
wiki/concepts/protocol-freqmeter.md	The testbench sweeps the input over	PRESENT = the CORRECT claim; its disappearance means someone broke it
wiki/concepts/protocol-freqmeter.md	The warm-up period of each run is not checked	PRESENT = correct
tb/tb_pe_soc_freqmeter.v	twelve points from 80 Hz	PRESENT = the defect; 7fe4a1f replaces it, unmerged
tb/tb_pe_soc_freqmeter.v	N_BANK   = N_SEG * (N_PER_SEG - 1)	PRESENT = correct
regress/run_all.sh	Twelve banked points from 100 Hz to 12.5 kHz	PRESENT = correct (mine)
```

**Deliberately not wired into a gate.** A check that verified a record's anchors
would be a gate nobody asked for, added at 01:00 by the worker who wrote the
record — the exact scope failure this session has declined twice already, and
worse here, because I would be gating my own prose. What is worth having is that
the anchors are *machine-readable at all*: the next session can check them with
one `grep -F` loop, or wire them into `check_doc_index.sh` if that is ever the
right home, and the difference between those is a decision that belongs to
somebody other than me.

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

**3. The freqmeter `$display` — the GENERATOR of all three wrong copies, already
diagnosed by its owner and waiting on a decision.** The banner opens at
`tb_pe_soc_freqmeter.v:309`, and the range it prints is on **line 310**. That
line passes `N_BANK` ("12 banked points") directly beside `1_000_000/p_us[0]` and
`1_000_000/p_us[N_PTS-1]`, so the banner announces
**"12 banked points, 158.7 Hz to 10 000 Hz"** — the full sweep's endpoints, and
`p_us[0]` is run 0's warm-up, never banked. The twelve are
`p_us[2]` (100 Hz) to `p_us[16]` (12.5 kHz). **This line is where
"158 Hz" came from** in the `run_all.sh` comment, the TB comment and the wiki.

`7fe4a1f` (unmerged) already documents this, in the file. Quoted as three
contiguous lines of their comment, because the comment WRAPS and a one-line
quotation of it would be a sentence I assembled rather than one they wrote:

> *"NOT DONE HERE, because the sweep was scoped COMMENT-ONLY and this is a"*
> *"$display: the honest fix is to label the two figures in the string"*
> *"itself, which is a behaviour-visible change and needs a decision."*

The banner is unchanged;
only the comment around it was fixed. So this needs a **decision, not a
diagnosis** — and it is a real one: a `$display` edit changes test output, which
is exactly the kind of thing the dep-guard and mutation harnesses treat as
observable, which is presumably why it was correctly deferred.

It also **leaves no trace**: `run_all.sh` captures only each case's PASS/FAIL, so
the string is in no run log, and there is no freqmeter mutation harness, so the
act's output lands in exactly one place — a terminal. A wrong claim that is
never written down cannot be diffed, reviewed, or gated.

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

**5. A gate can report OK for a reason that has nothing to do with what it
checks — and my own change caused one.** `8fea9fc` routed every gate log in
`run_all.sh` through `$CHIP_WT_DIR`. That broke
`regress/test_check_wiki_pages.sh`, whose wiring fixture did not set the
variable, so the fixture's redirect became `/check_wiki_pages.log` —
unwritable (verified). The gate therefore went **RED**, and the wiki negative
control *wants* red, so it passed **for the wrong reason**: the 21:50 run's
`negative control: OK (46 passed, 0 failed)` was satisfied by the fixture's own
breakage. `587b425` at 23:19 fixed it, and its message states the class better
than the fix does: *"a fixture must model everything the thing under test
READS, or it is measuring the fixture."* Mechanism verified (`/` unwritable);
the vacuous pass is strongly implied, not demonstrated — I did not run another
worker's pre-fix regression to watch it fail. The 47 cases and 16 suites are
unaffected and stand; this leg is the one that was not real.

**6. Cheap proxies, published as measurements.** Eight of my own claims were
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
