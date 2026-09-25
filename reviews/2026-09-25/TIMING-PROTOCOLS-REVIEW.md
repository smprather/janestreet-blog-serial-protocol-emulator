# Timing protocols — WS2812, servo PWM, DHT11

**2026-09-25 · branch `fw-timing-protocols` · three new demo acts**

## What this is

Three protocols in which the **waveform is the specification**, added as firmware
plus testbench plus a demo act. They are the sharpest available test of the
project's cycle-accuracy claim, because nothing on the wire gives a receiver a
clock to resynchronise to: the value *is* a pulse width, and a program that is
one clock out is wrong.

| act | firmware | TB | the number that is the claim |
|---|---|---|---|
| WS2812, 800 kHz one-wire, GRB | `firmware/ws2812.pe` (129 words) | `tb/tb_pe_soc_ws2812.v` | every 1-cell high for **exactly 48 clocks** (800.0 ns) |
| Servo PWM, 50 Hz, 1–2 ms | `firmware/servo_sweep.pe` (84 words) | `tb/tb_pe_soc_servo.v` | frame period **19 999.95 µs = 50.000 Hz**, widths within 0.15 µs |
| DHT11, start signal + 40-bit read | `firmware/dht11_read.pe` (134 words) | `tb/tb_pe_soc_dht11.v` | sample margin **17.0 µs / 25.0 µs**, both sides |

## Measured results (all on real RTL, Icarus + the real SRAM macro)

```text
WS2812   7 frame starts found (anchored on the >50 us reset)
         reset before frame 1: 60.85 us      reset between frames: 62.28 us
         frame 0: 9c e0 8a (G,R,B)   frame 1: 9c e0 8a (G,R,B)
         10 one-cells at 48 clocks (800.0 ns), 14 zero-cells at 0
         PASS: all checks

SERVO    5 rising edges, 6 falling edges
         pulse 0:  1000.15 us  (+0.15)     pulse 3:  1250.13 us  (+0.13)
         pulse 1:  1500.13 us  (+0.13)     pulse 4:  2000.10 us  (+0.10)
         pulse 2:  1750.12 us  (+0.12)
         frame period (1000 us -> 1500 us): 19999.95 us = 50.000 Hz
         dmem[10] (position index) = 5      PASS: all checks

DHT11    start signal: line low for 18093.0 us
         host-high window: 30.0 us, then released (pin_oe)
         40 samples (spin-loop reads filtered), 40 bits sent by the sensor
         bytes: 2c 01 aa 55 2c   (humidity, temperature, checksum)
         sample margin: 17.0 us past the longest 0-release, 25.0 us before the 1 ends
         PASS: all checks
```

## How the timing is made exact

The core is single-cycle (one instruction per clock, no stalls), so **N
instructions take exactly N clocks**. Every timed interval in these programs is
therefore either straight-line code (the WS2812 cell) or a loop whose every
iteration has a fixed instruction count (the two delay routines). No delay is
calibrated against the free-running 1 µs tick, because that tick's phase
residual is up to a full microsecond — **80 % of a WS2812 bit cell** — and the
error would be the resolution of the mechanism rather than a rounding error in a
constant.

The delay routine is three nested 8-bit counters:

```text
total(n1,n2,n3) = (n1-1) * (10 + (n2-1) * (4*n3 + 7)) + 4   clocks
```

The counters are **fitted to the target by division and a small search**, not by
trial and error, and the tables are in `tools/fw/peasm.py` and the firmware
headers. The WS2812 bit cell and the servo table land within 0.15 µs of nominal;
the DHT11's 18 ms start lands 0.5 % long, which is the right direction for a
minimum.

## Defects found and fixed on the way (all recorded in the sources)

The most valuable part of this block is the list of things that were wrong before
they were caught, because most of them are *invisible* defects — the program
runs, the waveform looks plausible, and a window check forgives it.

**In the firmware (8):**

1. **The delay routine's missing inner reload.** Both inner counters are
   destroyed by their own loops; the first version read and wrote one slot, so the
   second outer pass read zero, subtracted one, wrapped to 255, and produced
   1.1 M clocks where 3 631 were asked for.
2. **The level driven on the wrong pin bit** (0x80 instead of the data pin's
   0x40): correct-looking levels, on the wrong bit for seven cells in eight.
3. **The next cell's bit taken from the unshifted byte**: every cell repeated the
   previous cell's bit.
4. **The byte counter starting at 0** instead of 8: 255 cells per byte.
5. **The equalised branches off by one**, twice — the byte-boundary cell 13 clocks
   short, then 1 clock long.
6. **`ADD A,X` read as "load X"** in the DHT11 accumulator, so the bit was doubled
   instead of set.
7. **`X` used as scratch** where the ISA's own header says it is the long-lived
   index: every byte was banked at the accumulator's own value.
8. **The DHT11 accumulator built right-shift**, i.e. LSB first: a *reversed* byte,
   which has the right number of bits and the right number of ones and so looks
   nothing like broken.

**In the testbenches (5)** — which is the part worth recording, because a defect in
the measuring instrument is worse than a defect in the thing measured:

9. **The clock counter and the edge recorder in two `always @(posedge clk)`
   blocks.** Icarus does not guarantee the order, and a recorder that sees the
   counter before the increment on one cycle and after it on the next turns a
   perfect 75-clock cell into an alternating 74/76 — a firmware that is one clock
   out every other edge. One process, and the WS2812 cell was exact.
