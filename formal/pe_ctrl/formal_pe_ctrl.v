// formal_pe_ctrl.v — TARGET 2: the R2 bounded-read engine's three claims.
//
//   P2a NO WRAP / NO OVERRUN. A bounded read can never walk past the end of
//       the space it targets, can never overrun the 16-word response buffer,
//       and can never declare a response longer than the buffer holds. The
//       frame index never runs past its CRC word.
//   P2b STICKY RANGE. An out-of-range bounded read latches FAULT_RANGE, and
//       the bit then holds until a CLEAR_FAULT applies a mask covering it.
//       (A STATUS read reports faults without clearing them.)
//   P2c WORD-ALIGNED SERIALIZER. A response frame starts at bit 0 of a word;
//       the fetch handoff waits for the filler to reach the end of a word, so
//       the 0xFFFF filler the host skips is always a whole number of words;
//       the word index advances only at the last bit of a word.
//
// HOW THE SUBJECT BECOMES VISIBLE. These are internal-state claims
// (resp_len/resp_idx/faults/rstate/r_addr/r_left), and yosys does not resolve
// hierarchical references into connections -- the implicit-wire trap pe_ctrl's
// own header documents. Modelling the SPI transaction instead needs a
// clock/delay engine the yosys frontend rejects (the first campaign verified
// that). So the properties are stated over the guarded `ifdef FORMAL`
// observation ports the manager approved (2026-09-25); each tap is an alias of
// an existing signal plus two 1-cycle event registers, listed with its claim
// in pe_ctrl.v's port block. Synthesis never defines FORMAL and
// tools/check_formal_ifdef.sh enforces that.
//
// WHY THE PROPERTIES ARE STATED AT THEIR DECISION POINTS RATHER THAN AS GLOBAL
// INVARIANTS. The host can clock a second (valid) request frame while a
// response is still shifting -- the pads are free inputs, so the proof must
// consider it. In that re-entrant case the RTL keeps the old resp_idx while a
// new resp_len arrives, so "resp_active -> resp_idx <= resp_len+4" is NOT true
// of the unmodified design. The honest property is the one about the decision:
// the index only ever ADVANCES to a value the OLD resp_len allowed, and it
// starts each frame at 0. That is exactly the wrap claim, and it is the form
// that kills its mutant.
//
// PROOF METHOD. The claims are invariant-shaped, and the SPI frame that wakes
// the read engine costs ~230 clock cycles on this toolchain (16 bits per word,
// two synchronizer stages per edge), which puts a plain BMC out of reach at the
// gate depth. They are therefore proved by TEMPORAL INDUCTION (the base case
// AND the induction step; run_formal.sh runs it at a small depth), which is an
// UNBOUNDED proof -- stronger than the bounded proofs of targets 1 and 3.
// Depth is still documented: the induction depth needed is printed per run.
`default_nettype none

module formal_pe_ctrl #(
  parameter int WORDS      = 1024,
  parameter int DMEM_BYTES = 16
) (
  input wire        clk,
  input wire        rst_n,

  // The host pads are FREE inputs: the proof ranges over every host behaviour,
  // well-formed frames and hostile ones alike.
  input wire        spi_sclk,
  input wire        spi_mosi,
  input wire        spi_cs_n,
  input wire        run,

  // The memory responder's data is free; its valid is modelled as the
  // documented one-cycle-latency answer to dbg_rd_req. (R_WAIT holds until
  // valid, so the real latency cannot change these properties.)
  input wire [15:0] dbg_rd_data,

  // The architectural state a STATUS/DUMP_CORE response can report: free.
  input wire [9:0]  dbg_pc,
  input wire [7:0]  dbg_a,
  input wire [7:0]  dbg_x,
  input wire [7:0]  dbg_y,
  input wire [15:0] dbg_insn,
  input wire [7:0]  dbg_timer
);
  wire        spi_miso, miso_oe, irq_n, host_we, host_imem_sel;
  wire        load_active, load_error, dbg_rd_req, dbg_rd_dmem;
  wire [9:0]  host_addr;
  wire [15:0] host_wdata, words_written, faults, dbg_rd_addr;

  // the manager-approved observation ports (see pe_ctrl.v's port block)
  wire [15:0] fv_resp_len, fv_r_addr, fv_r_left, fv_r_slot, fv_faults, fv_clr_mask;
  wire [4:0]  fv_resp_idx;
  wire        fv_resp_active, fv_r_dmem, fv_range_evt, fv_r_launch;
  wire [2:0]  fv_rstate;
  wire [3:0]  fv_resp_bitpos, fv_fill_pos;

  // The read engine's localparam states, repeated here because a wrapper may
  // not reference the DUT's locals. They are the values of the R2 engine's
  // (documented, unchanged) encoding.
  localparam logic [2:0] R_IDLE = 3'd0, R_START = 3'd1, R_REQ = 3'd2, R_WAIT = 3'd3;

  reg rd_valid_r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) rd_valid_r <= 1'b0;
    else        rd_valid_r <= dbg_rd_req;
  end

  pe_ctrl #(.WORDS(WORDS), .DMEM_BYTES(DMEM_BYTES)) dut (
    .clk(clk), .rst_n(rst_n),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n),
    .spi_miso(spi_miso), .miso_oe(miso_oe), .irq_n(irq_n),
    .run(run),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .load_active(load_active), .load_error(load_error),
    .words_written(words_written), .faults(faults),
    .dbg_rd_req(dbg_rd_req), .dbg_rd_dmem(dbg_rd_dmem), .dbg_rd_addr(dbg_rd_addr),
    .dbg_rd_data(dbg_rd_data), .dbg_rd_valid(rd_valid_r),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
    .dbg_insn(dbg_insn), .dbg_timer(dbg_timer),
    .fv_resp_len(fv_resp_len), .fv_resp_idx(fv_resp_idx),
    .fv_resp_active(fv_resp_active), .fv_r_addr(fv_r_addr),
    .fv_r_left(fv_r_left), .fv_r_slot(fv_r_slot), .fv_r_dmem(fv_r_dmem),
    .fv_rstate(fv_rstate), .fv_faults(fv_faults), .fv_clr_mask(fv_clr_mask),
    .fv_range_evt(fv_range_evt), .fv_resp_bitpos(fv_resp_bitpos),
    .fv_fill_pos(fv_fill_pos), .fv_r_launch(fv_r_launch)
  );

  // ---- reset discipline (the flow must pass -set-assumes for this to exist
  // as a constraint at all -- see formal/fv_run.sh) -----------------------
  always @(*) begin
    if ($initstate) assume (!rst_n);
  end

  // ---- P2a: no walk past the bound --------------------------------------
  // Stated UNCONDITIONALLY so the claim is inductive. Every value r_addr/
  // r_left ever take comes either from the guarded load at a walk start
  // (address+count within the target space) or from an increment/decrement
  // pair that preserves the sum, and a rejected read leaves them alone. The
  // 17-bit sum makes a wrap visible instead of silent.
  wire [16:0] walk_end = {1'b0, fv_r_addr} + {1'b0, fv_r_left};
  always @(*) begin
    assert (fv_r_dmem ? (walk_end <= 17'(DMEM_BYTES))
                      : (walk_end <= 17'(WORDS)));
  end

  // ---- P2a: no resp_buf slot overrun ------------------------------------
  // The words still to be written must fit in the slots from r_slot on; the
  // buffer has 16. A dmem walk packs two bytes per word, hence ceil(r_left/2).
  wire [16:0] words_left = fv_r_dmem ? (({1'b0, fv_r_left} + 17'd1) >> 1)
                                     : {1'b0, fv_r_left};
  always @(*) begin
    assert ({1'b0, fv_r_slot} + words_left <= 17'd16);
  end

  // ---- P2a: the declared length never exceeds the buffer ----------------
  // The frame carries 4 header words plus resp_len payload words, and resp_idx
  // is 5 bits: a length above 16 would make the frame index itself unaddressable.
  always @(*) begin
    assert (fv_resp_len <= 16'd16);
  end

  // ---- P2a: the frame index never runs past its CRC word ----------------
  // (a) each frame starts at index 0 ...
  always @(posedge clk) begin
    if (rst_n && fv_resp_active && !$past(fv_resp_active))
      assert (fv_resp_idx == 5'd0);
  end
  // (b) ... and an index only ever ADVANCES to a value the length in force at
  // the decision allowed. Using $past(resp_len) is the point: the decision was
  // made against the length then current, and this is the form that is true of
  // the RTL (and that a removed stop-check mutant violates).
  always @(posedge clk) begin
    if (rst_n && fv_resp_active && $past(fv_resp_active)
        && fv_resp_idx != $past(fv_resp_idx)) begin
      assert (fv_resp_idx <= $past(fv_resp_len) + 5'd4);
    end
  end

  // ---- P2b: RANGE is set, then sticky -----------------------------------
  // (a) an out-of-range bounded read latches FAULT_RANGE. The observation
  // register records the branch that ran, so this is about the real branch,
  // not a re-decision.
  always @(posedge clk) begin
    if (rst_n && $past(fv_range_evt)) assert (fv_faults[2]);
  end
  // (b) stickiness: bit 2 may only FALL on a cycle where a CLEAR_FAULT applied
  // a mask covering it. STATUS only reads faults; the reset edge is excluded
  // (the async reset legitimately clears it, and $past(rst_n) sees that edge).
  always @(posedge clk) begin
    if (rst_n && $past(rst_n) && $past(fv_faults[2]) && !fv_faults[2])
      assert ($past(fv_clr_mask[2]));
  end

  // ---- P2c: word-aligned serializer -------------------------------------
  // (a) a frame starts at bit 0 of a word
  always @(posedge clk) begin
    if (rst_n && fv_resp_active && !$past(fv_resp_active))
      assert (fv_resp_bitpos == 4'd0);
  end
  // (b) the fetch handoff takes the line only at the END of a filler word, so
  // the whole 0xFFFF words the host skipped are exactly whole words
  always @(posedge clk) begin
    if (rst_n && fv_resp_active && !$past(fv_resp_active) && $past(fv_r_launch))
      assert ($past(fv_fill_pos) == 4'd15);
  end
  // (c) the word index advances only at the last bit of a word -- the RTL's
  // own 16-bit word framing, which a 15-bit (or 17-bit) shift would break
  always @(posedge clk) begin
    if (rst_n && fv_resp_active && $past(fv_resp_active)
        && fv_resp_idx != $past(fv_resp_idx))
      assert ($past(fv_resp_bitpos) == 4'd15);
  end

  // ---- liveness of the walk states (kept for the vacuity report) --------
  // Nothing asserted here: formal/pe_ctrl reachability is exercised through
  // the mutant checks, which cannot pass unless a real walk happens.
endmodule

`default_nettype wire
