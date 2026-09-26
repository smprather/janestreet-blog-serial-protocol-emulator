---
title: I2C transaction layer Implementation Plan
created: 2026-09-23
updated: 2026-09-26
type: plan
tags: [protocol, architecture, verification, firmware, timing]
sources: [wiki/STATUS.md, wiki/plans/through-i2c.md, wiki/concepts/i2c-on-the-matrix.md, rtl/pe_pinmux.v, rtl/pe_soc.v, firmware/i2c_xfer.pe, tools/fw/peemu.py, tb/tb_pe_soc_i2c_xfer.v]
confidence: high
---

# I2C transaction layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A firmware I2C master transaction on real RTL — START, 7-bit address + R/W, data byte with ACK, repeated START, read byte with NACK, STOP — verified by an independent slave model in the emulator and in an RTL testbench, with standard-mode timing measured at the pin.

**Architecture:** Firmware only; no new RTL. The pin matrix (`rtl/pe_pinmux.v`), the 1 µs tick (`pe_soc` ports 4/6) and the open-drain/read-back contract are already built and measured ([[concepts/i2c-on-the-matrix]]). The transaction is a new program, `firmware/i2c_xfer.pe`, plus two independent slave models: one in `tools/fw/peemu.py` for the fast loop, one in the RTL TB.

**Tech Stack:** ISA firmware (`tools/fw/peasm.py`), bit-accurate emulator (`tools/fw/peemu.py`), Icarus Verilog TB, the existing `mutate_i2c_tb.sh` style.

**Spec:** [[plans/through-i2c]] (steps 6–7 and the firmware design sections) reconciled below, plus `wiki/concepts/i2c-on-the-matrix.md` (the measured timing and the three traps). `wiki/STATUS.md` item 3 is the work item.

> **Status 2026-09-23: COMPLETE, including the review-focus gaps.** Tasks 1–4
> are done: the emulator checker and the RTL TB are both in the regression
> (RTL 29/29, firmware 20/20, eleven firmware mutation guards), and the docs
> are updated. The three review-focus behaviours — arbitration release/abort,
> defined unexpected-NACK aborts, and SCL-stretch waiting — are implemented and
> tested on both models; an abort parks (no automatic retry). No RTL changed, so
> the recorded synthesis/STA screens stand.

## Reconciliation — the plan vs the current tree

The plan is dated 2026-09-20 and predates several completed milestones. What is
stale, and what it means for this work:

| Plan text | Current tree | Consequence |
|---|---|---|
| 40 MHz, UART tick 173, `pe_uart_soc` | 60 MHz locked (ADR-005), `pe_soc`, UART tick 260, **1 µs I2C tick = 60 clk exact** | Use the current tick; all timing numbers are the concept page's. |
| Tick table `tLOW=5, tHIGH=6` | Firmware uses **`T_LOW=7`, `T_HIGH=6`** (peasm) because the free-running tick delivers `(N-1, N]` | Do not reintroduce 5/6; reuse the target-tick wait and the existing constants. |
| "a rotate is 8 cycles, one instruction" | **The ISA has no rotate and no shift-left.** `SHR` is the only shift | Left shift = `MOV X,A; ADD A,X` (A = 2A). This is the plan's one real ISA divergence. |
| Blocker 1 (UART TB), Blocker 2 (matrix), Blocker 3 (SRAM) | All resolved | No prerequisites left. |
| Step 6 pin grammar, step 7 TB timing | Done (`i2c_pins.pe`, 79 words; `tb_pe_soc_i2c.v`; `tools/checks/i2c_timing.py`) | The transaction is built from proven primitives; reuse the idioms, not new RTL. |
| Emulator gains the pin-matrix model | Done (`peemu.Soc` models the matrix, open-drain, `i2c_pull_low`) | The transaction needs only a slave model on top. |
| "New TB drives a slave model" | The current TB's "other device" is a static pull-down | The transaction needs a real byte-level slave FSM. |
| Fast mode (step 8) | Out of scope, and out of this milestone | Not built. |

**The one open I2C item is the transaction layer** (byte, ACK, address, read,
repeated START). Nothing else in the plan blocks it.

## Definition of done (v1)

One transaction, fixed by the test to be independent of the firmware:

```
START · 0xA0 (addr 0x50 + W) · ACK · 0xA5 · ACK
      · repeated START · 0xA1 (addr 0x50 + R) · ACK · read 0x5A · NACK · STOP
```

- The slave model decodes the wire; it is not told what the firmware intends.
- The firmware records in dmem: write-address ACK, write-data ACK, read-address
  ACK, the read byte, "NACK sent", and a completion flag.
- Timing: every tLOW >= 4.7 µs, tHIGH >= 4.0 µs, period >= 10 µs (the standard
  mode floors already measured for the bit cell), across the tick-phase sweep.
- Grammar: exactly one START, one repeated START, one STOP, and no SDA move
  while SCL is high except those conditions.

## Global Constraints

- **The flow config's macro hardening metadata is static-gated** (E2); no RTL
  changes are planned, so `flow/pe_soc.json` should not move.
- **60 MHz locked**; the I2C tick is 60 clocks exactly.
- **Do not run physical flow, DRC or LVS.** Periodic synthesis/STA screens are
  allowed and expected at the end.
- **Every TB self-checks, prints `PASS`, and is registered in `run_all.sh`.**
- **Firmware `.hex` images are committed and assembled by `run_firmware_tests.sh`
  before the SoC TBs run.**
