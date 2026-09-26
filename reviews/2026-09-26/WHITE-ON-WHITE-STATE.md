# White-on-white in the figures — state of the fix

Written at the 70% wrap so the next session continues from a record rather than
from a memory. Branch `docs/diag-bus`, tip `a6970db` (local == remote at the time
of writing). Gate: `diagrams: OK`, self-test **12 of 12**.

The user-reported symptom was: **"white lines in the SVGs are lost on a white
background."**

---

## What the problem actually was

Not the obvious thing. An audit of all 42 SVGs found **58 fatal** white-on-white
elements, from four independent mechanisms:

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

| | |
|---|---|
| fatal white-on-white | **58 -> 0**, measured |
| malformed 5-digit hex fixed | **20**, in the 12 timing-family sources; **0** remain |
| canonical palette | authored once, written verbatim into **17** in-scope sources |
| figures re-rendered | **42 png / 42 svg**, on the pinned toolchain (`diagrams/TOOLCHAIN.md`) |
| visual confirmation | `proto-ws2812-timing` (had 19 white arrowheads) and `proto-midi` viewed and read |
| gate: white-on-white | in `tools/diag/check_diagrams.sh`, negative control case (j) |
| gate: palette drift | by SHA-1 digest, negative control case (k) |
| self-test | **12 of 12** |
| drift-exempt | 5 files, owned and verified clean by their own author |

**Canonical block digests** (12 hex, trailing whitespace normalised) — the drift
check's ground truth:

```
NOTE  6cef8ec7e7f7      every figure
SEQ   e6b4a55955c8      figures with an actor
STATE 4ae48999b2a9      figures with states
```

**Seven lost stereotypes restored.** The palette I first authored carried only
`<<tx>> <<rx>> <<ack>> <<abort>> <<box>>`, while the sources use seven more —
`<<brk>> <<slot>> <<crc>> <<data>> <<stat>> <<hs>> <<wait>>`, the timing family's
own semantic vocabulary. Those states silently fell back to the default blue.
Now defined in all 9 in-scope sources that have a state block; `proto-dmx512`
went from 3 distinct state fills to 11. Cause recorded: I repainted a family's
vocabulary without enumerating it first. Nothing was *invisible*, which is
precisely why the mechanical check passed and only looking found it.

## What REMAINS

1. **The malformed-hex class is fixed but NOT GATED.** Nothing prevents a future
   `#12345`. A four-line lint over `diagrams/*.puml` rejecting any hex literal
   that is not exactly 3 or 6 digits would close it, and it is the cheapest
   remaining item. Highest value, because mechanism 1 is the one that actually
   made figures invisible.

2. **The visual pass is incomplete.** Roughly five of the 42 figures have been
   viewed since the final re-render. The mechanical check proves no *fatal* white
   remains, but it is deliberately narrow (see 3), and only looking caught the
   stereotype regression. Finish viewing all 42 on a white background.

3. **The white check is narrow on purpose — know what it will not catch.** It
   flags near-white text, near-white stroke, and a near-white *fill* whose own
   outline is also near-white or absent. It deliberately does **not** flag a
   near-white fill with a dark outline and dark content, because that is a light
   background doing its job and flagging it would be a false positive on most of
   the corpus. Residual blind spot: a figure genuinely invisible while being
   filled near-white AND outlined near-white needs the human eye. Item 2 is the
   mitigation.

4. **The 5 drift-exempt files are unmonitored by the drift check**:
   `project-plan.puml`, `project-progress.puml`, `proto-r2-read-path.puml`,
   `proto-r3-debug-control.puml`, `proto-spi-framing.puml`. Reported clean by
   their own author (all-explicit fills, zero `<style>` blocks, WCAG worst
   contrast 6.00:1) and a palette change would not move them. If their palette
   ever changes, add their digests to the canonical set or re-verify them and drop
   the exemption.

5. **No WCAG contrast measurement was done by this worker.** Another author
   measured their five sets; ours were checked for the white class and read by
   eye, not measured for contrast ratio.

## Three lessons worth keeping

- **A malformed colour code is not a syntax error, it is a silent default.**
  PlantUML drops a five-digit hex and paints with white. It looked like a design
  bug and was a typo in a literal.
- **A propagated definition needs a presence check, and a check needs a negative
  control.** The palette was written into 17 files and nothing held them together
  for several commits.
- **`!include` is not usable in this toolchain.** A top-level include reaches only
  the first block of a multi-block source (verified), and a relative include fails
  from every invocation style while an absolute path works and is unportable
  across worktrees. Hence one authored palette propagated to the sources, with
  the drift check keeping the copies honest.
