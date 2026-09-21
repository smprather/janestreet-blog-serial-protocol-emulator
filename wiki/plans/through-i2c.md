---
title: Plan — Through I2C
created: 2026-09-20
updated: 2026-09-20
type: plan
tags: [plan, protocol, architecture, area-budget, verification]
sources: [raw/articles/janestreet-protocol-emulator-competition.md]
confidence: medium
---

# Plan — Through I2C

The goal of this milestone: **a real I2C master transaction executed by firmware
on real RTL** — START, 7-bit address + R/W, data byte, ACK, repeated START, read
byte with ACK/NACK, STOP — verified by a testbench that does not know how the
firmware works, and reproduced in the bit-accurate emulator.

Why I2C third and last of the baseline tier: it is the only one of the three that
cannot be done with a plain push-pull output. It needs **open-drain** (drive low /
release), an **input path on the same pin**, and **read-back during transmit** for
arbitration. UART needed none of that; SPI needs none of it either. Building I2C
therefore builds the pin matrix, and the pin matrix is the last piece of hardware
that gates every remaining protocol ([[concepts/physical-layer-gpio]],
[[reference/protocol-pin-budget]]).

## Definition of done

1. `tb/run_all.sh` green, including the new firmware RTL test and regenerated
   reference pages (`tools/gen_signal_glossary.py` is currently **stale**).
2. A firmware program in `firmware/` that runs an I2C master transaction, with
   timing that meets Standard-mode spec limits **as measured on the pin**, not as
   intended by the source.
3. An RTL testbench driving an independent I2C slave model (not a re-implementation
   of the firmware's assumptions) with START/repeated-START/ACK/NACK/STOP.
4. The same program reproduced in `tools/peemu.py`, and the RTL TB and the emulator
   agreeing bit-for-bit on the transaction.
5. All of it committed, with `wiki/log.md` and [[STATUS]] updated.

Out of scope for this milestone: fast-mode I2C, clock stretching, and the
board-level PHY work (pull-ups, level shifting).

**Changed 2026-09-20: the SRAM swap is now a PREREQUISITE, not out of scope.** An
earlier revision deferred it on the grounds that the I2C program would probably stay
under ~120 words. Two things killed that: `tools/peasm.py` now rejects a program
over 128 words outright rather than emitting one the 7-bit program counter silently
aliases, and flop instruction memory turns out to be 89% of the die. Do the swap
first — see Blocker 3 and [[decisions/adr-003-memory-plan]].

## What already exists that this reuses

| Piece | Where | Use in this milestone |
|---|---|---|
| CPU (16 opcodes, A/Y/X, 8-bit PC) | `rtl/pe_cpu.v` | runs the firmware; unchanged |
| SoC (CPU + IMEM/DMEM + tick timer) | `rtl/pe_uart_soc.v` | becomes the model for the I2C SoC; generalize, do not fork |
| Assembler + emulator | `tools/peasm.py`, `tools/peemu.py` | firmware development loop |
| I2C framing reference | `tb/tb_pe_i2c.v` (PASSES) | its START/STOP/ACK stimulus is the reference behaviour to reproduce in firmware |
| SERDES | `rtl/pe_serdes.v` | **not used by I2C**. See "Why not the SERDES" below |
| Pin budget | [[reference/protocol-pin-budget]] | 2 of 24 pads, so no budget risk |

### Why not the SERDES

`rtl/pe_serdes.v` is a word engine: load 8-32 bits, pace with `bit_en`, collect a
word. It is the right shape for UART/SPI/CAN/USB, where a byte moves in one
operation. I2C is not that shape: every bit is conditional (ACK sampling,
arbitration read-back, clock stretching), and the byte engine cannot be told to
stop mid-word. The PIO lesson applies — a byte engine earns its area for bulk
transfers, not for a protocol whose control flow is per-bit. Keep the SERDES for
the protocols that already use it; I2C is bit-banged. That is a deliberate
architecture statement, not a shortcut, and it is worth saying in the writeup.

## Blocker 1 — the UART RTL test (RESOLVED 2026-09-20; three separate defects)

`tb_pe_uart_soc.v` was red: TX decoded `d0` for `0x41` and `e8` for `0x42`, then
the watchdog fired. The symptom looked like a CPU/peripheral cycle-model divergence
between `rtl/pe_cpu.v` and `tools/peemu.py`. It was not. Three defects, none of them
in the CPU:

1. **The testbench lost the echo's start edge — the dominant bug.**
   `@(negedge tx_pin)` was executed *after* `send_byte()` returned. The firmware
   echoes the byte as soon as it has assembled it, and RX and TX are **separate
   pins** — so the echo's start bit was already in flight when the TB began waiting.
   The TB therefore missed it and synced to the next falling edge, which is the
   *last* data bit's edge, not the start bit. Every decode was shifted by one bit,
   which is exactly what "got d0 want 41" looks like: `0x41 = 01000001`, read one
   bit late, decodes `11010000 = d0`.
   Fix: latch the edge in an `always @(negedge tx_pin)` monitor and anchor the
   sample grid to the *latched* time — the TB comment's own intent ("anchored to
   the START-BIT EDGE") made true, rather than assumed.
2. **The testbench loaded 112 of the program's 114 words** (`tb_pe_uart_soc.v:70`,
   `i < 112`, and `$readmemh` warns the same). The program's final `JMP 0` loop-back
   is at word 113. Not the cause of the decode failure, but the program under test
   was not the program that was assembled.
