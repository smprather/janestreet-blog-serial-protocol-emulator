# White-on-white in the figures — state of the fix

Written at the first 70% wrap, rewritten at the second and at the third, so
the next session continues from a record rather than from a memory.

| what | first wrap | second | third |
| --- | --- | --- | --- |
| branch | `docs/diag-bus` (merged to main as `28b3dd0`) | `docs/diag-hexlint` off `28b3dd0` | same branch, at `76e5d81` |
| corpus | 22 sources, 42 figures | 34 sources, 54 figures | 34 sources, 54 figures |
| fatal white-on-white | 58 -> 0 | 22 findings in 10 figures, all in post-fix additions | **0, whole corpus** |
| malformed 5-digit hex | 20 fixed, 0 remain | **22 more, live on main in 4 families** | **0, whole corpus** |
| self-test | 12 of 12 | 15 of 15 | **21 of 21** |
| figures viewed | ~5 of 42 | 54 of 54 | 54 of 54, then 14 again after the re-render |
| gate on the real tree | `diagrams: OK` | red (22 on main, 54 mid-session) | **`diagrams: OK`** |

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
| gate: malformed hex | **added this session**, cases (m) and (n) |
| white check actually looks at every figure | **fixed this session**, case (l) |
| white check: undrawn elements, translucent strokes | **fixed this session**, cases (o), (q), control (p) |
| self-test | **21 of 21** |
| visual pass | **54 of 54 figures viewed** |
| drift-exempt | 5 files, unchanged, and now also hex-checked and viewed |
| the four post-fix families | **adopted the canonical palette, re-rendered, 302 -> 0 near-white strokes** |

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

### 3. An element PlantUML was told to draw, and did not

Documented as a "latent hole" and then found to be a live route, in the act of
writing its test. `ArrowColor #FFFFFF00` is a **valid** 8-digit literal — 8 is a
length PlantUML honours, which is exactly why the hex lint accepts it — and with
zero alpha PlantUML does not fall back to white. It emits
`<line style="stroke:none">`: **the arrow is not drawn.** The stroke pattern
required a `#`, so an undrawn arrow was a clean figure. That is the reported
symptom arriving through a value the check believed it understood.

Scoped to `line`/`polyline`/`path`/`polygon`, where a none-stroke means an
undrawn element. The false-positive surface was measured, not assumed:
`stroke:none` occurs in 4 of the 54 figures, 18 times, **all on `<rect>`**
containers drawn fill-only, and **zero** times on the four elements the rule
covers. Case (o) plants it; case (p) is the control — a dark, fully opaque
8-digit literal, which must stay CLEAN, because a fix that simply rejected 8
digits would pass (o) and be wrong, and would put this check in conflict with
the hex lint.

The 8-digit **luminance** hole was closed at the same time, and it turned out
to have been closed already by accident: the stroke pattern was `{3,6}`, which
matches the first six characters of `#FFFFFF4D` and reads them as `#FFFFFF` —
right only because the prefix happened to be the pale part. A pale translucent
colour that did not *start* with six pale digits (`#FFEEEE80`, which composites
to 0.966) would have been read as opaque `#FFEEEE` and missed. `lum()` now
composites the alpha over the page rather than discarding it, and the pattern
passes the whole value through. Case (q) pins the translucent half; it passed
before this commit, but for the accidental reason, which is the reason it is
worth having as a named case.

---

## CLOSED: the four families, in this worker's lane

The manager's dispatch assumed the palette-drift findings would clear with the
re-renders. They would not: **re-rendering reproduces whatever the source says**,
and these sources said `BorderColor #33555` and `BackgroundColor White`. So the
sources changed first and the re-render followed — which is why this is a 12-file
source change and not a one-character fix.

| | before | after |
|---|---|---|
| `#33555` | 22 in 12 sources | **0** |
| near-white strokes | 302 across 10 figures | **0** |
| missing NOTE palette | 12 sources | **0** |
| gate | 22 failures on main, 54 mid-session | **`diagrams: OK`** |

What was done, per family (`proto-sr04`, `proto-nec-ir`, `proto-freqmeter`,
`proto-fm-biphase`, three stems each):

- `#33555` → `#4A6FA5` in all 22, **including inside the frame sources' own
  `rectangle` blocks**, which the drift check does not police and which would
  otherwise have been the surviving copy of the defect.
