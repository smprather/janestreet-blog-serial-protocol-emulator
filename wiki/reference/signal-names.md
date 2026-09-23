---
title: Signal Names
created: 2026-09-18
updated: 2026-09-18
type: reference
tags: [architecture, verification]
sources: [rtl/pe_serdes.v, rtl/pe_codec_mux.v, rtl/pe_nrzi.v, rtl/pe_manch.v, rtl/pe_bitstuff.v]
confidence: high
---

# Signal Names

Every port the RTL exposes, what it means, and when it is valid. **Port
tables are extracted from the Verilog by `tools/gen/signal_glossary.py`**
(`--check` fails if this page is stale), so a renamed port cannot leave this
page lying. The prose is the hand-written part; the interface is not.

15 modules, 182 ports.

Two terms this page assumes and [[concepts/strobe-and-committing-edge]]
defines: the **strobe** (`bit_en`) and the **committing edge**.

## Naming conventions

| Pattern | Meaning |
|---|---|
| `tx_*` / `rx_*` | Direction. `tx_` faces the wire (outbound), `rx_` faces the wire (inbound) — both are named from the **pin's** point of view, not the core's. |
| `*_en` | A strobe/enable pulse, high for one cycle (e.g. `bit_en`). Not a level. |
| `*_valid` | Qualifier meaning "this output carries real data this cycle". `rx_bit_valid=0` means the bit was a stuff bit. |
| `*_raw` | In the codecs: the plain NRZ bit, **before** line coding. `tx_raw` in, `tx_wire` out. |
| `*_wire` | The encoded bit/level as it appears on the wire. |
| `*_lvl` | A held line level, not a bit. |
| `*_err` | Line-code violation detected on receive. |
| `cfg_*` | Configuration. **Snapshot** variants (`cfg_lsb_tx`) are captured copies that protect an in-flight transfer. |
| `*_cnt` | A counter of bits moved. |
| `*_nbits` | A captured copy of the requested length (`tx_nbits`, `rx_nbits`). |
| `*_shreg` | A bit register. In `pe_serdes` the RX side is a **bit-placer**, not a shifter — see `rx_pos`. |
| `clr` | Frame boundary; resets run/symbol tracking. Not a reset. |
| `bypass` | Stage disable. Every codec stage is runtime-bypassable. |

## `pe_serdes`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. The DUT counts strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low async reset. |
| `cfg_lsb_first` | inp | 1 | Bit order. 1 = LSB first (UART), 0 = MSB first (SPI). **Snapshotted** into `cfg_lsb_tx`/`cfg_lsb_rx` at load/start, so the core may rewrite it mid-transfer without corrupting an in-flight word. |
| `bit_en` | inp | 1 | **The strobe** — one-cycle pulse meaning "this is the moment". The only thing that advances TX or captures RX. Supplied by the timing block/DRU, never by this block. See [[concepts/strobe-and-committing-edge]]. |
| `tx_load` | inp | 1 | Starts a transmit. Captures `tx_data`, `tx_len`, and the bit order. Ignored when `tx_len == 0`. |
| `tx_data` | inp | `[MAXLEN-1:0]` | Word to send. Shifted out one bit per strobe. |
| `tx_len` | inp | `[LENW-1:0]` | Bits to send, 1..MAXLEN. Captured at load; not clamped above MAXLEN (out of contract). |
| `tx_ser` | out | 1 | Serial output. Idles **high** (UART idle), driven only while `tx_busy`. |
| `tx_busy` | out | 1 | High from load until the final strobe. |
| `tx_done` | out | 1 | One-cycle pulse on the final strobe. TX-only event — see the sticky-flag note in the testbenches. |
| `rx_ser` | inp | 1 | Serial input, **expected already synchronized** (latch-pair dual-edge capture flop, ADR-002). This block is single-edge. |
| `rx_start` | inp | 1 | Starts a receive. Captures `rx_len` and the bit order. Ignored when `rx_len == 0`. |
| `rx_len` | inp | `[LENW-1:0]` | Bits to receive, 1..MAXLEN. |
| `rx_data` | out | `[MAXLEN-1:0]` | Assembled word. Payload always lands in `[rx_len-1:0]` regardless of bit order. |
| `rx_busy` | out | 1 | High from start until the final strobe — drops one cycle **before** `rx_valid`. |
| `rx_valid` | out | 1 | Word complete. Delayed one cycle past the final strobe by design (so `rx_data` can copy the register without a variable-shift path). |

