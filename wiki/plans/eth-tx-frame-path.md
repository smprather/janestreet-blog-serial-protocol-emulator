---
title: 10BASE-T TX frame path (eth_tx)
created: 2026-09-24
updated: 2026-09-24
type: plan
tags: [architecture, integration, ethernet, tx, timing, pads]
sources: [rtl/pe_eth_mac.v, rtl/pe_crc.v, rtl/pe_serdes.v, rtl/pe_codec_mux.v, rtl/pe_manch.v, rtl/pe_fbuf.v, rtl/pe_soc.v, rtl/tt_um_protocol_emulator.v, tb/tb_pe_eth_mac.v, wiki/concepts/ethernet-scope.md, wiki/concepts/tx-timing-generation.md, wiki/reference/crc-config.md, wiki/reference/protocol-pin-budget.md, reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md, reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md]
confidence: medium
---

# 10BASE-T TX frame path (`eth_tx`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status: PLANNING ONLY — 2026-09-24. No RTL, test, script or firmware
> change is made by this plan.** The eight scope groups below are written so
> the manager can adopt the recommended default per group at review, exactly
> as [[plans/serdes-integration]] was resolved by the 2026-09-24 manager
> decision. Nothing here is implemented until those groups are adopted.

**Goal:** Build the last unbuilt block in the project topology: a 10BASE-T
transmitter that takes a firmware-supplied frame (header + payload), emits the
56-bit preamble and SFD, appends the FCS computed in hardware, pads short
frames to the 64-byte minimum, enforces the 96-bit-time inter-frame gap, and
presents real Manchester cells at a pad — proven by decoding the pad waveform
at the pin with real frames and a real FCS, and by looping the transmitted
frame back through the already-verified receive chain
(`pe_dru -> pe_manch -> pe_eth_mac` + `pe_crc` + `pe_fbuf`).

**Architecture:** a new `rtl/pe_eth_tx.v` frame engine sits beside the SERDES
word engine inside `pe_soc`. It is paced by the existing engine divider's
`cell_en` (one strobe per Manchester cell; `DIV = 6` gives the exact 100 ns
bit at the locked 60 MHz) and feeds the existing `u_tx_codec` (Manchester,
`cfg = 0x04`) through a one-line owner mux, so there is exactly one Manchester
encoder and one already-verified pad-overlay path. The FCS is a second,
TX-dedicated `pe_crc #(.W(32))` instance with the generated RevEng-checked
constants; the RX instance stays owned by `pe_eth_mac`. Firmware streams the
frame's header and payload bytes through an 8-byte staging FIFO in an extended
`0xF` window (indices 16-23 push-and-wrap, 24/25 length, 26 control, 27
status); the hardware owns everything from preamble to IFG. The recommended
pad is a reclaimed `uo_out[2]` (`dbg_pc[0]`), muxed so reset stays
bit-identical, with `ui_in[2]` staying the RX pin.

**Tech Stack:** Verilog-2001/2012 RTL, Icarus Verilog (`iverilog`/`vvp`),
Verilator + yosys lint gate, the repo's Python assembler (`tools/fw/peasm.py`),
native yosys + OpenSTA screens (no physical flow).

