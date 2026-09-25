# Host Controller GUI plan review — 2026-09-24

**Reviewed:** `wiki/plans/host-controller-gui.md` at branch `host-controller-gui`,
commit `203a251` (the only commit on this branch; plan is 539 lines).

**Against (current chip contracts):**

- `wiki/decisions/adr-007-pe-ctrl-passive-slave.md` — the accepted loader
  decision (`ui_in[3]=SCLK`, `ui_in[4]=MOSI`, `ui_in[5]=CS_N`; write-only v1).
- `wiki/plans/pe-ctrl-readback.md` — plan-only MISO options A1/A2/A3, recommended
  echo pad `uio[4]`, rate audit and guards.
- `rtl/pe_ctrl.v` — the implemented passive loader (synchronizers, mode-0
  MSB-first shift, CS framing, run gate/abort, `load_error`, `words_written`).
- `rtl/tt_um_protocol_emulator.v` — the current pad ownership (`uio[7:4]`
  released, `uio[2:3]` firmware SPI MOSI/CS_N, `uo_out[1]` heartbeat,
  `uo_out[7:2]` `dbg_pc[5:0]`, `ui_in[3:5]` loader).
- `rtl/pe_soc.v`, `rtl/pe_imem.v`, `rtl/pe_cpu.v` — write-only host port,
  CPU-only IMEM read port, truncated debug exports.
- `wiki/reference/protocol-pin-budget.md`, `wiki/reference/clock-arithmetic.md`,
  `info.yaml`, `tools/fw/peasm.py`.
- External corroboration for the one pad claim the repo cannot source:
  the Tiny Tapeout pinout convention (bottom SPI row
  `uio[4]=CS, uio[5]=MOSI, uio[6]=MISO, uio[7]=SCK`), page cached from
  <https://tinytapeout.com/specs/pinouts/> ("SPI ... Bottom row").

**Method.** Every claim in the plan that touches pads, rates, readback
semantics or observability was checked against the RTL/plan/decision sources
above and marked:

- **MATCH** — the plan restates the current contract; no RTL change needed.
- **PLAN-CHANGE** — the plan deliberately supersedes the current contract or
  needs RTL that does not exist; correct as a forward contract, but the RTL
  work and its tests must land before the claim is true.
- **PLAN-ERROR** — the plan (or a plan it relies on) is wrong or
  contradictory and must be corrected before it is implemented as written.

No source file outside this review was modified. No physical flow, DRC or LVS
was run (standing ruling).

---

## 1. Summary of findings

The plan is internally coherent as a **target architecture**, and its host-side
contracts (frame layout, CRC choice, image/manifest rules, state machine,
provenance rules) are implementable today. It is **not** a description of the
current chip: it converts a write-only 16-bit loader into a framed
command/response engine with readback, faults, IRQ and a second SPI target. All
of that is new RTL, correctly enumerated in plan Tasks 3–5, but the plan's
global constraints and locked decisions read as if several of those contracts
already exist.

Three conflicts are fatal if not resolved before RTL work:

1. **`uio[4]` is claimed twice.** The host plan assigns it to host `CS_N`
   (plan L52); `wiki/plans/pe-ctrl-readback.md` recommends it as the MISO echo
   pad (`uio_oe[4] = load_active`, L39–44, L184). Both cannot win. The host
   plan's framed protocol already returns data on `uio[6]` (plan L52, L365), so
   the echo option must be retired or re-padded before either plan becomes RTL.
2. **The readback rate is unbounded by the plan.** The plan's blanket
   `min(5 MHz, clk/6)` cap is a host policy; the actual binding limit depends on
   the MISO update option (A1 guard 2.5 MHz, A2 5 MHz, A3 10 MHz; computed
   ~7.5/~7.7/~15 MHz). The plan never chooses A1/A2/A3, and every framed command
   returns MISO, so the loader's 10 MHz write ceiling does not apply to the
   command path.
3. **"Terminal self-jump" does not describe the repo's firmware.** Only
   `firmware/i2c_pins.pe` ends in `halt: JMP halt`; `uart_echo.pe`,
   `spi_xfer.pe`, `eth_rx.pe` and `tick_count.pe` end in `JMP main`/`JMP poll`
   (backward loops). A host warning that literally requires a self-jump would
   fire on four of six existing images. The correct predicate is "last word is
   an unconditional JMP back into the image"; the host implementation below
   records that correction (the plan file is not edited).