- The canonical NOTE block in all 12. None had one, so every note in these
  figures was PlantUML's default `#FEFFDD` — luminance 0.99, one of the four
  mechanisms the original audit found, reintroduced across a third of the
  corpus.
- The canonical SEQ block in the 4 timing sources, the canonical STATE block in
  the 4 base sources, verbatim from a reference whose digests were already
  canonical. That is what kills the white arrows: `ArrowColor` becomes
  `#335550`, honoured, instead of a five-digit value that is dropped.
- `BackgroundColor White` → the canonical `#EEF3FB`. This was the second damage
  signature: the state boxes rendered `fill="#FFF"` with a white border, so the
  state text floated with no box at all.
- The 2 stale `proto-ds18b20` renders re-rendered with no source change.

**The one judgement call.** All four families deliberately set monospace, and
the canonical palette carries no font, because a palette is colour. Keeping the
font inside the block would have made all 12 sources *drift*; dropping it would
have quietly re-typeset 12 figures. Both are avoidable because the in-scope
corpus already solved it: `skinparam defaultFontName Monospaced`, **unbraced**,
20 times across the 17 sources — which is exactly why their braced blocks still
hash canonically. So the font lines were lifted out of the blocks and kept, in
the position the corpus puts them, after the title.

**The stereotype check came before the render.** Every stereotype in use across
the 12 is either one of the 12 canonical ones or declared in its own source's
block — checked first, because repainting a family's vocabulary without
enumerating it is the mistake this work already made once, and it is invisible
to every mechanical check.

**Visual pass: all 14 re-rendered figures viewed.** The three signatures are
gone and the gain is not marginal — the timing figures had message labels with
no lines and now have lines, arrowheads and visible activation boxes; the state
figures had bare text and now have bordered boxes; the frame figures' pale
boxes now have visible outlines. Confirmed mechanically as well as by eye: the
`fill="#F4F7FB" stroke:#FFF` combination that produced the invisible outlines
now occurs **zero** times in the corpus.

## What the manager's premise got wrong, recorded because it nearly cost the fix

"The drift clears with re-renders." It does not. Re-rendering is a *reproduction*
step; the drift and the white-on-white were both in the **source**, so a
re-render alone would have reproduced the defect faithfully and the gate would
still be red. Anyone optimising for the re-render first would have "verified"
the broken figures and moved on.

---

## What the gate reported on the four families, and what they were

*Superseded by the CLOSED section above; kept because the failure mode is worth
having on the record. The corpus grew from 22 sources to 34 while the fix was in
review, and the gate was blind to all of it.*

| | count, as found |
| --- | --- |
| malformed `#33555` | **22 literals in 12 sources** |
| white-on-white | **22 findings, 302 near-white strokes, 10 figures** |
| palette drift (pre-existing) | 20 findings, same sources |
| stale renders (pre-existing) | `proto-ds18b20`, `proto-ds18b20-timing` |
| gate exit code before this session | **already 1** (22 failures: 20 drift + 2 stale) |
| gate exit code mid-session, after the two gate fixes | 1 (54 failures) |
| gate exit code now | **0** |

All of it was in **four figure families added after the white-on-white fix**:
`proto-sr04`, `proto-nec-ir`, `proto-freqmeter`, `proto-fm-biphase` — every
occurrence the same `#33555`, every one a copy of the pre-fix pattern. So the
merged gate was not merely incomplete on them; its report was **affirmatively
wrong** ("no white-on-white" over 302 white strokes). The manager later placed
these four families in this worker's lane and they are now fixed and
re-rendered.

**What each family looked like to a reader** — recorded because the three
signatures are different, and a "looks fine at a glance" review passes all
three:

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

It flags near-white text, near-white stroke, a near-white *fill* whose own
outline is also near-white or absent, and — since this session — a
`line`/`polyline`/`path`/`polygon` emitted with `stroke:none`. It deliberately
does **not** flag a near-white fill with a dark outline and dark content, because
that is a light background doing its job.

Two more holes were **claimed** here earlier and are corrected now, because a
state record that keeps a disproved claim is worse than no record:

- **8-digit hex — was claimed to bypass `lum()`; it did not, in practice.**
  `lum()` did return `None` for 8 digits, but the stroke pattern was `{3,6}`, so
  it matched the first *six* characters of `#FFFFFF4D` and read them as
  `#FFFFFF` — right only because the prefix happened to be the pale part. Now
  fixed properly (`lum()` composites the alpha over the page, the pattern passes
  the whole value through) and pinned by case (q).
