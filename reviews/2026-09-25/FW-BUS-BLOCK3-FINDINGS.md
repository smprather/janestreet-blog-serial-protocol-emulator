# BLOCK 3 — UART rate flexibility: findings (2026-09-25)

Worker `fw-bus`, branch `fw-bus-protocols`. BLOCK 2 landed as `02c9101` +
`a4a9772`. **BLOCK 3 is complete and committed.**

> ## THE HEADLINE CORRECTION, and it reverses this file's own earlier conclusion
>
> The previous version of this file ended with:
>
> > "the transmitter is right and the testbench's receiver is the defect"
>
> **That was wrong, and every part of it was wrong for the same reason: the
> transmitter's arithmetic was never checked against the wire.** A clock-resolution
> probe of the TX pin shows the pin carrying a bit cell of 979 clocks — a
> transmitter running at 61 kbaud on a MIDI wire — with every byte arriving
> shifted right by two. Nothing about the receiver could have found that,
> because the receiver was being written to agree with a wrong wire.
>
> Seven real firmware defects were found in the two programs, and **none of them
> was found by reading the code**. All seven were found by a testbench that
> measured the pin. Four of them produced output that was *mostly correct*,
> which is the shape of bug that survives review, and one of them was found only
> because the receiver was built to verify a stop bit.
>
> The one durable lesson is at the bottom: **a delay built by counting
> instructions is arithmetic, and arithmetic that is only ever compared with
> itself has never been tested.**

---

## Measured results, one line each

> **MIDI.** All fourteen wire bytes exact (`90 20 40 21 41 22 42 80 23 43 24 44 25 45`),
> running status replacing rather than accumulating (six messages, **2** status
> bytes on the wire, 14 bytes not 18), **0 framing errors**, and a bit cell
> measured at **31.9987 µs = 31,251 baud with a spread of 0.0000 µs across all
> fourteen frames** — i.e. 1920 clocks exactly, where 1920 clocks *is* 31,250
> baud.
>
> **DMX512-A.** Break **88.06 µs** (floor 87.5), mark **12.38 µs** (floor 8.0),
> **513 of 513** slots decoded with **both** stop bits verified on every one,
> every slot value equal to the recomputed ramp, and a cell measured at
> **3.9998 µs = 250,010 baud, spread 0.0000 µs across all 513 slots** — 240
> clocks exactly, where 240 clocks *is* 250,000 baud.

Both programs are timed by counted instructions, and both land on their nominal
rate to the clock. That is the result the block exists to produce, and it took
seven defects and a receiver rewrite to reach it.

---

## Defect 1 — the rate was TWICE the MIDI rate

The old header said "half-bit at 31.25 kbaud = 960 clocks = 16.000 µs", which is
**true**, and then built 960 clocks *per bit cell*. A cell is a whole bit, not a
half. Measured: 16.316 µs per cell, i.e. **61,286 baud on a MIDI wire**.

The old header went on to report "31,188 baud, 0.2 % from nominal" — a number
produced by dividing the measured cell by two, which is asking the wrong question
of the right measurement. It is worth keeping that in the record: the error was
not a typo in a constant, it was a unit confusion that *looked* like a
carefully-measured number, and only the wire could catch it.

**The TB's rate window is anchored to 32.000 µs, never to the firmware's own
arithmetic**, and that is the only reason this was catchable at all.

## Defect 2 — every byte lost its two lowest bits

`sb_hold` was the common tail of all ten cells and the shift lived there, so the
**stop cell and the start cell each shifted the working copy**. Ten shifts for
eight bits. The wire carried `source >> 2` on all fourteen frames: `0x90` went
out as `0x24`, `0x20` as `0x08`, `0x40` as `0x10`.

Only the two highest bits of a MIDI status byte survive that, so a receiver
would have decoded six well-formed messages built from the wrong data. The
shift now lives in the **data branch only**: *a cell that carries no data bit
must not consume one.*

## Defect 3 — there was no stop bit at the end of the frame, and the byte check did not find it

The cell dispatch tested the index for zero, so cell 0 drove 1 and cell 1 drove
0: the frame was `[stop][start][d0..d7]`, one cell out of phase, and the only
high cell in a frame was the *next* frame's leading cell.

Because the stream is back-to-back, that is a **well-formed** frame — the missing
stop bit is the next frame's first cell. The receiver decoded **thirteen of the
fourteen bytes correctly**, including `0x90` and the running-status flip to
`0x80`. It failed only on the **last** frame, which has no following frame to
supply a stop bit, and it failed as a single stop sample reading low.

