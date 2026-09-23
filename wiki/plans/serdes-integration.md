---
title: Integrate pe_serdes + pe_codec_mux into pe_soc
created: 2026-09-23
updated: 2026-09-23
type: plan
tags: [architecture, integration, serdes, codec, timing, pads]
sources: [rtl/pe_serdes.v, rtl/pe_codec_mux.v, rtl/pe_soc.v, rtl/pe_dru.v, rtl/pe_pinmux.v, tb/tb_pe_serdes.v, tb/tb_pe_codec_mux.v, diagrams/project-plan.puml, wiki/reference/block-diagram.md, wiki/plans/ethernet-soc.md]
confidence: high
---

# Integrate `pe_serdes` + `pe_codec_mux` into `pe_soc`

## Why

`pe_serdes` (539 cells) and `pe_codec_mux` (130 cells: `pe_bitstuff` 99,
`pe_nrzi` 15, `pe_manch` 7, glue) are the last two **built, TB-verified,
instantiated-nowhere** blocks (`wiki/reference/block-diagram.md`). They are the
shared word engine and the line-code pipeline the stretch personas need:
10BASE-T **transmit** (the receive chain is already in `pe_soc`), low-speed USB
(NRZI + stuffing), CAN (stuffing), and a hardware-paced path for plain
protocols. The project-plan diagram already draws them inside the SoC with
`cpu ..> serdes` and `codec ..> pads` as planned.

This plan is **review-only**: no RTL changes until it is accepted. It was
amended 2026-09-23 after the first review (window encoding, LENW, strobe split,
overlay insertion point, TX-consumer scope); the findings and their
source-grounded resolutions are recorded in
`reviews/2026-09-23/SERDES-INTEGRATION-REVIEW.md`.

## What the blocks actually contract (source-grounded)

**`pe_serdes`** — one shift engine, two independent sides:

| Side | Inputs | Outputs | Semantics |
|---|---|---|---|
| TX | `tx_load`, `tx_data[31:0]`, `tx_len[5:0]`, `cfg_lsb_first` | `tx_ser`, `tx_busy`, `tx_done` | load/start while busy **restarts**; bit order and length snapshot at load; `tx_ser` idles **high** |
| RX | `rx_ser`, `rx_start`, `rx_len[5:0]`, `cfg_lsb_first` | `rx_data[31:0]`, `rx_busy`, `rx_valid` | first bit lands at `rx_data[0]` (LSB-first) or `[rx_len-1]` (MSB-first); `rx_valid` is one cycle behind the final strobe |

Shared: `clk`, `rst_n`, `bit_en` (one strobe per bit cell, from the timing
block). `MAXLEN = 32`; lengths 0/`>MAXLEN` are out of contract. `rx_ser` must
already be synchronized/captured (ADR-002 lazy capture) — the block is
single-edge and does not synchronize.

**`pe_codec_mux`** — fixed-order, runtime-bypassable pipeline:

- TX: `tx_bit -> [stuff] -> [nrzi] -> [manch] -> tx_wire`.
- RX: `rx_wire -> [manch] -> [nrzi] -> [stuff] -> rx_bit`.
- `cfg[0]` stuff, `cfg[1]` NRZI, `cfg[2]` Manchester, `cfg[3]` `half_phase`
  (timing-driven half-cell select), `cfg[6:4]` run length (0 => 5; CAN 5, USB 6),
  `cfg[7]` ones-only (USB 0xE3 vs CAN 0x63).
- `bit_en` is the **cadence the timing block must supply**: one per raw bit for
  plain/NRZI/stuffed modes, one per **half-cell** (with `half_phase` toggling)
  for Manchester. `clr` resets the pipeline state.
- TX stuff/manch stages are combinational; NRZI's line level is registered and
  lands at the strobe. RX reports `rx_err` (stuffing/NRZI violations).

**`pe_soc` today** — deliberately no protocol hardware: CPU + tick timer +
`pe_pinmux` + SRAM/dmem/fbuf + the 10BASE-T receive chain
(`pe_dru -> pe_manch -> pe_eth_mac` + `pe_crc` + `pe_fbuf`). The CPU's IO space
is **4 bits** (`io_port[3:0]`), ports `0x0..0xE` are allocated (`0xE` BUFCTRL),
and **`0xF` is free**. The tick timer gives half-bit ticks
(`TICKS_PER_BIT = CLK_HZ/BAUD/2`) and I2C 1 µs ticks — but no hardware bit
strobe. `pe_dru` is the only lazy-capture path: `rx_pin -> bit_en`,
`rx_first/rx_second/rx_wire`, `locked`, with `SPB = 12`. `pe_pinmux` owns
per-pin out/oe/od, and firmware reads pins back through it.

