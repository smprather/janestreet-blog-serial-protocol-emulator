---
title: pe_ctrl readback path (host response)
created: 2026-09-23
updated: 2026-09-24
type: plan
tags: [boot, loader, pads, observability, verification]
sources: [wiki/decisions/adr-007-pe-ctrl-passive-slave.md, rtl/pe_ctrl.v, rtl/tt_um_protocol_emulator.v, wiki/reference/protocol-pin-budget.md, wiki/STATUS.md]
confidence: high
---

# pe_ctrl readback: evaluating a MISO response

## Status — IMPLEMENTED, option A1 (2026-09-24)

Manager decision: **A1** — one-frame word echo on `uio[4]`, strict mode 0,
host guard rate **2.5 MHz** (computed limit ~7.5 MHz at the A1 commit latch;
2.5 MHz is the chosen guard). The five open decisions at the bottom of this
plan are resolved: (1) **A1**; (2) **one trailing frame**, kept in the same
CS-low session (it writes `0x0000` into the undefined tail; skip it when the
program's own output is the proof); (3) release on **`load_active`** (`CS_N`
low **and** `run` low → pad released); (4) the final committed word of a full
1,024-word image **does** echo through the receive lockout; (5) the numeric
timing contract below; (6) A2's extra latency was not needed — A1 at the
2.5 MHz guard carries ~9 clk of margin over its `H ≥ 4 clk` commit bound.

**The contract, numeric (rulings a–d):**

- every frame whose echo the host samples runs at **SCLK ≤ 2.5 MHz** — the
  ceiling applies to the whole readback transaction, load frames included
  (ruling c);
- minimum SCLK low phase **≥ 100 ns (6 clk at 60 MHz)**; the computed limits
  assume ~50% duty, and the hard bounds are the rate ceiling plus that low
  phase (ruling b);
- `CS_N` → first rising edge **≥ 100 ns** (the OE follows the synchronized
  `CS_N` by 2 clk; the frame-0 bit preloads at the detected `cs_fall`, +3 clk)
  (ruling d);