3. **A dead jump target in the transmit path.**
   `firmware/uart_echo.pe`: after decrementing the pending-tick counter, the branch
   was `JNZ tx_startw` (the poll) where the firmware's own comment above it says the
   poll must jump back to the *snapshot*, not to the poll. Jumping to the poll makes
   the wait exit after a single tick, so a 2-tick wait lasted 1 tick: the start bit
   and the first bit cell came out 4.3 µs instead of 8.67 µs. Fix: `JNZ tx_start`.
   The same idiom appears in the receive path and in the other transmit waits — in
   those the target is already `*w` with the snapshot re-taken at the block top, so
   they are correct; the start block is a copy that lost its snapshot label.

Verified after the fixes: `tb_pe_uart_soc` **PASS** on all four bytes (41, 42, 00,
FF), the emulator PASSes the same four, and `tb/run_firmware_tests.sh` is 5/5.
TX cell widths measured at the pin: **8.6-8.7 µs**, of which the 8675 ns last cell
is the firmware's own tick-loop latency, not drift.

A fourth, cosmetic defect is left standing: the tick is **173** clocks
(`40_000_000 / 115_200 / 2`), but the comment in `rtl/pe_uart_soc.v:58`, the
`uart_echo.pe` header and `tools/peemu.py:43` all say 174 (real baud is therefore
115,607, +0.35%). The code is right, the comments are wrong. Cheap to correct
alongside step 2; it matters because that number is what a reader will trust when
they compute their own protocol's tick.

The lesson worth keeping, and it is the same one the CAN/USB testbenches taught in
Milestone 1: **a testbench that "waits for" an event it may have already missed is
not testing anything.** Latch the edge, then anchor to the latched time.

## Blocker 2 — the pin matrix and open-drain (the actual new hardware)

I2C needs, per pin:

- **drive low** — output-enable asserted, output data 0
- **release** — output-enable deasserted, pin floats to the external pull-up
- **read** — the pin's level, whether we are driving it or not

Tiny Tapeout's `uio` pads have a per-pin output-enable, so open-drain is native to
the pad; what does not exist yet is the block in front of it. Design:

```
        per-pin:                        the matrix adds:
  cfg_out[i]  ──┐
  cfg_oe[i]   ──┼──> pin_reg[i] ──> pad_oe / pad_out
  cfg_in[i]   <──┘   pin_lvl[i] <── pad_in
  cfg_prot[i] selects one of 8 protocol wire sets
```