**TBs and gaps.** `tb_pe_serdes` and `tb_pe_codec_mux` cover the units
(boundaries, bit orders, all codec subsets, stage timing). There is **no
mutation suite for either block** (the seven suites cover i2c, spi, fbuf,
eth_mac, eth_soc, ctrl, i2c_xfer), and no SoC- or top-level instance.

## Architectural position: why this does not break the thesis

`pe_soc`'s header says "there is NO protocol hardware in this file... no shift
register, no framing logic, no baud generator that knows what a bit is." This
integration adds a shift register and a code pipeline, so the claim must become
precise, not weakened:

- **No protocol-specific hardware.** Nothing in the engine knows framing,
  addresses, ACKs, or a protocol name; the word width, bit order, line code and
  strobe cadence are registers firmware sets. Protocol semantics stay in
  firmware, exactly as UART/SPI/I2C do today.
- **The engine is a pacing resource, not a mode.** It exists because firmware
  cannot bit-bang 10BASE-T's 20 MHz half-cells or USB's NRZI+stuffing chain.
  The bit-banged port path remains the default and keeps working unchanged.

The header, `wiki/concepts/spi-as-firmware.md` and the "no protocol hardware"
line in STATUS must be updated in the same change.

## Interface and data path (recommended shape)

**TX.** `serdes.tx_ser -> codec.tx_bit`; `codec.tx_wire` reaches the pin
through a per-pin **level override applied at `pe_pinmux`'s level input,
before its open-drain gate** -- not on the post-matrix `pin_out` wire. The
matrix's enable equation is
`pad_oe[i] = reg_oe[i] && (!reg_od[i] || !reg_out[i])` (`rtl/pe_pinmux.v`),
so an override that only replaced `pin_out` would leave `pad_oe` keyed to the
un-overridden register level: an engine `0` while the register held `1` on an
`od=1` pin would release instead of pulling low. The fix is to feed the
overridden level into both outputs:
`eff_out[i] = overlay_en[i] ? tx_wire : reg_out[i]`, i.e. extend the matrix
with a per-pin level override (a SoC-internal signal) rather than muxing after
it. Firmware still owns `oe`/`od`, so open-drain personas work with the engine.
Restricting v1 to push-pull pins (`od=0`) is rejected as a firmware footgun;
the pre-gate override is a small, local change. Reset default: overlay off on
every pin -- the bit-banged personas are bit-identical.

**RX.** One capture path, not two: route the engine's RX through the existing
`pe_dru` (`rx_wire`, `rx_first`, `rx_second`, `bit_en`, `locked`), whose input
is already the synchronized pin. Two modes:
- **DRU-decoded (Manchester)**: `dru.bit_en` is a **per-bit** strobe and the
  half-cell data arrives as `rx_first`/`rx_second`; that is exactly how the
  signed-off eth chain drives `pe_manch` (`half_phase = 0`). `manch_en = 1`.
- **Plain/NRZI/stuffed**: `dru.rx_wire` feeds the codec; the strobe comes from
  the new timing block at the bit rate.
A later refactor could replace the dedicated `pe_manch` in the eth RX chain
with `codec_mux`; **not in this change** — the receive chain is signed off and
must not be disturbed.

**Timing/strobe block (new, small).** Two strobes, because the serdes and the
codec run at different cadences:
- `serdes_bit_en`: once per **logical bit** -- the serdes sides advance on it.
- `codec_bit_en`: once per **codec cell**. For plain/NRZI/stuffed modes it is
  the same per-bit cadence; for Manchester TX it runs at **twice the bit
  rate** with `half_phase` toggling, and `serdes.tx_ser` is held stable across
  both half-cell strobes (`pe_manch`: `tx_wire = half_phase ? tx_raw : ~tx_raw`).
- Manchester **RX** does not use the divider: `pe_dru` gives `bit_en` once per
  decoded bit plus `rx_first`/`rx_second`, which the codec's `pe_manch`
  consumes directly (as the eth chain does). Plain/NRZI/stuffed RX uses
  `dru.bit_en` with `dru.rx_wire`.
The divider register sets the bit period; the Manchester half-cell rate is
derived from it, not from a second divisor. An optional single-shot mode lets
firmware pace plain TX by hand. This is the only new stateful block; it is
protocol-agnostic and has no notion of baud -- the divisor is a register.

## Control/status semantics and CPU/firmware access

The binding constraint is the **4-bit IO space**: `0xF` is the only free port,
and widening the port field would touch the ISA, `pe_cpu`, `peasm` and every
firmware. Recommendation: an **indexed register window at `0xF`**, no ISA
change:

- **Latched phase, all 8 data bits intact.** The window has a `phase` bit
  (reset to INDEX) and a 4-bit `INDEX` pointer:
  - `OUT 0xF, A` in INDEX phase: `INDEX <= A[3:0]`, `phase <= DATA`. The access
    carries the index, not data.
  - `OUT 0xF, A` in DATA phase: `REG[INDEX] <= A[7:0]`, `INDEX <= INDEX+1`,
    phase stays DATA -- a data burst is one index write plus N full-width
    writes.
  - `IN A, 0xF`: returns `REG[INDEX]`, `INDEX <= INDEX+1` (reads always
    auto-increment), and `phase <= INDEX`. **Any read re-arms index phase**, so
    the next write is an index write.
- Firmware sequences: write a word = `IN` (arms; use it for STATUS) + `OUT`
  index `TXDATA_lo` + 4 `OUT` data bytes; read a word = `OUT` index
  `RXDATA_lo` + 4 `IN` bytes. Mixing a write burst after a read burst costs
  the re-arming read, which can be the STATUS read.

Proposed 16-entry map (values are a shape to review, not a freeze):

| Idx | Name | R/W | Meaning |
|---|---|---|---|
| 0 | `CTRL` | w | engine enable, `tx_load`, `rx_start`, `clr`, `cfg_lsb_first`, TX-pin select |
| 1 | `CFG` | w | `codec_mux.cfg` byte (stuff/nrzi/manch/half_phase/run/ones_only) |
| 2-3 | `DIVL/DIVH` | w | bit-strobe divisor |
| 4 | `TXLEN` | w | `tx_len[5:0]`, 1..32 (0 invalid); `LENW = 6` |
| 5 | `RXLEN` | w | `rx_len[5:0]`, 1..32 (0 invalid) |
| 6 | `STATUS` | r | `tx_busy/tx_done/rx_busy/rx_valid/rx_err/dru_locked/engine_en` |
| 7-10 | `TXDATA` | w | 32-bit TX word (MSB-last or first, per `cfg_lsb_first`) |
| 11-14 | `RXDATA` | r | 32-bit RX word |
| 15 | spare | - | future personas / status |

`TXLEN`/`RXLEN` are separate because the serdes has independent sides (it can
transmit and receive at once), and a single 8-bit register cannot hold two
six-bit lengths regardless of encoding. The 6-bit 1..32 encoding follows
`LENW = $clog2(MAXLEN+1) = 6`; a 5-bit `0 => 32` encoding is an acceptable
alternative if the reviewer prefers it, but not both fields in one byte.

Reset default: engine disabled, overlay off, `REG` reads 0 -- every existing
TB and firmware is unaffected. Firmware cost: an index write plus one access
per byte; bursts amortise the index write, and switching bursts costs one
re-arming read. This is why the window is a resource for the paced/stretch
personas, not a replacement for bit-banging the baseline ones. The alternative
(5-bit IO space) is a separate, larger decision and is **explicitly out of
scope**.

## Reset and clocking

Single `clk`/`rst_n` domain, no new clocks. `rst_n` clears the engine, codec
state, divider and window. `bit_en` idles low; `serdes.tx_ser` idles high
(per its contract) but is only visible on a pin when the overlay is enabled
and OE is set. The only asynchronous paths remain the existing DRU capture and
the loader's SCLK synchronizer; the engine's `rx_ser` is always a captured
signal, never a raw pad.

## Testbench and mutation evidence (planned)

1. **Unit coverage is already there**; add the missing **mutation suites** for
   `pe_serdes` and `pe_codec_mux` (`regress/mutate_serdes_tb.sh`,
   `regress/mutate_codec_tb.sh`) so the integration is not standing on TBs no
   fault injection has ever challenged (`serdes` bit order, restart-while-busy,
   `rx_valid` timing; codec pipeline order, bypass subsets, ones-only,
   half_phase).
2. **SoC-level, additive path**: a new `tb_pe_soc_serdes` that loads a small
   firmware using the `0xF` window, drives a TX word through the overlay with a
   wire model, and loops it back through the DRU + codec + serdes RX, checking
   the word both ways. Two configurations: plain (LSB-first and MSB-first) and
   Manchester (half-cell strobes, `half_phase`), the latter decoded by the same
   model `tb_pe_soc_eth` uses.
3. **Non-regression, on the same run**: `tb_pe_soc_uart`, `tb_pe_soc_spi`,
   `tb_pe_soc_i2c_xfer`, `tb_pe_soc_tick`, `tb_pe_soc_eth` must stay green with
   the engine disabled at reset — the proof that the path is additive.
