# Docs accuracy review — pass 6 (2026-09-26)

Author: protocol-worker. Rolling pass, reading remote tips only. Covers
`docs/diag-bus 6c89c07` — four new figure sets (SPI mode 3 + CRC, UART RTS/CTS,
MIDI 31.25k, DMX512-A) and five new `wiki/concepts/` pages.

**One finding of substance, and it is the class this project treats as worst: two
of the four sets assert MEASURED numbers whose measuring apparatus is not in the
tree the figures ship in.**

## 1. Finding — owner: pw-diag-bus (and a landing order, not a wording fix)

`diagrams/proto-midi.puml` and `diagrams/proto-dmx512.puml` assert measured
results: **31.9987 µs** (MIDI, line 269), **88.06 µs** break against a floor of
87.5, **12.38 µs** mark against a floor of 8.0, 512 slots, and the 3 999.8 ns cell
= 250 010 baud.

**None of that can be reproduced from `docs/diag-bus`, or from `main`.** The
apparatus is not there:

| | `main` | `docs/diag-bus` | `fw-bus-protocols` |
| --- | --- | --- | --- |
| `tb/tb_pe_soc_midi.v` | absent | **absent** | present |
| `tb/tb_pe_soc_dmx512.v` | absent | **absent** | present |
| `firmware/midi_xfer.pe` | absent | **absent** | present |
| `firmware/dmx512.pe` | absent | **absent** | present |
| `tb_pe_soc_spi3`, `tb_pe_soc_uart_flow` (+ firmware) | present | present | present |

`origin/fw-bus-protocols` (75b0e3e) holds the two acts and is **not merged into
`main`**. So the two figures that are checkable (SPI3, UART flow) are checkable,
and the two that quote the most precise numbers in the fleet are the two that
cannot be checked at all.

This is not a claim that the numbers are wrong. They are fw-bus's own
measurements and are probably right. It is that **a figure which states a
measurement without saying where the measurement lives is a claim wearing a
result's clothes** — the same failure as the day record's stale frequency-meter
row, one level down: a reader on this branch has no way to know the number came
from an unmerged branch, and when that branch lands the numbers may move, as the
timing suite's own figures did when fw-timing added acts.

Two fixes, and the second is better:

1. cite the provenance in the figure — which branch and commit the measurement
   came from, and that the act is not yet in `main`; or
2. **land fw-bus first, then rebase the figures.** A "measured" number whose TB is
   in the tree is worth ten that are merely true, because a reader can re-run it.
   Whichever is chosen, the honest interim is to mark the numbers as
   *measured on `fw-bus-protocols`, not reproducible at this ref* rather than to
   leave them unqualified.

Worth noting the merge gate agrees, mechanically: mapping a merge that touched
`diagrams/proto-midi.puml` selects **no testbench case at all**, because no case
compiles a figure. Diagrams are documentation, so that is correct behaviour — and
it is also why nothing in the project's own tooling would have caught this.

## 2. Verified — what could be checked

* **The DMX cell arithmetic is internally consistent.** Break 22 cells of LOW at
  4.0 µs = 88 µs against 88.06 measured; mark 3 cells of HIGH = 12 µs against
  12.38 measured; the datasheet floors quoted (87.5 and 8.0) bracket both
  correctly. The figure also states the START code is 0x00 and that the mark is
  released *once* rather than inside the loop, with the reason — an `OUT` inside
  the loop would make the mark depend on which iteration it was, which is the kind
  of detail a figure usually gets wrong.
* **Neither MIDI nor DMX repeats C3's error.** Neither figure makes a claim about
  "the tick" at all: they express cell times in microseconds and cell counts in
  firmware iterations, which is what the corrected maps say these acts do (they
  count instructions and program neither tick). So the trap C3 warned about —
  "DMX is the rate the tick cannot express AT ALL", true of the 260-clock
  half-bit and false of the 1 µs `I2CTICK` — has **not** been reintroduced here.

  The observation to offer, though, is that the absence of the wrong claim is not
  the presence of the right one. A reader comparing these figures with the maps
  gets a *stronger* statement from the map, which now names both ticks and cites
  `pe_soc.v:560`. A figure that says nothing about the tick is not wrong; it is
  just one step short of the corrected framing, and one careless sentence away
  from C3.

