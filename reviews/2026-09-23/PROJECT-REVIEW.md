# Project review — 2026-09-23

## Scope and result

Fresh review of the current project state after the SERDES plan amendments and
the `pe_ctrl` readback audit, plus a check of the requested diagram cleanup.
Reviewed the current handoff, status page, plans, architecture/progress diagrams,
generated RTL inventory, and the available regression/hardening evidence.

No new functional RTL finding. The two recent audits changed planning and
documentation only; neither implemented the pending SERDES integration or
readback interface. The user still needs to choose A1/A2/A3 for readback, and
the SERDES plan's open scope decisions still need acceptance before RTL work.

## Current architecture and progress maps

`diagrams/` now contains only `README.md`, `project-plan.puml`, and
`project-progress.puml`. The first is the full intended topology; the second
marks completed, standalone, and open work separately. The SERDES plan and both
maps show the recommended two-codec shape, independent half-cell phase, separate
SERDES TX/RX enables, and a stuffed-cell handshake while keeping codec topology
and SERDES cadence decisions open. Wire loopback is the first planned consumer;
a complete Ethernet TX frame path is a separate future block.

The retired viewer setup instructions and live-canvas concept page are removed
from the project documentation. Historical review material and the independent
viewer utility code remain outside the diagram sources. The generated
`wiki/reference/block-diagram.md` remains an RTL inventory, not the project-wide
architecture diagram.

The requested removal of obsolete walkthrough entries in `wiki/log.md` is a
deliberate exception to its append-only convention; unaffected chronological
history remains.

## Verification evidence

- `./regress/run_all.sh --fast -j8` exited 0: 29/29 RTL testbenches, 20/20
  firmware tests, parameter guards and lint passed, and all seven mutation
  suites reported no unexplained survivors. This run was in progress while the
  docs cleanup was being prepared; it covered the RTL/regression state, while
  the documentation-specific checks below were run after the edits.
- `python3 tools/gen/block_diagram.py --check` and `python3 tools/gen/signal_glossary.py --check` passed.
- PlantUML syntax checks passed for both maps, and both rendered to PNG under
  `/tmp`.
- `bash -n regress/run_all.sh` and `git diff --check` passed.
- `README.md`, `HANDOFF.md`, `wiki/`, and `diagrams/` have no stale viewer setup
  instructions; current retirement notes remain. `diagrams/` has no rendered
  leftovers.
- Existing synthesis evidence remains 3,298 mapped cells for `pe_soc` and
  3,613 for `tt_um_top`; the SPI pad aliases add no sequential timing path.
  Existing `pe_ctrl` hardening evidence is 5,791 µm², zero Yosys problems,
  slow-corner setup slack +8.71 ns and hold slack −0.12/−0.16/−0.19 ns
  (slow/typical/fast). These are prior screens, not new runs in this review.

No physical flow, DRC, or LVS was run.

## Review disposition

Keep the two current plan decisions visible in `HANDOFF.md`. Once the user
selects a readback option and accepts the SERDES integration scope, implement
one plan at a time and update `project-progress.puml` with verified progress.
Update `project-plan.puml` only when the agreed topology or scope changes.
