// formal_pe_eth_tx_reach.v — VACUITY LABELS for the eth_tx safety proof.
//
// A "PROVED" that never reaches the state a claim is about is worse than no
// proof, because it is trusted. This target makes vacuity MACHINE-CHECKED
// instead of asserted in prose: for a selected state it asserts that the state
// is NEVER reached. The expected result is inverted from a normal proof:
//
//   COUNTEREXAMPLE  the state IS reachable within the bound (a model is the
//                   witness) => the corresponding assertion is LIVE at this
//                   depth, and a mutant targeting it must be caught;
//   PROVED          the state is UNREACHABLE within the bound => the
//                   corresponding assertion passes VACUOUSLY here and must be
//                   labelled as such, never reported as a proof.
//
// Why not `cover` statements: this yosys build's `sat` engine cannot model
// $cover cells (verified: "ERROR: No SAT model available for cell $cover"), so
// reachability is stated as a refuted safety claim instead.
//
// SEL (compile-time macro REACH_SEL, default 0)
//   0  a frame is in flight           (tx_busy)      -> P1a's apply edge
//   1  a frame completed              (tx_done)      -> P1b
//   2  the gap is running             (ifg_active)   -> P2
//   3  the gap CLOSES                 (P2's assertion precondition)
//
// Run per selector; see formal/run_formal.sh (`-DREACH_SEL=n`).
`default_nettype none

`ifndef REACH_SEL
  `define REACH_SEL 0
`endif

module formal_pe_eth_tx_reach #(
  parameter int MAX_STORED = 1514
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
  wire push_ready, tx_busy, tx_done, tx_underrun, tx_overlong, ifg_active, tx_bit;

  pe_eth_tx #(.MAX_STORED(MAX_STORED)) dut (
    .clk(clk), .rst_n(rst_n),
    .enable(enable), .cell_start(cell_start), .half_phase(half_phase),
    .push(push), .push_byte(push_byte), .push_ready(push_ready),
    .frame_len(frame_len), .start(start), .frame_abort(frame_abort),
    .tx_busy(tx_busy), .tx_done(tx_done),
    .tx_underrun(tx_underrun), .tx_overlong(tx_overlong),
    .ifg_active(ifg_active), .tx_bit(tx_bit)
  );

  localparam int SEL = `REACH_SEL;

  reg prev_ifg;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) prev_ifg <= 1'b0;
    else        prev_ifg <= ifg_active;
  end

  // "never reached" claims. A model means the state IS reachable.
  always @(posedge clk) begin
    if (rst_n) begin
      case (SEL)
        0: assert (!tx_busy);
        1: assert (!tx_done);
        2: assert (!ifg_active);
        3: if (cell_start) assert (!(prev_ifg && !ifg_active));  // gap closed
        default: assert (1'b0);
      endcase
    end
  end

  always @(*) begin
    if ($initstate) assume (!rst_n);
  end
endmodule

`default_nettype wire
