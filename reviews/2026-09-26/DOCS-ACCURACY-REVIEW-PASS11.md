# Docs accuracy review, pass 11 — the diag-bus prose remainder

Date: 2026-09-26. Author: protocol-worker (harness & RTL hardening steward).
Scope: the prose the `docs/diag-bus` line added, read **single-tree** and
measured against **main at report time**, not against the branch. Order as
instructed: figure sets and their pages first, prose pages after.

The line's own prose, scoped by merge-base `c5b3fbf` → `6481fdb`:
`diagrams/TOOLCHAIN.md` (91 new lines), `diagrams/README.md`, `README.md`,
`HANDOFF.md`, `docs/demo-walkthrough.md`, `wiki/log.md`, and
`tools/diag/check_diagrams.sh` (+180).

## 1. What held, measured

Seven of the branch's load-bearing claims are **still true on main**:

1. **The pin matches this host on every line** — `plantuml 1.2026.8`,
   `graphviz 16.1.0`, `java 26.0.2`, `Noto Sans Mono`, `Noto Sans`, all five
   confirmed against `plantuml -version`, `dot -V`, `java -version`, `fc-match`.
2. **The pin's core property holds**: the committed `diagrams/project-plan.svg`
   is **byte-identical** to a fresh render of its source on this host. So the
   byte comparison really is authoritative here, which is the entire reason the
   file exists.
3. **The five dot-rendered figures are exactly those five** — `project-plan`,
   `project-progress`, `proto-r2-read-path`, `proto-r3-debug-control`,
   `proto-spi-framing` are the only `package`/`component` sources, and all five
   exist. The claim about which figures the layout engine drives is correct.
4. **A missing pin is a failure, not a skip** (`check_diagrams.sh:390`), as the
   file states — fail-closed, so the byte comparison is never silently dropped.
5. **A pin mismatch downgrades byte differences to INCONCLUSIVE** rather than to
   failures, which is the mechanism behind the file's warning that *a pin bump
   without a re-render turns the gate green*. The warning is not folklore; it
   follows from the code, and that is the non-obvious claim in the file.
6. **104 relative links across the five prose files, 0 dangling.** Worth stating
   as a result rather than an absence of work: a dangling pointer was a real
   finding on this branch earlier, so this is the re-check that says it is still
   clean.
7. **The smetana mechanism**: forcing PlantUML's own engine really does move the
   geometry — `project-plan.svg`'s `viewBox` goes `0 0 6155 5510` →
   `0 0 5931 5104`.

## 2. What did not hold — three findings, one species

Every defect found is the *same* defect: **a number that was true at one
revision and is not true now.** None of the prose is wrong about the design; it
is frozen at the moment it was written.

**F1 — "five of the twenty-two sources" (FIXED).** The denominator was exact
when written: 22 `.puml` sources at the merge-base `c5b3fbf` *and* at the branch
tip `6481fdb`. Main now carries **34**; twelve sources landed after the tip. So
the count described the branch, not the project — the lesson wiki-features
already recorded, recurring in a file that did not exist then. Fixed by
**removing the denominator** ("five of them") rather than restating it as 34: a
count that a later commit invalidates is not a fact, it is a subscription.

**F2 — the smetana byte figures (FIXED).** The file claimed `112,288 B →
106,411 B`. Measured today: `122,715 B → 116,223 B`. Both are stale, because
`project-plan.svg` itself was re-rendered since; the *mechanism* is unchanged
(F1's viewBox numbers). Two things were wrong with the sentence beyond the
numbers: it offered **byte sizes as the evidence for a claim about "coordinates
and `viewBox`"**, and byte size is neither of those things; and a byte count
taken from a figure is a property of *that revision of that figure*, so it
cannot be the test. Replaced with the `viewBox` values, which are the actual
claim, and said plainly that the byte sizes are a snapshot.

**F3 — README.md's figure table is behind, and nothing checks it (REPORTED, not
fixed).** The table lists 47 of the 54 PNG renders. Missing: **12 renders = four
whole act figure sets** — `proto-fm-biphase`, `proto-freqmeter`, `proto-nec-ir`,
`proto-sr04`, each with its `-frame` and `-timing` siblings. All four acts *do*
have concept pages (`wiki/concepts/protocol-*.md`, all present), so only the
README index is behind, not the documentation layer.

The part that matters more than the omission: **nothing checks that table.**
`check_diagrams.sh` verifies every render against its source, and
`check_wiki_pages.sh` verifies page frontmatter and links — but the README figure
index is a third hand-maintained list, asserted by nothing, and it has already
drifted. That is the species this project keeps paying for, and the one
delay_lattice's own coverage check exists to catch ("a second hand-maintained
list in the same file is a second thing that can drift, which is the failure the
coverage check exists because I already made it once").

I did **not** add the 12 rows. Whether that table is meant to be exhaustive or
curated is the owner's call, and picking one silently would be editing a
judgement rather than a fact. Recommendation to the owner: if it is meant to be
exhaustive, add the rows *and* assert the table against the filesystem both ways,
in the same commit — otherwise soften the sentence that implies completeness.

## 3. Two method notes, because both nearly produced a false finding

- My first count said **"61 renders on disk are not listed"**, which reads as an
  alarming omission. It was an artifact of comparing the wrong populations: 54 of
  those 61 are the **SVG twins** of listed PNGs, because the table links PNG
  (42) plus 5 SVG. The real figure is **12 PNG across 12 sources across 4 act
  sets**. A big scary number is often a measurement of the wrong set, and the
  fix is to separate the populations before reporting either.
- Everything here was measured on **main**, not on the branch. All three findings
  are invisible from the branch: on `6481fdb` the prose is *correct*. A reviewer
  reading the branch would have found nothing, which is the cleanest possible
  statement of why the reading has to be single-tree at report time.

## 4. Lesson

The prose did not rot; it was **frozen**, and it froze silently, which is the
part worth keeping. A prose claim with no gate behind it does not decay
gradually — it is true at the moment of writing and wrong at the next revision
that touches the thing it counts, with nothing in between to say so. Two cheap
guards, both now applied to the file I corrected: **do not write a denominator a
later commit can invalidate**, and **do not offer a byte count as evidence for a
geometric claim**. The mechanism claims — which is most of what this branch is
actually for — all held, and they held because they are claims about *how* the
toolchain behaves rather than about *what the tree currently contains*.

Cross-reference: the sampler disproof in
`DEP-GUARD-SAMPLER-DESIGN.md` §6 is the same lesson wearing a different hat, and
it is the reason a review pass that only reads prose is not enough here.
