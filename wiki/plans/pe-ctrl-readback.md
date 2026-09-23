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
    readback SCLK **<= 5 MHz** (the per-bit MISO path still binds; two frames
    only relaxes the commit path).
  - **A3, rising-edge update + two frames**: readback SCLK **<= 10 MHz** --
    the only variant that reaches the loader rate; MISO changes ~3 clk after
    each *rising* edge (documented, non-mode-0 change timing).
- A write-only host that ignores MISO is bit-identical to today.
- Reading the last word(s) costs one (A1) or two (A2) trailing frames, which
  write `16'h0000` to `imem[N]`/`imem[N+1]`; the tail past the image is already
  undefined (ADR-007). After a full 1024-word load `load_error` latches and the
  receive path stops, so trailing frames assemble and write nothing; the host
  may skip them when the program's own output is the proof.

## Timing audit (2026-09-23): two independent ceilings (mode 0 at 10 MHz cannot meet setup)

Derived from `rtl/pe_ctrl.v` at the worst-case SCLK phase relative to the
60 MHz `clk` (the pad edge lands just after a clk edge; 16.67 ns per cycle).
Two paths set the readback rate, and they are independent:

**A. The per-bit MISO update path (binds every bit, at every frame latency).**
A registered update triggered by the synchronized falling edge:

| Event | Delay from the SCLK falling pad edge |
|---|---|
| `sclk_s0` captures | +1 clk (16.7 ns) |
| `sclk_s1` captures; the fall detector is valid for one clk cycle | +2 clk (33.3 ns) |
| the MISO register samples the detector | +3 clk (50 ns) |
| pad output + host setup | +t_pad + t_setup (~5 + ~10 ns) |

The host samples at the next rising edge, one half period later:
`T/2 >= 3 clk + t_pad + t_setup` ≈ 65 ns -> a **computed limit of ~7.7 MHz**.
This cap is independent of how many frames the echo is delayed, which is why
A2's frame delay does not fix it. A combinational fall-gated update
(2 clk + logic) would reach ~9-11 MHz but puts the pad on an asynchronous
gate; it is not proposed.

**B. The echo-commit path (binds the first bit; frame latency relaxes it).**
The completed word is registered at +3 clk, but the imem write commits and
`W_DONE` runs at **+5..6 clk (83-100 ns)**; the echo must be commit-latched
(never `word_ready`; an aborted word must never echo). The first echo bit must
be present before the host's first sample of the frame that carries it:

- **A1 (one frame)**: first bit at the frame's 16th fall, `T/2` after the
  completing rise -> `T/2 >= 6 clk`, a **computed limit of 5.0 MHz** (no
  margin). The per-bit limit (7.7 MHz) is not binding here; the earlier
  6-clk half-period derivation is this term, and it remains the A1 maximum.
- **A2 (two frames)**: first bit at the following frame's 16th fall, `1.5T`
  after the rise -> `T >= 4 clk`, limit ~15 MHz; the **per-bit limit
  (7.7 MHz) is binding**, not the commit.

**Combined**: A1 = min(5.0, 7.7) = **5.0 MHz computed**; A2 = min(15, 7.7) =
**7.7 MHz computed**. Neither reaches 10 MHz with a registered falling-edge
update: **A2 does not support 10 MHz** -- the earlier version of this plan
claimed it did by solving only the commit path.

The documented ceilings are the computed limits **with deliberate margin**, not
the limits themselves: A1 -> 2.5 MHz (half period 200 ns vs the 6-clk commit,
2x margin); A2 -> 5 MHz (half period 100 ns vs the 65 ns per-bit latency,
~2 clk of pad/setup/jitter margin).

**A3, the safe 10 MHz variant (different implementation).** Update MISO on the
synchronized *rising*-edge detector instead: the bit changes ~3 clk after the
edge the host just sampled with, so the next sample is a full period away:
`T >= 3 clk + t_pad + t_setup` ≈ 65 ns (limit ~15 MHz), and with a two-frame
echo the commit (<=6 clk) fits `1.5T` comfortably (limit ~15 MHz). At 10 MHz
the margins are ~35 ns per bit and ~50 ns on the commit. The cost is a
documented deviation from strict mode-0 change timing (MISO changes ~50 ns
after each rising edge, not on the fall); a mode-0 host only requires setup
before its sampling edge, so this is safe, but it must be written into the
contract and tested.