Two cross-cutting consequences the plan underplays:

- **Every pad/observability improvement lands with RTL.** Until Phase R1/R2
  land, the chip's only live observability is `uo_out[7:2] = dbg_pc[5:0]`
  plus the `uo_out[1]` heartbeat — so the plan's Task 5 Step 3 instruction to
  "remove claims that the PE has no MISO/readback" is true only after the RTL.
- **`load_error` is the only sticky fault that exists**, it is internal to
  `pe_ctrl`, cleared on CS falling (RTL L147–160), and has no pad. The plan's
  `IRQ_N` and `CLEAR_FAULT` need a new fault register, a new output pin and a
  wrapper remap.

---

## 2. Reconciliation table

Line references: **P** = `wiki/plans/host-controller-gui.md`,
**RB** = `wiki/plans/pe-ctrl-readback.md`, **ADR7** =
`wiki/decisions/adr-007-pe-ctrl-passive-slave.md`, **CTRL** = `rtl/pe_ctrl.v`,
**TOP** = `rtl/tt_um_protocol_emulator.v`, **SOC** = `rtl/pe_soc.v`,
**IMEM** = `rtl/pe_imem.v`, **CPU** = `rtl/pe_cpu.v`.

### 2.1 Pads

| # | Plan claim | Current contract (source) | Verdict | Required action |
|---|---|---|---|---|
| P1 | Host SPI is `uio[4]=CS_N`, `uio[5]=MOSI`, `uio[6]=MISO`, `uio[7]=SCK`, "matching the lower PMOD SPI row" (P52, P361, P365) | Current loader is `ui_in[3]=SCLK`, `ui_in[4]=MOSI`, `ui_in[5]=CS_N` (ADR7 §5; CTRL L66–73; TOP L126–127; `info.yaml` `ui[3:5]`). `uio[7:4]` are **released**, not host SPI (TOP L215–216). The "lower PMOD" mapping is the TT convention `uio[4]=CS, uio[5]=MOSI, uio[6]=MISO, uio[7]=SCK` (TT pinouts page, "SPI ... Bottom row"; no in-repo source) | **PLAN-CHANGE** | Deliberate pin move; needs TOP remap + `info.yaml` + generated pin-budget regen. The freed `ui_in[3:5]` stay unused inputs. Cite the TT pinout convention as the source of "lower PMOD", not the RTL. |
| P2 | MISO echo pad `uio[4]`, `uio_oe[4] = load_active` (RB L39–44, L184) | Host plan needs `uio[4]` for `CS_N` (P52) | **PLAN-ERROR** (cross-plan collision) | Resolve before RTL: either the framed protocol supersedes the echo (retire RB A1–A3, keep the commit-latched safety rules) or the echo moves off `uio[4]`. Record the decision; do not implement both. |
| P3 | `uo_out[1]` becomes `IRQ_N`; heartbeat moves to a status field (P53, P361) | `uo_out[1] = dbg_timer[7]` heartbeat (TOP L55, L178); **no `irq_n` signal exists anywhere in `rtl/`**. `uo_out` is 8/8 committed (protocol-pin-budget "This design's actual pinout") | **PLAN-CHANGE** | New sticky-fault register + `irq_n` output and wrapper route; heartbeat becomes a STATUS payload field, which requires the Phase R2 read path. Do not remove the heartbeat before that path exists, or bring-up loses its only scope-visible liveness. Update pin-budget generator + `info.yaml`. |
| P4 | `uio[0:3]` stay available for firmware protocol personas (P36, P361) | `uio[0:1]` = I2C SDA/SCL, `uio[2:3]` = SPI MOSI/CS_N on the SoC matrix (TOP L202–213); they remain firmware-controlled | **MATCH** (as a reservation; they are in use today, not free) | None. Note the host row `uio[4:7]` is disjoint from the firmware row `uio[0:3]`. |
| P5 | "Tiny Tapeout supplies 24 general-purpose digital pads: 8 `ui_in`, 8 `uo_out`, 8 `uio`; `clk`/`rst_n` are management inputs" (P27) | 8+8+8=24 usable; 26 pad bits include clk/rst_n (protocol-pin-budget budget table) | **MATCH** | None. |
| P6 | `HOST_SCK/MOSI/CS_N` are asynchronous and must be synchronized (P30) | 2-flop synchronizers + edge detect in CTRL L81–104 | **MATCH** (bit-level) | The framed protocol must reuse this synchronizer; do not add a second sampling path. |

