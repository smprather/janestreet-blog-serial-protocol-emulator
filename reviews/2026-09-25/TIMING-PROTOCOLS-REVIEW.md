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

---

## DS18B20 (Block 2 act a) — where the read rewrite stands at the flush

Firmware and TB are committed as a **WIP checkpoint** (`0339a29`, `2a60791`); the
TB's latest edge-driven model edit is **uncommitted in the worktree and persists**.
The act is **not wired into `run_all.sh` and is not claimed to pass.** Block 1's
three acts remain green after the merge onto main (ws2812 / servo / dht11 all PASS).

**Verified on real RTL (the write path):** reset pulse 485.7 µs (min 480),
presence pulse found by the firmware's two edge-spins, **16/16 write slots
reconstructed from the pads**, and **both commands 0xCC (SKIP ROM) and 0xBE (READ
SCRATCHPAD) decode correctly, LSB-first, from the wire.** The read path does not
yet bank the right bytes (last run `ff ff`, want `2b 01`).

### Fixed so far (all committed, all in the sources with reasons)

1. **dmem collision between the delay routine and the protocol.** The delay owned
   dmem[9–15] (its middle-counter *target* was dmem[10]) and the protocol also used
   dmem[10] (write command counter, then read byte counter). Every delay overwrote
   the phase counter, so the byte transition read whatever the delay left behind.
   Now **disjoint**: delay owns 9–15, protocol owns 0–8. Write command counter
   moved to dmem[7], read byte counter to dmem[8]. *General lesson: a delay
   routine and its caller must never share a data slot.*
2. **LSB-first accumulate.** The read used the DHT11's shift-LEFT + bit-at-LSB
   (MSB-first accumulation) on LSB-first 1-Wire data, so bytes came back
   **reversed** (0x2b as 0xd4) — right bit count, right ones, so nothing looked
   wrong. Now `SHR` + `OR 0x80` (bit in at the top; the first read slides down to
   bit0).
3. **Fixed-timing read (removed the edge race).** The read waited for the sensor's
   falling edge, but the line was still low from the initiation pulse, so the loop
   exited immediately and every sample landed a whole slot early. Now: pull low
   6 µs, release, wait `OW_T40` (~25.4 µs), **sample the level** — the DHT11
   lesson: count to a fixed instant where the wire presents a level; wait for
   edges only where the wire announces an event.

### The read handshake — what remains, and the key new finding

The remaining fault is **in the TB's sensor model, not the firmware**: the read
cycle is only **~32 µs** (6 µs pull + 25.4 µs wait + overhead), so any model that
*holds* a 1 for longer than ~32 µs never returns to its ready state between slots
and the slots bleed together. Holds of 8/25/40/55 µs were all tried; each read
`ff ff` or a wrong byte. The fix in the latest (uncommitted) edit is to stop
modelling time and start modelling the **master's release edges**: the sensor
presents bit N's level (low for 1, released for 0) from the master's N-th release
until the master's (N+1)-th release, so the level is correct at any instant the
firmware samples, with no model-local hold timer to mis-time. It compiles but was
**still reading `ff ff` when the flush hit** — the edge-driven level logic needs one
more pass (likely the `presenting` gate / `r_bits[n_read_slots-1]` indexing).

### Process note: the pi-lens host_gui blocker was a STALE-COPY finding

Worth recording because it cost a lot of investigation. The recurring
"call without try/except" STOP on `tools/host_gui/{session,transport}.py` was
**stale in both directions**: my worktree's `session.py` was pinned at `e607597`
(8 commits behind main), where `_result_int` did not exist and `_status_fields` /
`_snapshot` were bare conversions — the check was flagging my **stale** copy while
the manager was reading main's **fixed** copy. Merging `origin/main` brought the
gui-worker's `_result_int` fix (31 refs, typed `SessionError`→409, the exact
surface-not-swallow property) into my tree and the tool **downgraded `session.py`
to a [stale] advisory** on its own. The four remaining `transport.py` findings
(L114/115/118/154) are pure `int()`/`float()` coercions of untrusted input on the
gui-worker's surface — manager-ruled **CLOSED as stale-premise, no code change
wanted on either side**. I made **no edit** to either file; the resolution was to
sync the tree, not to edit another actor's surface. *Lesson: for a stale-tree lint
finding on another actor's code, pull the fix; do not hand-edit.*

