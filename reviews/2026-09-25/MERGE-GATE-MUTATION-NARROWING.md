# The merge gate narrows the mutation suites too — MAPPED, not skipped

Date: 2026-09-25. Author: protocol-worker. Implements the manager's ruling
(2026-09-25, Q2): *a mutation suite runs in a narrowed gate **iff** one of its
MUTABLE targets intersects the merge-mapped changed set; anything unmappable
runs **all** mutation suites; and the gate output must **print** which suites ran
and which were skipped-by-mapping **with the reason**, so GREEN never claims
more than it ran.* The full unfiltered `run_all.sh` — the master/nightly gate —
is untouched: the narrowing exists only inside `regress/verify_merge.sh`.

**Nothing here has been run end-to-end, on purpose.** The manager was waiting on
the worktree's single-run lock to gate a merge, so no gate run was started; §6
says exactly what is and is not verified.

---

## 1. The ruling's premise was true for 7 of 16 harnesses, so it needed normalising

`MUTABLE="..."` already existed in `mutate_ctrl_r3_tb`, `mutate_eth_soc_tb`,
`mutate_eth_tx_loop_tb`, `mutate_fbuf_tb`, `mutate_i2c_tb`, `mutate_spi_tb` and
one more — a real convention with real users, documented in `mutate_eth_soc_tb`
("file must be in MUTABLE"). But the other shapes were `FILES=(...)`
(`mutate_codec_tb`) and bare `RTL=`/`WRTL=` scalars
(`mutate_ctrl_tb`, `mutate_eth_mac_tb`, `mutate_eth_tx_tb`, `mutate_serdes_tb`,
`mutate_soc_serdes_tb`), and four published nothing at all. **A reader could not
tell from `mutate_spi_tb.sh` what it mutates**, which is worth fixing on its own
terms. All 16 now declare `MUTABLE`, derived from evidence, not recollection:

| harness | MUTABLE | evidence |
| --- | --- | --- |
| `mutate_codec_tb` | 4 rtl | the `FILES=(...)` array it snapshots and restores |
| `mutate_ctrl_tb` | `pe_ctrl.v`, `tt_um_protocol_emulator.v` | `RTL=`, `WRTL=`, each backed up and restored |
| `mutate_eth_mac_tb` / `eth_tx_tb` / `serdes_tb` | one rtl each | `RTL=` (`pe_crc` in `eth_tx_tb` appears only in a compile list) |
| `mutate_soc_serdes_tb` | `pe_soc.v` | `RTL=` |
| `mutate_i2c_xfer_tb` | `i2c_xfer.pe/.hex` | `PE=`, `HEX=` |
| `mutate_fwbus_tb` | 3 firmware × `.pe/.hex` | the `FWS=` list it copies, mutates and cmp-restores |
| `mutate_timing_tb` | 7 firmware × `.pe/.hex` | the `for f in …` list it snapshots into `$SNAP` |
| `mutate_macro_flow_config` | **empty** | writes only under `$TMP`; mutates nothing in the repo |

The declarations are pure additions: the seven that already used `MUTABLE` were
left alone, and the nine new ones are inert string assignments.

**An empty `MUTABLE` and a missing one are opposites, and the distinction is
load-bearing.** Empty means "this suite mutates nothing in the repo, so no
merge can affect it" → it is never narrowed away. Missing means "its scope is
unknown" → the gate escalates and runs everything. Without the distinction the
fail-safe would have to be all-or-nothing.

## 2. The drift gate — and two live bugs it found on its first run

A list that *misses* a file its harness writes is the most dangerous omission in
this repository: the gate would skip the suite guarding exactly the file the
merge changed. So `regress/check_mutation_lists.sh` proves each list covers every
repo path the harness writes, and it **runs inside the full gate** (next to
`param_guards.sh`), because a list is only trustworthy while something keeps
proving it.

On its first run it failed three harnesses, and **two were real gaps in
already-published lists**:

* `mutate_i2c_tb` declared `firmware/i2c_pins.pe` but **not** `i2c_pins.hex` —
  which it writes twice (`peasm.py … -o firmware/i2c_pins.hex`) and restores,
  and which it also names as `IMAGE=`.
* `mutate_spi_tb` had the same omission for `firmware/spi_xfer.hex`.
* (`mutate_i2c_tb` additionally writes `firmware/uart_echo.hex`.)

