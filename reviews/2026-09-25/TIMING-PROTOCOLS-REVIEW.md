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

## Act (c) Stepper step/dir ramp — CLOSED, in the regression

Commit `2f2e6c4`. `firmware/stepper_ramp.pe` (96 words) +
`tb/tb_pe_soc_stepper_ramp.v`, in `run_all.sh` and `run_firmware_tests.sh`, and
`mutate_timing_tb.sh` goes **37 → 48 cases, all 48 detected, 0 survived**.

The only act here that drives a **mechanism**: the driver chip counts STEP
edges and the motor's position *is* that count, so there is no acknowledgement,
no status word, and nothing at the far end to resynchronise to. The claim is
therefore the sharpest and the simplest in the block — every step period is an
exact instruction count measured on the pin, and the ramp is exactly linear **to
the clock**. The firmware subtracts ten outer steps of the `(4,40)` pair
(5110 clocks) per step, so the constancy is *in the program* rather than assumed
about a table of twelve constants.

Measured: **1661.133 µs falling to 809.501 µs (602 Hz → 1235 Hz)**, 12 pulses,
12 distinct periods, all 11 intervals strictly shortening, all in band,
direction changed once mid-ramp with **6.00 µs of setup**.

### The two faults the WIP checkpoint left open were both closed — and neither was a fault in the ramp

**1. The 373-clock displacement was NOT a defect.** The direction change is the
only thing in the program that is not a step, so exactly one interval carries it:
that interval is long by the setup delay (349 clocks) plus 24 instructions of
flip bookkeeping, and the interval after it is short by the same 373 —
`4735.72 + 5483.67 = 2 × 5109.7` exactly. **The check was wrong, not the
firmware**: it expected two anomalies where there is one cost and its recovery,
and it never established what the cost *was*. It is now pinned rather than
excused — every other interval exactly on the line, the **pair sums to exactly
twice the line**, the change is the long one, and the excess is at least the
setup delay — so a firmware that added or dropped an instruction in the flip
fails the sum.

**2. The direction change NEVER REACHED THE WIRE, and the cause was a real
firmware bug.** The step's level write went out as `LDI A, 0x00; OUT TXPIN, A`
and cleared the **DIR bit** too, so the first step zeroed DIR and the change half
a ramp later wrote 0 to a register that was already 0. The direction never
changed after step one, and the TB's `n_flip == 2` check **passed on a spurious
pair of edges at init** — one when the program set DIR at startup and one when
the first step cleared it.

**That was the FOURTH write in the program that cleared the other pin**, all with
one cause, and they were found in this order:

| write | what it clobbered |
|---|---|
| the step's level write (`0x00`) | DIR zeroed by the first step — the direction never changed |
| `ph1`'s release (`0x00`) | DIR floating for the whole of every step pulse |
| `st_step`'s `PINOE` (`ST_STEP`) | **DIR released at exactly the STEP edge, which is where a driver decodes it** — hence the new `ST_BOTH` constant |
| the park's (`0x00`) | a direction change after the last step |

`PINOE` and `TXPIN` are **whole registers**, so a write that means "this pin" is
a write that also means "the other pin" unless the other pin's level is carried
in it. The direction *value* now lives in `dmem[0]` and every write carries it.
This is the same lesson the 1-Wire act recorded for `od` and this repository's
third instance of "what a peripheral sees is the PIN, not the data register".

### The gate found the act's own blind spot twice more

**A released DIR pad SURVIVED every edge-based check.** The edges such a pad
makes land on the interval **boundaries** rather than inside an interval, and a
pad floating to the pull-down still reads as a **valid level** — so nothing about
edge counts or intervals can see it. The fix is the sharper claim the protocol
actually makes: **a driver decodes DIR on the STEP edge**, so the TB now measures
the direction **at every step edge** — 6 of 6 high in the first run, 0 of 6 in
the second, changing exactly once at step 6. A floating pad during the step
pulse decodes as the wrong direction on *every* step, and nothing else in the
file noticed.

