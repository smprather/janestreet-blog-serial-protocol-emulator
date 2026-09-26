# Demo walkthrough — Protocol Emulator: one FPGA, a laptop, four protocols

This is the judge-facing script for demonstrating the entry. It covers what the
chip does, how the host controller drives it, what is *proven* versus
*simulated* versus *pending hardware*, and how to demo without a board.

Every claim below is backed by a checked-in artifact (a testbench, a
regression log, or a host test). Where something is not proven yet, it says
so — a judge should be able to tell the difference at a glance.

## The one-sentence pitch

A single synthesizable microcontroller-grade core, running protocol logic as
*firmware* instead of gates, exposes UART, SPI, I2C and 10BASE-T over its pin
matrix; a local browser UI on a laptop loads programs into it and observes it
over a USB-attached dev board, and the whole thing is verified by a
regression that runs in about a minute.

## 60-second architecture view

```
  ┌──────────── laptop (Linux) ────────────┐   USB CDC   ┌──── dev board ────┐   SPI   ┌──── shuttle ────┐
  │  browser UI  ← WebSocket →  host stack  │  newline    │  Pico/RP2040     │ mode-0  │  protocol       │
  │  (tools/host_gui)   transport/session  │  JSON       │  bridge           │ host    │  emulator SoC   │
  │                    ↕ PE frame codec    │  ─────────► │  (tools/host_     │ SPI ───► │  pe_cpu + SRAM  │
  │  transport ────────────────────────────┘             │   bridge)        │         │  + pin matrix   │
  └──────────────────────────────────────────────────────┤  uio[4:7]        │         │  + 10BASE-T     │
                                                         └──────────────────┘         └─────────────────┘
```

The design bet is in the middle box: protocols are *programs* the CPU runs, so
a protocol persona is a `.pe` file, not a Verilog block. The cost of that bet
(a slower bit-banged core) is paid deliberately: 260 clocks per half UART bit
at 60 MHz gives 115,385 baud against a nominal 115,200 (+0.16 %), which every
frame in the demos is checked against.

## The four protocol acts (each is a real artifact)

1. **UART — 115200 8N1 echo.** `firmware/uart_echo.pe` (118 words) echoes
   bytes on the pin matrix. Proven on RTL by `tb_pe_soc_uart`, which drives a
   real waveform in and decodes the real waveform out, passing on `41/42/00/FF`
   with a measured 8.6–8.7 µs bit cell. On the emulator it is
   `python3 tools/fw/peemu.py firmware/uart_echo.hex --send "41 42"`.
2. **SPI — mode-0 master.** `firmware/spi_xfer.pe` is a mode-0 master against
   a slave model; the same mode-0 engine also carries the host load path.
3. **I2C — a real transaction.** `firmware/i2c_xfer.pe` (311 words) does
   START, address+write, ACK, data, repeated START, address+read, NACK, STOP.
   Proven against an independent Verilog slave FSM *and* across all 60 clock
   phases; the golden tests caught arbitration loss, a missed NACK, and missing
   SCL stretch handling — all three now fixed and covered.
4. **10BASE-T Ethernet — both directions.** A receive MAC that
   validates the FCS, guards committed bytes and streams frames into a
   firmware-visible window (`eth_rx.pe`), plus a transmit path that emits
   real Manchester cells onto the pad and decodes them back at the pad
   (`tb_pe_eth_tx`: an ARP reply is stored as 60 bytes and re-decoded from 576
   wire bits). Firmware programs drive both (`eth_arp_echo`, `eth_tx_two`, a
   wrap probe and a busy probe).

**Deep reading** — [`wiki/concepts/overview.md`](../wiki/concepts/overview.md) is the index. Per act: [UART RTS/CTS](../wiki/concepts/protocol-uart-flow.md) · [SPI mode 3 + per-word CRC](../wiki/concepts/protocol-spi3-crc.md) · [I2C read burst + clock stretching](../wiki/concepts/protocol-i2c-adv.md), plus the baseline pages [SPI as firmware](../wiki/concepts/spi-as-firmware.md) · [I2C on the matrix](../wiki/concepts/i2c-on-the-matrix.md) · [Ethernet receive path](../wiki/concepts/ethernet-receive-path.md). Figures: [uart-flow](../diagrams/proto-uart-flow.png) · [spi3-crc](../diagrams/proto-spi3-crc.png) · [i2c-adv](../diagrams/proto-i2c-adv.png)

