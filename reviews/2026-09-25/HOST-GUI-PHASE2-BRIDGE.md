# Host GUI phase 2 result — Pico bridge (2026-09-25)

**Date entry (UTC):** 2026-09-25T06:30:18Z (`date -u +"%Y-%m-%dT%H:%M:%SZ"`).
**Branch:** `host-controller-gui` (base `153fbde`; phase 1b code at `c12734e`).
**Code commit:** `c28234d` (`feat: add Pico USB SPI bridge`).
**Scope:** plan Task 2 — `tools/host_bridge/` (`pe_frame.py`, `tt_adapter.py`,
`main.py`, `tests/`) plus the shared-golden-vector half of
`tools/host_gui/tests/test_protocol.py`. The phase arrived written but
uncommitted and unrecorded after the 2026-09-25 01:06 interrupted edit; all
uncommitted work was preserved and committed as it stood, then verified.

## What was built

| File | Role |
|---|---|
| `tools/host_bridge/pe_frame.py` | MicroPython-sized frame codec: sync `A55A`, `{version,opcode,target}` header, sequence, 16-bit length, CRC-16/CCITT-FALSE, opcode/status/target constants, typed `FrameError`. |
| `tools/host_bridge/tt_adapter.py` | SDK HAL (`enable_project`, `set_clock`, `reset`, `set_run`, `configure_host_spi(sclk_hz)`, `host_spi_transfer`, `irq_n`). Owns `uio_oe_pico` (uio[4:7] direction), the CS_N idle level, and the 60 MHz project clock that is only ever started. No invented RP2040 pin default; `irq_n` returns `None` until RTL phase R1 exists. |
| `tools/host_bridge/main.py` | Newline-JSON USB endpoint: versioned id-echoed requests, typed errors, bounded line length, events (`board.reset`, `chip.status`, `chip.irq`, `spi.timeout`, `protocol.error`, `usb.disconnect`), framed SPI transactions with CS framing, LOAD-forces-`run=0`, start only after a successful LOAD, `run=0` gating for memory/dump, SCLK cap `min(5 MHz, clk/6)`. |
| `tools/host_bridge/tests/golden_vectors.json` | 4 CRC vectors + 6 frame vectors read by *both* `test_bridge.py` and `tools/host_gui/tests/test_protocol.py`, so the bridge codec and the host codec are checked against the same bytes. |
| `tools/host_bridge/tests/fakes.py` | `FakeTTAdapter` HAL double that routes bytes to the phase-1b `FakePE` chip model. |
| `tools/host_bridge/tests/test_bridge.py` | 43 cases: golden vectors, hello/prepare, LOAD echo/abort/1024 words, start/stop ordering, stopped-only reads, IRQ edge behavior, line-protocol errors, SCLK negotiation. |
| `tools/host_bridge/tests/test_tt_adapter.py` | 8 cases against a fake `ttboard`/`machine`: project/clock/reset/run calls, `uio_oe_pico` direction (firmware row preserved), CS_N idle/framing/release-on-error, IRQ polarity. |
| `tools/host_bridge/tests/test_host_integration.py` | 4 cases: real `SerialTransport` + `ControllerSession` over the real `PicoBridge` via the existing `LoopbackPort` — connect/load/start/status/stop/read/dump round trip, IRQ→event→FAULTED, run gating, SPI-timeout never a success. |

## What this session found in the interrupted tree (and fixed)

1. **Malformed argument types killed the bridge** — Task 2 Step 5 requires
   malformed input to be rejected "without killing the bridge". Any
   non-integer `hz`/`address`/`count`/`mask`/`target` raised `ValueError` or
   `TypeError` out of `handle_line` and out of the `serve_io` loop.
   Test-first:
   - RED: `python3 -m unittest tools.host_bridge.tests.test_bridge.TestProtocolLines.test_malformed_argument_types_do_not_kill_the_bridge -v`
     → `FAILED (errors=5)` (`ValueError: invalid literal for int()`,
     `TypeError: int() argument ... not 'NoneType'`).
   - Fix: `main._int_arg()` turns a wrong type into a typed `BridgeError`;
     all five ops use it.
   - GREEN: bridge suite 55/55.
2. **The concrete adapter had no test** — plan Task 2 Step 1 asks the fake to
   record `uio_oe_pico` calls, but the fake HAL sat one level below it.
   `tests/test_tt_adapter.py` now records the SDK surface. It was written
   against existing code (no first RED); in-memory mutation probes show the
   direction assertions bite: dropping CS_N output, MOSI output, SCK output,
   or failing to hand MISO back to input each fails the test.
