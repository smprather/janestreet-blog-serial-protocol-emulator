# Project block diagrams

These are the project's editable, text-based PlantUML sources. No rendered
images are checked in.

To preview both diagrams locally, with PlantUML installed:

```sh
plantuml -tpng -o /tmp diagrams/project-plan.puml diagrams/project-progress.puml
```

- `project-plan.puml` shows the full planned architecture, including the
  committed baseline and stretch goals. Optional protocol targets are marked
  separately.
- `project-progress.puml` shows implementation and verification status. Keep
  it current whenever a block's implementation or integration status changes.

Update `project-plan.puml` when an architecture or scope decision changes. The
project plan and progress view are intentionally separate: changing progress
does not silently change the plan.
