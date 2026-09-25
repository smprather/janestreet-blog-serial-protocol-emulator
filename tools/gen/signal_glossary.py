#!/usr/bin/env python3
"""Generate wiki/reference/signal-names.md from the RTL port declarations.

Signal names are the project's real interface; prose about them goes stale the
moment a port is renamed or a cfg bit moves. So the port tables are EXTRACTED
from the Verilog rather than typed by hand, and the hand-written part is limited
to the notes that the RTL cannot state about itself (what a name means, when it
is valid, which protocol uses it).

    python3 tools/gen/signal_glossary.py            # write the page
    python3 tools/gen/signal_glossary.py --check     # exit 1 if it is out of date

--check makes drift a test failure: run it from the regression script and a
renamed port cannot silently leave the glossary lying.

Ports are attributed by module declaration. Descriptions come from a NOTES table
below; a port with no note is still listed (with an explicit marker) so the table
can never silently omit a signal the RTL exposes.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
RTL = REPO / "rtl"
OUT = REPO / "wiki" / "reference" / "signal-names.md"

# ---------------------------------------------------------------------------
# Hand-written: what each port MEANS. Keys are (module, port). Anything not
# listed is emitted with a "no note yet" marker, which is the point: the table
# is complete even when the prose is not.
# ---------------------------------------------------------------------------

NOTES: dict[tuple[str, str], str] = {
    # ---- ports every module shares --------------------------------------
    ("*", "clk"): "System clock. Blocks count strobes, not cycles.",
    ("*", "rst_n"): "Active-low asynchronous reset.",
    ("*", "bit_en"): "**The strobe** — one-cycle pulse meaning \"this is the moment\". The only thing that commits state in this block. Supplied by the timing block/DRU. See [[concepts/strobe-and-committing-edge]].",
    # ---- pe_pinmux: per-pin direction, open-drain, read-back ------------
    ("pe_pinmux", "we"): "Register write strobe. One write port for all four registers — `addr` picks which.",
    ("pe_pinmux", "addr"): "Register select: 0 = OUT, 1 = OE, 2 = IN (**read-only**; a write here is a no-op, not an error), 3 = OD.",
    ("pe_pinmux", "wdata"): "Value to write to the selected register. One bit per pin; bits above `PINS` are ignored.",
    ("pe_pinmux", "rdata"): "Value of the selected register. Reading IN returns the **pad level**, sampled combinationally — not a stored copy, which would report the previous bit cell and make arbitration read as a pass while the bus was being fought.",
    ("pe_pinmux", "pad_in"): "The level on each pin, driven or not. The external pull-up owns a released line, and wired-AND means any driver pulling low drags the whole wire down.",
    ("pe_pinmux", "pad_out"): "Level to drive. Only reaches the pad where `pad_oe` is high.",
    ("pe_pinmux", "pad_oe"): "1 = this pin may drive. **In OD mode this is `oe & ~out`**, so a pin holding a 1 is RELEASED rather than driven high — that gate is the bus-contention safety property, and it is why the same firmware (`out=1` to send a 1, `out=0` to send a 0) works in both modes. See [[concepts/pin-matrix]].<br>**Open-drain** (I2C, PS/2): never drive high; release and let the board's pull-up do it.<br>**Tristate** (I2C arbitration): read back the pad level to see whether another master won the bit.<br>**Push-pull** (UART, SPI, CAN, USB): `oe=1` and toggle `out`.",
    # ---- pe_serdes: the shared bit engine -------------------------------
    ("pe_serdes", "clk"): "System clock. The DUT counts strobes, not cycles.",
    ("pe_serdes", "rst_n"): "Active-low async reset.",
    ("pe_serdes", "cfg_lsb_first"): "Bit order. 1 = LSB first (UART), 0 = MSB first (SPI). **Snapshotted** into `cfg_lsb_tx`/`cfg_lsb_rx` at load/start, so the core may rewrite it mid-transfer without corrupting an in-flight word.",
    ("pe_serdes", "tx_bit_en"): "**The TX-side strobe** — one-cycle pulse per PAYLOAD bit cell; the only thing that advances `tx_shreg`. Supplied by the integration's payload-only gate (`tx_cell_en && !tx_stuffed`), so the shifter HOLDS across an inserted stuff cell. Split from the old single `bit_en` because with stuffing the two directions need different sequences. See [[concepts/strobe-and-committing-edge]].",
    ("pe_serdes", "rx_bit_en"): "**The RX-side strobe** — one-cycle pulse per PAYLOAD bit cell; the only thing that captures `rx_ser`. Supplied by the integration's payload-only gate (`rx_cell_en && rx_bit_valid`), so a received stuff cell is SKIPPED. See [[concepts/strobe-and-committing-edge]].",
    ("pe_serdes", "tx_load"): "Starts a transmit. Captures `tx_data`, `tx_len`, and the bit order. Ignored when `tx_len == 0`.",
    ("pe_serdes", "tx_data"): "Word to send. Shifted out one bit per strobe.",
    ("pe_serdes", "tx_len"): "Bits to send, 1..MAXLEN. Captured at load; not clamped above MAXLEN (out of contract).",
    ("pe_serdes", "tx_ser"): "Serial output. Idles **high** (UART idle), driven only while `tx_busy`.",
    ("pe_serdes", "tx_busy"): "High from load until the final strobe.",
    ("pe_serdes", "tx_done"): "One-cycle pulse on the final strobe. TX-only event — see the sticky-flag note in the testbenches.",
    # FORMAL-ONLY observation taps (manager-approved 2026-09-25): guarded by
    # `ifdef FORMAL`, never present in synthesis or simulation (the
    # formal-ifdef gate proves 0 fv_* wires in a synthesis elaboration). They
    # exist so the formal targets can state internal-state claims over ports.
    ("pe_eth_tx", "fv_ifg_cnt"): "FORMAL ONLY — the gap counter, for the inductive IFG-floor proof.",
    ("pe_eth_tx", "fv_state"): "FORMAL ONLY — the FSM state, for the IFG floor's structural precondition.",
    ("pe_eth_tx", "fv_fcs_left"): "FORMAL ONLY — the FCS counter, for the frame-end precondition.",
    ("pe_eth_tx", "fv_abort_pend"): "FORMAL ONLY — the abort queue bit (one of the gap's documented abandonment exits).",
    ("pe_ctrl", "fv_resp_len"): "FORMAL ONLY — response length, for the R2 no-wrap claims.",
    ("pe_ctrl", "fv_resp_idx"): "FORMAL ONLY — frame word index, for the R2 no-wrap claims.",
    ("pe_ctrl", "fv_resp_active"): "FORMAL ONLY — serializer live, for the R2 frame-start claims.",
    ("pe_ctrl", "fv_r_addr"): "FORMAL ONLY — walk address, for the R2 bound claim.",
    ("pe_ctrl", "fv_r_left"): "FORMAL ONLY — walk items left, for the R2 bound claim.",
    ("pe_ctrl", "fv_r_slot"): "FORMAL ONLY — next response slot, for the R2 buffer-budget claim.",
    ("pe_ctrl", "fv_r_dmem"): "FORMAL ONLY — walk target (imem word / dmem byte), for the R2 bound claim.",
    ("pe_ctrl", "fv_rstate"): "FORMAL ONLY — read-engine state, for the R2 walk claims.",
    ("pe_ctrl", "fv_faults"): "FORMAL ONLY — the sticky fault register, for the R2 RANGE-stickiness claim.",
    ("pe_ctrl", "fv_clr_mask"): "FORMAL ONLY — the mask a CLEAR_FAULT applied, for the R2 stickiness claim.",
    ("pe_ctrl", "fv_resp_bitpos"): "FORMAL ONLY — bit position in the word, for the R2 word-alignment claim.",
    ("pe_ctrl", "fv_r_imm"): "FORMAL ONLY — immediate rejection (R_START with stale walk registers).",
    ("pe_soc", "fv_tx_path"): "FORMAL ONLY — the codec owner bit, for the target-4 exclusivity proof.",
    ("pe_soc", "fv_eth_tx_owner"): "FORMAL ONLY — the owner-mux output, for the target-4 exclusivity proof.",
    ("pe_soc", "fv_eth_tx_busy"): "FORMAL ONLY — the frame engine's busy wire, for the owner guard.",
    ("pe_soc", "fv_ser_tx_busy"): "FORMAL ONLY — the SERDES TX busy wire (the UNGUARDED direction is finding F2).",
    ("pe_serdes", "rx_ser"): "Serial input, **expected already synchronized** (latch-pair dual-edge capture flop, ADR-002). This block is single-edge.",
    ("pe_serdes", "rx_start"): "Starts a receive. Captures `rx_len` and the bit order. Ignored when `rx_len == 0`.",
    ("pe_serdes", "rx_len"): "Bits to receive, 1..MAXLEN.",
    ("pe_serdes", "rx_data"): "Assembled word. Payload always lands in `[rx_len-1:0]` regardless of bit order.",
    ("pe_serdes", "rx_busy"): "High from start until the final strobe — drops one cycle **before** `rx_valid`.",
    ("pe_serdes", "rx_valid"): "Word complete. Delayed one cycle past the final strobe by design (so `rx_data` can copy the register without a variable-shift path).",
    # ---- pe_codec_mux: the codec pipeline --------------------------------
    ("pe_codec_mux", "cfg"): "Stage select. `cfg[0]` stuff, `cfg[1]` NRZI, `cfg[2]` Manchester, `cfg[3]` `half_phase`, `cfg[6:4]` `run_cfg` (0 ⇒ default 5), `cfg[7]` `ones_only` (1 ⇒ stuff only runs of one, USB; 0 ⇒ either polarity, CAN). The USB configuration byte is **`0xE3`** (stuff + NRZI, run 6, ones-only); CAN is **`0x51`** (stuff + run 5 — `0x01` is equivalent, its run nibble 0 means the default 5). `0x05` would set `cfg[2]` and enable Manchester, so it is not a CAN preset. Using the old `0x63` selects symmetric stuffing and corrupts USB zero runs.",
    ("pe_codec_mux", "clr"): "Frame/SOF boundary — resets stuffing run tracking.",
    # ---- pe_crc: the CRC / LFSR engine ----------------------------------
    ("pe_crc", "bit_en"): "**The strobe** — one-cycle pulse meaning \"this is the moment\". One strobe per **wire bit**, in transmission order. See [[concepts/strobe-and-committing-edge]].",
    ("pe_crc", "clr"): "Frame boundary: `R <= cfg_seed` and the verdict drops. Wins over `bit_en`. This is a re-seed, NOT a reset — a frame boundary is not a power cycle. Note the ordering rule it creates: a consumer must latch the verdict before clearing for the next frame.",
    ("pe_crc", "crc_field"): "Level. While high, the block emits the CRC field: `crc_bit` is driven out and the register does a pure shift, so it drains to zero.",
    ("pe_crc", "bit_in"): "Wire bit in, transmission order. Ignored while `crc_field` — the block feeds its own output back on those strobes.",
    ("pe_crc", "cfg_poly_r"): "**The REVERSED polynomial**, low-justified (`rev(poly, Wcrc)`, not `rev(poly, 32)`). One expression serves both CRC families; see [[reference/crc-config]] for every value.",
    ("pe_crc", "cfg_seed"): "Seed in R orientation, low-justified: `init` for a reflected algorithm, `rev(init, Wcrc)` for a non-reflected one.",
    ("pe_crc", "cfg_out_inv"): "1 ⇒ complement the field bits on the wire (Ethernet FCS, USB CRCs). Expresses `xorout` because every target's is all-ones or all-zeros. Applies to `crc_bit` only, never to the feedback — see the RTL header for why that distinction is load-bearing.",
    ("pe_crc", "crc_bit"): "The field bit for this strobe: `R[0] ^ cfg_out_inv`. LSB-first of `R` is LSB-first of the CRC for a reflected algorithm and **MSB-first** of it for a non-reflected one, which is correct for both.",
    ("pe_crc", "crc_zero"): "**A status, not an event.** Asserts after the final field strobe and holds until `clr`. Means \"the frame at this boundary is clean\" — the register drains to zero for a transmitter and for a receiver that folds the field un-complemented.",
    ("pe_crc", "crc_state"): "The register, for observability and firmware readback. Reading the CRC a receiver computed means sampling it at the right strobe, which is a firmware-timing decision, not a feature of this port.",
    # ---- pe_eth_mac: buffer ownership (E1) -------------------------------
    ("pe_eth_mac", "buf_reset"): "**Whole-ring reclaim**: moves BOTH pointers to zero. Only legal when the ring is empty and nothing is in flight, so it is a testbench/debug control — the SoC does not pulse it in traffic (it caused E1).",
    ("pe_eth_mac", "buf_consume"): "**Consumer-owned reclaim**: a pulse advances the READ pointer to `buf_consume_addr`. It never touches the write pointer, so it is safe while the next frame is arriving — the E1 fix.",
    ("pe_eth_mac", "buf_consume_addr"): "The consumer's current position (the SoC wires the BUFBYTE window pointer). Accepted only as a forward distance no greater than the allocated bytes; a duplicate is a no-op and a backward address is ignored, so `room` cannot be over-credited.",
    # ---- pe_ctrl: the framed host-control bus (R1) -----------------------
    ("pe_ctrl", "spi_sclk"): "The host SCK pad. **Asynchronous**: synchronized with 2 flops; one bit per detected rising edge (SPI mode 0). The write ceiling at the 60 MHz core is ~10 MHz; the host's first-pass guard is 5 MHz because responses have their own mode-0 margin.",
    ("pe_ctrl", "spi_mosi"): "Host data in, MSB-first, sampled on the rising SCLK edge while CS_N is low.",
    ("pe_ctrl", "spi_cs_n"): "Active-low transaction select. A falling edge starts a new frame and resets the frame FSM; sticky faults, `words_written`, the echo and the selected target persist. A rising edge ends the transaction and latches FAULT_PROTOCOL if a word was mid-shift.",
    ("pe_ctrl", "run"): "The core's run strap. A LOAD while `run` is high answers NOT_READY with no fault; a queued word aborted by `run` rising never commits, counts or echoes.",
    ("pe_ctrl", "host_we"): "One-cycle write pulse, one per COMMITTED LOAD payload word, into the SoC's host write port.",
    ("pe_ctrl", "host_imem_sel"): "Held 1: R1 loads instruction memory only.",
    ("pe_ctrl", "host_addr"): "Word address, incremented per committed word (0..WORDS-1); a word past the end latches FAULT_RANGE and the response answers ST_RANGE.",
    ("pe_ctrl", "host_wdata"): "The queued LOAD payload word, committed on the next write pulse.",
    ("pe_ctrl", "load_active"): "Level: selected (`CS_N` low) and `run` low.",
    ("pe_ctrl", "load_error"): "Mirror of `faults[0]` (FAULT_LOAD): a queued word was aborted by `run` rising. Sticky until CLEAR_FAULT masks it.",
    ("pe_ctrl", "spi_miso"): "Framed response data, MSB-first, mode 0 (changes on the detected falling edge): sync `16'hA55A`, header `{version,opcode,target}`, sequence, length, payload, CRC-16/CCITT-FALSE. Driven only while a response shifts.",
    ("pe_ctrl", "miso_oe"): "Pad output-enable (wrapper `uio_oe[6]`): asserted only while a response frame shifts, held through the last bit's sampling edge, released one falling edge later or immediately when `CS_N` rises.",
    ("pe_ctrl", "irq_n"): "Active low; asserted while any sticky fault bit is set and released when CLEAR_FAULT masks them. A STATUS read does not clear faults.",
    ("pe_ctrl", "faults"): "Sticky fault register: FAULT_LOAD 0x1 (run abort), FAULT_CRC 0x2, FAULT_RANGE 0x4, FAULT_PROTOCOL 0x8. CLEAR_FAULT applies its mask; STATUS reports without clearing.",
    ("pe_ctrl", "words_written"): "Count of words committed since the current LOAD header was accepted (frame-scoped, not CS-scoped); reset at the header and incremented only on a commit.",
    # ---- pe_dru: the oversampled Manchester receiver --------------------
    ("pe_dru", "bit_en"): "**The strobe** — one per decoded **bit cell** (not per half-cell: pe_manch is given both halves at once). This is the DRU's whole output contract. See [[concepts/strobe-and-committing-edge]].",
    ("pe_dru", "rx_pin"): "The raw **asynchronous** pin. Synchronized internally (2 flops) before anything else touches it — this is the one place in the design where metastability would actually be sampled.",
    ("pe_dru", "cfg_filter_en"): "3-tap majority on the *synchronized* pin, for a noisy cable. The output is resampled before it drives the edge detector, so turning it on removes glitches without moving an edge; off by default because on a clean line it is pure latency.",
    ("pe_dru", "cfg_lock_bits"): "Well-formed cells required before `locked` asserts (0 ⇒ default 4). A cell is well-formed when its two halves differ, which is the Manchester code itself.",
    ("pe_dru", "rx_first"): "First half-cell level of the bit `bit_en` commits. Fed to `pe_manch.rx_first`.",
    ("pe_dru", "rx_second"): "Second half-cell level — **this is the bit value**. H→L is a 0, L→H is a 1, so the codec reads it directly. Fed to `pe_manch.rx_second`.",
    ("pe_dru", "rx_wire"): "The latest half-cell sample, for a consumer that wants the raw oversampled level rather than Manchester bits.",
    ("pe_dru", "locked"): "**Confidence, not a gate.** Asserted after `cfg_lock_bits` well-formed cells; cleared by the first malformed one. `bit_en` is emitted whether or not locked — gating on it would drop the preamble, which is the part every protocol here expects to be dropped. Nothing in this repo gates on it.",
    ("pe_dru", "dbg_phase"): "The phase counter (distance from the last transition, mod SPB). Bring-up only; the capture phase is SPB/4 and 3·SPB/4. **SPB's ceiling is 16, not merely a multiple of 4** — this counter is 4 bits and `4'(SPB-1)` truncates above it, which silently kills all capture (SPB=20 emits nothing). Both constraints are elaboration errors in the RTL and are boundary-tested by `regress/param_guards.sh`.",
    ("pe_codec_mux", "tx_bit"): "Raw bit in from the SM/SERDES.",
    ("pe_codec_mux", "tx_wire"): "Encoded bit out to the pin matrix.",
    ("pe_codec_mux", "tx_stuffed"): "This strobe emits a stuff bit; the raw input is ignored.",
    ("pe_codec_mux", "rx_wire"): "Wire bit in from the pin matrix / DRU.",
    ("pe_codec_mux", "rx_first"): "Manchester first half-cell sample (from the DRU).",
    ("pe_codec_mux", "rx_second"): "Manchester second half-cell sample (from the DRU).",
    ("pe_codec_mux", "rx_bit"): "Decoded raw bit out.",
    ("pe_codec_mux", "rx_bit_valid"): "0 ⇒ this wire bit was a stuff bit and carries no data.",
    ("pe_codec_mux", "rx_err"): "Line-code violation (e.g. a bit after a full run that is not complementary).",
    # ---- pe_nrzi ---------------------------------------------------------
    ("pe_nrzi", "bypass"): "1 ⇒ pass the raw bit through untouched.",
    ("pe_nrzi", "tx_raw"): "Raw bit in. 0 toggles the line, 1 holds it.",
    ("pe_nrzi", "tx_wire"): "Line level out.",
    ("pe_nrzi", "rx_wire"): "Line level in.",
    ("pe_nrzi", "rx_raw"): "Decoded bit: `wire XNOR previous level` — a transition is a 0, no transition is a 1.",
    ("pe_nrzi", "tx_lvl"): "The line level currently being driven.",
    ("pe_nrzi", "clr"): "Frame/SOF boundary — return both the TX and RX line "
                        "levels to idle J. A USB packet starts from idle J, and "
                        "without this the only route there is a chip reset.",
    # ---- pe_manch --------------------------------------------------------
    ("pe_manch", "half_phase"): "0 = first half-cell, 1 = second half-cell. Driven by the SM/timing side.",
    ("pe_soc", "tx_cell_en"): "The timing divider's one-pulse-per-ENCODED-cell strobe into the TX codec (payload cells plus inserted stuff slots — never per half-cell).",
    ("pe_soc", "rx_cell_en"): "The RX codec's cell strobe: the DRU's per-decoded-cell strobe in Manchester mode, the divider's cell strobe over the DRU's synchronized level for plain/NRZI/stuffed (self-timed loopback scope — no plain-mode phase acquisition).",
    ("pe_soc", "half_phase"): "Manchester half-cell LEVEL from the divider — two toggles per encoded cell, not a strobe. Goes to the TX codec instance's cfg[3]; the RX instance carries 0 there.",
    ("pe_manch", "bypass"): "1 ⇒ pass the raw bit through untouched.",
    ("pe_manch", "tx_wire"): "Manchester-encoded level out: `half_phase` selects which half-cell of the symbol is currently driven.",
    ("pe_manch", "rx_wire"): "Line level in (the DRU supplies the two half-cell samples instead, see rx_first/rx_second).",
    ("pe_manch", "tx_raw"): "Raw bit in: 0 ⇒ H then L, 1 ⇒ L then H (IEEE 802.3).",
    ("pe_manch", "rx_first"): "First half-cell sample.",
    ("pe_manch", "rx_second"): "Second half-cell sample.",
    ("pe_manch", "rx_raw"): "Decoded bit.",
    ("pe_manch", "rx_err"): "Illegal symbol — equal halves mean there was no "
                            "mid-bit edge. REGISTERED and strobe-gated: valid "
                            "for one cycle after the committing edge, like "
                            "pe_bitstuff's. It was combinational and ungated, "
                            "which made it true of an idle line too.",
    ("pe_manch", "clr"): "Frame boundary — drop any pending error.",
    # ---- pe_bitstuff -----------------------------------------------------
    ("pe_bitstuff", "clr"): "Frame/SOF boundary — reset run tracking.",
    ("pe_cpu", "dbg_pc"): "Program counter, for observability. A real PORT, not a "
                          "hierarchical reference from the parent: a cross-module "
                          "reference simulates but does not synthesise.",
    ("pe_cpu", "dbg_a"): "Accumulator, for observability. See dbg_pc.",
    # ---- pe_imem: the instruction memory wrapper ------------------------
    ("pe_imem", "imem_addr"): "CPU fetch address. The data for this address appears on `imem_rdata` **one cycle later** — the macro's read latency, which pe_cpu's fetch-ahead is built around.",
    ("pe_imem", "imem_rdata"): "Instruction word for the address driven **last** cycle. Wire-to-wire from the macro's `A_DOUT`; a register here would add a second cycle of latency and break the fetch-ahead.",
    ("pe_imem", "host_we"): "Loader write. Takes priority over the fetch port; by construction the two cannot collide, because the SoC holds the CPU at PC=0 while the loader owns the window.",
    ("pe_imem", "host_addr"): "Loader address, one word per cycle. Wide enough to name any instruction word.",
    ("pe_imem", "host_wdata"): "Loader data. The wrapper writes all 16 bits; the macro's `A_BM` is tied high, because `BM=0` with `WEN=1` is a silent no-op rather than an error.",
    ("pe_bitstuff", "bypass"): "1 ⇒ pass the raw bit through untouched (no stuffing).",
    ("pe_bitstuff", "run_cfg"): "Stuff after this many identical bits (5 = CAN, 6 = USB-LS).",
    ("pe_bitstuff", "ones_only"): "1 ⇒ only a run of ONES is stuffed (USB 1.1 §7.1.9); 0 ⇒ a run of either polarity (CAN). Counters saturate on a run that cannot be stuffed, because a USB zero run is unbounded.",
    ("pe_bitstuff", "tx_raw"): "Raw bit in.",
    ("pe_bitstuff", "tx_wire"): "Bit out, with stuff bits inserted.",
    ("pe_bitstuff", "tx_stuffed"): "A stuff bit is owed on the **next** strobe (`tx_pend`); the raw input is ignored on that strobe.",
    ("pe_bitstuff", "rx_wire"): "Wire bit in.",
    ("pe_bitstuff", "rx_raw"): "Bit out, with stuff bits removed.",
    ("pe_bitstuff", "rx_raw_valid"): "0 ⇒ this wire bit was a stuff bit.",
    ("pe_bitstuff", "rx_err"): "The bit after a full run was not complementary.",
}

# Internal (non-port) signals worth naming, because the RTL and the testbenches
# refer to them. Extracted-and-checked the same way where they are declared.
INTERNALS: dict[tuple[str, str], str] = {
    ("pe_serdes", "tx_shreg"): "Holds the word being sent.",
    ("pe_serdes", "tx_nbits"): "Snapshot of `tx_len` taken at load.",
    ("pe_serdes", "tx_cnt"): "Index of the bit currently on `tx_ser`.",
    ("pe_serdes", "tx_rd_idx"): "Bit-select index: `tx_cnt` when LSB-first, `tx_nbits-1-tx_cnt` when MSB-first. This is why `tx_ser` is combinational and correct **before** the strobe.",
    ("pe_serdes", "cfg_lsb_tx"): "Snapshot of `cfg_lsb_first` at load (transmit side).",
    ("pe_serdes", "rx_shreg"): "Bit-placer register — bit *k* is written straight to `rx_pos`, never shifted.",
    ("pe_serdes", "rx_nbits"): "Snapshot of `rx_len` taken at start.",
    ("pe_serdes", "rx_cnt"): "Bits captured so far.",
    ("pe_serdes", "rx_pos"): "Write position for the incoming bit: counts 0→len-1 LSB-first, len-1→0 MSB-first.",
    ("pe_serdes", "cfg_lsb_rx"): "Snapshot of `cfg_lsb_first` at start (receive side).",
    ("pe_serdes", "rx_fin"): "Final bit seen; the word completes on the next cycle (the delayed `rx_valid`).",
    ("pe_nrzi", "tx_level"): "Line level the transmitter drives.",
    ("pe_nrzi", "rx_level"): "Last wire level the receiver sampled — separate state, because a receiver cannot see the transmitter's.",
    ("pe_bitstuff", "tx_run"): "Current run length of identical bits.",
    ("pe_bitstuff", "tx_lvl"): "Value of the current run.",
    ("pe_bitstuff", "tx_pend"): "A stuff bit is owed on the next strobe.",
}

CONVENTION_ROWS = [
    ("`tx_*` / `rx_*`", "Direction. `tx_` faces the wire (outbound), `rx_` faces the wire (inbound) — both are named from the **pin's** point of view, not the core's."),
    ("`*_en`", "A strobe/enable pulse, high for one cycle (e.g. `bit_en`). Not a level."),
    ("`*_valid`", "Qualifier meaning \"this output carries real data this cycle\". `rx_bit_valid=0` means the bit was a stuff bit."),
    ("`*_raw`", "In the codecs: the plain NRZ bit, **before** line coding. `tx_raw` in, `tx_wire` out."),
    ("`*_wire`", "The encoded bit/level as it appears on the wire."),
    ("`*_lvl`", "A held line level, not a bit."),
    ("`*_err`", "Line-code violation detected on receive."),
    ("`cfg_*`", "Configuration. **Snapshot** variants (`cfg_lsb_tx`) are captured copies that protect an in-flight transfer."),
    ("`*_cnt`", "A counter of bits moved."),
    ("`*_nbits`", "A captured copy of the requested length (`tx_nbits`, `rx_nbits`)."),
    ("`*_shreg`", "A bit register. In `pe_serdes` the RX side is a **bit-placer**, not a shifter — see `rx_pos`."),
    ("`clr`", "Frame boundary; resets run/symbol tracking. Not a reset."),
    ("`bypass`", "Stage disable. Every codec stage is runtime-bypassable."),
]


def port_blocks(text: str, module: str) -> list[tuple[str, str, str]]:
    """`(direction, width, name)` for one module's port list."""
    m = re.search(rf"^\s*module\s+{module}\b(.*?)\);", text, re.DOTALL | re.MULTILINE)
    if not m:
        return []
    body = m.group(1)
    # Drop full-line comments so commented ports are not mistaken for real ones.
    body = re.sub(r"//[^\n]*", "", body)
    out: list[tuple[str, str, str]] = []
    for dm in re.finditer(
        r"\b(input|output|inout)\b\s*(?:logic|wire|reg|bit)?\s*(\[[^\]]*\])?\s*"
        r"([A-Za-z_][A-Za-z_0-9]*)",
        body,
    ):
        direction, width, name = dm.group(1), (dm.group(2) or "").strip(), dm.group(3)
        out.append((direction, width or "1", name))
    return out