### 2.2 Rates

| # | Plan claim | Current contract (source) | Verdict | Required action |
|---|---|---|---|---|
| P7 | First-pass ceiling `min(5 MHz, project_clk_hz / 6)`; may later raise "toward 10 MHz at 60 MHz" (P29) | Loader write ceiling at 60 MHz is **10 MHz** = six `clk` per full period, three per half (CTRL L30–34; clock-arithmetic "SPI SCK (10 MHz target) 6.000 ticks EXACT"). RB computes the mode-0 MISO update path at ~7.7 MHz and the A1 commit latch at ~7.5 MHz, with guards 2.5/5/10 MHz for A1/A2/A3 (RB L77–83, L129–155) | **PLAN-CHANGE** | `min(5 MHz, clk/6)` evaluates to 5 MHz at 60 MHz, i.e. the plan's own guard, not the RTL ceiling — mark it "host-enforced first-pass cap". More importantly, choose the readback option: 5 MHz is safe under A2/A3 but **over the A1 guard** (2.5 MHz). Under strict mode 0 the computed ceiling is ~7.5–7.7 MHz, so "toward 10 MHz" is reachable only with A3's documented non-mode-0 change edge. The bridge must store and enforce the negotiated cap; no path may exceed it. |
| P8 | "The bridge must keep the project clock alive while connected" (P25) | No opposing chip contract; loader/memory are clocked logic | **MATCH** (board policy) | None. |
| P9 | 60 MHz PE operating point (P22, P60, P369) | `clock-arithmetic.md` (LOCKED 60 MHz); `info.yaml` `clock_hz: 60000000`; ADR-005 | **MATCH** | None. |

### 2.3 PE host protocol and readback

