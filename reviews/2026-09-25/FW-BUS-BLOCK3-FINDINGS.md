# BLOCK 3 — UART rate flexibility: findings and handoff (2026-09-25)

Worker `fw-bus`, branch `fw-bus-protocols`. BLOCK 2 landed as `02c9101` +
`a4a9772`. **BLOCK 3 is partial and is NOT committed** — see
[WIP inventory](#wip-inventory-deliberately-uncommitted) and
[Why this stopped where it did](#why-this-stopped-where-it-did).

The point of this file is that the measurements below cost a full working
session to obtain, and none of them are recoverable from the code alone. The
next session should not have to re-derive any of them.

---

## Measured results, one line

> firmware/midi_xfer.pe (109 words) assembles and runs, and its own record is
> `dmem bytes=14, status_bytes=2, finished=0xA5` — six two-data-byte MIDI
> messages over fourteen wire bytes with two status bytes, which *is* the
> running-status saving (18 bytes without it); a raw edge trace of the TX pin
> measured every half-bit at 16.283–16.433 µs, i.e. **30,420–30,704 baud
> against a nominal 31,250, −1.8% to −2.7%**, inside the 3% the act needs — so
> **the transmitter is right and the testbench's receiver is the defect**.

---

## Finding 1 — the target-wait idiom gives (N−1, N] ticks, not N

`pe_soc`'s target idiom — read the counter, add N, poll until it equals the
target — **does not give N ticks**. The read lands at a random phase within
the counter's 260-clock window, so a 3-tick wait completes anywhere in
**(520, 780] clocks**, a 260-clock spread.

`firmware/uart_echo.pe` records exactly this for the 1-tick case:

> "a wait that snapshots the count and loops until it changes therefore returns
> after anywhere in (0, 1] ticks"

Nobody had written down that it **scales**. The consequence:

| rate | cell | (N−1,N] spread as a fraction | usable? |
| --- | --- | --- |---|
| 115200 8N1 | 8.67 µs | 1.2% of a bit | yes — the receiver re-synchronises on every start bit |
| 31250 8N1 | 32 µs | 27% of a **half-bit** | **no** — the grid walks out of its cell within eight bits |

**Therefore both BLOCK 3 acts are timed from counted instructions alone and use
the timer zero times.** The measured symptom before the fix: the half-bit came
out at 17.7 µs instead of 16.03, the testbench's sampling grid drifted 3.4 µs
per bit, and the payload decoded correctly for the first two bytes (`0x20`,
`0x40`) and wrong from the third (`0x21` → `0x10`). A UART cannot repair a
transmitter that jitters; only a deterministic delay can.

This closes the follow-up recorded in `wiki/plans/through-i2c.md`
("removing it needs a sub-tick delay, roughly 130 clocks of counted NOPs").

## Finding 2 — the factorisation is the trick, and 8-bit counters truncate silently

The MIDI half-bit is 960 clocks. The delay shape is two NOPs, an `LDI A, N`,
then N iterations of a body:

```text
cost = 2 + 1 + N x (body) + 2 OUT register latencies
```

`960 − 3 = 957`, and `957 = 3 x 319 = 9 x 106.33 = 33 x 29 = 11 x 87`. The
**only** split with both factors inside an 8-bit counter is **11 × 87** (a body
of nine NOPs plus `SUB` and `JNZ`, 87 iterations).

A 319-iteration loop **assembles, runs, and silently truncates to 63
iterations** — a 192-clock delay, i.e. 156 kbaud. This is not hypothetical: the
first probe written for this act did precisely that and reported a
"measurement" that was silently the time since reset. The next session must
keep every delay-loop counter ≤ 255.

Measured on the real CPU: **961.92 clocks = 16.032 µs = 31,188 baud**, −0.2%.

## Finding 3 — a counted-NOP delay is 3N + 5 clocks *pin to pin*, not 3N

The `+5` is the `LDI` plus two `OUT` register latencies. Omitting it is a
**2-clocks-per-cell** error: 0.13% on the rate, small enough to decode
successfully, which is exactly why it survives review. The same figure applies
to the DMX case below, where it is the difference between 118 and 120 clocks.

`1 instruction = 1 clock` is now **measured, not assumed**: differencing two
loop lengths on the real CPU gives `NOP/SUB+JNZ` = **3.000 clocks** per
iteration.

## Finding 4 — DMX 250 kbaud is exact with no timer at all

A 2 µs half-bit is **shorter than one 260-clock tick**, so at 250 kbaud the
timer cannot be used even once. And the delay can be made exact:

```text
2 + 1 + 23 x 5 + 2 = 120 clocks = 2.0000 us = 250,000 baud   (measured exactly)
```

The two acts bracket the problem nicely: **MIDI is the rate a fractional tick
cannot express; DMX is the rate a tick cannot express at all.**

---

## WIP inventory (deliberately uncommitted)

These three files exist in `/tmp/worktrees/fw-bus` and are **intentionally not
committed**, so that a `git add -A` in the worktree cannot land a **red**
testbench. The committed branch is green.

| File | State |
| --- | --- |
| `firmware/midi_xfer.pe` | **complete and working** — 109 words, assembles, message layer proven by its own record |
| `firmware/midi_xfer.hex` | current build of the above |
| `tb/tb_pe_soc_midi.v` | **RED** — the receiver cannot frame the stream (four failed versions, diagnosed below) |
| `regress/dev_tb.sh` | dev-only helper, unquoted `$SOC` is intentional word-splitting; not part of the regression |

Reproduce with:

```bash
cd /tmp/worktrees/fw-bus
python3 tools/fw/peasm.py firmware/midi_xfer.pe -o firmware/midi_xfer.hex
./regress/dev_tb.sh tb_pe_soc_midi tb_pe_soc_midi
```

## Why this stopped where it did

The transmitter is proven; the testbench is not. Committing a testbench nobody
has seen pass is worse than not having one — it manufactures a green tick for
a claim nothing checks. A `PASS` line in `run_all.sh` that has never been
observed is exactly the failure mode this project's own house rules exist to
prevent, and the BLOCK 2 mutation gate had just caught two of mine for the same
reason (a vacuous SCLK check, and a mutation that was not a defect at all).

## The MIDI receiver: four failed versions and the actual lesson

`tb_pe_soc_midi.v` is red for **one** reason, and it is a receiver problem
rather than a firmware one.

**The lesson: in a back-to-back 8N1 stream a falling edge is not a start bit
and a rising edge is not a stop bit.** A data bit going 1→0 falls exactly like
a start bit, and a data bit going 0→1 rises exactly like the stop bit. Every
edge-based scheme therefore fails:

| version | what it tried | how it failed |
| --- | --- | --- |
| 1 | `@(negedge tx_pin)` starts a decode | data transitions start decodes mid-frame; returned `0xa8` where `0x90` went out |
| 2 | a `decoding` flag blocking 9.5 bit periods | consumed the real start bit whenever a data edge woke it early; missed ~2 frames in 3 |
| 3 | require ≥1.5 bit periods of HIGH before a fall | for the data pattern 1,1,0 the preceding high run is two whole bits, which is indistinguishable from a stop bit |
| 4 | anchor on the stop bit, measured | **the rate check now differences consecutive POSEDGES, and data-bit rises are counted** — `t_stop_rise` is not the stop bit, so the frame period came out 5× short and 12 of 14 stop bits read low |

**The fix the next session should build: a free-running oversampling
receiver** (a sampler every quarter-bit, on its own timeline, never blocking),
which searches for a high→low transition, samples eight bits at the mid-points
**verifying the stop bit is high before accepting the frame**, and returns to
the search immediately on a framing error. The verification is what makes it
safe: a data transition produces a candidate whose stop bit reads low, and is
discarded without consuming the timeline. Two further requirements:

- sample at the **measured** bit period (from two consecutive verified stop-bit
  edges), not the nominal 32 µs — the transmitter runs 1.85% fast, and a
  nominal grid accumulates 0.18 of a bit per frame;
- re-anchor on the **verified** stop edge every frame, so the rate error never
  accumulates.

## Self-inflicted testbench defects recorded so they are not repeated

Three of these cost more time than the firmware did, and all three produced
failures that *looked* like protocol defects:

1. **A drain cap that was not derived from the rate.** The first version allowed
   900 µs for 14 bytes × 320 µs = 4480 µs of stream — five times too little — so
   the run stopped after two and a half messages and every check failed on a
   truncated stream. **Any cap in a receiver must be computed from the rate.**
2. **A task that both positioned and sampled.** `frame_from_stop` sampled and
   its caller sampled too, so each iteration decoded two frames and the output
   was the odd bytes of a stream read at double rate. One job per task.
3. **`$readmemh` images and probe assumptions.** The very first timing probe
   assumed pin 0 resets LOW; it resets **HIGH** (the UART idle level), so the
   `LDI A, 1` produced no edge and the "measurement" was the time since reset —
   a constant 1808 clocks for three different loop lengths. **Record every edge
   rather than the first and last**, and re-check the reset level of any pin
   used as a probe.

Also: Icarus rejects an unpacked array `localparam` outright
("unpacked array parameters are not supported yet") — the same wall
`tb_pe_soc_spi.v` documented. Use packed vectors and remember a concatenation
is MSB-first, so the **last** literal is index 0.

## Next session's checklist

1. Rewrite `tb_pe_soc_midi.v`'s receiver as the oversampling search above. The
   firmware does not need to change; verify with the existing transcript
   (`wire byte 1..14`, `running status now ..`, `dmem: bytes=14 status_bytes=2
   finished=a5`).
2. RED-first, as always: point the finished TB at `firmware/spi_xfer.hex` (or
   any 115200 firmware) and record the failures before repairing it.
3. Act 5: `firmware/dmx512.pe` + `tb/tb_pe_soc_dmx512.v`. **The frame is 22.6 ms
   of simulated time** (513 slots × 11 bits × 4 µs), so the TB must be lean —
   no per-clock `$sformatf`, sample on TX edges, and expect a long run. The
   transmitter is timed at exactly 120 clocks per half-bit (Finding 4); the
   frame is break (≥ 87.5 µs) + mark (≥ 8 µs) + start code + 512 slots, and the
   512 slot values are a wrapping 8-bit ramp, which is the natural thing for an
   8-bit slot counter to generate and for the TB to recompute.
4. Extend `regress/mutate_fwbus_tb.sh` with mutations for both new programs —
   including at least one that changes the counted delay constant, since that is
   the defect class both acts exist to prevent and the mutation gate is the only
   thing that will prove the rate check is not vacuous.
5. Same-list wiring: 2 TBs into `regress/run_all.sh`, 2 firmwares into
   `regress/run_firmware_tests.sh`, then the full regression and a commit.

## Limits

Simulated and mapped evidence only. No synthesis or STA screen was run for
BLOCK 3, because no RTL changed — the acts are programs on the same CPU, pin
matrix and tick that `firmware/i2c_xfer.pe` and `firmware/spi_xfer.pe` already
use, which is the thesis being demonstrated. No physical flow, DRC or LVS.
