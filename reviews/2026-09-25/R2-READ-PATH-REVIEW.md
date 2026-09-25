# R2 chip-side read path — implementation and conformance record (2026-09-25)

Phase R2 of the framed PE host protocol: the host can now READ the chip.
Phase R1 (the framed request/response bus, LOAD, STATUS, CLEAR_FAULT, TARGET)
is recorded in `HANDOFF.md`; this is the read phase that closes the P3
liveness gap's first half and gives the host a debugger.

**Acceptance spec:** the gui-worker golden package
(`reviews/2026-09-25/r2-hex`, commits 262a639 / a297028) — 8 vectors / 15
steps of exact request and response bytes, the model image each vector assumes,
and a drift-gated generator whose inverse (`load_model_from_image`) is the load
procedure. **All 15 steps pass on the chip, byte-exactly, CRC word included.**

## What landed

| Piece | Where |
|---|---|
| Full-width debug registers | `rtl/pe_cpu.v` — `dbg_pc` at PCW (10 bits at 1,024 words; the old 8-bit truncation is gone), plus new `dbg_x`/`dbg_y`/`dbg_insn`; A stays 8 bits |
| Bounded host read port | `rtl/pe_soc.v` — one request/answer shape, one cycle of latency, imem returns a WORD and dmem a BYTE; the CPU's address buses are arbitrated, safe because reads are only issued while `run=0` |
| Read opcodes + R2 STATUS | `rtl/pe_ctrl.v` — 0x12 READ_CPU, 0x13 READ_IMEM, 0x14 READ_DMEM, 0x15 DUMP_CORE; response buffer grown 8 -> 16 slots for the 11-word header; the read engine walks the range and starts the serializer |
| Wait-word contract | `rtl/pe_ctrl.v` — 0xFFFF filler during the fetch (driven, not floated), the frame starts at the first non-0xFFFF word |
| Wrapper wiring | `rtl/tt_um_protocol_emulator.v` — no new pads; the 19-of-24 budget and the G6 `uo_out[2]` reclaim are untouched |
| Conformance TB | `tb/tb_pe_ctrl_r2.v` + `tb/r2-vectors/` (the package, plus generated includes) |
| Unit TB | `tb/tb_pe_ctrl.v` — R2 cases added; the read port is modelled with a one-cycle memory image |

## The wire contract (a host must implement this)

- **READ_CPU (0x12)** is the ONLY non-halting read: it answers while `run=1`.
  Response `(OK, pc, a, x, y, insn, run)`, registers at their NATIVE widths —
  the manager ruled the ISA is the source of truth, so the host FakePE's 13-bit
  A was a model bug and A stays 8.
- **READ_IMEM (0x13)** request `(address, count)` in WORDS, response ascending.
- **READ_DMEM (0x14)** request `(byte address, byte count)` in bytes; two
  bytes per response word, **high byte first**, ascending.
- **DUMP_CORE (0x15)** the STATUS header while stopped; NOT_READY while running.
- **STATUS is 11 payload words**: `status, state, run, target, pc, a, x, y,
  timer, faults, words_written` — R2 stopped stubbing the cpu-derived fields.
- **Wait words.** A bounded read cannot answer inside the request's own bit
  times (each fetched word/byte is a round trip), so the chip drives `0xFFFF`
  filler and the frame begins at the first non-`0xFFFF` word. A host skips
  LEADING fillers — a filler can never be a header (opcode bit 7 set, version
  and target bounded) and the skip is leading-only, so a `0xFFFF` in a payload
  is data. **Worst case 15 filler words** (a 15-word read, one round trip each).
  Transport-level only: the response bytes are unchanged and an R1 host sees
  zero wait words.
- **Bounds and faults.** `address+count` past the end is RANGE, never a wrapped
  read, and latches sticky `FAULT_RANGE` (0x4), which `CLEAR_FAULT` clears. A
  count larger than one frame can carry (15 words / 30 bytes) also answers
  RANGE so the host splits. Bounded reads are NOT_READY while `run=1` with NO
  fault (a sequencing rejection, like LOAD).

