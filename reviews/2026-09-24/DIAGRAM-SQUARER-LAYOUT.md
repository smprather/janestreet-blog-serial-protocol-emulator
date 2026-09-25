# Squarer diagram layout — both maps — 2026-09-24

Recorded 2026-09-24 14:02 CDT (19:02 UTC), `date`-stamped. Task 5a, the
approved layout experiment from `reviews/2026-09-23/PROJECT-REVIEW.md`
("Old wide render provenance and layout follow-up"), now covering both maps.

## Result — both targets met

| map | before PNG | before aspect | after PNG | after aspect | target | met |
|---|---|---|---|---|---|---|
| `project-plan.puml` | 4180 × 2520 | 1.6587 | **3194 × 2476** | **1.2900** | ≤ 1.4:1 | yes |
| `project-progress.puml` | 6195 × 1354 (sprawled from 4189 × 1956 = 2.14:1 during the Task-3 end refresh) | 4.5753 | **3681 × 2493** | **1.4765** | ≤ 2.0:1 | yes |

SVG sidecars: plan 4181 × 2521 → **3195 × 2477**; progress 6196 × 1355 →
**3682 × 2494**. The checked-in renders reproduce the experiment dimensions
exactly.

## What changed

- **Plan — notes into a compact block below the architecture.** All four notes
  (`pads`, `pc`, `readback`, `serdes`) are now anchored `note bottom of pads`
  instead of one note per node, so PlantUML lays them out as a block under the
  bottom node. The architecture graph, packages and edges are otherwise
  untouched. (Intermediate measurement of this step alone: 3304 × 2458,
  1.3442 — already inside target.)
- **Progress — vertical-spine discipline.** `left to right direction` became
  `top to bottom direction`; no structural edits. The existing packages
  (Program load, Firmware protocols, 10BASE-T receive, Word-engine
  integration, Static gates) now stack as vertical status lanes instead of
  five columns. (Direction-only measurement: 3681 × 2440, 1.5086.)
- **Status-accuracy wording only** (the sanctioned deltas; nothing else):
  - plan package `Optional loader readback — decision pending` →
    `Loader readback A1 — landed 2026-09-24`;
  - plan package `Planned shared word engine` → `Integrated shared word
    engine`;
  - plan readback component → `A1 commit-latched word echo on uio[4]`; the
    `loader ..> readback` and `readback ..> pads` edge labels updated to
    match; the readback note now records the landed A1 contract, and the
    serdes note records the landed split-enable/two-codec topology and its
    evidence pointer (replacing "remain open"/"no readback RTL exists");
  - progress macro-gate label `E2-6 + R3 fixed (26 checks) / manager
    verification pending` → `E2-6 + R3 closed (26 checks) / manager-verified
    2026-09-24`, and its class `<<standalone>>` (amber) → `<<complete>>`
    (green) since the gate is closed and integrated in `run_all.sh`;
  - progress macro-gate note status → CLOSED 2026-09-24 after manager
    verification (26/26 harness, regression exit 0);
  - progress readback note `no STA refresh yet` → `mapped STA refresh done
    2026-09-24; pe_ctrl summary unchanged`;
  - progress loopback note gained one closeout sentence: the codec mutation
    suite is 13/13 on the frozen tree and the mapped STA screen found no new
    violation class.

## Counts — zero lost nodes, edges, labels or notes

Parsed independently before and after (script counts `component ... as`,
`package ... {`, arrow lines and `note ... end note` blocks; JSON set/multiset
comparison):

| map | packages | components | edges | notes |
|---|---|---|---|---|
| plan before → after | 7 → 7 | 26 → 26 | 36 → 36 | 4 → 4 |
| progress before → after | 5 → 5 | 24 → 24 | 26 → 26 | 4 → 4 |

Multiset diff of the plan edges reports only the two sanctioned status-label
changes (`loader ..> readback`, `readback ..> pads`); every other edge
triple+label is identical. Progress edges are byte-identical in triple+label.
Every component id is preserved in both maps; the only changed component
labels are the four status ones listed above. Note bodies changed only in the
three sanctioned status notes (plan readback/serdes; progress
readback/macrogate/loopback), and the note count stayed 4 in both maps.

## Verification commands and checks

```bash
# render (README commands, from the repo root)
JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -DPLANTUML_LIMIT_SIZE=8192" \
  plantuml -tpng diagrams/project-plan.puml diagrams/project-progress.puml
JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -DPLANTUML_LIMIT_SIZE=8192" \
  plantuml -tsvg diagrams/project-plan.puml diagrams/project-progress.puml

JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" \
  plantuml --check-syntax diagrams/project-plan.puml diagrams/project-progress.puml
# rc=0, no diagnostics

JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" plantuml --check-graphviz
# GraphViz: dot - graphviz version 16.1.0 (0); Installation seems OK. File generation OK
```

PlantUML 1.2026.8, GraphViz dot 16.1.0. The experiments were built and
rendered in `/tmp/task5a/` (throwaway sources; not checked in) and only the
winning sources and re-rendered `PNG`/`SVG` sidecars were copied into
`diagrams/`.

## Limits

The layout is Graphviz auto-placement; dimensions will move when content is
added or labels are edited, so re-measure after future content changes. The
progress map's five packages are still arranged into lanes by Graphviz; the
1.48:1 result holds for the current content. `wiki/plans/demo-host-gui.md`
was not touched, and the shared worktree was not reset, reverted or cleaned.
