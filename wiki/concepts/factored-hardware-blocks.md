---
title: Factored Hardware Blocks
created: 2026-09-17
updated: 2026-09-17
type: concept
tags: [architecture, area-budget, protocol]
sources: [raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: medium
---

# Factored Hardware Blocks

Keep the programmable core small by factoring shared, parameterized primitives between the execution engine and the pin matrix (TX/RX FIFOs + interrupts decouple them). Firmware then works at byte/packet level; bit-level timing lives in hardware. Area figures below are transcript estimates (~130 nm cells) to confirm after first synthesis per [[concepts/competition-overview]].

## Blocks to factor out

- 8x/16x oversampling CDR engine ([[concepts/cdr-oversampling]]): edge-triggered phase counter, majority-vote filtering, clean data-strobe/bit-clock out. Serves 10BASE-T, USB NRZI phase, UART start-bit tracking, PS/2. (~60 cells.)
- Parametric SerDes shift registers (8-32 b, MSB/LSB-first, configurable shift edge): serves every listed protocol; avoids per-bit pin toggling in microcode. IMPLEMENTED as rtl/pe_serdes.v (runtime order/length, bit-placer RX): 623 cells / ~11.5k um2 typ corner, 129 flops, iverilog PASS + verilator clean.
- Framing/transcoding: NRZI/Manchester transcoder, bit-stuffer/unstuffer (USB: 6 ones; CAN: 5 equal bits), OE/tri-state direction control for I2C ACKs, SWD turnaround, USB SE0. (~15-40 cells each.) IMPLEMENTED as rtl/pe_line_codec.v + rtl/pe_codec_mux.v: nrzi 12 cells, manch 5, bitstuff 84 (runtime run_cfg 1-15), mux glue 9 — 110 cells / 1.6k um2 total. Config byte muxes any SUBSET of stages in/out; pipeline order fixed (stuff -> line code) as that is the physically correct composition.
- Configurable CRC LFSR (polynomial/seed/bit-reversal masks): CRC-5/16 (USB), CRC-15 (CAN), CRC-32/FCS (Ethernet). ~120 cells for CRC-32 vs ~30 instructions/bit in firmware.

## 8b/10b explicitly not needed

None of the targets use it: 10BASE-T is Manchester (8b/10b arrived with 100BASE-TX/1000BASE-T); USB LS is NRZI + stuffing; CAN is NRZ + stuffing; UART/SPI/I2C/JTAG/SWD/PS/2 are raw NRZ with clocks or start/stop framing. Revisit only if chasing gigabit-class protocols.