**A second mutant survived twice and looked like a gap in the testbench both
times — and was neither.** It released the DIR pad at the direction change, which
put it in a position that seemed to implicate the edge checks. It does not: the
pad is released for the four instructions between that write and the write that
sets the direction, **and the direction being set is the pull-down's own value**,
so the wire is identical either way. It is a **benign mutant**. It was **deleted
and replaced** rather than caught by loosening a check, because a gate that
claims to catch a no-op is making the same error as a check that cannot fail,
one level down. This is the second time this act block has deleted a mutation
that was not a defect (the first was `ir-no-rotate`, written against the byte's
load rather than its rotate).

### Three testbench defects, and the pattern is the same as the previous four acts

The measuring instrument, again: `$time` quantises to the module's `timeunit`
(1 ns) and returns an integer, so every width here is in **tenths of a
nanosecond** — this act's claim is that a step period is right to the *clock*,
and 1 ns is 0.06 clocks, an order of magnitude coarser. The ramp was first
computed in **one pass that compared each period against the next before
computing it**, so every "ramp" equalled a period and every ramp check passed
while printing numbers that looked like measurements. And `dir_lvl` watched the
**data register** rather than the pin, so a released pad looked like a valid
level — found by the gate (`st-dir-released` survived), which is the third time in
this block the gate has found the act's blind spot rather than a defect in the
design.

### One more counted-delay-constant mutation, and how to pick a good one

`st-ramp-const` is the case worth copying for any ramp: it does **not** shift
the whole ramp, because shifting a ramp is a *different valid ramp, not a
defect*, and a gate claiming to catch that would be claiming to catch a choice.
It sets `ST_GAP0 = 112`, which **runs the ramp out**: by the twelfth step the
counter is 2 outer steps, 17 µs, an order of magnitude under the driver's minimum
step rate — and one step earlier it is 255, the unsigned wrap, which is the
defect this block has now found four times. Two more mutate constants directly
(`ST_SETUP` under the driver's 5 µs, `ST_PULSE` under the driver's 1 µs) and one
mutates the ramp **decrement** from 10 to 9 — a perfectly good ramp that is not
*this* ramp, and which only an equality check against 5110 can tell apart.

### Still open

Nothing. All three Block 2 acts are closed and in the regression.

## The pattern across all six acts, stated once

Every one of these defects is **invisible from the waveform's shape alone**: a
reversed byte, a complemented byte, a truncated immediate, a runner that reads
back its own zero, a set-up block with no entry point, a ladder that does not
cover its callers, a counter initialised one step off. In every case the program
runs, the waveform looks like a protocol, and the only thing that catches it is a
testbench that **reconstructs the data from the wire and compares it against what
was sent** — plus a mutation gate that perturbs the fitted constants, because
three of the five acts *are* a fitted constant and a gate that cannot perturb one
is not testing the thing the act claims.

And **seven of the eighteen defects were in the measuring instrument**, not the
thing measured: a quantised clock (twice), a rounding artefact poisoning a
minimum, an accumulator reporting numbers no waveform has, a check reading a
value the loop had not written (twice), a watch on the data register instead of
the pin, and an edge-count where the claim was about edge *position*. That is
worth more than the defects themselves, because a defect in the testbench
invents a defect that is not there, and the first thing anyone does with an
invented defect is go looking for it in the design.

**The last two lessons are the ones I would keep.** A *check* can pass without
running — the direction-setup assertion sat behind an `if (found)` that was never
true, and an edge *count* passed on two spurious edges for a program in which
the direction never changed. And a *mutation* can survive without being a defect
— releasing a pad for four instructions before setting it to the pull-down's own
value changes nothing on the wire, and loosening a check to catch it would be
claiming to catch a no-op. Both are the same error one level apart: a gate
element that reports success without asserting anything.

---