## 3. The wiki-pages gate's negative control: RUN, and it is not decoration

The manager asked for this to be executed rather than read, on the grounds that a
negative control which is decoration is the one thing this project has been
burned by. Run at `origin/docs/wiki-features a4e0b1a`, in a scratch worktree.

**Result: 13 cases, 13 passed, 0 failed, exit 0.**

The thirteen, and what each is for:

1. **unmodified copy is green (positive control)** — the case most gates omit,
   and the one that makes the other twelve mean anything. Without it, a gate
   that *always* failed would score 12 of 12 and look perfect.
2. a NEW off-taxonomy tag is red · 3. a NEW page with no frontmatter is red ·
   4. a NEW page with fewer than two outbound links is red · 5. a page dropped
   from `index.md` is red — the four new-violation shapes, one per rule that can
   fire on a new page.
6. a FIXED page whose pin **survives** is STALE-red · 7. the STALE report **names
   the page and the rule** · 8. a fixed page whose pin was **also removed** is
   green — the 6/7/8 triple is what makes the stale check more than "any change is
   red": it must fire on an outlived pin, say which, and then go quiet when the
   pin is retired.
9–13. **HARNESS ERROR, not a pass**, for: a missing baseline, a missing schema,
   no pages at all, a baseline line with no reason, and a renamed taxonomy
   heading. These are the fail-closed paths — a checker that cannot see the wiki,
   or cannot parse it, must never report a clean wiki.

**Are the cases real? Yes, and here is the check rather than the assurance.** Every
case asserts an exit code *and* a specific substring of the gate's output, so a
case cannot pass by failing for an unrelated reason. I confirmed the comparison
is real by breaking one expectation — asking the taxonomy case to look for a
string the gate can never print — and **exactly that case went red** (12 passed, 1
failed, exit 1); restoring it returned the run to 13/13. A harness that ignores its
expectations would have stayed green through both.

**And the gate is honest about the damage it was built to measure.** On the real
wiki at that ref it reports:

```
43 hand-written pages, 43 taxonomy tags read from wiki/SCHEMA.md
violations found: 12 across 8 page(s)
baseline: 12 pinned violation(s) (12 line(s) read)
check_wiki_pages: OK — 0 new, 0 stale; 12 known violation(s) pinned in the baseline
```

So the gate is green **on a wiki that has 12 known violations across 8 pages**,
and it says so in the same breath rather than implying a clean wiki. That is the
intended design — a pinned baseline with STALE detection so fixes cannot be
inherited silently — but it is worth stating plainly for anyone reading the
project's CI: **green here means "no new or stale violations", not "the wiki
conforms".** The output carries that distinction, so the gate is not misleading;
the number is just one a reader should know to look at.

**Closed: the wiki-pages gate's negative control is real, and it passes.**

## 4. Not reviewed, and stated rather than implied

* **The five new `wiki/concepts/` pages** — `protocol-midi.md`,
  `protocol-dmx512.md`, `protocol-spi3-crc.md`, `protocol-uart-flow.md`, and
  `protocol-i2c-adv.md` (which covers a figure set pass 3 already cleared). These
  are the highest-risk remaining item precisely because of the propagation
  pattern established in passes 4 and 5: D1/D2 and D3 each survived in a page
  after the figure was corrected. **If the pages restate the measured numbers,
  they restate them without the apparatus too.**
* **The SPI3/CRC-8 and UART RTS/CTS claim details.** Their apparatus is present,
  so they are checkable — I confirmed presence and the DMX arithmetic, and ran
  out of room before checking the CRC-8 parameters, the per-word CRC framing, the
  "both modes sample on the rising edge" claim, or the UART "the wire is idle for
  every instant CTS is low, sampled per clock" claim against their testbenches.
  Not reviewed.
