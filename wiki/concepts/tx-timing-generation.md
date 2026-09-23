---
title: TX Timing Generation (No PLL)
created: 2026-09-18
updated: 2026-09-21
type: concept
tags: [clocking, architecture, protocol, decision]
sources: [raw/articles/tinytapeout-clock-spec.md, raw/transcripts/gemini-asic-competition-discussion-2026-09.md]
confidence: high
---

# TX Timing Generation (No PLL)

Binding TX constraint across all targets: the 50 ns half-UI of 10BASE-T Manchester. (SPI half-SCLK ties it only if we choose 10 MHz SCK — that rate is ours to pick.) Everything else is >=100 ns.

## The 60 MHz operating point (ADR-005)

The ~66 MHz figure is the platform's pad ceiling ([[entities/tiny-tapeout]]), NOT
our operating point: the demo-board clock is programmable 1 Hz-66.5 MHz. Set it
to **60 MHz** (see [[decisions/adr-005-60mhz-turbo]]):

- TX (single-edge, no DDR needed): 50 ns = exactly 3 ticks, 100 ns = exactly 6. Spec-exact Manchester edges, 10 MHz SCK, binary-rate SWD/JTAG. No fractional anything.
- RX (DDR per [[decisions/adr-002-latch-pair-det-flop]]): 60 MHz dual-edge = 16.67 ns sample period, an 8.33 ns grid = exactly 6 samples per 50 ns half-UI — 12 samples per 100 ns bit (SPB = 12), extending the ADR-001 design point upward by 50%.
- USB-LS (1.5 Mbps): 666.67 ns = **exactly 40.00 ticks** single-edge — integer, so the NCO is a plain divider here rather than a 53/53/54 dither. At 40 MHz it was 26.67 ticks and needed the dither; 60 MHz removes that quantization entirely.
- UART 115200: half-bit tick is 260 clk (delivered 115,385, +0.160%) — improved from +0.353% at 40 MHz.

**40 MHz is no longer the default.** The history: 40 MHz was chosen because
50 ns = 2 ticks, and it worked; 60 MHz is strictly better on every axis, so the
repo moved to it (2026-09-21). The change was parameters and comments only —
no RTL restructuring, no firmware edit.

## 66 MHz is NOT the upgrade — it is provably infeasible for 10BASE-T TX

An earlier revision of this page called 66 MHz a "forced fallback" whose edge
quantization "eats the 10BASE-T TX jitter budget". That understated it. The
window is a **conformance test**, and 66 MHz fails it for every possible edge
placement, dithered or not.

The test (IEEE 802.3 §14.3.1.2.3, as implemented by UNH MAU suite
14.1.10/14.1.11): after a triggering zero crossing, the next crossings must fall
at **8.0 BT ±11 ns and 8.5 BT ±11 ns** with the twisted-pair model (±20 ns
without). 1 BT = 100 ns, so 8.0 BT = 800 ns = 16 half-UIs and 8.5 BT = 850 ns =
17 half-UIs.

A run of identical bits puts a crossing on **every** half-UI, so both spans are
constrained at once. Let the gaps between consecutive crossings be integer tick
counts `d_k`. Then

```
span16(k) = d_k + d_(k+1) + ... + d_(k+15)       must lie in +/-11 ns of 800 ns
span17(k) = span16(k) + d_(k+16)                  must lie in +/-11 ns of 850 ns
```

At 66.0 MHz (T = 15.1515 ns) the window admits exactly one tick count each:

| span | ideal | ticks in window | error |
|---|---|---|---|
| 800 ns | 52.80 | **53** (52 gives −12.12 ns) | +3.03 ns |
| 850 ns | 56.10 | **56** (57 gives +13.64 ns) | −1.52 ns |

Subtracting the two forces `d_(k+16) = 56 − 53 = 3` for every k, so every gap is
3 ticks and `span16 = 16 × 3 = 48` ticks = 727 ns — but the window demands 53
ticks = 803 ns. **Contradiction.** Equivalently: the span average must be
53/16 = 3.3125 ticks while the 17-span constraint pins each gap at exactly 3.
No dither escapes this; the constraint is on the sliding window, not on the
instantaneous edge.

**66.5 MHz is feasible and 66.0 is not, and 0.5 MHz is the whole reason:**
at 66.5 MHz (T = 15.0376 ns) `A16 = {53}` and `A17 = {56, 57}`, so gaps may be 3
or 4 and a 16-periodic pattern of **5 gaps of 4 and 11 gaps of 3** sums to 53 and
keeps every 17-span in {56, 57}. It works, it needs a designed dither generator,
and it buys 0.5 MHz over 60 for that complexity.

## The actual upgrade: 60 MHz, exact with no dither anywhere

`f = 20n MHz` makes both 50 ns and 100 ns exact integers. Below the 66.5 MHz
ceiling that means n = 1 (20), n = 2 (40), **n = 3 (60)**. 60 MHz is generated
exactly by the demo board (RP2040 120 MHz / 2). The board's own default,
62.5 MHz = 125/2, is *not* 20n and fails the same way 66 does.

| | 40 MHz | **60 MHz** | 66 MHz |
|---|---|---|---|
| 10BASE-T half-UI (50 ns) | 2.000 exact | **3.000 exact** | 3.300 → infeasible |
| 10BASE-T bit / SPI 10 MHz half | 4.000 / 2.000 exact | **6.000 / 3.000 exact** | 6.600 / 3.300 |
| TX jitter window | PASS, uniform | **PASS, uniform** | **FAIL, provably** |
| CAN 1 Mbps, I2C 100 kHz, PS/2 | exact | **exact** | exact |
| USB-LS bit (666.67 ns) | 26.667 (−0.33) | **40.000 exact** | 44.000 exact |
| RX DDR grid | 12.500 ns | **8.333 ns** | 7.576 ns |
| samples per 50 ns half-UI | 4 (SPB=8) | **6 (SPB=12)** | 6.6 (uneven) |
| UART 115200 half-bit | 173 (+0.353%) | **260 (+0.160%)** | 286 (+0.458%) |

