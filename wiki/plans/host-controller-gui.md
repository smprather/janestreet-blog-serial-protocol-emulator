---
title: Host controller GUI and PE host-control bus
created: 2026-09-24
updated: 2026-09-24
type: plan
tags: [plan, host-controller, pico, usb, spi, debug, gui]
sources: [wiki/STATUS.md, HANDOFF.md, rtl/pe_ctrl.v, rtl/pe_soc.v, rtl/pe_imem.v, rtl/pe_cpu.v, rtl/tt_um_protocol_emulator.v, tools/fw/peasm.py, tools/fw/peemu.py, regress/run_firmware_tests.sh, regress/run_all.sh, wiki/decisions/adr-007-pe-ctrl-passive-slave.md, wiki/reference/protocol-pin-budget.md, wiki/reference/clock-arithmetic.md]
confidence: high
---

# Host Controller GUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Linux host GUI that connects over USB to a Tiny Tapeout Pico bridge, loads and controls the protocol-emulator ASIC through a bidirectional SPI host port, reports chip-originated status and faults, and supports read-only core and memory dumps.

**Architecture:** The operator uses a local browser UI served by a Python process. That process speaks a versioned line protocol to a MicroPython bridge on the Pico over USB CDC. The Pico uses the Tiny Tapeout SDK to select the shuttle, own reset and the 60 MHz project clock, and drive the PE SPI slave. The PE exposes a framed command/response protocol on the lower PMOD SPI row, returns status and readback data over MISO, and asserts a dedicated IRQ line for sticky faults. An internal target selector permits a second on-chip SPI target without consuming another physical bus.

**Tech Stack:** Python 3.12+ host tooling, FastAPI/uvicorn and pyserial as optional GUI dependencies, vanilla HTML/CSS/JavaScript, MicroPython using the Tiny Tapeout `tt` SDK and PIO/SPI support, Verilog RTL, Icarus, Verilator, Yosys, and the existing shell regression harness.

**Spec:** This document is the approved host-controller handoff and implementation contract. The earlier source draft is `wiki/plans/demo-host-gui.md`; the decisions below supersede its open transport, status, pin, and second-channel choices.

## Global Constraints

- The fixed physical chain is Linux host controller → USB → Pico/RP2040 → SPI → PE through the Tiny Tapeout development board.
- The PE operating point is 60 MHz (`rtl/pe_soc.v` and `flow/pe_soc.json`); the bridge must keep the project clock alive while connected so host queries can complete.
- Tiny Tapeout supplies 24 general-purpose digital pads: 8 `ui_in`, 8 `uo_out`, and 8 `uio`; `clk` and `rst_n` are management inputs. Pad direction is fixed by bank even when signal roles are reassigned.
- The board I/O domain is 3.3 V and inputs are not 5 V tolerant. The published 33 MHz output and 66 MHz input limits are sky130 pad reference figures; use the IHP flow and measured timing for signoff.
- The first-pass host SPI ceiling is `min(5 MHz, project_clk_hz / 6)`. A later timing/silicon pass may raise the cap toward 10 MHz at 60 MHz, but no code may silently exceed the negotiated cap.
- `HOST_SCK`, `HOST_MOSI`, and `HOST_CS_N` are asynchronous to the PE core clock and must be synchronized. `HOST_MISO` is a selected-target output and must be released safely when idle.
- `IRQ_N` is active low, defaults high, remains asserted for a sticky fault until the fault is read/cleared according to the command contract, and is serviced by the Pico as an asynchronous wake/event.
- `RUN` is driven by the Pico on `ui_in[1]`; the PE does not need an internal run command. Reset, clock, mux selection, and run sequencing belong to the Pico bridge.
- Keep `uio[0:3]` available for firmware protocol personas. The host SPI owns `uio[4:7]`; no second external SPI bus is reserved.
- The second SPI capability is an internal target selected by a protocol target field. It must not add a physical pad, clock, or external MISO.
- A short image is allowed only when the program has a terminal self-jump; the first image contract does not silently pad the undefined IMEM tail. The GUI must display the declared word count and warning.
- Do not run physical flow, DRC, or LVS as part of this plan. Simulation, lint, synthesis screening, and the existing regression are the required local gates.
- Do not modify the separate firmware SPI, I2C, Ethernet, or pin-matrix contracts except where a test explicitly proves ownership is disjoint.

