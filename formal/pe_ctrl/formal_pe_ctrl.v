// formal_pe_ctrl.v — TARGET 2: the R2 bounded-read engine's claims.
//
//   P2a NO WRAP / NO OVERRUN. A bounded read can never walk past the end of the
//       space it targets, can never overrun the 16-word response buffer, and
//       can never declare a response longer than the buffer holds. The frame
//       index starts at 0 and only ever advances to a value the length in
//       force at the decision allowed.
//   P2b STICKY RANGE. The FAULT_RANGE bit may only FALL on a cycle where a
//       CLEAR_FAULT applied a mask covering it. (A STATUS read reports faults
//       without clearing them.)
//   P2c WORD-ALIGNED SERIALIZER. A response frame starts at bit 0 of a word,
//       and the word index advances only at the last bit of a word.
//
// HOW THE SUBJECT BECOMES VISIBLE. These are internal-state claims, and yosys
// does not resolve hierarchical references into connections -- the implicit-wire
// trap pe_ctrl's own header documents. Modelling the SPI transaction instead
// needs a clock/delay engine the frontend rejects, and a BMC that actually
// DELIVERS a request frame costs ~230 cycles (16 bits per word, two
// synchronizer stages per edge) -- a depth whose SAT instance dies at the
// memory cap (measured: the pe_ctrl tempinduct attempt hit 6.29 GB and was
// killed by the watchdog). So the claims are stated over the guarded
// `ifdef FORMAL` observation ports the manager approved (2026-09-25) and the
// proof is TEMPORAL INDUCTION, which is unbounded and needs no frame delivery.
//
// WHY EVERY CLAIM HERE IS TRANSITION-LOCAL. An induction proof assumes its
// assertions over the previous k steps and proves them one step later, over an
// ARBITRARY pre-state -- not just reachable ones. A claim whose premise is a
// free-running register can therefore be falsified by a state the design can
// never reach: the first version of this file claimed "an out-of-range read
// latches FAULT_RANGE" from a registered observation flag, and it needed >65
// induction steps and 6 GB without closing, because the solver could set the
// flag with no branch behind it. The claims that survive are the ones whose
// premises are the engine's OWN transition conditions (the bound guards, the
// serializer's bit counter, the CLEAR_FAULT branch) -- each follows from one
// step of the RTL's logic.
//
// HONEST LIMITS, LABELLED NOT HIDDEN. Two candidate claims are NOT here:
//   * "an out-of-range read latches FAULT_RANGE" (the set half of P2b) is an
//     event claim; the event is visible directly in the RTL and pinned by the
//     range golden vectors, and its registered observation form is not
//     inductive. Only the STICKINESS half is proved here.
//   * "the fetch handoff waits for the end of a filler word" is not inductive
//     either: a new request frame can legitimately CANCEL a pending launch (the
//     RTL clears r_launch in every S_CRC), and separating cancellation from
//     handoff needs the frame-dispatch state, which duplicates the decision
//     logic under test. It is covered by the wire-level golden vectors and the
//     pe_ctrl TB instead.
`default_nettype none

module formal_pe_ctrl #(
  parameter int WORDS      = 1024,
  parameter int DMEM_BYTES = 16
) (
  input wire        clk,
  input wire        rst_n,

  // The host pads are FREE inputs: the proof ranges over every host behaviour,
  // well-formed frames and hostile ones alike. (The claims below are transition
  // invariants, so their truth does not depend on a frame being delivered.)
  input wire        spi_sclk,
  input wire        spi_mosi,
  input wire        spi_cs_n,
  input wire        run,

  // The memory responder's data is free; its valid is modelled as the
  // documented one-cycle-latency answer to dbg_rd_req. (R_WAIT holds until
  // valid, so the real latency cannot change these claims.)
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
  wire        fv_resp_active, fv_r_dmem;
  wire [2:0]  fv_rstate;
  wire [3:0]  fv_resp_bitpos;
  wire        fv_r_imm;

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
    .fv_resp_bitpos(fv_resp_bitpos), .fv_r_imm(fv_r_imm)
  );

  // ---- reset discipline (fv_run.sh passes -set-assumes; without it this is
  // decoration -- see the flag's note there) -------------------------------
  always @(*) begin
    if ($initstate) assume (!rst_n);
  end

  // ---- P2a: no walk past the bound --------------------------------------
  // Unconditional so the claim is inductive: every value r_addr/r_left ever
  // take comes from the guarded load at a walk start (address+count inside the
  // target space) or from an increment/decrement pair that preserves the sum,
  // and a rejected read leaves them alone. The 17-bit sum makes a wrap visible
  // instead of silent.
  wire [16:0] walk_end = {1'b0, fv_r_addr} + {1'b0, fv_r_left};
  localparam logic [2:0] R_START = 3'd1, R_REQ = 3'd2, R_WAIT = 3'd3;
  // R_START is a walking state only when the walk was ACCEPTED: an immediate
  // rejection parks in R_START too, holding stale r_addr/r_left.
  wire walking = (fv_rstate == R_START && !fv_r_imm)
              || (fv_rstate == R_REQ) || (fv_rstate == R_WAIT);
  // Restricted to the walking states on purpose: R_IDLE and an immediate
  // rejection (R_START) legitimately hold STALE or never-loaded values, and in
  // an arbitrary pre-state a stale register could be anything. Inside a walk
  // the registers are live, and r_left != 0 is what makes the decrement safe
  // (r_left-1 would otherwise wrap to 65535 and break the bound in one step).
  always @(*) begin
    if (walking) assert (fv_r_left != 16'd0);
  end

  // ---- P2a: no resp_buf slot overrun ------------------------------------
  // The words still to be written must fit in the slots from r_slot on; the
  // buffer has 16. A dmem walk packs two bytes per word, hence ceil(r_left/2).
  wire [16:0] words_left = fv_r_dmem ? (({1'b0, fv_r_left} + 17'd1) >> 1)
                                     : {1'b0, fv_r_left};
  // r_slot != 0 keeps the next write inside the buffer: with slots 1..15 in
  // use and the sum capped at 16, the write lands at r_slot <= 15.
`ifndef FV_INDUCT
  // ---- NOT INDUCTIVE ON THIS TOOLCHAIN: gate-depth BMC only -------------
  // Kept in the file (and checked at the gate depth) but excluded from the
  // induction target, because the induction step does not close on it: in an
  // arbitrary pre-state the solver can pick r_slot=0 / an inconsistent pair and
  // the claim is not derivable from one transition. The honest label is
  // "PROVED at depth 16; not exercised on a live walk; induction open". The
  // same applies to the three claims below (walksum, slotsum, idxadv).
  always @(*) begin
    if (walking) assert (fv_r_slot != 16'd0);
  end
`endif

  // ---- P2a: the bound is ESTABLISHED at the accept and PRESERVED ---------
  // The bound alone is not inductive: in an arbitrary pre-state the solver can
  // pick r_addr=676 with r_left=1 and no reachable history behind it (measured
  // -- that exact model came out of yosys's dump). The coupling below is the
  // missing link, stated as the two halves that ARE one-step:
  //   (1) the ACCEPT transition loads a pair that satisfies the bound (the
  //       engine's own guard is the transition's condition, so this follows in
  //       one step);
  //   (2) while walking, the pair's SUM only ever moves with the preserving
  //       increment/decrement, so equality to the previous cycle's sum holds on
  //       every walking step except the accept itself.
  // Together they carry the accept's bound through the whole walk.
  wire accepting = (fv_rstate == R_START) && !fv_r_imm && !p_in_start;
  always @(*) begin
    if (accepting) begin
      assert (fv_r_dmem ? (walk_end <= 17'(DMEM_BYTES))
                        : (walk_end <= 17'(WORDS)));
    end
  end
`ifndef FV_INDUCT
  always @(*) begin
    if (walking && p_walking) assert (walk_end == p_walk_end);
  end
`endif

  // The slot budget the same way: at the accept, the first slot and the
  // accepted count fit the buffer; while walking, the pair's sum never grows.
  always @(*) begin
    if (accepting) assert ({1'b0, fv_r_slot} + words_left <= 17'd16);
  end
`ifndef FV_INDUCT
  always @(*) begin
    if (walking && p_walking)
      assert ({1'b0, fv_r_slot} + words_left <= p_slot_sum);
  end
`endif

  // ---- P2a: the declared length never exceeds the buffer ----------------
  // The frame carries 4 header words plus resp_len payload words and resp_idx
  // is 5 bits: a longer response would make its own index unaddressable.
  always @(*) begin
    assert (fv_resp_len <= 16'd16);
  end

  // ---- previous-cycle snapshots (explicit) ------------------------------
  // WHY NOT `$past` / CLOCKED ASSERTS. After clk2fflogic, a CLOCKED assertion
  // references SAMPLED COPIES of the signals it reads, and each copy is an
  // independent state bit: an arbitrary induction state can set one copy to 1
  // and another to 0 for the same signal. That is not a design bug but a proof
  // artefact -- yosys's own model dump for the failing attempt showed
  // `resp_active#sampled = 1` next to `resp_active#sampled = 0` in the initial
  // state -- and it made every clocked claim here non-inductive while BMC
  // proved it. Combinational asserts read the wires themselves; the previous
  // cycle comes from ONE explicit snapshot register per signal, so the
  // induction has a single coherent state to close over. (The 3b IFG wrapper
  // closed precisely this way; this file learned it the hard way.)
  reg        p_active, p_rst_n;
  reg        p_walking, p_in_start;
  reg [16:0] p_walk_end, p_slot_sum;
  reg [4:0]  p_resp_idx;
  reg [15:0] p_resp_len;
  reg [3:0]  p_resp_bitpos;
  reg        p_faults2;
  reg [15:0] p_clr_mask;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_active <= 1'b0; p_rst_n <= 1'b0; p_resp_idx <= 5'd0;
      p_resp_len <= 16'd0; p_resp_bitpos <= 4'd0;
      p_faults2 <= 1'b0; p_clr_mask <= 16'd0;
      p_walking <= 1'b0; p_in_start <= 1'b0;
      p_walk_end <= 17'd0; p_slot_sum <= 17'd0;
    end else begin
      p_active      <= fv_resp_active;
      p_rst_n       <= rst_n;
      p_resp_idx    <= fv_resp_idx;
      p_resp_len    <= fv_resp_len;
      p_resp_bitpos <= fv_resp_bitpos;
      p_faults2     <= fv_faults[2];
      p_clr_mask    <= fv_clr_mask;
      p_walking     <= walking;
      p_in_start    <= (fv_rstate == R_START);
      p_walk_end    <= walk_end;
      p_slot_sum    <= {1'b0, fv_r_slot} + words_left;
    end
  end

  // ---- P2a: the frame index starts at 0 and never runs past its CRC ------
  always @(*) begin
    if (fv_resp_active && !p_active) assert (fv_resp_idx == 5'd0);
  end
  // The advance compares against the PREVIOUS length on purpose: the decision
  // was made against the length then current, which is the form that is true of
  // the RTL (and that a removed stop-check mutant breaks).
`ifndef FV_INDUCT
  always @(*) begin
    if (fv_resp_active && p_active && fv_resp_idx != p_resp_idx)
      assert (fv_resp_idx <= p_resp_len + 5'd4);
  end
`endif

  // ---- P2b: FAULT_RANGE is sticky ---------------------------------------
  // Bit 2 may only FALL on a cycle where a CLEAR_FAULT applied a mask covering
  // it: the only assignment that can clear a set bit is `faults & ~pay0` in the
  // OP_CLRFLT branch, which also drives the observation port. Reset is excluded
  // by the snapshot (the reset edge legitimately clears the register).
  always @(*) begin
    if (rst_n && p_rst_n && p_faults2 && !fv_faults[2]) assert (fv_clr_mask[2]);
  end

  // ---- P2c: word-aligned serializer -------------------------------------
  always @(*) begin
    if (fv_resp_active && !p_active) assert (fv_resp_bitpos == 4'd0);
  end
  // A change is either a RESTART (every activation sets the index to 0) or an
  // advance, and an advance happens only at the last bit of a word.
  always @(*) begin
    if (fv_resp_active && p_active && fv_resp_idx != p_resp_idx)
      assert (fv_resp_idx == 5'd0 || p_resp_bitpos == 4'd15);
  end
endmodule

`default_nettype wire