## The debug act — arm a breakpoint, hit it, step across it, resume (R3)

The four acts above are firmware personas. This one is the thing you cannot do
with `peemu.py`: **the chip is stopped by a host command, on a real instruction
boundary.** It is the act that turns "the host can read the chip" into "the
host can debug the chip", and it runs entirely over the same framed bus as the
load — no side channel, no simulation-only hook.

Run it yourself, no board needed:

```
python3 tools/host_bridge/acceptance.py --fake   # the 7 r3_demo_* beats
```

1. **Arm.** `DEBUG_BP_SET(2)` over the host bus. The response's five-word
   prefix reads back the address it just armed and `bp_flags=0x01`.
2. **Run, and hit.** Raise the `run` strap. The core advances until its
   *landing* address equals the armed one, and stops there. The demo clocks
   the model to that point because `FakePE` does not self-advance; a real core
   gets there on its own.
3. **The hit is a distinct state, not "stopped".** `DEBUG_STATUS` reports
   `state=3` (**BP_HIT**), `pc=2`, `bp_flags=0x03` (bit0 armed + bit1 hit) —
   and `run=1`. That last one is the point: **the hit holds the core, it does
   not drop the run strap.** A plain stop is `state=0`; a single-step pause is
   `state=2`. All four are in one 2-bit word, and R2's own `STATUS` reports the
   same encoding, so old host code keeps its meaning.
