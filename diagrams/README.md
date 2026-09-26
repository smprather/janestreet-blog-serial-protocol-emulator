# Project block diagrams

These are the project's editable, text-based PlantUML sources. Keep generated
`.svg` and `.png` renders beside each `.puml` source so they are easy to preview
in tools that do not render PlantUML.

Regenerate both formats after editing either diagram, with PlantUML installed:

```sh
JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -DPLANTUML_LIMIT_SIZE=8192" \
  plantuml -tpng diagrams/project-plan.puml diagrams/project-progress.puml
JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -DPLANTUML_LIMIT_SIZE=8192" \
  plantuml -tsvg diagrams/project-plan.puml diagrams/project-progress.puml
```

- `project-plan.puml` shows the full planned architecture, including the
  committed baseline and stretch goals. Optional protocol targets are marked
  separately.
- `project-progress.puml` shows implementation and verification status. Keep
  it current whenever a block's implementation or integration status changes.

Update `project-plan.puml` when an architecture or scope decision changes. The
project plan and progress view are intentionally separate: changing progress
does not silently change the plan.

## Toolchain pin

The renders in this directory are byte-compared against fresh renders by
`tools/diag/check_diagrams.sh`, which is only meaningful on a host whose renderer
produces the same bytes. The pinned versions live in
[`TOOLCHAIN.md`](TOOLCHAIN.md) and the gate checks them.

If the gate reports a **TOOLCHAIN MISMATCH**, the byte comparison is
*inconclusive* for that run — not a defect in any figure. Install the pinned
versions, or re-render and bump the pin **in the same commit**. Do not silence it
by re-rendering alone: that discards the staleness the gate exists to catch.

Bumping the pin means re-rendering **every** figure in this directory, not the one
that moved, or the corpus ends up in a state no single toolchain reproduces.
