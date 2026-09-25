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

At that review point, `diagrams/` contained `README.md`, `project-plan.puml`, and
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

A follow-up comparison against the amended plans found six diagram wording or
edge issues and corrected them: the timing block now distinguishes the
encoded-cell strobe from the half-cell level; control reaches timing and the
SERDES through the `0xF` window; the wire-loopback path says simulation wire
model rather than pads; and the MISO route and its unresolved host-contract
choices are explicit. The progress map's completion colors did not need to
change. At that review point, both PlantUML sources rendered in headless mode
to `/tmp` and no rendered image was checked into `diagrams/`.

The current plan identifies the board-side SPI host as the RP2040 on the Tiny
Tapeout demo board (Raspberry Pi Pico). The progress map marks board bring-up
open and does not assign unconfirmed pad mappings to the Pico.

The host/board boundary is now explicit: a planned GUI on a connected Linux PC
controls the RP2040 on the Tiny Tapeout demo board, and the RP2040 drives the
chip's passive SPI loader. PC-to-board transport, control API, clock controls,
and load-status strategy remain undecided. A requirements/planning task was
added as item 8 in `wiki/STATUS.md`; no GUI or bridge firmware exists yet.

### Old wide render provenance and layout follow-up

The supplied 1393×269 image matches `/tmp/plantuml-view/project-plan.png`
(3568×675) label-for-label, downscaled with a small border trim. That 5.29:1
render is timestamped 2026-09-23 13:19. It depicts an uncommitted pre-`cc00c58`
draft: `git log --all --diff-filter=A -- '*.puml'` finds the first committed
plan source later at `cc00c58`, and searches for the screenshot's “Stretch goals” wording find no diagram commit. The draft `.puml` source is gone; only
the render and a 2026-09-23 13:26 vertical experiment survive in `/tmp`. Both
the supplied image's matching render and current sidecars report PlantUML
1.2026.8, so the wide layout comes from the old draft's sparse horizontal
structure rather than a renderer-version difference.

Current sources are much denser: the planned map has 7 nested packages, 26
components, 36 edges and four notes; it renders 4180×2520 (1.66:1). The
progress map is 4189×1956 (2.14:1). Both PNG and SVG sidecars are checked in
beside their sources. `PLANTUML_LIMIT_SIZE=8192` is needed for complete PNG
output above PlantUML's default 4096 px limit; the README commands set it.

Merely shortening notes and labels has an estimated result near 2700×1600
(1.7:1), essentially no improvement over the current plan's 1.66:1 and not a
good match for the user's near-square goal. The better next proposal is to keep
all nodes/edges, center the PC → RP2040 → SoC path as a vertical spine, group
receive and TX paths as side branches, and put the explanatory notes in a
compact block below the architecture. Try the placement in a temporary source
and compare the render dimensions before replacing the checked-in layout. This
layout experiment awaits approval; no layout-only changes have been made.
The newly added PC GUI and board path remain in both current maps.

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
corrected. The diagrams were source text only at that review point; current SVG
and PNG previews sit beside each PlantUML source.

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
flow was launched. (These are the pre-E1-followup-fix counts; the post-fix
refresh is in "E1 ring-release follow-up" below.)

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

### Readback contract review

A fresh source-grounded audit confirmed the `uio[4]` mapping and timing
calculations in `wiki/plans/pe-ctrl-readback.md`, and found additional host
contract requirements before implementation: the last committed word of a
full 1,024-word image needs a response frame even after `load_error` blocks
receive; A1/A2 need a minimum SCLK low phase or fixed duty cycle, not only a
frequency ceiling; per-word verification requires the readback rate on every
echoed frame; and the CS-to-first-clock setup needs a numeric bound. A2's
computed limit (~7.7 MHz) is only slightly above A1 (~7.5 MHz), so its extra
latency needs a clear purpose. The audit and exact source traces are in
`reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`. These choices remain open and no
RTL or tests changed.

A further source-grounded SERDES decision-readiness audit found no mismatch in
the planned topology. It grouped the remaining user decisions into milestone
scope, plain asynchronous RX scope, topology, and CPU access; evidence-backed
defaults are recorded in the follow-up review, but none is selected. The plan's
area estimate was stale (`pe_soc` 3,298); a subsequent mapped synthesis repeat
refreshed both the SoC and TT-top baselines. Repeat after implementation to
measure its delta. No RTL or tests changed.

## Ethernet frame-buffer and macro-flow follow-up

A fresh source review of the E1/E2 fixes found a functional ring-wrap release
failure and a simultaneous accounting-update capacity leak in E1, plus gaps in
the static E2 regression gate. At review time the directed temporary
simulations reproduced both E1 cases, and no RTL/config fixes or physical
checks had been run. The E1 fix that followed is in the next section, and the
E2-1/E2-2 gate fix is in the one after it, with E2-3's PDK-less policy, E2-4's
view validation and E2-5's per-type geometry in the same harness. Full
findings and limits are in
`reviews/2026-09-23/E1-E2-FOLLOWUP-REVIEW.md`. The current macro-flow gate
still passes for both present SRAMs; the E2 findings concern what it fails to
detect.

## E1 ring-release follow-up (2026-09-23)