10. **`50 * 60_000_000` overflows a 32-bit integer** to a negative number, so the
    reset threshold matched *every* rising edge and a "second frame" was really
    cell 3 of the first.
11. **Frame anchors taken from the first two rising edges**, which are cell 0 and
    cell 3 for this data, not two frames. Replaced by an anchor on the reset.
12. **The host-high window measured on the line**, where it is unmeasurable: the
    host drives high and then releases, and the pull-up holds the line high
    throughout, so the release moves nothing. Measured on `pin_oe` instead.
13. **The DHT11 sample recorder filtering on the gap *before* a read** rather than
    the gap after it, which records the first read of every spin loop instead of
    the forty real samples.

**And one in the harness's own conventions (1):**

14. **`run` raised at the same instant as a clock edge.** The instruction memory
    is a real SRAM macro with a registered read; the fetch is left half-updated and
    the first instruction is silently dropped. The servo firmware's first
    instruction is `LDI A,97`, the one that loads the first entry of the pulse
    table, so the drop left `dmem[0]` as X and the first position's delay was
    taken from an unwritten byte — a 2.6 ms pulse where 1.0 ms was asked for.
    The failure pointed at the arithmetic rather than at the load. Fixed the same
    way `tb_pe_soc_eth_loop.v` fixes it: four stopped clocks, then a `#1`.

## Non-vacuity

`regress/mutate_timing_tb.sh`: **14 firmware mutants, 14 detected, 0 survived, 0
harness errors**, and the firmware tree is `cmp`-verified byte-identical
afterwards. Each mutant is chosen so the check it trips is the *specific* property
the testbench claims:

| mutant | trips |
|---|---|
| WS2812 cell one clock short | the 75-cycle grid (not a window — 74 clocks is still 1.23 µs) |
| WS2812 level on the wrong bit | the decode |
| WS2812 line never driven low | the decode (7 checks) |
| WS2812 byte index never advanced | the decode |
| WS2812 reset reload removed | the >50 µs reset |
| servo first pulse 1.0 → 1.75 ms | the per-pulse width and the sweep span |
| servo 20 ms slot → 17.6 ms | the frame period |
| servo two positions swapped | the sweep ORDER |
| servo line idles high | the pulse count (the first pulse has no rising edge) |
| DHT11 start signal 18 ms → 0.26 ms | the start signal |
| DHT11 host window 30 → 170 µs | the 20–40 µs window |
| DHT11 sample at 14 µs instead of 45 | the decode (inside a 0's release) |
| DHT11 accumulator right-shift | the decode (a reversed byte) |
| DHT11 wait-for-release removed | the decode |

The TBs also assert non-vacuity directly: the WS2812 frame must open with a 1
(so the cell grid has an edge to anchor on) and contain both bit values; the
servo's five widths must be pairwise distinct and span >900 µs; the DHT11 frame
must carry ≥20 bit-transitions out of 39.

## The cost, stated

The servo TB simulates **52.5 ms** and the DHT11 TB **22 ms** of 60 MHz — 3.2 M
and 1.33 M clocks, 66 s and 29 s of wall time. That is two orders of magnitude
more than any other TB in the repository, and it moves the full regression from
about a minute to about three. Three things were done about it and none of them
weakened a claim:

- the frame rate is measured on **two** 20 ms slots rather than five (the sweep
  claims rest on five measured *widths*, which is what they need);
- the two long TBs dump a **narrow** signal set instead of `$dumpvars(0, tb)`,
  which was 99 s → 66 s on the servo alone — the waveform, not the design, was
  the bottleneck;
- the edge recorders are **edge-triggered with `$realtime`**, not per-clock with
  a counter, worth another ~40 %.

## Limits

- The DHT11 is **modelled**, and the model reproduces the bus hold after the
  fortieth bit. That is not bending the test to the firmware: the host's sample
  method (after a 0's release ends) is the only method in use, so a sensor that
  released the bus immediately would make the last bit unreadable by any of them.
  The 26–28 µs and 70 µs figures are the sensor's own windows and the model
  drives the **worst case of each**.
- The servo TB does not read the servo's position-feedback pulse. A real driver
  would; this one drives and parks.
- One DHT11 read, then park. A real driver loops (the DHT11 needs ~1 s between
  conversions, which is not this simulation's timescale).
- The WS2812's 0-cell is low for the whole cell rather than carrying a 0.4 µs
  high first. Measured and reported rather than implied: the strip samples at
  about 2/3 into the cell, so a line that is low throughout is unambiguously a 0.
- The three acts use pin 6. It is the first unclaimed pad in the documented map,
  and claiming it does not change the pin budget (the three programs are
  alternatives, not additions to a single image).

## Evidence

- `./regress/run_all.sh --fast -j8` — RTL **37/37**, firmware **29/29**, lint
  clean, every gate, **13 mutation suites** (the new `mutate_timing_tb.sh`
  included at 14/14).
- `tools/fw/peasm.py` gains four `CONSTS` entries (`LED_DIN`, `WS_RST1`,
  `WS_RST2`, `SRV_DATA`, `DHT_DATA`) in the existing timing-constants block.
- Docs: `docs/demo-walkthrough.md` gains the three acts with their measured
  numbers; `wiki/STATUS.md` gains the summary block.
