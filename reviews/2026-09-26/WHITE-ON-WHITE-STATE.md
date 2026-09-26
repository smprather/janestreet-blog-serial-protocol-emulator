# White-on-white in the figures — state of the fix

Written at the first 70% wrap, rewritten at the second so the next session
continues from a record rather than from a memory.

| branch | `docs/diag-bus` (merged to main as `28b3dd0`) | `docs/diag-hexlint` off `28b3dd0` |
| corpus | 22 sources, 42 figures | **34 sources, 54 figures** |
| fatal white-on-white | 58 -> 0 | 0 in the 22 in-scope; **22 findings in 10 figures added after the fix** |
| self-test | 12 of 12 | **15 of 15** |
| figures viewed since the last re-render | ~5 of 42 | **54 of 54** |
| gate on the real tree | `diagrams: OK` | **red, and it was already red before this session** (see below) |

The user-reported symptom was: **"white lines in the SVGs are lost on a white
background."**

---

## What the problem actually was

Not the obvious thing. An audit of all the SVGs found **58 fatal**
white-on-white elements, from four independent mechanisms:

1. **Malformed colour codes — the dominant cause, and invisible in review.**
   `ArrowColor #33555` is **five** hex digits. PlantUML does not reject it; it
   **drops the setting** and falls back to its default arrow colour, which is
   **white**. Verified head to head on the same diagram: with `#33555` the arrow
   renders `#FFF`, with `#335550` it renders dark. There were **20** such values,
   all in the 12 timing-family sources, accounting for the white arrow *lines* and
   *arrowheads*. A five-digit hex looks entirely plausible in a source file and
   produces an invisible figure.

2. **The default note background.** PlantUML's default is `#FEFFDD`, luminance
   0.99. **No source in the tree set `NoteBackgroundColor`**, so all 294 notes
   were pale yellow on white — white on white by another route.

3. **Near-white "unobtrusive" choices**: `#FAFAFA` life lines (0.98), `#FBFBFB`
   group backgrounds (0.984), `#EFEFEF`, `#F8F8F8` legend background.

4. **The page is white**, so anything painted on it must be a dark ink or carry
   a border.

## What is DONE

| | count |
| --- | --- |
| fatal white-on-white in the 22 in-scope sources | **58 -> 0**, measured |
| malformed 5-digit hex fixed | **20**, in the 12 timing-family sources |
| canonical palette | authored once, written verbatim into **17** in-scope sources |
| figures re-rendered | on the pinned toolchain (`diagrams/TOOLCHAIN.md`) |
| gate: white-on-white | in `tools/diag/check_diagrams.sh`, negative control case (j) |
| gate: palette drift | by SHA-1 digest, negative control case (k) |
| gate: malformed hex | **new this session**, cases (m) and (n) |
| white check actually looks at every figure | **fixed this session**, case (l) |
| self-test | **15 of 15** |
| visual pass | **54 of 54 figures viewed** |
| drift-exempt | 5 files, unchanged, and now also hex-checked and viewed |

**Canonical block digests** (12 hex, trailing whitespace normalised) — the drift
check's ground truth:

```text
NOTE  6cef8ec7e7f7      every figure
SEQ   e6b4a55955c8      figures with an actor
STATE 4ae48999b2a9      figures with states
```