## Locked Decisions

### Host-to-board transport

- Use USB CDC through the Pico's serial device (`/dev/ttyACM0` on the target Linux host).
- The first Pico protocol is newline-delimited JSON for easy MicroPython debugging and browser integration.
- Every request has a monotonically increasing integer `id`, an operation, and an argument object; every response echoes the `id`.
- The bridge emits asynchronous event objects for USB disconnect, board reset, SPI timeout, PE IRQ, status changes, and protocol faults.
- The first release uses a custom bridge mode entered by the Pico `main.py`; preservation of the stock REPL or a composite CDC/REPL interface remains an open deployment item.

### Board-side support

- The Pico uses the Tiny Tapeout SDK to select the target shuttle, drive project reset, set the 60 MHz project clock, and configure `uio_oe_pico` direction.
- Host SPI logical mapping is `uio[4]=CS_N`, `uio[5]=MOSI`, `uio[6]=MISO`, and `uio[7]=SCK`, matching the lower PMOD SPI row.
- `uo_out[1]` becomes `IRQ_N`; the former heartbeat is returned as a status field instead of occupying a pad.
- The Pico drives `ui_in[1]` for `RUN`, holds it low during reset/load/dump, and raises it only after a successful load response.
- The Pico must not stop the project clock during a connected host session. A future low-power mode may stop it only after the host has been told that status/readback is unavailable.

### Program-image format

- The GUI accepts a `.pe` source file and invokes the existing `tools/fw/peasm.py` assembler without changing the firmware ISA.
- The host creates a manifest containing source name, declared word count, load address zero, expected 60 MHz clock, and a SHA-256 digest of the canonical big-endian 16-bit word bytes.
- Words are sent MSB-first in the PE binary frame. The first release does not add a separate container file and does not pad the image to 1,024 words.
- The GUI refuses an image over 1,024 words, warns when the image is shorter than 1,024 words, and requires the program's existing terminal self-jump convention. A later container/padded-image format may be added without changing the PE frame.

### PE host protocol

The first PE wire contract is binary, word-oriented SPI mode 0, MSB-first, with `CS_N` low for a complete frame. Every frame contains these 16-bit words:

| Word | Meaning |
|---|---|
| 0 | Synchronization value `16'hA55A` |
| 1 | `{version[3:0], opcode[7:0], target[3:0]}`; version is 1 |
| 2 | Sequence number |
| 3 | Payload length in 16-bit words |
| 4..N | Command or response payload |
| N+1 | CRC-16/CCITT-FALSE over all preceding words, polynomial `16'h1021`, init `16'hFFFF`, no reflection, no final XOR |

Response opcodes set bit 7 and echo the request sequence and target. The first response payload word is a status code: `0=OK`, `1=BUSY`, `2=BAD_FRAME`, `3=RANGE`, `4=FAULT`, `5=UNSUPPORTED`, `6=NOT_READY`.

The initial opcode set is:

| Opcode | Name | Request payload | Response payload |
|---:|---|---|---|
| `0x01` | `PING` | none | status |
| `0x10` | `LOAD` | image words, load address fixed to zero | status, words written, fault bits |
| `0x11` | `STATUS` | none | state, run, target, PC, A, X, Y, timer, fault bits, words written |
| `0x12` | `READ_CPU` | none | PC, A, X, Y, current instruction, state |
| `0x13` | `READ_IMEM` | address, word count | returned words |
| `0x14` | `READ_DMEM` | byte address, byte count | returned bytes packed into words |
| `0x15` | `DUMP_CORE` | none | dump header; subsequent reads use the same range commands |
| `0x16` | `CLEAR_FAULT` | fault mask | updated fault bits |
| `0x20` | `TARGET` | target number | selected target and capabilities |

`STATUS` and `READ_CPU` are non-halting. `LOAD`, `READ_IMEM`, `READ_DMEM`, and `DUMP_CORE` require `run=0`; the Pico enforces this before issuing the command. `DUMP_CORE` captures a stable register header while stopped, then the GUI reads IMEM and DMEM in bounded blocks. The internal target selector is exercised with target 1, a small loopback/test target that returns a deterministic response without external pins.

