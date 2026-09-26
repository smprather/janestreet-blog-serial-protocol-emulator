# Docs accuracy review — pass 10 (2026-09-26)

Author: protocol-worker. The diag-bus remainder, single-tree method, and the
formal-campaign denominators that pass 7 left open. Two results: one **closed
with evidence**, one **now a defect rather than a candidate**.

## 1. The formal denominators: CORRECT, and pass 7's open item is closed

Pass 7 recorded the denominators as unverified. They arrived inside `diag-bus` by
**merge** rather than by a doc commit, which is exactly the case where a claim
changes carrier unnoticed — so I checked them against the artifacts rather than
re-reporting the note.

| `wiki/concepts/formal-verification.md` claims | `formal/results/*` says | |
| --- | --- | --- |
| **5 modules**: `pe_pinmux`, `pe_eth_tx`, `pe_ctrl`, `pe_soc`, `pe_cpu` | the ten targets name exactly those five subjects | ✓ |
| **10** gate target rows: 8 PROVED, 1 REACHABLE, 1 VACUOUS | 8 / 1 / 1, ten rows | ✓ |
| of those, **6 `bmc`, 4 `induct`** | 6 bmc, 4 induct | ✓ |
| **14 mutants, all CAUGHT** | 9 `CAUGHT-no-closure` + 5 `CAUGHT-witness` = 14 | ✓ |
| **11 targets** = the ten plus the SMT unlock | ten `run_target` entries + `formal/smt_induct.sh` | ✓ |

**The best thing on that page is not a number.** It states that the maps print
"10 properties / 5 modules / 14 mutants" while a dispatch may call the toolchain
total "11 targets", and says plainly that *both are right and neither replaces
the other*. A denominator that legitimately appears in two forms is usually
where an F1-class drift starts; naming the ambiguity in the artefact that
contains it is the fix, and this page does it.

**Closed: the formal denominators are accurate as written.**

## 2. The sharpened trigger's finding, now a DEFECT: six measurements still live in two places

Re-running the overlap test under the sharpened semantics (a measured number in
both a figure and a map is a **restatement**, not a candidate) against `main`:

```
  5816      in maps: 1        12.38   in maps: 1
  1160      in maps: 1        88.06   in maps: 1
  158 Hz    in maps: 1        10 kHz  in maps: 1
```

All six are still present in the maps. Under option (a) each of them is the
**figure's** claim and the map should link the figure rather than keep a copy, so
each is a defect with a named owner and a named remedy — the map edit is
diag-proto's, and this is the measurement that says whether it has landed. It has
not.

This is the same six pass 9 found, and the only thing that has changed is its
status: **from a candidate I triaged by hand to a defect with a fix.** That is
the ruling working — the ambiguity is gone, and what remains is a to-do with an
owner.

## 3. Method, and what it does not cover

Single tree, `main`, listed directly; no multi-tree `ls-tree`, no worktree reads.
For §1 the ground truth is the artifacts on `main`; for §2 it is a string-overlap
test whose result is a *pointer* to the defect, not a judgement about it.

Not covered, and not claimed: the merged `docs/diag-bus` history read commit by
commit; the prose wiki pages as opposed to the figure pages (the figure sets and
their companion pages are what §1 and §2 cover, plus the earlier per-set
passes); and the diagrams gate's internals, which I ran rather than read.
