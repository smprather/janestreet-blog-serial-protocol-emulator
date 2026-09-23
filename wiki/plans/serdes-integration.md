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

This plan is **review-only**: no RTL changes until it is accepted.

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

**TX.** `serdes.tx_ser -> codec.tx_bit`; `codec.tx_wire` goes to a **per-pin
overlay mux** inside `pe_soc` *before* the matrix's output register:
`pin_out[i] = overlay_en[i] ? tx_wire : matrix_out[i]`, while `pin_oe[i]` /
`pin_od[i]` stay entirely under firmware/matrix control. A released pin is
never driven by the engine; open-drain personas can keep using the matrix path
or set OE appropriately. Reset default: overlay disabled on every pin — the
existing bit-banged personas are bit-identical.

**RX.** One capture path, not two: route the engine's RX through the existing
`pe_dru` (`rx_wire`, `rx_first`, `rx_second`, `bit_en`, `locked`), whose input
is already the synchronized pin. Two modes:
- **DRU-decoded (Manchester)**: `dru.bit_en` (half-cell cadence) +
  `rx_first/rx_second` feed the codec; `manch_en = 1`.
- **Plain/NRZI/stuffed**: `dru.rx_wire` feeds the codec; the strobe comes from
  the new timing block at the bit rate.
A later refactor could replace the dedicated `pe_manch` in the eth RX chain
with `codec_mux`; **not in this change** — the receive chain is signed off and
must not be disturbed.

**Timing/strobe block (new, small).** A programmable divider:
`bit_en` every `DIV+1` clk cycles, plus a `half_phase` toggle at twice the rate
when Manchester is enabled, plus an optional single-shot for firmware-paced
modes. Sources: the new divider for TX and plain RX; `pe_dru.bit_en` for
Manchester RX. This is the only new stateful block; it is protocol-agnostic and
has no notion of baud — the divisor is a register.

## Control/status semantics and CPU/firmware access

The binding constraint is the **4-bit IO space**: `0xF` is the only free port,
and widening the port field would touch the ISA, `pe_cpu`, `peasm` and every
firmware. Recommendation: an **indexed register window at `0xF`**, no ISA
change:

- `OUT 0xF, A` with `A[7] = 1` sets `INDEX <= A[3:0]`.
- `OUT 0xF, A` with `A[7] = 0` writes `REG[INDEX] <= A[7:0]`; a read returns
  `REG[INDEX]`. Every access auto-increments `INDEX` (16-entry wrap), so a
  32-bit word is one index write plus four data accesses.

Proposed 16-entry map (values are a shape to review, not a freeze):

| Idx | Name | R/W | Meaning |
|---|---|---|---|
| 0 | `CTRL` | w | engine enable, `tx_load`, `rx_start`, `clr`, `cfg_lsb_first`, TX-pin select |
| 1 | `CFG` | w | `codec_mux.cfg` byte (stuff/nrzi/manch/half_phase/run/ones_only) |
| 2-3 | `DIVL/DIVH` | w | bit-strobe divisor |
| 4 | `LEN` | w | `tx_len`, `rx_len` (5+5 packed) |
| 5 | `STATUS` | r | `tx_busy/tx_done/rx_busy/rx_valid/rx_err/dru_locked/engine_en` |
| 6-9 | `TXDATA` | w | 32-bit TX word (MSB-last or first, per `cfg_lsb_first`) |
| 10-13 | `RXDATA` | r | 32-bit RX word |
| 14-15 | spare | - | future personas / status |

Reset default: engine disabled, overlay off, `REG` reads 0 — every existing
TB and firmware is unaffected. Firmware cost: ~5 IO accesses per engine word,
which is why this is a resource for the paced/stretch personas, not a
replacement for bit-banging the baseline ones. The alternative (5-bit IO
space) is a separate, larger decision and is **explicitly out of scope**.

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
4. **First consumer** (recommended): a 10BASE-T TX check driven from
   `pe_eth_mac`/`pe_fbuf` or firmware, decoded by a Manchester receiver model,
   which is the actual reason the engine is needed. If the reviewer prefers,
   the first consumer can instead be an engine-paced plain UART TX.
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
- **Strobe fanout**: one `bit_en` reaches serdes, codec (three stages) and the
  DRU-derived branch; check max-fanout and skew.
- **32-bit shift registers** and the 16x8 window bank are flop-based; the area
  delta is known but the window's read-mux path must be checked for
  timing/depth.
- The existing eth RX chain is untouched; its recorded STA facts stay valid.

## Pad / persona implications

- **No new pads.** The engine uses the same port bits and the matrix's OE/OD;
  the loader (`ui[3:5]`), the SPI pads (`uio[2:3]`), I2C (`uio[0:1]`) and the
  debug pins are unchanged. The pin budget is unchanged by the engine itself
  (it is routing, not new IO).
- **Personas enabled**: 10BASE-T TX, USB-LS (NRZI + ones-only stuffing), CAN
  (stuffing), and hardware-paced plain protocols. JTAG/SWD/PS/2 remain
  optional targets.
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
6. First-consumer TX test (10BASE-T or engine-paced UART).
7. `synth_area.sh` + native yosys/OpenSTA screen; update STATUS, block diagram
   (orphans retire), log and the progress diagram.

## Open decisions for the reviewer

1. **Scope**: additive engine (recommended) vs. migrating the baseline
   personas onto it now.
2. **Access**: the `0xF` indexed window (recommended) vs. widening the IO space
   (ISA/CPU/assembler change; out of scope here).
3. **RX path**: DRU as the single capture path (recommended) vs. a second
   synchronizer for plain modes.
4. **First consumer**: 10BASE-T TX (recommended, it motivates the engine) vs.
   an engine-paced plain UART.
5. **Manchester output**: combinational cascade (start) vs. a registered output
   stage (if STA demands it).

No RTL was changed; no physical flow, DRC or LVS was run.