**A merge touching `firmware/spi_xfer.hex` would have skipped the SPI mutation
suite** — and the SPI suite is the one that proves the TB catches a wrong bit
order. That is the exact failure the ruling exists to prevent, present in the
tree before this work started.

The third failure was mine, in the checker: it excluded `SRCS=`/`WTB_SRCS=` from
the write scan but not `SOC_SRCS=`/`TOP_SRCS=`, so it demanded thirteen
compile-list files be declared mutable. The exclusion is now a suffix (`*_SRCS`),
and the excluded set is **printed** on every run — an exclusion nobody can see is
an exclusion nobody can review.

## 3. What runs, and what is printed

`map_mutations` intersects each suite's `MUTABLE` with the same changed set the
cases were mapped from (merged-in ∪ behind-while-away), and the gate prints
every suite with a verdict and a reason. Live output on the manager's fw-repair
merge (`b252f0c`, real work, not a fixture):

```text
--- mutation suites (2 run, 14 skipped by mapping, 16 total) ---
  SKIP  mutate_codec_tb            no MUTABLE target among the changed files
  …
  RUN   mutate_macro_flow_config   MUTABLE is empty: mutates nothing in the repo, never narrowed away
  RUN   mutate_timing_tb           MUTABLE intersects the changed set (firmware/freqmeter.pe)
  -> FULL SUITE: formal/results/summary.txt (a change outside rtl/, tb/ and firmware/assembler)
```text

(The escalation is the *case* mapping's, not the mutation one: that merge also
touched `regress/` and `tools/fw/peasm.py`, which are global. Both narrowing
mechanisms are independent and both are printed.)

## 4. The three properties that keep it honest — all escalate to MORE