## File Map

The implementation is split into focused units:

- `tools/host_gui/image.py`: `.pe` assembly, word validation, manifest creation, and digest calculation.
- `tools/host_gui/protocol.py`: PE frame encode/decode, CRC, opcodes, and typed frame errors.
- `tools/host_gui/transport.py`: USB request correlation, timeouts, reconnect, and asynchronous events.
- `tools/host_gui/session.py`: `DISCONNECTED`, `PREPARED`, `LOADING`, `LOADED`, `RUNNING`, `STOPPED`, and `FAULTED` state transitions.
- `tools/host_gui/server.py`: local HTTP/WebSocket API and static-file serving.
- `tools/host_gui/web/index.html`, `app.js`, `style.css`: dependency-free operator workspace.
- `tools/host_gui/tests/`: `unittest` coverage for image, protocol, transport, session, and API behavior.
- `tools/host_bridge/pe_frame.py`: MicroPython-compatible PE frame constants, CRC, and packet assembly.
- `tools/host_bridge/tt_adapter.py`: narrow wrapper around the Tiny Tapeout SDK for project selection, clock, reset, run, and pin direction.
- `tools/host_bridge/main.py`: USB line protocol, SPI transactions, IRQ event handling, and board-side state machine.
- `tools/host_bridge/tests/`: host-side fake-SDK tests using the same JSON and frame golden vectors.
- `rtl/pe_ctrl.v`: bidirectional PE SPI protocol, load engine, status/fault registers, MISO serializer, and internal target selection.
- `rtl/pe_soc.v`: host read arbitration, debug register export, and safe host access to IMEM/DMEM.
- `rtl/pe_imem.v`: host read port with deterministic arbitration against the CPU fetch.
- `rtl/pe_cpu.v`: explicit full PC, X, Y, and current-instruction debug outputs.
- `rtl/tt_um_protocol_emulator.v`: new pin ownership and lower-PMOD host-SPI wiring.
- `tb/tb_pe_host.v`: PE protocol, MISO, load, readback, dump, target, and IRQ tests.
- `regress/mutate_host_tb.sh`: mutation coverage for synchronization, framing, CRC, ranges, tri-state, and IRQ behavior.
- `info.yaml`: updated pin descriptions and host-side signal names.
- `pyproject.toml`: optional `host-gui` dependency group only; the core regression remains dependency-free.

## Task 1: Implement the Host Image and Frame Contracts

**Files:**
- Create: `tools/host_gui/__init__.py`
- Create: `tools/host_gui/image.py`
- Create: `tools/host_gui/protocol.py`
- Create: `tools/host_gui/tests/__init__.py`
- Create: `tools/host_gui/tests/test_image.py`
- Create: `tools/host_gui/tests/test_protocol.py`
- Modify: `pyproject.toml` only if the optional dependency group is added

**Interfaces:**
- `assemble_program(source: Path, repo_root: Path) -> ProgramImage`
- `ProgramImage.words: tuple[int, ...]`
- `ProgramImage.word_count: int`
- `ProgramImage.sha256: str`
- `encode_frame(opcode: int, sequence: int, target: int, payload: bytes) -> bytes`
- `decode_frame(raw: bytes) -> Frame`
- `crc16_ccitt(data: bytes) -> int`

- [ ] **Step 1: Write image tests for valid assembly and size limits**

```python
def test_assemble_program_returns_words_and_digest(self):
    image = assemble_program(FIXTURES / "echo.pe", REPO_ROOT)
    self.assertGreater(image.word_count, 0)
    self.assertEqual(len(image.sha256), 64)

def test_oversize_image_is_rejected(self):
    with self.assertRaises(ImageError):
        assemble_program(FIXTURES / "oversize.pe", REPO_ROOT)
```

- [ ] **Step 2: Run the image tests and verify they fail before implementation**

Run: `python3 -m unittest tools.host_gui.tests.test_image -v`

Expected: FAIL because `tools.host_gui.image` does not exist.

- [ ] **Step 3: Implement `.pe` assembly through the existing tool**

