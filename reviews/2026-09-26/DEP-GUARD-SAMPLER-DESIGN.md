# The harness-edit pre-flight: where it stands, and the sampler design

> **RESOLVED. §3 IS DISPROVED AND WAS NOT BUILT; ITS REPLACEMENT WAS RULED, BUILT
> AND LANDED. START AT §8.**
>
> This file was written as an open design and it stayed open after the question
> was answered, which is its own small lesson: prose that poses a question does
> not update itself when someone answers it. **§8 records the ruling, the
> mechanism that shipped, what was verified, and the coverage limit that comes
> with it.** §§3–7 are the history of how the wrong design was caught and what
> replaced it, and are kept because the disproof is the most useful thing in
> here — but nothing below is a plan any more.
>
> The short version, for a reader in a hurry:
> * **§3's discriminator is WRONG** and was never built. Its premise ("a
>   harness's own final restore is the last thing it does") is false for **all
>   sixteen** harnesses: they restore *per case inside the mutation loop*, so
>   "mutated → original → further mutation" is the normal shape of every clean
>   run. At the designed 50 ms poll it fired ~120 times on one clean
>   `mutate_i2c_tb.sh` run, which would have made every mutation suite return
>   exit 4 and every merge INCONCLUSIVE. Measurements in **§6**; the disproof is
>   an executable case in `regress/test_dep_guard.sh`.
> * The manager ruled **option (a), the declaration protocol**, and it is built,
>   wired into `run_mutation_suite`, enforced by `check_harness_preflight`, and
>   landed. All sixteen harnesses verified on real runs.
> * **The mid-run restore is now CAUGHT**, proven on a real harness.
> * **The honest limit:** detection requires the interference to persist
>   **0.15 s** (`CHIP_DEP_SAMPLE_PERSIST`), so a suite whose cases are shorter
>   than that — `mutate_serdes_tb.sh` runs 7 cases in 0.8 s, ~114 ms each — is
>   protected in the no-false-positive direction ONLY.

Date: 2026-09-26. Author: protocol-worker. Written at a hard wrap so a fresh
session can build the sampler without re-deriving it. **Nothing here is
speculative: every "is" below was measured, and every "is not" was measured
failing.**

## 1. What the guard does today, and what it does not

`regress/dep_guard.sh` is sourced by `regress/run_lock.sh`, so every script that
takes the run lock gets it. Two entry points, `chip_dep_stamp <label> [deps…]`
and `chip_dep_check <label>`, hashing file **content** with `sha256sum` and
comparing against a stored list.

Two dependency classes are now covered:

1. **The harness script itself**, plus `regress/run_lock.sh`. This closed the
   original race: a harness edited mid-run could report a false PASS, because
   bash reads a script *incrementally* and the verdict is decided by the text that
   moved.
2. **The harness's `MUTABLE` targets** — the exact RTL files it mutates. Added
   because on 2026-09-25 `mutate_eth_mac_tb.sh` was live on `rtl/pe_eth_mac.v`,
   the file was restored **from outside the harness** mid-run, and the guard could
   not see it. All sixteen harnesses already publish a `MUTABLE` line, so the
   dependency list was written down and simply not being *read* as one.

Wired in `regress/run_all.sh`'s `run_mutation_suite`, which brackets each suite's
invocation with stamp and check and returns **4** (INCONCLUSIVE) on any change.
`regress/verify_merge.sh` turns the `CHIP-DEP-CHANGED` marker into INCONCLUSIVE
**even when the run exited 0**, because an exit 0 is what a false pass looks like
from outside.

**The boundary, stated plainly.** A start-stamp / end-verify on content cannot
see an actor who **restores** a target to its starting content mid-run: that
leaves the file exactly as the guard expects to find it. That *is* the real
2026-09-25 incident. So today the guard catches an external edit that is not put
back, and any failure to restore — **not** the mid-run restore.

## 2. The self-test, and what its cases mean

`regress/test_dep_guard.sh` is **10/10** and runs inside the full suite. It takes
no run lock and touches nothing in the repo, so it is safe beside a real run.

Cases 1–7 are the original script/dependency cases. Cases 8–10 are the DUT ones:

* **8 — a CLEAN run with a mutating target still reports its verdict.** The one
  that matters most: if it failed, the dependency would be firing on the
  project's own normal behaviour, since all sixteen harnesses mutate and restore.
* **9 — a mid-run change to a MUTABLE target is INCONCLUSIVE, never a verdict.**
* **10 — the limitation, pinned as a case.** A mid-run restore-to-original is
  invisible to a content check. **This case must pass today, and that is the
  point**: it puts the boundary in the test suite itself, so cases 8 and 9 cannot
  later be read as coverage of the whole class. Building the sampler should
  **flip this case** — the visible proof the class closed.

Two fixture rules learned the hard way, both worth keeping:

* Use the existing inline `bash -c` + positional-args shape. A generated nested
  script with its own heredoc broke twice: the inner `EOF` terminated the outer
  heredoc (leaving the file unparseable, and running a `chmod` against `/`), and
  after that was fixed the body's target path was expanded by the *parent* when
  the unquoted heredoc was written. The fixture was wrong; the guard was not.
* In this session the *method* was wrong more often than the documents were: a
  multi-tree `git ls-tree` reporting zero files, a `git show` failing for a file
  read successfully another way, an unspaced digit grep reporting a thin-spaced
  number as deleted. **A number search is not a number's identity** — search a
  digit *group* with optional internal spaces.

## 3. THE SAMPLER — the design, for the next session

**Goal: an external mid-run RESTORE also trips INCONCLUSIVE.** Scoped to the
mutation targets.

### Entry points

```sh
chip_dep_sample_start <label> <target>...   # background poller over the targets
chip_dep_sample_stop  <label>              # returns non-zero if it saw interference
```

* `sample_start` reads each target's current hash (the same one `chip_dep_stamp`
  just recorded), then launches a background subshell that polls each target
  every ~50 ms while a sentinel file `$CHIP_DEP_STAMP_DIR/$label.sampling`
  exists. It maintains a per-file `seen mutated` flag and writes a HIT file when a
  file goes **mutated → original while the run is live**.
* `sample_stop` removes the sentinel, waits for the poller, and returns non-zero
  if a HIT was recorded — printing the same `CHIP-DEP-CHANGED` marker so
  `verify_merge.sh` needs no new knowledge.

### The discriminator, and where a naive version lies

**"mutated → original" alone fires on every clean run**, because a harness's own
final restore is exactly that transition. So the signal only indicates
interference when the transition is followed by **further mutation**: the
harness's own restore is the last thing it does, whereas an external restore
leaves the harness running and it will mutate again.

**Stated edge case, not a hidden one:** a restore during a harness's *final*
mutant is still missed, because no further mutation follows. Alternative if that
matters — have the harness announce its own restore, which couples it to the guard
and is a bigger change than the sampler.

### Wiring

In `regress/run_all.sh`'s `run_mutation_suite`, bracket the invocation:
`chip_dep_sample_start "suite_$n" "${_mut_deps[@]}"` before `"$@"`, and after it
force the existing exit-4 path if `chip_dep_sample_stop` reports a hit. Keep the
content check too — the sampler subsumes the "changed and not restored" case but
the content check is what catches a *failed restore* after the harness exits.

### Self-test, required before it ships

Per the manager's ruling, three directions, all in
`regress/test_dep_guard.sh`, in the existing inline `bash -c` style:

1. an **external edit** trips it (case 9 must keep passing),
2. an **external restore** trips it — and case 10 **flips** from "pinned
   limitation" to "caught",
3. a **clean run does not** trip it (case 8 must keep passing).

A guard that is wired in but not self-tested is worse than one that does not
exist: it claims coverage it has not demonstrated. That is why this is written
down as a design rather than half-built.

## 4. Open items, in the order the manager set — as they stood, now CLOSED

> **Superseded by §8.** Of the four below, 1 and 2 are DONE, 4 was already closed,
> and 3 is `tools/fw/peasm.py:200` (`# clocks (1.22 us)`, the D3 conversion error)
> which is **fw-timing's file, still open, and deliberately not re-raised here** —
> it was routed and re-raising it is noise. Kept verbatim because the queue this
> session inherited is part of the record.

