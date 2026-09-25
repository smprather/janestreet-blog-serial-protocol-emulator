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
//   * SETTING tx_path is UNCONDITIONAL -- `if (io_wdata[2]) tx_path <= 1'b1;`
//     with no ser_tx_busy term. A TXCTRL write that sets the owner bit during
//     a SERDES transmission therefore steals the codec mid-frame. C2 states
//     the missing guard; the companion refutation target
//     formal_pe_soc_refute.v is expected to FAIL it, and that failure is the
//     machine-checked form of finding F2 in the 2026-09-25 review. It is NOT
//     fixed here: an RTL behaviour change needs the manager's ruling.
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
  wire fv_tx_path, fv_eth_tx_owner, fv_eth_tx_busy, fv_ser_tx_busy;

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
    .fv_eth_tx_busy(fv_eth_tx_busy), .fv_ser_tx_busy(fv_ser_tx_busy)
  );

  // ---- previous-cycle snapshots (explicit; combinational claims only, for
  // the same reason formal_pe_ctrl.v documents: clocked asserts read sampled
  // copies that an arbitrary induction state can set inconsistently) --------
  reg p_tx_path, p_eth_busy, p_ser_busy;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_tx_path <= 1'b0; p_eth_busy <= 1'b0; p_ser_busy <= 1'b0;
    end else begin
      p_tx_path  <= fv_tx_path;
      p_eth_busy <= fv_eth_tx_busy;
      p_ser_busy <= fv_ser_tx_busy;
    end
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
    if (p_tx_path && !fv_tx_path) assert (!p_eth_busy);
  end
endmodule

`default_nettype wire
