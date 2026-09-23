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

## Documentation findings closed

An independent cross-check found several stale or mixed-status descriptions.
The generated RTL inventory had a completed I2C plan described as the live work
list, an obsolete pin-matrix orphan link, and a planned-integration row that
named the SERDES but omitted its codec. The generator and generated page now
describe the integrated matrix, completed plan, live STATUS work list, and the
joint SERDES/codec loopback milestone.

The plan map now includes the optional `uio[4]` MISO readback path with A1/A2/A3
still pending, and it distinguishes the DRU Manchester strobe from the timing
block's plain-mode cell strobe. Both maps mark two codec instances as the current
recommendation while keeping codec topology and SERDES cadence choices open.
Generated page titles/dates and the README generator inventory were also
corrected. The diagrams directory contains source text only.

The mapped synthesis rerun also found stale current counts in the MAC summary
and generated SRAM fallback prose. STATUS and the generator now use the fresh
counts; dated 2026-09-20 area-budget numbers remain historical with a note
distinguishing the newer memory read-hold implementation and tool version.

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
- The SPI pad aliases add no sequential timing path. Existing `pe_ctrl`
  hardening evidence is 5,791 µm², zero Yosys problems,
  slow-corner setup slack +8.71 ns and hold slack −0.12/−0.16/−0.19 ns
  (slow/typical/fast). These are prior screens, not new runs in this review.

The later 2026-09-23 pure synthesis rerun (`./regress/synth_area.sh`) exited 0
with Yosys 0.69+post and no surfaced diagnostics across 17 hierarchy checks.
It measured `pe_eth_mac` at 1,402 cells, `pe_imem`'s flop fallback at 61,057
cells / 1,300,811.665 µm², `pe_soc` at 3,298 cells / 53,730.697 µm², and
`tt_um_top` at 3,613 cells / 59,547.852 µm². The source log is
`/tmp/synth_area_run.log`. This is mapped synthesis only; no STA or physical
flow was launched.

The mapped `pe_ctrl` three-corner screen was also repeated on 2026-09-23 with
Yosys 0.69+post and OpenSTA 3.1.0: zero synthesis problems, 292 cells / 75
flops, 5,791.149 µm²; setup +8.71/+8.80/+8.86 ns and hold −0.12/−0.16/−0.19
ns (slow/typical/fast). Fresh reports are byte-identical to the checked-in
screen, including its expected asynchronous-pin constraints and unplaced
high-fanout caveats. This did not include placement or routing.

## Follow-up plan review

A fresh read-only audit at `a97b613` found unresolved control/status and
completion semantics in the SERDES plan, an asynchronous plain-RX scope
question, and two readback session-boundary requirements. It also corrected
two stale plan descriptions and clarified the Manchester half-cell interval.
The details and source checks are in
`reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`. A second independent doc check
found two wording errors in the amended SERDES plan; both were corrected and
verified against the diagram and RTL. No RTL was changed.

## Ethernet frame-buffer and macro-flow follow-up

A fresh source review of the E1/E2 fixes found a functional ring-wrap release
failure and a simultaneous accounting-update capacity leak in E1, plus gaps in
the static E2 regression gate. Directed temporary simulations reproduce both
E1 cases. The current macro-flow gate still passes for both present SRAMs; the
E2 findings concern what it fails to detect. Full findings and limits are in
`reviews/2026-09-23/E1-E2-FOLLOWUP-REVIEW.md`. No RTL/config fixes or physical
checks were run.

No physical flow, DRC, or LVS was run.

## Review disposition

Keep the plan decisions and follow-up requirements visible in `HANDOFF.md`.
Once the user selects a readback option and accepts the SERDES integration
scope, implement one plan at a time and update `project-progress.puml` with
verified progress.
Update `project-plan.puml` only when the agreed topology or scope changes.