So: neither the byte comparisons nor the rate check found this. The one check
that did is the receiver's — *a frame is accepted only if its stop bit reads
high*. **Thirteen of fourteen is a failure, not a near-miss**, and that is the
argument for building a receiver that verifies rather than a position counter
that counts.

## Defect 4 — a cell's length belongs to the PATH BETWEEN TWO CELLS

This is the most expensive fact in both files, and `midi_xfer.pe` paid for it
twice.

The obvious model is "each cell drives its bit, waits, repeats". Under that
model the padding NOPs look like arbitrary constants. They are not: the time
from one cell's **output** to the next cell's **output** depends on *which cell
is next*, because the dispatch that selects the next cell's code is only partly
executed on each path. Reaching a data cell runs six instructions of dispatch;
reaching the start bit runs five; the first stop runs two and the second three.

Measured in DMX, at clock resolution, on one frame: cells of **241, 240 and
1917 clocks**. The TB reported a mean of 4.0114 µs and a spread of 0.0148 µs,
which is not a rate at all — it was half the slots at 4.0165 µs and half at
4.0000 µs. Only a histogram of the *distinct* measurements says that, and that
histogram is now printed.

The fix is padding NOPs whose counts are not a matter of taste:

| | MIDI | DMX |
| --- | --- | --- |
| data cell (the reference) | 1920 clocks | 240 clocks |
| padding needed | 3 in `sb_start`, 3 + 5 in `sb_stop` | 3 in `sb_start`, 5 in `sb_stop`, 2 + 4 in `sb_stop2` |
| cells per frame | 10 | 11 |

## Defect 5 — the page counter was incremented per slot, not per page

DMX's first version counted slots and pages in one byte, so the frame ended
after **two data slots**. Caught as a watchdog timeout 250 µs into a 22.6 ms
frame with three slots decoded correctly — which is the shape a "the frame
stopped early" bug always has: everything that was decoded was *right*.

The fix is two bytes and the arithmetic that separates them: a slot counter
within a page (which wraps on its own, so it needs no comparison at all) and a
page counter beside it.

## Defect 6 — the page counter was never initialised, so the frame never ended

`dmem[9]` was written only at a page boundary, so at the first one it was `x`;
`x + 1` is `x`, and `SUB A, 2` on an `x` is an `x`. The comparison could never
be true and the firmware transmitted for ever. The wire was **perfect** — 513
correct slots — and the symptom was a watchdog timeout with the transmitter
still running.

Worth recording next to defect 5: both are "the frame ended at the wrong time",
one from counting the wrong thing and one from counting an `x`, and both present
as *the wire looks perfect*.

## Defect 7 — the start code's exit advanced the payload ramp

The transmitter has one exit, and the start code's exit landed in the same
place a data slot's did. The payload became "data slot *k* + 1" instead of
"*k*": still a ramp, still a legal fixture, and one index out of step with every
document describing it. A flag in `dmem[7]` and one branch fix it, because a
shared transmitter on an ISA with no `CALL/RET` needs the frame layer to say
what leaving it means.

---

## The receiver, and the four versions that failed first

`tb_pe_soc_midi.v` is a **free-running oversampling search**: a background
strobe every **eighth** bit (8×, 4 µs) on its own timeline, a high-to-low
transition as a *candidate* start bit, eight samples at mid-points, and **the
stop bit verified before the frame is accepted**. A candidate whose stop reads
low is discarded and the search continues, which costs nothing because the
sampler never waited for the decoder.

**It is 8×, and this file said "quarter-bit" until 2026-09-25 16:30.** The cause
was not loose prose: the receiver's interval variable was *named* `quarter`
while holding a bit divided by eight, and the name propagated into three
committed places — this file, `tb_pe_soc_dmx512.v`'s header, and one WORKLOG
entry — before anyone compared the name against the code. The variable is now
`ovs_ns` and the reason is recorded at its declaration. It is the same lesson as
the 5.7 M strobe claim one section down, and the same reason it survived: **the
mutation gate checks the firmware, and nothing in the suite checks a testbench's
claims about itself.** A variable whose name lies will keep writing false
comments for whoever reads the file next.

Four earlier versions decoded from edges and every one failed on a back-to-back
8N1 stream, for one reason: **in a back-to-back 8N1 stream a falling edge is not
a start bit and a rising edge is not a stop bit.** A data bit going 1→0 falls
exactly like a start bit.

