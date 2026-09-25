# Follow-up review of deferred interface plans — 2026-09-23

## Scope

Read-only audit of `wiki/plans/pe-ctrl-readback.md` and
`wiki/plans/serdes-integration.md` against the current SERDES, codec, DRU, SoC,
wrapper and loader RTL; relevant unit and pad-level tests; existing reviews;
and the mapped synthesis/STA evidence. No RTL, tests, or implementation
artifacts were changed by this review. No physical flow, DRC, or LVS ran.

## Findings

### Decisions that require the user

1. **SERDES integration scope and interface.** The existing plan's seven open
   choices remain open: additive engine versus migration; indexed `0xF` window
   versus widening the ISA; DRU capture versus a second synchronizer; first
   consumer; Manchester output staging; codec topology; and SERDES cadence
   interface. See `wiki/plans/serdes-integration.md`'s open decisions.
2. **Readback contract.** Choose A1/A2/A3, trailing-frame policy, and when MISO
   is enabled/released. See `wiki/plans/pe-ctrl-readback.md`.
3. **Plain asynchronous RX scope.** The planned plain/NRZI/stuffed receive path
   uses a synchronized pin level with a free-running cell strobe. It has no
   start-edge phase acquisition; the existing DRU only recovers Manchester
   phase. This is adequate for the first self-timed loopback, but not an
   arbitrary asynchronous sender. Either scope the first version to loopback
   and sources aligned to the timing block, or authorize phase acquisition.

### Engineering requirements to resolve after scope is accepted

1. **Latch status events for software.** The proposed `STATUS` contains
   `tx_done`, `rx_valid`, and `rx_err`. `tx_done` and `rx_valid` are one-clock
   pulses (`rtl/pe_serdes.v`); Manchester error is also registered for one
   clock, while the bit-stuffer error holds until a later cell clears it
   (`rtl/pe_manch.v`, `rtl/pe_bitstuff.v`). A CPU polling loop can miss these
   events at protocol-dependent intervals. Define sticky set and clear
   semantics and add directed test/mutation coverage. The project's existing
   warning about missed single-cycle events is `wiki/STATUS.md` gotcha 6.
2. **Specify start and clear strobes.** The plan maps `tx_load`, `rx_start`,
   and `clr` as `CTRL` bits. Current `pe_serdes` treats `tx_load` and
   `rx_start` as levels and reloads/restarts while held; codec `clr` is also a
   level. Define one-cycle write-triggered strobes or auto-clear bits, and
   document that data, length and config are written before start.
3. **Define TX completion across a final stuffed cell.** On the last payload
   strobe, `pe_serdes` can drop `tx_busy` while `pe_bitstuff` arms a trailing
   stuff cell for the next codec-cell strobe. Define whether `tx_done` means
   payload consumed or wire idle; ensure the timing block emits the pending
   cell. Add a directed trailing-stuff loopback case.
4. **Preload the first MISO response bit at session start.** Mode 0 samples on
   the first rising edge, before that session has had a falling edge to shift
   MISO. On CS_N falling, preload the first response bit (zero for an empty
   echo) and test a repeated session so the prior session's last bit cannot
   leak into it.
5. **Specify CS setup for the synchronized MISO output enable.** The proposed
   `uio_oe[4] = load_active` uses `load_active = ~cs_s1 && !run` in
   `rtl/pe_ctrl.v`; `cs_s1` is the second synchronizer stage. Thus pad OE
   assertion/release follows CS_N by two `clk` edges. Specify the minimum
   CS_N-to-first-clock setup or choose a faster OE path, then sweep the
   boundary in the pad-level test.
6. **Keep the STA statement precise.** Manchester TX changes its combinational
   output at half-cell boundaries. At 20 MHz with a 60 MHz clock, each
   half-cell interval is 3 clocks (50 ns); `half_phase` is a level, not a
   strobe. That interval alone does not establish a three-cycle STA path
   budget. The implementation's constrained output timing must be checked in
   mapped STA.

## Documentation corrections made

- The SERDES plan no longer claims the project map has a direct CPU-to-SERDES
  edge or a codec-to-pad edge. The map shows CPU access through the window and
  timing control, then codec output through the overlay and pin matrix.
- The readback plan now says SoC port bits 6-7 have unused matrix outputs/OEs,
  while input bit 7 is live for the 10BASE-T DRU via `ui_in[2]`.
- Both plans now state the requirements above for their respective future
  implementations. These edits do not select the open interfaces or authorize
  RTL work.

## Cross-checks that matched

The two codec instances, split TX/RX enables, current-cycle stuff/valid gates,
separate `TXLEN`/`RXLEN`, six-bit length width, seven-suite mutation list, and
current standalone SERDES/codec cell counts match the inspected sources and
records. The readback arithmetic and guard labels match the prior timing audit:
approximately 7.5 MHz (A1) and 7.7 MHz (A2) computed limits, with 2.5/5 MHz
guards; A3 is the rising-edge, non-mode-0 update option. The fresh mapped
`pe_ctrl` STA repeat reproduces the checked-in reports byte-for-byte, with the
documented asynchronous SPI input and unplaced high-fanout caveats.

## Disposition

Keep both designs plan-only until the user resolves the choices above. The
SERDES plan's first wire-loopback can remain self-timed if asynchronous plain
RX is explicitly out of scope. No evidence from this review changes the
project diagrams' planned topology or implementation progress.