| # | Plan claim | Current contract (source) | Verdict | Required action |
|---|---|---|---|---|
| P10 | Frame = sync `16'hA55A`, `{version,opcode,target}`, seq, len, payload, CRC-16/CCITT-FALSE (poly `0x1021`, init `FFFF`, no reflect, no final XOR) (P68–75) | `pe_ctrl` has **no** frame parser: every 16 rising edges unconditionally commits a word to `imem` (CTRL L148–215, header "Every 16 rising edges: `imem[addr] <= word`"). If a framed LOAD were clocked into today's RTL, the sync/header/seq/len/CRC words would all be written to instruction memory. The CRC parameters are **not** in the repo's RevEng-checked catalogue (`tools/gen/crc_config.py` entries are CRC-16/USB and CRC-16/ARC, both poly `0x8005`); reusing `pe_crc` for this frame CRC would need a new catalogue entry/check. The host implementation is checked against the published CCITT-FALSE check value `0x29B1` | **PLAN-CHANGE** | New command engine in `pe_ctrl`: bounded frame FSM, sync detect, version/len checks, CRC accumulator, opcode dispatch, response serializer; only LOAD payload words reach `host_we`. `tb_pe_host.v` + mutations (plan Task 3 / RTL Phase R1). Add the CCITT-FALSE row to the generator before any RTL reuses `pe_crc`. |
| P11 | Word 1 layout `{version[3:0], opcode[7:0], target[3:0]}`; response opcodes set bit 7; response echoes seq and target (P72, P77) | No such register or response path | **PLAN-CHANGE** | New RTL; internally consistent (all request opcodes ≤ `0x7F`). |
| P12 | Status codes `0=OK … 6=NOT_READY`; first response payload word is the status (P77) | No status/response register | **PLAN-CHANGE** | New RTL. Define the status for `LOAD` while `run=1` (plan says "reject" in Task 3 Step 4 but never picks `FAULT` vs `NOT_READY`) — open detail, decide in the contract. |
| P13 | Opcodes `0x01 PING`, `0x10 LOAD`, `0x11 STATUS`, `0x12 READ_CPU`, `0x13 READ_IMEM`, `0x14 READ_DMEM`, `0x15 DUMP_CORE`, `0x16 CLEAR_FAULT`, `0x20 TARGET` (P79–91) | Only primitive capabilities exist: `words_written`, sticky `load_error`, `load_active` (CTRL L74–77); no command decode, no read path, no IRQ, no target | **PLAN-CHANGE** | Phase R1 (PING/LOAD/CLEAR_FAULT/TARGET/loader-local STATUS + IRQ) then Phase R2 (read ops). |
| P14 | `LOAD` rejects `run=1`, masks `host_we`, aborts a queued word on a rising `run`, never resurrects it (P284) | **Implemented and reviewed**: `host_we = we_r & ~run` (CTRL L129); queued/`W_PULSE` words are discarded, flagged, not counted (CTRL L180–215); PE-CTRL-REVIEW resolution in `PE-CTRL-RESOLUTION.md` | **MATCH** | Reuse the abort semantics unchanged; extend `tb_pe_host` with the same three run-transition windows. |
| P15 | `LOAD` response: status, words written, fault bits (P85) | `words_written` is 16-bit and resets on CS falling (CTRL L147–158); `load_error` is sticky and also cleared on CS falling; neither is externally readable | **PLAN-CHANGE** | The framed protocol needs session semantics (CS or frame scoped) and a response path; keep the counter's exact behavior tested. |
| P16 | `STATUS`/`READ_CPU` non-halting; `DUMP_CORE` captures a stable register header while stopped; `LOAD`/`READ_*`/`DUMP_CORE` require `run=0` (P93) | No stop/halt concept beyond `run` holding the CPU at PC 0; `pe_cpu` exposes only `dbg_pc[7:0]` (truncated) and `dbg_a[7:0]` (CPU L85–86, L138–139); X/Y and current instruction are not ports | **PLAN-CHANGE** | Phase R2: explicit debug ports (full PC, X, Y, insn) in `pe_cpu`; snapshot registers in the read engine; define chip-side rejection of reads while `run=1` rather than relying on the Pico. |
| P17 | `READ_IMEM` / `READ_DMEM` bounded reads; `READ_DMEM` "byte address, byte count" (P87–88) | `pe_imem` has **one read port**, used by the CPU fetch; the SoC host port is write-only (`host_we`, `host_imem_sel`, `host_addr`, `host_wdata`; SOC L136–144, L227–233). DMEM is **16 bytes** (`DMEM_BYTES = 16`, SOC L121; host DMEM writes range-checked at L247) | **PLAN-CHANGE** | Phase R2: host read mux/arbiter in `pe_soc` + read port in `pe_imem`; range checks must use 1024 words / 16 bytes and reject, never wrap (plan already says `RANGE`). RB option C (L164) records the shared-read-port cost. |
| P18 | A1 echo, commit-latched, "an aborted word must never echo"; reading the last word(s) costs one/two trailing frames that write `16'h0000` into the undefined tail (RB L71–92) | No echo register exists. The host plan forbids padding and has no trailing frames: `LOAD` response is the acknowledgement; short images rely on a terminal jump (P35, P62) | **PLAN-CHANGE** (host plan supersedes; RB is plan-only) | If the framed protocol is implemented first, retire RB's trailing-frame writes — they would contradict the "does not pad the image" contract. If an A1 echo is built as a stepping stone, re-pad it (P2) and keep the commit-latched/abort rules. |
| P19 | Target selector + target-1 deterministic loopback over the same MISO; unknown target → `UNSUPPORTED`, no fault; no extra pad/clock/MISO (P37–38, P91, P294–295) | No target selector, no MISO, no second target | **PLAN-CHANGE** | Phase R1: target field decode in the serializer; target 1 responder with no external pin. Consistent with the pin budget (no new pads). |
| P20 | `IRQ_N` active low, defaults high, stays asserted until the fault is read/cleared; `CLEAR_FAULT` with a mask clears it; Pico reads `STATUS` before emitting `chip.fault` (P31, P46, P237, P511) | Only `load_error` (internal, cleared by CS falling). No fault mask, no IRQ pad, no `CLEAR_FAULT` | **PLAN-CHANGE** | Phase R1: sticky fault register with mask-based clear, `irq_n` output, and fault bits in the response. Fault sources beyond loader/CRC/range/protocol are explicitly open (P Open Items 4) — do not silently invent CPU fault bits. |
| P21 | `HOST_MISO` is a selected-target output, released safely when idle (P30; Task 3 Step 3 "low-impedance only while a response is selected… release when CS_N high") | `uio_oe[7:4]=0` today (TOP L216); RB proposes `uio_oe[4] = load_active` gated by selection and `run` (RB L44, L210) | **PLAN-CHANGE** | Gating rule must be explicit: MISO drives only while a framed response is being shifted (and `CS_N` low), else releases; sweep the CS-to-first-clock boundary in the pad TB (RB L58–60). |

