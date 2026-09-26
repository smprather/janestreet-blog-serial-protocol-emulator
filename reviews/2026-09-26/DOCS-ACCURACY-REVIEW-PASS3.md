# Docs accuracy review — pass 3 (2026-09-26)

Author: protocol-worker. Rolling pass. Pass 3 covers `docs/diag-bus c5271ca` (the
I2C-advanced set, the target pass 2 named) and `docs/diag-timing 692dec0` (the
servo set), plus the current state of pass 1's three corrections.

**Result: the I2C set is accurate — no corrections. The servo set has TWO
arithmetic errors, both in a derived callout, both of which break a reader's
attempt to reproduce the figure's own headline number. Pass 1's corrections are
still unactioned.**

## 1. Corrections — owner: **pw-diag-timing** (the servo figure set)

Both are in the "one outer step" derivations, which appear in all three servo
figures. They do not affect any *measured* value, and every measured width, the
tables, the frame period and the pass/fail bands are correct. What is wrong is
the arithmetic a reader would use to reproduce those numbers.

### D1 (low-medium) — the pulse's per-step cost is 625 clocks, not 619

`proto-servo.puml:42` and `proto-servo-timing.puml:84` both say:

> one outer step = 4*152 + 11 = **619 clocks** = **10.3 µs**

The same figures state the routine's formula (`proto-servo.puml:51`):

> `total(n1,n2,n3) = (n1-1)*(10 + (n2-1)*(4*n3+7)) + 4`

For the pulse table (`n2 = 2`, `n3 = 152`) that is
`10 + (2-1)*(4*152+7)` = `10 + 615` = **625 clocks = 10.417 µs**, so the figure
contradicts itself, and `4*152+11` is not what its own formula evaluates to (the
`+11` appears to have absorbed the `+10` and the `+7` inconsistently).

**Why it matters, concretely:** a reader who reproduces the 1 ms pulse from 96
steps × 10.3 µs gets ≈ 990 µs and concludes the figure is 1 % out. From 625 they
get 96 × 10.417 = 1000.03 µs, which lands on the measured **1000.15 µs** the same
figure reports. The derivation, not the measurement, is what is broken.

### D2 (low-medium) — the gap's per-step cost: the written sum is wrong

`proto-servo-frame.puml:134` and `proto-servo-timing.puml` say:

> (10 + 10*499) = **4 655 clocks** = **77.6 µs**

`10 + 10*499` is **5 000**, not 4 655, so both the clock count and the µs figure
are wrong; the correct per-outer-step cost for the gap table (`n2 = 11`,
`n3 = 123`) is `10 + 10*(4*123+7)` = 5 000 clocks = **83.333 µs**.

**Why it matters, and the check that settles it:** with 5 000, the 19 ms gap
reproduces exactly — `(229-1)*5000 + 4` = 1 140 004 clocks = **19 000.07 µs**,
which is the 19.000 ms the figure's table claims. With 4 655 it does not
reproduce at all (228 × 4655 = 1 061 340 clocks = 17.69 ms). So the correct value
is demonstrably 5 000, and the figure's own headline gap depends on it.

Both are one-line fixes in the callout boxes. Neither changes a measured number,
a table, a band, or a verdict — which is worth saying explicitly, because a
reviewer's job here is to say *which* claim is wrong, not to make the document
look wrong.

## 2. Verified correct — no correction

**`docs/diag-bus c5271ca`, the I2C-advanced set (`proto-i2c-adv.puml`, 101
claim-bearing lines).** Checked against the gate that runs in every full suite,
the firmware, and the independent TB decoder:

| claim | ground truth |
| --- | --- |
| `tLOW 7 µs (min 4.7)`, `tHIGH 6 µs (min 4.0)` | `tb_pe_soc_i2c_adv.v` asserts `min_low_ns >= 4700` and `min_high_ns >= 4000`; `tools/checks/i2c_timing.py` `FLOORS` = 4.7 / 4.0 |
| the waits are in **1 µs ticks** | `firmware/i2c_adv.pe` waits are `IN A, I2CTICK` throughout — the exact 1 µs tick (`pe_soc.v:560`), not the 260-clock half-bit |
| "the recipient of the 9th clock **swaps by phase**" — the act's central subtlety | `send_byte`'s ACK slot releases SDA and samples; `read_byte`'s drives it. Confirmed in the firmware, and it is why a master that only ever releases SDA deadlocks |
| `dmem[10]` = transaction state, `dmem[11]` = read accumulator, `dmem[13]` = the ACK slot, `dmem[15]` = 0xA5/0x55 | the firmware's own header block, and the TB asserts `dmem[15] == 0xA5` on success and `0x55` on abort |
| "the dispatcher is `LDM A,10` then a cumulative `SUB A,1` / `JZ` chain, two instructions per state" | verbatim in the firmware; and the reason it works is the one the firmware states — `SUB A,1` leaves the decremented value so the next `JZ` tests the next-lower state |
| the wire sequence `0xA0 A 0x3C A 0x5A A (repeated START) 0xA1 A 0x11 A 0x22 A 0x33 N STOP` | `firmware/i2c_adv.pe` loads `A0 3C 5A A1`; the TB asserts the ACKs land in `dmem[1..4]` and the three read bytes in `dmem[5..7] == 11/22/33`, with `sl_rd_ack == N_RD - 1` and `sl_nack_seen` |
| the stretch: "slave holds SCL: 900 clks = 15.0 µs", and `tHIGH` starts at the **real** rise | 900/60 MHz = 15.0 µs; and the TB asserts `max_low_ns > (cfg_stretch_len * 1000 / CLK_HZ) * 80/100`, i.e. the stretch is checked as a real low-phase extension |

One thing the figure is careful **not** to claim, worth recording: the 60-phase
sweep belongs to `tools/checks/i2c_timing.py`, which runs against
`firmware/i2c_pins.pe` — the *baseline* I2C program — not `i2c_adv.pe`. The figure
makes no 60-phase claim for the advanced act, so there is nothing to correct; a
reader who assumed otherwise would be over-claiming, and the figure does not help
them do it.

## 3. Status of pass 1's corrections (owner: pw-diag-proto) — still unactioned

At `d17e07a`, unchanged: **C1** the pre-repair `cpu_exec` expression in four
places (the maps' three plus the new figure's THE GATE box at
`proto-r3-debug-control.puml:105`); **C2** the maps listing 3 of 4 debug opcodes
(`project-plan.puml:107`, `project-progress.puml:174`) while the same branch's
figure lists all four correctly — still a self-contradiction within one branch;
**C3** "one 260-clock tick" undisisambiguated in three places.

## 4. Not yet reviewed

`docs/wiki-features 48e4cef` (the per-SCHEMA index entries and the servo wiring)
and the new `wiki/concepts/protocol-servo.md`, which is the natural companion to
the figures corrected above and may restate the same derivation — worth checking
against D1/D2 when it is read, so the fix is made once rather than twice.
