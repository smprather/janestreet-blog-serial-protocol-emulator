# Host GUI Task 8 result — final verification, host scope (2026-09-25)

**Date entry (UTC):** 2026-09-25T06:52:20Z (`date -u +"%Y-%m-%dT%H:%M:%SZ"`).
**Branch:** `host-controller-gui` at `0681175` (phase 3 pin), base `153fbde`.
**Scope:** plan Task 8 for the **host stack**, plus the two record items the
Task 7 ruling postponed: the host-side `wiki/STATUS.md` entry (this branch's
copy only) and the plan-status roll-up. Real-hardware runs stay out of scope.
No chip-side file was touched; `main` was not checked out or modified by this
worktree.

## Task 8 steps, host scope

| Step | Plan command | Result |
|---|---|---|
| 1 | `python3 -m unittest discover -s tools/host_gui/tests -v` | `Ran 154 tests ... OK (skipped=1)` |
| 1 | `python3 -m unittest discover -s tools/host_bridge/tests -v` | `Ran 63 tests ... OK` |
| 2 | `./regress/run_all.sh --fast -j8` | **deferred to the chip manager** (ruling below) |
| 3 | `./regress/synth_area.sh` | **deferred to the chip manager** (ruling below) |
| 4 | `git status --short --branch && git diff --check && git log --oneline -10` | clean branch, no whitespace errors, log is the host-plan history |

Supplementary host evidence (fresh, same tree):

```bash
$ python3 -m unittest tools.host_gui.tests.test_protocol
Ran 34 tests ... OK
$ ruff check tools/host_gui tools/host_bridge
All checks passed!
$ python3 -m compileall -q tools/host_gui tools/host_bridge
(clean)
$ python3 tools/host_bridge/acceptance.py --fake        # exit 0
RESULT: PASS (16 PASS, 0 FAIL, 1 SKIP)
$ python3 tools/host_bridge/acceptance.py --device /dev/ttyACM0   # exit 1
RESULT: FAIL (0 PASS, 1 FAIL, 0 SKIP)   # the open() failure path
```

Logs: `/tmp/task8-step1.log`, `/tmp/task8-rest.log`, `/tmp/acc-final.txt`,
`/tmp/acc-dev.txt`.

**Optional-dependency boundary, re-closed this dispatch** (the one standing
skip): the phase-1b venv still exists with fastapi/uvicorn/pyserial, and both
suites were run in it —

```bash
$ /tmp/hostgui-venv/bin/python -m unittest discover -s tools/host_gui/tests
Ran 154 tests ... OK (skipped=2)      # the FastAPI route test runs here
$ /tmp/hostgui-venv/bin/python -m unittest discover -s tools/host_bridge/tests
Ran 63 tests ... OK
```

The two venv skips are the dependency-absent checks (no-pyserial and
`create_app` without FastAPI) that the system interpreter runs; the system run
skips the FastAPI route test. Both sides of the boundary are therefore
exercised, not merely declared.

## No chip-side changes (Task 8 Step 4, proved)

`git diff --name-only main..HEAD` lists **41** files, all of them under
`tools/host_gui/`, `tools/host_bridge/`, `reviews/`, `wiki/plans/host-controller-gui.md`,
`wiki/STATUS.md` (this branch's copy), `README.md`, `HANDOFF.md`, or
`pyproject.toml`. A filter for `rtl/`, `tb/`, `sim/`, `firmware/`, `flow/`,
`info.yaml`, `regress/`, `tools/fw/`, `tools/gen/`, `tools/checks/` returns
**nothing**. `git worktree list` shows `main` checked out in
`/home/mylesp/janestreet-blog-serial-protocol-emulator` (at `4f3a4fa`) and this
worktree on `host-controller-gui`.

## The deferred record items, done here

1. **`wiki/STATUS.md`** — a top blockquote in the resume-here stack and a
   standalone `## Host controller GUI and Pico bridge (host side, branch
   host-controller-gui)` section with the five host pieces, their evidence, and
   an explicit "nothing here is chip-confirmed yet". This is the **host
   branch's** copy; the chip-side `wiki/STATUS.md` in the main worktree was not
   touched, as the dispatch requires.
2. **Plan-status roll-up** — `reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md`
   section 11 now carries the per-task state table (Tasks 1/2/6/7/8 done on the
   host side; 3/4/5 open chip-side), the final numbers, and the open items.

## Rulings

- **Task 8 Steps 2–3 (chip regression and synthesis screening) are the chip
  manager's, not this branch's.** The manager's own dispatch re-verify
  (`regress/run_all.sh --fast -j8`) was already running in the main worktree
  while this was recorded, and the host branch carries no chip RTL, so a second
  heavy run here would contend for CPU/RAM and would only re-prove the
  pre-dispatch RTL that the chip phases are about to replace. Host-only changes
  cannot affect a Verilog regression, and `git diff` proves the host branch
  touches no file any regression reads. Cost if wrong: two heavy runs
  serialized instead of one; the evidence is reproducible on request.
- **Plan Task 8 is not "the plan is complete".** The plan's acceptance criteria
  (real USB connect, chip readback, IRQ on hardware) depend on Tasks 3–5, which
  are chip-side. This record closes the host scope only; the plan stays open.
- **Branch merge is the manager's call.** The finishing-a-development-branch
  menu (merge / push-PR / keep) was not exercised: the dispatch says stop and
  report, the main worktree is mid-verification, and a merge would touch the
  shared branch state. The branch and worktree are preserved for that decision.
  Cost if wrong: none; every commit is on `host-controller-gui` and unreferenced
  from anywhere else.

## Limits (unchanged from phases 2–3)

- The real Pico/USB/pyserial acceptance has not been run (hardware-gated).
- `FakePE` is a model; every readback/IRQ/fault claim is fake-hardware
  evidence, not chip evidence.
- The `--fake` heartbeat is a scripted timer step; only the real run can show
  chip liveness.
- OOM watch: this dispatch ran only the host suites (each < 1 s), the two venv
  suites, ruff, compileall and the acceptance runner; all were short-lived
  processes, no new long-lived python, and the heavy chip regression was left to
  the manager's already-running job.

## Final review

Self-review (no subagent tool) of the host branch's Task 8 changes: the STATUS
section, the review roll-up and this record are documentation only; the host
code is unchanged since `f6fdd65`/`0681175`, which were verified green before
this dispatch. No Critical/Important findings.

No testbench, RTL regression, synthesis, STA, physical flow, DRC or LVS was run
in this worktree.
