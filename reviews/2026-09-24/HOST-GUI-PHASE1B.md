# Host GUI phase 1b result — 2026-09-24

**Date entry (UTC):** 2026-09-24T19:07:55Z (`date -u +"%Y-%m-%dT%H:%M:%SZ"`).
**Branch:** `host-controller-gui` (base `153fbde`, the phase 1a contract layer).
**Code commit:** `c12734e` (`feat: add host transport, session, server and fake PE`).
**Scope:** plan Task 6 (transport, session, server, first page) plus a fake-PE
backend for host-side testing. Test-first; the phase 1a 55-case suite stays
green and is extended.

## What was built

| File | Role |
|---|---|
| `tools/host_gui/transport.py` | Newline-JSON USB CDC transport: versioned requests (`v`, monotonic `id`, `op`, `args`), id-echoed responses, queued async events, typed errors (`TransportTimeout`, `TransportClosed`, `TransportProtocolError`, `BridgeCommandError`), bounded event queue, abandoned-id tracking so a late response can never satisfy the next request. pyserial imported only in `open_serial()`. |
| `tools/host_gui/fake_pe.py` | `FakePE`: in-memory 1024×16 IMEM / 16-byte DMEM chip model speaking the framed protocol via `protocol.py` — LOAD (words-written + fault bits + echo), STATUS, READ_CPU, READ_IMEM, READ_DMEM, DUMP_CORE, CLEAR_FAULT, TARGET + deterministic loopback target 1, status codes 0–6, `run=0` gating, BAD_FRAME salvage responses with latched CRC/protocol faults. `FakeBridge`: newline-JSON op surface + `board.reset`/`chip.irq`/`chip.status`/`protocol.error` events. |
| `tools/host_gui/session.py` | `ControllerSession` state machine (DISCONNECTED→PREPARED→LOADING→LOADED→RUNNING→STOPPED, FAULTED), typed `LoadResult`/`StatusSnapshot`/`CoreDump`, gating per plan Task 6 Step 3, fresh transport + request ids per reconnect, last status/fault preserved across disconnect, `negotiate_sclk()` enforcing `hello.sclk_hz_max`. |
| `tools/host_gui/server.py` | Dependency-free `Api` request logic + `resolve_source` (bare `.pe` name inside the configured sources dir; traversal/absolute/non-`.pe` rejected), optional FastAPI `create_app` and uvicorn `serve`; loopback bind, no arbitrary paths. |
| `tools/host_gui/web/{index.html,app.js,style.css}` | First operator page: status panel (state/session/SCLK cap/chip/run/words/faults), source picker, connect→load→start→stop→dump rail, `load-progress` bar, manifest (words/digest/terminal-jump warning), event feed. |
| `tools/host_gui/board.py` | R0 constants encoded: `HOST_SPI_PADS = {cs_n:4, mosi:5, miso:6, sck:7}`, `SCLK_GUARD_HZ = 5 MHz`, `PE_CLOCK_HZ = 60 MHz`. |
| `pyproject.toml` | Optional `[project.optional-dependencies] host-gui = [fastapi, uvicorn, pyserial]`; core tools stay dependency-free. |

Test helpers live in `tools/host_gui/tests/fakes.py` (`FakeClock`,
`ScriptedPort`, `FaultyPort`, `LoopbackPort`, `StubTransport`), so no test
needs pyserial, a board, FastAPI or a real clock.

## TDD evidence

1. **RED (before any phase 1b production module existed)** — each new module's
   tests were written first and run:

   ```
   python3 -m unittest tools.host_gui.tests.test_transport   # FAILED (errors=1): cannot import name 'transport'
   python3 -m unittest tools.host_gui.tests.test_fake_pe     # FAILED (errors=1): cannot import name 'fake_pe'
   python3 -m unittest tools.host_gui.tests.test_session     # FAILED (errors=1): cannot import name 'session'
   python3 -m unittest tools.host_gui.tests.test_api         # FAILED (errors=1): cannot import name 'server'
   ```