The per-pin registers are the interesting part: a *write* drives `oe`/`out`; a
*read* returns the pad level. Firmware does `OUT PINSET, mask` / `OUT PINCLR, mask`
and `IN PINREAD`. Registering the output (as `pe_uart_soc.v` already does for its
single pin) gives the read-back path a clean 1-cycle answer, which is what the
arbitration check needs.

I2C-specific semantics to pin down in the design (these are the decisions; the
gates are easy):

- **Release means the last output value stops mattering.** Firmware should write
  `out=1` and `oe=0` for release, or the transition from driving 0 to releasing
  will glitch — actually *will not* glitch if `oe` gates the pad, but a reviewer
  will ask, so the ordering rule belongs in the RTL header: `oe` must be cleared
  before `out` is driven, and the pad's own OE gating is what makes it safe.
- **Arbitration loss is a first-class signal.** Read back every bit transmitted as
  a 1: if the pad reads 0, another master won. Firmware needs that as a branch
  (one `IN` + one `JNZ` per bit — 2 cycles at µs scale, free). Most bit-bang I2C
  implementations skip this; doing it in firmware is a genuine differentiator.
- **Clock stretching** (a slave holding SCL low) is *observable* for free with the
  read-back path: before rising SCL, read it; if low, wait. One `IN`/`JNZ` per
  clock. Include it — it is the difference between "speaks to a friendly EEPROM"
  and "speaks I2C".
- **Two pins, or one?** SDA and SCL both need open-drain; SDA also needs read-back.
  SCL only needs drive-low/release and an optional read-back for stretching. Budget
  two pads, both with the full per-pin structure — symmetric and it costs 8 flops.

Sizing: 8 pins x (2 out + 1 oe + 1 in + 1 cfg) ≈ 40 flops plus a small mux tree, in
the low hundreds of cells. Compare against the SERDES's 539 cells — the pin matrix
should be *smaller*, because it has no datapath.

## Blocker 3 — instruction memory (sizing, not a wall)

`uart_echo` is **114 words of 128**. A UART is 19 words per byte of payload; an I2C
master plus per-bit arbitration and stretching is more, and two protocols resident
at once will not fit. Options, with the real numbers from [[reference/sram-budget]]:

| Option | Size | Die cost (template 6x4 = 1002x432) | Note |
|---|---|---|---|
| Flops, 256 words | ~4.1 kbit | ~4 k cells ≈ 18% of the logic budget | no macro needed, no latency change |
| `1P_512x16_c2_bm_bist` | 8,192 b | 45,309 µm² = **8%** | 512 words, 1-cycle read, wide-and-flat shape |
| `1P_1024x16_c2_bm_bist` | 16,384 b | 79,674 µm² = **14%** | 1024 words, the comfortable choice |
| `1P_1024x32_c2_bm_bist` | 32,768 b | 140,183 µm² = 24% | 4 KB — the practical ceiling |

Recommendation: **`1P_1024x16` (1024 instructions)**. This section is now
SUPERSEDED by [[decisions/adr-003-memory-plan]], which keeps that choice and adds
the second macro for an Ethernet frame buffer, with the measured per-word cost of
flop memory (1,271 um2 and 60 cells per instruction word, making IMEM 89% of the
current design) and the occupancy figures for both tile allocations. The instruction port
already models a registered ROM (`rtl/pe_cpu.v:104-117` documents the fetch-ahead
that a registered read requires), so swapping flops for a macro does not change the
CPU's interface or its cycle model. That was the right call when the SoC was written
and it pays off exactly here.

**This is now a blocker sooner than the original text implied.** `tools/peasm.py`
gained a hard size check on 2026-09-20: a program over the depth is REJECTED rather
than emitted and silently aliased. That is the right behaviour, and it means the I2C
program cannot quietly overflow -- it will fail to assemble. With `uart_echo` at 114
of what was then 128, do the swap FIRST. [[STATUS]]'s ordered next steps put it at
position 1 for this reason.

### RESOLVED 2026-09-20 — and it was NOT free

The swap is done: `rtl/pe_imem.v` instantiates the real `1P_1024x16_c2_bm_bist`
macro, the program is 1,024 words, and the SoC went from **8,744 cells / 182,650 µm²
to 1,083 cells / 19,795 µm²**.

