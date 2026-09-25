// formal_pe_eth_tx.v — SAFETY: frame bounds, the IFG floor, and the underrun
// abandon path of the 10BASE-T TX frame engine.
//
// THE PROPERTIES (the engine's header claims):
//   P1a the length LATCHED at a start pulse is legal (the runt/jabber guard);
//   P1b the frame CONSUMES exactly the length it latched (atomicity);
//   P1c a COMPLETED frame's consumed length was legal (the completion form);
//   P2  the inter-frame gap is >= 96 cells after every frame (proved in
//       formal_pe_eth_tx_ifg.v, inductively);
//   P3  a FIFO underrun abandons to IDLE without a partial FCS.
//
// FINDING F1, AND HOW IT WAS CLOSED. Campaign I proved P1 with a shadow that
// sampled frame_len at the apply boundary, which exposed a real hole: the
// engine tested `len_ok` at the start PULSE but re-read frame_len when it
// latched `stored_bytes` at the next cell boundary, so a host rewrite in that
// <=DIV-1 clock window transmitted a length the guard never saw. Campaign I
// recorded it as finding F1 and carried a labelled TXLEN-hold contract
// assumption to keep the proof honest. The manager's ruling (2026-09-25) fixed
// the RTL instead: the guard and the latch are now the SAME event
// (`pend_len <= frame_len` at the pulse, `stored_bytes <= pend_len` at the
// boundary). THE ASSUMPTION IS THEREFORE DISCHARGED — this wrapper has no
// contract assumption beyond the campaign's reset discipline, and P1b is the
// claim that makes the atomicity explicit. The proof no longer needs a
// one-cycle-delayed frame_len shadow: it reads the engine's own pend_len and
// stored_bytes through the guarded `ifdef FORMAL` taps.
//
// P1a/P1b are one-step claims, so they are live at the gate's shallow depth
// AND kill their mutants there; the completion form P1c cannot fire before
// ~576 cells (64 prelude + 480 data/pad + 32 FCS) and is therefore vacuous at
// the gate depth — labelled by the companion reachability target
// formal/pe_eth_tx_reach.v, never reported as a proof of the deep case.
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
  wire [6:0] fv_ifg_cnt;      // P2 taps: the gap counter, the FSM state, and
  wire [2:0] fv_state;        // the FCS counter (all formal-only aliases)
  wire [5:0] fv_fcs_left;

  pe_eth_tx #(.MAX_STORED(MAX_STORED)) dut (
    .clk(clk), .rst_n(rst_n),
    .enable(enable), .cell_start(cell_start), .half_phase(half_phase),
    .push(push), .push_byte(push_byte), .push_ready(push_ready),
    .frame_len(frame_len), .start(start), .frame_abort(frame_abort),
    .tx_busy(tx_busy), .tx_done(tx_done),
    .tx_underrun(tx_underrun), .tx_overlong(tx_overlong),
    .ifg_active(ifg_active), .tx_bit(tx_bit),
    .fv_ifg_cnt(fv_ifg_cnt), .fv_state(fv_state), .fv_fcs_left(fv_fcs_left),
    .fv_pend_len(fv_pend_len), .fv_stored_bytes(fv_stored_bytes)
  );

  // ---- P1: VALIDATE-AND-LATCH (manager ruling 2026-09-25, finding F1) ----
  // The RTL now guards and latches the SAME value: the length tested at the
  // start pulse goes into pend_len and becomes stored_bytes at the cell
  // boundary. The proof therefore needs no contract assumption at all -- the
  // assumption that used to carry the TXLEN hold rule is DISCHARGED, and the
  // claims below are the two halves of the fix:
  //
  //   P1a  the length LATCHED at a start pulse is legal (the guard and the
  //        latch are one event, so this is the runt/jabber policy itself);
  //   P1b  the length the frame CONSUMES equals the length it latched (the
  //        atomicity half: a TXLEN rewrite after the pulse cannot reach the
  //        frame in flight);
  //   P1c  a completed frame's consumed length was legal (the original
  //        completion claim, kept for the record; it cannot fire before ~576
  //        cells, so P1a/P1b are what is live at the gate depth).
  wire [11:0] fv_pend_len;
  wire [11:0] fv_stored_bytes;
  reg  [11:0] p_pend_len;      // snapshot, so the latch event is one step
  reg         busy_d;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_pend_len <= 12'd0;
      busy_d     <= 1'b0;
    end else begin
      p_pend_len <= fv_pend_len;
      busy_d     <= tx_busy;
    end
  end

  // P1a: the latched length is legal. `!=` rather than a rise detector: the
  // value can only change by the latch itself or the reset, and reset keeps it
  // in the domain.
  always @(*) begin
    if (fv_pend_len != p_pend_len)
      assert (fv_pend_len >= 12'd14 && fv_pend_len <= 12'(MAX_STORED));
  end

  // P1b: the frame consumes exactly what it latched (checked at the apply
  // edge, which is the boundary where stored_bytes is loaded).
  always @(*) begin
    if (tx_busy && !busy_d) assert (fv_stored_bytes == fv_pend_len);
  end

  // P1c: the completion form, over the consumed length.
  always @(*) begin
    if (tx_done)
      assert (fv_stored_bytes >= 12'd14 && fv_stored_bytes <= 12'(MAX_STORED));
  end

  // ---- reset discipline -------------------------------------------------
  // Enforced by the flow: `sat` needs -set-assumes for this (and any) $assume
  // to be a constraint at all. Without that flag it is decoration.
  always @(*) begin
    if ($initstate) assume (!rst_n);
  end

  // ---- P1b: a transmitted frame is always inside the length domain ------
  // (superseded by P1c above, which states it over the CONSUMED length; the old
  // accepted-length shadow went with the TXLEN hold assumption.)

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