4. **Inspect.** `READ_CPU` gives `pc/a/x/y/insn` — with `insn` the word *at*
   the held PC, which is exactly the instruction you are about to single-step.
   `DEBUG_STATUS` adds the breakpoint address and flags on top. (Its last word
   is the **run strap**, not the debug state: a detail this repo's own vectors
   initially got wrong and the chip's conformance run caught.)
5. **Step across it — and both halves matter.** One `DEBUG_STEP` retires
   **exactly one instruction**, so `a` visibly changes and the PC advances to 3.
   Stop-before is about the instruction *at* the breakpoint, which had **not**
   run — which is what lets a debugger inspect that instruction and then step
   *it*. Stepping off the breakpoint clears the hit.
6. **Clear.** `DEBUG_BP_CLR` is the **only** release, and it also disarms: with
   the strap high the core resumes; with the strap low it falls to the boot
   stop and the PC re-zeroes. So a core can never be stranded on a hold.
7. **Resume with the breakpoint still wanted.** Step off → clear → re-arm. The
   GUI offers this as one action precisely because the naive "clear to get
   going" silently drops your breakpoint.

**One operational trap, worth knowing before you demo it.** Once the core is
stopped on a breakpoint it is in a *debug hold*, and while held the run strap is
ignored in **both** directions — pulling it low will not restart the chip, and
neither will STOP. The only release is `DEBUG_BP_CLR` (which also disarms); a
hardware reset is the other escape. So if the GUI dies mid-debug you come back
to a chip that looks powered and configured but will not run until you clear the
breakpoint. The acceptance demo's own `r3_demo_6_clear_releases` beat depends on
this release.

Two honest caveats, both on the acceptance output itself: a free-running core
cannot be stepped at all (the chip answers `NOT_READY` with no fault), and a
breakpoint is **one PC address** — there is no watchpoint and no data
breakpoint in R3.

## The three timing acts — where the waveform IS the specification

The four protocols above all have something to decode: a start bit, a clock edge, an
ACK. Get a bit slightly wrong and the peer resynchronises. The three acts below
are the opposite, and they are why this project can claim *cycle* accuracy
rather than merely "works on the bench": **there is no clock on the wire, the
value is a pulse width, and a firmware that is one clock out is wrong.**

They are also the cheapest thing to demonstrate live, because each is a `.pe`
file and a testbench, and each testbench prints its measurements.

**5. WS2812 — 800 kHz one-wire, GRB, 24 bits, cycle-exact.**
`firmware/ws2812.pe` (129 words) drives a strip on pin 6. 1.25 µs per cell is
**exactly 75 clocks** at 60 MHz, with no remainder, and the bit cell is
straight-line code — so the period is the *length of the program*, not a count
calibrated against a tick. `tb_pe_soc_ws2812` measures on the pads: every 1-cell
high for **exactly 48 clocks (800.0 ns, the datasheet's nominal tHIGH1)**, every
0-cell for exactly 0, the 24 cells spanning exactly 24 × 75 clocks, and every
1-cell's rising edge on the 75-cycle grid. It runs the strip twice, so the >50 µs
reset *between* frames is measured too (62.3 µs measured).

> The grid check is the one that earns the word "cycle-accurate". A cell that was
> 74 or 76 clocks still clears every datasheet window in the world — it is still
> 1.23 µs — and a decoder that resynchronises on every rising edge would never
> notice. The mutation suite includes exactly that mutant, and the TB catches it.

**6. Servo PWM — 50 Hz, 1–2 ms, five positions.**
`firmware/servo_sweep.pe` (84 words) sweeps 1000, 1500, 1750, 1250 and 2000 µs.
Each position carries **its own gap, chosen as 20 ms − its own pulse**, so the
frame is a *slot* and the rise-to-rise is 20 ms whatever the pulse is. Measured:
**19 999.95 µs = 50.000 Hz**, and the five widths land within 0.15 µs of nominal.
The order is deliberately not monotonic, so a firmware that emitted the right
widths in the wrong order fails.

> The two full 20 ms slots are what the 50 Hz claim rests on; the last three
> positions use a 2.5 ms gap. That trade is stated in the firmware header and the
> TB prints the short gaps rather than hiding them.

**7. DHT11 — a start signal and a 40-bit timed read.**
`firmware/dht11_read.pe` (134 words) drives the 18 ms start signal, the 30 µs
host-high window, then releases the line and **reads 40 bits whose value is a
pulse width** (26–28 µs high = 0, 70 µs = 1). `tb_pe_soc_dht11` models a sensor
driven at the **worst case of each window** and checks the sample margin on both
sides: **17.0 µs past the longest 0-release, 25.0 µs before the 1-release ends**.

> The host **synchronises on the data line's edges** rather than counting
> milliseconds per bit, because the sensor's 0-bit is 76–78 µs long and a
> fixed-wait host drifts 40 µs over twenty zero bits — three times the margin.
> That is the single most useful thing this act demonstrates, and it is a
> firmware property, not a hardware one.

**Deep reading** — [WS2812](../wiki/concepts/protocol-ws2812.md) · [servo PWM](../wiki/concepts/protocol-servo.md) · [DHT11](../wiki/concepts/protocol-dht11.md) — each page carries the measured pulse widths and the tolerances they have to clear. Figures: [ws2812](../diagrams/proto-ws2812.png) · [ws2812-timing](../diagrams/proto-ws2812-timing.png) · [servo](../diagrams/proto-servo.png) · [servo-timing](../diagrams/proto-servo-timing.png) · [dht11](../diagrams/proto-dht11.png) · [dht11-timing](../diagrams/proto-dht11-timing.png)

### What the three acts cost, and what they prove about the claim

| | WS2812 | Servo | DHT11 |
|---|---|---|---|
| firmware | 129 words | 84 words | 134 words |
| simulated time | 65 µs | **52.5 ms** | **22 ms** |
| regression time | 0.4 s | **66 s** | 29 s |
| the number that is the claim | 48 clocks, exactly | 20 ms, ±0.005 µs | 17/25 µs of margin |
| mutants caught | 5/5 | 4/4 | 5/5 |

`regress/mutate_timing_tb.sh` runs those 14 firmware mutants in parallel on
private copies and then verifies the tree was never written to. It exists because
the DUT of these three is partly a *program*: nothing in `rtl/` can notice that a
cell is one clock short.

**The honest cost:** the servo and DHT11 testbenches simulate milliseconds, so
the full regression's wall time goes from about a minute to about three. The
frame rate is measured on two slots rather than five, and the three TBs dump a
narrow set of signals instead of everything, for exactly that reason. The
alternative — a fast regression that does not measure milliseconds — cannot make
the claim at all.

## Three more, where the chip READS the world

The six acts above all *drive* something. These three are the other direction:
the pin is an input, the thing being measured belongs to somebody else, and the
firmware has to recover a number from a waveform it does not control. The claim
is the same cycle-accuracy claim and the same evidence — measured on the pads,
reconstructed by a model that was written from the datasheet rather than from
the firmware, and mutation-tested so that a "close enough" program cannot pass.

**8. DS18B20 — 1-Wire, and the only act where the DEVICE initiates.**
`firmware/ds18b20.pe` (205 words) drives a DS18B20 on pin 6. After the host's
reset pulse **the sensor answers** with a presence pulse, and every read slot is
timed by the sensor rather than by the host, so the firmware's edge-wait loops
and the pin matrix's read-back are both load-bearing here in a way they are not
in the DHT11. Measured on the pads by `tb_pe_soc_ds18b20`: reset **485.7 µs**
(minimum 480), presence **120.0 µs** (datasheet 60–240), a write-1's low pulse
**5.0 µs** and a write-0's **64.8 µs** (bands 1–15 and 60–120), the two commands
**decoded from the pads as `cc` and `be`** rather than read out of the firmware,
**16 read slots**, the temperature bytes back as **`2b 01`** LSB first, read-slot
initiation pulses **6.2–6.3 µs**, and the sample instant **10.8 µs after the
sensor's latest permitted response and 19.2 µs before its hold ends**.

> The single most useful thing this act shows is that **a read slot and a write
> slot have opposite polarity**: a one is the line LOW, because the *slave* is
> holding it down, whereas in a write slot the line being low is the *host's*
> zero. The firmware had the write slot's polarity, and both bytes came back
> bit-for-bit complemented — `2b` as `d4`, `01` as `fe` — with the right bit
> count, the right number of ones, and nothing at all wrong-looking in the run.

**9. NEC infrared remote — the one act with no wire at all.**
`firmware/nec_ir.pe` (165 words) drives an IR LED on pin 6. Nothing is connected
to anything: the only thing that leaves the pin is light, so a NEC receiver has
to *find* a 38 kHz burst, integrate it, and time the silences between bursts to
learn that a gap of 1.6875 ms is a zero and a gap of 0.5625 ms is a one. Nothing
resynchronises to anything, which is what makes the carrier the claim:
`tb_pe_soc_ir_nec` measures **38,049 Hz off the pin (+0.128 % on 38.000 kHz)**,
the two half periods **787.95–794.95** and **788.95 clocks**, a **8988.0 µs**
leader in 343 carrier cycles, a **4504.0 µs** leader gap, eight data bursts of
**552.0 µs**, four long gaps and four short ones, a stop burst, and the payload
decoded **LSB first as `a5`**.

> The mutation suite found this act's own blind spot, and it is the most useful
> result in the block: putting **both** carrier half-periods on the same delay
> pair gives a carrier of 788 clocks one way and 782 the other. That is 38.05 kHz
> against 37.88 — **0.4 % asymmetric on every single edge** — and it sits inside
> every frequency window a real receiver has, so it **passed**. "Each half is
> constant" is not "the two halves are equal": a receiver does not care that the
> carrier is on frequency, it cares that it is a *carrier*, and one whose halves
> differ is a square wave with the wrong duty cycle.

**10. Stepper step/dir ramp — a mechanism, not a wire.**
`firmware/stepper_ramp.pe` (96 words) drives STEP on pin 6 and DIR on pin 5. A
stepper driver counts STEP edges and the motor's position *is* that count, so
there is no acknowledgement, no status word, and nothing at the far end to
resynchronise to: a step period is a single number and it is either right or the
motor is somewhere it will never report being. Twelve steps — six one way, the
direction changes, six back — with the period falling by **exactly 5110 clocks
(85.2 µs) every step**. `tb_pe_soc_stepper_ramp` measures **1661.133 µs falling
to 809.501 µs (602 Hz → 1235 Hz)**, twelve distinct periods, all eleven intervals
strictly shortening, and the direction changed **once**, **6.00 µs** before the
next STEP edge so the driver is given its setup time.

> The ramp is a **subtraction**, not a table of twelve constants: the program
> holds one counter and subtracts 10 from it per step, so the linearity is *in
> the program* and the testbench can check it as an **equality against 5110
> clocks** rather than a window. The one interval that is not on the line — the
> direction change, the only thing in the program that is not a step — is pinned
> by a **sum** with its neighbour rather than excused. And this act found a trap
> worth putting in the findings list: **`PINOE` and `TXPIN` are whole
> registers**, so a write meaning "this pin" is a write that also means "the
> other pin". The direction was cleared by the first step, then released during
> every pulse, then released *at exactly the STEP edge where a driver decodes
> it* — four writes, one cause, and the direction never once changed on the wire.

**Deep reading** — [DS18B20](../wiki/concepts/protocol-ds18b20.md) and [DHT11](../wiki/concepts/protocol-dht11.md) — the pages give the reset/presence timings each device demands and the margin this firmware leaves. Figures: [ds18b20](../diagrams/proto-ds18b20.png) · [ds18b20-frame](../diagrams/proto-ds18b20-frame.png) · [ds18b20-timing](../diagrams/proto-ds18b20-timing.png)

### What the three input acts cost, and what they add

| | DS18B20 | NEC IR | Stepper |
|---|---|---|---|
| firmware | 205 words | 165 words | 96 words |
| simulated time | 3.0 ms | **32.1 ms** | 14.4 ms |
| regression time | 3.6 s | **42.7 s** | 20.7 s |
| the number that is the claim | 10.8 / 19.2 µs of margin | **38,049 Hz, +0.128 %** | **exactly 5110 clocks per step** |
| mutants caught | 12/12 | 11/11 | 11/11 |

`regress/mutate_timing_tb.sh` now runs **48 firmware mutants** in parallel on
private copies and verifies afterwards that the firmware tree was never written
to. Five of them perturb a **counted delay constant** through `peasm --const`
rather than a text edit, because the 1-Wire and infrared programs name their
delays as symbols — the value is a *fitted instruction count* living in the
assembler's table, and a harness that could only `sed` a source file would
silently cover no counted delay at all.

**The honest cost:** these are the two slowest testbenches in the repository
(52.5 ms for the servo, 32.1 ms here) and they run in the same parallel
`--fast -j8` pass, so the wall-time cost is bounded by the slowest one rather
than the sum. What buys it is that the claims are about **milliseconds**, and a
regression that refused to simulate milliseconds could not make them.

## How the host controller fits in the demo

The GUI is not a mock: it speaks the real wire protocol to the real bridge.

- **Assemble.** Pick `firmware/uart_echo.pe`; the host runs the existing assembler
  (`tools/fw/peasm.py`), refuses >1024 words, and shows the word count, a
  SHA-256 of the canonical image and a terminal-jump warning.
- **Load.** The words are framed (sync `A55A`, version/opcode/target,
  sequence, length, CRC-16/CCITT-FALSE) and clocked into the chip's
  instruction memory. The response is a real acknowledgement: words written,
  fault bits, and a final-word echo. The GUI refuses to proceed unless the
  acknowledgement matches the image.
- **Start / stop.** `run` is held low through reset and load, and is raised
  only after a successful load. A stopped core is a *deliberate state*, not a
  side effect.
- **Observe.** Status shows run/state, registers, the heartbeat timer, fault
  bits and words written; a register dump and bounded memory reads are
  available while stopped. A chip fault surfaces as an event and the GUI
  labels what is *host-commanded*, *board-observed* or *chip-confirmed*.
- **The bridge is real firmware.** `tools/host_bridge/main.py` runs on the
  Pico, owns reset, the 60 MHz project clock and the SPI pins, and was
  verified on a real MicroPython interpreter (not just by inspection).

## The merge gate — a merge is never pushed without the tests its diff can break

`regress/verify_merge.sh` is the gate. Before pushing a merge (or a branch that
is about to be merged), run it:

```sh
./regress/verify_merge.sh                 # gate HEAD (the merge you are pushing)
./regress/verify_merge.sh --list          # print the mapping, run nothing
./regress/verify_merge.sh --fast -j8      # same gate, parallel
./regress/verify_merge.sh --self-test     # the mapper's own 18 checks, no RTL
```

It maps the merge onto the testbenches that can be affected, using
`regress/run_all.sh`'s **own** `CASES` table (parsed, not restated, so a case
added to the suite cannot be invisible to the gate): a changed `rtl/foo.v`
selects the cases that compile `foo.v`; a changed `tb/<case>.v` (or anything
under `tb/<case>/`) selects that case; a changed `firmware/*` or `tools/fw/*`
selects every case compiling `pe_cpu.v`/`pe_soc.v` — the cases whose DUT is
partly firmware. It also maps what the *other* side gained while the branch was
away (`merge-base..M^1`), which is the direction the actual 2026-09-25 failure
came from. Anything it cannot map confidently is a **full** suite run, said out
loud, never a quiet subset.

Exit codes, and the reason each one exists:

| code | meaning |
| --- | --- |
| 0 | the affected set is green |
| 1 | red, **with a named failing case** |
| 2 | usage / environment |
| 3 | gate error — it could not confirm it ran the set it selected, or `run_all.sh` rejected its filter |
| 4 | **inconclusive** — the run died (OOM, out of disk, the single-run lock) and named no failing case, **or a script it depends on changed while it was running**. Not a pass, not a red |

**Why 4 exists, and the pre-flight that feeds it.** The gate's own first run
exited 137 with an empty failure list, and a gate that reports "RED, the affected
set failed" for a run that never finished is claiming something its log does not
support. The same argument covers a worse case: bash reads a script
*incrementally*, so editing a harness while it runs can make it report a **false
PASS** — and a false pass is believed, which is the worst thing a gate here can
do. `regress/dep_guard.sh` therefore stamps the **content** of the scripts a run
executes and re-checks them on the way out; a change, or a vanished file, prints
`CHIP-DEP-CHANGED` and the gate reports INCONCLUSIVE **even if the run exited 0**.
It is checked over the whole `regress/` dependency set at the run's exit and again
around each mutation suite, and `regress/test_dep_guard.sh` — a gate in its own
right, inside the full suite — proves it fires on a real change, stays quiet on an
unchanged run, ignores a content-preserving `touch`, and fails 3 of its 7 cases
when its own comparison is disabled.

**Why 4 exists.** The gate's own first run exited 137 with an empty failure
list, and a gate that reports "RED, the affected set failed" for a run that never
finished is claiming something its log does not support. Read 4 as "make the run
finish", never as "the RTL is fine".

**The 27-check self-test is not optional reading.** `--self-test` asserts the
mapper's rules, the mutation mapping, the skip-print, the empty-selection
refusal, *and* the hand-off contract between the gate and `run_all.sh`'s
`--cases` / `MUTATE_ONLY` filters — the pairs that disagreed during this gate's
own development and made a filter select nothing while the gate still had a
selection to show. The count of checks it ran is itself asserted, so a
self-test that silently stops exercising rules fails instead of reporting
success.

**The mutation suites are narrowed too, and the narrowing is printed.** By the
manager's 2026-09-25 ruling a narrowed gate runs a mutation suite only when one
of that suite's `MUTABLE` targets intersects the merge's changed set:

```text
--- mutation suites (2 run, 14 skipped by mapping, 16 total) ---
  RUN   mutate_timing_tb         MUTABLE intersects the changed set (firmware/freqmeter.pe)
  SKIP  mutate_ctrl_tb           no MUTABLE target among the changed files
  RUN   mutate_macro_flow_config MUTABLE is empty: mutates nothing in the repo, never narrowed away
```

Measured cost of the 16 suites, sequential (2026-09-25): **1456 s**, and the
distribution is lopsided — `mutate_eth_mac_tb` 378 s, `mutate_eth_tx_loop_tb`
343 s, `mutate_timing_tb` 335 s against four suites under 5 s. The one figure that had been voided is now re-measured and valid:
`mutate_timing_tb` at **323 s** (58 cases, 58 detected, 0 survived), and
the total is 1456 s. It had first reported FAILED because a file edit
landed while bash was executing it — a read/write race, not a defect in
the harness, which was intact throughout. That race is now closed for
every run that goes through the gate: see the pre-flight below and
`reviews/2026-09-25/MERGE-GATE-MUTATION-NARROWING.md` §5 and §8.

Three properties keep the narrowing honest, and all three escalate to running
*more*, never less: a harness with no `MUTABLE` line is unmappable and runs
everything; an empty selection is refused exactly as an empty case selection
is; and the suite count `run_all.sh` reports is compared against the count the
mapper chose, so a `MUTATE_ONLY` that matched nothing is a **gate error**, not a
green with zero mutation coverage. `MUTATE_ONLY` travels as an environment
variable, so `./regress/run_all.sh` — the master gate — is unchanged and always
runs all 16. `regress/check_mutation_lists.sh` proves each list still covers
every file its harness writes; it found two live gaps in already-published lists
on its first run.

Full evidence: `reviews/2026-09-25/MERGE-FORENSICS-5B4731F.md` §5-§6.

## What is proven, what is simulated, what is pending

| Claim | Status | Evidence |
| --- | --- | --- |
| UART / SPI / I2C / 10BASE-T personas run as firmware | **RTL-proven** | `tb_pe_soc_uart`, `tb_pe_soc_spi`, `tb_pe_soc_i2c*`, `tb_pe_soc_eth*`, `tb_pe_eth_tx` |
| Full regression is green | **RTL-proven** | `./regress/run_all.sh --fast -j8` → exit 0 on a cold clone: **RTL 34/34, firmware 26/26, 12 mutation suites** (R2 and the wait-word gate are registered in `run_all`; see `docs/cold-clone-audit.md`) |
| 60 MHz maps and routes | **RTL-proven (mapped, not routed)** | area + screen reports; physical flow intentionally out of scope |
| Host GUI + bridge against fakes | **host-proven** | one-command gate `tools/host_gui/run_host_tests.sh` (host tests, bridge tests, lint, both fuzz campaigns, soak smoke, MicroPython conformance, acceptance `--fake` → 35 PASS, 0 FAIL, 1 SKIP) |
| Bridge on a real MicroPython | **measured** | built the MicroPython unix port and ran the deployed modules on it; found and fixed 5 deployment blockers (`reviews/2026-09-25/HOST-BRIDGE-MICROPYTHON.md`) |
| Framed host bus (PING/LOAD/STATUS/CLEAR_FAULT/TARGET, target-1 loopback, sticky faults, `IRQ_N`) | **RTL-proven** | chip-side R1 landed and verified with mutation coverage; the host's bridge/acceptance drive the same contract |
| Host protocol on real silicon (R1) | **LANDED + verified** | the chip team landed the framed bus, `IRQ_N` and target 1; the host stack speaks that exact contract today |
| Memory/register readback (R2) | **chip-confirmed (simulation)** | chip R2 landed and registered in `run_all`: `tb_pe_ctrl_r2` reports **18/18** golden steps PASS, byte-exact (CRC included) with the model image loaded per vector, the opening 3-word LOAD replayed as a real frame, and `pe_ctrl` STA-screened. The record lives in the **chip** repo (`reviews/2026-09-25/R2-READ-PATH-REVIEW.md`); this repo's package consumed those same steps as its acceptance spec (`reviews/2026-09-25/R2-READ-VERIFICATION.json`) |
| Liveness is observable (P3) | **chip-confirmed (simulation)** | R2's STATUS is 11 words incl. `pc/a/x/y/timer` at native widths, and `READ_CPU` is the one **non-halting** read, so a host can watch a RUNNING program (chip P3 finding closed; host GUI surfacing is this branch) |
| Debug control: arm / hit / inspect / step / clear / resume (R3) | **chip-confirmed (simulation), 25/26 steps** | chip R3 landed; the chip's own `tb_pe_ctrl_r3_conf` is **GREEN 26/26** against the contract, with a 7-mutant gate (all caught) and formal proofs for S1–S4. It covers **25 of the 26** steps in this repo's golden package byte-exactly, and those 25 now carry `chip_confirmed=true` with the chip's citations; the one exception is a step whose expected `insn` is not contract-determined for a free-running core (a freeze-snapshot TB model boundary), which **both sides leave unproven** rather than "fixing" to match a testbench. The host's GUI panel, session state machine and the 7-beat `r3_demo_*` acceptance act drive the same contract; see `reviews/2026-09-25/R3-DEBUG-VERIFICATION.json` and `R3-VECTOR-BYTES.md`. **Not** hardware-confirmed |
| Board-in-the-loop acceptance | **pending** | runner + runbook exist (`docs/host-bridge-bringup.md`); needs a board. This is the one thing the demo table marks not-done |
| Physical flow (DRC/LVS) | **out of scope by design** | deferred in the plan; no physical tools run |

The honest shape of the entry: the *chip* is a verified microcontroller with
four working protocol personas, a verified framed host bus (R1) and verified
register/memory readback (R2, byte-exact against the same golden vectors the
host gates on); the *host* stack is a verified client whose real bridge
firmware speaks that bus and whose acceptance spec is the chip's own passing
table. The one thing not yet demonstrated is the **physical** run - a Pico over
USB with a real shuttle - which is stated as such everywhere it appears.

## Timings worth quoting

- Core: **60 MHz** (16.667 ns). UART tick: **260 clocks per half bit** →
  115,385 baud vs 115,200 nominal (+0.16 %).
- Host SPI first pass: **5 MHz** cap (`min(5 MHz, clk/6)`), the negotiated
  rate the bridge reports in `hello` and refuses to exceed.
- Full regression wall time: about a minute (`run_all.sh --fast -j8`).
- The demos are sized to be watchable: a 118-word image loads in one framed
  transaction (about 2 KB on the wire) acknowledged with four response words,
  and a status read is a single frame exchange.

## Fallback demo — no board at all (the judge's laptop is enough)

If there is no board on the table, the whole story still runs, in order of
"how much hardware it touches":

1. **Show the GUI against the bridge on the same laptop.** Start the host
   stack; the acceptance runner's `--fake` mode is a complete, honest
   end-to-end run: real GUI/session/transport/bridge, a modelled chip.
   `python3 tools/host_bridge/acceptance.py --fake` → 35 PASS, 0 FAIL, 1 SKIP
   SKIP, and you can drive the same sequence from the browser.
2. **Show the firmware on the emulator.** `python3 tools/fw/peemu.py
   firmware/uart_echo.hex --send "41 42"` — the exact words the hardware
   testbench checks, from the CPU model, in ~2 seconds.
3. **Show the protocols as code, not slides.** Open the four `.pe` files and
   the four testbenches; the personas are a few hundred words each, and each
   one's proof is a checked-in test with a `PASS` line.
4. **Frame the remaining hardware work out loud** (the table above). A demo
   that ends by naming its own pending integration — with the acceptance spec
   already written for it — reads as a team that knows where it is.

## Run it yourself

```bash
# full host-side gate (no board needed, about a second)
tools/host_gui/run_host_tests.sh

# the end-to-end acceptance against fakes
python3 tools/host_bridge/acceptance.py --fake

# the firmware loop the demos use
python3 tools/fw/peemu.py firmware/uart_echo.hex --send "41 42" --max-cycles 900000

# with a board (bring-up + triage table in docs/host-bridge-bringup.md)
python3 tools/host_bridge/acceptance.py --device /dev/ttyACM0 --board <revision>
```
