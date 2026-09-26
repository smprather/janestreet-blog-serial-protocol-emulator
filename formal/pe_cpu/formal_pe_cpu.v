// formal_pe_cpu.v — R3 DEBUG CONTROL at the core: single-step and debug hold.
//
// THE CLAIMS (the R3 contract, reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md):
//   S1  a step commits EXACTLY ONE instruction: on the cycle after a dbg_step
//       pulse the PC equals the landing address the core computed (next_pc);
//   S2  a debug hold PRESERVES the PC: while dbg_hold is high and no step is in
//       flight and the strap is low, the PC does not change, and no side effect
//       (io_we/io_re/dmem_we) is asserted;
//   S3  the PC only ever ADVANCES on an execute cycle (a strap cycle or a step
//       cycle) -- so while held, nothing commits;
//   S4  the boot stop still holds the PC at 0 (R2's read-arbitration
//       precondition must not regress).
//
// Shape: combinational asserts over explicit previous-cycle snapshots, proved by
// temporal induction (unbounded) through formal/fv_run.sh. The whole point is
// local -- the execute gate, the PC update and the fetch address -- so the
// claims close from ONE transition each.
`default_nettype none

module formal_pe_cpu #(
  parameter int IMEM_WORDS = 16,
  parameter int DMEM_BYTES = 16
) (
  input wire        clk,
  input wire        rst_n,
  input wire        run,
  input wire        dbg_hold,
  input wire        dbg_step,
  input wire [15:0] imem_rdata,   // free: every instruction, every opcode
  input wire [7:0]  dmem_rdata,
  input wire [7:0]  io_rdata
);
  localparam int IAW = (IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS);
  localparam int DAW = (DMEM_BYTES <= 2) ? 1 : $clog2(DMEM_BYTES);
  localparam int PCW = (IAW > 8) ? IAW : 8;

  wire [IAW-1:0] imem_addr;
  wire [DAW-1:0] dmem_addr;
  wire           dmem_we, io_we, io_re;
  wire [7:0]     dmem_wdata, io_wdata;
  wire [3:0]     io_port;
  wire [PCW-1:0] dbg_pc, dbg_next_pc;
  wire [7:0]     dbg_a, dbg_x, dbg_y;
  wire [15:0]    dbg_insn;

  pe_cpu #(.IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES)) dut (
    .clk(clk), .rst_n(rst_n), .run(run),
    .dbg_hold(dbg_hold), .dbg_step(dbg_step),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_addr(dmem_addr), .dmem_we(dmem_we), .dmem_wdata(dmem_wdata),
    .dmem_rdata(dmem_rdata),
    .io_port(io_port), .io_we(io_we), .io_re(io_re),
    .io_wdata(io_wdata), .io_rdata(io_rdata),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
    .dbg_insn(dbg_insn), .dbg_next_pc(dbg_next_pc)
  );

  // ---- previous-cycle snapshots (explicit: one register per signal, so the
  // induction has a single coherent state to close over) -------------------
  reg [PCW-1:0] p_pc, p_next;
  reg           p_hold, p_step, p_run, p_exec, p_rst_n;

  wire exec_now = dbg_step || (run && !dbg_hold);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_pc <= {PCW{1'b0}}; p_next <= {PCW{1'b0}};
      p_hold <= 1'b0; p_step <= 1'b0; p_run <= 1'b0; p_exec <= 1'b0;
      p_rst_n <= 1'b0;
    end else begin
      p_pc   <= dbg_pc;
      p_next <= dbg_next_pc;
      p_hold <= dbg_hold;
      p_step <= dbg_step;
      p_run  <= run;
      p_exec <= exec_now;
      p_rst_n <= rst_n;
    end
  end

  always @(*) begin
    if ($initstate) assume (!rst_n);
  end

  // ---- S2: a held, non-stepping, non-running cycle preserves the PC -------
  always @(*) begin
    if (p_rst_n && p_hold && !p_step && !p_run) assert (dbg_pc == p_pc);
  end

  // ---- S1: a step lands exactly on the address the core computed ----------
  // One pulse, one PC update, to the value the fetch-ahead already named.
  always @(*) begin
    if (p_rst_n && p_step) assert (dbg_pc == p_next);
  end

  // ---- S3: the PC changes ONLY by executing, or by the boot stop's re-zero -
  // Two legitimate ways the PC moves: an execute cycle (a strap cycle or a
  // step) advances it to next_pc, and the boot stop (no strap, no hold, no
  // step) pins it back to 0. Nothing else may touch it -- so while held, it is
  // frozen.
  always @(*) begin
    if (p_rst_n && dbg_pc != p_pc)
      assert (p_exec || (!p_run && !p_hold && !p_step));
  end

  // ---- S2 (side effects): a held core commits nothing --------------------
  always @(*) begin
    if (rst_n && dbg_hold && !dbg_step && !run)
      assert (!dmem_we && !io_we && !io_re);
  end

  // ---- S4: the boot stop still pins the PC at 0 --------------------------
  // The PC register zeroes one edge AFTER the strap falls (the RTL addresses
  // zero immediately for the fetch, but the register itself takes an edge),
  // so the claim is about the cycle after the stop -- which is also the state
  // R2's read arbitration relies on.
  always @(*) begin
    if (p_rst_n && !p_run && !p_hold && !p_step)
      assert (dbg_pc == {PCW{1'b0}});
  end
endmodule

`default_nettype wire
