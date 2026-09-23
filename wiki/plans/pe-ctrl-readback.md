---
title: pe_ctrl readback path (host response)
created: 2026-09-23
updated: 2026-09-23
type: plan
tags: [boot, loader, pads, observability, verification]
sources: [wiki/decisions/adr-007-pe-ctrl-passive-slave.md, rtl/pe_ctrl.v, rtl/tt_um_protocol_emulator.v, wiki/reference/protocol-pin-budget.md, wiki/STATUS.md]
confidence: high
---

# pe_ctrl readback: evaluating a MISO response

## Why

ADR-007 shipped the loader **write-only**: the host cannot confirm words
landed, and the only live observability is the debug PC on `uo_out[7:2]`
(STATUS item 4). ADR-007 calls a read path "a later additive change"; item 4's
revisit trigger names it. The interface choice is **still open**, so this plan
fixes the feasible pad/host mapping and the minimal contract, with options and
tradeoffs, before any RTL changes.

## What v1 has

- `rtl/pe_ctrl.v`: mode-0 SPI slave, `ui_in[3]`=SCLK, `ui_in[4]`=MOSI,
  `ui_in[5]`=CS_N; MSB-first 16-bit words; CS low resets the address; every 16
  rising edges writes `imem[addr]`; `run` gates writes; sticky `load_error`;
  `words_written`; `load_active` (selected and stopped).
- Free pads: `ui_in[6:7]` (inputs only), `uio[7:4]` (bidir, released),
  `uo_out` fully committed (UART TX / heartbeat / debug PC). The SoC port bits
  6-7 and their matrix OE are unused.

## Feasible mapping

MISO is a chip **output**, so it must land on a `uio` pad: `uo_out` has none
free, `ui_in` cannot drive, and the matrix's SPI pads (bits 0-2) are
chip-owned as outputs at reset (ADR-007).

**Recommended: `uio[4]`**, adjacent to the SPI pair on `uio[2:3]`:

| | |
|---|---|
| value | `uio_out[4] = pe_ctrl.spi_miso` |
| enable | `uio_oe[4] = pe_ctrl.load_active` -- driven only while selected and stopped, released otherwise (no reset change: released) |
| loader pads | unchanged: `ui_in[3:5]`; matrix/port contract untouched |

Budget when implemented: committed **18 -> 19** of 24, free `uio` **4 -> 3**;
the all-nine shortfall goes **9 -> 10** (debug kept) / **3 -> 4** (reclaimed)
because the readback is loader overhead, not one of the nine protocols. The
generator recomputes on implementation; nothing is regenerated for this plan.

## Minimal protocol contract (recommended option A: echo)

- Mode 0, MSB-first, 16 bits per frame -- the same framing as the load. The
  load contract is **untouched**: every 16 rising edges still writes a word.
- `spi_miso` changes on the **falling** SCLK edge while selected; released when
  CS_N is high (or `run` is high).
- Frame 0 presents `16'h0000`. During frame k >= 1, MISO presents the word
  completed at frame k-1 (an `echo_reg` latched from `word_data` at the prior
  frame's 16th falling edge). The host verifies each word **one frame late** --
  a standard full-duplex slave; a write-only host that ignores MISO is
  bit-identical to today.
- The final word's echo costs one trailing frame, which writes `16'h0000` to
  `imem[N]` and increments the address. The tail past the image is already
  undefined (ADR-007), and the host may skip it if the program's own output is
  the proof. This is the contract's one wart and it is documented, not hidden.

## Options and tradeoffs

| Option | Logic/pads | Verifies | Cost |
|---|---|---|---|
| **A. Echo** (recommended) | 1 `uio`, ~17 flops | every written word bit-exact, through the shift and write path | one trailing frame for the last word; no status channel |
| **B. Status frame** | 1 `uio`, ~20 flops | framing, `load_error`, `words_written` live | not the data; `load_error` is cleared at CS fall, so a previous-load status needs a retained copy |
| **C. Peek/poke** | 1 pad + `pe_imem`/`pe_soc` read mux | actual memory contents (imem, later dmem) | the imem macro's one read port is shared with the CPU; a mux/arbiter crosses module boundaries; a command bit breaks "16 rises = a write" |
| **D. Reuse pads** | 0 | -- | impossible: no free `uo_out`; `ui_in` cannot drive; matrix pads are chip-owned at reset |

Recommendation: **A first** -- smallest, additive, backward compatible. B is
additive later if a board wants a status channel; mixing status into the echo
frame is possible but not minimal.

## Test and mutation plan (if A is picked)

1. `tb_pe_ctrl.v`: the host model samples MISO on rising edges and checks
   frame 0 is zero, each echo is the previous word, bits change on falls, and
   MISO releases on CS high / `run` high. Every existing write-only case runs
   unchanged (non-vacuity: the old behaviour is not perturbed).
2. `tb_tt_um_protocol_emulator.v`: pad-level phase -- clock an image through
   `ui_in[3:5]`, read the echo on `uio[4]`/`uio_oe[4]`, then raise `run` and
   check the program executes. The unclaimed-pin monitors narrow from
   `uio[7:4]` to `uio[7:5]` while selected.
3. Probes, each independently detected: echo sourced from `shreg` instead of
   the completed word; change on the rise instead of the fall; `uio_oe[4]`
   stuck driven / stuck released; reversed bit order; frame 0 not zero;
   echo updated before the write commits. Extend `regress/mutate_ctrl_tb.sh`
   (or add a focused suite) and restore the source byte-identically.
4. Screens: `regress/synth_area.sh` (expect ~+17 flops and no wrapper logic);
   the pe_ctrl STA screen if its constraints cover the new output, otherwise
   record the register -> pad path class as with the SPI alias. No physical
   flow, DRC or LVS.

## Open decisions for the reviewer

1. **A (echo) vs B (status) vs both** -- A is recommended.
2. **Last-word policy**: allow the trailing dummy frame, or stop at N-1
   verifications?
3. **Release condition**: `load_active` (recommended; `run` high also releases)
   vs `~cs_s1` (drives while CS is low even with `run` high).