| version | what it tried | how it failed |
| --- | --- | --- |
| 1 | `@(negedge tx_pin)` starts a decode | a data transition starts a decode mid-frame; returned `0xa8` where `0x90` went out |
| 2 | a `decoding` flag blocking 9.5 bit periods | consumed the real start bit whenever a data edge woke it early; missed ~2 frames in 3 |
| 3 | require ≥1.5 bit periods of HIGH before a fall | for the data pattern 1,1,0 the preceding high run is two whole bits, indistinguishable from a stop bit |
| 4 | anchor on the stop bit, measured | the rate check differenced consecutive POSEDGES and counted data-bit rises, so the frame period came out 5× short and 12 of 14 stop bits read low — a phase-error detector wearing a rate check's clothes |

**And the one distinction the finished receiver keeps:** an edge monitor
timestamps transitions to the picosecond, because using an edge for *timing* is
not the same as using it to *decide*. The stop-bit sample decides; the monitor
only measures. A receiver that takes both decisions from edges is version 1.

## The rate window is 0.3 %, and that number is not a preference

The transmitters are counted-instruction dividers on a known 60 MHz clock, so the
only rates they *can* produce near nominal sit on a grid set by the delay loop's
body:

| | MIDI (13-clock body) | DMX (2-clock body) |
| --- | --- | --- |
| cell | 1920 clocks = 32.000 µs | 240 clocks = 4.000 µs |
| neighbours | 1907 / 1933 clocks, ±0.68 % | 238 / 242 clocks, ±0.83 % |
| TB window | ±0.3 % | ±0.3 % |

MIDI 1.0 allows ±2 %. A ±2 % window would admit all three of MIDI's achievable
rates, the rate check would be decoration, and **the counted-delay mutation would
survive it**. The window is narrower than the quantisation so that it admits
exactly one achievable value — which is the only reason the mutation gate can
prove the check is not vacuous.

## The cell is measured INSIDE a frame, and why that is not a detail

The obvious measurement is "difference consecutive start bits". It is **wrong**:
consecutive frames are ten cells *plus the message layer's inter-frame gap*, and
that gap depends on which branch the message layer takes — sending a status byte
costs more instructions than running status does. Measured that way, the TB
reported 32.0437 µs for a transmitter putting 32.0000 µs on the wire; the
0.0437 is the message layer, not the transmitter.

What *is* exact is a pair of edges inside one frame, because a frame's cells are
all one length and nothing else comes between them. The TB takes the start bit's
falling edge, takes the next edge on the wire, counts the cells between them from
the byte it just decoded, and divides. The count comes from a byte the verified
stop bit has already vouched for and which the expected-byte checks hold to a
fixed list, so the measurement is not circular: **the bytes are known before the
rate is asked for.**

That measurement found defect 4, and it found the DMX page counter bugs are
invisible to it (as they should be — those are frame-level, not cell-level).

## The "every cell is the same length" assertion, and why the window could not do it

One clock is 0.05 % of a MIDI bit. So is a single padding NOP. **The ±0.3 %
window is blind to it by a factor of six** — and a mutation adding one NOP to
`sb_start` survives the window while breaking the frame's rate.

Both TBs therefore also assert that every in-frame measurement agrees to within
a picosecond. The clean firmware measures **exactly zero** spread, because a pure
divider has nothing to be inexact about. That check is what makes
`midi-cell-padding-nop` a detected mutation rather than a survivor.

## The factorisation, and the 8-bit counter that eats it

| | delay needed | body | iterations | result |
| --- | --- | --- | --- | --- |
| MIDI | 1898 clocks | 13 (11 NOPs + `SUB` + `JNZ`) | 146 | 1920 clocks = 31,250 baud |
| MIDI break/mark | 236 clocks/iteration | 2 (`SUB` + `JNZ`) | 117 | 240 clocks = one bit cell |
| DMX | 219 clocks | 2 | 109 | 240 clocks = 250,000 baud |
| DMX break/mark | 236 clocks | 2 | 117 | 240 clocks = one bit cell |

`1 instruction = 1 clock` is **measured, not assumed**: the first version of
MIDI's loop counted 979 instructions from one cell's `OUT` to the next, and a
clock-resolution probe of the TX pin measured 979 clocks (16.316 µs). That exact
agreement is the single fact both cell budgets rest on, and it is why the
arithmetic is written as arithmetic and the TB measures the pin.

