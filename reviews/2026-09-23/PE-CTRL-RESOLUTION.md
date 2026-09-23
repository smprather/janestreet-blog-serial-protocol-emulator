# pe_ctrl run-transition race — resolution

**Finding:** P1 in `reviews/2026-09-23/PE-CTRL-REVIEW.md` (independently
reproduced by the reviewer against the current `pe_ctrl`).
**Status:** fixed. The queued word is aborted on any `run` transition, the
host write is masked by `run`, and the three windows are permanent regression
cases with mutation guards.

## Root cause

`pe_ctrl` checked `run` when the write pipeline *started* (`W_IDLE`), but
`W_PULSE` raised `we_r` unconditionally. Raising `run` after a complete word
queued and before the pulse was sampled produced `writes=1
writes_while_run=1 error=0` — a host write committed while the core was
executing. A queued-but-unstarted word could also wait for `run` to fall and
then write stale program data.

## Safe abort semantics (what the loader promises now)

1. **`host_we` is masked by `run` at the pin**: `host_we = we_r & ~run`. Even
   if a pipeline window puts `we_r` high, `pe_imem` cannot commit a host write
   during execution.
2. **A queued word is discarded, not deferred.** `run` high in `W_IDLE`
   (word queued, pipeline not started) drops the word and latches
   `load_error`; it cannot reappear when `run` falls.
3. **`W_PULSE` aborts before the pulse is sampled** when `run` is high.
4. **`W_DONE` detects `run` at the sampling edge**: the masked word is not
   counted, the address does not advance, and `load_error` latches.
5. `load_error` is sticky until the next `CS_N` falling edge and now also means
   "a `run` transition aborted a queued word". The host must reload; nothing
   partial or stale reaches instruction memory.

The `host_we` mask and the `W_DONE` abort are both load-bearing: the mask is
what stops a write when `run` rises after `we_r` was set in `W_PULSE`, and the
`W_DONE` check is what keeps accounting and `load_error` honest. The `W_PULSE`
abort is defence in depth and is *not independently observable* given the other
two — the mutation harness documents that and deliberately omits an equivalent
mutation rather than demanding a lie.

## Evidence

**Pre-fix RTL (`39c0eb4:rtl/pe_ctrl.v`), new TB cases:**

| case | window | pre-fix result |
|---|---|---|
| 7a | `run` rises in `W_PULSE` (the review's window) | FAIL: 1 write, 1 while running, word counted, not flagged, reappears |
| 7b | `run` rises with the word queued in `W_IDLE`; **CS_N held low** | FAIL: not flagged, and the queued word writes after `run` falls (`cap_n=1`, `words_written=1`) |
| 7c | `run` rises inside `W_DONE` | FAIL: 1 write while running |

7b's first version raised `CS_N` before the stale check, and the CS rising edge
clears `word_ready` — so it proved the flag but not the deferred write. The
review caught that. The case now keeps `CS_N` low, drops `run`, waits 16 clocks
(the write pipeline is three), asserts `cap_n == 0`, and only then raises
`CS_N`. On the pre-fix RTL it reports `7b: queued word written after run fell
(CS still low)`; the `idle-abort` mutant reports that same assertion directly,
not merely the flag.

**Post-fix:** all cases pass. The TB observes post-edge state (`@(posedge clk);
#1`) so each window is hit deterministically, not by scheduling luck.

**Mutation guards** (`regress/mutate_ctrl_tb.sh`, 11 mutations, 11 detected,
0 survived): the eight protocol mutations plus

- `idle-abort` — remove the `W_IDLE` abort → 7b catches the deferred write
  with `CS_N` still low, and the missing flag;
- `host-we-mask` — remove `& ~run` → 7c catches the write while running;
- `done-run-check` — remove the `W_DONE` abort → 7c catches the false count.

The `run-gate` mutation (receive path) initially survived because the `W_IDLE`
abort masked it; the missing assertion was that an attempted load while running
is *ignored*, not flagged. Case 5 now checks `load_error == 0`, and `run-gate`
is detected.

**Full regression** (`/tmp/run_all_pe_ctrl3.log`): RTL 28/28, firmware 19/19,
lint clean, six mutation suites (i2c, spi, fbuf, eth_mac, eth_soc, ctrl) green,
macro-flow gate and all generated-doc gates green.

**Post-fix synthesis/STA screen** (same scripts as the review, isolated,
unplaced/ideal clock; the reviewer's three-corner rerun at `ef4041d` is the
canonical copy: `pe-ctrl-hardening/synthesis.txt`, `sta-slow.txt`,
`sta-typ.txt`, `sta-fast.txt`):

- Yosys `check -assert`: 0 problems; area 5,791.1 µm² (pre-fix 5,649.8).
- Worst setup slack **+8.71 ns** at the slow corner (typical +8.80, fast +8.86).
- Hold min −0.12/−0.16/−0.19 ns (slow/typical/fast), the `run` input under the
  0 ns minimum input-delay screen assumption; high-fanout violations remain
  pre-physical-repair. The asynchronous SPI inputs are false-pathed as
  synchronizer inputs, as in the review's screen. Synchronizer MTBF and
  hardening are not established; no physical flow, DRC or LVS ran.

## Files

- `rtl/pe_ctrl.v` (abort semantics, `host_we` mask, header)
- `tb/tb_pe_ctrl.v` (cases 5 assertion, 7a/7b/7c)
- `regress/mutate_ctrl_tb.sh` (new), `regress/run_all.sh` (suite registered)
- `reviews/2026-09-23/pe-ctrl-hardening/` (three-corner post-fix screen)
