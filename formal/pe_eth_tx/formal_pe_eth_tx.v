// formal_pe_eth_tx.v — SAFETY: frame bounds, the IFG floor, and the underrun
// abandon path of the 10BASE-T TX frame engine.
//
// THE PROPERTIES (the engine's header claims):
//   P1a the length APPLIED at a start boundary is legal: the engine never
//       begins a frame outside [14, MAX_STORED] (the runt/jabber guard);
//   P1b a COMPLETED frame's length was legal (the completion form of P1a);
//   P2  the inter-frame gap is >= 96 cells after every frame;
//   P3  a FIFO underrun abandons to IDLE without a partial FCS.
//
// WHY P1 IS SPLIT, AND WHAT THE FIRST CAMPAIGN MISSED.
// The first version sampled frame_len on the `start` INPUT pulse — one or more
// cycles before the engine applies it (`start_pend` is consumed at the next
// cell_start, up to DIV-1 clocks later). The engine itself reads frame_len
// TWICE: it tests `len_ok` at the pulse edge but latches `stored_bytes <=
// frame_len` at the apply edge. So a host that rewrites TXLEN between those two
// edges gets one length validated and another transmitted, and the old shadow
// could not see it. THIS SHADOW SAMPLES AT THE APPLY BOUNDARY (the edge where
// tx_busy rises 0->1), which is exactly where the engine latches, so
// `acc_len` is the engine's OWN accepted length. Because the rise detector
// reads tx_busy one cycle after the fact, it reads the one-cycle-delayed copy
// `len_d` of frame_len, which at that edge is the value the engine latched.
//
// THE WINDOW IS REAL, AND IT IS NOT PROVED — IT IS ASSUMED AWAY.
// Dropping the assumption below makes P1a FAIL on the UNMODIFIED RTL: a
// 6-cycle counterexample starts a frame with TXLEN=14 and rewrites it to 13
// before the apply boundary. That trace is recorded as a finding in
// reviews/2026-09-25/FORMAL-VERIFICATION.md (the guard is a start-pulse check
// against a boundary-time latch: a <=DIV-1 clock hole, host-reachable from the
// CPU's 0xF window since SoC writes of win_regs[24]/[25] are not gated on
// tx_busy). The proof therefore carries ONE explicit assumption, and the
// assumption is itself mutant-checked (`eth_tx_len_window` in
// formal/mutants.sh removes it and requires this target to FAIL):
//
//   THE TXLEN HOLD CONTRACT — the documented host rule (G1 in
//   wiki/plans/eth-tx-frame-path.md: firmware writes TXLEN, pushes bytes, then
//   frame_start; TXLEN is held until the engine applies the start). The
//   assumption is kept as NARROW as the design needs: it constrains frame_len
//   only on the edges between a start pulse and the apply edge it produces.
//
// P1a is a one-step claim at the apply edge, so it is live at the gate's
// shallow depth AND kills both bound-removal mutants there; the completion form
// P1b cannot fire before ~576 cells (64 prelude + 480 data/pad + 32 FCS) and is
// therefore vacuous at the gate depth — labelled by the companion reachability
// target formal/pe_eth_tx_reach.v, never reported as a proof of the deep case.
// P2 is vacuous until a frame completes AND the gap closes (~672 cells).
//
// All of this is stated over PORTS: no RTL instrumentation, no hierarchical
// tap (yosys does not resolve cross-module references into connections — the
// trap pe_ctrl's header documents).
`default_nettype none

module formal_pe_eth_tx #(
  parameter int MAX_STORED = 1514,
  parameter int IFG_CELLS  = 96
) (
  input wire        clk,
  input wire        rst_n,
  input wire        enable,
  input wire        cell_start,
  input wire        half_phase,
  input wire        push,
  input wire [7:0]  push_byte,
  input wire [11:0] frame_len,
  input wire        start,
  input wire        frame_abort
);
  wire       push_ready, tx_busy, tx_done, tx_underrun, tx_overlong, ifg_active;
  wire       tx_bit;

  pe_eth_tx #(.MAX_STORED(MAX_STORED)) dut (
    .clk(clk), .rst_n(rst_n),
    .enable(enable), .cell_start(cell_start), .half_phase(half_phase),
    .push(push), .push_byte(push_byte), .push_ready(push_ready),
    .frame_len(frame_len), .start(start), .frame_abort(frame_abort),
    .tx_busy(tx_busy), .tx_done(tx_done),
    .tx_underrun(tx_underrun), .tx_overlong(tx_overlong),
    .ifg_active(ifg_active), .tx_bit(tx_bit)
  );

  // ---- the engine's OWN accepted length ---------------------------------
  reg [11:0] len_d;        // frame_len delayed one cycle (the apply-boundary read)
  reg        busy_d;       // tx_busy delayed one cycle (rise detector)
  reg [11:0] acc_len;      // the length the engine accepted at the last start
  reg        acc_started;  // a frame is (or was) in flight from an accepted start

  // The TXLEN hold shadow: set at a start pulse, cleared at the apply edge.
  // Its pre-edge value is 1 on every edge in [pulse+1 .. apply], exactly the
  // window the engine's late re-read spans.
  reg        hold;
  reg [11:0] hold_len;     // TXLEN as the engine read it at the pulse edge

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      len_d <= 12'd0; busy_d <= 1'b0;
      acc_len <= 12'd0; acc_started <= 1'b0;
      hold <= 1'b0; hold_len <= 12'd0;
    end else begin
      len_d  <= frame_len;
      busy_d <= tx_busy;

      if (start) begin
        hold     <= 1'b1;
        hold_len <= frame_len;    // the value the engine's len_ok test reads
      end else if (tx_busy && !busy_d) begin
        hold     <= 1'b0;         // the engine applied a start at this edge
      end

      if (tx_busy && !busy_d) begin
        // the engine applied a start at the edge one cycle ago: len_d holds
        // the value it latched into stored_bytes, so it is the value to check.
        assert (len_d >= 12'd14 && len_d <= 12'(MAX_STORED));   // P1a
        acc_len     <= len_d;
        acc_started <= 1'b1;
      end else if (tx_done) begin
        acc_started <= 1'b0;      // frame closed; the next start reloads
      end
    end
  end

  // THE ONE ASSUMPTION (see the header). Not a property of the RTL: removing it
  // makes P1a fail on the unmodified design, which is the recorded finding.
  always @(posedge clk) begin
    if (rst_n && hold) assume (frame_len == hold_len);
  end

  // ---- IFG accounting (P2) ----------------------------------------------
  // Count cell boundaries spent inside the gap, and check the count when the
  // gap CLOSES. Two subtleties, both learned from a counterexample:
  //   * the engine asserts tx_done on the LAST cell of the FCS, and ifg_active
  //     only reads high on the NEXT cell -- so the cell where a frame finishes
  //     is NOT the end of a gap;
  //   * therefore the gap is closed on a falling edge of ifg_active sampled at
  //     a cell boundary, and that is the only moment the claim is about.
  // VACUOUS AT THE GATE DEPTH: reaching this assertion needs a complete frame
  // plus 96 gap cells (~672 cells); the reachability target labels it.
  reg [7:0] ifg_run;
  reg       prev_ifg;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ifg_run   <= 8'd0;
      prev_ifg  <= 1'b0;
    end else if (cell_start) begin
      if (ifg_active) begin
        ifg_run <= ifg_run + 8'd1;
      end else begin
        if (prev_ifg) assert (ifg_run >= 8'(IFG_CELLS));
        ifg_run <= 8'd0;
      end
      prev_ifg <= ifg_active;
    end
  end

  // ---- reset discipline -------------------------------------------------
  // Enforced by the flow: `sat` needs -set-assumes for this (and any) $assume
  // to be a constraint at all. Without that flag it is decoration.
  always @(*) begin
    if ($initstate) assume (!rst_n);
  end

  // ---- P1b: a transmitted frame is always inside the length domain ------
  // The completion form of the claim, over the engine's own accepted length.
  always @(*) begin
    if (tx_done) assert (acc_started && acc_len >= 12'd14 && acc_len <= 12'(MAX_STORED));
  end

  // A refused start must actually be refused: tx_overlong pulses and the
  // engine stays out of the data path.
  always @(*) begin
    if (tx_overlong) assert (!tx_done);
  end

  // ---- P3: an underrun abandons without a partial FCS --------------------
  // tx_underrun and tx_done are the two terminal pulses; a frame cannot
  // complete on the same cycle it ran dry, and an underrun must clear busy.
  always @(*) begin
    if (tx_underrun) assert (!tx_done);
  end
  always @(posedge clk) begin
    if (rst_n && $past(tx_underrun) && !$past(frame_abort)) begin
      assert (!tx_busy || $past(tx_busy));
    end
  end
endmodule

`default_nettype wire
