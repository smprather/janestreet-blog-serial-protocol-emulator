# Diagram toolchain pin

**Why this file exists.** `tools/diag/check_diagrams.sh` proves that every
rendered figure is byte-identical to a fresh render of its `.puml`. That is the
strongest staleness check available, and it is only meaningful **on a host whose
renderer produces the same bytes as the host that made the committed renders.**

Nothing pinned that. The versions below were recorded in prose in `wiki/log.md`
and `reviews/`, but nothing *checked* them, so a contributor on a host with a
different PlantUML, a different Graphviz, or a different JDK would get a red
gate on figures they had never touched — **a red that no diagram change can
clear.** That is worse than no gate: it trains people to ignore the gate, and it
is fixed by re-rendering, which destroys the very staleness the gate exists to
catch. The first version of this gate shipped exactly that failure mode and was
reported by a sibling worker.

## The pin

Machine-readable, one `key = value` per line, read by the gate:

```
plantuml    = 1.2026.8
graphviz    = 16.1.0
java        = 26.0.2
monospace   = Noto Sans Mono
sans-serif  = Noto Sans
```

`plantuml` is the version only (`1.2026.8`), not the build stamp; the stamp
changes between builds of the same release and pinning it would make the gate
red for a rebuild that changes no output.

## What is actually sensitive, measured rather than assumed

The obvious suspect is fonts, and on this project it is **not** the driver:

- PlantUML emits `font-family="monospace"` and `font-family="sans-serif"` —
  **generic** family references, so the *viewer's* fontconfig picks the glyphs at
  display time and the committed file is unaffected by which font is installed.
- Substituting the resolved monospace font (Adwaita Mono, confirmed with
  `fc-match`) leaves `project-plan.svg` **byte-identical**.

What does move the bytes is the **layout engine**:

- `dot` produces the geometry for every `package`/`component` figure — five of
  them: `project-plan`, `project-progress`, `proto-r2-read-path`,
  `proto-r3-debug-control`, `proto-spi-framing`. (Named rather than counted: an
  earlier version of this line said "five of the twenty-two sources", and the
  denominator was a snapshot of one revision — main carried 34 sources a few
  commits later, so the count described the BRANCH, not the project.)
- Forcing PlantUML's own engine (`-Playout=smetana`) changes
  `project-plan.svg`'s geometry: its `viewBox` goes `0 0 6155 5510` →
  `0 0 5931 5104` and the file shrinks from 122,715 B to 116,223 B. The
  *geometry* is the claim; the byte sizes are one figure's snapshot of it and
  will move whenever that figure is edited, so do not treat them as the test.
- Among the dot-rendered figures the **largest** are the most sensitive, because
  complex layouts have the most coordinates to move. That is why a font/dot
  mismatch shows up as "the two big maps failed and the thirty small figures
  passed" rather than as a uniform failure.

The font lines in the pin are kept anyway. They cost nothing, they document what
the renders were made against, and they become load-bearing the moment a
PlantUML release bakes real font names or metrics into the output instead of
generic references.

## What the gate does with this

- **Pin matches every line** → the byte comparison is authoritative, and a
  mismatch is a real stale or hand-edited render. This is the property that makes
  the gate worth having, and a one-byte edit is still a hard failure.
- **Any line differs** → the gate reports a **TOOLCHAIN MISMATCH** naming the
  component and both versions, and treats byte-differences as *inconclusive*
  rather than failures. The environment-independent checks — does the source
  parse, is every block's render present in both formats, is any render
  unclaimed, is the aspect sane — still run and still fail, because none of them
  depends on which renderer produced the bytes.

So a red from this gate always has an action attached: fix the figure, or fix
the toolchain. There is no third possibility where the gate is red and neither
is possible.

## Changing the pin

Change it **in the same commit that re-renders every figure**, and say why in the
commit message. A pin bump without a re-render makes the gate green while the
committed renders still came from the old toolchain — which is precisely the
staleness the gate exists to catch, hidden behind a version check.

To re-render, use the commands in [`README.md`](README.md).

## If you are on a different host

Either install the pinned versions, or re-render the figures on your host and
propose the pin bump together with the re-render. What you must not do is commit
a partial re-render: mixing renders from two toolchains leaves the corpus in a
state where no single toolchain reproduces it, and the gate will (correctly) say
so.