- frame 0 presents `0x0000` (preloaded at `cs_fall`, so the previous
  session's last bit cannot leak); frame k presents the word committed at
  frame k-1; the echo updates **only** at the `W_DONE` edge where
  `words_written` increments — an aborted word can never echo, and the
  serializer is not gated by `load_error`, so the final word of a full image
  still shifts out (ruling a).

Budget as predicted: committed pads **18 → 19** of 24, free `uio` **4 → 3**,
all-nine shortfall **9 → 10** (debug kept) / **3 → 4** (reclaimed).

Evidence: `tb_pe_ctrl` cases 8–12 with mode-0 stability checks, pad-level
echo in `tb_tt_um_protocol_emulator` (including the full 1,024-word image),
`regress/mutate_ctrl_tb.sh` **23 detected / 0 survived** (11 → 23),
`./regress/run_all.sh --fast -j8` green (29/29, 20/20),
`./regress/synth_area.sh` clean (`pe_ctrl` 463 cells / 8,661.30 µm²,
`tt_um_top` 4,038 / 65,686.27 µm²). Full review:
`reviews/2026-09-24/PE-CTRL-READBACK-REVIEW.md`. No STA refresh has been run
yet (manager-scheduled); no physical flow, DRC or LVS.

## Why

ADR-007 shipped the loader **write-only**: the host cannot confirm words
landed, and the only live observability is the debug PC on `uo_out[7:2]`
(STATUS item 4). ADR-007 calls a read path "a later additive change"; item 4's
revisit trigger names it. The interface choice was **still open** when this
plan was written (it was decided and implemented on 2026-09-24 — see
*Status* above), so this plan fixes the feasible pad/host mapping and the
minimal contract, with options and tradeoffs, before any RTL changes.

## What v1 has

- `rtl/pe_ctrl.v`: mode-0 SPI slave, `ui_in[3]`=SCLK, `ui_in[4]`=MOSI,
  `ui_in[5]`=CS_N; MSB-first 16-bit words; CS low resets the address; every 16
  rising edges writes `imem[addr]`; `run` gates writes; sticky `load_error`;
  `words_written`; `load_active` (selected and stopped).
- Free pads: `ui_in[6:7]` (inputs only), `uio[7:4]` (bidir, released),
  `uo_out` fully committed (UART TX / heartbeat / debug PC). The matrix's
  output and OE for SoC port bits 6-7 are unused; input bit 7 is already used
  for the 10BASE-T DRU through `ui_in[2]`.

## Feasible mapping

MISO is a chip **output**, so it must land on a `uio` pad: `uo_out` has none
free, `ui_in` cannot drive, and the matrix's SPI pads (bits 0-2) are
chip-owned as outputs at reset (ADR-007).

**Recommended: `uio[4]`**, adjacent to the SPI pair on `uio[2:3]`:

| | |
|---|---|
| value | `uio_out[4] = pe_ctrl.spi_miso` |
| enable | `uio_oe[4] = pe_ctrl.load_active` -- driven only while selected and stopped, released otherwise (no reset change: released) |
| loader pads | unchanged: `ui_in[3:5]`; matrix/port contract untouched |

Budget when implemented: committed **18 -> 19** of 24, free `uio` **4 -> 3**;
the all-nine shortfall goes **9 -> 10** (debug kept) / **3 -> 4** (reclaimed)
because the readback is loader overhead, not one of the nine protocols. The
generator recomputes on implementation; nothing is regenerated for this plan.

## Minimal protocol contract (recommended option A: echo)

- Mode 0, MSB-first, 16 bits per frame -- the same framing as the load. The
  load contract is **untouched**: every 16 rising edges still writes a word.
- `spi_miso` changes on the **falling** SCLK edge while selected; released when
  CS_N is high (or `run` is high).
- Because `load_active` follows the synchronized CS_N, the proposed `uio_oe[4]`
  may take two `clk` edges to assert or release after the pad-level CS_N edge.
  The host contract must specify a minimum CS_N-to-first-clock setup time (or
  the implementation must use a faster OE path); sweep this boundary in the
  pad-level test.
- A CS_N falling edge starts a **session**: address 0, `words_written` 0,
  `load_error` clear, and the echo cleared. The trailing frame(s) that read the
  last word(s) back are part of the **same** CS-low session -- `cs_fall` resets
  the address, so a CS toggle between the load and the trailing frames would
  write `imem[0]`/`imem[1]` instead of the tail.
- Frame 0 presents `16'h0000`. Since mode 0 samples on the first rising edge
  before any falling edge in that session, the CS_N falling-edge handling must
  preload the first response bit (zero for the empty echo) before that sample;
  a repeated-session test must ensure the previous session's final bit cannot
  leak into the first bit. The echo is **commit-latched**: the echo register
  captures the completed word only at the `W_DONE` edge where the imem write
  actually commits (`words_written` increments) -- never at `word_ready` and
  never on the `run`-abort path. **An aborted word must never echo.**
- Echo latency, and the SCLK ceiling it buys (see the timing audit):
  - **A1, one frame** (recommended default): frame k presents the word
    committed at frame k-1; readback SCLK **<= 2.5 MHz**.
  - **A2, two frames**: frame k presents the word committed at frame k-2;
    readback SCLK **<= 5 MHz** (a guard margin; the computed limits are
    ~7.5 MHz for A1 and ~7.7 MHz for A2 -- A2 buys commit slack, not rate).
  - **A3, rising-edge update + two frames**: readback SCLK **<= 10 MHz** (guard;
    computed ~15 MHz) -- the only variant that reaches the loader rate; MISO
    changes 2..3 clk after each *rising* edge and holds at least
    `2 clk - t_pad - t_hold` (~23 ns) after the host's sampled edge
    (documented, non-mode-0 change timing).
- A write-only host that ignores MISO is bit-identical to today.
- Reading the last word(s) costs one (A1) or two (A2) trailing frames, which
  write `16'h0000` to `imem[N]`/`imem[N+1]`; the tail past the image is already
  undefined (ADR-007). After a full 1024-word load `load_error` latches and the
  receive path stops, so trailing frames assemble and write nothing; the host
  may skip them when the program's own output is the proof.

## Timing audit (2026-09-23): per-bit ~7.7 MHz; A1's commit latch binds at ~7.5 MHz

Derived from `rtl/pe_ctrl.v` at the worst-case SCLK phase relative to the
60 MHz `clk` (raw edge just after a clk edge; 16.67 ns per cycle). Let H be the
SCLK half period. The chosen architecture updates MISO **after** the
synchronized fall detector, so data is required before the **next rising
sample**, not before the raw falling pad edge -- the earlier A1 claim
(`T/2 >= 6 clk`) got that wrong and is reconciled below.

**A. Per-bit MISO update (every bit).** Raw fall at t = 0; `sclk_s0` at
+1 clk; `sclk_s1` and the fall detector at +2 clk; the MISO register samples
the detector at +3 clk (worst phase) and the pad follows after `t_pad`. The
host samples at the next rise, H later:
`H >= 3 clk + t_pad + t_setup` (~65 ns with ~5 ns pad + ~10 ns setup) -> a
**computed limit of ~7.7 MHz**.

**B. Echo commit (the first bit of the carried word).** The completed word is
registered at +3 clk, but the imem write commits and `W_DONE` runs at **+5..6
clk (worst 6)**. The fall that presents the first echo bit occurs H after the
completing rise; its synchronized register update is at **H + 3 clk** and must
see the commit, so `H + 3 clk >= 6 clk + 1 edge` (the one-edge separation from
the commit flag) -> `H >= 4 clk`. The next host sample is at `2H`, giving
`2H >= H + 3 clk + t_pad + t_setup`. At `H = 4 clk` that leaves about one clk
(~17 ns) for the stated ~5 + ~10 ns pad+setup -- **essentially zero margin** --
so A1's commit latch is the binding term at ~7.5 MHz; the per-bit path alone
is ~7.7 MHz.

- **A2 (two frames)**: the first bit is presented at the fall that follows the
  *next* frame's 16th rise (the first fall of the second frame after the
  commit frame), **16.5 * T_sclk** after the completing rise (one frame plus
  one half bit; `T_frame = 16 * T_sclk`), not 1.5 bit periods and not the
  following frame's 16th fall (31 half-periods = 15.5 * T_sclk). The commit
  constraint becomes `16.5 * T_sclk + 3 clk >= 6 clk + 1 edge` (i.e.
  `16.5 * T_sclk >= 4 clk`), which the per-bit term already dominates.