`assemble_program` must invoke `tools/fw/peasm.py` with a temporary output path, parse one four-digit hexadecimal word per non-empty line, reject values outside `0..0xffff`, reject more than 1,024 words, and compute SHA-256 over each word encoded as two big-endian bytes. It must not rewrite firmware source files.

- [ ] **Step 4: Write protocol golden-vector tests**

```python
def test_ping_frame_round_trips(self):
    raw = encode_frame(OP_PING, 7, TARGET_HOST, b"")
    frame = decode_frame(raw)
    self.assertEqual(frame.opcode, OP_PING)
    self.assertEqual(frame.sequence, 7)
    self.assertEqual(frame.target, TARGET_HOST)

def test_crc_mismatch_is_rejected(self):
    raw = bytearray(encode_frame(OP_STATUS, 1, TARGET_HOST, b""))
    raw[-1] ^= 0x01
    with self.assertRaises(FrameError):
        decode_frame(bytes(raw))
```

- [ ] **Step 5: Implement framing and run all contract tests**

Run: `python3 -m unittest tools.host_gui.tests.test_image tools.host_gui.tests.test_protocol -v`

Expected: PASS with malformed sync, length, CRC, opcode, and target cases covered.

- [ ] **Step 6: Commit the contract layer**

```bash
git add tools/host_gui pyproject.toml
git commit -m "feat: define host image and PE frame contracts"
```

## Task 2: Implement the USB Transport and Pico Bridge

**Files:**
- Create: `tools/host_bridge/pe_frame.py`
- Create: `tools/host_bridge/tt_adapter.py`
- Create: `tools/host_bridge/main.py`
- Create: `tools/host_bridge/tests/test_bridge.py`
- Modify: `pyproject.toml` for the optional `host-gui` dependency group

**Interfaces:**
- `USBRequest(id: int, op: str, args: dict[str, object])`
- `USBResponse(id: int, ok: bool, result: dict[str, object] | None, error: str | None)`
- `TTAdapter.enable_project(name: str) -> None`
- `TTAdapter.set_clock(hz: int) -> None`
- `TTAdapter.reset(active: bool) -> None`
- `TTAdapter.set_run(active: bool) -> None`
- `TTAdapter.configure_host_spi() -> None`
- `PicoBridge.handle(request: USBRequest) -> USBResponse`
- `PicoBridge.poll_irq() -> list[dict[str, object]]`

- [ ] **Step 1: Write fake-SDK bridge tests**

The fake adapter must record project selection, clock, reset, run, and `uio_oe_pico` calls. Tests must prove that `load` forces `run=0`, `start` raises `run` only after a successful PE response, `status` reads MISO, and an IRQ causes one `chip.fault` event without clearing the PE fault.

- [ ] **Step 2: Run the bridge tests and verify the expected failure**

Run: `python3 -m unittest tools.host_bridge.tests.test_bridge -v`

Expected: FAIL because the bridge and adapter are not implemented.

- [ ] **Step 3: Implement the MicroPython-compatible frame module**

Use the same constants and CRC algorithm as `tools/host_gui/protocol.py`. Keep this module small enough for MicroPython and add a shared golden-vector file that both host and bridge tests read.

- [ ] **Step 4: Implement the TT SDK adapter**

The adapter must use the SDK's project selection, reset, `clock_project_PWM(60_000_000)`, `ui_in` run control, and `uio_oe_pico` direction control. It must configure the Pico as output on host `CS_N`, `MOSI`, and `SCK`, input on host `MISO` and `IRQ_N`, and keep the firmware protocol row untouched.

- [ ] **Step 5: Implement the line-protocol loop**

Parse one JSON object per line, reject malformed or oversized lines without killing the bridge, correlate responses by `id`, and emit event lines for `board.connected`, `board.reset`, `spi.timeout`, `chip.irq`, `chip.status`, and `protocol.error`. A command timeout must not report a successful PE operation.

- [ ] **Step 6: Implement SPI sequencing**

For every PE command: set `CS_N` low, send the complete framed transaction, sample MISO through the Pico SPI peripheral, set `CS_N` high, and return the decoded response. `load` must use the negotiated SCLK cap and must stop on a CRC or range error. IRQ handling must read `STATUS` before emitting a fault event.

- [ ] **Step 7: Run the bridge tests with fake hardware**

