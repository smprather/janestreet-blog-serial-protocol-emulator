# Host GUI R2 read-path prep — host side, not chip-confirmed (2026-09-25)

**Date entry (UTC):** 2026-09-25T07:24:40Z.
**Branch:** `host-controller-gui` at `c1fc916` (role-doc commit), base `153fbde`.
**Scope:** manager dispatch — "prepare R2 read-path integration on the host side
per plan Task 3-5: extend FakePE and the acceptance expectations for the read
ops the chip side will implement, clearly marked not-chip-confirmed, so
chip-side R2 can be validated end-to-end the moment it lands." No chip-side
change; this branch still touches no `rtl/`/`tb/`/`info.yaml` file. Proved
against the **fork point** (`git diff --name-only 153fbde..HEAD` = zero
chip-side files), not `main..HEAD`: `main` has since moved to `e77e7cb` (the
protocol-worker's eth-tx work), which makes that range show what main has that
this branch lacks.

## Manager RULINGs (settled 2026-09-25, applied in `264ce27`)

- **An out-of-range READ latches sticky `FAULT_RANGE`** (0x4), consistent with
  out-of-range writes; `CLEAR_FAULT` clears it. The model default is `latch`
  (the `status-only` parameter is kept only so the rejected behavior stays
  reachable in a test).
- **READ payload is low-word-first, ascending** — the same ascending stream
  LOAD uses: `READ_IMEM(a,n)` returns words `a..a+n-1` in order, `READ_DMEM(a,n)`
  packs bytes `a..a+n-1` big-endian per word.
- **Chaining happens within the same turn** (process fix): the interrupt file is
  the manager's async review trigger, not the end of work; a turn ends only on
  IDLE-QUEUE-EMPTY / QUESTION / BLOCKED. HANDOFF's role section was rewritten.

**What R2 is (chip side, not done):** plan Tasks 3-5 / review rows P16-P17 —
full-width CPU debug ports (PC/A/X/Y/insn, replacing the 8-bit `dbg_pc`/`dbg_a`
truncation), a `pe_imem` host read port, a SoC host-read mux with explicit
no-wrap range rejection (1024 words / 16 bytes), and chip-side read-while-running
rejection. That RTL is under the chip-repo manager's dispatch. **None of it is
on the chip; nothing below is chip-confirmed.**

## What this prep adds (all host-side)

1. **`tools/host_gui/r2_reads.py`** — the single source of truth for the R2
   read obligations. Seven obligations, each a named probe over the host
   `FakePE` model, each `chip_confirmed=False`, plus an explicit
   `NOT_CHIP_CONFIRMED` note: `read_imem_bounded`, `read_dmem_bounded`,
   `dump_core_header`, `read_cpu_non_halting`, `read_while_running_rejected`,
   `range_never_wraps`, `full_width_debug_regs`. `run_all_probes()` / `by_name()`
   are the entry points the acceptance runner (and, later, the chip TB) use, so
   host model / acceptance / chip TBs cannot drift on *what the read path owes*.
2. **`FakePE(read_fault_policy=...)`** — parameterizes the one read-contract
   question the plan leaves open: does an out-of-range **read** latch a sticky
   fault (`"latch"`, the historical default, kept so no existing test changes)
   or answer `RANGE` with no fault (`"status-only"`)? Write/load range faults
   still latch under both. The two open questions (this one, and the exact
   READ_CPU/READ_DMEM payload word order) are logged as WORKLOG `QUESTION`s for
   the chip side; the host does not presume either answer.
3. **Acceptance R2 checks** — `acceptance.py --fake` now runs five end-to-end
   read checks through the real host stack over the real bridge, every one
   tagged `[not chip-confirmed: ...]`: `r2_read_cpu` (the only read that must
   answer while running), `r2_read_imem` (last-word boundary address), `r2_read_dmem`
   (byte-addressed pattern), `r2_range` (read past the end must be `RANGE` and
   must not wrap; reports the model's fault policy and clears any latched fault
   so the script stays deterministic), `r2_dump_header` (dump_core header ==
   status header while stopped). On hardware before R2 these are *expected to
   fail* — they are the gate, not decoration.
4. **Docs** — acceptance checklist fixture and README record the new 21/0/1
   dry-run shape and point at `r2_reads.py`.

## Same-turn chain after the rulings (commits `a6f46c9`..`3790fc3`)

Once the rulings landed, the host side kept chaining within the turn:

- **`a6f46c9` — session-level `read_cpu()`.** `ControllerSession.read_cpu()`
  returns a typed `CpuSnapshot(pc,a,x,y,insn,state)`, full-width and
  **non-halting** (requires only a connected session), and the acceptance
  `r2_read_cpu` check now drives it instead of the raw transport.
- **`a0b3577` — `/api/read_cpu` route** (`Api.read_cpu` -> `{"cpu": {...}}`),
  with the FastAPI route exercised in the phase-1b venv.
- **`bbae976` — lifecycle gate.** `r2_range_fault_lifecycle` proves the ruled
  sticky-fault cycle end to end: bad read -> STATUS `faults=0x0004` + session
  `FAULTED` -> `CLEAR_FAULT` `0x0000` + `STOPPED`. The dry run is
  `PASS (22 PASS, 0 FAIL, 1 SKIP)`.
- **`e879290` — the page shows the live CPU header** (PC/A/X/Y/insn from
  `/api/read_cpu`, polled 1x/s while running).
- **`3790fc3` — closed the phase-2 open limit "IRQ latency while idle".** The
  Pico samples `IRQ_N` only when a host request unblocks its read loop, so an
  idle session never saw a fault. The page now keeps a 2 s status poll
  **whenever connected**; an integration test proves a stopped-session fault
  reaches the host as `chip.irq` and moves the session to `FAULTED` with
  `last_fault` retained.

Suite state at the end of the chain: host_gui 176 (system **and** venv),
bridge 67, r2 15, acceptance `--fake` `PASS (22/0/1)`, ruff clean, `node
--check` clean, compileall clean. TDD red->green for every task. No chip-side
file touched.

## Evidence

```bash
$ python3 -m unittest tools.host_gui.tests.test_r2_reads      # new, RED first
ImportError: cannot import name 'r2_reads'  ->  Ran 13 tests  OK
$ python3 -m unittest tools.host_bridge.tests.test_acceptance
Ran 10 tests  OK        # includes the 5 R2 dry-run checks)
$ python3 tools/host_bridge/acceptance.py --fake
  PASS r2_read_cpu    ... while running [not chip-confirmed ...]
  PASS r2_read_imem   address=117 count=1 -> 16386 [not chip-confirmed ...]
  PASS r2_read_dmem   model-seeded pattern read back: 0a0b0c0d [not chip-confirmed ...]
  PASS r2_range       read_imem failed with status 3; read-fault policy=latch [not chip-confirmed ...]
  PASS r2_dump_header dump_core header == status header while stopped [not chip-confirmed ...]
RESULT: PASS (21 PASS, 0 FAIL, 1 SKIP)
$ python3 -m unittest discover -s tools/host_gui/tests    # 167 (was 154 + 13 R2)
OK (skipped=1)
$ python3 -m unittest discover -s tools/host_bridge/tests  # 65 (was 63 + 2 acceptance)
OK
$ ruff check tools/host_gui tools/host_bridge            # All checks passed!
$ python3 -m compileall -q tools/host_gui tools/host_bridge   # clean
```

No regression: the earlier 154/63 suites grew only by the new cases; every
pre-existing test still passes. Probe design TDD: the R2 module and the
acceptance R2 checks were each written before the code and watched RED
(`ImportError` / missing-check `AssertionError`) then GREEN.

## Status when chip R2 lands

The same five acceptance checks and the seven `r2_reads` probes become the
end-to-end validation: run `acceptance.py --device /dev/ttyACM0`, flip
`chip_confirmed` to True per obligation **with the hardware run as evidence**,
and the chip TB (`tb_pe_host.v`, chip-side) covers the no-wrap/range and
read-while-running cases on real RTL. Until then every line here is
host-model evidence only.

## Rulings

- **A read range error's sticky-fault behavior is left to the chip, not decided
  in the model.** The plan's read step (line 334) requires `RANGE` + "do not
  wrap" but is silent on latching; the model parameterizes both so the host
  tests neither presume it. Cost if wrong: a one-line model default and the
  matching chip behavior move together once R2 defines it.
- **Acceptance R2 checks FAIL on hardware before R2** rather than skip. A host
  that skipped them would report PASS for a read path that does not exist. Cost
  if wrong: the first hardware run shows red on exactly the checks that are
  supposed to be red pre-R2.

## Limits

- The FakePE is a model; every probe is host-side. No R2 RTL exists, so nothing
  here is chip-confirmed (by design, and flagged on every line).
- Real-hardware acceptance still out of scope (needs hardware + R2).
- `read_cpu` in the acceptance goes through the session now (`a6f46c9`); the
  page shows the same header and polls it while running (`e879290`).
- A chip fault on an idle/stopped board is surfaced by the page's 2 s status
  poll while connected (`3790fc3`), because the Pico can only sample `IRQ_N`
  when a host request unblocks its read loop; the hardware run should still
  measure the end-to-end latency.
- One-command re-verify: `tools/host_gui/run_host_tests.sh` (`c24fd87`) runs
  every host gate — host_gui tests, host_bridge tests, ruff, compileall and the
  acceptance dry run — and is verified to fail on a real defect.
- **Branch base / merge note (manager's call).** The host branch forked at
  `153fbde`; `main` is now `e77e7cb`, so the branch is behind on chip files and
  `HANDOFF.md`, `README.md` and `wiki/STATUS.md` are edited on both sides and
  will conflict at merge. I have **not** rebased or merged: a rebase would
  rewrite the commit hashes already cited in `WORKLOG.md` and in these records,
  and the merge decision belongs to the manager. The host gates read no chip
  file, so they re-verify cleanly on this tree; after the merge the same
  `run_host_tests.sh` is the command to re-run.

## Same-turn chain log (WORKLOG-traceable)

Each entry was a separate commit, logged `TASK-START`/`TASK-DONE`/`CHAIN` in
`/home/mylesp/janestreet-blog-serial-protocol-emulator/WORKLOG.md` (actor
`gui-worker`), and ended with the interrupt-file rewrite that triggers the
manager's async review. `264ce27` rulings · `a6f46c9` session read_cpu ·
`a0b3577` API route · `bbae976` lifecycle gate · `e879290` page header ·
`3790fc3` idle-fault visibility · `1c5a969` records · `d233fe0` fail-fast gap ·
`c24fd87` one-command host gate.

Record: WORKLOG `QUESTION` lines carry the two contract questions to the chip
side; the host-side chain continues independently.