**Spec:** `wiki/STATUS.md` "Next steps (ordered)" item 9 (added with this
plan); `wiki/concepts/ethernet-scope.md` (the line-layer scope and why the bit
work is hardware); `wiki/concepts/tx-timing-generation.md` (60 MHz is exact
and 66 MHz provably fails the §14.3.1.2.3 jitter window); the RX counterpart
`wiki/plans/ethernet-soc.md` and `reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md`
("the full 10BASE-T TX consumer ... gets its own plan; this plan only delivers
the engine it will use").

**Definition of done (acceptance):** `firmware/eth_tx_arp.pe` pushes a 42-byte
ARP request through the window; the chip's tx pad carries a real Manchester
waveform whose decoded bytes match, whose FCS matches an independently
computed reference, and whose short frame was padded to the 64-byte minimum;
a second, longer-than-64-byte frame proves no padding and a full-payload FCS;
an overlength request is refused with a sticky fault; two frames sent
back-to-back are separated by ≥96 bit times; and a loopback TB wires the tx
pad to the rx pin so the same frame arrives in the receive chain FCS-clean
(the chip exchanges a real frame with itself). The unit and loopback TBs each
have a mutation suite with zero unexplained survivors, and
`./regress/run_all.sh --fast -j8` is green.

**Baseline of record and state observed at plan-writing time.** The pin
baseline used below is the manager-recorded post-A1 pinout: **19 of 24 usable
pads committed, `uio[7:5]` free, `ui_in[7:6]` free**, and STATUS item 4's
"a `pe_ctrl` readback path lands" revisit trigger has fired (the A1 readback
landed 2026-09-24). Observed in the shared worktree at plan-writing time:
`rtl/pe_ctrl.v` / `rtl/tt_um_protocol_emulator.v` carry an uncommitted,
unrecorded "phase R1" host-bus change (`uio[4:7]` framed host bus, referencing
a `wiki/plans/host-controller-gui.md` that does not exist). The pad
recommendation below is deliberately stated so it survives **either**
baseline — it takes the pad from `uo_out`, not from the free `uio` — and the
free-`uio` alternative is flagged as baseline-dependent for the manager to
reconcile before implementation.

## Global Constraints

- **60 MHz operating point is LOCKED** (`CLK_HZ = 60_000_000`, a `localparam`
  in `pe_soc`). One Manchester cell is exactly **6 clk = 100 ns** and a
  half-cell is **3 clk = 50 ns**; the divider register is `DIV = 6`. Do not
  add a clock parameter and do not change the RX grid: `pe_dru` stays at
  `SPB = 12` (8.333 ns per dual-edge sample, 6 samples per half-cell, 12 per
  bit), which is the loopback's capture margin.
- **The tx jitter window is a conformance test, not a slogan:** IEEE 802.3
  §14.3.1.2.3 requires crossings at 8.0 BT ±11 ns and 8.5 BT ±11 ns after a
  triggering crossing. 60 MHz is exact (50 ns and 100 ns are integer clocks);
  66 MHz provably fails at every edge placement. No dither, no fractional
  divider.
- **Standing user ruling: do not run physical flow, DRC or LVS.** Synthesis
  and mapped OpenSTA screens are allowed and expected.
- **Every new testbench is self-checking, prints `PASS: <name>` on success,
  and is added to `regress/run_all.sh`'s `CASES` array.** A TB nothing runs is
  not a test.
- **`regress/lint.sh` has no accepted warnings.** Sink every unused signal
  explicitly (`wire _unused = &{...}` pattern).
- **Generated docs are drift-gated**: RTL changes that move a port, an
  instantiation, a pin count or a number require regenerating
  `tools/gen/*.py --check` pages in the same change (`signal_glossary`,
  `pin_budget`, `block_diagram`, `floorplan_feasibility`, `crc_config`,
  `clock_arithmetic`).
- **Every source list that elaborates `pe_soc` must gain `rtl/pe_eth_tx.v` in
  the same change**: `flow/pe_soc.json` (`VERILOG_FILES`), `info.yaml`,
  `regress/synth_area.sh` (both report lines), `tools/checks/macro_flow_config.py`,
  and every mutation-harness source list. This exact miss failed the first
  SERDES full run (five places, one cause); do not repeat it.
- **CRC-32 constants come from the generated `wiki/reference/crc-config.md` and
  are never hand-edited**: `cfg_poly_r = 32'hEDB88320` (rev(0x04C11DB7, 32)),
  `cfg_seed = 32'hFFFFFFFF`, `cfg_out_inv = 1'b1`. The generator re-asserts the
  RevEng catalogue check value `0xCBF43926` for "123456789" and `tb_pe_crc`
  re-checks it in RTL.
- **The receiver's FCS verdict is `crc_state == 32'hDEBB20E3` (CRC-32/ISO-HDLC
  catalogue residue), never `crc_zero`.** A transmitter emits the complemented
  field (`crc_bit = R[0] ^ cfg_out_inv`, pure-shift feedback); `crc_zero`
  belongs to the opposite convention and its use in an acceptance check is the
  documented `pe_eth_mac`/`pe_crc` bug class.
- **Reset default is bit-identical.** The frame engine is disabled at reset
  (`tx_path = 0`), the codec owner mux selects the SERDES, the pad mux selects
  `dbg_pc[0]`, and the extended window's new indices read 0 — every existing
  TB and firmware image must stay green before the feature is enabled. The
  reclaimed pad's function changes only while firmware enables the TX persona;
  the mux keeps reset and every existing firmware image bit-identical.
- **Firmware `.hex` images are committed**; `regress/run_firmware_tests.sh`
  assembles every program before the RTL TBs run.
- **Verilog house style:** one header comment per module stating the contract
  and the trap each non-obvious choice avoids; no timescale in RTL files.

## The frame, in wire order (the numbers every step uses)

| Phase | Bits on the wire | Notes |
|---|---|---|
| Preamble | 56 bits, `1,0,1,0,...` starting with 1 | a **wire pattern**, not byte 0xAA through an LSB-first helper (the `tb_pe_eth_mac` trap: 0xAA through the helper inverts the phase and creates a false SFD window) |
| SFD | 8 bits = `0xD5` LSB-first = `1,0,1,0,1,0,1,1` | continues the alternation for 6 bits, then two 1s |
| Header + payload | 8·N bits, each octet LSB-first | N = firmware `TXLEN` (14..1514) |
| Pad | 8·(60−N) zero bits when N < 60 | 802.3's 64-byte minimum: 14 header + 46 data + 4 FCS; pad bytes are data on the wire and are covered by the FCS |
| FCS | 32 bits, `crc_bit = R[0] ^ 1`, one per cell | field mode (pure shift); never folded back |
| IFG | 96 idle cells (9,600 ns = 576 clk) before the next preamble | the receiver's own hunt gate needs 8 idle cells, so the standard's 96 is generous on purpose |

Totals: minimum frame = 64 bytes = 512 bits = 51.2 µs + 6.4 µs prelude;
maximum basic frame = 1,518 bytes = 121.44 µs (+ prelude/IFG). Stored bytes
(header + payload + pad) are bounded at **60..1514**; below 60 the hardware
pads, above 1,514 the request is refused (jabber policy).

## Scope groups and recommended defaults

Each group is independent enough to be adopted or amended on its own. Every
"RECOMMENDED DEFAULT" is written to be safe to adopt as-is; alternatives carry
their costs so the manager can trade them at review.

### G1. Frame source and firmware contract — RECOMMENDED DEFAULT: firmware-streamed bytes through the window's extended upper bank

Firmware pushes the frame's header and payload (**no preamble, no pad, no
FCS**) through the `0xF` window and writes `TXLEN`; hardware appends
everything else. The window grows from 16 to 32 entries (5-bit index; the ISA
data byte already carries it): indices **16-23 are a byte-push bank that
writes into an 8-byte staging FIFO and wraps within 16-23** (so a burst never
wraps into `CTRL`), **24/25 = `TXLENL`/`TXLENH`** (11 bits, 14..1514),
**26 = `TXCTRL`** (`frame_start` strobe, `frame_abort`, `tx_path` owner bit),
**27 = `TXSTAT`** (`tx_busy`, latched `tx_done`, `tx_underrun`, `tx_overlong`,
`fifo_ready`, `ifg_active`; set-beats-clear on read); 28-31 spare. Existing
indices 0-15 keep their exact current semantics.

Rationale: the CPU's data memory is 16 bytes and cannot hold a frame; the
thesis is "firmware sequences frames, hardware does bits", and the RX side
already inverts this pattern (hardware stores, firmware walks). The 48-clk
(800 ns) per-byte deadline is generous: the first consumer's push loop will be
a handful of instructions per byte (Task 5 measures it).

Alternatives: **(A)** hardware TX buffer read — firmware composes the frame
into a buffer, then triggers; no CPU deadline, but costs the buffer and its
arbitration (see G2), and the compose write path is as much window traffic as
the streaming path. **(B)** firmware emits preamble/pad/FCS bytes itself —
rejected: the CRC-32 is ~5× over the 48-instruction budget and the preamble
pattern is the documented phase trap. **(C)** a full frame in IMEM constants
with a fixed program — viable only for static probes (no variable payload,
large program), kept as a test trick, not the contract.

### G2. Buffer strategy — RECOMMENDED DEFAULT: no frame-sized TX buffer; an 8-byte staging FIFO in flops

The frame source is firmware: for replies it walks the RX buffer (already
proven) and pushes each byte; for probes it pushes constants. The 8-byte FIFO
absorbs CPU latency (~6.4 µs of wire time: 8 bytes × 8 bits × 100 ns). No new SRAM macro, no change to
`pe_fbuf`'s verified single-port RX ownership, and a maximum-length frame is
naturally supported because nothing is partitioned.

Alternatives: **(A) a new dedicated TX frame macro** (same
`RM_IHPSG13_1P_1024x16` part, +79,674 µm² per the SRAM budget, a third macro
to place/PDN/time, floorplan occupancy rises) — clean ownership and zero CPU
deadline; the right choice only if the CPU deadline proves binding in Task 5.
**(B) carve a TX region out of `pe_fbuf`** — no new macro, but it modifies the
verified RX store-and-forward ownership contract, a 2 KB macro cannot hold a
max RX frame *and* a max TX frame in separate partitions, and the single-port
arbitration between RX writes, CPU reads/writes and TX reads would need a
corner-case proof the current one-window design deliberately avoids. Rejected
for v1; revisit only if G1's streaming proves insufficient.

### G3. Preamble/SFD insertion point — RECOMMENDED DEFAULT: hardware-owned, before DATA, CRC cleared at its start

The TX FSM emits the fixed 64-bit prelude as its own PREAMBLE state; the
preamble and SFD are **never folded into the CRC** (`crc_clr` one cycle at the
preamble start; the first `crc_bit_en` is the first header bit). The preamble
is emitted as wire bits, not as bytes through a byte helper — the exact
`0xAA`-through-`send_byte` phase inversion `tb_pe_eth_mac` documents.

Alternatives: firmware supplies the prelude bytes (rejected: the trap above
plus 8 bytes of window traffic per frame); reuse the SERDES to emit
`0xAAAA...` words (rejected: 32-bit cap and the same phase trap). Cost of the
default: one FSM state and a 64-count.

### G4. FCS ownership — RECOMMENDED DEFAULT: a second, TX-dedicated `pe_crc #(.W(32))` instance

`pe_eth_mac` currently owns the SoC's only `pe_crc` and folds RX bits
continuously while a frame arrives; 10BASE-T TX and RX are independent
directions on separate pairs, so time-sharing one LFSR would let a transmit
corrupt an in-flight receive. The TX engine instantiates its **own**
`pe_crc` (same generated constants), folds every header/payload/pad bit in
transmission order, then asserts `crc_field` for 32 `cell_en` strobes and
emits `crc_bit` (pure shift, `R[0]^1`). The end-of-frame register state is
checked in the TX TB, not just the emitted wire bits (the `pe_crc` header's
field-mode trap: the wire bits are identical whether or not the complement is
inside the feedback, and only the register state differs).

Alternatives: **(A) time-share the RX instance with RX priority** — saves
~209 mapped cells but stalls TX mid-frame and the ownership corner has no
test; rejected. **(B) one muxed instance with a mode bit** — same stall
problem plus touched RX path; rejected. Cost of the default: ~209 cells /
~3.4k µm² mapped (measured `pe_crc` figure; confirm with `synth_area.sh`).

### G5. Line-code path — RECOMMENDED DEFAULT: reuse `u_tx_codec` + the divider + the overlay, via an owner mux

The TX engine replaces `u_tx_codec.tx_bit` when it owns the path:
`tx_bit = tx_path ? eth_tx_bit : ser_tx`, with the FSM asserting `tx_path`
only while it is enabled and the SERDES TX is idle. `cell_en` (DIV=6) clocks
the codec; `half_phase` drives Manchester's second half; the existing
`ov_en`/`ov_bit` overlay drives the selected pad. One Manchester encoder, one
timing block, one pad path — all already verified by `tb_pe_soc_serdes` and
the Task-4 STA screen.

**The idle trap this default carries:** `pe_manch` is combinational, so a
*constant* `tx_bit` under a toggling `half_phase` puts a 20 MHz square wave on
the wire, which is not 10BASE-T idle (idle is a constant level). The FSM must
drive `tx_bit = half_phase` whenever it owns the path and is not mid-frame;
the TX TB checks the idle level between frames.

Alternatives: **(A) a dedicated `pe_manch` instance + divider inside
`pe_eth_tx`** — decouples the frame path from the engine window/serdes, but
duplicates the encoder and adds a second pad mux/timing path (~7 cells +
divider + mux, more surface for less reuse); **(B) drive the frame through
`pe_serdes` word mode** — rejected: no per-bit control for the preamble/FCS
and a 32-bit word cap.

### G6. Pad selection and the reset-default rule — RECOMMENDED DEFAULT: reclaim `uo_out[2]` (`dbg_pc[0]`) as `eth_tx`, muxed so reset is bit-identical

`uo_out[2] = pin_oe_bus[7] ? pin_out_bus[7] : dbg_pc[0]`, with the other five
debug pins unchanged. The engine's existing overlay (`eng_txsel = 0`, the
reset default, selects port bit 7) drives the pad once firmware sets port
bit 7's matrix enable; at reset and under every existing firmware image,
`pin_oe_bus[7]`
is 0 and `uo_out[7:2]` remains `dbg_pc[5:0]` exactly. RX stays on `ui_in[2]`.
Costs: `dbg_pc[0]` is hidden while the 10BASE-T TX persona drives the pad; the
committed count stays **19 of 24** (the pad was already committed as
`dbg_pc[0]` — only its function changes); the wrapper TB's pin-map checks
update;
the generated pin-budget page regenerates. Rationale: STATUS item 4's trigger
has fired; 10BASE-T's budget row is a dedicated `eth_tx(out)`/`eth_rx(in)`
pair; and the free `uio` pads stay free for the matrix's runtime-direction
personas.

