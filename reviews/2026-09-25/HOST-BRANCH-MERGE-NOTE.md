# Host-branch merge note (for the chip manager) — 2026-09-25

**Ruling (b): the host-branch merge is deferred to the chip manager after chip
plan Task 7, and I have NOT rebased.** My commit hashes stay valid and are
cited in `WORKLOG.md` and in the host records. This note is the whole merge
instruction: three files conflict, every one of my regions is fenced with
`<!-- BEGIN/END gui-worker host block ... -->` comments, and each resolution is
"keep both sides" with a stated order. No chip-side content is edited or
dropped by this note.

State: host branch `host-controller-gui` (fork `153fbde`, tip `65d0f97`),
`main` at `e77e7cb`. Only these three files are edited on both sides;
everything else the host branch touches (`tools/host_gui/**`,
`tools/host_bridge/**`, `reviews/2026-09-2*/**`, `wiki/plans/host-controller-gui.md`,
`pyproject.toml`) is new or host-only and merges cleanly.

## 1. `HANDOFF.md` — two fenced blocks, both keep

My diff is two hunks; the chip side inserted its `## Operating role: Pi
Harness & RTL Hardening Steward` and `## Pi pane input check` at the same
top-of-file anchor, so hunk 1 will textually conflict.

- **Block A (top notes)** — fence: `gui-worker host block (top notes)`. It is
  the four dated host blockquotes (R2 prep, Task 8, phase 3, phase 2) directly
  under the title. **Resolution:** keep chip's role/pan-check sections first,
  then Block A immediately after them (or Block A first — either is fine; do
  not interleave the blockquote stack with the chip role sections). Nothing in
  Block A depends on position; it is a dated status stack.
- **Block B (role + chaining protocol)** — fence: `gui-worker host block (role
  + chaining protocol)`, the `## Session role: gui-worker` section. It sits in
  the middle of the file just above `## Resume after refactor review`.
  **Resolution:** keep it whole in place. It is self-contained (ownership,
  chip boundary, WORKLOG duty, chaining protocol, cold-resume) and reads fine
  next to the chip-side `## Operating role` at the top.
- Refresh before merge: Block A already carries current numbers (host_gui 187,
  bridge 73, acceptance 22/0/1). The older dated blockquotes are history on
  purpose — do not renumber them, they are the per-phase record.

## 2. `wiki/STATUS.md` — two fenced blocks, both keep

- **Block A (top note)** — fence: `gui-worker host block (top note)`, the
  `> **Host controller GUI + Pico bridge ...**` blockquote under the title.
  The chip side has its own top blockquote(s). **Resolution:** keep both
  blockquotes, host one directly after the chip top blockquote(s).
- **Block B (host tooling section)** — fence: `gui-worker host block (host
  tooling section)`, the `## Host controller GUI and Pico bridge (host side,
  branch host-controller-gui)` table (currently just above `## Area budget`).
  **Resolution:** keep the whole section; it is a standalone table with its own
  scope sentence ("This section describes the host branch; it is not a
  statement about main's chip state"), so it can sit anywhere in the document.
- The section's evidence column (176/67 → current 187/73, acceptance 22/0/1)
  is host-side only; after the merge the host manager re-runs
  `tools/host_gui/run_host_tests.sh` and updates those numbers in place.

## 3. `README.md` — one fenced block, both keep

- **Block** — fence: `gui-worker host block (host controller section)`, the
  `## Host controller (USB → Pico → PE)` section (install/permissions, bridge
  deployment, 60 MHz + 5 MHz cap, LOAD/start sequence, acceptance commands,
  evidence levels). The chip side edited Quick start / Layout (+20/-2). My
  section is a single insertion and the chip's Quick-start edits are in
  different lines. **Resolution:** if git conflicts, take the union: keep
  chip's Quick start exactly as it is on `main`, and place my fenced section
  after the Quick start block (before `## Layout`). The one line I added
  inside the Quick-start-adjacent area (`tools/host_gui/run_host_tests.sh` in
  the host code block) is inside the fenced block, not in the chip Quick
  start.

## How to verify the merge (host side, one command)

```bash
tools/host_gui/run_host_tests.sh          # every host gate; exit 0
python3 -m tools.host_gui.r2_vectors --check   # chip-side vector package not stale
grep -c "gui-worker host block" HANDOFF.md wiki/STATUS.md README.md   # 2 2 1
```

If the block count is not `2 2 1`, one of my fenced regions was dropped or
split — re-copy it from `host-controller-gui` before trusting the merge.

## What I did NOT do (deliberately)

- No rebase, no merge, no push, no branch deletion (ruling b; and a rebase
  would rewrite the hashes cited in `WORKLOG.md`).
- No edit to any chip-side file. `git diff --name-only 153fbde..HEAD` on the
  host branch adds zero `rtl/ tb/ sim/ firmware/ flow/ info.yaml regress/
  tools/fw/ tools/gen/ tools/checks/` paths.
- No change to the chip-side `wiki/STATUS.md` in the main worktree; the host
  STATUS block above is this branch's copy only.
