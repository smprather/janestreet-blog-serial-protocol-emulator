# Docs accuracy review — pass 9 (2026-09-26)

Author: protocol-worker. The map-trigger sweep, run on the manager's instruction
with the single-tree method, plus the NEC-IR label question and the first part
of the diag-bus remainder.

## 1. THE METHOD, quoted so it can be judged

**Single tree, `main`, listed directly.** `git ls-tree -r --name-only main --
diagrams`, then `git show main:<path>` per file. No multi-tree `ls-tree` (which
silently returned zero figures for a set I had already reviewed file by file), no
worktree reads, no grep across refs. 34 `.puml` on `main` = 2 maps + 32 act
figures.

**The test applied:** a **measured** quantity (a timing, a rate, a clock count)
that appears in BOTH an act figure and a map. That is the C1 class — a figure
restating a number the map also states — read in the direction that matters once
the maps became the architecture authority.

**What this method does NOT cover, stated so nobody reads more into it than is
there:**
* it compares **number strings**, so it cannot tell which side sourced which. A
  shared number is a CANDIDATE, never a verdict, and every candidate below is
  triaged by hand against the RTL or the firmware;
* it **excludes opcodes and state encodings** on purpose — the maps legitimately
  index those, they are the architecture's own vocabulary, and a figure citing
  `0x21` is citing `pe_ctrl.v`, not the map;
* it covers **`main` only**. The three figure branches are reviewed through their
  merges; a figure that exists only on a branch is invisible to it;
* it says nothing about the **renders** (`.png`/`.svg`), which
  `tools/diag/check_diagrams.sh` owns;
* universal constants are excluded from the finding by triage, below.

## 2. WHAT THE TRIGGER FOUND — the C1 class, and it is in the MAPS

**32 figures, 21 distinct measured quantities in the maps, 12 figures sharing a
quantity with a map.** Triaged:

* **Coincidences of universal constants, not restatements** — the 1 µs
  `I2CTICK` period and the 260-clock / 4.3333 µs UART half-bit. Every act that
  uses or avoids that tick states it, and neither figure is sourcing the map.
* **A real finding, and it is the maps.** The maps restate **six
  protocol-specific MEASURED results** that belong to the act figures: sr04's
  5816 µs and 1160 µs, DMX's 12.38 µs mark and 88.06 µs break, and the
  freqmeter's 158 Hz and 10 kHz endpoints. Meanwhile the maps link only **three**
  figures by name — `proto-r2-read-path`, `proto-r3-debug-control`,
  `proto-spi-framing`, all from the diag-proto set. The 29 act figures are
  *named* in the maps, but the figures that own the measurements are not linked,
  and each measurement now exists in **two** places.

This is precisely the propagation hazard the D1/D2 and D3 corrections walked
into, one level up. When I corrected the servo derivations, the fix had to be
made in the figures *and* the companion page, because the page restated the
figure. Here the second copy is in the map: had the servo figures' numbers been
restated there, a figure correction would have left the map silently stale — and
the map is the thing a submission reader treats as authoritative.

The figures' own numbers are not in question; I verified DMX's 513 × 11 × 4.000 µs
and the sr04/freqmeter figures against their own testbenches in earlier passes.

**The remedy is a choice about the ruling's own asymmetry, so it is the manager's
to make, and I am not making it:** either the map **links** the act figure instead
of restating its measurement (which is what the ruling already says maps may do,
and would make a figure correction a one-place edit), or the map keeps the number
and the map-trigger is understood to verify **both copies in the same pass** —
which is what just happened, and it worked, but it depends on the reviewer
noticing rather than on a rule.

## 3. NEC-IR: the unsent frame IS labelled — no finding

`diagrams/proto-nec-ir-frame.puml` carries four labelling lines, and they are in
the figure that shows the frame: *"This act does not send it. The figure shows it
because 'how does a repeat code…'"*, and the two payload rows are marked **NOT
SENT** (grey) — the 32-bit address/command block and the 0x00/0xFF repeat. So a
reader cannot mistake it for a wire claim, which was the question.
`proto-nec-ir.puml` has no labelling lines, and does not need any: it does not
show the unsent frame. The labelling is in the right figure.

## 4. diag-bus remainder — partially covered, honestly bounded

`main` now carries the SPI3 rule fix, the diagrams gate and the merged figure
sets, so most of what pass 7 listed as unreviewed is reachable from `main` and was
covered by the sweep and the earlier per-set passes. **Not yet reviewed:** the
contents of the merged `docs/diag-bus` history commit-by-commit (39 commits), and
`check_diagrams.sh` run rather than read.