## Act (b) Block 3 — INPUT FREQUENCY + DUTY METER — CLOSED, in the regression

`firmware/freqmeter.pe` (103 words) + `tb/tb_pe_soc_freqmeter.v` + 4 peasm
CONSTS (`FM_IN`, `FM_PER_BASE`, `FM_HI_BASE`, and the map comment that goes
with them).

### Why this act is a different shape of problem

The other six all **drive** a pad. This one **listens**. The PWM arrives from
outside, the program cannot ask when the edges are coming, and the answer it
has to produce is a count between two edges it did not schedule. So the number
that is the claim is not a delay at all — it is the **accuracy of a count**,
and the honest way to state that is per point, because the instrument's
resolution *is* the specification:

| point | period | relative error of a 1 µs counter |
|---|---|---|
| 10 000 µs (100 Hz) | 10 000 | 0.01 % |
| 100 µs (10 kHz) | 100 | 1.0 % |

The tolerance is therefore 1 % of the period with a floor of 1.5 ticks, and at
the fast end of the sweep the *tolerance* is the dominant term and the
quantisation is a percent of it. A single accuracy number would be a false
claim at one end or the other.

### The ISA constraint, and what it cost

No carry flag, only `JZ`/`JZ`… only `JZ`/`JNZ`. Three arithmetic facts decided
the whole program, and they are worth stating because the third one is the
expensive one:

1. **A 16-bit increment is cheap.** `+1` on the low byte is exactly zero when
   it carries, so the carry test is one `JZ` on the low result.
2. **A 16-bit add of a variable is affordable, but only just.** The carry test
   is the same `JZ`, except that `0 + 0 = 0` is not a carry, so a general
   addend needs a *guard*: when the low result is zero, reload the low operand
   and test it for zero too. This program gets that guard away **for free**,
   because its addend is the elapsed microsecond count and is therefore never
   zero — "the low byte came out zero" can then only mean "the low byte
   wrapped". The guard is not skipped, it is *unnecessary*, and the comment
   says which.
3. **A 16-bit subtract is a different machine.** The borrow of `a - b` cannot
   be read off the difference: `(a-b) mod 256` has two preimages, one positive
   and one negative, for every value except zero. Getting it exactly needs a
   four-case analysis on bit 7, and a *compare* is the same analysis again.

So the program contains **no 16-bit subtract and no compare at all**, and the
design is what removes them:

> the period is `T` at the rising edge, because `T` is **reset** at every
> rising edge; the high time is `H` at the rising edge, because `H` is also
> reset there and stops counting at the falling edge.

Two resets remove every subtract, every compare and every divide. The
firmware therefore measures rather than computes — the act's commit message
called it *capture only* before a line of it existed, and that is what it
turned out to be, for a reason the commit message could not have known.

### The trap in the timebase, and why the flag is not used

This SoC has **two** tick counters and they are not the same size:

| port | name | period | what it is for |
|---|---|---|---|
| 0x7 | `STATUS` | 260 clocks = **4.33 µs** | the UART half-bit tick: it exists to place a serial sample mid-cell |
| 0x4 | `I2CTICK` | 60 clocks = **1 µs** | the free-running microsecond counter |
| 0x6 | `I2CSTAT` | 1 µs | that counter's clear-on-read flag |

The first version counted `STATUS`, and measured 0.24 ticks per microsecond: a
factor of 4.33 out, reporting a 200 µs period as 46. A tick counter whose name
says TIMER is not a microsecond.

The fix is not to use the 1 µs *flag* either. A clear-on-read flag is one bit,
so a poll loop that takes longer than a tick reports several ticks as one, and
the loss is invisible in the result — the measurement is simply short, by an
amount that depends on how busy the program was. This program reads the
**counter** and adds the **difference**:

```text
elapsed = (now - previous) mod 256
```

exact for any loop up to 255 µs, and this loop is 1.3 µs — two hundred times
inside it. Two properties follow, and both are bought by the same three
instructions:

* there is no flag to lose, so a slow iteration (the bank is the slowest thing
  in the program) makes the measurement late by **exactly the right amount**
  rather than wrong;
* the borrow of `now - previous` is used only as "is it zero", which is the
  one comparison the ISA has. The *value* of the same subtraction is the
  elapsed time, so one `SUB` does both jobs.

### The machine has sixteen bytes, and the testbench had to be told

`DMEM_BYTES = 16` in `rtl/pe_soc.v`, and every top level passes 16. A period is
two bytes and a high time two, so the firmware banks **two points per run** and
the sweep is **six runs of three periods** — the first period of each run is a
warm-up, and it is not checked, for a reason that is a property of the protocol
rather than of the firmware: the firmware starts in the middle of it, so the
time since the previous rising edge is not a period. A receiver that starts
mid-period misses that one period. A testbench that pretended otherwise would
be asking the firmware to measure something it was never present for.

The RED testbench (ccb6b8d) asked for sixteen points in `dmem[0..63]` on a
machine with sixteen bytes: twelve of its own expectations were read out of an
address space that does not exist, and its DONE flag at `dmem[14]` was *inside
the data it was reporting*. **A test that sizes memory to what it wishes for is
a test that reports success without measuring anything**, and the count of such
elements in this block is now three.

The map uses all sixteen, and one byte is shared rather than found: the slot
index doubles as the "no rising edge seen yet" state (`FF`), because the
program needed one byte more than the machine has and the slot index is the one
value that is not a measurement.

### Measured (real RTL, Icarus + the real SRAM macro)

Twelve banked points, each checked against a **second, independent measurement
of the pad** (the receiver in the TB), not against the generator's table — a
generator that knew the answer would agree with a firmware that had the sweep
wrong.

```text
point  0: period   8000 us ( 125.00 Hz)  high 6000 us  duty 75.0 %  [pad 8000.000 / 75.00 %]
point  1: period  10001 us (  99.99 Hz)  high 2500 us  duty 25.0 %  [pad 10000.000 / 25.00 %]
point  2: period   3150 us ( 317.46 Hz)  high 1039 us  duty 33.0 %  [pad 3150.000 / 33.00 %]
point  3: period   4000 us ( 250.00 Hz)  high  400 us  duty 10.0 %  [pad 4000.000 / 10.00 %]
point  4: period   1600 us ( 625.00 Hz)  high 1056 us  duty 66.0 %  [pad 1600.000 / 66.00 %]
point  5: period   2000 us ( 500.00 Hz)  high 1600 us  duty 80.0 %  [pad 2000.000 / 80.00 %]
point  6: period    801 us (1248.44 Hz)  high  480 us  duty 59.9 %  [pad  800.000 / 60.00 %]
point  7: period   1000 us (1000.00 Hz)  high  399 us  duty 39.9 %  [pad 1000.000 / 40.00 %]
point  8: period    400 us (2500.00 Hz)  high  180 us  duty 45.0 %  [pad  400.000 / 45.00 %]
point  9: period    500 us (2000.00 Hz)  high  275 us  duty 55.0 %  [pad  500.000 / 55.00 %]
point 10: period     80 us (12500.00 Hz) high   12 us  duty 15.0 %  [pad   80.000 / 15.00 %]
point 11: period    100 us (10000.00 Hz) high   50 us  duty 50.0 %  [pad  100.000 / 50.00 %]
```

Every period is exact except three, by exactly **one tick** — 10 001, 801 and
399 against 10 000, 800 and 400 — and the duty follows to a tenth of a point
(59.9, 39.9) because the two counts share the same edge discipline. Those
three are the resolution showing up in the log instead of hiding in a
tolerance, which is what a measured-truth record should look like.

The 16-bit claim is point 1: 10 001 µs, from a counter whose low byte wrapped
**39 times**. A firmware counting into a byte reports **16 µs** there, and has
no symptom at any other point in the sweep.

