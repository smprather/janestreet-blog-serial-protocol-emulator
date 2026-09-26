# Docs accuracy review — pass 5 (2026-09-26)

Author: protocol-worker. Rolling pass, and the first one run against **remote
tips** rather than local refs after C1–C3 were re-verified.

**D1/D2 are closed, and closed better than the correction asked for. D3 is still
live and has propagated to a new companion page. The new wiki-pages gate is the
strongest piece of work in the fleet so far — with one claim still to check.**

## 1. Closed — D1 and D2, owner pw-diag-timing (`6ff9491`)

Verified at `origin/docs/diag-timing`: the corrected figures carry **625 clocks =
10.4167 µs** for the pulse step and **5 000 clocks = 83.3333 µs** for the gap
step, and the old 10.3 / 77.6 values are gone from every file.

The part worth reporting is *how* the page was fixed.
`wiki/concepts/protocol-servo.md:100-101` now carries a two-column table with the
**correct form and the wrong form side by side** — `10 + 1*(4*152+7)` = 625 clocks
against `4*152+11` = 619 clocks — and lines 129-133 add a full reproduction table
(`96·625 + 4` = 60 004 clocks = 1 000.07 µs for each of the five positions). The
one remaining `4 655` in that file is inside the correction note (line 107), not a
live claim. A reader can now see the error, not just its absence.

**Closed.**

## 2. Still open — D3, owner pw-diag-timing, and it has spread

`69 clocks = 1.22 µs` remains live in three places:

* `diagrams/proto-ds18b20.puml:47` and `:71` (the `PH0` and `DLY` blocks)
* **`wiki/concepts/protocol-ds18b20.md:158`** — the new companion page, which
  restates it as "a 69-clock (1.22 µs) step"

The value is 1.15 µs, and the same set's own `25.4 µs` derivation
(`(23-1)*69 + 4` = 1 520 clocks = 25.33 µs) is consistent only at 1.15.

The propagation is the finding, not the arithmetic: **a figure correction is not
done until the companion page is checked**, because the pages restate the
figures' numbers in prose. D1/D2 had exactly this shape — the figures were
corrected in pass 3 and the page still carried both wrong values until this pass
— and D3 is now repeating it one commit later. It is cheap to check: the page and
the figure are the same claim in two files.

## 3. The new wiki-pages gate (pw-wiki-features, `254beb7`) — assessed

This is the first piece of documentation infrastructure in the fleet, and it is
built the way this project has learned to build things. Assessed on what I read,
not yet executed:

* **The claim it replaces is honest.** `0c7068a` recorded that the five
  `wiki/SCHEMA.md` rules were *enforced by nothing*, and that every documentation
  gate in `run_all.sh` is a generated-page drift check, so a hand-written page
  could break all five unnoticed. That diagnosis is correct: the generated-page
  gates compare `wiki/reference/*` against `tools/gen/*` and never read a
  hand-written page.
* **The five rules are named, and the overlapping one is handled.** `no-type` is
  only checked on a page that *has* frontmatter, explicitly so that one defect is
  not reported twice and the baseline does not need two lines to pin one problem —
  which is the same care as `check_mutation_lists.sh`'s single-defect-per-line
  rule.
* **The baseline is a separate pinned file** (`wiki/.known-rule-violations.txt`),
  so pre-existing violations are enumerated rather than tolerated by a wildcard.
* **It has a real negative control** — `regress/test_check_wiki_pages.sh`, whose
  stated purpose is "prove check_wiki_pages.sh can FAIL", and whose two anchor
  cases are exactly the ones that matter: a **new** violation must be red, and a
  **pinned violation that has been FIXED** must also be red (STALE). The stale
  case is the one most gates omit, and a baseline that can silently outlive its
  defect is a checklist.
* It takes no run lock, mutates no RTL, and every case runs in a `mktemp -d`
  copy, so it is safe beside a real run.

**One claim not yet checked, and it is the load-bearing one:** that the negative
control has **13 cases** and that they pass. A negative control is the part of a
gate that can be decoration, and this project has the receipts — a self-test
that once passed while checking nothing. The gate's honesty is the claim; the
honest thing to do with it is run it, which I have not yet done.

## 4. Not reviewed

* **`docs/diag-bus aab4ae2`** — four new figure sets (SPI mode 3 + CRC, UART
  RTS/CTS, MIDI 31.25k, DMX512-A). This is the largest unreviewed block in the
  fleet and the next target: MIDI and DMX are exactly the acts C3 was about, so
  the maps' corrected framing should be checked for having reached the figures
  that make those claims.
* **Not executed:** `regress/check_wiki_pages.sh` and its negative control, as
  above. Assessed by reading, and labelled as such.