3. **Host and bridge had only ever met each other's fakes** — the phase-1
   tests drive `FakeBridge` and this phase's tests drive `FakeTTAdapter`.
   `tests/test_host_integration.py` now runs the real `SerialTransport` and
   `ControllerSession` against the real `PicoBridge` over `LoopbackPort`.

## Commands and results

```bash
$ python3 -m unittest discover -s tools/host_bridge/tests -v
Ran 55 tests in 0.011s
OK

$ python3 -m unittest tools.host_gui.tests.test_protocol -v
Ran 34 tests in 0.005s
OK

$ python3 -m unittest discover -s tools/host_gui/tests -v
Ran 154 tests in 0.706s
OK (skipped=1)

$ ruff check tools/host_gui tools/host_bridge
All checks passed!

$ python3 -m compileall -q tools/host_gui tools/host_bridge   # exit 0, no output
```

The one skip is the phase-1b FastAPI route test (FastAPI is not installed in
the system interpreter; the phase-1b venv run covers that path). Full log:
`/tmp/host-bridge-verify.log`.

## Rulings (plan vs implementation)

- **`board.connected` is not an event line.** Plan Task 2 Step 5 lists it, but
  the connection signal is the synchronous `hello` response (protocol version,
  clock, SCLK cap, pads), which is what `ControllerSession.connect()` and the
  phase-1b `FakeBridge` already use. Cost if wrong: a future consumer that
  blocks on `board.connected` needs the event added on both sides.
- **The IRQ event is `chip.irq`, not `chip.fault`.** Plan Task 2 Step 1 says
  `chip.fault`; Step 5 and the phase-1b host contract say `chip.irq`; the
  implementation, the fake bridge and `session.process_events()` all use
  `chip.irq`. Cost if wrong: one rename across three modules.
- **IRQ is sampled between request lines.** `serve_io` polls `irq_n()` before
  each blocking `readline`, so an idle session delivers a chip IRQ when the
  host next sends a request; there is no interrupt-driven stdin wake in v1
  (recorded under limits; fixing it needs hardware to verify).
- **The bridge does not enforce the 1024-word cap.** The host image layer
  refuses oversize images (phase 1a); the bridge forwards and the chip is
  expected to answer RANGE. Cost if wrong: a non-GUI client could send more
  words and rely on chip-side rejection.

## Known limits (honest scope)

- **Real Pico/USB is unverified.** No serial device was opened; `open_serial`
  and the pyserial path have never run against hardware. The MicroPython
  deployment (SDK version, flat-file import of `pe_frame`/`tt_adapter`,
  `machine.SPI` pin mapping, RP2040 vs RP2350 GPIO numbers — plan Open Item 2)
  is reviewed by inspection only. `from __future__ import annotations` and
  PEP 604 unions in `tt_adapter.py`/`main.py` are a MicroPython compatibility
  assumption, not a measured fact.
- **Chip-side behavior is out of scope.** RTL phases R1 (protocol engine, IRQ,
  target 1) and R2 (read path) are under the chip-repo manager; `FakePE` is a
  model, so every "chip-confirmed" claim here is fake-hardware evidence only.
  No `rtl/`, `tb/`, `info.yaml` or regression file was touched.
- **IRQ latency while idle** is poll-driven as described in the rulings; the
  hardware acceptance run (plan Task 7) should measure it and add a stdin
  poll/select loop if instant delivery is required.
- **Deferred minor (phase-1b host, cross-layer observation):** a bridge
  `ok=false` (e.g. an SPI timeout during `load`) raises `SessionError` but
  leaves `ControllerSession` in `LOADING` until the next successful
  `status()`; it is never reported as success, and the phase-1b suite has no
  failing case for it. Not changed here to keep this phase to Task 2.
- **SDK-level failures during `hello`/`prepare` are fail-fast.** A missing
  project or pin map raises out of the serve loop instead of answering
  `ok=false`; only the SPI transfer path has typed errors.
- **Final review:** self-review (no subagent tool in this session) of the
  phase diff at `c28234d` against plan Task 2 and the phase-1b host contract;
  no Critical/Important findings remain after the three fixes above.

No testbench, RTL regression, synthesis, STA, physical flow, DRC or LVS was
run. `regress/run_all.sh` was intentionally not run: this phase changes no RTL
or firmware, and the chip-side regression is under the manager's dispatch.