Alternatives: **(A) map port bit 7 to a free `uio[5]` pad** — no debug loss,
no committed-count change; uses 1 of 3 baseline-free `uio` and **collides if
the in-flight host-bus change claims `uio[4:7]`** (flagged above); **(B) share
`uo_out[0]` via `eng_txsel = 1`** — zero pinout delta and already supported by
the engine, but steals the UART TX/SPI SCLK pad for the whole 10BASE-T
persona; **(C) hardwire `eth_tx` onto `uo_out[2]` with no dbg fallback** —
one assignment instead of a mux, but breaks the reset-default rule; recorded,
not recommended.

### G7. First consumer and acceptance tests — RECOMMENDED DEFAULT: a fixed 42-byte ARP request, decoded at the pin, then looped back through the RX chain

`firmware/eth_tx_arp.pe` pushes a constant ARP request (14-byte header +
28-byte ARP payload; hardware pads to 60 and appends the FCS) and polls
`TXSTAT`; `tb_pe_soc_eth_tx.v` decodes the real Manchester waveform at the SoC
pin; a pad-level case in `tb_tt_um_protocol_emulator` decodes `uo_out[2]`; and
a loopback TB wires the tx pad to the rx pin so the frame crosses the entire
verified RX chain FCS-clean. Directed acceptance frames: 42 bytes (padded,
FCS over pad), exactly 64 bytes (no pad, boundary), 1,514 bytes (maximum),
1,515 bytes (refused), 13 bytes (refused as sub-header), an aborted frame, and
two frames at the minimum IFG.