**Keep every delay-loop counter ≤ 255.** This is not a style rule. A count that
does not fit the 8-bit counter is not a build error — the assembler is silent,
the loop runs `count mod 256` times, and nothing else in the system can tell. The
first probe written for the MIDI act did exactly that with a 319-iteration loop
and reported a "measurement" that was silently the time since reset. The nearest
DMX trap is a 3-clock body wanting `634 / 3`, which rounds to a count that fits
and is wrong by 3 %.

## DMX-512-A: the rate a tick cannot express at all

A DMX bit is 4 µs and the shared tick is 4.3333 µs, so a bit is **0.923 of a
tick** and the timer cannot be used even once. The two acts bracket the problem
exactly: **MIDI is the rate a fractional tick cannot express; DMX is the rate a
tick cannot express at all.**

Break (≥ 87.5 µs) and mark (≥ 8.0 µs) are expressed in **whole bit cells of the
same counted delay** — 22 and 3 — so there is no second timing constant in the
file to get wrong. 87.5/4 = 21.875, so 22 is the smallest whole number of cells
that clears the floor, and it clears it by 0.5 µs. The mark uses three cells
rather than two: two is 8.000 µs, *exactly* the minimum, and "exactly the
minimum" is not a place to build a design when one more cell costs nothing.

**The 512-slot payload is a wrapping 8-bit ramp**, because an 8-bit register
incremented with an 8-bit add *is* one — two instructions per slot, recomputed
independently by the TB. It cannot be faked by a transmitter with the bit order
reversed, because a 512-slot ramp is not a palindrome in either order: slot 1 is
`0x01` and slot 128 is `0x80`, and swapping the orders turns the first into
`0x80`.

## The lean testbench, and a performance claim of mine that was false

One DMX512-A frame is **22.6 ms of simulated time = 1.37 million clocks**, and
`tb_pe_soc_dmx512.v` finishes in ~28 s.

The first plan was to reuse the MIDI receiver's free-running strobe, and I
justified dropping it with a number: *"following it literally would have meant
5.7 million strobe events across the frame — the testbench would have spent more
time on its own sampler than on the DUT."*

**Measured, that is false by a factor of 125.** The comparison was built and
timed rather than left as arithmetic: the same testbench plus a free-running
1/8-bit strobe across the whole frame fires **45,753** strobes, not 5,700,000,
and runs in **27 s against 28 s** — no measurable difference at all. The 5.7 M
came from scaling 22.8 ms by a nanosecond-scale interval instead of by half a
cell; 22.8 ms / 0.5 µs is 45,600, and that is the whole number.

So the lean design **does not pay for itself in simulation time.** It is kept for
the two reasons that survive measurement:

1. **Less state.** A background process that must be serviced correctly for
   22.8 ms is a second thing that can be wrong. This design has none.
2. **Every sample point is computed from the slot's own start edge**, so the
   receiver never has to reason about a grid that has to be re-anchored across a
   quarter of a second of wire.

The generalisable part is the point: **a design justified by a performance claim
that nobody timed is a design waiting to be believed.** This one sat in a
testbench comment *and* in this file for a full commit — through the mutation
gate, through two full green suites, and through my own review — before anything
measured it. It is the same shape as every other defect in this file: an
assertion, repeated confidently, that nothing ever checked. The mutation gate
checks the *firmware*; nothing in the suite checks the *testbench's own claims
about itself*.

## Non-vacuity, run both ways — and a floor is not a fingerprint

Driven by `firmware/dmx512.hex`, `tb_pe_soc_dmx512.v` passes. Driven by
`firmware/midi_xfer.hex` — a real 8N1 stream at 31.25 kbaud on the same pin — it
fails, which is the same demonstration the MIDI TB gets from `spi_xfer.hex`.

The detail is worth more than the pass/fail: **the break and mark checks PASS on
the wrong protocol.** A 31.25 kbaud frame's long low run measures **159.99 µs**
and its idle high **32.00 µs**, which clears the 87.5 µs break floor and the
8 µs mark floor without meaning it. What actually rejects the wrong stream is
the **stop-bit verification** and the **per-slot comparison**.

A floor says "not shorter than", and a wrong protocol is not shorter. That is a
real limitation of the two floor checks and it is worth knowing before anyone
relies on them: they are necessary, not sufficient, and only the structural
checks (the two stop bits, the slot values, the count) distinguish *this*
protocol from a slower one.