**This page's claim that the swap "does not change the CPU's interface" was true of
the cycle model and FALSE of the address width**, which is the part worth recording.
The macro's read latency is one cycle (matching the registered-ROM port this design
already had), so the fetch protocol really was ready. But `pe_cpu.v` had a fixed
8-bit PC and encoded jump targets in `arg[7:0]`, so at 1024 words:

- `next_pc[IAW-1:0]` was an out-of-range part-select on an 8-bit vector, and
- the reachable program stayed **256 words** regardless of memory depth.

896 words of the 79,674 µm² macro would have been addressable by nothing. The PC and
the jump-target field had to widen in the same change, and the assembler's range
check had to widen with them or the two would have disagreed about the limit
silently. Full reasoning: [[decisions/adr-004-program-counter-width]].

Verified after the change: `tb_pe_uart_soc` still PASSes on 41/42/00/FF with the
program in SRAM, and `run_firmware_tests.sh` gained a positive test that word 300 is
reachable -- which the old 8-bit PC could not express.

## Firmware design for I2C

### Tick plan — one tick, and every Standard-mode constant is 4-5 of them

At 60 MHz, 115200 baud needs a 260-clock tick. I2C needs a *different, coarser*
tick: **1 µs = 60 clocks**, giving

| Parameter | Standard-mode min | Ticks | Delivered | Margin |
|---|---|---|---|---|
| `tLOW` | 4.7 µs | 5 | 5.0 µs | +300 ns |
| `tHIGH` | 4.0 µs | 6 | 6.0 µs | +2000 ns |
| `tSU;STA` (SDA setup before SCL falls) | 4.7 µs | 5 | 5.0 µs | +300 ns |
| `tHD;STA` (SCL low after START) | 4.0 µs | 5 | 5.0 µs | +1000 ns |
| `tSU;STO` (SCL high before SDA rises) | 4.0 µs | 5 | 5.0 µs | +1000 ns |
| `tBUF` (idle between transactions) | 4.7 µs | 5 | 5.0 µs | +300 ns |

Resulting bus: **90.9 kbit/s**, inside the 100 kHz Standard-mode ceiling. 5/5 would
be exactly 100.0 kbit/s — at the limit, which is the kind of thing that works on the
bench and fails in a compliance report. 5/6 is the safe choice.

### Which tick the pull-up actually eats (corrected 2026-09-20)

An earlier revision of this section said the 300 ns margins were consumed on `tLOW`
and told firmware to budget `tLOW` as 4.8 µs driven. **That is backwards**, and the
direction matters because it decides which parameter gets the spare tick.

The spec measures at V<sub>IL</sub> = 0.3 V<sub>DD</sub> and V<sub>IH</sub> =
0.7 V<sub>DD</sub>. SCL's falling edge is **driven** by the master and is fast
(t<sub>f</sub> ≤ 300 ns); its rising edge is **released** to an external pull-up and
is slow (t<sub>r</sub> ≤ 1000 ns in Standard mode). So:

- **`tLOW` is measured longer than it is driven.** The clock goes low promptly at
  the start and only crosses back up through 0.3 V<sub>DD</sub> some way into the
  rise. Driving 5 ticks yields ≥ 5.0 µs at the pin. It has margin it did not pay for.
- **`tHIGH` is measured shorter than it is released.** The window does not open
  until SCL crosses 0.7 V<sub>DD</sub>, near the *end* of the rise, and it closes on
  a fast falling edge. Releasing for 6 ticks yields as little as 6.0 − 1.0 = **5.0 µs**
  at the pin against a 4.0 µs minimum.

The 5/6 split in the table above is therefore correct, but for the opposite reason
to the one previously written: the extra tick belongs to `tHIGH` because `tHIGH` is
the one the pull-up edge takes from. Firmware should drive `tLOW` for its full 5
ticks and **not** shorten it to 4.8 µs.

The same asymmetry is why clock stretching is cheap to support: a slave holding SCL
low simply delays the 0.7 V<sub>DD</sub> crossing, and a master that polls SCL before
counting `tHIGH` is already measuring the right thing.

