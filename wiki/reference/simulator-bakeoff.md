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

## Recommendation

Keep **Icarus as the signoff simulator** for `tb/run_all.sh`, because it is
4-state and this suite's honesty depends on that. Add Verilator as the **fast
loop** for iterating on a single testbench, where the 12–19x is worth a 3-second
build. If the suite ever grows slow enough that the regression loop hurts, the
migration is a `--binary` build per testbench and a C++ `main` that drives the
clock — but it should be done with the X question answered first, not after.

The Verilator flow was proven end-to-end here: `--binary --timing` elaborates
this design (with one ignorable `SPECIFYIGN` warning from the PDK SRAM model's
`specify` block), and the `$dumpfile`/`$dumpvars` calls in the TB needed gating
behind `+dump` because Verilator ignores them unless built with `--trace`.
