# Cold-start instructions

## Message to the next manager

You are the **Pi Harness & RTL Hardening Steward** for
`/home/mylesp/janestreet-blog-serial-protocol-emulator`.

Start by reading `HANDOFF.md`, `reviews/2026-09-23/PROJECT-REVIEW.md`, and
`wiki/STATUS.md`. Continue the user's persistent task: check the live Pi harness
in the shared tmux window `pi-protocol-worker` every 15 minutes (use window
names, not pane IDs — names survive an OOM or terminal loss), review completed
RTL/hardening work,
and keep the project review and handoff current. The user allows occasional
synthesis and STA screens to catch RTL that cannot be hardened. Slow corner is
also a hold-check corner. Never run physical flow, DRC, or LVS.

The default tmux server and worktree are shared live state. Never kill the tmux
server. Inspect `git status` before editing; substantial uncommitted work is
present. Do not reset, revert, or clean it. Leave Pi at its prompt after each
task. The user delegated ALL project decisions to the manager (2026-09-24):
nothing is waiting on user choices; implement the tasks the manager assigns.
The one boundary: host-controller GUI/bridge work waits for the user's plan
from their separate session.

Interrupt protocol (2026-09-24): as your LAST action before ending any turn,
write `/tmp/pi-worker-interrupt` containing a concise summary of what you did
and its evidence. Mid-task, write `QUESTION: <text>` there (and keep working)
or `BLOCKED: <text>` (and stop at your prompt). The manager deletes the file
before each dispatch and wakes on its appearance.

## Continuous work protocol (user standing order 2026-09-25: "I don't want
to come back and find nobody working")

- The queue is the source of work: `wiki/STATUS.md` "Next steps (ordered)",
  the current checkpoint queue in this file, and any dispatch message.
- **CHAIN TASKS.** When you finish a task and the queue holds a
  clearly-scoped next task inside the manager-adopted plans (no new design
  decision or ruling needed — the user delegated ALL project decisions to
  the manager), START IT IMMEDIATELY after writing your interrupt file. Do
  not idle at the prompt waiting to be told. One task at a time; each task
  ends with `/tmp/pi-worker-interrupt` rewritten as its last action (concise
  summary + evidence + hashes).
- STOP chaining and wait for the manager only when: the next step is
  ambiguous or needs a design/ruling decision, it touches the host-controller
  boundary (write `BLOCKED:`), the queue is empty, or the dispatch explicitly
  says stop.
- If your input box contains unexpected text when a turn ends, treat it as a
  possibly-mangled mid-turn dispatch from the manager: surface it in your
  interrupt (`QUESTION:`) instead of ignoring it.
- Throughput discipline: prefer whole plan tasks per dispatch; keep the tree
  green at every task boundary (mutation harnesses must restore and
  `cmp`-verify before you move on); never reset/revert/clean the shared
  uncommitted worktree.
- **Shared worklog (user standing order 2026-09-25):** append EVERY state
  change to `WORKLOG.md` in the repo root — one line,
  `YYYY-MM-DD HH:MM TZ | protocol-worker | EVENT | detail`, newest at the
  bottom, append-only. Events: `TASK-START`, `TASK-DONE`, `CHAIN`,
  `QUESTION`, `BLOCKED`, `RULING`, `STALL` (+ the exact reason),
  `CONTEXT-NEW` (after a `/new`). The log is the manager's debugging paper
  trail: when work stops, the manager back-traces it here and fixes the
  cause. Log the START of a task the moment you begin it — not only the
  finish — so a stall mid-task is visible.

## Current checkpoint — 2026-09-24 evening (supersedes the checkpoints below)

