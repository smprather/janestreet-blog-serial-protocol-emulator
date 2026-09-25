// formal_pe_eth_tx_ifg.v — P2 ONLY: the inter-frame gap floor (>= IFG_CELLS
// cell boundaries after every frame's last FCS cell), proved INDUCTIVELY.
//
// WHY A SEPARATE, SINGLE-PURPOSE WRAPPER. The floor cannot be reached by BMC
// on this toolchain: a minimum frame is 64 prelude + 480 data/pad + 32 FCS
// cells and the gap closes 96 cells later, so the interesting state is ~672
// cells in. MEASURED: the shortened-gap mutant SURVIVES at depth 240
// (formal/results/mutant_eth_tx_ifg90.log) and the 700-step run dies at the
// 6 GB memory cap. Per the manager's ruling (2026-09-25) the claim is proved
// by TEMPORAL INDUCTION instead. Induction requires EVERY assertion in the
// target to be inductive, and the sibling wrapper's P1a/P1b/P3 claims are
// keyed on free registers (tx_done, acc_started, start_pend) that an arbitrary
// pre-state may set to anything -- so they are proved bounded in
// formal_pe_eth_tx.v, and only the structural floor claims live here.
//
// THE HELPERS, EACH DERIVABLE FROM ONE TRANSITION (that is what makes the
// induction close; every premise is a DUT-internal signal or a structural
// condition, never a free-running shadow):
//
//   T1  the FCS's LAST cell opens the gap with the counter at 0:
//         state==S_FCS && fcs_left==1 && cell_start && enable  ->  S_IFG, cnt=0
//   T2  while the gap is open the engine's counter and the shadow agree, so
//       "the engine counts the gap" is proved rather than assumed;
//   T3  the gap closes only at the counter's terminal value: the shadow at the
//       close is >= IFG_CELLS-1, so the engine spent the full IFG_CELLS cell
//       boundaries in the gap;
//   T4  a frame is never APPLIED while the gap is open (a tx_busy rise cannot
//       come out of S_IFG), so the next preamble cannot cut the gap short.
//
// T1+T2+T3+T4 = the floor. The ONE documented exception is the `enable` guard:
// losing the codec path abandons the frame (pe_eth_tx's header documents it;
// the SoC refuses to clear tx_path while busy, so the guard covers the eng_en
// route). The mutant check requires the shortened-gap mutant to FAIL here at a
// depth of a few cycles -- a proof that does not kill its mutant is not a proof.
//
// WHY NOT KEY ON tx_done. T1's premise is the FCS's last cell, a STRUCTURAL
// condition. A tx_done-keyed claim is NOT inductive: tx_done is a free register
// in an arbitrary pre-state, so the solver can assert it while the FSM is
// nowhere near the FCS (measured: such a formulation needs >8 induction steps
// and never closes). That is why the DUT exposes fv_state/fv_fcs_left/fv_ifg_cnt
// under `ifdef FORMAL` (manager-approved observation ports).
`default_nettype none

module formal_pe_eth_tx_ifg #(
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
  wire [6:0] fv_ifg_cnt;
  wire [2:0] fv_state;
  wire [5:0] fv_fcs_left;
  wire       fv_abort_pend;

  pe_eth_tx #(.MAX_STORED(MAX_STORED)) dut (
    .clk(clk), .rst_n(rst_n),
    .enable(enable), .cell_start(cell_start), .half_phase(half_phase),
    .push(push), .push_byte(push_byte), .push_ready(push_ready),
    .frame_len(frame_len), .start(start), .frame_abort(frame_abort),
    .tx_busy(tx_busy), .tx_done(tx_done),
    .tx_underrun(tx_underrun), .tx_overlong(tx_overlong),
    .ifg_active(ifg_active), .tx_bit(tx_bit),
    .fv_ifg_cnt(fv_ifg_cnt), .fv_state(fv_state), .fv_fcs_left(fv_fcs_left),
    .fv_abort_pend(fv_abort_pend)
  );

  localparam logic [2:0] S_FCS = 3'd4, S_IFG = 3'd5;    // the engine's encoding
  localparam logic [6:0] IFG_TERM = 7'(IFG_CELLS - 1);  // 95 for 96 cells

  // ---- previous-cycle snapshots (explicit, so every claim reads as one step)
  reg [6:0] gap_run;                    // shadow: gap boundaries counted
  reg       p_ifg_active, p_enable, p_abort_pend, p_cell_start;
  reg [5:0] p_fcs_left;
  reg [2:0] p_state;
  reg [5:0] p_fcs_left;
  reg       busy_d;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gap_run <= 7'd0; busy_d <= 1'b0;
      p_ifg_active <= 1'b0; p_enable <= 1'b0; p_abort_pend <= 1'b0;
      p_cell_start <= 1'b0; p_fcs_left <= 6'd0;
      p_state <= 3'd0; p_fcs_left <= 6'd0;
    end else begin
      if (cell_start) begin
        if (ifg_active) gap_run <= gap_run + 7'd1;
        else            gap_run <= 7'd0;
      end
      busy_d       <= tx_busy;
      p_ifg_active <= ifg_active;
      p_enable     <= enable;
      p_abort_pend <= fv_abort_pend;
      p_cell_start <= cell_start;
      p_fcs_left   <= fv_fcs_left;

      p_state      <= fv_state;
      p_fcs_left   <= fv_fcs_left;
    end
  end

  // ---- reset discipline (fv_run.sh passes -set-assumes; without it this is
  // decoration -- see the flag's note in fv_run.sh) -------------------------
  always @(*) begin
    if ($initstate) assume (!rst_n);
  end

  // ---- T1: the FCS's last cell opens the gap, counter reset ---------------
  always @(*) begin
    if (p_state == S_FCS && fv_state == S_IFG) assert (fv_ifg_cnt == 7'd0);
  end

  // ---- T1b: the gap is MANDATORY after an un-aborted frame end -----------
  // Without this, a mutant that goes straight from the FCS to IDLE (no gap at
  // all) SURVIVES every other claim here (measured: `skip the gap` did exactly
  // that). This is the "frame-end implies ifg_active" half of the manager's
  // helper invariant, in its structural form.
  always @(*) begin
    if (p_state == S_FCS && p_fcs_left == 6'd1 && p_cell_start && p_enable
        && !p_abort_pend) begin
      assert (ifg_active);
    end
  end

  // ---- T2: coupling of the two counters while the gap is open ------------
  always @(*) begin
    if (ifg_active) assert (fv_ifg_cnt == gap_run);
  end

  // ---- T3: the gap closes only at the terminal count, or by ABANDONMENT ---
  // The engine has exactly three ways out of S_IFG: the counter's terminal
  // value, `abort_pend` (the host aborted -- pe_eth_tx documents that an abort
  // does NOT run an IFG), and losing `enable`. The first is the floor; the
  // other two are documented abandonments and are named in the guard, so this
  // claim is exactly "a completed, un-aborted, enabled frame's gap spans the
  // full IFG_CELLS cell boundaries" -- and the induction closes on the engine's
  // own transition instead of on an assumption about reachability.
  always @(*) begin
    if (p_ifg_active && !ifg_active && p_enable && !p_abort_pend)
      assert (gap_run >= IFG_TERM);
  end

  // ---- T4: no frame is applied while the gap is open ---------------------
  always @(*) begin
    if (tx_busy && !busy_d) assert (!p_ifg_active);
  end
endmodule

`default_nettype wire