Spec values are from UM10204 Table 10, not recalled.

### The turnaround budget — the number that decides the read path

`tVD;DAT(max) = 3.45 µs` (Standard mode) is how long a slave may take to drive data
after SCL falls, and the master must have sampled it `tSU;DAT = 250 ns` before SCL
rises again. So after the master pulls SCL low and releases SDA, the firmware has

**tLOW − tVD;DAT − tSU;DAT = 4.7 − 3.45 − 0.25 = 1.0 µs = 60 cycles**

to notice the bit, read the pin, check it against what it drove, and raise SCL.
60 cycles for a 3-4 cycle decision: comfortable, and it stays comfortable in
fast mode (1.3 − 0.9 − 0.1 = 0.3 µs = 18 cycles). This is the number that makes
the read path *designable* rather than hopeful, and it belongs in the firmware
header as the reason the read sequence is written as straight-line code with no
loops in the critical path.

### Per-bit cost, with the ISA we actually have

The ISA has `SHR` and no shift-left. That looks fatal for I2C's MSB-first order
until you notice **a rotate suffices as long as the shift happens after every bit
except the last** — the mirror of the UART RX loop, which shifts after every bit
*including* the last. Left build:

```
        LDI   A, 0
bit:    IN    A_PIN, PINREAD     ; sample
        ...  OR the bit into A's LSB (only when the pin reads 1)
        LDM   A, byte
        ROTL  A                  ; 8 cycles, one instruction, no carry
        STM   byte, A
```

Cost per bit: a rotate is 8 cycles, the tick wait is a few cycles of granularity,
`IN`+branch is 4-6. At µs-scale I2C timing, **15-25 cycles per bit is invisible**;
the 8-cycle rotate is 200 ns against a 5000 ns cell. No new opcode is needed. This
is worth stating explicitly because the obvious reaction to "no shift-left" is to add
one, and the ISA's area discipline says do not relax it for a problem the rotate
already solves.

### Transaction structure

```
START:  SDA released, SCL high 6 ticks; SDA low; 5 ticks (tSU;STA); SCL low
byte:   8x { SCL low; hold SDA >=1 tick AFTER SCL falls (tHD;DAT, see below);
             then drive or release SDA per bit, >=1 tick before SCL rises;
             if transmitting a 1, read SDA back -> arbitration loss;
             (if reading, release SDA and sample the bit);
             SCL high (6 ticks); }
ACK:    9th clock: release SDA, SCL high, sample SDA -> ACK (low) / NACK (high)
STOP:   SCL low, SDA low; SCL high (5 ticks); SDA released (rises while SCL high)
```

The two orderings that must be written into the firmware header because they are
where implementations get this wrong: SDA may only change **while SCL is low**
(except START/STOP, which are defined by changing while SCL is high), and the
read-back for arbitration must happen **before** the SCL falling edge, since that is
when the slave is still obliged to hold its data.

**Both data-timing margins are a full tick, not the minimum (corrected 2026-09-20).**
An earlier revision budgeted "≥10 cycles before SCL rises" for `tSU;DAT`. Ten cycles
at 40 MHz is 250 ns, which is *exactly* the Standard-mode minimum — a setup budget
with zero margin, at the one place where the pull-up's rise time also lands. Use one
tick (1 µs, 4× the minimum); it is free at this bit rate.

**`tHD;DAT` is not zero, and this is the error worth catching before the firmware is
written.** An earlier revision of the risks section said our write path "changes SDA
right after SCL falls (hold ~0) which is legal". Table 10 does give
t<sub>HD;DAT</sub>(min) = 0 µs, but note 2 of that table requires a transmitter to
**internally provide at least 300 ns of SDA hold** with respect to
V<sub>IH</sub>(min) of SCL, to bridge the undefined region of SCL's falling edge.
Changing SDA the instant SCL falls does not do that, and the failure it produces is
the nastiest kind: a receiver that latches on the old data most of the time and on
the new data occasionally, depending on bus capacitance. Hold SDA for one full tick
after SCL falls before changing it. At 5 ticks of `tLOW` that leaves 4 ticks for the
data to settle, which is still far inside `tSU;DAT`.