## `pe_bitstuff`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `bit_en` | inp | 1 | **The strobe** — one-cycle pulse meaning "this is the moment". The only thing that commits state in this block. Supplied by the timing block/DRU. See [[concepts/strobe-and-committing-edge]]. |
| `bypass` | inp | 1 | 1 ⇒ pass the raw bit through untouched (no stuffing). |
| `clr` | inp | 1 | Frame/SOF boundary — reset run tracking. |
| `run_cfg` | inp | `[3:0]` | Stuff after this many identical bits (5 = CAN, 6 = USB-LS). |
| `ones_only` | inp | 1 | 1 ⇒ only a run of ONES is stuffed (USB 1.1 §7.1.9); 0 ⇒ a run of either polarity (CAN). Counters saturate on a run that cannot be stuffed, because a USB zero run is unbounded. |
| `tx_raw` | inp | 1 | Raw bit in. |
| `tx_wire` | out | 1 | Bit out, with stuff bits inserted. |
| `tx_stuffed` | out | 1 | A stuff bit is owed on the **next** strobe (`tx_pend`); the raw input is ignored on that strobe. |
| `rx_wire` | inp | 1 | Wire bit in. |
| `rx_raw` | out | 1 | Bit out, with stuff bits removed. |
| `rx_raw_valid` | out | 1 | 0 ⇒ this wire bit was a stuff bit. |
| `rx_err` | out | 1 | The bit after a full run was not complementary. |

## `pe_codec_mux`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `cfg` | inp | `[7:0]` | Stage select. `cfg[0]` stuff, `cfg[1]` NRZI, `cfg[2]` Manchester, `cfg[3]` `half_phase`, `cfg[6:4]` `run_cfg` (0 ⇒ default 5), `cfg[7]` `ones_only` (1 ⇒ stuff only runs of one, USB; 0 ⇒ either polarity, CAN). The USB configuration byte is **`0xE3`** (stuff + NRZI, run 6, ones-only); CAN is **`0x51`** (stuff + run 5 — `0x01` is equivalent, its run nibble 0 means the default 5). `0x05` would set `cfg[2]` and enable Manchester, so it is not a CAN preset. Using the old `0x63` selects symmetric stuffing and corrupts USB zero runs. |
| `bit_en` | inp | 1 | **The strobe** — one-cycle pulse meaning "this is the moment". The only thing that commits state in this block. Supplied by the timing block/DRU. See [[concepts/strobe-and-committing-edge]]. |
| `clr` | inp | 1 | Frame/SOF boundary — resets stuffing run tracking. |
| `tx_bit` | inp | 1 | Raw bit in from the SM/SERDES. |
| `tx_wire` | out | 1 | Encoded bit out to the pin matrix. |
| `tx_stuffed` | out | 1 | This strobe emits a stuff bit; the raw input is ignored. |
| `rx_wire` | inp | 1 | Wire bit in from the pin matrix / DRU. |
| `rx_first` | inp | 1 | Manchester first half-cell sample (from the DRU). |
| `rx_second` | inp | 1 | Manchester second half-cell sample (from the DRU). |
| `rx_bit` | out | 1 | Decoded raw bit out. |
| `rx_bit_valid` | out | 1 | 0 ⇒ this wire bit was a stuff bit and carries no data. |
| `rx_err` | out | 1 | Line-code violation (e.g. a bit after a full run that is not complementary). |

## `pe_cpu`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low asynchronous reset. |
| `run` | inp | 1 | _no note yet_ |
| `imem_addr` | out | `[((IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS))-1:0]` | _no note yet_ |
| `imem_rdata` | inp | `[15:0]` | _no note yet_ |
| `dmem_addr` | out | `[((DMEM_BYTES <= 2) ? 1 : $clog2(DMEM_BYTES))-1:0]` | _no note yet_ |
| `dmem_we` | out | 1 | _no note yet_ |
| `dmem_wdata` | out | `[7:0]` | _no note yet_ |
| `dmem_rdata` | inp | `[7:0]` | _no note yet_ |
| `io_port` | out | `[3:0]` | _no note yet_ |
| `io_we` | out | 1 | _no note yet_ |
| `io_re` | out | 1 | _no note yet_ |
| `io_wdata` | out | `[7:0]` | _no note yet_ |
| `io_rdata` | inp | `[7:0]` | _no note yet_ |
| `dbg_pc` | out | `[7:0]` | Program counter, for observability. A real PORT, not a hierarchical reference from the parent: a cross-module reference simulates but does not synthesise. |
| `dbg_a` | out | `[7:0]` | Accumulator, for observability. See dbg_pc. |