The `$dumpvars` is the TB scope only, and this one **is** a measured call rather
than arithmetic: a full-hierarchy dump over 1.37 M clocks is a file of hundreds
of megabytes that the regression would write on every run, for a waveform whose
only moving part is a 4 µs square wave the assertions already measure on the pin.

## Self-inflicted testbench defects, recorded so they are not repeated

There were four more, recorded because the first one is the most expensive
mistake of the whole block and the other three are the ordinary way a testbench
lies to you.

0. **A merge resolver that kept only the conflict hunks.** Resolving
   `run_all.sh` against `main` with a script that appended a line *only* when
   the state was `ours` silently dropped all 233 lines outside the hunks — the
   whole file header, the run lock, the options parsing, and the three BLOCK 1+2
   testbench entries — leaving a 3-line file. The check that caught it was
   counting the entries expected in the list being unioned (5 protocol TBs
   before, 2 after) and not reading the file. **A merge resolution is a build
   step and gets the same verify-don't-trust treatment as any other.**
1. **A drain cap that is not derived from the rate.** The first version allowed
   900 µs for 14 bytes × 320 µs = 4480 µs of stream — five times too little — so
   the run stopped after two and a half messages and every check failed on a
   truncated stream that looked exactly like a protocol defect. **Any cap in a
   receiver must be computed from the rate.**
2. **A task that both positioned and sampled**, so each iteration decoded two
   frames and the output was the odd bytes of a stream read at double rate. One
   job per task.
3. **`$readmemh` images and probe assumptions.** A probe assumed pin 0 resets
   LOW; it resets **HIGH** (the UART idle level), so a measurement came out as
   the time since reset. **Record every edge, and re-check the reset level of any
   pin used as a probe.** A second probe counted clocks in an `integer` that was
   never initialised, so every timestamp in the file was `x` and `x + 1` is `x`.
4. **Sampling on the timeline you are measuring.** The first DMX version found
   the start bit's fall, waited for the cell-9 rise in order to measure the cell,
   and only then decoded the slot — by which time the simulation clock was nine
   cells past the slot it was about to sample, every sample landed in the past,
   took no delay, and read whatever the line was doing. It decoded the start code
   as `0xff`: eight ones, from eight samples taken at one instant. Sample on the
   nominal grid and refine afterwards.
5. **Reading the DUT before it has run.** The last DMX check read `dmem` half a
   cell before the frame layer had executed and reported `slots_low=0, pages=x,
   finished=00` for a frame that had just gone out complete.