### 2.4 Observability, image format, documentation

| # | Plan claim | Current contract (source) | Verdict | Required action |
|---|---|---|---|---|
| P22 | "Reports chip-originated status and faults" via the GUI (P18, P511 acceptance 5) | Chip-originated observability today = `uo_out[7:2] dbg_pc[5:0]` + `uo_out[1]` heartbeat (TOP L178–179); no readback path (TOP header "The chip has NO READBACK PATH"; protocol-pin-budget) | **PLAN-CHANGE** | True only after Phase R1/R2. Until then the GUI must label chip state as host-commanded/board-observed, not chip-confirmed (the plan's own provenance rule, P440). |
| P23 | GUI refuses >1024 words; warns when shorter than 1024; requires terminal self-jump; no padding (P35, P62) | `peasm.py` already rejects >1024 (`IMEM_WORDS = 1024`, check at peasm L371–377) and encodes JMP targets with PCW=10 (L148–153, L296–306). Existing firmware ends in **backward JMP loops**, not self-jumps: `i2c_pins.pe` `halt: JMP halt`; `uart_echo.pe`/`eth_rx.pe` `JMP main`; `spi_xfer.pe` `JMP main`; `tick_count.pe` `JMP poll` | **PLAN-ERROR** (definition) | Correct the predicate to "last word is an unconditional JMP to an address within the image" (not literally to itself). Host `image.py` below implements this and records the correction; short images without it produce a warning, oversize images are refused. |
| P24 | Manifest: source name, declared word count, load address zero, expected 60 MHz clock, SHA-256 of the canonical big-endian 16-bit word bytes (P59–60) | New host contract; no conflicting source. `peasm.py` emits lowercase, newline-separated 4-digit hex words (`-o`) | **MATCH** (new host code) | Implemented in `tools/host_gui/image.py` (Phase 1 host work below). |
| P25 | "Remove claims that the PE has no MISO/readback" in `info.yaml`/docs (P369) | Current truth IS "no MISO/readback" (TOP header; ADR7 "No readback in v1"; `info.yaml` docs) | **PLAN-CHANGE** | Docs land with the RTL, not before. `info.yaml` also has **duplicate `ui[3]`/`ui[4]`/`ui[5]` keys** today (assigned then re-declared empty) — fix with unique keys in the same pass (P369 already asks for this). |
| P26 | 3.3 V, not 5 V tolerant; 33 MHz output / 66 MHz input are sky130 pad reference figures; use the IHP flow/measured timing for signoff (P28) | 66 MHz input and the `sky130_ef_io_gpiov2_pad` attribution are sourced (`wiki/raw/articles/tinytapeout-clock-spec.md`); the **33 MHz output figure has no in-repo source**; signoff authority is the IHP flow (STATUS timing tables, clock-arithmetic) | **PLAN-CHANGE** (citation) | Keep the IHP-flow signoff instruction; add the missing citation or drop the 33 MHz figure. Do not quote sky130 numbers as IHP limits. |
| P27 | `RUN` = `ui_in[1]`; the PE does not need a run command (P32, P54) | TOP L98/L127 (`run = ui_in[1]`), ADR7 §4 (`run` strap), CTRL `run` gate | **MATCH** | None. |
| P28 | Second SPI target consumes no additional physical pad/clock/external MISO (P37–38) | No second bus/pads are reserved; `uio[7:4]` released (TOP L215–216) | **MATCH** (as a constraint) | The capability itself is P19 (new RTL). |
| P29 | Pico owns reset/clock/run, uses `clock_project_PWM(60_000_000)` and `uio_oe_pico` (P50, P229) | Board/board-SDK contract, not chip RTL; RP2040/RP2350 board detection is an acknowledged open item (P Open Items 2) | **MATCH** (board policy) | None in RTL. |

### 2.5 What the table means

- **MATCH** rows: P4, P5, P6, P8, P9, P14, P24, P27, P28, P29 — mostly the
  physical bit-level loader behavior and board policy. Everything else is
  forward work.
- **PLAN-ERROR** rows: P2 (`uio[4]` collision), P23 (terminal-jump wording).
  P2 must be resolved by a decision (host plan wins is the only consistent
  choice, since its response path is on `uio[6]`); P23 is corrected in the host
  implementation and recorded here.
- **PLAN-CHANGE** rows are not defects in the plan's intent — they are the RTL
  work list below. The dangerous ones are P3/P7/P20/P21, where the plan's
  wording ("becomes", "ceiling", "asserts", "must be released") can be mistaken
  for current behavior.

---

## 3. Rate reconciliation in one place

| Path | Computed limit | Chosen guard | Source | Applies to |
|---|---|---|---|---|
| Write-only LOAD bits | 10 MHz @ 60 MHz (6 clk/full period) | — | CTRL L30–34; clock-arithmetic | Phase R1 frame receive while `run=0` |
| Mode-0 MISO per-bit update | ~7.7 MHz | A1 2.5 MHz / A2 5 MHz | RB L94–135 | Any framed response under strict mode 0 |
| A1 echo commit latch (first bit) | ~7.5 MHz (binding) | 2.5 MHz | RB L103–135 | Echo option only |
| A3 rising-edge update | ~15 MHz | 10 MHz | RB L137–147 | Only documented non-mode-0 variant |
| Plan cap | `min(5 MHz, clk/6)` = **5 MHz** | host policy | P29 | The bridge's negotiated cap; 5 MHz is **not** safe for A1 (2.5 MHz guard) |

The plan's phrase "may raise the cap toward 10 MHz at 60 MHz" is only
achievable after the readback update option is chosen (A3) and the mode-0
change-edge deviation is documented. Until then the cap should be 5 MHz for
A2/A3-style readback and 2.5 MHz if A1 is chosen.

---

## 4. Phased RTL-change list

Ordered by dependency; each phase keeps the existing regression green before
the next. No phase includes physical flow, DRC or LVS.

**R0 — reconciliation decisions (no RTL; can happen in parallel with R1 host code)**

1. Resolve the `uio[4]` collision: adopt the host plan's framed protocol and
   retire the RB echo option (or move the echo). Record the choice in the
   plan/readback plan.
2. Choose A1/A2/A3 (or framed-equivalent response timing) and the corresponding
   guard; state it in the PE contract and the bridge.
3. Fix the terminal-jump definition (backward unconditional JMP within the
   image) wherever firmware/load policy is documented.
4. Decide the `LOAD while run=1` status code (`FAULT` vs `NOT_READY`).
5. Fix `info.yaml` duplicate `ui[3:5]` keys when the pin map is next touched.

**R1 — `pe_ctrl` command engine, MISO, IRQ, pads (no SoC read port yet)**

- Frame FSM: sync `A55A`, header version/opcode/target, seq, len,
  CRC-16/CCITT-FALSE, bounded lengths, response serializer on `spi_miso`.
- Opcodes: `PING`, `LOAD` (payload words only reach `host_we`), loader-local
  `STATUS` (state/`run`/`words_written`/`load_error`), `CLEAR_FAULT`, `TARGET`.
- Sticky fault register + mask clear + `irq_n`; keep `load_error` semantics.
- Target-1 deterministic responder through the same serializer, no pads.
- Wrapper: route host SPI to `uio[4:7]`, MISO drive gating on `uio_oe[6]`,
  `IRQ_N` to `uo_out[1]`; free `ui_in[3:5]`; keep `uio[0:3]` firmware row.
- `tb/tb_pe_host.v` + `regress/mutate_host_tb.sh` (sync, header, CRC, length,
  run-abort, MISO release, target select, IRQ set/clear).
- Docs: `info.yaml`, `wiki/reference/protocol-pin-budget.md`,
  `wiki/entities/tiny-tapeout.md`, wrapper header.

**R2 — SoC debug and memory readback**

- `pe_imem`: host read port, arbitration priority only while the host read is
  active and `run=0`; never read and write the same cycle.
- `pe_cpu`: explicit full `pc`, `x`, `y`, `insn` outputs; keep `dbg_pc`/`dbg_a`.
- `pe_soc`: host read mux (IMEM/DMEM/debug) with an explicit address map,
  range rejection (1024 words / 16 bytes, no wrap), chip-side `run=1` read
  rejection; `dbg_timer` into the status path.
- `READ_CPU`, `READ_IMEM`, `READ_DMEM`, `DUMP_CORE` payloads assembled; the
  heartbeat becomes a STATUS field.
- `tb_pe_host.v` extensions: known-word readback, range, read-while-run,
  stopped dump, X/Y/insn.

**R3 — integration and documentation close-out**

- Update generated references and block diagrams; run `regress/lint.sh`,
  `regress/run_all.sh --fast -j8`, `regress/synth_area.sh` (mapped screening).
- Keep the existing 29/29 RTL + 20/20 firmware + mutation gates green; add the
  new TB to `CASES` and the mutation suite to `run_all.sh`.

**R4 — host phases (started now, not blocked by R0–R3)**

- Phase 1a (this branch): `tools/host_gui/protocol.py`, `tools/host_gui/image.py`
  + tests — implement the plan's wire/image contracts exactly.
- Phase 1b: `transport.py`, `session.py`, `server.py`, web UI; bridge; acceptance
  (plan Tasks 2, 6, 7).

---

## 5. Open questions the review adds to the plan's own list

1. Does the framed protocol supersede the RB echo entirely, or is A1 built
   first as an observability stepping stone? (Determines whether `uio[4]`
   belongs to `CS_N` or `MISO`.)
2. Which response timing option sets the readback guard (2.5/5/10 MHz)?
3. What is the `LOAD`-while-`run=1` response code, and does `CLEAR_FAULT`
   also clear loader faults (`load_error`) or only protocol faults?
4. Does `DUMP_CORE` snapshot DMEM/IMEM ranges too, or only the register header?
5. Should `STATUS` include the heartbeat as the plan's P53 says (the heartbeat
   is `dbg_timer[7]`, a free-running 8-bit counter bit) — yes, but the exact
   field width and clear-on-read behavior need definition.

