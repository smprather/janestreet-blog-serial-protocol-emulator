# Docs accuracy review, pass 12 — rolling pass on main, at report time

Date: 2026-09-26. Author: protocol-worker (harness & RTL hardening steward).
Single-tree, **main at report time**, not a branch. Scope chosen by what moved
since pass 11: the README gallery was regenerated exhaustively (my pass-11 F3),
the wiki-features link gate landed (`dc0e5a6`), diag-timing's fm-biphase date
bump landed, and the cooperation protocol landed.

**sr04 is excluded from every claim here.** fw-timing's act is on its branch
(`c790945`) and my three sr04 findings are routed to them, so any sr04 reading
would be mid-flight and is labelled as such rather than asserted.

## 1. Pass 11's F3 is closed — verified BOTH ways

Pass 11 reported the README figure table listing 47 of 54 PNGs, with 12 renders
(four whole act sets) missing and **nothing checking the table**. The manager
regenerated it exhaustively. Re-measured at report time:

| check | result |
|---|---|
| links in README | 59 |
| **broken** links (listed, not on disk) | **0** |
| `.puml` sources | 34 |
| sources with **no** listed render | **0** (was 12) |
| PNGs on disk / listed | 54 / 54, **0** unlisted (was 12) |

Both directions now clean, which is the form that matters: a list checked one way
only is consistent with a list nobody checks.

## 2. The formal denominators — re-derived from the FILES, and all three hold

`wiki/concepts/formal-verification.md:37,39,41` states *10 gate target rows: 8
PROVED, 1 REACHABLE, 1 VACUOUS (6 bmc, 4 induct)*, *14 mutants, all CAUGHT (4
bmc, 10 induct)*, and the maps' *"10 properties / 5 modules / 14 mutants"*.
Re-derived from each page's own cited source, never from the page:

| claim | source | measured | verdict |
|---|---|---|---|
| 10 gate rows | `formal/results/summary.txt` | 10 data rows | holds |
| 8 PROVED / 1 REACHABLE / 1 VACUOUS | same | 8 / 1 / 1 | holds |
| 6 bmc / 4 induct (gate rows) | same, `shape` column | bmc=6 induct=4 | holds |
| 5 modules | `formal/<mod>/` dirs | 5 | holds |
| 14 mutants | `formal/results/mutants.txt` | 14 data rows | holds |
| 4 bmc / 10 induct (mutants) | same, `shape` column | bmc=4 induct=10 | holds |

## 3. Two column mis-reads, and the one that should worry a reviewer most

Both of my denominators checks were wrong at least once before they were right,
and the header is what saved me: `summary.txt` is `name|result|depth|shape|…`
and `mutants.txt` is `mutant|shape|result`.

* I read **column 3 of `summary.txt` as the engine**. It is `depth`. My output
  was `1=4 16=6` — and, read as counts, that is **4 and 6, which is the 4
  induct / 6 bmc the page claims.**
* I then read **column 2 of `mutants.txt` as the result**. It is `shape`, so my
  "all CAUGHT" histogram printed `bmc=4 induct=10`; an exact match on `$3=="CAUGHT"`
  returned **0 of 14**, which read as a refutation and was not one.

The generalisable point, and it is the reason this pass is worth more than its
findings: **a mis-parse that DISAGREES with a claim is harmless, because it
sends you back to the file. A mis-parse that AGREES stops you looking.** My
depth/shape error produced exactly the claimed numbers and I nearly recorded
"CONFIRMED" on the strength of a column that was never about engines. The
defence is dull and non-negotiable: read the header row before believing any
column, and treat agreement as a reason to check harder rather than as a result.

## 4. One refinement, not an error: "all CAUGHT" loses a distinction

All 14 mutants are caught, so the claim holds — but the file splits it:
**`CAUGHT-no-closure` = 9, `CAUGHT-witness` = 5**. Those are not the same
assertion: a witness is a concrete counterexample, a no-closure result is the
absence of one. "fourteen injected defects, all CAUGHT" is true and slightly
overstates the uniformity, because a reader will take "caught" to mean the
stronger kind uniformly. Cheap to state precisely, and it belongs to the page's
owner.

## 5. Debris in the results directory: 17 logs for 14 tracked mutants