Alternatives: first consumer = an ARP **reply** derived from a received
request (exercises RX→TX interleave and firmware header swaps; a good second
step after the fixed request); first consumer = an ICMP-echo-shaped frame
(larger payload, no ARP semantics; a weaker demonstration).

### G8. Mutation-suite plan — RECOMMENDED DEFAULT: one unit suite plus one loopback suite

`regress/mutate_eth_tx_tb.sh` (unit, ≥14 mutations): preamble one bit short /
long, preamble phase inverted, SFD order flipped, CRC not cleared at frame
start, FCS emitted un-complemented, field mode shortened or lengthened, pad inserted before
the FCS, pad omitted, pad not folded into the CRC, IFG 95 cells, overlength
accepted, underrun silent, idle square wave, octet order MSB-first, `tx_done`
before the FCS. `regress/mutate_eth_tx_loop_tb.sh` (loopback/integration,
≥7): owner mux stuck on SERDES, overlay not driven, pad not mapped,
`cell_en` doubled, RX capture disconnected, FCS verdict swapped to
`crc_zero`, window push wrap landing in `CTRL`. Both harnesses follow the
house convention: baseline must pass first, each mutation must be detected,
sources are snapshotted with `cp` and restored with `cmp`-verified copies
(never `git checkout` — gotcha 63), `EXIT`/`INT`/`TERM` traps restore, and
`run_all.sh` gains both suites.