- **No new ISA opcode.** The transaction must be expressible with the current
  16 opcodes; if it cannot, that is a finding, not a licence to extend the ISA.

## Review Focus

1. **A stalled SCL (clock stretching).** The transaction loop should read SCL
   back before treating a released clock as high; the TB can hold SCL low and
   require the firmware to wait. Task 2/3 pin it or document it as out of v1.
2. **Arbitration during transmitted 1s.** The pin-level firmware proved the
   read-back; the transaction should keep it for address/data bits and record a
   loss. Task 2 records it; Task 3 drives SDA low during a transmitted 1.
3. **A NACK where ACK is expected.** The read-address phase must still proceed
   to the read; a data byte NACK must be recorded and the master must STOP.
   Task 1's slave model can be configured to NACK.
4. **The read turnaround.** Release SDA before the slave drives, and do not
   drive during the ACK slot; the plan's 1 µs window is the budget.
5. **Ticks > 255.** The tick counter is 8-bit and free-running; a transaction
   spans many wraps. The target-tick equality wait already handles the wrap
   (the concept page's note); a multi-wrap cell would not.

---

### Task 1: Emulator slave model + transaction checker (test-first)

**Files:**
- Modify: `tools/fw/peemu.py` (add `I2CSlaveModel` + `Soc.poll_i2c_slave`)
- Create: `tools/checks/i2c_xfer_check.py`

**Interfaces:**
- `I2CSlaveModel(address=0x50, read_byte=0x5A, nack_data=False)` with
  `poll(soc)` called after every `soc.step()`; it reads `soc.wire_bits()` and
  sets `soc.i2c_pull_low`. It records `writes: list[int]`, `reads: int`,
  `started`/`stopped`.
- `i2c_xfer_check.py`: assembles `firmware/i2c_xfer.pe`, runs it with the slave
  model, decodes the wire into a transaction, and checks bytes, ACKs, dmem
  observables and timing floors. Exit 0/1.

- [ ] **Step 1: Write the checker and the slave model.** The checker's expected
  transaction is the fixed sequence above; it must fail while
  `firmware/i2c_xfer.pe` does not exist (assemble error) — that is RED.
- [ ] **Step 2: Run it, watch it fail on the missing program.**
- [ ] **Step 3: Implement the slave model and the checker's decode.**

### Task 2: `firmware/i2c_xfer.pe` until the checker passes

**Files:**
- Create: `firmware/i2c_xfer.pe`, `firmware/i2c_xfer.hex`
- Modify: `regress/run_firmware_tests.sh`
- Modify: `tools/fw/peasm.py` only if a constant is missing (SDA/SCL and the
  tick constants exist; no opcodes are added).

- [ ] **Step 1–N: TDD against `i2c_xfer_check.py`** — START, address write,
  ACK sample, data write, ACK, repeated START, read address, ACK, read byte,
  NACK, STOP; dmem observables; then the timing/grammar assertions.

### Task 3: RTL testbench with an independent slave model

**Files:**
- Create: `tb/tb_pe_soc_i2c_xfer.v`
- Modify: `regress/run_all.sh` (TB case), `regress/mutate_i2c_tb.sh` or a new
  `regress/mutate_i2c_xfer_tb.sh`.

**Interfaces:** an open-drain bus (as in `tb_pe_soc_i2c.v`) plus a Verilog slave
FSM: START/STOP detect, shift on SCL rising, ACK on the 9th bit, fixed read byte,
timing/grammar monitors, and the firmware's dmem observables.

- [ ] **Step 1: Write the TB against the already-working firmware; watch it
  pass on the clean design, then verify it can fail** (e.g. the slave NACKs the
  address and the TB must report it) before wiring it into the regression.
- [ ] **Step 2: Mutation harness** for the new TB (address bit order, ACK
  polarity, read-bit order, repeated-start handling).

### Task 4: Docs, wiring, hardening screen

**Files:**
- Modify: `wiki/concepts/i2c-on-the-matrix.md` (open work → done), `wiki/STATUS.md`
  (item 3 done), `wiki/log.md`, `HANDOFF.md`, `wiki/plans/through-i2c.md`
  (point to this plan).
- Run: `./regress/run_all.sh --fast -j8`, then a synthesis/STA screen of the SoC
  (no RTL changes expected, so the numbers should be unchanged) and the
  `i2c_xfer_check.py` sweep.

## Self-Review

**Spec coverage:** the plan's DoD (transaction, independent slave, emulator
parity, timing at the pin, docs/regression) is Tasks 1–4. The reconciliation
table accounts for every stale claim that would otherwise mislead the
implementation (40 MHz, 5/6 ticks, ROTL, prerequisites).

**Placeholder scan:** every task names exact files and interfaces; the firmware
body is developed TDD against the checker rather than pre-written, which is the
point of the emulator fast loop.

**Type consistency:** `poll_i2c_slave` mirrors `poll_spi_slave`'s call-after-step
contract; dmem slots are fixed by the checker and the TB; the 1 µs tick and
SDA/SCL constants come from `peasm.py`.

**Review Focus:** item 1 is pinned by the TB's stretch test or documented out;
item 2 by an SDA-low-during-transmit test; item 3 by a NACK configuration in
both slave models; item 4 by the read-byte check; item 5 is handled by the
existing equality wait and noted.