## `pe_crc`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low asynchronous reset. |
| `bit_en` | inp | 1 | **The strobe** — one-cycle pulse meaning "this is the moment". One strobe per **wire bit**, in transmission order. See [[concepts/strobe-and-committing-edge]]. |
| `clr` | inp | 1 | Frame boundary: `R <= cfg_seed` and the verdict drops. Wins over `bit_en`. This is a re-seed, NOT a reset — a frame boundary is not a power cycle. Note the ordering rule it creates: a consumer must latch the verdict before clearing for the next frame. |
| `crc_field` | inp | 1 | Level. While high, the block emits the CRC field: `crc_bit` is driven out and the register does a pure shift, so it drains to zero. |
| `bit_in` | inp | 1 | Wire bit in, transmission order. Ignored while `crc_field` — the block feeds its own output back on those strobes. |
| `cfg_poly_r` | inp | `[W-1:0]` | **The REVERSED polynomial**, low-justified (`rev(poly, Wcrc)`, not `rev(poly, 32)`). One expression serves both CRC families; see [[reference/crc-config]] for every value. |
| `cfg_seed` | inp | `[W-1:0]` | Seed in R orientation, low-justified: `init` for a reflected algorithm, `rev(init, Wcrc)` for a non-reflected one. |
| `cfg_out_inv` | inp | 1 | 1 ⇒ complement the field bits on the wire (Ethernet FCS, USB CRCs). Expresses `xorout` because every target's is all-ones or all-zeros. Applies to `crc_bit` only, never to the feedback — see the RTL header for why that distinction is load-bearing. |
| `crc_bit` | out | 1 | The field bit for this strobe: `R[0] ^ cfg_out_inv`. LSB-first of `R` is LSB-first of the CRC for a reflected algorithm and **MSB-first** of it for a non-reflected one, which is correct for both. |
| `crc_zero` | out | 1 | **A status, not an event.** Asserts after the final field strobe and holds until `clr`. Means "the frame at this boundary is clean" — the register drains to zero for a transmitter and for a receiver that folds the field un-complemented. |
| `crc_state` | out | `[W-1:0]` | The register, for observability and firmware readback. Reading the CRC a receiver computed means sampling it at the right strobe, which is a firmware-timing decision, not a feature of this port. |

## `pe_ctrl`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low asynchronous reset. |
| `spi_sclk` | inp | 1 | The loader clock pad. **Asynchronous**: synchronized with 2 flops and sampled on the rising edge (SPI mode 0). ≤ ~10 MHz at the 60 MHz core. |
| `spi_mosi` | inp | 1 | Loader data, MSB-first, sampled on the rising SCLK edge while CS_N is low. |
| `spi_cs_n` | inp | 1 | Active-low load select. A falling edge resets the word address to 0 and clears the sticky error; a rising edge ends the load and discards a partial word. |
| `run` | inp | 1 | The core's run strap. Every receive and write path is gated on `!run`, so a load can never overwrite executing code. |
| `host_we` | out | 1 | One-cycle write pulse, one per completed 16-bit word, into the SoC's host port. |
| `host_imem_sel` | out | 1 | Held 1: v1 loads instruction memory only. |
| `host_addr` | out | `[((((WORDS <= 2) ? 1 : $clog2(WORDS)) > 8)
                 ? ((WORDS <= 2) ? 1 : $clog2(WORDS)) : 8)-1:0]` | Word address, incremented per completed word (0..WORDS-1). |
| `host_wdata` | out | `[15:0]` | The assembled MSB-first 16-bit word. |
| `load_active` | out | 1 | Level: selected (`CS_N` low) and `run` low. |
| `load_error` | out | 1 | Sticky until the next `CS_N` falling edge: a partial word, or a load longer than `WORDS`, was discarded. |
| `words_written` | out | `[15:0]` | Count of words handed to the host port since the current `CS_N` fell (debug/observability). |