## Review Focus

Input classes and failure modes the spec implies but the tasks' obvious tests
may not exercise. Each is pinned to the task that owns the code.

1. **Idle is a constant, not "stop driving".** `pe_manch` toggles the wire
   every half-cell for any constant `tx_bit`; the FSM must output
   `half_phase` when idle. Task 2's unit TB checks a long idle stretch for
   zero transitions; Task 4 checks it at the pad.
2. **The FCS register's end state, not just the wire bits.** `pe_crc`'s
   field-mode trap makes the emitted bits identical whether the complement is
   inside the feedback or on the wire; only the register's drain-to-zero
   differs. Task 2 checks both the emitted 32 bits against an independent
   left-shifting model and the register's post-field value.
3. **Padding is data.** Pad zero bits must be folded into the FCS and counted
   toward the 64-byte minimum; the RX side already folds pad and does not
   store it, so a TX that skips the fold still looks fine to a byte compare
   but fails the residue. Task 2 pins this with a 42-byte frame.
4. **The SFD cannot be matched as a byte.** Task 1's decoder assembles
   LSB-first and looks for the 64-bit wire prelude; the `0xAA` helper trap is
   the reason the TX side is checked at the bit level.
5. **The staging FIFO deadline.** The CPU writes on the SoC clock while
   `cell_en` drains at 100 ns/bit (800 ns/byte); an underrun must be a sticky,
   observable fault (never a silent gap), and the push wrap must stay inside
   16-23 so a burst can never write `CTRL`. Tasks 1-3 cover both.
6. **IFG and the receiver's hunt gate.** 96 cells (576 clk) is the standard's
   number and the receiver needs only 8 idle cells; a short IFG breaks the
   *loopback* even though TX alone looks correct. Task 5's two-frame
   acceptance and Task 6's IFG mutation pin it.
7. **Owner arbitration is exclusive.** The frame engine and the SERDES share
   `u_tx_codec`; a frame start while `ser_tx_busy` (or a `tx_path` clear while
   mid-frame) must be refused with a busy status, not interleaved. Task 3
   owns the mux and its directed cases.
8. **The reclaimed pad vs every existing persona.** The wrapper mux must keep
   `uo_out[7:2] == dbg_pc[5:0]` at reset and under every non-TX firmware; only
   an enabled TX persona may observe the swapped bit. Task 4 makes this a
   permanent check in `tb_tt_um_protocol_emulator`.

## Tasks

### Task 1: Unit TB first — `tb/tb_pe_eth_tx.v` (RED on the pre-change tree)

**Files:**
- Create: `tb/tb_pe_eth_tx.v`

**Interfaces:**
- Drives: `clk` (60 MHz), `cell_en` (one clk pulse every 6), `half_phase`
  (level toggling every 3 clk), the push/FIFO interface, `TXLEN`, `start`,
  `abort`, `enable`.
- Observes: `tx_bit`, `tx_busy`, `tx_done`, `tx_underrun`, `tx_overlong`,
  FIFO readiness. The TB owns the Manchester decode and the reference FCS
  (independent left-shifting model, as `tb_pe_eth_mac` does).

- [ ] **Step 1: Write the TB and its decode.** Reuse `tb_pe_eth_mac`'s
  conventions verbatim: `lvl_of(bit, half)`, cells sampled at half-cell
  boundaries, octets LSB-first, the 64-bit prelude as a wire pattern, and
  `ref_crc32` implemented as a left-shifting reflected datapath so agreement
  is evidence rather than the DUT marking its own homework.
