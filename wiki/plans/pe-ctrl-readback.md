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
- Frame 0 presents `16'h0000`. The echo is **commit-latched**: the echo register
  captures the completed word only at the `W_DONE` edge where the imem write
  actually commits (`words_written` increments) -- never at `word_ready` and
  never on the `run`-abort path. **An aborted word must never echo.**
- Echo latency, and the SCLK ceiling it buys (see the timing audit):
  - **A1, one frame** (recommended default): frame k presents the word
    committed at frame k-1; readback SCLK **<= 2.5 MHz**.
  - **A2, two frames**: frame k presents the word committed at frame k-2;
    readback SCLK **<= 10 MHz** (the full loader rate), at the cost of one more
    trailing frame.
- A write-only host that ignores MISO is bit-identical to today.
- Reading the last word(s) costs one (A1) or two (A2) trailing frames, which
  write `16'h0000` to `imem[N]`/`imem[N+1]`; the tail past the image is already
  undefined (ADR-007). After a full 1024-word load `load_error` latches and the
  receive path stops, so trailing frames assemble and write nothing; the host
  may skip them when the program's own output is the proof.

## Timing audit (2026-09-23): mode 0 at 10 MHz cannot meet setup

Derived cycle-by-cycle from `rtl/pe_ctrl.v` (worst-case SCLK phase relative to
the 60 MHz `clk`, 16.67 ns per cycle; the pad edge lands just after a clk edge):

| Event | Worst-case delay from the SCLK pad edge |
|---|---|
| `sclk_s0` captures | +1 clk (16.7 ns) |
| `sclk_s1` captures; the edge detector is valid for one clk cycle | +2 clk (33.3 ns) |
| the receive block samples the detector: `word_data`/`word_ready` | +3 clk (50 ns) |
| `W_IDLE -> W_PULSE` | +4 clk (66.7 ns) |
| `W_PULSE -> we_r` (`host_we` high) | +5 clk (83.3 ns) |
| **imem write commits; `W_DONE` executes** | **+6 clk (100 ns)** |
| a registered MISO update on the detected fall | +3 clk (50 ns) |
| pad output delay + host setup | +~5-15 ns |

A 10 MHz half period is 50 ns = 3 clk. A falling-edge MISO update is therefore
visible at, or after, the next rising sample -- **strict mode-0 readback at
10 MHz has zero or negative setup margin**. Even a combinational fall-gated
update (2 clk, 33 ns) leaves only ~17 ns for the pad and host setup at the
worst phase, which is not defensible across corners.

The write commit sets the real bound: the echo of word k cannot be presented
before the write commits, up to +6 clk (100 ns) after the completing rise.

- **A1 (one frame)**: the first echo bit must be set by the frame's 16th
  falling edge, one half period after the rise, so `half_period >= 6 clk +
  margin` -- a computed bound of ~4 MHz, **2.5 MHz recommended** (half period
  200 ns, 100 ns of margin).
- **A2 (two frames)**: the first bit is set at the 16th fall of the following
  frame, `1.5 periods` after the rise, so **10 MHz works** (150 ns vs the
  100 ns worst-case commit, 50 ns of margin).

Implementation consequence: the echo register loads in the `W_DONE` branch
**only on the commit path** (`run == 0`), never when the queued word is aborted;
`load_error` and aborted words must not leak into the echo. Load-only
transactions keep the existing 10 MHz ceiling; only readback slows down (A1) or
adds a frame (A2). A rise-edge MISO update does not help -- the first bit still
cannot be presented before the commit -- and it breaks the strict mode-0 change
timing.

## Options and tradeoffs

| Option | Logic/pads | Verifies | Cost |
|---|---|---|---|
| **A1. One-frame echo** (recommended default) | 1 `uio`, ~17 flops | every committed word bit-exact, through the shift and write path | readback SCLK <= 2.5 MHz; one trailing frame; no status channel |
| **A2. Two-frame echo** | same + frame tracking | same (commit-latched) | readback SCLK <= 10 MHz; two trailing frames |
| **B. Status frame** | 1 `uio`, ~20 flops | framing, `load_error`, `words_written` live | not the data; `load_error` is cleared at CS fall, so a previous-load status needs a retained copy |
| **C. Peek/poke** | 1 pad + `pe_imem`/`pe_soc` read mux | actual memory contents (imem, later dmem) | the imem macro's one read port is shared with the CPU; a mux/arbiter crosses module boundaries; a command bit breaks "16 rises = a write" |
| **D. Reuse pads** | 0 | -- | impossible: no free `uo_out`; `ui_in` cannot drive; matrix pads are chip-owned at reset |

Recommendation: **A first** -- smallest, additive, backward compatible. B is
additive later if a board wants a status channel; mixing status into the echo
frame is possible but not minimal.

## Test and mutation plan (if A is picked)

1. `tb_pe_ctrl.v`: the host model samples MISO on rising edges and checks
   frame 0 is zero, the echo is the committed word at the chosen latency, bits
   change on falls, and MISO releases on CS high / `run` high. The host SCLK is
   **phase-swept relative to `clk`** (worst case: an SCLK edge just after a clk
   edge) at the documented readback ceiling, checking MISO is stable at least a
   clk before every sampling edge. Every existing write-only case runs
   unchanged (non-vacuity: the old behaviour is not perturbed).
2. `tb_tt_um_protocol_emulator.v`: pad-level phase -- clock an image through
   `ui_in[3:5]`, read the echo on `uio[4]`/`uio_oe[4]`, then raise `run` and
   check the program executes. The unclaimed-pin monitors narrow from
   `uio[7:4]` to `uio[7:5]` while selected.
3. Probes, each independently detected: echo latched at `word_ready` instead
   of the commit edge; **a word aborted by `run` appearing in the echo**;
   change on the rise instead of the fall; `uio_oe[4]` stuck driven / stuck
   released; reversed bit order; frame 0 not zero; wrong echo latency (one vs
   two frames); echo sourced from `shreg` instead of the completed word.
   Extend `regress/mutate_ctrl_tb.sh` (or add a focused suite) and restore the
   source byte-identically.
4. Screens: `regress/synth_area.sh` (expect ~+17 flops and no wrapper logic);
   the pe_ctrl STA screen if its constraints cover the new output, otherwise
   record the register -> pad path class as with the SPI alias. No physical
   flow, DRC or LVS.

## Open decisions for the reviewer

1. **A1 (one-frame, readback <= 2.5 MHz) vs A2 (two-frame, readback
   <= 10 MHz)** -- A1 is the simpler protocol; A2 keeps one SCLK rate. The
   commit latency (up to 6 clk) is what rules out a one-frame echo at 10 MHz.
2. **Trailing frames**: A1 needs one, A2 two (writing `0x0000` into the
   undefined tail); skip them when the program's own output is the proof.
3. **Release condition**: `load_active` (recommended; `run` high also releases)
   vs `~cs_s1` (drives while CS is low even with `run` high).
