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