- [ ] **Step 2: Define the directed frame set.** A 42-byte ARP request
  (padded), an exactly-64-byte frame (no pad), a 1,514-byte maximum frame, a
  1,515-byte overlength (fault), a 13-byte sub-header (fault), a mid-frame
  `abort`, an underrun case, a long idle stretch, and two back-to-back frames
  at the minimum IFG.
- [ ] **Step 3: Run it on the pre-change tree.** Command:
  `cd sim && iverilog -g2012 -s tb_pe_eth_tx -o /tmp/tb_pe_eth_tx.vvp ../rtl/pe_eth_tx.v ../rtl/pe_crc.v ../tb/tb_pe_eth_tx.v`
  Expected: the compile fails because `pe_eth_tx` does not exist. That is RED.
- [ ] **Step 4: Freeze the check list in the TB header** (what each check
  proves, what it would miss), per house style.

### Task 2: Implement `rtl/pe_eth_tx.v` (the frame engine + its own `pe_crc`)

**Files:**
- Create: `rtl/pe_eth_tx.v`
- Modify: `regress/synth_area.sh` (standalone `report pe_eth_tx` line, so the
  mapped figure is visible from the first commit)

**Interfaces (the contract the tasks below consume):**

```verilog
module pe_eth_tx #( parameter int MAX_STORED = 1514 ) (
  input  logic       clk, rst_n,
  input  logic       enable,        // tx_path: owns u_tx_codec.tx_bit
  input  logic       cell_en,       // one strobe per Manchester cell (DIV=6)
  input  logic       half_phase,    // Manchester half-cell level
  // frame source (staging FIFO write side, fed by the window)
  input  logic       push, input logic [7:0] push_byte,
  output logic       push_ready,
  input  logic [11:0] frame_len,    // stored bytes, 14..1514
  input  logic       start, abort,
  // status
  output logic       tx_busy, tx_done, tx_underrun, tx_overlong,
  // raw bit into u_tx_codec (Manchester cfg=0x04)
  output logic       tx_bit
);
```

- [ ] **Step 1: Write the module header** with the state list, the wire-order
  table from this plan, the idle trap, the FCS field-mode trap, and the
  runt/jabber policy. No timescale.
- [ ] **Step 2: Implement the FSM**: `IDLE/IFG/PREAMBLE/DATA/PAD/FCS/END`
  (faults fold into IDLE with sticky flags). IDLE emits `tx_bit =
  half_phase` while `enable`; PREAMBLE counts 56 wire bits then the 8 SFD
  bits; `crc_clr` one cycle at PREAMBLE entry; DATA shifts each FIFO byte out
  LSB-first and folds every bit; PAD emits zeros to 60 stored bytes, folded;
  FCS asserts `crc_field` for 32 cells; END starts the 96-cell IFG and pulses
  `tx_done`.
- [ ] **Step 3: Implement the FIFO and the length/fault checks.** 8-byte
  staging FIFO; `start` refused (returns busy) while `tx_busy` or when
  `frame_len < 14 || frame_len > MAX_STORED` (sticky `tx_overlong`);
  FIFO-empty mid-frame → sticky `tx_underrun` and return to IDLE; `abort`
  returns to IDLE after the current cell.
- [ ] **Step 4: Instantiate the TX-dedicated `pe_crc #(.W(32))`** with the
  generated constants and fold/field wiring; the register state is observed by
  the TB.
- [ ] **Step 5: Run the Task 1 TB green.** `iverilog … && vvp`; expect
  `PASS: tb_pe_eth_tx`. Fix the FSM, not the TB, when a check fails — unless
  the check itself is wrong, in which case record why.
- [ ] **Step 6: Register the TB in `run_all.sh`** with its source list
  (`rtl/pe_eth_tx.v rtl/pe_crc.v`), and run `regress/lint.sh` clean.

### Task 3: Integrate into `pe_soc` — the extended window, the owner mux, DIV=6

**Files:**
- Modify: `rtl/pe_soc.v` (window: 5-bit index + upper bank; new engine
  section wiring; header memory map and engine contract)
- Modify: `regress/run_all.sh`, `regress/synth_area.sh`, `flow/pe_soc.json`,
  `info.yaml`, `tools/checks/macro_flow_config.py` and the mutation-harness
  source lists (the same-list rule)
- Create: `tb/tb_pe_soc_eth_tx.v`

**Interfaces:**
- Window indices 16-23 push-and-wrap; 24/25 `TXLENL/H`; 26 `TXCTRL`
  (`frame_start` one-cycle strobe, `frame_abort`, `tx_path`); 27 `TXSTAT`
  (set-beats-clear on read). Indices 0-15 are unchanged.
