# Simulator bake-off: Icarus vs Verilator

Both simulate this design correctly. They are not interchangeable, and the
difference shows up as a pair of numbers rather than a preference.

Measured 2026-09-22 on the competition machine (Ryzen 9 5900X, 24 threads,
load average ~1.7). Same testbench file, same firmware hex, same SRAM
behavioural model, same work in both cases — only the simulator differs.
Both were verified to print `PASS: all checks` before being timed, and the
I2C TB was checked the same way. Five runs each, median reported.

## Speed

| testbench | Icarus 13.0 | Verilator 5.050 | ratio |
|---|---|---|---|
| `tb_pe_spi_soc` (8 frames) | 110.3 ms | 8.7 ms | **12.7x** |
| `tb_pe_i2c_soc` (longest) | 283.3 ms | 15.0 ms | **18.9x** |

Verilator's run-to-run spread was also much tighter — 15, 15, 15, 15, 15 ms on
the I2C TB against 279–286 ms for Icarus. A testbench suite that runs in a
predictable few milliseconds is a suite that gets run.

## Build cost, which is the other half

| | Icarus | Verilator |
|---|---|---|
| compile (SPI TB) | **9 ms** | 2773 ms |

Verilator's build is **~300x** Icarus's, and it is paid once per source change
(`--binary` runs its own `make -j24`). Break-even on the SPI testbench is about
**27 runs**. The practical reading:

- **One-off debugging run** — Icarus. Nine milliseconds to a running simulation
  beats three seconds of C++ compilation every time.
- **The regression loop** (`tb/run_all.sh`, 23 testbenches + 2 mutation
  harnesses) — Verilator, comfortably. At 12–19x per test the build is repaid
  within a couple of full passes.

## What Verilator does NOT give you: X

This is the reason the bake-off is not just a speed table.

```
  ICARUS     unassigned reg = xx   ==== 4-STATE: X is preserved
  VERILATOR  unassigned reg = 00   ==== 2-STATE: X collapsed to 00
```

Verilator is **2-state**. An unassigned or `x`-literal signal becomes `0`, and
it stays `0` silently. Two consequences for this project:

1. **`=== x` checks do not work under Verilator.** This suite uses `===` in
   places precisely because `x` is a real failure mode here — the accumulator
   in `tb_pe_spi_soc` is `xx` until the firmware first writes it, and the
   reset-seed equivalence argument in `rtl/pe_uart_soc.v` depends on comparing
   against a known seed rather than an unknown. A 2-state simulator cannot
   express "this was never driven", so a bug that manifests as *uninitialised*
   reads as a valid 0 instead.
2. **X-propagation bugs are invisible.** A design that reads an undriven net
   and happens to work because the bit is 0 will pass under Verilator and
   behave differently in silicon, where the bit could be anything.

That risk was tested rather than assumed. The same five mutations from
`tb/mutate_spi_tb.sh` were run under both simulators, and the FAIL counts
matched exactly:

| mutation | Icarus FAILs | Verilator FAILs |
|---|---|---|
| 1. sample MISO before the rise | 9 | 9 |
| 2. shift LSB-first | 9 | 9 |
| 3. CS_N never deasserted | 10 | 10 |
| 4. pin read ignores inputs | 17 | 17 |
| 5. no explicit SCLK idle | 9 | 9 |

So on **this** suite, at **this** maturity, Verilator loses no detection power.
That is an empirical result about these five mutations, not a general guarantee
— the X-blindness above is still real, and a future testbench that relies on
`=== x` to catch an undriven net would silently stop testing if it were only
ever run under Verilator.

## The suite-level result, which is the opposite of the per-test one

Per-run, Verilator wins by 12-19x. Per SUITE, it loses badly, and the number is
worth writing down because the naive reading of "12-19x faster" is that
`run_all.sh` should switch simulators:

| 24 testbenches, compile + run | time |
|---|---|
| Icarus, serial | **2.40 s** |
| Verilator, 24 separate `--binary` builds | **167.19 s** |

**69.6x slower.** Verilator builds per `--top-module` and has no shared cache
across them (median build 5.6 s, min 5.3 s, max 33.7 s), so a suite of 24
one-shot testbenches pays 24 full builds. The 12-19x per-run speedup is paid
back only after ~27 runs of the SAME testbench — which is exactly the loop
Verilator is good for (iterating on one TB, or a long randomized soak) and
exactly what a regression suite is not.

So `tb/run_all.sh --fast` does NOT swap simulators. It runs the same 4-state
Icarus simulation in parallel across the testbenches, which is where the suite's
headroom actually is.

`--fast` also cannot be a Verilator path for a second, independent reason:
**`tb_pe_pinmux` does not run under Verilator at all.**

```
%Error-DIDNOTCONVERGE: ../tb/tb_pe_pinmux.v:51: Active region did not
converge after '--converge-limit' of 10000 tries
```

That testbench models the bus at STRENGTH LEVELS — a pull-up versus strong 0/1 —
because the `od` bit's whole purpose is making contention unreachable, so
"contention never happened" is the property under test. Verilator's 2-state
model cannot express weak/strong, and it aborts rather than degrading. This is
the X problem again, in a form that stops the run instead of hiding in it.

## Recommendation

What is actually wired up:

- **`tb/run_all.sh` (default) — Icarus, serial.** The signoff path, because it is
  4-state and this suite's honesty depends on that.
- **`tb/run_all.sh --fast [-jN]` — Icarus, parallel across testbenches.** The same
  simulation, so it cannot weaken verification by being 2-state. Measured 10.7 s
  → 9.4 s on the full suite; the testbench loop itself drops from ~2.4 s to
  ~0.5 s, and the remainder is dominated by the two mutation harnesses
  (`mutate_i2c_tb.sh` 4.9 s + `mutate_spi_tb.sh` 1.1 s), which are inherently
  serial because they mutate and restore shared RTL in place.
- **Verilator — the single-testbench iteration loop**, not wired into
  `run_all.sh` at all, for the 69.6x reason above.

Verified rather than assumed: `--fast` and the serial path produce **identical
verdicts** on all 24 testbenches, and an injected fault (`pin_rd` forced to zero)
fails both paths with identical diagnostics and exit code 1. A fast path that
only agreed on the passing case would be worthless.

The Verilator flow was proven end-to-end here: `--binary --timing` elaborates
this design (with one ignorable `SPECIFYIGN` warning from the PDK SRAM model's
`specify` block), and the `$dumpfile`/`$dumpvars` calls in the TB needed gating
behind `+dump` because Verilator ignores them unless built with `--trace`.

A note for whoever revisits this: the survey that produced the table above is
worth re-running if the suite's shape changes a lot (many more testbenches, or a
long soak test). The rule of thumb that falls out of the numbers is that
Verilator wins when the SAME testbench runs many times and loses when each
testbench runs once.