## Conformance: 15/15, per vector

```
[read_imem_address_1_count_2]  PASS   [read_imem_not_ready]        PASS
[read_dmem_address_0_count_4]   PASS   [read_dmem_not_ready]        PASS
[dump_core_header]             PASS   [dump_core_not_ready]        PASS
[status_header]                PASS   [read_imem_last_word]        PASS
[read_cpu_while_running]       PASS   [read_imem_past_end_no_wrap] PASS
[read_cpu_full_width_regs]     PASS   [read_dmem_past_end_no_wrap] PASS
[bad_read_answers_range]       PASS   [status_shows_sticky_fault]  PASS
[clear_fault_clears_the_bit]   PASS
```

The TB loads `imem.hex`/`dmem.hex`, applies each vector's sparse overrides and
register state, replays the session's opening 3-word LOAD (the vectors assume
`words_written = 3`, so that DUT counter is established by a real transaction,
not poked in), then compares every response byte — skipping wait words — to the
golden stream.

## Three real defects the work found

1. **Odd dmem byte counts dropped the trailing byte.** It was held in `r_half`
   and never emitted, leaving the response a word short of its declared length.
   Fixed, and the flush uses `dbg_rd_data`, not `r_half` — the byte is still in
   flight when the non-blocking assignment lands.
2. **The response launch never fired.** It was placed inside the `r_filling`
   arm, but setting `r_launch` clears `r_filling`, so the arm was skipped
   exactly when the launch was needed.
3. **An X on the MISO pad before the first frame.** The filler state was never
   reset, and `r_filling` feeds `miso_oe`; the pad-level TB caught it.

Two mutation anchors also moved with the R2 work (`status-fields-zero` ->
`resp_buf[10]`, `miso-oe-stuck` -> the extended `miso_oe` expression) and were
re-anchored rather than deleted.

## Evidence

`./regress/run_all.sh --fast -j8` **exit 0** — RTL **34/34** (the conformance
TB is the 34th), firmware **26/26**, lint clean, 12 generated gates, **12**
mutation suites including `mutate_ctrl_tb.sh` **29/29** and the two eth_tx
suites **18/18** and **7/7** (`/tmp/run_all_r2_done.log`).

## Mapped timing screen (added after the conformance run)

`reviews/2026-09-25/r2-sta/`, 16.667 ns, `pe_soc` and `tt_um_top`, slow/typ/fast,
ZERO and BOARD variants (12 screens, runner exit 0). The R2 read port, the
full-width debug bus and the wait-word filler are in these netlists.

- `pe_soc` is UNCHANGED against the eth-tx screen: setup 0.00, hold
  -0.87/-0.61/-0.48 (zero) and -0.55/-0.42/-0.37 (board).
- `tt_um_top` hold IMPROVED: -0.59/-0.45/-0.38 (zero) against -0.71/-0.52/-0.43,
  and the zero and board variants now AGREE at every corner — the external
  worst class is no longer what the top level reports.
- The new R2 classes (`dbg_rd_data`, `dbg_pc`, and the `uio_out[6]` MISO pad)
  appear only inside the PRE-EXISTING external-output class, all shallower than
  that class's worst, and all cleared by the 1.0 ns board floor.

**No new violation class.** Mapped pre-layout screen only: no placement,
routing, DRC or LVS.

## Limits

- Simulation and mapped pre-layout screening only; no physical flow, DRC or
  LVS.
- The conformance TB depends on the golden package being present in
  `tb/r2-vectors/`; the drift gate that keeps the image and the streams in step
  lives in the host package, and the copy here is refreshed when it lands.
- The P3 liveness gap is CLOSED on the chip side by this phase: `STATUS`
  now carries `pc`/`a`/`x`/`y`/`timer` at native widths and `READ_CPU`
  answers while `run=1`, so a host can see a running program. Only the
  host-side surfacing (the GUI) remains, in the host-controller branch.