### Defects found, in the firmware (2) and in the testbench (4)

**Firmware**

1. **The wrong tick counter.** Port 7 is the 4.33 µs UART half-bit tick, not
   a microsecond. Every measurement was a factor of 4.33 out, and *short* at
   every point — the shape a timebase mistake always has, and invisible in a
   log that only prints the two slowest points.
2. **A clear-on-read flag for a timebase.** Not a wrong answer yet, but the
   design was one busy iteration away from losing ticks silently; replaced by
   the counter difference, which is immune.

**Testbench**

3. **`pin_in_bus` put the PWM on bit 5, not bit 6.** `{1'b1, 1'b1, pwm,
   5'b11111}` is eight bits with `pwm` third from the top — the firmware reads
   bit 6, so the pad never appeared to change and the firmware sat in its
   poll loop for 60 ms reporting nothing. Inherited from the RED testbench, and
   the reason the first full run's only output was a watchdog. The three
   sibling acts all write the same concatenation correctly
   (`{1'b1, ow_line, 6'b111111}`), so the correct form was in the repository
   and was not copied.
4. **The receiver was armed before the pad was presented, not when the
   firmware was released.** Whether presenting the pad high is itself an edge
   depends on where the previous run's waveform stopped, so the edge list had
   a spurious entry on some runs and not others, and the index arithmetic
   (`2k+1`, `2k+2`) was off by one exactly when nobody was looking. Two of the
   twelve points were compared against the wrong interval. Armed at the
   release instead, the list *is* the firmware's own view of the signal.
5. **A ternary that was never a comparison.** `if (a > b ? w : f)` parses as
   `if ((a > b) ? w : f)`, and both arms of the ternary are nonzero, so the
   condition was **always true**: the period and high-time checks reported
   "12 of 12 are not" for values that differed by 0.0000 µs, and a check that
   fires on correct data is a check nobody will read twice. The same
   expression, in a `$display`, evaluated correctly — which is why it took a
   debug copy with the difference printed to find.
6. **A result that was never written passed every arithmetic check.** A
   comparison against an unknown is false in Verilog, so a firmware that banked
   one point and left the other slot alone passed the period check, the
   high-time check, the duty check and the DONE check. Found by asking what a
   `fm-finishes-early` mutant would do, before writing the mutant: the TB now
   has an explicit "was it actually written" check.

### Non-vacuity

Ten mutation cases, all detected. Two of them exist because this act's own
failure modes demanded them:

| mutant | what it proves |
|---|---|
| `fm-tick-port` | the timebase is the 1 µs counter and not the 4.33 µs one |
| `fm-t-high-byte` | the 16-bit claim: the high byte really is incremented |
| `fm-h-high-byte` | …in the *other* counter too (the longest high time, 6 000 µs, is not covered by the longest period) |
| `fm-wrong-pad` | the pad mask constant, reached through `--const` because a `sed` of the `.pe` cannot reach peasm's table |
| `fm-no-rearm` | the reset that makes the measurement elapsed-time rather than absolute-time — and it is the one mutant whose **first** point is still correct |
| `fm-double-count` | the counters advance once per elapsed microsecond |
| `fm-idx-stuck` | the slot index advances |
| `fm-finishes-early` | the run does not stop after one point (and it is caught only by the new X check) |
| `fm-high-is-period` | the high time is banked from the high-time counter, not the period counter — every duty would read 100 %, which is a value a careless reader accepts |
| `fm-per-base` | the slot base constant, where a shifted base *overlaps* the working counters on a sixteen-byte machine instead of running off the end |

Plus the testbench's own non-vacuity: the twelve periods and the twelve high
times are pairwise distinct, the duties are neither constant nor 50 % twice
running, and at least one banked period is above 255 while another is inside a
byte — which is the 16-bit claim stated from both sides.

### The cost, stated