- `u_tx_codec.tx_bit = tx_path ? eth_tx_bit : ser_tx`; `pe_eth_tx.enable =
  eng_en && tx_path`; `tx_path` refuses to clear while `tx_busy` (status says
  busy); a frame start while `ser_tx_busy` is refused.
- `DIV = 6` for 10BASE-T personas (documented in the SoC header), `cfg = 0x04`
  (Manchester, no stuff), `eng_txsel = 0` (overlay bit 7). `cell_en` and
  `half_phase` come from the existing divider unchanged.

- [ ] **Step 1: Write `tb_pe_soc_eth_tx.v` first** (RED): load
  `firmware/eth_tx_arp.pe`, run the SoC, decode `dut.eng_tx_wire` (the codec
  output before the matrix) at the pin, and check the frame + `TXSTAT`. On the
  pre-change SoC the upper index bit is ignored (`io_wdata[3:0]`), so those
  writes alias indices 0-11 (a push byte of `0x10` would hit `CTRL`) and no
  frame appears — the TB's watchdog reports RED.
- [ ] **Step 2: Extend the window.** `win_index`/`win_phase` width, the
  upper-bank push decode with the 16-23 wraparound, the new read views for
  27, and the special-cased one-cycle strobes for 26; prove indices 0-15
  behave byte-identically (the existing TBs are the proof).
- [ ] **Step 3: Instantiate `pe_eth_tx`** and wire the owner mux, the
  FIFO push, `TXLEN`, control strobes and status, keeping every unused signal
  sunk for lint.
- [ ] **Step 4: Update the `pe_soc` header** (memory map, engine section
  contract, DIV=6 note, owner/fault semantics).
- [ ] **Step 5: Run the SoC TX TB and every existing TB.** Expected:
  `PASS: tb_pe_soc_eth_tx`; 30/30 existing RTL TBs still green with the
  feature disabled at reset (the additive proof).
- [ ] **Step 6: Update every source list in one pass** (the SERDES lesson),
  then `./regress/run_all.sh --fast -j8` exit 0 and `./regress/synth_area.sh`
  clean; record the `pe_soc`/`tt_um_top` deltas.

### Task 4: Pad-level verification — the reclaimed pad and the real waveform

**Files:**
- Modify: `rtl/tt_um_protocol_emulator.v` (pin-map header, the `uo_out[2]`
  mux, `_unused` sink)
- Modify: `tb/tb_tt_um_protocol_emulator.v` (pin-map checks + the TX decode
  case)
- Regenerate: `wiki/reference/protocol-pin-budget.md` (`pin_budget.py`),
  `wiki/reference/block-diagram.md` (`block_diagram.py`), `wiki/reference/signal-names.md`
- Modify: `info.yaml` (`uio`/`uo_out` descriptions at the wrapper)

**Interfaces:**
- `uo_out[2] = pin_oe_bus[7] ? pin_out_bus[7] : dbg_pc[0]`; `uo_out[7:3]`
  keep `dbg_pc[5:1]`; RX stays `ui_in[2]`.

- [ ] **Step 1: Add the wrapper mux and header note**, sink nothing new,
  keep lint clean.
- [ ] **Step 2: Extend the wrapper TB first (RED where observable).** Check
  (a) reset/non-TX: `uo_out[7:2] === dbg_pc[5:0]` continuously, and the pad
  is not X; (b) TX persona: `uo_out[2]` Manchester-decodes to the expected
  frame with the reference FCS, the pad is push-pull driven while active, and
  it returns to `dbg_pc[0]` when the persona is disabled.
- [ ] **Step 3: Regenerate the gated pages** and confirm the pin budget still
  reports 19 of 24 committed with `uo_out[2]`'s function updated (or the
  reconciled baseline if G6 is amended).
- [ ] **Step 4: Run `tb_tt_um_protocol_emulator` and the full fast
  regression.**

### Task 5: First consumer, loopback acceptance and firmware timing

**Files:**
- Create: `firmware/eth_tx_arp.pe`, `firmware/eth_arp_echo.pe`
  (the second adds the RX loop; both hex images committed)
- Modify: `regress/run_firmware_tests.sh` (assemble both)
- Create: `tb/tb_pe_soc_eth_loop.v`
- Modify: `tools/fw/peasm.py` only if a new port symbol is needed (the window
  is already `ENGINE = 0xF`)

**Interfaces:**
- `eth_tx_arp.pe`: write `TXLEN=42`, push 42 bytes, `frame_start`, poll
  `TXSTAT.done`, store a done flag in dmem (the TB's observable).
- `eth_arp_echo.pe`: the same push, then the existing `eth_rx.pe` poll/walk
  loop over the looped-back frame.

- [ ] **Step 1: Write `firmware/eth_tx_arp.pe` and watch the SoC TB fail
  on the pre-integration RTL** (window writes are no-ops; watchdog). RED
  evidence before the RTL lands, as with every other consumer.
- [ ] **Step 2: Measure the push loop's cycles per byte** against the
  48-clk budget and record the slack in the plan's status when implemented;
  if <1.5× slack, revisit G1/G2 (the buffer alternatives) before proceeding.
- [ ] **Step 3: Add the loopback TB.** Wire `pin_out_bus[7]` to
  `pin_in_bus[7]` in the TB, load `eth_arp_echo.pe`, and check the RX
  consumer's dmem exactly as `tb_pe_soc_eth` does (length, EtherType, byte
  sum, FCS-clean) — the chip exchanges a real frame with itself.