Run: `python3 -m unittest tools.host_bridge.tests.test_bridge -v`

Expected: PASS for connect, load, start, stop, status, dump, timeout, disconnect, and IRQ cases.

- [ ] **Step 8: Commit the bridge layer**

```bash
git add tools/host_bridge pyproject.toml
git commit -m "feat: add Pico USB SPI bridge"
```

## Task 3: Add the PE Bidirectional Host Protocol

**Files:**
- Modify: `rtl/pe_ctrl.v`
- Create: `tb/tb_pe_host.v`
- Create: `regress/mutate_host_tb.sh`
- Modify: `regress/run_all.sh`
- Modify: `regress/lint.sh`

**Interfaces:**
- PE host inputs: `spi_sclk`, `spi_mosi`, `spi_cs_n`, `run`
- PE host output: `spi_miso`
- PE fault output: `irq_n`
- PE host read/write port: `host_we`, `host_re`, `host_addr`, `host_wdata`, `host_rdata`
- PE status signals: `load_active`, `load_error`, `words_written`, `status_state`, `status_faults`, `status_pc`, `status_a`, `status_x`, `status_y`, `status_timer`

- [ ] **Step 1: Write the protocol testbench cases**

The testbench must cover sync detection, version rejection, CRC rejection, response sequencing, `PING`, `LOAD` with known words, load range failure, `STATUS`, `READ_CPU`, `READ_IMEM`, `READ_DMEM`, `DUMP_CORE` while stopped, `CLEAR_FAULT`, target 0/target 1 selection, MISO release when idle, and IRQ assertion/clear behavior.

- [ ] **Step 2: Run the new testbench and verify it fails before RTL changes**

Run: `./regress/run_one_tb.sh "tb_pe_host|../rtl/pe_ctrl.v ../rtl/pe_soc.v ../rtl/pe_imem.v ../rtl/pe_cpu.v|tb_pe_host" "$(mktemp -d)"`

Expected: COMPILE-FAIL because the host ports and protocol are not present.

- [ ] **Step 3: Extend `pe_ctrl` with synchronized frame reception**

Retain the two-flop synchronizers and edge detector. Add a bounded frame state machine, opcode dispatch, sequence matching, CRC accumulation, response shift register, and target field. `spi_miso` must be low-impedance only while a response is selected and must return to the released state when `CS_N` is high.

- [ ] **Step 4: Preserve the loader’s run safety rules**

`LOAD` must reject `run=1`, mask `host_we`, abort a queued word if run rises, latch a fault, and never allow a later run transition to resurrect the word. The existing loader behavior must remain testable as a command-level case.

- [ ] **Step 5: Add the target-1 loopback/test target**

Target 1 must return a deterministic status/identification response through the same MISO serializer and must not claim external pins. The target selector must reject unknown target numbers with `UNSUPPORTED` and set no fault for a well-formed unsupported query.

- [ ] **Step 6: Run the protocol testbench**

Run: `./regress/run_one_tb.sh "tb_pe_host|../rtl/pe_ctrl.v ../rtl/pe_soc.v ../rtl/pe_imem.v ../rtl/pe_cpu.v|tb_pe_host" "$(mktemp -d)"`

Expected: PASS.

- [ ] **Step 7: Add mutation checks**

`regress/mutate_host_tb.sh` must mutate the synchronizer, frame length, CRC, opcode decode, MISO ownership, run gate, read range, fault clear, and target select. It must restore the source after every mutation and fail if any mutation survives.

- [ ] **Step 8: Commit the PE protocol layer**

```bash
git add rtl/pe_ctrl.v tb/tb_pe_host.v regress/mutate_host_tb.sh regress/run_all.sh regress/lint.sh
git commit -m "feat: add bidirectional PE host protocol"
```

## Task 4: Add SoC and Memory Readback

**Files:**
- Modify: `rtl/pe_soc.v`
- Modify: `rtl/pe_imem.v`
- Modify: `rtl/pe_cpu.v`
- Modify: `tb/tb_pe_host.v`

**Interfaces:**
- `pe_soc` consumes `host_re`, `host_addr`, `host_imem_sel`, and returns `host_rdata`.
- `pe_imem` exposes a host read address/data port while preserving the CPU fetch read port.
- `pe_cpu` exposes full PC, X, Y, and current instruction as explicit ports.