---

## 6. Verification of this review

- All RTL/plan references above were read in this worktree at `203a251`
  (`git status` clean at review time; no source outside this review and the new
  `tools/host_gui/` package was modified).
- The host Phase 1a work in this review's branch was test-first: 55 tests were
  run before the modules existed (both modules `ImportError`, matching plan
  Task 1 Step 2), then implemented and re-run green:
  `python3 -m unittest tools.host_gui.tests.test_protocol tools.host_gui.tests.test_image -v`
  → `Ran 55 tests ... OK`; `python3 -m unittest discover -s tools/host_gui/tests -v`
  → same; `ruff check tools/host_gui` → all checks passed.
- The CRC implementation is measured against the RevEng catalogue check value
  `0x29B1` for `b"123456789"` plus an independent bit-by-bit reference in the
  tests (not against itself). The golden frame bytes in the tests were produced
  by that independent reference before `protocol.py` existed.
- No testbench, regression, synthesis, STA, physical flow, DRC or LVS was run
  for this review. The plan file `wiki/plans/host-controller-gui.md` was **not**
  edited; corrections are recorded here only.

---

## 7. Host Phase 1a delivered in this worktree

Not blocked by any reconciliation row above; implements the plan's wire/image
contracts as written (with the P23 terminal-jump wording corrected):