- [ ] **Step 4: Two-frame IFG acceptance**: back-to-back frames at the
  minimum gap both arrive FCS-clean, and the RX chain reports exactly two.
- [ ] **Step 5: Register both TBs in `run_all.sh`** and run the full fast
  regression (firmware count rises by two).

### Task 6: Mutation suites

**Files:**
- Create: `regress/mutate_eth_tx_tb.sh` (unit)
- Create: `regress/mutate_eth_tx_loop_tb.sh` (loopback/integration)
- Modify: `regress/run_all.sh`

- [ ] **Step 1: Write the unit harness** with the G8 mutation list; baseline
  passes first; each mutation must fail the TB; restore is a `cp` snapshot
  with `cmp` verification after every mutation; signal traps restore.
- [ ] **Step 2: Write the loopback harness** with the integration mutations
  (owner mux, overlay, pad map, doubled `cell_en`, RX disconnect, `crc_zero`
  verdict swap, push-wrap into `CTRL`).
- [ ] **Step 3: Wire both into `run_all.sh`** (suites 11 and 12) and record
  the counts in the status block and the log.

### Task 7: Hardening, screens and the documentation close-out

**Files:**
- Modify: `wiki/STATUS.md`, `wiki/log.md`, `HANDOFF.md`,
  `wiki/index.md`, `diagrams/project-plan.puml`,
  `diagrams/project-progress.puml` (the `eth_tx` open block retires)
- Regenerate: every `tools/gen/*.py` page touched
- Create: `reviews/2026-09-24/ETH-TX-FRAME-PATH-REVIEW.md` (or the date of
  implementation) with the RED/GREEN evidence, hashes and limits

- [ ] **Step 1: Run the final full regression** (`run_all.sh --fast -j8`)
  and `synth_area.sh`; copy exact counts into STATUS, never guessed numbers.
- [ ] **Step 2: Mapped OpenSTA screen** at 16.667 ns on the new classes —
  the frame FSM, the FIFO read path, the FCS/CRC path, the owner mux and the
  pad mux — on both `pe_soc` and `tt_um_top`, slow/typ/fast, with the
  ZERO/BOARD variants used by Task 5b where direct inputs are involved.
  Record "no new violation class" or the specific new holds; slow corner is
  also the hold corner. No physical flow, DRC or LVS.
- [ ] **Step 3: Update the canonical docs**: STATUS item 9 and item 4, the
  block diagram/glossary, both diagrams, the concept page (the TX path's
  contract and its traps), `wiki/log.md`, `wiki/index.md`, and `HANDOFF.md`'s
  top block in the established style.
- [ ] **Step 4: Review record** with source hashes, exact commands, RED
  transcripts, mutation tables and limits; link it from the plan's Status.

## Self-Review

**1. Spec coverage.** The manager's required coverage maps to: preamble/SFD
insertion → G3 + Task 2 Step 2; FCS append semantics, `crc_zero` ban and the
catalogue residue → Global Constraints + G4 + Task 2 Step 4; 64-byte minimum
and maximum-length handling → the wire-order table + G1/G2 + Task 2 Step 3;
IFG = 96 bit times → the table + Task 2 Step 2 + Task 5 Step 4; runt/jabber
policy → Task 2 Step 3 (pad below 60, refuse above 1,514); 100 ns bit period
at the locked 60 MHz / SPB=12 grid → Global Constraints + G5; pad-level
verification driving real Manchester and decoding at the pin → G7 + Tasks 4-5.

**2. Placeholder scan.** Every step names its files, interfaces, commands and
expected result. The only deliberately non-exact text is the measured counts
in Task 7, which must come from the regression output.

**3. Type consistency.** `TXLEN` is 11 bits (14..1514 fits `[10:0]` in 24/25);
`frame_len` is 12 bits at the module port so 1,515 is representable for the
refusal check; `cell_en` counts both prelude and frame cells, `TXLEN` counts
stored bytes only; `crc_field` is a level for exactly 32 `cell_en` strobes;
the push wrap is arithmetic inside 16-23 and never reaches `CTRL` (index 0).

**4. Review Focus.** Items 1-8 each name the failure mode and the task that
pins it; items 1-3 are the three traps carried from existing block headers
(idle via `half_phase`, field-mode register state, pad-as-data), so the plan
is standing on recorded defects, not invented ones.

**5. Not decided silently.** G1-G8 are the manager's scope groups; each has a
recommended default and priced alternatives. Nothing in this plan presumes a
choice the manager has not been offered.