## Test strategy

- **Reference stimulus:** `tb/tb_pe_i2c.v` already generates START, addr+R/W, ACK,
  data, repeated START, read, NACK, STOP against the SERDES, and passes. Reuse
  its shape so the new TB is testing the same bus, not a private dialect.
- **New TB:** `tb/tb_pe_i2c_soc.v` drives a slave model and captures SDA/SCL
  transitions, then **checks the timing, not just the bits** — period, `tLOW`,
  `tHIGH`, setup times — against the table above. A bit-level pass with a 3 µs
  `tHIGH` is a fail that a data-only TB would report as a pass.
- **Emulator parity:** `tools/peemu.py` gains the pin matrix model; the same
  transaction must decode identically in the emulator and the RTL TB. This is the
  cheap loop — a 2-second emulator run instead of a minute of `iverilog` — and it
  is what will find the timing bugs.
- **Real device (later, needs the board):** the acceptance test that matters for the
  competition writeup is talking to a real slave (an SSD1306, a 24C02, or a
  temperature sensor). Not this milestone, and it needs the board's pull-ups
  ([[reference/protocol-pin-budget]]).

## Order of work

| # | Work | Depends on | Done when |
|---|---|---|---|
| 1 | ~~Fix the UART RTL test~~ **DONE 2026-09-20**: TB edge latch + full 114-word load, `JNZ tx_start` in the firmware | — | `tb_pe_uart_soc` 4/4 green, cells 8.6-8.7 µs |
| 2 | Regenerate the glossary; add both new TBs + `run_firmware_tests.sh` to `run_all.sh`; extend `synth_area.sh`; fix the 174→173 comments | 1 | `run_all.sh` exits 0 with the new tests listed |
| 3 | Commit milestone 2 (CPU, SoC, assembler, emulator, firmware, TBs) and update [[STATUS]] + `log.md` | 2 | nothing untracked, STATUS describes what exists |
| 3b | ~~TT top level + `info.yaml`~~ **DONE 2026-09-20**: `rtl/tt_um_protocol_emulator.v`, `info.yaml`, `tb/tb_tt_um_protocol_emulator.v` (pad contract: no X on an output, `ena` gates nothing, open-drain never drives high) | — | the repo is submittable; `uio_oe` has a real path to a pad |
| 4 | Pin matrix / OE, as its own block with its own TB; replaces the fixed mapping in the TT wrapper | 3b | open-drain, read-back and tri-state verified |
| 5 | I2C SoC wiring (pin matrix + tick divider for 1 µs) | 4 | TB: pins do what firmware says |
| 6 | I2C firmware: START/STOP first, then byte, then ACK, then read | 1,5 | emulator decodes a full transaction |
| 7 | `tb_pe_i2c_soc.v` with timing assertions | 6 | transaction passes with timing checked |
| 8 | Fast-mode feasibility check (500 ns tick, 333 kHz) | 7 | written up, not necessarily built |

### Where this sits in the wider order

[[STATUS]] carries the authoritative ordered list beyond this milestone. The short
version, and the reasoning for it:

- **The SRAM swap comes before all of this** ([[decisions/adr-003-memory-plan]]).
- **SPI as firmware is cheaper than I2C and should come first**, because SPI is
  push-pull on 4 pins and needs NO pin matrix -- only the SoC's single in/out pin
  generalised to a multi-bit port. The blog's baseline is "UART, SPI, and I2C" and
  only UART exists as a program today.
- ~~**CRC LFSR before DRU.**~~ **BOTH DONE 2026-09-20.** `rtl/pe_crc.v` (209 cells) and
  `rtl/pe_dru.v` (116 cells) are built, self-checked and in `run_all.sh`. The LFSR
  came first, as planned, and the plan's reasoning held: the catalogue gave a golden
  reference on day one ([[reference/crc-config]]) where the DRU had none. The DRU's
  uncertainty was real — its sampling grid needed a theorem (an absent half-cell
  transition can only be a bit boundary), and a 3-tap majority filter turned out to
  shift every edge by a sample. Both are recorded in [[concepts/cdr-oversampling]].