**Computed limits: A1 ~7.5 MHz, A2 ~7.7 MHz** -- effectively the same rate;
A2 buys commit slack, not bandwidth. Every lower figure is a **chosen guard
margin**, not a computed limit: H = 4 clk (7.5 MHz) is marginal at A1 (~1 clk
before the pad+setup budget); H = 6 clk (5 MHz) leaves ~3 clk (~50 ns) before
it at either latency; **H = 12 clk (2.5 MHz)** leaves ~9 clk (~150 ns) and is
the conservative A1 default. (H = 8 clk would be 3.75 MHz, not 2.5 MHz: at
60 MHz, 2.5 MHz is a 400 ns period = 24 clk, i.e. H = 12 clk.)

**A3, the safe 10 MHz variant (different implementation).** Update MISO on the
synchronized *rising*-edge detector instead: the bit changes 2..3 clk after the
edge the host just sampled with (the earliest change is ~2 clk; the setup
bound below uses the worst 3 clk), so the next sample is a full period away:
`T >= 3 clk + t_pad + t_setup` ≈ 65 ns -- a **computed limit ~15 MHz; 10 MHz
is the chosen guard**. A3 must meet **hold** as well as setup: the guaranteed
hold after the sampled edge is `2 clk - t_pad - t_hold` (with an assumed
~5 ns host hold, ~33 - 5 - 5 = ~23 ns), and the setup before the next rising
edge is `T - (3 clk + t_pad + t_setup)`, ~35 ns at 10 MHz. The commit
(<= 6 clk) fits before the first echo bit one frame later. The cost is a
documented deviation from strict mode-0 change timing (MISO changes after each
rising edge, not on the fall), which must be written into the contract and
tested.

