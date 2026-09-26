# The harness-edit pre-flight: where it stands, and the sampler design

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

## 4. Open items, in the order the manager set

1. **Build the sampler** per §3, starting from the stated edge cases. Then the
   diag-bus prose remainder.
2. **The diag-bus prose remainder** — the 39-commit branch, read single-tree:
   figure sets and their pages first, prose pages after. Six measured act results
   were confirmed gone from both maps (option (a) landed) and the formal
   denominators were confirmed correct.
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
