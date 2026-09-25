# Host GUI phase 3 result — acceptance dry run (2026-09-25)

**Date entry (UTC):** 2026-09-25T06:47:06Z (`date -u +"%Y-%m-%dT%H:%M:%SZ"`).
**Branch:** `host-controller-gui` (base `153fbde`; phase 2 bridge at `c28234d`).
**Code commit:** `f6fdd65` (`test: add host controller board acceptance`).
**Result-doc commit:** `fdbeae9` (this file, HANDOFF.md and plan-review section 10).
**Scope:** plan Task 7 — the scripted acceptance runner and the no-hardware
`--fake` dry run. Step 3 (real Pico acceptance) remains hardware-gated;
`wiki/STATUS.md` was deferred (ruling below). No chip-side file was touched.

## What was built

| File | Role |
|---|---|
| `tools/host_bridge/acceptance.py` | One scripted sequence, two link modes. `--fake`: real `SerialTransport` + `ControllerSession` over the real `PicoBridge` against `FakeTTAdapter`/`FakePE` (never opens a device). `--device PATH`: the same sequence over USB CDC, with `--project` and `--board` labels. Reports per-step PASS/FAIL/SKIP plus a manifest, exits non-zero on any FAIL, and turns an unreadable device into the `dialout` hint instead of a traceback. |
| `tools/host_bridge/tests/test_acceptance.py` | 8 cases: the dry run passes with `open_serial` patched to fail if called, only `uart` skips, the chip fault path is exercised, a permission error carries the dialout hint, an open failure is reported rather than raised, and the CLI exit codes/flag exclusivity are pinned. |
| `tools/host_gui/tests/fixtures/acceptance.md` | Operator checklist: dry-run expected output, hardware prerequisites, and the fields a real run must record. |
| `README.md` | New "Host controller (USB -> Pico -> PE)" section: install/permissions, bridge deployment, 60 MHz clock and 5 MHz first-pass cap, the LOAD-forces-`run=0`/start-after-load sequence, acceptance commands, and the simulator/host/board/chip evidence levels. |

## Dry run (plan Task 7 Step 2)

```bash
$ python3 tools/host_bridge/acceptance.py --fake
Host controller acceptance - board: fake-adapter

  PASS open         fake SDK adapter + fake PE; no serial device opened
  PASS hello        v1 clock=60000000 sclk_max=5000000 pads={...}
  PASS prepare      state=PREPARED sclk<=5000000
  PASS sclk         negotiated 5000000 Hz; bridge applied 5000000
  PASS assemble     uart_echo.pe: 118 words, sha256 4ef87ef0bb7a56d5...
  PASS load         118/118 words, echo=0x4002, faults=0x0000
  PASS readback     118/118 words match the manifest
  PASS start        state=1 run=1
  PASS heartbeat    timer 0 -> 1
  PASS stop         state=STOPPED
  PASS dump         registers captured, words_written=118
  PASS irq          1 chip.irq event(s); PE fault still set (0x0001)
  PASS fault        faults=0x0001 state=FAULTED
  PASS clear_fault  faults=0x0000 state=STOPPED
  SKIP uart         no bridge op reports UART bytes; ...
  PASS disconnect   state=DISCONNECTED
  PASS reconnect    fresh session id=2, state=PREPARED

RESULT: PASS (16 PASS, 0 FAIL, 1 SKIP)
```

Wall time 0.087-0.092 s. The real-mode command was also run to prove the
failure path (pyserial is not installed and `/dev/ttyACM0` does not exist):

```bash
$ python3 tools/host_bridge/acceptance.py --device /dev/ttyACM0
  FAIL open  pyserial is required ... (install: pip install .[host-gui])
RESULT: FAIL (0 PASS, 1 FAIL, 0 SKIP)   # exit 1
```

## TDD evidence

- RED (before `tools/host_bridge/acceptance.py` existed):
  `python3 -m unittest tools.host_bridge.tests.test_acceptance` ->
  `ImportError: cannot import name 'acceptance' from 'tools.host_bridge'`
  -> `FAILED (errors=1)`.
- GREEN after implementation: 8/8, and the bridge suite 63/63 overall.
- The plan's direct-script command (`python3 tools/host_bridge/acceptance.py
  --fake`) needed a repository-root `sys.path` bootstrap because the module
  imports the `tools.*` packages; the CLI is verified in that exact form.

## Commands and results

```bash
$ python3 -m unittest discover -s tools/host_bridge/tests -v   # 63 tests
OK
$ python3 -m unittest discover -s tools/host_gui/tests -v      # 154 tests
OK (skipped=1)
$ python3 -m unittest tools.host_gui.tests.test_protocol -v   # 34 tests
OK
$ ruff check tools/host_gui tools/host_bridge
All checks passed!
$ python3 -m compileall -q tools/host_gui tools/host_bridge
(clean)
```

The one skip stays the phase-1b FastAPI route test on the system interpreter.

## Rulings

- **UART observation is SKIP, not PASS.** Plan Task 7 Step 3 wants observed
  UART bytes, but the Task 2 bridge contract has no op that reports them
  (`uo_out[0]` would need a Pico-side monitor). The runner marks `uart` SKIP
  with the reason rather than inventing bytes; the real run needs a bridge op
  or operator scope. Cost if wrong: a hardware acceptance that claims UART
  coverage with no contract behind it.
- **Hardware IRQ/fault/clear_fault are SKIP.** `IRQ_N`, the sticky fault
  register and `CLEAR_FAULT` are RTL phase R1; the adapter has no IRQ input
  until then. Fake mode exercises the whole path (scripted fault -> one
  `chip.irq` -> FAULTED -> `CLEAR_FAULT`). Cost if wrong: the real run cannot
  pass those steps until the chip work lands — which is the dependency anyway.
- **Heartbeat is scripted in fake mode.** `--fake` advances the fake PE timer
  (+1) between two STATUS reads so the runner's comparison logic is exercised;
  the detail string says so, and the real run must see chip movement. Cost if
  wrong: mistaking fake heartbeat for hardware liveness.
- **`wiki/STATUS.md` deferred to Task 8 / merge.** STATUS.md is the chip-side
  live backlog and the main worktree is actively dispatching against it
  (`git worktree list`: main at
  `/home/mylesp/janestreet-blog-serial-protocol-emulator`); editing it from the
  host branch risks a conflict for no host-side value. The status entry here,
  in HANDOFF.md and review section 10 stands in until then. Cost if wrong: one
  line to add at handoff.

## Limits

- **The real run (Step 3) has not been executed.** No Pico/USB/pyserial path
  was exercised; the only real-mode evidence is the failure path above.
- **`FakePE` is a model.** Readback/IRQ/fault evidence is fake-hardware
  evidence; chip-confirmed behavior needs RTL phases R1/R2 (chip-side, manager
  dispatch).
- **OOM watch (2026-09-25):** every run in this phase was short-lived
  (acceptance 0.09 s, largest suite 0.75 s) and bounded; the acceptance child
  peaked at 24.3 MiB RSS (`resource.RUSAGE_CHILDREN`). No long-lived python
  was spawned; a post-run `ps` showed only the unrelated system `wsdd` daemon
  and a chip-side check process from the main worktree.
- **Final review:** self-review (no subagent tool) of `f6fdd65` against plan
  Task 7; no Critical/Important findings after the ruff/noqa cleanup.

No testbench, RTL regression, synthesis, STA, physical flow, DRC or LVS was
run. This phase changes no RTL or firmware.