Step 1 is complete (see Blocker 1 for the measured evidence). Steps 2-3 are still
the prerequisite for everything else: an uncommitted, undocumented milestone is the
largest risk in the project today.

## Risks and open questions

- **The tile-size discrepancy is unresolved** (blog ~200x150 µm vs template
  167x108 µm). Every area number in this plan is per the template; the SRAM
  decision in Blocker 3 is the one place it changes the answer materially.
- ~~**Pad OE and open-drain through the TT harness** is assumed available (`uio_oe`)
  but has not been verified end to end in this repo.~~ **Partly closed 2026-09-20:**
  `rtl/tt_um_protocol_emulator.v` now exists and wires `uio_oe[1:0]` to SDA/SCL, and
  `tb/tb_tt_um_protocol_emulator.v` asserts the open-drain property continuously
  (a driven-high uio pin fails the run). What is still unverified is the *physical*
  pad cell: this is RTL-level proof, not a post-layout one. Re-check after the first
  full-chip floorplan.
- **`tVD;DAT(max) = 3.45 µs` applies to the slave**, but a master that holds SDA too
  long after SCL falls can hold the bus. Our write path holds SDA for one tick after
  SCL falls and then changes it — see the `tHD;DAT` note above, which corrects an
  earlier claim here that a hold of ~0 is legal. The read path must not drive SDA
  while ACKing.
- **No interrupts** means a long tick wait blocks everything. That is fine for a
  single protocol; it is the reason the architecture eventually wants two cores or
  an event/interrupt path to the firmware. Worth a decision record before the
  second protocol that must run concurrently (this is why the competition's
  "reprogrammable within timing limits" caveat exists).
- Verification emphasis in the competition rules is explicit; the timing
  assertions in step 7 and the emulator/RTL parity check are the two artifacts that
  demonstrate it cheaply.
- **The tick-delta wait has a half-tick of unremovable jitter, and I2C inherits it.**
  The timer free-runs, so "wait until the count changes" returns after (0, 1] ticks,
  not 1 tick. `uart_echo.pe` absorbs that: its 3-tick alignment lands in (2, 3] and
  every subsequent sample inherits the same offset, so a byte decodes as a unit. I2C
  is less forgiving, because the jitter lands on *each* SCL edge independently rather
  than once per frame. With a 1 µs tick and 5 µs of `tLOW` that is 20% of the
  parameter, which still clears every minimum in the table above — but it is the
  reason the table has whole ticks of margin everywhere and not 250 ns of it.
  A sub-tick delay (a counted NOP loop, ~86 clocks at 40 MHz for half a tick) would
  remove it for both protocols. Worth doing before fast mode, where the budget is
  12 cycles rather than 40.

## The two blocks that landed 2026-09-20 (not part of this milestone's steps)

`rtl/pe_crc.v` and `rtl/pe_dru.v` are items 4 and 5 of [[STATUS]]'s wider ordered
list, not steps of the I2C plan. Neither is needed for I2C — the CRC block does not
serve it (SMBus PEC does, which is a stretch), and the DRU serves only 10BASE-T and
PS/2 receive. They were built out of order deliberately: both are small, both are
independently testable, and the DRU is the highest-uncertainty block in the project,
so its risk is now retired rather than carried. **The I2C plan itself is unchanged.**

## Related

- [[STATUS]] — where this milestone sits in the project.
- [[concepts/physical-layer-gpio]] — why open-drain is emulated, not generated.
- [[reference/protocol-pin-budget]] — 2 of 24 pads, and what the board must add.
- [[reference/sram-budget]] — the numbers behind Blocker 3.
- [[concepts/cdr-oversampling]] — the DRU spec, still unbuilt, needed for 10BASE-T
  and PS/2 receive (not for this milestone).
- [[reference/signal-names]] — the port naming conventions the pin matrix must follow.