## `pe_dru`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low asynchronous reset. |
| `rx_pin` | inp | 1 | The raw **asynchronous** pin. Synchronized internally (2 flops) before anything else touches it — this is the one place in the design where metastability would actually be sampled. |
| `cfg_filter_en` | inp | 1 | 3-tap majority on the *synchronized* pin, for a noisy cable. The output is resampled before it drives the edge detector, so turning it on removes glitches without moving an edge; off by default because on a clean line it is pure latency. |
| `cfg_lock_bits` | inp | `[7:0]` | Well-formed cells required before `locked` asserts (0 ⇒ default 4). A cell is well-formed when its two halves differ, which is the Manchester code itself. |
| `bit_en` | out | 1 | **The strobe** — one per decoded **bit cell** (not per half-cell: pe_manch is given both halves at once). This is the DRU's whole output contract. See [[concepts/strobe-and-committing-edge]]. |
| `rx_first` | out | 1 | First half-cell level of the bit `bit_en` commits. Fed to `pe_manch.rx_first`. |
| `rx_second` | out | 1 | Second half-cell level — **this is the bit value**. H→L is a 0, L→H is a 1, so the codec reads it directly. Fed to `pe_manch.rx_second`. |
| `rx_wire` | out | 1 | The latest half-cell sample, for a consumer that wants the raw oversampled level rather than Manchester bits. |
| `locked` | out | 1 | **Confidence, not a gate.** Asserted after `cfg_lock_bits` well-formed cells; cleared by the first malformed one. `bit_en` is emitted whether or not locked — gating on it would drop the preamble, which is the part every protocol here expects to be dropped. Nothing in this repo gates on it. |
| `dbg_phase` | out | `[3:0]` | The phase counter (distance from the last transition, mod SPB). Bring-up only; the capture phase is SPB/4 and 3·SPB/4. **SPB's ceiling is 16, not merely a multiple of 4** — this counter is 4 bits and `4'(SPB-1)` truncates above it, which silently kills all capture (SPB=20 emits nothing). Both constraints are elaboration errors in the RTL and are boundary-tested by `regress/param_guards.sh`. |

## `pe_eth_mac`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low asynchronous reset. |
| `bit_en` | inp | 1 | **The strobe** — one-cycle pulse meaning "this is the moment". The only thing that commits state in this block. Supplied by the timing block/DRU. See [[concepts/strobe-and-committing-edge]]. |
| `rx_raw` | inp | 1 | _no note yet_ |
| `rx_err` | inp | 1 | _no note yet_ |
| `rx_first` | inp | 1 | _no note yet_ |
| `rx_second` | inp | 1 | _no note yet_ |
| `buf_reset` | inp | 1 | **Whole-ring reclaim**: moves BOTH pointers to zero. Only legal when the ring is empty and nothing is in flight, so it is a testbench/debug control — the SoC does not pulse it in traffic (it caused E1). |
| `buf_consume` | inp | 1 | **Consumer-owned reclaim**: a pulse advances the READ pointer to `buf_consume_addr`. It never touches the write pointer, so it is safe while the next frame is arriving — the E1 fix. |
| `buf_consume_addr` | inp | `[AW-1:0]` | The consumer's current position (the SoC wires the BUFBYTE window pointer). Accepted only as a forward distance no greater than the allocated bytes; a duplicate is a no-op and a backward address is ignored, so `room` cannot be over-credited. |
| `crc_bit_en` | out | 1 | _no note yet_ |
| `crc_clr` | out | 1 | _no note yet_ |
| `crc_bit_in` | out | 1 | _no note yet_ |
| `crc_field_out` | out | 1 | _no note yet_ |
| `crc_state` | inp | `[31:0]` | _no note yet_ |
| `fbuf_we` | out | 1 | _no note yet_ |
| `fbuf_waddr` | out | `[AW-1:0]` | _no note yet_ |
| `fbuf_wdata` | out | `[7:0]` | _no note yet_ |
| `frame_valid` | out | 1 | _no note yet_ |
| `frame_bad` | out | 1 | _no note yet_ |
| `frame_len` | out | `[15:0]` | _no note yet_ |
| `frame_field` | out | `[15:0]` | _no note yet_ |
| `frame_is_type` | out | 1 | _no note yet_ |
| `frame_ptr` | out | `[AW-1:0]` | _no note yet_ |
| `dbg_state` | out | `[2:0]` | _no note yet_ |

## `pe_fbuf`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `we` | inp | 1 | _no note yet_ |
| `waddr` | inp | `[((BYTES <= 2) ? 1 : $clog2(BYTES))-1:0]` | _no note yet_ |
| `wdata` | inp | `[7:0]` | _no note yet_ |
| `raddr` | inp | `[((BYTES <= 2) ? 1 : $clog2(BYTES))-1:0]` | _no note yet_ |
| `rdata` | out | `[7:0]` | _no note yet_ |

## `pe_imem`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `imem_addr` | inp | `[((WORDS <= 2) ? 1 : $clog2(WORDS))-1:0]` | CPU fetch address. The data for this address appears on `imem_rdata` **one cycle later** — the macro's read latency, which pe_cpu's fetch-ahead is built around. |
| `imem_rdata` | out | `[15:0]` | Instruction word for the address driven **last** cycle. Wire-to-wire from the macro's `A_DOUT`; a register here would add a second cycle of latency and break the fetch-ahead. |
| `host_we` | inp | 1 | Loader write. Takes priority over the fetch port; by construction the two cannot collide, because the SoC holds the CPU at PC=0 while the loader owns the window. |
| `host_addr` | inp | `[((WORDS <= 2) ? 1 : $clog2(WORDS))-1:0]` | Loader address, one word per cycle. Wide enough to name any instruction word. |
| `host_wdata` | inp | `[15:0]` | Loader data. The wrapper writes all 16 bits; the macro's `A_BM` is tied high, because `BM=0` with `WEN=1` is a silent no-op rather than an error. |

## `pe_manch`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `bit_en` | inp | 1 | **The strobe** — one-cycle pulse meaning "this is the moment". The only thing that commits state in this block. Supplied by the timing block/DRU. See [[concepts/strobe-and-committing-edge]]. |
| `bypass` | inp | 1 | 1 ⇒ pass the raw bit through untouched. |
| `clr` | inp | 1 | Frame boundary — drop any pending error. |
| `half_phase` | inp | 1 | 0 = first half-cell, 1 = second half-cell. Driven by the SM/timing side. |
| `tx_raw` | inp | 1 | Raw bit in: 0 ⇒ H then L, 1 ⇒ L then H (IEEE 802.3). |
| `tx_wire` | out | 1 | Manchester-encoded level out: `half_phase` selects which half-cell of the symbol is currently driven. |
| `rx_wire` | inp | 1 | Line level in (the DRU supplies the two half-cell samples instead, see rx_first/rx_second). |
| `rx_first` | inp | 1 | First half-cell sample. |
| `rx_second` | inp | 1 | Second half-cell sample. |
| `rx_raw` | out | 1 | Decoded bit. |
| `rx_err` | out | 1 | Illegal symbol — equal halves mean there was no mid-bit edge. REGISTERED and strobe-gated: valid for one cycle after the committing edge, like pe_bitstuff's. It was combinational and ungated, which made it true of an idle line too. |

## `pe_nrzi`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `bit_en` | inp | 1 | **The strobe** — one-cycle pulse meaning "this is the moment". The only thing that commits state in this block. Supplied by the timing block/DRU. See [[concepts/strobe-and-committing-edge]]. |
| `bypass` | inp | 1 | 1 ⇒ pass the raw bit through untouched. |
| `clr` | inp | 1 | Frame/SOF boundary — return both the TX and RX line levels to idle J. A USB packet starts from idle J, and without this the only route there is a chip reset. |
| `tx_raw` | inp | 1 | Raw bit in. 0 toggles the line, 1 holds it. |
| `tx_wire` | out | 1 | Line level out. |
| `rx_wire` | inp | 1 | Line level in. |
| `rx_raw` | out | 1 | Decoded bit: `wire XNOR previous level` — a transition is a 0, no transition is a 1. |
| `tx_lvl` | out | 1 | The line level currently being driven. |

## `pe_pinmux`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low asynchronous reset. |
| `we` | inp | 1 | Register write strobe. One write port for all four registers — `addr` picks which. |
| `addr` | inp | `[1:0]` | Register select: 0 = OUT, 1 = OE, 2 = IN (**read-only**; a write here is a no-op, not an error), 3 = OD. |
| `wdata` | inp | `[PINS-1:0]` | Value to write to the selected register. One bit per pin; bits above `PINS` are ignored. |
| `rdata` | out | `[PINS-1:0]` | Value of the selected register. Reading IN returns the **pad level**, sampled combinationally — not a stored copy, which would report the previous bit cell and make arbitration read as a pass while the bus was being fought. |
| `pad_in` | inp | `[PINS-1:0]` | The level on each pin, driven or not. The external pull-up owns a released line, and wired-AND means any driver pulling low drags the whole wire down. |
| `pad_out` | out | `[PINS-1:0]` | Level to drive. Only reaches the pad where `pad_oe` is high. |
| `pad_oe` | out | `[PINS-1:0]` | 1 = this pin may drive. **In OD mode this is `oe & ~out`**, so a pin holding a 1 is RELEASED rather than driven high — that gate is the bus-contention safety property, and it is why the same firmware (`out=1` to send a 1, `out=0` to send a 0) works in both modes. See [[concepts/pin-matrix]].<br>**Open-drain** (I2C, PS/2): never drive high; release and let the board's pull-up do it.<br>**Tristate** (I2C arbitration): read back the pad level to see whether another master won the bit.<br>**Push-pull** (UART, SPI, CAN, USB): `oe=1` and toggle `out`. |

## `pe_soc`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low asynchronous reset. |
| `host_we` | inp | 1 | _no note yet_ |
| `host_imem_sel` | inp | 1 | _no note yet_ |
| `host_addr` | inp | `[((((IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS)) > 8)
                 ? ((IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS)) : 8)-1:0]` | _no note yet_ |
| `host_wdata` | inp | `[15:0]` | _no note yet_ |
| `run` | inp | 1 | _no note yet_ |
| `pin_in` | inp | `[7:0]` | _no note yet_ |
| `pin_out` | out | `[7:0]` | _no note yet_ |
| `pin_oe` | out | `[7:0]` | _no note yet_ |
| `dbg_pc` | out | `[7:0]` | _no note yet_ |
| `dbg_a` | out | `[7:0]` | _no note yet_ |
| `dbg_timer` | out | `[7:0]` | _no note yet_ |

## `tt_um_protocol_emulator`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `ui_in` | inp | `[7:0]` | _no note yet_ |
| `uo_out` | out | `[7:0]` | _no note yet_ |
| `uio_in` | inp | `[7:0]` | _no note yet_ |
| `uio_out` | out | `[7:0]` | _no note yet_ |
| `uio_oe` | out | `[7:0]` | _no note yet_ |
| `ena` | inp | 1 | _no note yet_ |
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low asynchronous reset. |

## Internal signals worth naming

Not ports, but the RTL comments and testbenches refer to them. Presence is
checked against the declarations; a removed signal will fail `--check`.

| Signal | Meaning |
|---|---|
| `tx_shreg` | Holds the word being sent. |
| `tx_nbits` | Snapshot of `tx_len` taken at load. |
| `tx_cnt` | Index of the bit currently on `tx_ser`. |
| `tx_rd_idx` | Bit-select index: `tx_cnt` when LSB-first, `tx_nbits-1-tx_cnt` when MSB-first. This is why `tx_ser` is combinational and correct **before** the strobe. |
| `cfg_lsb_tx` | Snapshot of `cfg_lsb_first` at load (transmit side). |
| `rx_shreg` | Bit-placer register — bit *k* is written straight to `rx_pos`, never shifted. |
| `rx_nbits` | Snapshot of `rx_len` taken at start. |
| `rx_cnt` | Bits captured so far. |
| `rx_pos` | Write position for the incoming bit: counts 0→len-1 LSB-first, len-1→0 MSB-first. |
| `cfg_lsb_rx` | Snapshot of `cfg_lsb_first` at start (receive side). |
| `rx_fin` | Final bit seen; the word completes on the next cycle (the delayed `rx_valid`). |
| `tx_level` | Line level the transmitter drives. |
| `rx_level` | Last wire level the receiver sampled — separate state, because a receiver cannot see the transmitter's. |
| `tx_run` | Current run length of identical bits. |
| `tx_lvl` | Value of the current run. |
| `tx_pend` | A stuff bit is owed on the next strobe. |

## Deliberately absent

- **No protocol vocabulary in the RTL.** These blocks do not know what UART,
  CAN or USB are; a protocol is a `cfg` value plus strobe cadence plus
  firmware. That is why the names are mechanical (`tx_raw`, `bit_en`) rather
  than named after protocols.
- **No `tx_clk`/`rx_clk`.** There is one clock; bit timing is carried by the
  strobe, not by a second clock (which is the whole point of the design).
- **No FIFO signals yet.** The word FIFO and pin-matrix ports are not built;
  see [[STATUS]] for what exists.

## Related

- [[concepts/strobe-and-committing-edge]] — the two terms used throughout.
- [[concepts/factored-hardware-blocks]] — why these blocks are factored this way.