The E1/E2 follow-up review's two E1 findings are fixed in `rtl/pe_eth_mac.v`:
the release distance is measured modulo `BUF_BYTES`, and the consumer credit
(`consume_credit`) is summed into every producer `room` update instead of
being overwritten by the later state-machine assignment. Directed wrap and
collision tests in `tb/tb_pe_eth_mac.v` failed before the fix (`rptr = 1996,
want 144`; `room = 1852, want 2048`; collision `room = 2001, want 2047`) and
pass after. Validating the gate exposed two harness defects -- the directed
waits are now bounded, and `run_tb` counts only a printed FAIL as a detection
-- and two mutants were added for the fix; at that point `mutate_eth_mac_tb.sh`
was 18/18 (0 survivors, 0 harness errors, timeout-free), `mutate_eth_soc_tb.sh`
8/8, and `./regress/run_all.sh --fast -j8` exited 0 (29/29 RTL, 20/20
firmware, lint and every generated gate clean). A subsequent independent
accounting-coverage audit found the type-success settle, bad-frame settle and
`S_ERR` consume-credit folds lacked directed evidence. Three permanent probes
and three matching mutants were added; the review found no RTL defect. A second
audit then added a nonzero partial-allocation `S_ERR` collision and a full-ring
bad-FCS settle/recovery test for the `pay_cnt[AW]` reclaim bit. At that stage,
the MAC mutation gate was 22/22. Fresh `./regress/run_all.sh --fast -j8` passes with the new
tests: 29/29 RTL, 20/20 firmware, lint/elaboration, generated gates and all
seven TB mutation suites. The existing pure Yosys/OpenSTA SoC screen
reports `check -assert` 0 problems, setup 0.00 at all corners and hold
-0.87/-0.61/-0.48 ns (slow/typ/fast) -- unchanged from the recorded post-E1
screen. The pre-published-ownership `synth_area.sh` refresh reported `pe_eth_mac` 1,354 cells
/ 19,789.74 µm², `pe_soc` 3,306 / 53,615.56 µm² and `tt_um_top` 3,579 /
59,286.81 µm². E1-3 (an exact full-ring release reads as a duplicate) remains
documented. No physical flow, DRC or LVS.

A further pre-published-ownership current-tree repeat of `./regress/synth_area.sh` exited 0 and returned
the same counts: `pe_eth_mac` 1,354 / 19,789.7364 µm², `pe_soc` 3,306 /
53,615.5578 µm² and `tt_um_top` 3,579 / 59,286.8052 µm². The script surfaced
no diagnostics; full output is `/tmp/synth_area_diagram_followup.log`. This is
mapped pre-route synthesis only.

The new counts refreshed `wiki/reference/.floorplan-areas` and the generated
floorplan page. The same SERDES-derived factor gave estimated occupancy at
that revision of 60.0%, 36.1%, and 45.0% for the template 6×4, blog 6×4, and template 8×4
die scenarios. This is arithmetic using a padless core and an estimate for
routing/clock/fill; it is not placement, routing, or signoff. The generator
check passes. A follow-up source review also changed the page to say the flow
config declares the coordinates and PDN script clauses: the E2 gate checks
those inputs, while actual placement and power connectivity remain unverified.

## E2 macro-gate follow-up (2026-09-23)