- **Named colours — claimed to be a hole; measured, and it is not one.** The
  check reads the **SVG**, and PlantUML normalises names on output: `ArrowColor
  red` comes out `#F00`, `ArrowColor white` comes out `#FFF`. Corpus-wide, every
  colour value the check is handed across all 54 figures is hex3 or hex6 — 133
  and 416 of them, zero `rgb()`, zero names, zero unparsed. `FontColor white` is
  caught, precisely *because* PlantUML writes `#FFF`. No colour table needed, and
  the one named colour in the corpus source is handled correctly.

One genuine residual blind spot remains, and it is not in this class: a
near-white fill that has a **dark** outline and dark text is accepted by design,
so a figure that is entirely pale-but-outlined will pass. It was not seen in
these 54, and it is the one thing a human eye is still better at than this check.

## What REMAINS

1. ~~The four unowned families.~~ **DONE** — canonical palette adopted, 22
   literals fixed, 28 renders redone, `diagrams: OK`. See the CLOSED section.
2. **The 5 drift-exempt files — DECIDED, and the exemption is now audited.**
   `project-plan.puml`, `project-progress.puml`, `proto-r2-read-path.puml`,
   `proto-r3-debug-control.puml`, `proto-spi-framing.puml`. They keep their own
   palette, and the reason is mechanical rather than a matter of taste: **the
   canonical set is NOTE + SEQ + STATE and contains no `component` block, and
   these four maps are the only files in the corpus that carry one.** Each such
   block *is* that figure's entire colour vocabulary — twenty stereotypes
   between them (`<<complete>> <<open>> <<standalone>>`, `<<ops>> <<hdr>>
   <<live>> <<ceil>> <<refuse>>`, `<<free>> <<held>> <<hit>> <<enc>> <<trap>>`,
   `<<frame>> <<ctl>> <<data>> <<integ>> <<wait>>`) that exists nowhere else.
   Propagating would leave all twenty falling back to the base colour — the
   lost-stereotype bug at four times the scale of the mistake this work already
   made once — and two of those names **collide** with canonical stereotypes and
   mean something different: `proto-spi-framing`'s `<<wait>>` is `#b85450`, a
   red that marks a wait which can trap, where canonical `<<wait>>` is
   `#24506E`, blue. Overwriting it would change what the figure says, silently.

   So the reason is recorded **in the gate, next to the list**, and the
   exemption is **audited rather than asserted**: for each of the five,
   `exempt_audit` requires that it carries no block of a kind the fleet palette
   *does* define (a `sequence`/`state` block in an exempt file is drift hidden
   behind the name) and that every stereotype it uses is declared in one of its
   own blocks (an undeclared one falls back to the base colour, and an exempt
   file is the one place no other check looks). Cases (r), (s) and control (t)
   pin it; 0 findings on the real tree, verified, and the wiring was proved by
   planting both rot modes into a real exempt file and getting them named.

   An exemption that cannot fail is a comment with a list in it.
3. **No WCAG contrast measurement by this worker.** Another author measured their
   five sets; ours were checked for the white class and read by eye, never
   measured for contrast ratio. This is now the largest unmeasured claim in the
   figures, and it applies to the 4 families just re-rendered. The measurement
   method (geometric background attribution — PlantUML emits a shape and its
   label as siblings, so containment, not ancestry) is handed to `diag-proto`,
   who owns the sweep.
4. **The self-test costs ~60 s** (was 40 s); six cases, ten extra `plantuml`
   renders. It is wired into `regress/run_all.sh`, so that is suite time, paid
   deliberately: the alternative is not gating the class that caused the outage.

## Five lessons worth keeping

- **A malformed colour code is not a syntax error, it is a silent default.**
  PlantUML drops a five-digit hex and paints with white. It looked like a design
  bug and was a typo in a literal. It has now been in the tree twice, and the
  second time it arrived *after* the fix, in four families, under a gate that
  reported the tree clean.
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
- **A re-render reproduces the source; it does not repair it.** The dispatch
  that put these four families in this lane expected the drift to clear with the
  re-renders. It would not have: re-rendering `BorderColor #33555` produces
  `#33555` being dropped all over again, and the gate would still be red — with
  the broken figures freshly "verified". The order is always source, then render,
  and the reason a stale render is a cheap thing to fix is exactly the same
  reason it is a dangerous thing to reach for first.