| File | Contract | Tests |
|---|---|---|
| `tools/host_gui/protocol.py` | Frame encode/decode, CRC-16/CCITT-FALSE, opcode/status/target constants, typed `FrameError` subclasses (`Sync`, `Length`, `CRC`, `Version`, `Value`) | `tools/host_gui/tests/test_protocol.py` — catalogue check value, independent reference, golden bytes `A5 5A 10 10 00 07 00 00 7D FE`, round-trips, malformed cases |
| `tools/host_gui/image.py` | `assemble_program()` through `tools/fw/peasm.py`, 1024-word cap, canonical big-endian SHA-256, manifest, terminal-backward-jump warning, `ImageError` wrapping | `tools/host_gui/tests/test_image.py` — fixture words `0041 1001 4002`, oversize fixture refusal, digest, manifest JSON, jump predicates |
| `tools/host_gui/tests/fixtures/` | `echo.pe` (terminal jump) and `oversize.pe` (1025 NOPs) | used by `test_image.py` |

Next host phases (plan Tasks 2, 6, 7): `transport.py`/`session.py`/`server.py`,
`tools/host_bridge/`, acceptance — all still gated only by the RTL phases above
for chip-confirmed behavior, not for the host-side fakes.

---

## 8. R0 decisions resolved (W2-2, 2026-09-24)