---

## Act (a) DS18B20 1-Wire — CLOSED, in the regression

Commit `6cc69f9`. `firmware/ds18b20.pe` (205 words) + `tb/tb_pe_soc_ds18b20.v`,
in `run_all.sh` and `run_firmware_tests.sh`, and `mutate_timing_tb.sh` goes
**14 → 26 cases, all 26 detected, 0 survived**.

The flush note said the remaining fault was in the TB's sensor model ("the
edge-driven level gate needs one more pass"). **The model was right and the
firmware was wrong, in two places:**

1. **THE POLARITY.** A 1-Wire *read* slot is LOW = 1 (the slave holds the line
   down for a one); a *write* slot is the opposite, because there the host is
   the one pulling down. `ph4` sampled with `JZ rb_was_zero` — it read a **zero**
   from a line the sensor was pulling **down**. Both bytes came back bit-for-bit
   complemented: `2b → d4`, `01 → fe`. The firmware's own header stated the
   opposite of its code. Same invisible shape as the DHT11's reversed byte.
2. **THE READ BYTE COUNTER** was initialised with `STM 10, A` — `dmem[10]` is the
   **delay routine's** middle-counter target, the slot the write command counter
   was moved off one commit earlier — and decremented at `dmem[8]`, which nothing
   writes. So the loop banked the two *correct* bytes and then, with 255 slots
   left instead of 1, walked the byte index up until it banked over `dmem[5]`
   (its own index) and came back round to overwrite `dmem[0..1]`. That is why
   the flush saw `ff ff` from a read path that was right for all sixteen slots.