2. **GREEN (after implementation)**:

   ```
   $ python3 -m unittest discover -s tools/host_gui/tests
   Ran 152 tests in 0.666s
   OK (skipped=1)
   ```

   152 = 55 phase-1a cases + 97 phase-1b cases; the one skip is the FastAPI
   route test because FastAPI is not installed in the system interpreter.

3. **Optional-dependency path actually exercised** in a throwaway venv
   (`/tmp/hostgui-venv`, `pip install fastapi uvicorn httpx pyserial`):

   ```
   $ /tmp/hostgui-venv/bin/python -m unittest discover -s tools/host_gui/tests
   Ran 152 tests in 0.762s
   OK (skipped=2)
   ```

   In the venv the FastAPI route test runs (and passes) while the
   no-pyserial/`create_app`-without-fastapi checks skip; in the system
   interpreter the skips are reversed. Both sides of the optional-dependency
   boundary are therefore verified, not just declared.

4. **Lint/compile**: `ruff check tools/host_gui` → `All checks passed!`;
   `python3 -m compileall -q tools/host_gui` → clean.

5. **Server smoke** (venv, `fastapi.testclient`): `GET /` → 200 containing
   `load-progress`; `GET /app.js` → 200 containing `/api/load`;
   `GET /style.css` → 200; after `POST /api/load {"source":"uart_echo.pe"}` the
   WebSocket `/api/events` delivered `chip.status` with `words_written = 118`,
   `/api/status` reported the same, and `/api/dump` returned the register
   header. A real `uvicorn` boot on `127.0.0.1:8765` served `/api/health` and
   the page before being stopped.

## R0 decisions baked in (review section 8)

- **Pad mapping (plan wins):** `uio[4]=CS_N`, `uio[5]=MOSI`, `uio[6]=MISO`,
  `uio[7]=SCK`; the A1 raw echo on `uio[4]` is superseded. Encoded in
  `board.HOST_SPI_PADS`, reported in `hello.pads`, asserted by
  `test_fake_pe.test_hello_reports_version_clock_cap_and_plan_pads` and
  `test_session.TestBoardDecisions`.
- **A1 semantics transferred:** the per-word echo is the fake's
  `committed_words` log (tests assert every committed word), the final-word
  echo is the fourth LOAD response word (full-1024 case included), and a
  run-abort word is never committed, never counted and never echoed
  (`aborted word` tests). An aborted load never marks the session loaded.
- **5 MHz is the host guard, carried by the protocol:** `hello.sclk_hz_max`
  reports `board.SCLK_GUARD_HZ`; `session.negotiate_sclk()` rejects anything
  above the negotiated cap (`test_negotiate_sclk_never_exceeds_cap`).
- **Terminal rule (review row P23):** unchanged from phase 1a — a backward
  unconditional JMP; warned, not required.
- **Decisions taken while implementing (recorded here, not in the plan file):**
  - `LOAD` while `run=1` answers `STATUS_NOT_READY` with no fault (a clean
    sequencing rejection, not a fault), mirroring the plan's open item 4.
  - Clearing a fault after an **aborted** load returns the session to
    `PREPARED`, not `STOPPED`: an aborted image is not a valid program
    (`test_clear_fault_after_aborted_load_returns_to_prepared`).
  - READ_CPU stays non-halting; READ_IMEM/READ_DMEM/DUMP_CORE require
    `run=0`, matching the plan's explicit gating list and the shared
    `pe_imem` read port cost noted in `wiki/plans/pe-ctrl-readback.md`.

## Known limits (honest scope)

- The fake is a model, not evidence about silicon; the real bridge/Pico and
  the RTL phases R1/R2 remain open (see the review's RTL-change list).
- FastAPI route tests are skipped on the system interpreter by design; the
  venv run is the evidence for that path.
- The page's WebSocket fallback only engages when the WebSocket cannot be
  constructed; fine for the skeleton, revisit when the real bridge lands.

No testbench, RTL regression, synthesis, STA, physical flow, DRC or LVS was
run. No `rtl/*` or shared-worktree file was touched.
