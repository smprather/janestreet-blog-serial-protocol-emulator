---
title: Strobe and Committing Edge
created: 2026-09-18
updated: 2026-09-18
type: concept
tags: [architecture, verification, tooling]
sources: []
confidence: high
---

# Strobe and Committing Edge

The two words the RTL and TBs use constantly, defined once. Both are about *when*
something happens, not *what* happens — which is why they matter in a design whose
whole job is bit-level timing.

## The strobe

In this project a **strobe** is a one-clock-cycle enable pulse that says *"this is
the moment"*. The name in `pe_serdes.v` is `bit_en`.

It is not a clock and not a level. It is high across exactly one rising `clk`
edge, and it is the *only* thing that makes `pe_serdes` change state. From the
RTL header (`rtl/pe_serdes.v:12`):

> `bit_en` is the per-bit-cell strobe from the core/DRU timing logic.

Three consequences worth holding onto:

- **The DUT owns bit *order*, not bit *timing*.** `pe_serdes` never counts clock
  cycles. It counts strobes. Put strobes 16 clocks apart (UART in
  `tb_pe_uart.v`, `BP = 16`) or 2 apart (SPI) and the block behaves identically —
  it just advances per strobe. Spacing is the timing block's problem.
- **The strobe's source is outside the block.** In the testbenches the TB drives
  it; in the real chip the core/DRU timing logic does.
- **One strobe can mean more than one bit.** `pe_bitstuff` consumes a *following*
  strobe for the inserted stuff bit (`rtl/pe_bitstuff.v`), which is why
  `tx_stuffed` exists to tell the timing side "raw input is ignored on this one."

## The committing edge

The **committing edge** is the specific `clk` rising edge at which the strobe is
high — the instant a flop actually takes its new value. "Committed at the strobe"
means the change is visible *after* that edge, not before.

The distinction is the sampling-order trap the TBs document
(`tb/tb_pe_codec_mux.v:10-13`):

| Stage type | Wire output for bit *k* is valid… |
|---|---|
| Combinational (stuff, Manchester, `tx_ser`) | **before** the strobe — it is a function of current state |
| Registered (NRZI line level, RX capture) | **at/after** the strobe — the flop commits on that edge |

Getting this backwards produces a TB that samples a signal one cycle early or late
and then "proves" a bug that is not there. It is listed in
[[STATUS]] as gotcha 7, learned the hard way.

## Reading it off a waveform

In `sim/tb_pe_uart.vcd`, for the first data bit of `0x55`:

```
clk      ‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾  ... 16 cycles per bit cell
bit_en   ______________________|‾|________ ... one cycle, at the cell boundary
                                 ^
                          the committing edge
tx_ser   ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾ 0 ‾‾‾‾‾‾‾‾‾‾ ... already correct pre-strobe
```

Measured from the dump: `tx_load` rises at 206 ns, the first strobe at 217 ns, and
strobes repeat every 160 ns (16 × 10 ns) after that.

## Why the RX side is "delayed one cycle"

`rx_valid` does not rise on the committing edge of the final strobe — `rx_busy`
drops there and `rx_valid`/`rx_data` follow one cycle later
(`rtl/pe_serdes.v:21`). That delay is deliberate: by then `rx_shreg` already holds
the whole word, so the copy needs no variable-shift forward path. It costs ~1
cycle and saves the ~40 cells of that mux. A TB that expects `rx_valid` on the
same edge as the last strobe will fail against a correct design.

## Related

- [[reference/signal-names]] — every RTL port and what it means (the reference page).
- [[concepts/cdr-oversampling]] — where the RX strobe comes from in the real chip
  (the DRU's mid-bit pick), versus the TB driving it at cell boundaries here.
- [[concepts/tx-timing-generation]] — how the strobe spacing is generated at 60 MHz.
- [[concepts/factored-hardware-blocks]] — the block the strobe drives.