~43 ms of 60 MHz — 2.6 M clocks, the largest simulation in this repository, and
~55 s of wall. It is not trimmed: the 100 Hz point is where the 16-bit claim is
tested, and dropping it would leave the act asserting something it had not
measured. Two things were done about the cost and neither weakened a claim —
the generator is **edge-driven with absolute delays** rather than woken once per
clock (a 2.6 M clock TB that woke up 2.6 M times to decide whether the pin had
moved would spend its wall time deciding it had not), and the DONE flag is
polled every 256 clocks rather than every clock, because the firmware is parked
once it is set and a per-clock read of `dut.dmem` is 2.6 M hierarchical reads.

---

## MERGE-REPAIR: six acts red in main, and the cause was not in the six acts

**manager dispatch 2026-09-25 · commit `3657847` on `fw-timing-protocols`**

### What was reported

All six acts fail in main (5b4731f and later) with `dmem = xx`, zero edges.
They were green on the branch they were verified on. The manager's hypothesis
was that the merge dropped something in the act dependency chain, with
`tools/fw/peasm.py` named as the visible difference.

### What the evidence said, and it was not the hypothesis

**Every one of the twelve files the six acts own is byte-identical between main
and the green branch** — six `.pe`, six `.hex`, six TBs, and `peasm.py`. That
was checked by object hash (`git rev-parse main:<path>` against
`HEAD:<path>`), not by eye. There is nothing in the six acts to repair.

The `peasm.py` difference the manager saw is **this branch's uncommitted
Block 3 WIP**: the `FM_IN` / `FM_PER_BASE` / `FM_HI_BASE` constants and the
block's comment. It is work in progress on this branch, not damage done by the
merge, and it is now a separate commit (`d88e316`) that a `git diff` of two
trees will not confuse with a merge artefact again.

The real difference was one file the six acts do not own and do depend on:
**`rtl/pe_cpu.v`**, where the R3 debug-control block added two **module
inputs**, `dbg_hold` and `dbg_step`.

### The mechanism

```verilog
wire cpu_exec = dbg_step || (run && !dbg_hold);   // R3, as merged
```

A testbench that predates those ports leaves them unconnected. The port arrives
as `Z`, so `!dbg_hold` is `X`, so `cpu_exec` is `X`, so **`if (cpu_exec)` is
false and the core never commits an instruction**. Every observable in the
system then stays at its reset value: `dmem` reads back `x`, the pad never
moves, and the testbench reports zero edges and eventually a watchdog.

The evidence that this is the whole story is a **pattern**, not an argument.
Of the nineteen testbenches that instantiate `pe_soc`:

| tie `dbg_hold`? | count | result |
|---|---|---|
| no | **7** | **all 7 fail** (the six acts + the RED frequency meter) |
| yes | 12 | all 12 pass (`tb_pe_soc_tick`'s comment reads "R3: debug control idle here") |

Seven failing out of nineteen, and the seven are exactly the seven that do not
name the ports. A merge that dropped content does not produce that shape; a
new port with no default does, precisely.

### The repair, in two independent hunks

1. **`rtl/pe_cpu.v`, where the input is consumed.** The gate now tests both
   debug inputs with **case equality against `1'b1`**, so anything that is not
   a hard one reads as "not held" / "no step" — the debug interface is
   inactive unless something actively asserts it. In synthesis this is the
   identical expression (`x` and `z` do not exist in hardware), so the netlist
   does not change. The convention belongs at the consumer rather than at
   every call site, because a call site is the one place that can forget it.
2. **The six acts' TBs, plus the frequency meter's**, tie the ports
   explicitly, so no act *depends* on an RTL convention and the two repairs
   cannot mask each other.

Either alone is sufficient; both are kept.

### Reported, not touched: the formal wrapper

`formal/pe_soc/formal_pe_soc.v` also instantiates `pe_soc` without naming
these two ports. There a floating input is not a dead core but a **free
variable**, so every `pe_soc` target is proved with the debug hold free rather
than inactive — weaker, not broken, and invisible in the current results.
That is the R3 owner's call to make, so it is flagged rather than fixed here.

### And a pre-existing failure the merge also carries

`R3 golden package: FAILED` — `reviews/2026-09-25/r3-hex/README.md` and
`tb/r3-vectors/README.md` disagree about the chip-confirmation status (25 of 26
steps claimed chip-confirmed in simulation, versus none). **Reproduced
identically in a pristine export of main**, so it is not caused by the repair.
Also out of scope here; flagged for the R3 owner.

### Verification

All on real RTL, Icarus, the real `1P_1024x16` SRAM macro, in throwaway
`git archive` exports of main so the main worktree was never touched.

| probe | contents | result |
|---|---|---|
| **B** | `main` as merged, unpatched | **6/6 FAIL** (`edges=0`, `dmem=xx`) |
| **A** | `main` + the `rtl/pe_cpu.v` hunk **only** | **6/6 PASS** |
| **C** | `main` + the six TB hunks **only** | **6/6 PASS** |
| **worktree** | `main` + both (this branch) | **6/6 PASS** |

The commands, from any `git archive main` export, with
`SRAM=$(regress/sram_model.sh)` and
`RTL="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v"`:

```sh
cd tb
for t in ws2812 servo dht11 ds18b20 ir_nec stepper_ramp; do
  iverilog -g2012 -s tb_pe_soc_$t -o /tmp/v_$t.vvp $RTL $SRAM tb_pe_soc_$t.v
  timeout 900 vvp /tmp/v_$t.vvp | grep -E '^(PASS|FAIL)'
done
```

**Run these from the `tb/` directory.** The testbenches `$readmemh` a path
relative to it (`../firmware/<name>.hex`), and running the same binaries from
`/tmp` produces `ERROR: $readmemh: Unable to open ...` and then
`FAIL: ... edges=0` — a failure signature **identical** to the real defect. I
produced two rounds of exactly that false evidence before noticing, and it is
the most dangerous coincidence in this whole episode: a wrong working
directory reproduces the merge bug perfectly.

### Two process notes worth keeping

**I broke my own repair once, silently.** The port list ended without a
trailing comma, so the `.dbg_hold` line became part of the comment and the port
was still unconnected — the same defect as not writing it, and it elaborates
and runs. All six acts still failed. Nothing but *compiling* caught it: no
test, no gate, no assertion. An elaboration failure is the only instrument
that sees a port that is syntactically fine and semantically absent.

**A full suite run in this worktree filled `/tmp` and left mutants in the
tree.** `run_all.sh --fast -j8` reached RTL 46/46 and FIRMWARE 37/37 — with
the frequency-meter act included and green — and then eight mutation harnesses
failed with `OSError: [Errno 28] No space left on device`, and one of them
could not restore its snapshot: `FATAL: rtl/pe_eth_mac.v does not match the
snapshot after restore`. Sixteen files were left mutated. This is the
documented hazard (the per-worktree lock protects files from concurrent
*runs*, not from a restore that fails), reproduced by running out of disk.
Recovery was `git checkout -- firmware/ rtl/ formal/`; the tree is clean at
`3657847` and `mutate_eth_mac_tb.sh` then reported **30 detected, 0 survived,
0 harness errors** with the tree byte-identical afterwards — so those eight
failures were environmental, not the repair.

**And I killed another worker's run doing it.** Stopping my own suite with
`pkill -9 -f "[v]vp"` matched **the manager's own verification run** in
`/tmp/vm-red`, which then exited 137 (SIGKILL) and printed
`MERGE GATE: RED — DO NOT PUSH HEAD`. The pattern was self-match-proof but not
*scope*-proof: a pattern that cannot match itself can still match everyone
else's processes. `pkill` is the wrong instrument in a shared `/tmp`; naming
the process tree and killing by PID is the right one.