1. **Build the sampler** per §3, starting from the stated edge cases. Then the
   diag-bus prose remainder.
   **DONE, and not per §3** — §3 was disproved before it was built (§6) and the
   manager ruled option (a) instead. See §8. The diag-bus prose remainder is
   pass 11 and its addendum.
2. **The diag-bus prose remainder** — the 39-commit branch, read single-tree:
   figure sets and their pages first, prose pages after. Six measured act results
   were confirmed gone from both maps (option (a) landed) and the formal
   denominators were confirmed correct.
   **DONE** — `reviews/2026-09-26/DOCS-ACCURACY-REVIEW-PASS11.md`, re-measured
   against main at report time.
3. **`tools/fw/peasm.py:200`** carries `# clocks (1.22 us)` — the D3 conversion
   error, in the assembler, whose owner is not in the docs fleet. Flagged to the
   manager, still open.
4. **A negative control for `tools/diag/delay_lattice.py`** was requested; the
   manager confirmed it has one (`--selftest` planting real errors, which my
   earlier "no test" finding was wrong about). Closed.

## 5. The state of the tree, for the next session

Clean apart from gate artefacts. `check_r2_package`, `check_wiki_pages`,
`check_shell_syntax`, `check_harness_preflight`, `check_mutation_lists` and
`tools/diag/check_diagrams.sh` are all green; `dep_guard --self-test` is 10/10 and
`verify_merge.sh --self-test` is 27/27. **A mutation harness is frequently live in
the shared worktree** — always check `git status rtl/` and the process list
before touching `rtl/`, and commit with explicit pathspecs so a live mutant is
never swept into a commit.

---

## 6. §3 IS MEASURED WRONG — the disproof, with the numbers

Fresh session, 2026-09-26. §3 was not built, because building it would have
shipped a guard that fires on the project's own normal behaviour.

### 6.1 The premise is false, and it is false for all sixteen harnesses

§3 rests on: *"a harness's own final restore is the last thing it does,
whereas an external restore leaves the harness running and it will mutate
again."* The first clause is wrong. Every harness restores **per case, inside
its mutation loop**, and then immediately applies the next case's mutant:

* `mutate_i2c_tb.sh` — `run_case` ends `restore` (line 154) and is then called
  again for the next mutation, so `rtl/pe_soc.v` goes
  `M O M O M O …` with **O between every pair of mutants**.
* `mutate_serdes_tb.sh` — `check_mutation` ends `restore; verify_restore`
  (line 89) and is called 7 times.
* The same shape holds in all sixteen: the only `restore` call sites are inside
  the per-case function, plus one `restore_pristine` in the EXIT trap.

So the sequence §3 calls interference is **the normal shape of a clean run**.
Its "signal" is the dominant pattern, not the anomaly.

### 6.2 Measured, on the project's own suites

Content-class sequence of a real clean run (recorder at 2 ms, `O` = pristine,
`M` = not pristine):

| clean run | sequence | inter-case pristine windows | mutant windows |
|---|---|---|---|
| `mutate_serdes_tb.sh` / `pe_serdes.v` | `OMOMOMOMOMOMOMO` | 13–18 ms | 12–22 ms |
| `mutate_i2c_tb.sh` / `pe_soc.v` | `OMOMOMO` | **60–62 ms** | 976–6207 ms |
| `mutate_eth_tx_tb.sh` / `pe_eth_tx.v` | `OMOM…OMO` (17 windows) | 13–32 ms | 426–8491 ms |

Then §3's discriminator, verbatim, at §3's own ~50 ms interval:

* `mutate_i2c_tb.sh` — **HIT, about 120 times**, on a run whose own summary
  reads *"6 detected, 1 survived, 0 inconclusive / no unexplained survivors"*.
  Not a probability: the 60–62 ms windows are **longer than the 50 ms poll**, so
  the poller is guaranteed to sample twice inside one.
* `mutate_serdes_tb.sh` — HIT on one run, no hit on another, identical harness.
  With 13–18 ms windows against a 50 ms poll the verdict is decided by **sampling
  phase**, not by interference.

