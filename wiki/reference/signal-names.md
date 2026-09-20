---
title: Signal Names
created: 2026-09-18
updated: 2026-09-18
type: reference
tags: [architecture, verification]
sources: [rtl/pe_serdes.v, rtl/pe_codec_mux.v, rtl/pe_line_codec.v]
confidence: high
---

# Signal Names

Every port the RTL exposes, what it means, and when it is valid. **Port
tables are extracted from the Verilog by `tools/gen_signal_glossary.py`**
(`--check` fails if this page is stale), so a renamed port cannot leave this
page lying. The prose is the hand-written part; the interface is not.

8 modules, 98 ports.

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

## `pe_codec_mux`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `cfg` | inp | `[7:0]` | Stage select. `cfg[0]` stuff, `cfg[1]` NRZI, `cfg[2]` Manchester, `cfg[3]` `half_phase`, `cfg[7:4]` `run_cfg` (0 ⇒ default 5). |
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

## `pe_bitstuff`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `bit_en` | inp | 1 | **The strobe** — one-cycle pulse meaning "this is the moment". The only thing that commits state in this block. Supplied by the timing block/DRU. See [[concepts/strobe-and-committing-edge]]. |
| `bypass` | inp | 1 | 1 ⇒ pass the raw bit through untouched (no stuffing). |
| `clr` | inp | 1 | Frame/SOF boundary — reset run tracking. |
| `run_cfg` | inp | `[3:0]` | Stuff after this many identical bits (5 = CAN, 6 = USB-LS). |
| `tx_raw` | inp | 1 | Raw bit in. |
| `tx_wire` | out | 1 | Bit out, with stuff bits inserted. |
| `tx_stuffed` | out | 1 | A stuff bit is owed on the **next** strobe (`tx_pend`); the raw input is ignored on that strobe. |
| `rx_wire` | inp | 1 | Wire bit in. |
| `rx_raw` | out | 1 | Bit out, with stuff bits removed. |
| `rx_raw_valid` | out | 1 | 0 ⇒ this wire bit was a stuff bit. |
| `rx_err` | out | 1 | The bit after a full run was not complementary. |

## `pe_uart_soc`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | inp | 1 | System clock. Blocks count strobes, not cycles. |
| `rst_n` | inp | 1 | Active-low asynchronous reset. |
| `host_we` | inp | 1 | _no note yet_ |
| `host_imem_sel` | inp | 1 | _no note yet_ |
| `host_addr` | inp | `[7:0]` | _no note yet_ |
| `host_wdata` | inp | `[15:0]` | _no note yet_ |
| `run` | inp | 1 | _no note yet_ |
| `pin_in` | inp | 1 | _no note yet_ |
| `pin_out` | out | 1 | _no note yet_ |
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
- [[concepts/live-canvas]] — where the generated timing diagrams come from.