**The method note matters more than the bugs:** the model was debugged by
hooking `pc=139` (`ph4`'s `IN`) and `pc=145/149` (the two `STM 4,A`) and reading
`a`/`dmem[4]` per sample. The wire was never the suspect once the decoded
samples were seen to be *exactly the complement* of the model's bits. A
one-bit inversion looks like a protocol bug and is a polarity bug, and the way
to tell them apart is to look at the accumulator, not the waveform.

**The TB's header had been claiming checks it did not implement.** Implemented:
the presence pulse inside 60–240 µs *and* the host's `pin_oe` released on every
clock of it; each write slot's low period inside its own band (1–15 / 60–120 µs);
exactly 16 read slots; every read slot's initiation pulse inside 1–15 µs; and the
**sample instant inside the sensor's data window with ≥ 2 µs of margin at both
ends**. The model gained a `tRDV` response delay at the datasheet's **maximum**
(15 µs), so "sampled too early" became falsifiable, and its read edges now come
off the **pads** rather than off its own state — which is what stopped it losing
the master's next release while still inside the previous bit's hold (that bug
silently ended the run at 8 slots).

**A recorded limit, not a gloss:** `tLOW` is mid-band and deliberately *not* worst
case, because with `tLOW` ∈ 15–60 and `tHIGH` ∈ 1–15 the two windows **overlap**
and no single instant is correct for every legal sensor timing — the guaranteed
window is one microsecond wide. Claiming the worst case there would be a
stronger-sounding and false statement.

Measured: reset 485.7 µs, presence 120.0 µs, write 1-low 5.0 µs / 0-low 64.8 µs,
commands `cc`/`be`, 16 read slots, bytes `2b 01`, initiation pulses 6.2–6.3 µs,
sample 10.8 µs after the response and 19.2 µs before the hold ends.

`ow-sample-late` and `ow-write1-width` are the cases that justify the two new
checks: both **decode correctly** and are caught by the margin and the band
alone. Neither would be caught by a byte comparison, which is exactly why those
checks exist.

## Act (b) NEC infrared remote — CLOSED, in the regression

Commit `a65e114`. `firmware/nec_ir.pe` (165 words) +
`tb/tb_pe_soc_ir_nec.v`, and `mutate_timing_tb.sh` goes **26 → 37 cases, all 37
detected, 0 survived**.

The sharpest timing claim in the repository and the only act with **no wire**:
the only thing that leaves the pin is light, so a receiver has to *find* a
38 kHz burst and time the silences between bursts, and nothing resynchronises to
anything. The carrier is fitted **to the clock**, not to microseconds.

Measured off the pin: **carrier 38,049 Hz (+0.128 %)**, LOW half 787.95–794.95
clocks, HIGH half 788.95 (spread 0.01), leader 8988.0 µs in 343 carrier cycles,
leader gap 4504.0 µs, eight data bursts of 552.0 µs, gaps 4 long (zeros) and 4
short (ones), stop burst 552.0 µs, decoded `a5`. 32 ms of 60 MHz.

The two half-period constants are **separate and fitted separately**, on
different `(n2,n3)` pairs, because the phase ladder costs 7 clocks more coming
out of phase 1 than out of phase 0. The fit lands both on 789 clocks — the same
"equalised branches" discipline the WS2812 act found twice.

**Five firmware defects, all invisible from the waveform's shape:**

1. **The eight-bit immediate, twice.** 9 ms is 342 carrier cycles and
   `LDI A, 342` assembled to `LDI A, 86` — a perfectly good 38 kHz carrier
   carrying a 2.3 ms "9 ms" leader. The leader is now `IR_LEADR` runs of
   `IR_LEAD` cycles. The same truncation hit the leader's gap: `(4,40)` wants
   529 outer steps and `529 & 0xFF` is 17, so 4.5 ms came out as **136 µs** —
   which does not look like a truncated constant, it looks like a transmitter in
   a hurry. It now uses `(3,130)`, whose 1064-clock step reaches the target in
   255 steps.
2. **The bursts never re-drove the pin.** A gap is made by releasing the pad and
   a burst by driving it again; the pad was driven once at the leader, so the
   program ran the whole frame with it released for every burst but the first
   and last — emitting a leader, 13.6 ms of silence and one burst. One shared
   `ir_emit` now, which is the copy the duplication risk warned about.
3. **A ladder that did not cover its own input domain.** `dmem[6]` held 2/3/4 —
   the phase numbers, the obvious thing to write — and `ir_burst_end` treated
   anything past 1 as the stop burst, so the frame ended after the leader.
   **Third instance in this block.**
4. **A setup block with no entry point**, so the bit counter was never set and
   the loop ran 255 times instead of eight.
5. **A block that fell through into its own caller**, which never emitted.

**Three testbench defects, and the pattern is the same as the WS2812 act's — the
measuring instrument inventing defects that are not there:**

6. `$time` is scaled to the module's `timeunit` and returns an integer, so
   timing a 13.1667 µs half period quantises to 0.06 clocks and the carrier
   appeared to jitter `787/788/789` every sixteen cycles. Every width is now in
   **tenths of a nanosecond** from `$realtime`: a measuring instrument with 0.4 %
   quantisation cannot support a 0.06 % claim.
7. `$rtoi` rounds each edge independently, so touching pulses measured as
   −0.1 ns; one negative sample dragged the minimum down and then every other
   half period counted as an outlier against it. A carrier silence is now bounded
   **below** as well as above.
8. The burst reconstruction was a running accumulator that reported every burst
   as 22 carrier cycles while measuring its width correctly — not a combination
   of numbers any waveform has. Rewritten as two passes. A "whole number of
   carrier cycles" check was written and then **deleted as unsound**: the burst
   opens with a two-instruction initiation pulse, so its span is not a whole
   number of periods, and the check fired on all ten bursts *including the
   correct ones*. A check that is wrong about what it measures is worse than no
   check — the first thing anyone would do is loosen the tolerance until it went
   away.

**The mutation gate found the act's own blind spot, which is the most valuable
thing here.** Its first run had 3 survivors of 11. One of them — putting **both**
half periods on the same delay pair — produced a carrier of 788 clocks one way
and 782 the other: 38.05 kHz against 37.88, **0.4 % asymmetric on every edge**,
inside every frequency window a real receiver has, and it **passed**. "Each half
is constant" is not "the two halves are equal". A receiver does not care that the
carrier is on frequency; it cares that the carrier is a *carrier*, and one whose
halves differ is a square wave at 38 kHz with the wrong duty cycle. The TB now
checks the two distributions **against each other**, to within a clock, and that
check is the act's whole point.

The other two survivors: a burst of 20 carrier cycles (526 µs, −6.4 %, which the
old ±10 % window accepted — now ±5 %, which admits the two widths a whole number
of cycles can produce, 21 at −1.7 % and 22 at +2.9 %, and rejects the third);
and a mutant that was behaviourally a no-op because I wrote its anchor against
the byte's *load* rather than its *rotate*.

## Act (c) Stepper step/dir ramp — **WIP, NOT GREEN, NOT WIRED IN**

Commit `b8b3b71`. `firmware/stepper_ramp.pe` (94 words) +
`tb/tb_pe_soc_stepper_ramp.v`. Deliberately **not** in `run_all.sh` or
`run_firmware_tests.sh`: wiring an act that fails would break the suite.

The claim is the sharpest and the simplest in the block — the only act that
drives a **mechanism**, where the driver's edge count *is* the motor's position,
so there is no acknowledgement and nothing to resynchronise to. Every step
period is an exact instruction count measured on the pin, and the ramp is exactly
linear **to the clock**: the firmware subtracts ten outer steps of the `(4,40)`
pair (5110 clocks) per step, so the constancy is *in the program*, not an
assumption about a table of twelve constants.

**Verified:** the ramp is exact on **8 of its 10** step intervals, measured as an
equality against 5110 clocks and not a tolerance — 1661.133 µs falling to
809.501 µs (602 Hz → 1235 Hz), 12 pulses, 12 distinct periods, all strictly
shortening, all in band, `dmem[14]=1`, and the firmware's ramp counter landing on
76 after twelve decrements of 10.

**Two faults open:**

1. **Two intervals around the direction change are off by a matched pair.**
   Interval 4→5 measures 4736.71 clocks and 5→6 measures 5482.67, summing to
   exactly 2 × 5109.7 — so ~373 clocks of cost have moved one interval later than
   they belong. 373 is close to `ST_SETUP`'s 418, and the direction change plus
   its setup delay is the only thing in the program that is not a step, so the
   mechanism is almost certainly the setup delay landing in the interval after
   the one it should be in. **Not root-caused** — the phase-3 setup return is the
   first place to look.
2. **The direction-change setup-time check is not running at all.** Its first
   version searched only the first DIR edge, which is the pin-matrix *init*
   rather than the flip, so it was vacuous by construction; fixing that exposed
   that the flip's timestamp does not land where the search expects.

**Two firmware defects already fixed, both the shape of ones this block has
already found.** The ramp counter was `dmem[9]` — the **delay routine's own
outer counter**, which counts itself to zero — so the program ran twelve steps at
a constant 2.09 ms: every step read back zero, subtracted ten, and got 246
again, the unsigned wrap, which is a perfectly plausible step period. *A delay
routine and its caller must never share a data slot.* And the ramp decremented
**before its first use**, so the nominal 196 was spent immediately and the first
interval was exactly one ramp step too long — which is what a counter
initialised off by one looks like from the outside.

**Two testbench defects, the pattern of the previous three acts:** `$time`
quantisation (every width here is in tenths of a nanosecond, because this act's
claim is right to the *clock*), and the ramp first computed in one pass that
compared each period against the next **before computing it**, so every "ramp"
equalled a period and every ramp check passed while printing numbers that looked
like measurements. A check that reads a value the loop has not filled in yet is
a check that cannot fail.

### Resume point, exactly

Root-cause the 373-clock displacement around the direction change (start with the
phase-3 setup return in `ph2`), then the DIR edge placement, then wire into
`run_all.sh` + `run_firmware_tests.sh`, then add the mutation gate. Do not
plausible-ise fault 1 into an accepted exception until it is explained.

## The pattern across all five acts, stated once

Every one of these defects is **invisible from the waveform's shape alone**: a
reversed byte, a complemented byte, a truncated immediate, a runner that reads
back its own zero, a set-up block with no entry point, a ladder that does not
cover its callers, a counter initialised one step off. In every case the program
runs, the waveform looks like a protocol, and the only thing that catches it is a
testbench that **reconstructs the data from the wire and compares it against what
was sent** — plus a mutation gate that perturbs the fitted constants, because
three of the five acts *are* a fitted constant and a gate that cannot perturb one
is not testing the thing the act claims.

And four of the twelve defects were in the **measuring instrument**, not the
thing measured: a quantised clock, a rounding artefact poisoning a minimum, an
accumulator reporting numbers no waveform has, and a check reading a value the
loop had not written. That is worth more than the defects themselves, because a
defect in the testbench invents a defect that is not there, and the first thing
anyone does with an invented defect is go looking for it in the design.