The pad/host terms assume `t_pad ~ 5 ns` and `t_setup ~ 10 ns`; the ceilings
scale with what a board actually adds (the formula is the record, the numbers
are the assumption).

## Options and tradeoffs

| Option | Logic/pads | Verifies | Cost |
|---|---|---|---|
| **A1. One-frame echo** (recommended default) | 1 `uio`, ~17 flops | every committed word bit-exact, through the shift and write path | readback SCLK <= 2.5 MHz; one trailing frame; no status channel |
| **A2. Two-frame echo** | same + frame tracking | same (commit-latched) | readback SCLK <= 5 MHz (per-bit bound); two trailing frames |
| **A3. Rising-edge update, two frames** | same, update on `sclk_rise` | same (commit-latched) | readback SCLK <= 10 MHz; non-mode-0 change edge; two trailing frames |
| **B. Status frame** | 1 `uio`, ~20 flops | framing, `load_error`, `words_written` live | not the data; `load_error` is cleared at CS fall, so a previous-load status needs a retained copy |
| **C. Peek/poke** | 1 pad + `pe_imem`/`pe_soc` read mux | actual memory contents (imem, later dmem) | the imem macro's one read port is shared with the CPU; a mux/arbiter crosses module boundaries; a command bit breaks "16 rises = a write" |
| **D. Reuse pads** | 0 | -- | impossible: no free `uo_out`; `ui_in` cannot drive; matrix pads are chip-owned at reset |

Recommendation: **A first** -- smallest, additive, backward compatible. B is
additive later if a board wants a status channel; mixing status into the echo
frame is possible but not minimal.

## Test and mutation plan (if A is picked)

1. `tb_pe_ctrl.v`: the host model samples MISO on rising edges and checks
   frame 0 is zero, the echo is the committed word at the chosen latency, bits
   change on falls (A1/A2) or within ~3 clk after each rise (A3), and MISO
   releases on CS high / `run` high. The host SCLK is **phase-swept relative
   to `clk`** (worst case: an SCLK edge just after a clk edge) at each
   candidate's documented ceiling (A1 2.5 MHz, A2 5 MHz, A3 10 MHz), checking
   MISO is stable at least a clk before every sampling edge. Every existing
   write-only case runs unchanged (non-vacuity: the old behaviour is not
   perturbed).
2. `tb_tt_um_protocol_emulator.v`: pad-level phase -- clock an image through
   `ui_in[3:5]`, read the echo on `uio[4]`/`uio_oe[4]`, then raise `run` and
   check the program executes. The unclaimed-pin monitors narrow from
   `uio[7:4]` to `uio[7:5]` while selected.
3. Probes, each independently detected: echo latched at `word_ready` instead
   of the commit edge; **a word aborted by `run` appearing in the echo**;
   change on the rise instead of the fall for A1/A2 (and on the fall instead
   of the rise for A3); `uio_oe[4]` stuck driven / stuck released; reversed
   bit order; frame 0 not zero; wrong echo latency (one vs two frames); echo
   sourced from `shreg` instead of the completed word. Extend
   `regress/mutate_ctrl_tb.sh` (or add a focused suite) and restore the source
   byte-identically.
4. Screens: `regress/synth_area.sh` (expect ~+17 flops and no wrapper logic);
   the pe_ctrl STA screen if its constraints cover the new output, otherwise
   record the register -> pad path class as with the SPI alias. No physical
   flow, DRC or LVS.

## Open decisions for the reviewer

1. **A1 (one-frame, strict mode 0, readback <= 2.5 MHz) vs A2 (two-frame,
   strict mode 0, readback <= 5 MHz) vs A3 (rising-edge update, two frames,
   readback <= 10 MHz)** -- A1 is the simplest protocol; A2 does not reach
   10 MHz because the per-bit MISO path binds at every frame latency; A3 is
   the only 10 MHz path and it documents a non-mode-0 change edge.
2. **Trailing frames**: A1 needs one, A2/A3 two (writing `0x0000` into the
   undefined tail); skip them when the program's own output is the proof.
3. **Release condition**: `load_active` (recommended; `run` high also releases)
   vs `~cs_s1` (drives while CS is low even with `run` high).