- [ ] **Step 1: Add failing readback assertions**

The testbench must prove that a known IMEM word read back through `READ_IMEM` matches the loaded word, DMEM reads return the last host-written bytes, `READ_CPU` reports the current stopped PC/A/X/Y, and a read while `run=1` is rejected rather than silently racing the CPU.

- [ ] **Step 2: Add the host read port to `pe_imem`**

Give host reads priority only while the host transaction is active and `run=0`; otherwise keep the CPU fetch path unchanged. A host read and host write may not drive the SRAM read/write controls in the same cycle.

- [ ] **Step 3: Add debug exports to `pe_cpu`**

Replace the truncated-only debug visibility with explicit ports for the full PC width, X, Y, and the current 16-bit instruction. Preserve the existing `dbg_pc` and `dbg_a` ports for current top-level users.

- [ ] **Step 4: Add host read arbitration in `pe_soc`**

Route host reads to IMEM, DMEM, or debug registers by an explicit address map. Reject addresses outside the declared memory sizes with `RANGE`; do not wrap. Keep the CPU fetch and host write behavior unchanged when no host read is active.

- [ ] **Step 5: Run host and existing SoC tests**

Run: `./regress/run_all.sh --fast -j8`

Expected: existing firmware/RTL cases and the new host cases all pass.

- [ ] **Step 6: Commit the readback layer**

```bash
git add rtl/pe_soc.v rtl/pe_imem.v rtl/pe_cpu.v tb/tb_pe_host.v
git commit -m "feat: expose PE debug and memory readback"
```

## Task 5: Remap the Wrapper and Pin Documentation

**Files:**
- Modify: `rtl/tt_um_protocol_emulator.v`
- Modify: `info.yaml`
- Modify: `wiki/reference/protocol-pin-budget.md`
- Modify: `wiki/entities/tiny-tapeout.md`
- Modify: `wiki/reference/clock-arithmetic.md`
- Modify: `README.md`

- [ ] **Step 1: Write wrapper ownership tests**

The top-level testbench must prove that `uio[4:7]` carry host `CS_N/MOSI/MISO/SCK`, `uo_out[1]` carries `IRQ_N`, `ui_in[1]` remains `RUN`, the firmware row `uio[0:3]` remains usable, and every released `uio` has `uio_oe=0` with a defined `uio_out` value.

- [ ] **Step 2: Update the wrapper wiring**

Route host inputs from `uio_in[4], uio_in[5], uio_in[7]`, route `HOST_MISO` to `uio_out[6]` with `uio_oe[6]` controlled by the host interface, route `IRQ_N` to `uo_out[1]`, and keep `uio[0:3]` on the SoC protocol matrix. Remove the old loader mapping from `ui_in[3:5]` and update the top-level pin comments.

- [ ] **Step 3: Update `info.yaml` and generated references**

Use unique pin keys, describe the lower PMOD host SPI and IRQ, state the 60 MHz operating point, and remove claims that the PE has no MISO/readback. Run the named generated-document checks after editing their sources.

- [ ] **Step 4: Run pad-level and lint checks**

Run: `./regress/lint.sh` and `./regress/run_all.sh --fast -j8`

Expected: no Verilator warnings, no Yosys elaboration findings, and all pad-level tests pass.

- [ ] **Step 5: Commit the pin and documentation changes**

```bash
git add rtl/tt_um_protocol_emulator.v info.yaml wiki/reference/protocol-pin-budget.md wiki/entities/tiny-tapeout.md wiki/reference/clock-arithmetic.md README.md
git commit -m "feat: map dedicated PE host SPI and IRQ"
```

## Task 6: Build the Local Web GUI

**Files:**
- Create: `tools/host_gui/transport.py`
- Create: `tools/host_gui/session.py`
- Create: `tools/host_gui/server.py`
- Create: `tools/host_gui/web/index.html`
- Create: `tools/host_gui/web/app.js`
- Create: `tools/host_gui/web/style.css`
- Create: `tools/host_gui/tests/test_transport.py`
- Create: `tools/host_gui/tests/test_session.py`
- Create: `tools/host_gui/tests/test_api.py`

