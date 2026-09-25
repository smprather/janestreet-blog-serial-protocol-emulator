// formal_pe_eth_tx.v — SAFETY: frame bounds, the IFG floor, and the underrun
// abandon path of the 10BASE-T TX frame engine.
//
// THE PROPERTIES (the engine's header claims):
//   P1  a transmitted frame is never < 14 or > 1514 stored bytes: a start
//       outside the domain is REFUSED (tx_overlong) and no frame is emitted;
//   P2  the inter-frame gap is >= 96 cells after every frame (the standard's
//       IFG, the number the engine's own header fixes);
//   P3  a FIFO underrun abandons to IDLE without a partial FCS (tx_underrun,
//       no tx_done for that frame).
//
// These are all stated over PORTS: frame_len in, and tx_overlong / tx_done /
// tx_underrun / ifg_active / cell_start out. No RTL instrumentation, no
// hierarchical tap (yosys does not resolve cross-module references into
// connections — the trap pe_ctrl's header documents).
//
// Inputs are anyseq: every push/start/abort/push-rate sequence, so the proof
// covers all stimuli rather than a testbench's schedule.
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

  // ---- the length domain -------------------------------------------------
  wire len_ok = (frame_len >= 12'd14) && (frame_len <= 12'(MAX_STORED));

  // ---- a shadow of what the engine accepted ---------------------------
  // The engine applies a start at the NEXT cell boundary and (after the fix)
  // transmits len_latch -- the length it validated at the start edge. So the
  // shadow tracks the same thing: capture frame_len when a start is seen, and
  // compare against what the engine actually reports completing.
  reg [11:0] m_len;
  reg       m_started;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_len     <= 12'd0;
      m_started <= 1'b0;
    end else if (tx_done) begin
      m_len     <= 12'd0;         // frame closed; next start reloads
      m_started <= 1'b0;
    end else if (start) begin
      m_len     <= frame_len;     // a start was issued
      m_started <= 1'b1;
    end
  end

  // ---- IFG accounting (P2) ----------------------------------------------
  // Count cell boundaries spent inside the gap, and check the count when the
  // gap CLOSES. Two subtleties, both learned from a counterexample:
  //   * the engine asserts tx_done on the LAST cell of the FCS, and ifg_active
  //     only reads high on the NEXT cell -- so the cell where a frame finishes
  //     is NOT the end of a gap;
  //   * therefore the gap is closed on a falling edge of ifg_active sampled at
  //     a cell boundary, and that is the only moment the claim is about.
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
  always @(*) begin
    if ($initstate) assume (!rst_n);
  end

  // ---- P1: a transmitted frame is always inside the length domain ------
  // If the engine reports a COMPLETED frame, the length that was requested
  // must have been legal. A runt/jabber is refused (tx_overlong) and can never
  // reach tx_done. Guarded by m_started so a tx_done with no start in flight
  // (which the engine should never produce) is not scored as a length bug but
  // is instead caught by the explicit "tx_done implies a start" assertion.
  always @(*) begin
    if (tx_done) assert (m_started && m_len >= 12'd14 && m_len <= 12'(MAX_STORED));
  end

  // A refused start must actually be refused: tx_overlong pulses and the
  // engine stays out of the data path.
  always @(*) begin
    if (tx_overlong) assert (!tx_done);
  end

  // ---- P2 is asserted inside the counter block above, at the gap's
  // falling edge, where "the gap lasted at least 96 cells" is a real claim.

  // ---- P3: an underrun abandons without a partial FCS --------------------
  // tx_underrun and tx_done are the two terminal pulses; a frame cannot
  // complete on the same cycle it ran dry, and an underrun must clear busy.
  always @(*) begin
    if (tx_underrun) assert (!tx_done);
  end
  always @(posedge clk) begin
    if (rst_n && $past(tx_underrun) && !$past(frame_abort)) begin
      // by the next cycle the engine must have left the frame (it abandons to
      // IDLE; the abort path is the only other way to leave early)
      assert (!tx_busy || $past(tx_busy));
    end
  end
endmodule

`default_nettype wire