**60 MHz is strictly better than 40 on every axis**, not merely faster: it keeps
every hard protocol exact, *improves* the USB-LS and UART quantization, and
refines the receive grid by 50% (SPB 8 → 12). Verified by running the DRU
testbench at SPB = 12: **`PASS: tb_pe_dru`**.

Note the SPB ceiling is **16**, not merely "a multiple of 4": `phase` is 4 bits
and `4'(SPB-1)` truncates above it, which silently kills all capture (SPB=20
emits nothing, with no error). Both constraints are now elaboration errors and
both are boundary-tested by `regress/param_guards.sh`. SPB=12 is comfortably inside.

**Measured end-to-end, not just on paper:** `tb_pe_soc_uart` with `CLK_HZ` set to
60 MHz passes unchanged — the firmware, the tick divider (260 = 60 MHz/115200/2),
and the whole SoC — with **no RTL or firmware modification**. That is the real
evidence that the turbo is a one-parameter change. (Both runs print Icarus's
`Not enough words in the file for the requested range [0:1023]` warning, which is
pre-existing and harmless: `uart_echo.hex` is 114 words and the TB loads into a
1024-word array.)

## Verdict

One programmable board clock; DDR capture for RX only; integer timing for every hard protocol; tiny NCO for the slow fractional ones. No PLL, no DLL, no on-die multiplication anywhere.

- **The operating point is 60 MHz, LOCKED** (ADR-005) — +50% core cycles over 40,
  exact timing throughout, SPB = 12. **It is no longer a parameter.** `CLK_HZ` is
  a `localparam` in `pe_soc` as of 2026-09-22: nothing ever instantiated the
  SoC at another rate, so the parameter was a second place for the derived
  arithmetic to be wrong rather than a real knob. See
  [[reference/clock-arithmetic]] for the computed constant table.
- **66 MHz is not a turbo, it is a trap.** It cannot meet the 10BASE-T TX jitter
  conformance window at any edge placement, and it breaks SPI's 10 MHz SCK
  integer relation. It also used to be the **STA signoff target**; that is now
  retired — both flow configs close at `CLOCK_PERIOD` 16.667 ns, so the reported
  slack IS the operating point with no conversion. See
  [[comparisons/clocking-options]] and [[concepts/cdr-oversampling]].

## Post-fabrication protocol ceiling (the Jane Street "arbitrary protocol" question)

Pulse width sets the SPEED floor: capture needs >=1 grid tick (8.33 ns plan grid at 60 MHz / 15.15 ns if 66 MHz single-edge), robust sampling >=2. Run length sets the PROTOCOL-CLASS ceiling for async protocols: (longest transition-free run) x (combined clock tolerance) must stay under 0.5 UI.

- Source-synchronous (clock on wire): unlimited rates, pure firmware, no tracking constraint.
- Async + regular transitions: bounded by tolerance class — 10BASE-T-class (+-100 ppm) tolerates 2500 UI runs; CAN-class (+-0.5%) 100 UI; UART-class (+-4%) only 12.5 UI; typical RC-osc (+-2%) 25 UI.
- Async + long runs + sloppy clocks (e.g. 30-bit preamble from a +-2% RC device): NOT DRU-coverable; falls back to firmware polling at core speed — same wall every PIO/PRU-class machine (RP2040 included) hits.

## Signoff policy: close AND run at 60 MHz

Core clock and protocol timing are orthogonal (all timing is strobe-based via NCOs/dividers), so:

- **Sign off every block at 60 MHz (16.667 ns), which IS the operating point.** Both flow configs carry this. The signoff was 66 MHz (15.15 ns, the pad-macro ceiling) until 2026-09-22; that target is **retired**, because it made every reported slack number require a conversion by the reader and because a longer period is strictly easier for setup — a design that closes at 66 has already closed at 60. Stating it directly is the clearer claim. The pad-ceiling hedge it used to provide is gone; if real IHP pads turn out to top below 66 MHz that is now a re-signoff rather than free, and the honest position is that no IHP-specific pad figure is published either way.
- **The operating point is locked at 60 MHz for integer-exact protocol timing**, with a 50%-finer RX grid than 40 (SPB 8 → 12). It is a `localparam` in `pe_soc`, not a parameter — see [[reference/clock-arithmetic]].
- Costs: ~50% more dynamic power at 60 than at 40 (no per-tile power wall at TT scale).

## Clock uncertainty spec: 1.0 ns at 66 MHz (not a blanket 5%)

TT's board clock is crystal-derived (RP2040/RP2350 PWM-PIO divided): ~50 ppm period accuracy — ppm-level offset, absorbed by NCOs, NOT STA uncertainty. The 10 ns pad insertion delay is constant skew (hits clock+data alike through the mux, cancels intra-tile), not uncertainty. FS/SF data-pad slew goes to set_input_delay rise/fall skew (SPICE-derived), not clock uncertainty.

Defensible budget: 0.1 ns board PLL jitter + 0.2 ns DDR latch-pair duty penalty + 0.4 ns clock-tree IR derate (PDN-hardened plan) ~= 1.0 ns (6.6% of 15.15 ns). Leaves +6.6 ns of the +7.6 ns pe_serdes slack intact. If silicon disagrees, revisit the IR derate knob first.