4. **First consumer, split in two**:
   - **Wire-loopback milestone (this plan)**: no frame layer. Engine TX (plain
     LSB/MSB and Manchester) drives a wire model that loops back into the DRU +
     codec + serdes RX; the word must match. This proves the engine, the strobe
     split and the overlay without any Ethernet framing.
   - **Full 10BASE-T TX consumer (separate plan/block)**: `pe_eth_mac` is
     receive-only (`rtl/pe_eth_mac.v`: `bit_en`/`rx_raw`/`rx_err`/
     `rx_first`/`rx_second` in; `fbuf_*`/`frame_*`/`crc_*` out) and `pe_fbuf`
     is the RX store -- neither can source a TX frame. A transmit path needs
     preamble/SFD generation, FCS generation (`pe_crc` is currently committed
     to the RX path, so TX needs a time-shared or duplicated LFSR), IFG/backoff
     timing, and a frame source (firmware bytes through the window, or a TX
     buffer + state machine). That is the `eth_tx` block on the progress
     diagram and gets its own plan; this plan only delivers the engine it will
     use.
5. All new TBs self-check, print `PASS`, and are registered in `run_all.sh`;
   every mutation must be independently detected and the source restored.

## Synthesis / STA hardening risks

- **Area**: +`pe_serdes` 539 + `pe_codec_mux` 130 + mux/divider/window glue
  (estimate +50-150 cells) on top of `pe_soc` 3,298 / TT top 3,613. Confirm
  with `synth_area.sh` after implementation.
- **Standalone signoff already exists**: `pe_serdes` was through full LibreLane
  Classic (2026-09-18, former 66 MHz target): **0 DRC, 0 LVS, setup WS
  +7.6 ns (slow), hold WS +0.116 ns (fast), 78% utilization**
  (`flow/run_librelane.sh flow/pe_serdes.json`). That covers the block alone,
  not the integration's overlay mux, strobe divider or fanout -- the SoC-level
  native yosys + OpenSTA screen is still required after implementation. No
  physical flow is part of this plan.
- **Combinational depth**: the stuff -> NRZI -> Manchester cascade is
  combinational into the pad-facing overlay; at Manchester's 20 MHz half-cells
  there are only **3 clk (50 ns) per strobe at 60 MHz**. The unit TB runs at
  100 MHz simulation, which proves function, not silicon timing — the
  implementation needs the native yosys + OpenSTA screen (as for pe_ctrl), and
  possibly a registered Manchester output stage if the path is too deep.
- **Strobe fanout/skew**: `serdes_bit_en` and `codec_bit_en` (Manchester runs
  the codec at twice the serdes rate) reach the shift engine, three codec
  stages and the DRU-derived branch; check max-fanout and the half-cell skew
  budget.
- **32-bit shift registers** and the 16x8 window bank are flop-based; the area
  delta is known but the window's read-mux path must be checked for
  timing/depth.
- The existing eth RX chain is untouched; its recorded STA facts stay valid.

## Pad / persona implications

- **No new pads.** The engine uses the same port bits and the matrix's OE/OD;
  the loader (`ui[3:5]`), the SPI pads (`uio[2:3]`), I2C (`uio[0:1]`) and the
  debug pins are unchanged. The pin budget is unchanged by the engine itself
  (it is routing, not new IO).
- **Personas enabled**: the 10BASE-T **wire** transmit side (the frame layer is
  a separate block), USB-LS (NRZI + ones-only stuffing), CAN (stuffing), and
  hardware-paced plain protocols. JTAG/SWD/PS/2 remain optional targets.
- **Half-duplex note**: 10BASE-T TX and RX share the RX pin (bit 7), so the
  overlay and the DRU are never enabled in opposite directions at once —
  firmware owns the turnaround through OE, and the plan must test it.

## Ordered work list (after review)

1. Header/docs correction: restate pe_soc's position as "no protocol-specific
   hardware" and link this plan.
2. Strobe/divider block + unit TB (mutation-tested).
3. `0xF` window + register file + reset defaults; CPU-visible test.
4. Serdes + codec instantiation with the overlay mux and DRU RX routing.
5. `tb_pe_soc_serdes` (plain + Manchester loopback); keep every existing TB
   green; add the two mutation suites.
6. Wire-loopback TB first (plain + Manchester); the full 10BASE-T TX consumer
   (frame/preamble/FCS/IFG/source) is a separate block and plan.
7. `synth_area.sh` + native yosys/OpenSTA screen; update STATUS, block diagram
   (orphans retire), log and the progress diagram.

## Open decisions for the reviewer

1. **Scope**: additive engine (recommended) vs. migrating the baseline
   personas onto it now.
2. **Access**: the `0xF` indexed window (recommended) vs. widening the IO space
   (ISA/CPU/assembler change; out of scope here).
3. **RX path**: DRU as the single capture path (recommended) vs. a second
   synchronizer for plain modes.
4. **First consumer**: the wire-loopback milestone (recommended; no frame
   layer) vs. an engine-paced plain UART TX. The full 10BASE-T TX frame path
   is a separate plan either way.
5. **Manchester output**: combinational cascade (start) vs. a registered output
   stage (if STA demands it).

No RTL was changed; no physical flow, DRC or LVS was run.