**Interfaces:**
- `SerialTransport.request(op: str, args: dict[str, object], timeout_s: float) -> dict[str, object]`
- `SerialTransport.events() -> Iterator[dict[str, object]]`
- `ControllerSession.connect() -> None`
- `ControllerSession.load(image: ProgramImage) -> LoadResult`
- `ControllerSession.start() -> None`
- `ControllerSession.stop() -> None`
- `ControllerSession.status() -> StatusSnapshot`
- `ControllerSession.dump_core() -> CoreDump`
- HTTP routes: `/api/health`, `/api/connect`, `/api/assemble`, `/api/load`, `/api/start`, `/api/stop`, `/api/status`, `/api/dump`
- WebSocket route: `/api/events`

- [ ] **Step 1: Write transport and state-machine tests**

Cover request IDs, timeout behavior, disconnect/reconnect, event ordering, rejected actions, load acknowledgement, start-after-load, stop-before-start, dump-while-running rejection, and typed fault states.

- [ ] **Step 2: Implement the serial transport**

Open the configured CDC device, read complete JSON lines, reject lines above the configured maximum, correlate responses by ID, and expose events through a bounded queue. Never synthesize a successful PE response after a timeout.

- [ ] **Step 3: Implement the session state machine**

Only allow load while stopped, start after a successful load, stop from any running state, and dump only while stopped. Preserve the last status and fault event after disconnect. A reconnect creates a new session ID and does not reuse stale request IDs.

- [ ] **Step 4: Implement the FastAPI server**

Serve the local UI, bind to loopback by default, expose the listed JSON routes, and forward bridge events to WebSocket clients. Do not expose arbitrary filesystem paths or arbitrary serial-device paths through HTTP.

- [ ] **Step 5: Implement the operator workspace**

Show connection/capability state, `.pe` file selection, assembly diagnostics, word count/digest, the explicit `prepare → load → start → observe → stop` rail, status/fault events, and a read-only core/memory dump view. Disable invalid controls and label every state transition as `host-commanded`, `board-observed`, or `chip-confirmed`.

- [ ] **Step 6: Run the GUI tests**

Run: `python3 -m unittest discover -s tools/host_gui/tests -v`

Expected: PASS without requiring a physical board.

- [ ] **Step 7: Commit the GUI layer**

```bash
git add tools/host_gui pyproject.toml
git commit -m "feat: add local host controller GUI"
```

## Task 7: Add Board-in-the-Loop Acceptance

**Files:**
- Create: `tools/host_bridge/acceptance.py`
- Create: `tools/host_gui/tests/fixtures/acceptance.md`
- Modify: `README.md`
- Modify: `wiki/STATUS.md`

- [ ] **Step 1: Implement a scripted acceptance runner**

The runner must connect to `/dev/ttyACM0`, perform `hello`, select the configured shuttle, set 60 MHz, hold reset, configure host SPI, assemble `firmware/uart_echo.pe`, load it, read back the declared words, raise `RUN`, observe status/heartbeat/UART activity, stop, dump registers, clear faults, and disconnect.

- [ ] **Step 2: Run the no-hardware acceptance dry run**

Run: `python3 tools/host_bridge/acceptance.py --fake`

Expected: PASS using the fake adapter and a scripted PE simulator. The dry run must not open a real serial device.

- [ ] **Step 3: Run the real Pico/PE acceptance when hardware is available**

Run: `python3 tools/host_bridge/acceptance.py --device /dev/ttyACM0`

Expected: PASS for connect, load/readback, start/stop, status, dump, IRQ, reconnect, and USB permission errors. Record the board revision, clock, SCLK rate, image digest, and observed UART bytes in the acceptance output.

- [ ] **Step 4: Update operator documentation**

Document `dialout`/device permissions, the bridge deployment command, the required 60 MHz clock, the 5 MHz first-pass SPI cap, the deliberate load/start sequence, and the distinction between simulator, host, board, and chip evidence.

- [ ] **Step 5: Commit the acceptance path**

```bash
git add tools/host_bridge/acceptance.py tools/host_gui/tests/fixtures/acceptance.md README.md wiki/STATUS.md
git commit -m "test: add host controller board acceptance"
```