The two E2 gate-coverage findings are fixed in
`tools/checks/macro_flow_config.py`: each `PDN_MACRO_CONNECTIONS` entry is
validated field-by-field, with power pins required on `VPWR` and `VSS!` on
`VGND` (not just the pin names), and the PDN script must contain the macro
grid's `add_pdn_stripe -layer Metal4` plus its ordered
`Metal4 -> $PDN_VERTICAL_LAYER` and
`$PDN_VERTICAL_LAYER -> $PDN_HORIZONTAL_LAYER` connects, matched inside the
same macro-grid command. A `--flow` option lets the negative tests point the
gate at a copy. `regress/mutate_macro_flow_config.sh` proves the gate rejects
wrong-net, missing-Metal4-to-vertical, missing-vertical-to-horizontal,
missing-Metal4-stripe, wrong-layer and reversed-layers mutations, all as
exit 1 (20/20 checks, tracked files byte-compared), and is wired into
`run_all.sh`. E2-3 is closed in the same harness: the checker returns exit 2
ONLY for "required PDK geometry/views unavailable and no other findings" (a
supported PDK-less skip that `run_all.sh` reports as SKIPPED), a finding with
the LEF missing still exits 1, a Yosys elaboration failure exits 1, and the
harness prints a clean SKIP when its own baseline is incomplete. E2-4 is also
closed: every configured macro type must have nonempty `gds`/`lef`/`lib`
views, every `./src/<name>` view must resolve to exactly one file of the
matching class and extension in the PDK `sg13g2_sram` tree `run_librelane.sh`
stages from, and the `lib` keys must cover the flow's required
`DEFAULT_CORNER`/`STA_CORNERS` list (derived from the flow config or the PDK's
LibreLane `config.tcl`); the harness adds missing-LEF, missing-GDS,
missing-corner, nonexistent-path and wrong-view-type mutations plus
view-finding-without-geometry and PDK-less wrong-type checks. E2-5 is closed
too: each configured macro type's own `./src` LEF view is resolved under the
PDK and its own `SIZE` drives that type's `DIE_AREA` fit and pairwise gap
checks (the pairwise test now uses each instance's own dimensions), with a
synthetic two-type flow (10x10 and 100x100 LEFs; die-fit, overlap and
missing-type-LEF configs) added to the harness and `--lef` kept as the
override testhook for the E2-3 exit taxonomy. E2-1 through E2-5 are fully
closed; physical flow, DRC and LVS remain deferred.
`./regress/run_all.sh --fast -j8` on the final tree exits 0 (29/29 RTL, 20/20
firmware, lint and every gate clean). No physical flow, DRC or LVS.

The missing-LEF path also passes end to end with SRAM simulation models
available separately:
`HOME=/tmp/nopdk IHP_PDK=/home/mylesp/pdk/IHP-Open-PDK ./regress/run_all.sh
--fast -j8` exits 0 (29/29 RTL, 20/20 firmware); macro geometry and its
geometry-dependent negative suite report SKIPPED.

No physical flow, DRC, or LVS was run.

## Review disposition

Keep the plan decisions and follow-up requirements visible in `HANDOFF.md`.
Once the user selects a readback option and accepts the SERDES integration
scope, implement one plan at a time and update `project-progress.puml` with
verified progress.
Update `project-plan.puml` only when the agreed topology or scope changes.

## Fresh MAC accounting review and fix (2026-09-23)

Pi's independent E1 audit found a P1 ownership hole: the accepted consume
distance was checked against allocated bytes, including an unpublished
in-flight frame. The frame could then be reclaimed a second time on a bad FCS,
TYPE windback, or `S_ERR`, making `room` exceed the ring size. Added the
committed-byte counter `published_used`, a guard against releasing beyond it,
and correct publication updates for length and TYPE frames. Directed tests
failed against the prior RTL and pass after the fix. The previously ineffective
producer-pointer rebase mutation is now observable because the directed case
partially consumes an earlier frame while a new one arrives.

Verification after the RTL change: the MAC gate detects all 30 mutations,
including TYPE/length publication collision arithmetic, exclusion of the TYPE
FCS from committed-byte counts, and preservation of older committed bytes
across bad-frame rollback and `S_ERR`. The full regression passes 29/29 RTL,
20/20 firmware, lint/elaboration, generated gates and all seven mutation
suites. Mapped synthesis reports 1,681 MAC cells /
23,749.6266 µm², 3,571 SoC cells / 56,816.8776 µm² and 3,888 TT-top cells /
62,745.4296 µm². A fresh three-corner mapped SoC screen reports zero Yosys
check problems, setup 0.00 ns and hold −0.87/−0.61/−0.48 ns (slow/typ/fast),
unchanged from the prior screen; existing unplaced hold/electrical violations
remain. Floorplan area cache and generated page were refreshed; current estimated
occupancy is 61.4%, 36.9%, and 46.0% for the template 6×4, blog 6×4, and
template 8×4 scenarios. These are padless-core area estimates, not physical
implementation results. Detailed source traces, limits and commands are in
`reviews/2026-09-23/E1-PUBLISHED-OWNERSHIP-REVIEW.md`. No physical flow, DRC or
LVS was run.

At 22:47 CDT, an independent re-hash confirmed the current
`rtl/pe_eth_mac.v` SHA-256 is
`750d0bd591cc3c1a6e425b03e4cd471a5b398ca6cc03265c654d03daa69195d9`, matching
the source recorded with the exact-source E1 mapped screen. The E1 map and STA
results therefore still apply to the current RTL. The ownership logic,
directed tests and all 30 MAC mutants passed review; no further functional
defect was found. All three corners check hold, including slow (−0.8692 ns
worst hold). The reported
0.00 ns setup worst at slow is a latch time-borrow path; worst slow
register-to-register setup is +2.2274 ns. Negative hold and electrical
violations remain in the ideal-clock, unplaced screen. Fresh logs are retained
in `reviews/2026-09-23/e1-published-ownership/`. Synthesis-area and STA screens
are not gates in `run_all.sh`, so they still require deliberate periodic runs.

### Periodic mapped hardening refresh (2026-09-23 22:53 CDT)

Because the E1 RTL remained unchanged, reran mapped synthesis and the three
corner timing screen without placement or routing. `./regress/synth_area.sh`
exited 0 with no surfaced synthesis diagnostics and reproduced the same counts:
`pe_eth_mac` 1,681 cells / 23,749.6266 µm²; `pe_soc` 3,571 / 56,816.8776 µm²;
`tt_um_top` 3,888 / 62,745.4296 µm². The source SHA-256 remains
`750d0bd591cc3c1a6e425b03e4cd471a5b398ca6cc03265c654d03daa69195d9`; the
mapped netlist used for STA has SHA-256
`af81045deec97cefdf5011b5a8f6025748a45a17d48fe27082f8dbc2020ec193`, matching
the exact-source screen.

Fresh OpenSTA 3.1.0 runs at slow/typ/fast all exited 0 and were byte-identical
to `e1-published-ownership/sta-{slow,typ,fast}.txt`. Worst setup is 0.00 ns at
each corner; worst hold is −0.87/−0.61/−0.48 ns (slow/typ/fast). Slow is a
hold-check corner: it reads the slow libraries, applies 0.25 ns hold
uncertainty, and reports minimum paths. The 0.00 ns slow setup summary remains
the transparent-latch time-borrow path; worst slow register-to-register setup
is +2.2274 ns. Existing ideal-clock, unplaced hold and electrical violations
remain. Logs are in `/tmp/e1-refresh-20260923/`. This is mapped evidence only;
no physical flow, DRC or LVS was run.

## Demo-GUI plan audit and E2 macro-gate re-review (2026-09-23)

### Part A — `wiki/plans/demo-host-gui.md` source/claim audit (documentation only)

Audited the draft against every cited source (`wiki/decisions/adr-007-pe-ctrl-passive-slave.md`,
`rtl/tt_um_protocol_emulator.v`, `rtl/pe_ctrl.v`,
`wiki/raw/articles/tinytapeout-clock-spec.md`, `wiki/entities/tiny-tapeout.md`,
`wiki/reference/protocol-pin-budget.md`, `wiki/plans/spi-pads.md`,
`wiki/plans/pe-ctrl-readback.md`, `README.md`, `wiki/STATUS.md` item 8).
Claims matched their sources except for these corrections, which are applied:

1. **Wikilink slug.** `[[decisions/adr-007]]` did not match
   `wiki/decisions/adr-007-pe-ctrl-passive-slave.md`; now the full slug. All
   five wikilinks on the page resolve (checked against the file tree).
2. **Loader rate is not a fixed 10 MHz.** `rtl/pe_ctrl.v` documents six core
   clocks per SCLK period (three per half) at 60 MHz, so the ceiling is
   `clk/6`. Every "≤10 MHz" was replaced with the derived cap; 10 MHz is
   stated as the 60 MHz figure only and is explicitly **not safe at an
   arbitrary lower `clk`** (1 MHz `clk` → ~166 kHz). Clock selection and load
   rate are now one decision (hold 60 MHz, or recompute the cap on every clock
   change); acceptance test A3 now proves the cap is derived, not fixed.
   Related corrections: `TT_IMEM_WORDS = 1024` (the parameter name), and the
   `run`-high path is described as `host_we` masking plus a queued-word abort
   latching the sticky `load_error` (which reaches no pad) instead of "writes
   silently gated / undetectable chip-side"; an image over 1,024 words was
   added as a host-side-refused, chip-side-invisible error path.
3. **Doc-check command.** `python3 tools/gen/*.py --check` does not run all
   seven generators: shell glob expansion passes the first `.py` as the
   program and the remaining paths as its arguments. The plan now lists the
   seven commands by name (`signal_glossary`, `pin_budget`, `sram_budget`,
   `floorplan_feasibility`, `crc_config`, `clock_arithmetic`,
   `block_diagram`), each run individually with `--check`.
4. **User-grounded facts vs caveats.** The Raspberry Pi Pico (RP2040) is
   recorded as the **chosen** host controller, not an open choice; the TT
   platform note about newer RP2350 demo PCBs is framed as a platform-revision
   caveat (`wiki/entities/tiny-tapeout.md` open question 2) and removed from
   the open-choices list. Every `USB CDC`/`serial`/`HID` reference is marked
   **hypothetical** — neither the clock-spec excerpt nor the user's statement
   establishes the PC↔board transport. The clock page is labelled
   **sky130-framed** (66 MHz pad macro, QFN-64/`mprj_io[6]`, RP2040 notes) with
   IHP-specific confirmation open (entities questions 1–3).

Verification after the edits: the seven named generator checks all report OK;
all wikilinks resolve; the page is indexed (`wiki/index.md`, count bumped) and
logged (`wiki/log.md`); `wiki/STATUS.md` item 8 still reads
`### 8. Linux demo-host GUI — TODO`. No GUI, bridge firmware, RTL or pinout
change.

### Part B — E2 static macro-flow checker and mutation harness re-review (read-only)

Commands and results (static only; probes ran on `/tmp` copies):

- `python3 tools/checks/macro_flow_config.py` on the tracked config: **OK
  (exit 0)**, 2 netlist instances (`u_imem.g_macro.u_sram`,
  `u_eth_fbuf.g_macro.u_sram`).
- `bash regress/mutate_macro_flow_config.sh`: **20 passed, 0 failed** — all 11
  mutations detected as exit 1, `pdkless-clean` exit 2/INCOMPLETE, and
  `pdkless-finding` / `pdkless-view-finding` / `pdkless-view-type` /
  `yosys-failure` all still exit 1, plus the three synthetic two-type geometry
  checks. The harness byte-compares `flow/pe_soc.json` and `flow/pe_soc_pdn.tcl`
  afterwards; both unchanged.
- **Exit-2 semantics re-probed independently:** `--pdk-root <empty>` on the
  tracked config → exit 2 INCOMPLETE (view tree and corner list unavailable,
  no findings); the same config with a wrong-net mutation → **exit 1** with 4
  findings. Exit 2 cannot absorb a finding on either testhook path.
- **PDN clause ordering / grid scoping:** a new probe with both `add_pdn_connect`
  commands scoped `-grid stdcell` → exit 1, "missing the macro-grid
  Metal4-to-vertical connect". Together with the harness's wrong-layer,
  reversed-layers, missing-clause and missing-stripe detections, ordering and
  macro-grid scoping hold.
- **Pin-to-net (E2-1):** five-field validation, net binding (`VPWR`/`VGND`)
  and slot checks confirmed by the wrong-net probe (4 findings) even with no
  PDK present.
- **Typed views and per-type geometry (E2-4/E2-5):** the five view mutations
  and the synthetic bounds/gap/missing-type-LEF checks behave exactly as the
  review's resolution section claims.

**Finding status (wrap-up, 2026-09-23): E2 is NOT fully closed — one open
finding, E2-6.** E2-1…E2-5 remain closed: the shipped harness is still
**20 passed / 0 failed**, and the exit-2 taxonomy, PDN ordering/grid scoping,
pin-to-net binding, typed-view and per-type-geometry claims all re-verified
above. The P2 probe below is a **confirmed checker false pass** and is
recorded as **open finding E2-6**: type B is configured with type A's 10×10
LEF while its own footprint is 100×100, and the checker accepts it in a 50×50
die (with B's own LEF the same config fails). **Recommended fix (review/report
only — not implemented):** match the configured macro type against the `MACRO`
declaration in the LEF resolved for its `lef` view (parse `MACRO <name>` and
compare with the `MACROS` key; extend the same identity check to `lib` view
names where present), and add a regression mutation to
`regress/mutate_macro_flow_config.sh` (e.g. `type-b-wrong-lef` on the existing
synthetic two-type fixture) that must be **detected as exit 1**. R1 and R3–R5
below are lower-priority coverage/robustness observations; they are not
assigned separate E2-# closure statuses in this review.

**Update (2026-09-23, later the same day):** the recommended fix above and R3
were then implemented (R1/R4/R5 remain observations). The shipped harness is
now **26 passed / 0 failed**. See the new subsection **"E2-6 resolution
(2026-09-23)"** at the end of this review: E2-6 is
**fixed-pending-manager-verification, not closed.**

**Residual findings (review only; no fix applied):**

- **R1 (low) — PDN entries are validated in one direction only.** An extra
  entry naming an instance absent from the netlist/config is silently ignored:
  probe added `u_removed\.g_macro\.u_sram VPWR VGND VDD! VSS!` to a config
  copy → exit 0, the instance never mentioned. Stale or typo'd supply entries
  are not flagged.
- **E2-6 / R2 (medium; FIXED 2026-09-23 — pending manager verification, see
  "E2-6 resolution" below) — view identity is basename-only, and geometry inherits
  the error (confirmed false pass).** A macro type configured with ANOTHER type's LEF passes, and its
  instances are then measured with the wrong `SIZE`. Probe: two-type fixture
  (A 10×10, B 100×100), `MACROS[B].lef = ./src/RM_…_A.lef` → **exit 0** with B
  at (20,0) in a 50×50 die; the same config with B's own LEF → exit 1 "not
  inside DIE_AREA". The LEF text carries `MACRO <name>`, so type↔file identity
  is cheaply checkable; GDS/LIB have no such check either.
- **R3 (low; FIXED 2026-09-23 in the same harness — see "E2-6 resolution"
  below) — corner coverage is key-pattern based with no file↔corner
  correspondence.** One `*_typ.lib` under a `*` key satisfies every required
  corner (probe exit 0), and a `nom_slow_1p08V_125C` key served by a
  `*_typ.lib` file also passes (probe exit 0). Both are plausible copy/paste
  errors the gate cannot see.
- **R4 (low) — macro supply pin names are hard-coded** (`VDD!`, `VDDARRAY!`,
  `VSS!`). Per-type generality currently stops at geometry (E2-5); a future
  macro type with different supply pins would produce false findings rather
  than a per-type pin map. Conservative, but worth recording.
- **R5 (informational, fail-closed) — instance-token matching compares the
  config token to `re.escape(name)` exactly.** A differently escaped but valid
  LibreLane instance regex (unescaped dots, `u_.*`) would be reported as "no
  PDN_MACRO_CONNECTIONS entry". Wrong direction for a false pass, but it can
  reject a legal config.

Boundaries: static checker + yosys elaboration only; probes and fixtures live
under `/tmp`; no physical flow, DRC or LVS; no RTL, flow-config, checker or
harness edits; no open plan implemented.

**Next user-gated choices:** (1) accept or revise `wiki/plans/demo-host-gui.md`
(STATUS item 8 stays TODO until then); (2) authorize the E2-6 fix above (type
↔ LEF `MACRO` match + the `type-b-wrong-lef` regression mutation) —
**implemented the same day; fixed-pending-manager-verification, see the
"E2-6 resolution" subsection below.** The readback A1/A2/A3 choice and the SERDES integration
scope decisions also remain open and user-gated.

## E2-6 resolution (2026-09-23 — fixed, pending manager verification)

Scope of this change: the recommended E2-6/R2 fix, plus R3, which fell out
cheaply. R1, R4 and R5 remain recorded observations (not fixed). No RTL,
flow-config or PDN-script changes; the false-pass demonstration and every
probe/fixture ran on `/tmp` copies; no physical flow, DRC or LVS.

### Sources and SHA-256

| file | before | after |
|---|---|---|
| `tools/checks/macro_flow_config.py` | `004d68d21fa3370fe4577dd23197efb6202f912629e2c951c986f9ae547b2af9` | `be87a3aad1e3ad9e534e422d5b9001b766cc5fa588039a881e9e685ddc8699bf` |
| `regress/mutate_macro_flow_config.sh` | `880131a34f4e565789b13356c33e635865538b1ffdb7a9740b1ea007f5a8be90` | `20b966e368812a51980811262c2bbedb0f29a490c9a6332168df8ae78694a38b` |
| `flow/pe_soc.json` (tracked, untouched) | `640c761e3167c4ddc0c42fcde4823e72896385bafa08b4377bf5fd2d611db653` | unchanged |
| `flow/pe_soc_pdn.tcl` (tracked, untouched) | `9dc80c11aeaef816799a23ba712c0defe9b07afbeb2a18928735a00acf62992d` | unchanged |
| `regress/run_all.sh` (untouched) | `0eb26669347efdafa20e340761f9d25c01903440ecbb52f1a6d4a4528817284d` | unchanged |

### Step 1 — the false pass, demonstrated first on a /tmp copy

`bash /tmp/e26-demo.sh` builds the synthetic two-type fixture exactly as the
harness does (A `SIZE 10 BY 10`, B `SIZE 100 BY 100`, fake PDK staging each
type's typed views and corner; A at (0,0), B at (20,0), `DIE_AREA
[0, 0, 50, 50]`) and runs the then-unmodified checker on two configs that
differ only in B's `lef` view:

- `bounds-own-lef.json` (B uses its own `./src/RM_IHPSG_FAKE_B.lef`) →
  `u_b: 100.0x100.0 (type RM_IHPSG_FAKE_B) at (20.0,0.0) is not inside
  DIE_AREA [0, 0, 50, 50]` — **exit 1**.
- `bounds-wrong-lef.json` (B configured with `./src/RM_IHPSG_FAKE_A.lef`,
  identical placement) → `macro flow config: OK` — **exit 0**, the E2-6 false
  pass: the checker measured A's 10×10 `SIZE` and never compared the file's
  `MACRO` declaration with the configured type.
- The script also re-hashes the tracked flow files: byte-identical to the
  before-hashes above.

### Step 2 — the fix (`tools/checks/macro_flow_config.py`)

New docstring items 6 and 7 describe the additions:

1. **E2-6 type↔view identity.** After PDK resolution finds exactly one file
   for a `lef` view, the checker parses `MACRO <name>` from it and compares it
   with the `MACROS` key; a mismatch is a finding
   (`declares MACRO X, not the configured type Y (E2-6: …)`), and a LEF with
   no `MACRO` declaration at all is a finding too (fail-closed: identity that
   cannot be established is not identity). The geometry check can therefore
   never silently measure one type with another type's footprint.
2. **lib identity, "where present"** (the review's recommended extension): a
   resolved `.lib` view that declares `cell(...)` must declare one for the
   configured type (`declares no cell for type X`); a file with no cell
   declaration carries no identity to compare and is not flagged — recorded
   below as a limit.
3. **R3 corner↔file correspondence.** Per macro type, every required corner's
   selected `lib` file set is recorded, and no single file may serve two or
   more required corners (`serves required corners […] from the same file …`).
   The check is config-only (no PDK read), so it also fails on the PDK-less
   paths; the exit-2 taxonomy is untouched.

### Step 3 — the regression mutation (`regress/mutate_macro_flow_config.sh`)

On the existing synthetic two-type fixture:

- **`type-b-wrong-lef` (required):** B's `lef` view is rewritten to
  `./src/RM_IHPSG_FAKE_A.lef` in a 50×50 die with B at (20,0); it must be
  **detected as exit 1** with the MACRO-identity finding.
- `type-b-wrong-lib`: B's `lib` view points at A's lib file → exit 1.
- `type-no-macro-lef`: B's `lef` points at a LEF that has `SIZE` but no
  `MACRO` line → exit 1 (fail-closed branch).
- `synth-identity-clean`: the legal fixture config must remain **exit 0**, the
  guard that the new checks cannot false-fail a correct config.
- R3 mutations on a copy of the tracked config: `corner-file-shared` (the
  `nom_slow_1p08V_125C` key served by the file `nom_typ_1p20V_25C` also uses)
  and `corner-key-wildcard` (one `*_typ.lib` under a `*` key satisfying every
  required corner) → both must be exit 1.

The harness grew from 20 to 26 checks.

### RED — pre-fix harness run

```text
bash regress/mutate_macro_flow_config.sh
  [corner-file-shared] SURVIVED: one lib file serving two required corners was accepted
  [corner-key-wildcard] SURVIVED: one lib file satisfying every corner under a * key was accepted
  [type-b-wrong-lef] FAILED: exit 0, want 1 + the MACRO-identity finding
  [type-b-wrong-lib] FAILED: want exit 1 + the lib-identity finding, got exit 0
  [type-no-macro-lef] FAILED: exit 0, want 1 + the no-MACRO finding
=== 21 passed, 5 failed ===
NEGATIVE TEST FAILURE: the gate does not reject every mutation.
exit 1
```

All five new detection checks failed for the right reason (the gate exited
0), while all 20 original checks and `synth-identity-clean` stayed green.

### GREEN — post-fix commands and results

| command | result |
|---|---|
| `python3 -m py_compile tools/checks/macro_flow_config.py` | OK |
| `python3 tools/checks/macro_flow_config.py` (tracked config, default PDK root) | `OK (placements, pin-to-net hooks and the Metal4 ladder complete)`, **exit 0**, 2 netlist instances; `sha256sum` of both tracked flow files identical to the before-hashes |
| `bash regress/mutate_macro_flow_config.sh` | `=== 26 passed, 0 failed ===`, **exit 0** — 0 failed, 0 survived, no harness errors, including `[type-b-wrong-lef] detected`; tracked flow files byte-compared unchanged |
| `bash /tmp/e26-demo.sh` (re-run post-fix) | both configs now **exit 1**; the wrong-LEF case reports `declares MACRO RM_IHPSG_FAKE_A, not the configured type RM_IHPSG_FAKE_B (E2-6: …)` |
| `./regress/run_all.sh --fast -j8` | **exit 0**: `FIRMWARE: 20 PASS: 20 FAIL: 0`, `TOTAL: 29 PASS: 29 FAIL: 0`, `lint clean`, `macro flow config: OK`, `macro flow config negatives: OK`, every generated gate current, all seven mutation suites OK. Log: `/tmp/run_all_e26.log` |

### Limits and residuals

- lib identity is checked only where a `cell(...)` declaration is present; a
  lib file with no cell declaration is not flagged (the review's "where
  present" wording).
- GDS view identity remains unchecked; it is recorded with R1, R4 and R5 as
  observations (the PDK GDS is binary and was out of this task's scope).
- Identity and per-type geometry need the resolved PDK tree, so PDK-less runs
  keep their exit-2 semantics; the harness's four `pdkless*`/`yosys-failure`
  checks re-verify them unchanged.
- No RTL changed; no physical flow, DRC or LVS was run.

**Status (manager update 2026-09-24): E2-6 and R3 are CLOSED.** The manager
independently re-ran the required verification on the A1-readback tree:
`bash regress/mutate_macro_flow_config.sh` reported 26 passed / 0 failed
(including `type-b-wrong-lef` detected, `type-b-wrong-lib` detected, fail-closed
identity for a LEF with no `MACRO` declaration, and R3's corner-file
correspondence), a code review of the identity logic in
`tools/checks/macro_flow_config.py` confirmed the LEF `MACRO` match with
fail-closed behavior and unchanged `flow/` files, and
`./regress/run_all.sh --fast -j8` exited 0 (log
`/tmp/run_all_mgr_verify_20260924.log`; lint clean, seven generated-doc gates
current, all seven mutation suites OK). R1, R4 and R5 remain recorded
observations.

## Manager verification of the A1 readback and mapped STA screen (2026-09-24)

Independent of the Task-2 report in
`reviews/2026-09-24/PE-CTRL-READBACK-REVIEW.md`: the full fast regression
exited 0 as above, and a fresh mapped `pe_ctrl` screen was run with the
recorded scripts (`reviews/2026-09-23/pe-ctrl-hardening/{synth.ys,sta-*.tcl}`,
Yosys + OpenSTA 3.1.0, `CLOCK_PERIOD` 16.667 ns). Worst setup is
+8.71/+8.80/+8.86 ns and worst hold is -0.12/-0.16/-0.19 ns (slow/typ/fast) --
identical worst values to the pre-readback screen; its direct `run`-input
0 ns min-input-delay artifact and the unplaced ideal-clock caveats are
unchanged. The new echo/`spi_miso` register-to-pad max-path groups report
+12.09/+12.19/+12.23 ns slack, far inside the 2.5 MHz host guard; min-path
groups add small -0.05 ns entries alongside the pre-existing ones (paths not
attributed in this screen) with no change to the worst. Mapped screening only;
no physical flow, DRC or LVS. Reports are saved in
`reviews/2026-09-24/manager-a1-sta/`.

## Manager verification of Task 4, Task 5a and Task 5b (2026-09-24, post-OOM restart)

- **Task 4 (closeout hardening: SERDES mapped STA refresh + codec mutation
  suite)** was verified post-task in
  `reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md` ("Manager verification"):  
  `bash regress/mutate_codec_tb.sh` 13 detected / 0 survived / 0 harness
  errors; `./regress/run_all.sh --fast -j8` exit 0 (FIRMWARE 21/21, TOTAL
  30/30, ten mutation suites; log `/tmp/run_all_mgr_t4verify.log`); spot
  checks of `reviews/2026-09-24/serdes-sta/` matched the review's worst
  setup/hold table (`pe_soc` 0.00 / −0.87/−0.61/−0.48 ns; `tt_um_top` 0.00 /
  −0.71/−0.52/−0.43 ns).
- **Task 5a (squarer diagram layout, both maps)** independently re-checked
  after the OOM restart: `diagrams/project-plan.png` is 3194×2476 and
  `diagrams/project-progress.png` is 3681×2493, reproducing the review's
  experiment dimensions exactly (plan 1.2900:1, progress 1.4765:1, both
  inside target); `plantuml --check-syntax` is clean; strict component counts
  match the review's tables (plan 26, progress 24). The before/after
  multiset comparison ran at task time (throwaway sources in `/tmp/task5a/`);
  the review records the only content changes as direction/anchor moves plus
  the six sanctioned status-label changes
  (`reviews/2026-09-24/DIAGRAM-SQUARER-LAYOUT.md`). No RTL, test or script
  change.
- **Task 5b (hold-screen attribution + BOARD-assumption STA variants)**
  independently re-checked: all 18 reports
  (`sta-{pe_soc,tt_um,pe_ctrl}-{slow,typ,fast}{,-board}.txt`) are present; a
  zero/board tcl pair differs only in the two `-min` delays (0.0 → 1.0 ns)
  plus header comments; sampled worst slacks match the review's table
  (`pe_soc` slow board max 0.00 / min −0.54; `pe_ctrl` slow board max 8.71 /
  min +0.04 — hold-clean at slow under the board assumption);
  `hold-attr-analysis.txt` and `analyze_hold.py` are present. The 1.0 ns
  board floor remains a labelled screening assumption, not a spec; every
  BOARD "MET" claim is conditional on it. Mapped pre-CTS screens only; no
  physical flow, DRC or LVS.
- The 2026-09-24 wezterm OOM killed the worker after the 5a/5b reviews were
  written but before `HANDOFF.md`/`wiki/STATUS.md`/`wiki/log.md` recorded
  them; that catch-up is dispatched as Task 6. From this restart the worker
  runs in the shared tmux window **`pi-protocol-worker`** — use window names,
  not pane IDs (names survive an OOM or terminal loss; the old `%46` pane is
  gone).

## Manager verification of the eth-tx plan (Task 7) and the R1 host-protocol
## reconciliation (Tasks 8-9), 2026-09-24 evening

- **Task 7 — `wiki/plans/eth-tx-frame-path.md` authored** (605 lines: eight
  scope groups G1-G8, each with an evidence-backed recommended default and
  priced alternatives, a Review Focus section, 7 tasks / 33 checkbox steps),
  registered in `wiki/index.md`, `wiki/log.md` and STATUS item 9.
  **Manager adoption: G1-G8 are adopted as the plan defaults (2026-09-24)**,
  with G6 re-checked against the now-recorded R1 host-protocol pad map:
  `uio` is 8/8 committed and `ui_in[3:7]` are free inputs, so the recommended
  `uo_out[2]` reclaim (`uo_out[2] = pin_oe_bus[7] ? pin_out_bus[7] :
  dbg_pc[0]`, reset bit-identical) is the only baseline-independent TX output
  and stands as adopted; the free-`uio` alternative is void under R1.
- **Tasks 8-9 — R1 host-protocol reconciliation.** The unrecorded chip-side
  host-protocol phase R1 (implemented 14:33 pre-OOM from the host-controller
  plan in the separate session repo `/tmp/opencode/host-controller-gui`,
  read-only from here) is now audited against its `HOST-CONTROLLER-PLAN-REVIEW`
  (P2 and P18 satisfied; P21 closed by a new CS-to-first-clock boundary sweep
  in the pad TB; P3 open), recorded in `HANDOFF.md`/`wiki/STATUS.md`/
  `wiki/log.md`, and verified: lint clean (15 verilator + 12 yosys),
  `./regress/run_all.sh --fast -j8` exit 0 (21/21 firmware, 30/30 RTL, ten
  mutation suites), `bash regress/mutate_ctrl_tb.sh` **29 detected / 0
  survived**, `./regress/synth_area.sh` exit 0 with real counts (`pe_ctrl`
  1,731 cells / 30,662.1126 µm², `tt_um_top` 6,633 / 113,254.8858 µm²,
  `pe_soc` unchanged 4,961 / 82,893.7746 µm²), seven generator checks OK.
- **Manager-authorized behavior-preserving fixes** (Task 9; `rtl/pe_ctrl.v`
  only, sha256 `aea1a765…`): the CRC helpers rewritten in old-style function
  form (the yosys `read_verilog -sv` frontend rejects `return` in functions)
  and a fixed 3-bit response-slot case replacing the `WIDTHTRUNC` 5-bit
  `resp_buf` index; plus `regress/synth_area.sh` now fails loudly on yosys
  errors (gotcha 13), and `info.yaml`/`pin_budget`/`signal_glossary`/wrapper
  header records were brought to the R1 map (19/24 committed, 5 free
  `ui_in`, 0 free `uio`).
- **A1 supersession (records updated):** the `uio[4]` echo is retired per the
  R0 pad ruling; its commit-latched and abort semantics live in the framed
  LOAD response (verified by `tb_pe_ctrl` cases 2/12/12b). The Task-2 A1
  verification above remains the historical record of the superseded
  interface.
- **OPEN FINDING (a) — P3 liveness gap:** the heartbeat pad is retired
  (`uo_out[1]` = IRQ_N) and the R1 STATUS layout deliberately omits
  timer/pc/a/x/y, so nothing shows liveness until the R2 read path lands.
  Recorded for the host-controller session / user; no protocol change made
  here.
- Next: implement the eth-tx plan in stages (plan Tasks 1-3, then 4-5, then
  6-7) on fresh worker context (`/new` at 43% after Task 9). No physical
  flow, DRC or LVS.

## Manager verification of eth-tx plan Tasks 1-5 (Manager Tasks 10-11) and
## the 2026-09-24 OOM forensics, 2026-09-25 early

- **Task 10 (plan Tasks 1-3)** landed and was recorded 2026-09-24 (STATUS /
  HANDOFF Task-10 blocks, SDD ledger). Its hash block is superseded by the
  Task-11 deltas below; the canonical hashes now live in the SDD ledger
  (`.superpowers/sdd/eth-tx-frame-path/progress.md`) and the fresh STATUS /
  HANDOFF top blocks.
- **Task 11 (plan Tasks 4-5)** landed in the tree 2026-09-24 18:21-18:43
  (wrapper G6 `uo_out[2]` mux `pin_oe_bus[7] ? pin_out_bus[7] : dbg_pc[0]`,
  reset bit-identical; pad-level TB decode 576 wire bits / FCS `9cc5cb34`;
  NEW `tb/tb_pe_soc_eth_loop.v` + four test firmwares; the wire loopback
  exchange `len=46 field=0806 sum=07`; two-frame IFG 102 cells; push-bank
  wrap `REG[24]=2a REG[26]=04`; start-while-busy `refused_start=1`; the
  push-gap limit 52 clk vs the 48-clk budget recorded as the plan's Task-5
  Step-2 trigger; and a real waveform defect the loopback caught and fixed —
  the engine's bit advance moved from the codec's `cell_en` to the cell
  boundary `cell_start`), but the implementing session was killed
  mid-verification **before any record was written**.
- **The kill: two kernel OOM events** (`journalctl -k`): 2026-09-24 14:33:40
  and 18:43:28, each `Out of memory: Killed process ... (python3)` with a
  runaway python3 at **22-23 GB anon RSS + ~5 GB swapped** inside the wezterm
  systemd unit's cgroup; systemd then failed the unit (`Failed with result
  'oom-kill'`) — the user's recurring dead-wezterm symptom. The 18:43:28
  event is the one that killed the Task-11 session (and the protocol/GUI
  sessions) mid-flight, leaving the tree unrecorded.
- **The red tree at manager verification was an UNRESTORED MUTANT, not a code
  defect.** Manager re-run of `./regress/run_all.sh --fast -j8` at 2026-09-25
  01:15 failed 3 of 33 (`tb_pe_pinmux` open-drain/arbitration,
  `tb_pe_soc_i2c` OD pins driven high, `tb_pe_soc_i2c_xfer` lost repeated
  START). Root cause by code review: `rtl/pe_pinmux.v` carried
  `assign pad_oe  = reg_oe;` with its open-drain gate gone — byte-exact
  output of `regress/mutate_i2c_tb.sh` mutation **m1** ("pe_pinmux: OD gate
  ignores od"), whose harness was running at 18:43 and died before its
  restore step (the harness's own comment warns about exactly this failure
  mode). Byte-exact pre-mutation snapshots survived in `/tmp/tmp.oxt87I4CGc`
  (harness PRISTINE) and `/tmp/tmp.Xde1jTGw8g` (case backup). The manager
  dispatched the restoration with the snapshot paths; the worker restored
  `rtl/pe_pinmux.v` **byte-identical** (sha256
  `c1fa0cec1cdc2ad04c6b9e97bc8ad4e6fdb0893e3fbda8256121ce7312949aef`,
  manager `cmp`-verified against both snapshots).
- **Fresh evidence (worker) + independent manager re-verification:**
  `./regress/run_all.sh --fast -j8` **exit 0** — RTL **33/33**, firmware
  **26/26**, lint clean, 12 generated gates, **ten mutation suites** (log
  `/tmp/run_all_mgr11_fix.log`; manager rerun `/tmp/mgr_verify2_run_all.log`);
  `./regress/synth_area.sh` **exit 0** — `pe_eth_tx` 892 / 16,040.0898 µm²,
  `pe_pinmux` 127 / 2,191.1904, `pe_soc` **6,219 / 108,084.8286**,
  `tt_um_top` **7,960 / 138,817.4004** (the pre-fix manager screen had
  `pe_pinmux` 111 / `pe_soc` 6,171 / `tt_um_top` 7,943 — the 16-cell
  difference is the restored OD gate); explicit reruns kept:
  `tb_pe_soc_eth_loop` PASS and `tb_tt_um_protocol_emulator` PASS.
- **Attribution note (worker's, adopted by the manager):** the `pe_soc`
  one-process set-beats-clear `tick_flag` code is byte-identical to git HEAD
  and **predates** the Task-11 dispatch; it is NOT a Task-11 delta (the only
  Task-11 `pe_soc` RTL edit is the `eth_cell_start` wire). Earlier manager
  notes that attributed it to Task 11 are corrected here.
- **Anti-recurrence mitigations deployed (2026-09-25, user orders):**
  `tools/manager/mem_monitor.sh` RAM watchdog (writes
  `/tmp/pi-mem-interrupt` at ~80% RAM; snapshots to
  `/tmp/pi-mem-snapshots/`; kills project-tooling runaways over 6 GB before
  they can OOM-kill wezterm), plus standing orders in
  `MANAGER-COLD-START.md` (always in the `sleep 1` interrupt loop; on a MEM
  interrupt **debug and fix**, never just report) and a dispatch convention
  to restore interrupted mutation runs from their surviving `/tmp/tmp.*`
  snapshots. The runaway python3's exact identity is **unconfirmed** (both
  OOM windows had GUI-bridge test activity; the watchdog will snapshot and
  identify it at the next occurrence).
- Limits: no `eth_tx` mutation suites yet (plan Task 6), no STA screen yet
  (plan Task 7). Mapped/simulation evidence only — no physical flow, DRC or
  LVS.