### 6.3 A measurement of my own that was VACUOUS, and how it was caught

The first probe run reported "no hit" on `mutate_i2c_tb.sh`, which contradicted
§6.2. The probe was wrong: its multi-file version reset the `seen`/`back` state
**inside the per-poll loop**, so it compared one sample against itself and could
never fire. Caught by distrusting a result that disagreed with a measurement
taken a minute earlier — the same "check the instrument" move that caught a
vacuous font test earlier in this project's history. The single-file probe keeps
state outside the poll loop and fires as §6.2 says. **A negative result from an
instrument that has never been seen to fire is not evidence.**

### 6.4 What shipping §3 would have cost

Every mutation suite returns exit 4; `verify_merge.sh` turns `CHIP-DEP-CHANGED`
into INCONCLUSIVE **even on exit 0**; so the merge gate is permanently
INCONCLUSIVE. That is worse than the gap it closes in a specific way: an
INCONCLUSIVE that always fires is one people learn to ignore, and this project's
whole premise is that a gate nobody believes is worse than no gate. The guard
would also have made its own case-8-style negative control fail — which is the
only reason the self-test exists.

### 6.5 The deeper reason it cannot be fixed by tuning

The harness's own restore and an external restore are **the same content
transition** — both write the pristine bytes the run started with. No amount of
hashing, polling or interval tuning separates them, because the information is
not in the file: it is in **who wrote it**. Sampling also cannot recover it,
because a clean run's own pristine windows are the same order of magnitude as
any poll interval you would choose. Detecting this needs either write
attribution (a kernel facility, not available here — `inotifywait` is ABSENT) or
the harness saying what it is about to do.

## 7. The two sound options considered — DECIDED, see §8

Neither is in the approved scope; both are small; the first is recommended.

**(a) Cooperation — one line per harness (recommended).** Every harness already
sources `dep_guard.sh` through `run_lock.sh`, so two functions are already in
scope inside all sixteen. Have the harness **declare** the state it is about to
establish (`chip_dep_expect_mutant` / `chip_dep_expect_pristine`, one line in
each `restore` and each mutation step), and have the poller flag a target whose
content **contradicts the current declaration**. A declaration is valid for a whole
*interval*, so a slow poller can only ever *miss* a transition, never invent one
— the failure direction that is safe. `regress/check_harness_preflight.sh`
already enforces a per-harness dep-guard requirement, so the new requirement
has an enforcement point and a self-test home. Cost: ~16 one-line edits plus
preflight, and the guard becomes coupled to the harnesses — which is a real
tradeoff, and the reason §3 called it "bigger".

**(b) Write attribution via a new Python helper.** `inotifywait` is absent, but
`ctypes` → `inotify_init1`/`inotify_add_watch` works (libc present), and an
event stream has no sampling aliasing at all: a clean run writes each target
strictly alternating `M O M O …`, so an external restore appears as a **second
pristine write with no mutant write between it**, which the project's own EXIT
trap (`restore_pristine` on every exit, `mutate_i2c_tb.sh:165-183`) cannot
mimic because nothing follows it. Correct, but a new tool, a new language in a
bash guard, and a second mechanism to keep alive.