The manager's W2-2 rulings are now encoded in host code and tests; details and
commands are in `reviews/2026-09-24/HOST-GUI-PHASE1B.md`:

1. **Pad mapping — the plan wins.** `uio[4]=CS_N`, `uio[5]=MOSI`,
   `uio[6]=MISO`, `uio[7]=SCK` (`tools/host_gui/board.py`, `FakeBridge.hello`,
   tests). The A1 raw echo on `uio[4]` is **superseded**; row P2 is closed in
   favor of the plan.
2. **A1 semantics transferred, not lost.** The per-word echo is the fake's
   commit log (every committed word asserted by tests), the final-word echo is
   the fourth LOAD response word (full-1024 case covered), and a run-aborted
   word is never committed, counted or echoed. An aborted load does not mark
   the session loaded.
3. **Rate.** 5 MHz is the host guard rate; `hello.sclk_hz_max` carries the
   negotiated cap and `ControllerSession.negotiate_sclk()` refuses to exceed
   it. The RTL readback ceiling decision (A1/A2/A3) is still R0-open for the
   chip side, but no host code can silently exceed the cap.
4. **Terminal rule** (row P23): a backward unconditional JMP, warned but not
   required — implemented in `image.py`.
5. **New decisions taken here:** `LOAD` while `run=1` returns `NOT_READY` with
   no fault; clearing a fault after an aborted load returns to `PREPARED`;
   `READ_CPU` stays non-halting while `READ_IMEM`/`READ_DMEM`/`DUMP_CORE`
   require `run=0`.

---

## 9. Host Task 2 bridge delivered (2026-09-25)

Plan Task 2 is implemented, verified and committed on `host-controller-gui`
at `c28234d`; evidence is in `reviews/2026-09-25/HOST-GUI-PHASE2-BRIDGE.md`.

- `tools/host_bridge/{pe_frame,tt_adapter,main}.py`: MicroPython frame codec
  shared with the host through `tests/golden_vectors.json`, the TT SDK HAL
  adapter (uio[4:7] direction, CS_N framing, 60 MHz clock never stopped), and
  the newline-JSON endpoint with LOAD/run gating and IRQ polling.
- 55/55 bridge tests (fake HAL, fake `ttboard`/`machine`, real host stack over
  the real bridge), 34/34 protocol, 154/154 host GUI, ruff and compileall
  clean.
- Resuming the interrupted edit fixed one crash (non-integer JSON arguments
  killed the bridge; now a typed `BridgeError`) and closed two coverage gaps
  (concrete adapter SDK calls, host↔bridge integration).
- Rulings: the synchronous `hello` response is the connection signal (no
  `board.connected` line); the IRQ event is `chip.irq` (Step 1's `chip.fault`
  name is superseded).

Remaining host work: Task 7 acceptance (`--fake` can land now; the real Pico
run needs hardware) and Task 8 final verification. Plan Tasks 3–5 (PE RTL
protocol, SoC/memory readback, pin remap) are chip-side and under the
chip-repo manager's dispatch; nothing in this phase claims chip behavior.

---

## 10. Host Task 7 acceptance runner delivered (2026-09-25)

Plan Task 7's scripted runner and no-hardware dry run are committed at
`f6fdd65`; evidence is in `reviews/2026-09-25/HOST-GUI-PHASE3-ACCEPTANCE.md`.

- `tools/host_bridge/acceptance.py --fake` runs the real host stack through
  the real bridge against the fake adapter/PE: `PASS (16 PASS, 0 FAIL, 1 SKIP)`
  — hello, prepare, 5 MHz cap, 118-word `uart_echo` assemble/load/readback,
  start/heartbeat, stop, dump, scripted IRQ -> FAULTED -> CLEAR_FAULT,
  disconnect and a fresh reconnect.
- The 8 new cases pin the dry run, the UART skip and the device-open failure
  text; bridge suite 63/63, host GUI 154/154, ruff and compileall clean.
- SKIPs are contract gaps, not passes: no bridge op reports UART bytes, and
  real IRQ/faults need RTL phase R1. The runner reports them with reasons.
- The real device run (Task 7 Step 3) remains hardware-gated; `wiki/STATUS.md`
  is deferred to Task 8/merge (shared chip-side backlog; ruling in the result
  doc).

Remaining: Task 8 final verification (whole-suite + regression + synthesis
screen) when the host phases and the chip RTL phases are ready to meet.