## Task 8: Final Verification and Handoff

- [ ] **Step 1: Run all Python host tests**

Run: `python3 -m unittest discover -s tools/host_gui/tests -v && python3 -m unittest discover -s tools/host_bridge/tests -v`

Expected: all host and bridge tests pass.

- [ ] **Step 2: Run firmware and RTL regression**

Run: `./regress/run_all.sh --fast -j8`

Expected: all firmware cases, RTL testbenches, parameter guards, generated-document gates, lint checks, and mutation suites pass.

- [ ] **Step 3: Run synthesis screening**

Run: `./regress/synth_area.sh`

Expected: synthesis completes without new hierarchy or diagnostic failures. Treat the result as mapped screening evidence, not physical signoff.

- [ ] **Step 4: Verify the final branch and diff**

Run: `git status --short --branch && git diff --check && git log --oneline -10`

Expected: only intended plan/implementation files are present, there are no whitespace errors, and `main` has not been checked out or modified by this worktree.

## Acceptance Criteria

The plan is complete when all of the following are true:

1. A Linux host can connect to the Pico over USB CDC and discover the PE capabilities.
2. The Pico selects the shuttle, owns reset/clock/run, and drives the lower PMOD host SPI without contention.
3. A `.pe` source assembles into a validated word image with a digest and explicit word count.
4. The PE acknowledges a load, returns status, supports bounded IMEM/DMEM reads, and returns a stopped core dump.
5. A PE fault asserts `IRQ_N`; the Pico converts it into a USB event without claiming the fault is cleared until the command succeeds.
6. The GUI presents provenance-aware status and never reports a timed-out or unacknowledged operation as successful.
7. Target 1 is reachable through the same physical host bus and consumes no additional TT pads.
8. All local regression, lint, mutation, host, bridge, and fake-hardware acceptance tests pass.
9. Physical flow, DRC, and LVS remain explicitly out of scope.

## Open Items

These are bounded decisions to resolve during implementation, not permission to leave core behavior unspecified:

1. **Pico firmware deployment:** choose whether the first bridge replaces the stock REPL, uses a separate USB interface, or provides a documented recovery mode.
2. **Board revision detection:** map logical `ui_in`, `uo_out`, and `uio` roles for the RP2040 TT04+ path and detect/report an RP2350 ETR board instead of assuming GPIO numbers.
3. **IHP timing margin:** confirm the 5 MHz first-pass SPI cap with mapped timing and, if stable, test 10 MHz at 60 MHz.
4. **CPU fault sources:** decide which CPU/SoC events should set the initial sticky fault bits beyond loader, CRC, range, and protocol faults.
5. **USB framing profile:** keep newline JSON for the first release, then replace it with binary only if measured Pico throughput or memory use requires it.
6. **Image packaging:** keep `.pe` plus manifest for v1; add a padded/container format only after the terminal-self-jump policy is exercised on hardware.
7. **Packaging and permissions:** choose pipx/uv tool, AppImage, or distro packaging and document the non-root `dialout`/`plugdev` rule.
8. **Target 1 function:** keep the first target as a deterministic loopback/test target; define its production protocol engine in a separate plan.

## Related Records

- `wiki/decisions/adr-007-pe-ctrl-passive-slave.md` records the original write-only loader decision that this plan supersedes with a bidirectional host contract.
- `rtl/pe_ctrl.v` records the current mode-0 loader, run gating, asynchronous SCLK trap, and sticky load error.
- `rtl/pe_soc.v` and `rtl/pe_imem.v` define the current write-only host port and memory interfaces.
- `rtl/tt_um_protocol_emulator.v` defines the current pad ownership and free `uio[4:7]` positions.
- `tools/fw/peasm.py` and `tools/fw/peemu.py` remain the canonical assembler and host-side firmware model.
- `regress/run_all.sh`, `regress/lint.sh`, and `regress/mutate_ctrl_tb.sh` define the required verification style.
- `wiki/reference/protocol-pin-budget.md` records the direction-aware pad budget and protocol tradeoffs.
- `wiki/reference/clock-arithmetic.md` records the 60 MHz operating point and the 10 MHz SPI arithmetic ceiling that the first pass deliberately conservatively reduces.