6. Icarus rejects an unpacked array `localparam` outright ("unpacked array
   parameters are not supported yet"). Use packed vectors, and remember a
   concatenation is MSB-first, so the **last** literal is index 0.
7. `$dumpvars(0, top, "exclusions...")` makes Icarus emit `cannot dump a
   vpiConstant` for every localparam in the excluded scopes. Exclude nothing;
   narrow the scope instead.

---

## What is committed, and what is deliberately not

| Path | State |
| --- | --- |
| `firmware/midi_xfer.pe` / `.hex` | **committed** — 123 words, 31,250 baud measured on the pin |
| `firmware/dmx512.pe` / `.hex` | **committed** — 126 words, 250,000 baud measured on the pin |
| `tb/tb_pe_soc_midi.v` | **committed** — oversampling receiver, stop bit verified |
| `tb/tb_pe_soc_dmx512.v` | **committed** — lean receiver, 513 slots, both stops verified |
| `regress/mutate_fwbus_tb.sh` | **committed** — 21 mutations, 21 detected, 0 survived |
| `regress/run_all.sh`, `regress/run_firmware_tests.sh` | **committed** — same-list wiring: 2 TBs, 2 firmwares |
| `main` merged beneath the branch | **committed** as `2adc845`, so landing is a fast-forward; the merge resolution was verified by counting entries, after it destroyed `run_all.sh` once — see the self-inflicted defects above |
| `regress/dev_tb.sh` | **NOT committed** — dev-only helper; a second way to run a TB is one more thing that can drift from the first |

## The mutation gate, and the two mutations the block exists for

`regress/mutate_fwbus_tb.sh` now mutation-tests **five** firmware DUTs — 21
mutations, **21 detected, 0 survived, 0 harness errors**, tree byte-clean after
the run. Nine are new. The two that matter most:

- **`midi-cell-count-minus-one`** — `146 → 145` iterations. The cell becomes
  1907 clocks, 0.68 % fast. A receiver resynchronises on the next start bit and
  never notices, which is precisely why it survives review.
- **`dmx-cell-count-minus-one`** — `109 → 108`. 238 clocks, 0.83 % slow.

Both are **the defect class both acts exist to prevent**, and both are caught only
because the rate window is narrower than the delay loop's own quantisation.

The third new mutation is the instructive one: **`midi-cell-padding-nop`**. One
extra NOP in `sb_start` is 0.05 %, which the rate window cannot see, and it is
caught by the *every cell measures the same* assertion. A mutation that a
tolerance cannot see is exactly the kind that produces a green tick for a claim
nothing checks.

Also new: the stop bit driven low (both acts), the shift removed (replaced by a
NOP so the cell length is unchanged and the mutation tests the payload alone),
running status negated, DMX's break one cell short, and the DMX ramp stepping by
two.

The gate now costs **3 m 46 s**, almost all of it the four DMX cases at ~27 s
each. That is the price of proving a protocol whose frame is a quarter of a
second long, and it is paid knowingly rather than discovered as a mysteriously
slow suite.

---

## The one durable lesson

> **A delay built by counting instructions is arithmetic, and arithmetic that is
> only ever compared with itself has never been tested.**

Both `pe_soc` timer idioms return `(N−1, N]`, not `N` — the read lands at a
random phase inside the counter's 260-clock window, so a 3-tick wait is anywhere
in (520, 780] clocks. Both new programs therefore use the timer **zero times**
and count instructions instead. And then, on the very next line, the
instruction count was wrong: a cell is a bit and not a half-bit, a shift in a
common tail is a shift on all ten cells, a dispatch is partly executed on some
paths and not others, and a page counter compared against 2 counts pages.

Every one of those was found by measuring the pin, and **not one of them would
have been found by a testbench that compared the firmware's own arithmetic with
the firmware's own arithmetic.** That closes the follow-up recorded in
`wiki/plans/through-i2c.md` ("removing it needs a sub-tick delay, roughly 130
clocks of counted NOPs") — 1898 clocks of them, for MIDI, and 219 for DMX.

The consequence worth carrying to the next bit-banged protocol: **build the
delay, then measure it on the pin, then assert the measurement is inside a window
narrower than the delay's own quantisation step** — otherwise the assertion
cannot see the one change that matters, and the suite will be green and wrong.

---

## Limits

**This section existed before this file was rewritten and was dropped in the
rewrite.** It is restored here, and the fact that it went missing for one
commit is itself the argument for having it: the file that lost it is the same
file that spent a section insisting that a rate assertion only counts if
something can see it, and an audit that checked the parts it had *added* and not
the part it had *removed* would not have caught that either. Restore a boundary
statement even when the rewrite feels like a pure improvement — especially then.

**Simulated evidence only.** No synthesis, no STA, no timing closure, no
physical flow, no DRC, no LVS, no hardware. The full regression passing
(`EXIT=0`, 39/39 testbenches, 35/35 firmwares, 21/21 mutations detected) means
the programs behave as specified **in 4-state simulation on the modelled CPU,
pin matrix, SRAM and pads**. It is not sign-off, and nothing here should be
quoted as such.

**No RTL changed in BLOCK 3**, which is the thesis being demonstrated rather than
a caveat: both acts are programs on the same CPU, pin matrix and 260-clock tick
that `firmware/i2c_xfer.pe` and `firmware/spi_xfer.pe` already use. That is also
precisely why no synthesis or STA screen was run — there is nothing new for it
to say — and why these results say nothing about whether a *hardware* UART or
DMX driver would meet its timing. What they demonstrate is the thesis of the
block: **the pin matrix and the tick are sufficient**, and a protocol whose rate
the tick cannot express is reachable in software, measured.

**Two things a hardware bring-up would still have to check**, and simulation
cannot: the real 60 MHz clock's tolerance across temperature (every figure here
assumes a perfect clock, which is why the transmitter is a pure divider and why
the cell measures to 0.0000 µs of spread — a real crystal will not), and the
pad's actual rise/fall behaviour against a 4 µs DMX bit cell.

**BLOCK 3 is not landed on `main`.** It is on `fw-bus-protocols` as `e630d74`,
with `main` merged in beneath it as `2adc845` so that landing is a clean
fast-forward. Merging it is the manager's call; see the open QUESTION in the
WORKLOG. The merge-readiness run that established this is on the merged tree,
not on the pre-merge one.