The pad/host terms assume `t_pad ~ 5 ns`, `t_setup ~ 10 ns` and
`t_hold ~ 5 ns`; the ceilings scale with what a board actually adds (the
formula is the record, the numbers are the assumption). Computed limits and
guard frequencies are kept separate throughout: 7.5/7.7/15 MHz computed vs
2.5/5/10 MHz guards.

## Options and tradeoffs

| Option | Logic/pads | Verifies | Cost |
|---|---|---|---|
| **A1. One-frame echo** (recommended default) | 1 `uio`, ~17 flops | every committed word bit-exact, through the shift and write path | readback SCLK <= 2.5 MHz (guard; computed ~7.5 MHz); one trailing frame; no status channel |
| **A2. Two-frame echo** | same + frame tracking | same (commit-latched) | readback SCLK <= 5 MHz (guard; computed ~7.7 MHz); two trailing frames |
| **A3. Rising-edge update, two frames** | same, update on `sclk_rise` | same (commit-latched) | readback SCLK <= 10 MHz (guard; computed ~15 MHz); non-mode-0 change edge; two trailing frames |
| **B. Status frame** | 1 `uio`, ~20 flops | framing, `load_error`, `words_written` live | not the data; `load_error` is cleared at CS fall, so a previous-load status needs a retained copy |
| **C. Peek/poke** | 1 pad + `pe_imem`/`pe_soc` read mux | actual memory contents (imem, later dmem) | the imem macro's one read port is shared with the CPU; a mux/arbiter crosses module boundaries; a command bit breaks "16 rises = a write" |
| **D. Reuse pads** | 0 | -- | impossible: no free `uo_out`; `ui_in` cannot drive; matrix pads are chip-owned at reset |

Recommendation: **A first** -- smallest, additive, backward compatible. B is
additive later if a board wants a status channel; mixing status into the echo
frame is possible but not minimal.

## Test and mutation plan (if A is picked)

1. `tb_pe_ctrl.v`: the host model samples MISO on rising edges and checks
   frame 0 is zero, the echo is the committed word at the chosen latency, bits
   change within ~3 clk after falls (A1/A2) or within ~3 clk after each rise
   (A3), and MISO releases on CS high / `run` high. The host SCLK is **phase-swept relative
   to `clk`** (worst case: an SCLK edge just after a clk edge) at each
   candidate's documented ceiling (A1 2.5 MHz, A2 5 MHz, A3 10 MHz), checking
   MISO is stable at least a clk before every sampling edge. Every existing
   write-only case runs unchanged (non-vacuity: the old behaviour is not
   perturbed).
2. `tb_tt_um_protocol_emulator.v`: pad-level phase -- clock an image through
   `ui_in[3:5]`, read the echo on `uio[4]`/`uio_oe[4]`, then raise `run` and
   check the program executes. The unclaimed-pin monitors narrow from
   `uio[7:4]` to `uio[7:5]` while selected.
3. Probes, each independently detected: echo latched at `word_ready` instead
   of the commit edge; **a word aborted by `run` appearing in the echo**;
   change on the rise instead of the fall for A1/A2 (and on the fall instead
   of the rise for A3); `uio_oe[4]` stuck driven / stuck released; reversed
   bit order; frame 0 not zero; wrong echo latency (one vs two frames); echo
   sourced from `shreg` instead of the completed word. Extend
   `regress/mutate_ctrl_tb.sh` (or add a focused suite) and restore the source
   byte-identically.
4. Screens: `regress/synth_area.sh` (expect ~+17 flops and no wrapper logic);
   the pe_ctrl STA screen if its constraints cover the new output, otherwise
   record the register -> pad path class as with the SPI alias. No physical
   flow, DRC or LVS.

## Read-only contract audit (2026-09-23)

A source-grounded follow-up verified the synchronizer/write-pipeline timing,
the `uio[4]` pad budget, and the existing wrapper and memory interfaces. The
mapping and commit-latched echo architecture are feasible; no interface choice
or RTL implementation was selected. Before implementation, the host contract
needs to close these points:

1. **Full 1,024-word image.** `pe_ctrl` sets sticky `load_error` in `W_DONE`
   when `addr == WORDS-1`, after committing word 1023. Receive then stops
   because `sclk_rise` is gated by `!load_error`. A full-image per-word echo
   still needs the following frame to serialize the last committed word. The
   MISO serializer must be allowed to shift the retained echo while the receive
   side is locked out, or the contract must explicitly exclude that last word
   (and say how a full image is verified). A test should load all 1,024 words
   and check the last echo and `load_error` independently.
2. **Specify SCLK timing by phase.** The A1/A2 fall-update path requires a
   minimum low phase of about `3 clk + t_pad + t_setup` (~65 ns under the
   stated 5 ns / 10 ns assumptions); A1's commit constraint also requires the
   low phase to meet its separate `H >= 4 clk` bound. A frequency ceiling alone
   does not guarantee either when duty cycle can vary. State a minimum low time
   or explicitly require the 50% duty cycle used by the calculations. A3's
   rising-update path needs its full-period setup bound and post-sample hold
   bound.
3. **State what must run at the readback rate.** A one-word echo register
   overwritten by each successful commit can verify every word only if each
   word's response is sampled before the next commit replaces it. Thus a fast
   load followed only by slow trailing frames cannot verify every word unless
   the design adds storage or the host rereads data another way. Decide whether
   the entire per-word echo transaction uses the selected ceiling or whether a
   different partial-verification contract is intended.
4. **Fix a numeric CS-to-first-clock setup.** The output enable follows the
   synchronized CS level, and the initial echo bit is loaded by the detected
   `cs_fall`; the pad-level test must define and sweep a concrete minimum
   CS_N-to-first-SCLK interval. A symbolic requirement is not enough for the
   host contract.
5. **Clarify A1 versus A2's value.** The computed limits are ~7.5 MHz and
   ~7.7 MHz. At 5 MHz, A1's `H=6 clk` clears its `H>=4 clk` commit bound and
   leaves the same ~50 ns per-bit margin as A2. A2's additional frame buys
   little computed rate over A1; decide whether its extra latency/trailing
   frame is justified by an explicit robustness requirement.

The rate figures also assume 50% duty cycle: at 5 MHz with a 30% low phase,
the low interval is only 60 ns and misses the ~65 ns A1/A2 data path bound.
This audit changes the open contract list, not the proposed topology or RTL.
The source checks and detailed disposition are in
`reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`.

## Open decisions for the reviewer

**RESOLVED 2026-09-24 — A1 chosen and implemented; see *Status* at the top.**
The list below is retained as the record of the options that were on the
table.

1. **A1 (one-frame, strict mode 0, readback <= 2.5 MHz guard) vs A2
   (two-frame, strict mode 0, readback <= 5 MHz guard) vs A3 (rising-edge
   update, two frames, readback <= 10 MHz)** -- the computed fall-update
   limits are ~7.5 MHz (A1) and ~7.7 MHz (A2), so the 2.5/5 MHz figures are
   chosen margins; A3 is the only path that reaches 10 MHz, and it documents
   a non-mode-0 change edge.
2. **Trailing frames**: A1 needs one, A2/A3 two (writing `0x0000` into the
   undefined tail); skip them when the program's own output is the proof.
3. **Release condition**: `load_active` (recommended; `run` high also releases)
   vs `~cs_s1` (drives while CS is low even with `run` high).
4. **Full-image proof**: allow the last committed echo to shift during the
   receive lockout after a 1,024-word image, or define a different full-image
   verification contract.
5. **Timing contract**: choose explicit minimum SCLK low time for A1/A2 (or a
   fixed duty-cycle requirement), a full-period and hold bound for A3, a
   numeric CS_N-to-first-clock setup, and whether the selected readback rate
   applies to every load frame.
6. **A2 rationale**: decide whether two-frame latency is justified when A1 at
   5 MHz already meets the stated commit and per-bit constraints with similar
   margin.
