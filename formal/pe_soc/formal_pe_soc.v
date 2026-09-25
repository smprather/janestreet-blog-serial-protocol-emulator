// formal_pe_soc.v — TARGET 4: the codec owner mux (tx_path exclusivity).
//
// WHAT THE DESIGN CLAIMS. pe_soc's arbitration comment says: "a start waits for
// the SERDES TX to be idle (never interleave mid-cell), and the mux swaps
// u_tx_codec's raw input". The mux itself makes "exactly one owner drives the
// codec" structural -- `eth_tx_owner = tx_path ? eth_tx_bit : ser_tx` cannot
// float or drive both. The claim with content is the one about OWNER CHANGES:
// the owner must not move while the engine losing the path is mid-frame.
//
// TWO DIRECTIONS, AND ONLY ONE IS GUARDED.
//   * CLEARING tx_path is refused while the frame engine is busy -- the RTL
//     has `else if (!eth_tx_busy) tx_path <= 1'b0;`. That is C1 below, and it
//     is PROVED here (unbounded, temporal induction).
//   * SETTING tx_path used to be UNCONDITIONAL -- `if (io_wdata[2]) tx_path <=
//     1'b1;` with no ser_tx_busy term, so a TXCTRL write during a SERDES
//     transmission stole the codec mid-frame. That was finding F2, and the
//     manager's ruling (2026-09-25) fixed it: a SET is now REFUSED while
//     ser_tx_busy, exactly as the CLEAR is refused while eth_tx_busy, and the
//     TXSTAT readback reflects the ACTUAL owner. C2 below is the claim that
//     enforces the new guard (it was the refutation target before the fix).
//
// WHY TRANSITION-LOCAL CLAIMS AND WHY NO FIRMWARE PROGRAM. The window writes
// that move the owner come from the CPU's IO bus (io_we/io_port/io_wdata), and
// an instruction memory full of zeros executes no IO at all -- a BMC that
// relies on firmware would be vacuous at every depth. Stating the claims over
// the owner and the two busy wires makes them one-step statements about the
// write logic itself, which is exactly where the guard (or its absence) lives.
`default_nettype none

module formal_pe_soc #(
  parameter int IMEM_WORDS = 1024,
  parameter int DMEM_BYTES = 16
) (
  input wire        clk,
  input wire        rst_n,
  input wire        host_we,
  input wire        host_imem_sel,
  input wire [9:0]  host_addr,
  input wire [15:0] host_wdata,
  input wire        run,
  input wire        dbg_rd_req,
  input wire        dbg_rd_dmem,
  input wire [15:0] dbg_rd_addr,
  input wire [7:0]  pin_in
);
  wire [15:0] dbg_rd_data;
  wire        dbg_rd_valid;
  wire [7:0]  pin_out, pin_oe, dbg_a, dbg_x, dbg_y, dbg_timer;
  wire [9:0]  dbg_pc;
  wire [15:0] dbg_insn;

  // the manager-approved observation ports (see pe_soc.v's port block)
  wire fv_tx_path, fv_eth_tx_owner, fv_ser_busy_seen, fv_eth_busy_seen;
  wire fv_set_took;

  pe_soc #(.IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES)) dut (
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata), .run(run),
    .dbg_rd_req(dbg_rd_req), .dbg_rd_dmem(dbg_rd_dmem),
    .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data),
    .dbg_rd_valid(dbg_rd_valid),
    .pin_in(pin_in), .pin_out(pin_out), .pin_oe(pin_oe),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
    .dbg_insn(dbg_insn), .dbg_timer(dbg_timer),
    .fv_tx_path(fv_tx_path), .fv_eth_tx_owner(fv_eth_tx_owner),
    .fv_ser_busy_seen(fv_ser_busy_seen), .fv_eth_busy_seen(fv_eth_busy_seen),
    .fv_set_took(fv_set_took)
  );

  // ---- previous-cycle snapshots (explicit; combinational claims only, for
  // the same reason formal_pe_ctrl.v documents: clocked asserts read sampled
  // copies that an arbitrary induction state can set inconsistently) --------
  // ONLY tx_path needs a snapshot: the busy values come from the guard's own
  // sampled taps (see pe_soc.v's port comment), which are already aligned with
  // the edge that moved the owner.
  reg p_tx_path;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) p_tx_path <= 1'b0;
    else        p_tx_path <= fv_tx_path;
  end

  always @(*) begin
    if ($initstate) assume (!rst_n);
  end

  // (The other half of exclusivity -- "never two owners, never a float" -- is
  // structural: eth_tx_owner is a 2:1 mux over the two engines' bits, so there
  // is no state in which both drive or neither does. There is nothing to prove
  // beyond the mux's own definition, and inventing a tautological assertion for
  // it would be dressing, not evidence.)

  // ---- C1: the owner is not taken away from a RUNNING frame engine -------
  // A falling tx_path is only possible on a TXCTRL write whose clear arm ran,
  // and that arm is gated by !eth_tx_busy. One-step, so the induction closes.
  always @(*) begin
    if (p_tx_path && !fv_tx_path) assert (!fv_eth_busy_seen);
  end

`ifndef FV_INDUCT
  // ---- C2: the owner is not taken away from a RUNNING SERDES (F2's fix) ---
  // LABELLED: checked at the gate depth, but NOT closed by induction on this
  // toolchain. The guard and the observed busy value are separate sampling
  // chains in yosys's clk2fflogic model (the same artifact that made the
  // pe_ctrl clocked claims non-inductive), so an arbitrary pre-state can make
  // "the guard was refused" and "the busy value was low" disagree. The
  // ENFORCEMENT for F2 is therefore the directed TB case in
  // tb_pe_soc_eth_loop.v (run_owner_probe: a TXCTRL claim during a live SERDES
  // transmission must leave the codec with the SERDES and the frame intact)
  // plus the `owner-set-guard-removed` mutation in
  // regress/mutate_eth_tx_loop_tb.sh, which the TB catches.
  always @(*) begin
    if (!p_tx_path && fv_tx_path) assert (!fv_ser_busy_seen);
  end
  // The same claim in the block's OWN terms (the form the manager's ruling
  // states: the set only TAKES when the SERDES is idle).
  always @(*) begin
    if (fv_set_took) assert (!fv_ser_busy_seen);
  end
`endif
endmodule

`default_nettype wire
