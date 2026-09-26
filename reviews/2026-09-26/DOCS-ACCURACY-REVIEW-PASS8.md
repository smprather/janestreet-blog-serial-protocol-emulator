# Docs accuracy review — pass 8 (2026-09-26)

Author: protocol-worker. Rolling pass. This one is mostly **three of my own
open items closed by re-checking, one of them a withdrawal of a pass-7 finding**,
plus the map-trigger sweep the manager's ruling armed.

## 1. F1 is FIXED, and fixed in the pattern I asked other figures for

`wiki/concepts/protocol-spi3-crc.md` now states **`resp = word[15:8] XOR 0x7E`** —
a single byte — and gives the reason it is a byte: the response register is 8-bit,
so `word[7:0] XOR 0x5A` is never computed. **The wrong rule is kept as the record
of the error**: the page still shows that `word XOR 0x7E5A` gives
`0x6F6E / 0x6C1F / 0x6D0C` and "is not what the wire" does. That is the same
"show the error, not only its absence" treatment diag-timing gave the D1/D2
derivations, and it is the right default: a reader who saw the old claim can see
exactly what it was and why it failed. On `main` (`75933fb`).

## 2. WITHDRAWN: the numbers gate DOES have a negative control

Pass 7 recorded that `tools/diag/delay_lattice.py` "carries no test for it". That
was **wrong**, and the error was mine: I searched for a separate test *file* with
a pattern that missed it. The self-test is a **mode of the gate itself** —
`--selftest` "plants real errors in a copy of the real files and demands that
[the gate catch them]" — and its own header records that it caught four bugs,
including one where the tool "stops being what does the work". The header also
carries a failure mode it defends against: passing a path literally named
`--selftest` and having the tool print "cannot…" instead of running.

So the fleet now has three gates with negative controls (wiki-pages: 13 cases;
numbers lattice: `--selftest` planting real errors; and the diagrams gate below),
and one open question about the third. **Withdrawn, with the reason, rather than
quietly dropped** — a finding retracted in silence is indistinguishable from one
that was never checked.

## 3. THE MAP TRIGGER FIRED — and the figures it names are there

Baseline recorded in pass 5 was `project-plan aa2554c` / `project-progress
42d4acc`. Both moved: `d435b68` "name the 29 sibling act figures in the maps,
and un-stale my own drift note", merged through the manager's `74d8708`.

The concern the trigger exists for — maps naming figures that do not exist — does
**not** materialise: `main` carries **34 `.puml` files** under `diagrams/`, the
per-act families among them (`proto-dht11{,-frame,-timing}`,
`proto-ds18b20{,-frame,-timing}`, `proto-fm-biphase{,-frame,-timing}`,
`proto-dmx512`, …). The maps' references resolve.

*(A caution about my own method, since it produced a false alarm first: a
multi-tree `git ls-tree -r --name-only A B C` returned zero figures for me, and
so did a `git show main:tb/…` that I had already read successfully by another
route. Listing the single tree on `main` directly is the method that worked. Two
of tonight's readings were wrong in the same way — a grep or a ref that looked
authoritative and was not.)*

## 4. A fourth gate exists: `tools/diag/check_diagrams.sh`

Not previously in this review. It checks three things about the figure set, and
each names the failure it exists for: **syntax** (every `.puml` parses under
`plantuml --check-syntax`, because a `.puml` with a syntax error *still renders*,
so a render gate alone cannot see it), **colocation** (a `.puml` with N blocks
must have exactly N `.png` and N `.svg`), and **prefix consistency** across a
per-act family (`proto-ws2812.puml` / `-frame` / `-timing`). It also carries a
note about a real hazard it has to defend against: restoring or checking out a
`.puml` updates its render but not its siblings.

## 5. NOT COMPLETED, and said so rather than papered over

* **The full map-trigger re-grep** (the C1 class: a figure restating a number the
  moved maps also state, re-verified against the RTL). I started it and stopped:
  two of the four checks in my batch returned results I could show were wrong,
  and publishing findings from a method I have just caught being wrong is
  precisely the failure this review exists to catch. The trigger has fired and the
  figures resolve; the restatement sweep is outstanding.
* **`check_diagrams.sh` itself** is described above from its header, not reviewed
  or run, and its own self-test status is unverified by me.
* The unreviewed remainder stands: diag-bus's 39 commits since pass 7, and the
  NEC-IR figure set with its deliberately-unsent frame (which I still need to
  confirm is LABELLED as illustrative rather than readable as a wire claim).