def declared_internals(text: str) -> set[str]:
    return set(re.findall(r"^\s*logic\s*(?:\[[^\]]*\])?\s*([A-Za-z_][A-Za-z_0-9]*)", text, re.MULTILINE))


def build() -> str:
    files = sorted(RTL.glob("*.v"))
    if not files:
        sys.exit(f"gen_signal_glossary: no RTL found in {RTL}")

    # pe_serdes first: it is the block firmware talks to, and the one a reader
    # arriving at this page is most likely looking for. The rest follow.
    def rank(path: Path) -> tuple[int, str]:
        return (0 if path.name == "pe_serdes.v" else 1, path.name)

    modules: list[tuple[str, list[tuple[str, str, str]]]] = []
    for f in sorted(files, key=rank):
        text = f.read_text(encoding="utf-8")
        for mod in re.findall(r"^\s*module\s+([A-Za-z_][A-Za-z_0-9]*)", text, re.MULTILINE):
            ports = port_blocks(text, mod)
            if ports:
                modules.append((mod, ports))

    total = sum(len(p) for _, p in modules)
    missing: list[str] = []

    lines: list[str] = [
        "---",
        "title: Signal Names",
        "created: 2026-09-18",
        "updated: 2026-09-23",
        "type: reference",
        "tags: [architecture, verification]",
        "sources: [rtl/pe_serdes.v, rtl/pe_codec_mux.v, rtl/pe_nrzi.v, rtl/pe_manch.v, rtl/pe_bitstuff.v]",
        "confidence: high",
        "---",
        "",
        "# Signal Names",
        "",
        "Every port the RTL exposes, what it means, and when it is valid. **Port",
        "tables are extracted from the Verilog by `tools/gen/signal_glossary.py`**",
        "(`--check` fails if this page is stale), so a renamed port cannot leave this",
        "page lying. The prose is the hand-written part; the interface is not.",
        "",
        f"{len(modules)} modules, {total} ports.",
        "",
        "Two terms this page assumes and [[concepts/strobe-and-committing-edge]]",
        "defines: the **strobe** (`bit_en`) and the **committing edge**.",
        "",
        "## Naming conventions",
        "",
        "| Pattern | Meaning |",
        "|---|---|",
    ]
    lines += [f"| {p} | {d} |" for p, d in CONVENTION_ROWS]

    for mod, ports in modules:
        lines += ["", f"## `{mod}`", ""]
        lines += ["| Port | Dir | Width | Meaning |", "|---|---|---|---|"]
        for direction, width, name in ports:
            note = NOTES.get((mod, name)) or NOTES.get(("*", name))
            if note is None:
                note = "_no note yet_"
                missing.append(f"{mod}.{name}")
            w = f"`{width}`" if width != "1" else "1"
            lines.append(f"| `{name}` | {direction[:3]} | {w} | {note} |")

    lines += [
        "",
        "## Internal signals worth naming",
        "",
        "Not ports, but the RTL comments and testbenches refer to them. Presence is",
        "checked against the declarations; a removed signal will fail `--check`.",
        "",
        "| Signal | Meaning |",
        "|---|---|",
    ]
    for (mod, name), note in INTERNALS.items():
        lines.append(f"| `{name}` | {note} |")

    lines += [
        "",
        "## Deliberately absent",
        "",
        "- **No protocol vocabulary in the RTL.** These blocks do not know what UART,",
        "  CAN or USB are; a protocol is a `cfg` value plus strobe cadence plus",
        "  firmware. That is why the names are mechanical (`tx_raw`, `bit_en`) rather",
        "  than named after protocols.",
        "- **No `tx_clk`/`rx_clk`.** There is one clock; bit timing is carried by the",
        "  strobe, not by a second clock (which is the whole point of the design).",
        "- **No FIFO signals yet.** The word FIFO and pin-matrix ports are not built;",
        "  see [[STATUS]] for what exists.",
        "",
        "## Related",
        "",
        "- [[concepts/strobe-and-committing-edge]] — the two terms used throughout.",
        "- [[concepts/factored-hardware-blocks]] — why these blocks are factored this way.",
        "",
    ]

    if missing:
        print(f"note: {len(missing)} port(s) have no note: {', '.join(missing[:6])}"
              f"{' …' if len(missing) > 6 else ''}", file=sys.stderr)
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the page on disk differs from a fresh render")
    args = ap.parse_args()

    rendered = build()
    if args.check:
        if not OUT.exists():
            print(f"gen_signal_glossary: {OUT} is missing", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != rendered:
            print(f"gen_signal_glossary: {OUT} is STALE — re-run without --check",
                  file=sys.stderr)
            return 1
        print("signal glossary up to date")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT} ({len(rendered)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