## Documentation re-check

An independent verification of the documentation edits found and corrected two
wording errors in the SERDES plan: the overlay-to-pin-matrix order was reversed
in one summary sentence, and the status-event rationale described all codec
errors as one-clock pulses. The sentence now follows the actual
codec -> overlay -> pin-matrix path, and the status rationale distinguishes
one-clock from strobe-gated events. Both corrections were rechecked against
`diagrams/project-plan.puml`, `rtl/pe_serdes.v`, `rtl/pe_manch.v`, and
`rtl/pe_bitstuff.v`.

## Readback host-contract follow-up (2026-09-23)

A fresh read-only source audit checked the readback plan against `pe_ctrl`, the
TT wrapper, the host write path, the instruction-memory ports, pin budget, and
clock arithmetic. The `uio[4]` mapping is free at reset and the commit-latched
echo can be added without changing the existing load path, but the host
contract is not yet complete. No files in RTL or tests changed.

1. **Full-image final word.** With `WORDS=1024`, `pe_ctrl.v` commits address
   1023 in `W_DONE`, increments `words_written`, and sets `load_error` at
   lines 220-224. The receive path at lines 166-168 rejects later SCLK rises
   while that error is set. Reading the just-committed final word requires a
   following frame; the proposed MISO serializer must keep shifting the echo
   despite receive lockout, or the plan must limit its full-image verification
   claim. Add a 1,024-word pad-level test that reads the final echo while
   confirming `load_error` and no extra write.
2. **Duty-cycle bound.** A1/A2 need low time of at least `3 clk + t_pad +
   t_setup` (~65 ns on the plan's assumptions), plus A1's separate commit
   bound. A frequency ceiling alone cannot guarantee that for arbitrary duty
   cycles; e.g. 5 MHz with a 30% low phase gives 60 ns. State a minimum low
   time or a required duty cycle. A3 has separate full-period setup and
   post-sample hold limits.
3. **Rate scope.** If the host is meant to verify every committed word, the
   selected rate bound applies to every frame carrying an echo: one retained
   echo word is replaced by each later commit, so 10 MHz loading followed by a
   slower trailing frame cannot recover all earlier words. A faster load plus
   slow tail only works for a weaker last-word/partial-verification contract
   or with additional storage. The host contract must say which applies.
4. **CS setup.** `load_active = ~cs_s1 && !run` at `pe_ctrl.v:106`; the first
   response bit is planned to preload on detected `cs_fall`. A numeric
   CS_N-to-first-SCLK minimum and pad-level boundary sweep are still needed.
5. **A1/A2 tradeoff.** Computed limits are ~7.5 and ~7.7 MHz. A1 at 5 MHz
   satisfies its `H>=4 clk` commit bound with the same ~50 ns per-bit margin
   as A2, so A2's two-frame latency has little rate benefit at its stated 5 MHz
   guard. Make its reason for the extra latency explicit.

These are plan/contract requirements, not a decision to change the interface.
The user still chooses A1/A2/A3, trailing-frame behavior, and the release
condition. No physical flow, DRC, or LVS was run.

## SERDES decision-readiness follow-up (2026-09-23)

A second read-only audit checked the amended SERDES plan against the current
`pe_serdes`, codec, DRU, pinmux, SoC and unit-test sources. It found no RTL or
plan-topology contradiction and made no file or RTL changes. The audit also
separated four bundled scope choices from engineering details that can be
finalized after scope is accepted:

1. **Milestone:** additive engine, disabled at reset, with a self-timed
   wire-loopback as the first consumer; retain existing personas bit-identical.
   This matches the plan's non-regression contract and avoids introducing a
   frame layer.
2. **Plain asynchronous RX:** exclude arbitrary-phase plain RX from v1; align
   the loopback wire model to the engine cadence. The current DRU only recovers
   Manchester phase, and no plain-mode start-edge acquisition exists.
3. **Topology:** use two existing codec instances, split `pe_serdes` TX/RX
   enables, the current DRU capture path, and the pin-level overlay before the
   open-drain gate. These choices match the current single shared codec and
   SERDES enables, DRU cell strobes, and `pe_pinmux` OE equation.
4. **Access:** use the 4-bit IO space's free `0xF` indexed window for the SoC
   milestone. A block-level loopback before adding CPU access remains a scope
   ordering option; widening the IO field is explicitly out of scope in the
   current plan.

The recommended defaults are evidence-backed recommendations only; none is
selected. Sticky status semantics, write-triggered strobes, trailing-stuff
completion, register details, output staging after STA, tests/mutations and
documentation remain engineering follow-ups. At audit time the plan's
`pe_soc` estimate of 3,298 cells and TT-top estimate of 3,613 were stale. A
subsequent `./regress/synth_area.sh` screen exited 0 and reports 1,354 cells /
19,789.7364 µm² for `pe_eth_mac`, 3,306 / 53,615.5578 µm² for `pe_soc`, and
3,579 / 59,286.8052 µm² for `tt_um_top`; no diagnostics were surfaced by the
script. The plan now uses the current baseline. Full output:
`/tmp/synth_area_diagram_followup.log`. This was mapped synthesis only; no
STA, physical flow, DRC or LVS ran.