**Seven lost stereotypes restored** (`<<brk>> <<slot>> <<crc>> <<data>>
<<stat>> <<hs>> <<wait>>`, the timing family's own vocabulary). Confirmed still
restored in this session's visual pass: the state figures render the green
data branch, the yellow status byte and the blue CRC fold in distinct colours,
with no fall-back-to-default-blue anywhere in the 54.

---

## What this session found: the gate was green and blind

Two defects in the gate that shipped with the fix, both found by **running** it
rather than reading it. Both are now fixed on `docs/diag-hexlint` (`a791de5`).

### 1. The white-on-white check examined 3 figures out of 54

The block sat **after** the `done` that closes the per-source loop, so it ran
once, on the leftovers of the last iteration — the **alphabetically last
source**. On the real tree that is `proto-ws2812-timing`. The other 51 figures
were reported clean without having been looked at.

**Why nothing caught it.** Case (j) planted a white line and the gate caught it —
because the planted source was named `fixture-white.puml` and sorted **last** in
its sandbox. The blind spot was the one place the test did not look. Case (l)
now plants the same defect as `aaa-white-first.puml`, so the last source is
benign and only a check that looks at *every* source can pass it. Reproduced by
hand on the real gate first: the identical source named `zz-white-last.puml` was
CAUGHT, and named `aa-white-first.puml` was NOT.

### 2. Nothing gated the malformed hex — and the class was live

New check **1c** rejects any hex literal in a `.puml` that is not 3, 6 or 8
digits. The valid set was **measured, not assumed**, because the obvious answer
is wrong. Rendering an arrow at each length and reading the stroke back out of
the SVG on the pinned toolchain (PlantUML 1.2026.8):

```text
#F  #FF  #FF00  #FF000  #FF00000  #FF0000444   ->  stroke:#FFF   DROPPED, white
#F00  #FF0000                                 ->  honoured
#FF000044                                    ->  honoured, emitted verbatim
```

So **8-digit `#RRGGBBAA` is valid and 4 is not**, though 4 looks like a short 8.
A rule written as "3 or 6" — which is what the task asked for — would have
flagged a legitimate literal, and a gate that cries wolf on a corpus of 932 good
literals gets switched off. The lookahead (`(?![[:alnum:]])`) is not cosmetic:
`#define`/`#else`/`#endif` begin with hex-looking runs (`def`, `e`). A whole-line
comment is skipped because a comment is prose *about* a colour; a trailing
comment is **not**, because `ArrowColor #33555 ' too dark` is a real defect with
a note attached, and skipping it would be fail-open.

Case (m) plants `#12345` on `FontColor` **on purpose, not on an arrow**: with an
arrow it would also trip the white check and prove nothing about the lint. On
`FontColor` the render is *perfect* — the fallback happens to be a legible black
— so the case shows the lint checks the **source**, and cannot be satisfied by
the white class. Case (n) is its control: same source, same property, six digits,
gate must be **CLEAN**.

---

## LIVE DEFECTS ON MAIN, in other authors' figures — reported, not touched

The corpus grew from 22 sources to 34 while the fix was in review, and the gate
was blind to all of it. What the corrected gate now reports:

| | count |
| --- | --- |
| malformed `#33555` | **22 literals in 12 sources** |
| white-on-white | **22 findings, 302 near-white strokes, 10 figures** |
| palette drift (pre-existing) | 20 findings, same sources |
| stale renders (pre-existing) | `proto-ds18b20`, `proto-ds18b20-timing` |
| gate exit code before this session | **already 1** (22 failures: 20 drift + 2 stale) |
| gate exit code now | 1 (54 failures) |

All of it is in **four figure families added after the white-on-white fix**:
`proto-sr04`, `proto-nec-ir`, `proto-freqmeter`, `proto-fm-biphase` — every
occurrence the same `#33555`, every one a copy of the pre-fix pattern. So the
merged gate was not merely incomplete on them; its report was **affirmatively
wrong** ("no white-on-white" over 302 white strokes).

**Not fixed here, deliberately.** They are other workers' figures, the fix needs
their 12 re-renders, and their palette drift is a larger job than the hex. The
one-character fix per literal is `#33555` -> `#335550`; the owners are the
`pw-diag-timing` / `proto` authors of `555fe9d`, `998daa6`, `ee5e01e`.

**What each family looks like to a reader** (from the visual pass, and the three
signatures are different, so a "looks fine at a glance" review will pass them):

1. **Timing figures** (`*-timing`, 4): the message arrows and arrowheads are
   white, so the sequence reads as **floating labels with no lines** — direction
   and order are gone. The worst of the three.
2. **Base state figures** (3): the state boxes are `fill="#FFF"` with
   `stroke:#FFF"`, so the state text **floats with no visible box**.
3. **Frame figures** (2): `fill="#F4F7FB"` boxes with a white border — the
   outline is invisible but the pale fill carries it. Degraded, not lost.

---

## The visual pass: 54 of 54, and what it found

Every figure in `diagrams/` was rendered, downscaled to fit, and looked at on its
white page. The mechanical check is deliberately narrow (below), so this is the
only thing that can see what it cannot.

- **44 figures: nothing invisible.** Arrows, arrowheads, activation boxes,
  waveform traces, state boxes, stereotype colours, note fills and every text
  element read on the page. The seven restored stereotypes are still restored
  (`proto-spi3-crc` shows the green data branch, purple CRC fold, blue bit-loop).
- **10 figures: confirmed damaged**, exactly the three signatures above. This is
  the same set the corrected gate names, found independently by eye.

## What the white check still will not catch — know this before trusting it

It flags near-white text, near-white stroke, and a near-white *fill* whose own
outline is also near-white or absent. It deliberately does **not** flag a
near-white fill with a dark outline and dark content, because that is a light
background doing its job.

Two **latent** holes found this session, both measured, neither live today
(`grep` finds zero occurrences of either in the corpus):

- **8-digit hex bypasses `lum()`.** `#RRGGBBAA` is honoured by PlantUML and
  emitted verbatim, but `lum()` returns `None` for anything that is not exactly
  3 or 6 digits, so such a stroke is skipped. Zero occurrences today; a future
  translucent stroke would be invisible to the check.
- **Named colours bypass `lum()` entirely.** `FontColor white` is not a `#`
  literal, so `lum()` returns `None` and the check passes it. That is white
  text, invisible, reported clean. Zero occurrences today.

Neither is fixed here: fixing `lum()` without a failing test first would be the
same discipline violation this gate exists to prevent, and both are latent.

## What REMAINS

1. **The four unowned families** (above). 22 malformed literals, 10 damaged
   figures, 20 palette-drift findings, 2 stale renders. Not mine; the gate names
   every one of them with a file and a line.
2. **The 5 drift-exempt files are unchanged** — `project-plan.puml`,
   `project-progress.puml`, `proto-r2-read-path.puml`, `proto-r3-debug-control.puml`,
   `proto-spi-framing.puml`. Same status as the first wrap, now with three more
   facts: the malformed-hex lint **passes on all five** (they are covered by
   check 1c, which has no exemption list), all five were **viewed** in the visual
   pass and have nothing invisible, and their palettes are unchanged so the
   exemption is still correct. If any of them ever adopts a palette block, add
   its digest to the canonical set or re-verify and drop the exemption.
3. **No WCAG contrast measurement by this worker.** Another author measured their
   five sets; ours were checked for the white class and read by eye, never
   measured for contrast ratio.
4. **The self-test costs 51 s** (was 40 s); three cases, six extra `plantuml`
   renders. It is wired into `regress/run_all.sh`, so that is suite time, paid
   deliberately: the alternative is not gating the class that caused the outage.

## Four lessons worth keeping

- **A malformed colour code is not a syntax error, it is a silent default.**
  PlantUML drops a five-digit hex and paints with white. It looked like a design
  bug and was a typo in a literal. It has now been in the tree twice.
- **A negative control planted where the bug is not, is not a control.** Case (j)
  passed for a whole merge while the class it guarded examined 3 figures of 54,
  because the planted file happened to sort last. The control has to be planted
  *in the blind spot*, which is a different instinct from planting it faithfully.
- **A gate that examines one file is a green light.** Not "a weaker check" — a
  green light, printed on every run, naming 51 files it never opened.
- **`!include` is not usable in this toolchain**, so one authored palette is
  propagated into the sources and the drift check keeps the copies honest. And
  **measure the valid set**: the rule everyone would write from memory ("3 or 6")
  is wrong here, and a wrong rule is worse than no rule because it gets disabled.