1. **A harness with no `MUTABLE` line is unmappable** → run all 16.
2. **An empty selection is refused**, symmetrically with an empty *case*
   selection: an empty selection is indistinguishable from a mapper that stopped
   working, so it escalates rather than reporting a green from zero mutation
   coverage. (Ruling's explicit requirement; self-tested.)
3. **The run is checked against the mapping.** `run_all.sh` prints
   `mutation suites: N ran, M SKIPPED by mapping`, the gate compares `N` to what
   it chose, and a mismatch is exit 3 (GATE ERROR) — a `MUTATE_ONLY` that
   silently matched nothing would otherwise be a green with no mutation coverage
   at all. GREEN also reports the mutation count in its own final line, so the
   log alone says what it covered.

`MUTATE_ONLY` travels as an **environment variable**, not an argument: every
ordinary `./regress/run_all.sh` in this repository, and every human habit, is
completely unaffected. `run_all.sh` also refuses a `MUTATE_ONLY` that matches no
suite, before running anything.

## 5. FINDING: editing a harness while it runs makes it report a FALSE failure

The measurement campaign that produced the cost table below ran
`mutate_timing_tb.sh` **while I was inserting the `MUTABLE` declaration into that
same file**. Bash reads a script incrementally, so the insertion shifted the
file under the running shell and the harness executed fragments of comment text
(`line 718: READ: command not found`, `unexpected EOF while looking for
matching '`). It reported **FAILED**.

* The harness is **intact**: `bash -n` clean, and the diff is +8 lines (the
  comment block and the declaration). Verified, not assumed.
* The number for that suite is **invalid** and is marked invalid wherever it is
  quoted. It needs re-measuring, which needs the run lock the manager was
  holding.
* **The hazard is general and nothing in the project prevents it.** The run lock
  stops harness-versus-harness and harness-versus-`run_all` concurrency; it does
  not stop a human or an agent editing a harness while that harness is
  executing. The symptom is a false *failure*, and the same race could in
  principle produce a false *pass*. A pre-flight "did any harness change since
  this run started?" check would close it; that is a follow-up, not something to
  bolt on unasked at the end of a ruling.

## 6. MEASURED cost of the 16 suites, sequential (2026-09-25)

| suite | s | | suite | s |
| --- | --- | --- | --- | --- |
| `mutate_eth_mac_tb` | 378 | | `mutate_eth_tx_tb` | 17 |
| `mutate_eth_tx_loop_tb` | 343 | | `mutate_ctrl_r3_tb` | 15 |
| `mutate_timing_tb` | **323 s (re-measured, VALID)** | | `mutate_i2c_tb` | 13 |
| `mutate_ctrl_tb` | 124 | | `mutate_spi_tb` | 3 |
| `mutate_i2c_xfer_tb` | 87 | | `mutate_codec_tb` | 1 |
| `mutate_eth_soc_tb` | 81 | | `mutate_soc_serdes_tb` | 1 |
| `mutate_fwbus_tb` | 65 | | `mutate_fbuf_tb`, `mutate_serdes_tb` | 0 |
| `mutate_macro_flow_config` | 5 | | **total** | **1456 s** |

The distribution is the useful part: **four suites cost 1076 s (73 %)** and four
cost under 5 s. So a narrowed gate's saving is dominated by *which* suites it
drops, not by how many — a merge in the codec or the frame buffer drops almost
everything, and a firmware merge keeps `mutate_timing_tb` (335 s) and
`mutate_fwbus_tb` (65 s) while dropping the other 14. Total is a lower bound
(parallel suites cost less concurrently; `run_all.sh` runs them in sequence).

**The invalid figure, now closed.** `mutate_timing_tb` first reported FAILED
because a `MUTABLE` insertion landed in that file while bash was executing it
(§5) — a read/write race, not a defect in the harness, which was intact
throughout. Re-measured afterwards with nothing editing it: **323 s, 58 cases,
58 detected, 0 survived, 0 harness errors, RESULT: PASS**, and the tree
`git status`-clean afterwards. The number that replaces it is not strictly
comparable with the other fifteen: the timing suite has since grown (it is 58
cases now, and fw-bus has been adding acts), so its cost is measured against the
suite as it stands today while the rest of the table is a snapshot from the
original campaign. **Total 1456 s.** Treat the table as a snapshot with a
per-row date, not as a current cost model.

**The hazard that voided it is now closed for the run_all path** —
`regress/dep_guard.sh` stamps the content of the scripts a run executes and
re-checks at exit, so the same race can no longer produce a verdict, in either
direction. See §8 for the one path it does not yet cover.

## 7. What is verified, and what is not

**Verified:** `--self-test` 27/27 (23 mapper rules including the mutation
mapping, the skip-print, the empty-selection refusal and the unmappable-harness
escalation, + 4 hand-off checks including `MUTATE_ONLY`), and the count of checks
it ran is itself asserted — with every counter disabled it reports `exercised 0
rule(s), expected 23` and exits 1. `check_mutation_lists.sh` clean on all 16,
with the excluded set printed. `bash -n` clean on `run_all.sh` and all 16
harnesses. The `MUTATE_ONLY` pre-flight selects 2 of 16, 1 of 16, and **refuses**
0 of 16 — tested in isolation, without the run lock.

**NOT verified** at the time of writing: no end-to-end gate run, because the
manager was holding the lock for the fw-repair merge. **Both were since run and
passed** — the narrowed gate is GREEN end-to-end (21 cases, 4 of 16 suites, with
the count cross-check satisfied against the real run), and the cross-check was
then made to disagree on purpose and correctly refused with exit 3. The same
session installed the harness-edit pre-flight and demonstrated it firing
(exit 4) on a mid-run edit to a harness that was executing at the time.

## 8. The one path the pre-flight does NOT yet cover: a STANDALONE suite run

Stated plainly because it is the same shape as the bug it fixes, and because
nobody should have to find it by reading the diff. `regress/dep_guard.sh` is
wired into `run_all.sh` — it stamps the whole `regress/` dependency set and
re-checks it in the exit trap, and `run_mutation_suite` stamps and checks each
suite **as run by the gate**. So every harness run *through* `run_all.sh` or
`verify_merge.sh` is covered.

A harness invoked directly — `regress/mutate_timing_tb.sh` on its own, which is
how anyone debugging one suite works, and **exactly how the original race
happened** (the cost campaign) — is not yet covered. It could not be covered from
`run_lock.sh`, which is where the rest of it lives, because every harness sets its
own `trap cleanup EXIT` *after* sourcing that file, and a second `trap … EXIT`
replaces the first. Closing it means a shape-aware edit to all sixteen harnesses
(stamp after the lock source, `exit 4` from `cleanup`), which changes sixteen exit
paths in the harnesses that guard the project's mutation evidence.

That is deliberately **not** done unasked in the same turn as the re-measurement:
the ordering that avoids recreating the race is the whole lesson of §5, and an
edit to sixteen harnesses is a bigger claim on the tree than it looks. The
honest statement of the residual risk: a standalone suite run can still report a
verdict from a script that moved underneath it, and the person most likely to do
that is the person debugging it.