**Not recommended, and why:** a duration heuristic ("a pristine window longer
than X means interference"). It is a per-suite fudge factor; wrong in the firing
direction it is §6.4, and wrong in the quiet direction it is merely the status
quo. Given that asymmetry, a threshold is not worth shipping without a ruling.

**Meanwhile the honest state is unchanged and still true:** the guard catches an
external edit that is not put back, and any failure to restore. It does not
catch a mid-run restore. Case 10 of `regress/test_dep_guard.sh` pins that as a
case, and the new case 11 records §6 as an executable disproof.

---

## 8. THE RULING, AND WHAT SHIPPED

This section exists because §§1–7 were written as an open design and stayed open
after the question was answered. A document that poses a question does not
update itself when somebody answers it, and the failure mode is quiet: the next
session reads "for a ruling", concludes nothing has been decided, and starts
work that is already landed.

### 8.1 The ruling

The manager took the disproof as this cycle's deliverable and ruled **option
(a), cooperation** — the declaration protocol. Option (b), write attribution via
a `ctypes` inotify helper, was not taken. A duration heuristic was explicitly
rejected, on the grounds already argued in §7: wrong in the quiet direction it is
merely the status quo, wrong in the firing direction it is the ~120-HIT disaster
of §6.4.

### 8.2 The mechanism that shipped

```sh
chip_dep_sample_start <label> <target>...   # watch the MUTABLE targets, in the background
chip_dep_expect pristine|mutated <file>...  # the HARNESS says what it just established
chip_dep_sample_stop <label>                # non-zero if a target contradicted a declaration
```

The poller never looks for a pattern. It compares what it sees against what the
harness **declared**, and a declaration is valid for an *interval*, so a slow
poller can only ever **miss** a transition — it can never invent one. A missed
detection is the status quo this file has always documented; an invented one is a
false INCONCLUSIVE on a clean run, which is the failure that got §3 thrown out.

A contradiction must hold for `CHIP_DEP_SAMPLE_PERSIST` (0.15 s) before it
counts, because every real mutation is applied by python's `write_text`, which
truncates and rewrites — the file is briefly neither the old content nor the new.
An external restore lasts 976–6207 ms (measured on `mutate_i2c_tb.sh`), two
orders of magnitude away.

Fail-closed throughout: a sampler that was never started, a poller that did not
run to completion, and any target the harness never declared all report
INCONCLUSIVE rather than "clean".

### 8.3 What was verified, and how

* **All sixteen harnesses** run clean under the sampler — no false positives.
* **The positive direction, on a real harness:** with a file copy standing in for
  a manager's restore of `rtl/pe_eth_tx.v` mid-run, `mutate_eth_tx_tb.sh`
  reports *"declared: mutated, observed: pristine, held for 0.165 s"*.
* `regress/test_dep_guard.sh` is **13/13**. The limitation case flipped from
  pinned to caught, and the negative control is a clean per-case run with
  deliberately adversarial 100 ms truncate windows that must produce **zero**
  false hits — the case §3's design failed.
* `regress/check_harness_preflight.sh` requires a harness with a non-empty
  `MUTABLE` to declare its baseline, with its own negative control proven.

Five placement errors were found **only** by running the real harnesses, never by
the self-test or by reading: `eth_soc` (whose `mutate()` takes anchor *strings*
and always writes `$RTL`, so `pe_eth_mac.v` is in `MUTABLE` but never written),
`spi` (a blanket declaration that landed inside `verify_restore()`'s loop),
`fwbus` (`$fw` is a stem), `i2c` (a fifth hand-rolled case outside `run_case`),
and `ctrl_r3` (a declaration placed after `return 0`, so dead code that never
ran). The through-line: **a declaration is a claim, and only a real run shows
whether a claim is true.**

### 8.4 The limit, stated rather than tuned away

**Detection requires the interference to persist at least 0.15 s.** A suite whose
cases are shorter than that is protected in the no-false-positive direction only.
Measured: `mutate_serdes_tb.sh` runs 7 cases in 0.8 s (~114 ms each), and an
induced restore there is **missed**; `mutate_eth_tx_tb.sh`, whose cases are
426–8491 ms, is **caught**.

That trade is deliberate and should not be quietly reversed. Lowering the window
to catch a 114 ms suite would put the false-positive class straight back, and a
false INCONCLUSIVE on a clean run trains people to ignore INCONCLUSIVE — the
outcome §6.4 exists to prevent. `CHIP_DEP_SAMPLE_PERSIST` is the single knob if
that is ever worth revisiting, and the decision belongs to whoever owns the
merge gate, not to the next person who trips over a missed detection.

### 8.5 State of the tree

Landed, not pending: the declaration protocol (`regress/dep_guard.sh`), the
self-test, the `run_mutation_suite` bracket, the preflight rule, and the
declarations in all sixteen harnesses. The self-expiring `<<wip>>` check on
`tb_pe_soc_sr04` is proven in **both** directions and the marking correctly
**stays** while that act is red; removing it belongs to the act's owner after
their branch merges green, not to this file.