- The user delegated every project decision to the manager ("no pending my
  authorization at all; drive the project to completion without my
  intervention"). Decisions made and executed: E2-6 fix (CLOSED), readback =
  A1 (verified), SERDES+codec integration = the recorded recommended defaults
  (Task 3, verified), closeout hardening (Task 4, verified), squarer diagram
  layout (Task 5a, verified), hold-screen attribution (Task 5b, verified).
  GUI planning is the user's in a separate session.
- The worker runs in the shared tmux window **`pi-protocol-worker`** (created
  2026-09-24 after a wezterm OOM killed the old `%46` pane). Use window
  names, not pane IDs — names survive an OOM or terminal loss, pane IDs do
  not. Target the worker as `tmux ... -t 0:pi-protocol-worker`.
- Task 1 (E2-6 + R3 checker fixes): DONE and manager-verified — macro harness
  26/26 re-run, identity-logic code review, full regression exit 0. E2-6 and
  R3 are CLOSED; R1/R4/R5 remain recorded observations.
- Task 2 (A1 readback, `uio[4]` echo): DONE and manager-verified —
  `./regress/run_all.sh --fast -j8` 29/29 + 20/20 exit 0; mapped `pe_ctrl` STA
  screen worst setup +8.71/+8.80/+8.86 ns, worst hold −0.12/−0.16/−0.19 ns
  (unchanged from pre-A1), new echo/`spi_miso` max-path groups
  +12.09/+12.19/+12.23 ns. Evidence: `reviews/2026-09-24/`
  (`PE-CTRL-READBACK-REVIEW.md`, `manager-a1-sta/`). Baselines now: `pe_ctrl`
  463 cells / 8,661.30 µm², `pe_soc` 3,571 / 56,816.88 µm², `tt_um_top`
  4,038 / 65,686.27 µm².
- Task 3 (SERDES + codec integration, STATUS item 7): DONE and
  manager-verified (30/30 RTL, 21/21 firmware, ten mutation suites;
  `pe_soc` 4,961 cells / 82,893.77 µm², `tt_um_top` 5,363 / 91,268.06 µm²).
- Task 4 (closeout hardening: SERDES mapped STA refresh + codec mutation
  suite): DONE and manager-verified —
  `reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md`.
- Task 5a (squarer diagram layout, both maps): DONE — plan 3194×2476
  (1.29:1), progress 3681×2493 (1.48:1);
  `reviews/2026-09-24/DIAGRAM-SQUARER-LAYOUT.md`.
- Task 5b (hold-screen attribution + BOARD-assumption STA variants): DONE —
  `reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md`.
- Post-restart progress (2026-09-24 evening): Task 6 (5a/5b docs catch-up)
  DONE; Task 7 (eth-tx plan `wiki/plans/eth-tx-frame-path.md`, eight scope
  groups with defaults) DONE and the manager ADOPTED G1-G8; Tasks 8-9
  reconciled and verified the unrecorded chip-side host-protocol phase R1
  from the separate host-controller session (audited against its
  `HOST-CONTROLLER-PLAN-REVIEW` in the read-only
  `/tmp/opencode/host-controller-gui`; the A1 `uio[4]` echo is retired per
  the R0 pad ruling, its commit-latched/abort semantics live in the framed
  LOAD response; R1 pad map = `uio[4:7]` host row, `uo_out[1]` IRQ_N,
  `ui_in[3:5]` freed, 19/24 committed); lint, full regression (30/30 RTL,
  21/21 firmware, ten mutation suites), the 29/29 ctrl suite and synth are
  green after two manager-authorized behavior-preserving `pe_ctrl` fixes.
  Queue status (manager update 2026-09-25 ~01:55 CDT): plan Tasks 1-5 are
  LANDED and recorded (Manager Tasks 10-11; see the manager section in
  `reviews/2026-09-23/PROJECT-REVIEW.md`). The tree is GREEN (33/33 RTL,
  26/26 firmware, ten mutation suites). The 2026-09-24 18:43 kernel OOM
  (runaway python3, 22 GB) killed sessions mid-task and left an unrestored
  `mutate_i2c_tb.sh` m1 mutant in `rtl/pe_pinmux.v` — restored byte-exact
  from the harness snapshot. Next: plan Task 6 (eth_tx mutation suites),
  then plan Task 7 (STA + closeout), then final closeout. A RAM watchdog
  (`tools/manager/mem_monitor.sh` -> `/tmp/pi-mem-interrupt`) now guards the
  box; manager standing orders: always stay in the interrupt loop, and on a
  MEM interrupt debug and fix. The SDD ledger
  .superpowers/sdd/eth-tx-frame-path/progress.md is the task-level record.
  OPEN FINDING (a): the P3 heartbeat
  liveness gap — the heartbeat pad is gone and the R1 STATUS layout omits
  timer/pc/a/x/y, so nothing shows liveness until the R2 read path. STATUS
  item 8 GUI implementation awaits the user's plan.

## Checkpoint archive — 2026-09-23 evening (historical, superseded above)

- Pi pane `%46` returned to its prompt; last checked at 22:55 CDT, with the
  next 15-minute check due around 23:10 CDT. `wiki/STATUS.md` has no ungated
  implementation task: item 8 awaits acceptance; the readback and SERDES plans
  still need the user's choices; E2-6 awaits a decision to authorize its fix.
- Pi's draft for the Linux demo-host GUI is in `wiki/plans/demo-host-gui.md`
  (STATUS item 8 remains TODO pending user acceptance). It describes the Linux
  PC → RP2040 Pico on the Tiny Tapeout dev board → ASIC path. The Pico/RP2040 is
  the user's selected controller. PC-to-board USB/serial/HID transport remains
  hypothetical until verified. The loader SCLK cap follows `clk/6`, so 10 MHz
  is valid only at the 60 MHz operating point; the plan retains the
  sky130-framed clock-spec caveat. The seven generated-document checks passed
  explicitly by name in this session. The source/claim audit is complete and
  recorded in `reviews/2026-09-23/PROJECT-REVIEW.md` and `HANDOFF.md`.
- Pi independently exercised the E2 macro-flow checker with synthetic
  fixtures. The mutation harness reports 20/20, but this does not close the
  residual observations R1–R5 in the project review. The false pass is tracked
  as **E2-6 / R2**:
  macro type `RM_IHPSG_FAKE_B` has a 100×100 LEF and is placed at (20, 0) in a
  50×50 die, but its config points to type A's 10×10 LEF. The checker measures
  the configured file's `SIZE` without verifying that its `MACRO` declaration
  matches the configured macro type, so it accepts the invalid placement.
  Other confirmed gaps: stale PDN entries for absent instances are ignored
  (R1); wildcard liberty coverage and corner-key/file mismatches pass (R3);
  supply-pin names are hard-coded (R4); and legal alternate instance regex
  spellings are rejected (R5, fail-closed). A `-grid stdcell` PDN-connect
  probe is correctly rejected. No E2 fix was applied.
- Do **not** report E2 as fully closed. Pi recorded the GUI-plan audit and E2
  findings in `HANDOFF.md` and `reviews/2026-09-23/PROJECT-REVIEW.md`. A
  suggested next fix is to match each LEF's `MACRO` name to its configured type
  and add a regression mutation. Keep all E2 findings open until corrected and
  independently verified.
- Existing E1 evidence is recorded in
  `reviews/2026-09-23/E1-PUBLISHED-OWNERSHIP-REVIEW.md` and
  `reviews/2026-09-23/e1-published-ownership/`. Prior notes report the full fast
  regression and 30/30 MAC mutation results, plus mapped Yosys/OpenSTA screens;
  these are not physical signoff. At 22:53 CDT, mapped synthesis and three
  corner OpenSTA were rerun: synthesis counts unchanged, setup 0.00 ns, hold
  −0.87/−0.61/−0.48 ns slow/typ/fast. Fresh STA output was byte-identical to the
  recorded exact-source reports. Logs: `/tmp/e1-refresh-20260923/`.

## Pasteable short prompt

> Continue as the Pi Harness & RTL Hardening Steward. Read `COLD-START.md`,
> `HANDOFF.md`, `reviews/2026-09-23/PROJECT-REVIEW.md`, and `wiki/STATUS.md`.
> The user delegated all project decisions to the manager; implement the tasks
> the manager assigns and CHAIN into the next scoped queue item without
> idling (see the Continuous work protocol below), and
> write `/tmp/pi-worker-interrupt` (summary, or
> `QUESTION:`/`BLOCKED:` + text) as your last action before ending a turn.
> Preserve the shared uncommitted worktree. You run in the tmux window
> `pi-protocol-worker` (use window names, not pane IDs). Tasks 1-5b are
> landed and manager-verified (E2-6/R3 fixes, A1 readback, SERDES+codec
> integration, closeout hardening, diagram layout, hold attribution); the
> current queue is in `COLD-START.md`'s checkpoint. Synthesis/STA screens are
> allowed; physical flow, DRC and LVS are prohibited.