`formal/results/` holds **17** `mutant_*.log` files while `mutants.txt` tracks
**14**. The three orphans are real files, not stubs: `eth_tx_len_window`
(88 KB), `pe_ctrl_bp_set_no_range` (192 KB), `pe_soc_owner_guard_removed`
(823 KB), and none has a row in `mutants.txt`. The page's denominator is
sourced from `mutants.txt` and is therefore **correct** — but anyone counting
the directory gets 17. This is the same species as the things this project keeps
naming: a marker that outlived the thing it marked. Whether they are stale or
awaiting tracking is the formal owner's call, not mine to delete.

## 6. Gates at report time

Numbers gate **PASS** (32 files, 20 lattice entries, 48 conversions, exit 0).
Wiki pages **0 new / 0 stale / 0 pinned**. Diagram renders OK. `rtl/` and
`firmware/` clean.

## 7. Lesson

Pass 11's finding was that prose does not rot, it *freezes*. This pass adds the
other half: a **denominator** does not rot either, but it can be *confirmed by
accident* — by a check that reads the wrong column and happens to produce the
right numbers. Every claim in §2 holds, and three of them nearly did not get
checked at all.

---

## 8. Addendum — the map-trigger fire loop, on the two routed sr04 items

Re-sequenced as read-only (no run lock needed). The trigger: a measurement moves,
so find every surface that RESTATES it. Searched the two maps, the concept page
and all three `proto-sr04` figures, with **digit-group-tolerant** patterns
(`1[\s]?160`, so a thin-spaced `1 160` is not read as a deletion — the mistake
that nearly produced a false alarm earlier tonight).

### 8.1 The documented failure mode is STALE — this is the real finding

What the page and all three figures assert, as recorded evidence:

> `measurement 1: echo 5816 us -> firmware 1160 us, answer X mm`
> `| echo 2 | 5 816 µs | 1 160 µs | FAIL, never measured |`
> `FAIL the second measurement never ran` … `FAIL, X is an unwritten byte`

What main's testbench does **today**, measured:

> `run 1: echo 5816 us -> firmware 5816 us, answer 991 mm (expected 999 mm)`

So the firmware has been fixed since that evidence was recorded: it now returns
5816 µs, where the docs say it still returns 1160 µs and never completes. The
answer is no longer `X` (an unwritten byte) but a real number, `991`. **Every
surface still narrates the old symptom** — the concept page and all three
figures. This is not a reworded defect; it is recorded output that no longer
describes the tree, and the `X is an unwritten byte` line in particular now
points a reader at a cause that has been fixed.

### 8.2 The `11/64` "exactness" claim is replicated ~8 times, and I OVERSTATED it

Routing note, and a correction to what I told the manager earlier. I reported
the TB's *"us*11/64 is exact and this is an equality"* as **false**. Having read
every restatement, the fairer statement is that it is **ambiguous in a way that
misleads**, and the blast radius is much larger than one sentence:

| surface | restatement |
|---|---|
| `protocol-sr04.md:99,115,123` | `199.375 → 199 mm`; "the testbench asserts this"; "an equality" |
| `proto-sr04.puml:12` | "us\*11/64 is an EQUALITY here, and it holds exactly" |
| `proto-sr04-frame.puml:45,121,129` | "mm = us \* 11/64 **EXACT**"; "the conversion is exact" |
| `proto-sr04-timing.puml:92,94` | "mm = us \* 11/64, exactly" |

The claim is **defensible on one reading and false on the other**. With
`us = 64q + r`, the integer result *is* exactly `11q + floor(11r/64)` — no
rounding error at all. But the real products are `199.375` and `999.625`, so a
reader who takes "exact" to mean "the product is a whole number" is misled, and
the page half-disclaims itself by printing `199.375` three lines from the word
"equality". So: not a falsehood to be deleted, a claim that must say **which**
exactness it means. That correction is more expensive than I implied, because it
touches four documents and re-rendering three figures on the pinned toolchain.

### 8.3 The 357-vs-1024 cause is documented NOWHERE

`1024`, `357`, `1 KiB` and `4 KiB`: **zero hits** across both maps, the page and
the figures. The docs narrate the shortfall's *symptom* ("X is an unwritten
byte") without ever stating the cause — firmware image 357 words against a
`[0:1023]` request. A reader cannot act on a cause that is not written down, and
when the symptom changed to `991` (§8.1) they had nothing to connect it to.

### 8.4 What the trigger found clean

**`991` appears nowhere** — no map, page or figure restates the wrong answer the
firmware now returns, which is correct while the act is red: the documentation
records `X`, not a wrong measurement. And the digit-group tolerance earned its
keep: the figures write `1 160` and `5 816` with thin spaces throughout, so a
literal search would have reported these numbers as *absent*.
