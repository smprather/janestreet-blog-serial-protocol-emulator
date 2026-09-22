// pe_fbuf.v — frame buffer: 2 KB behind a byte interface, on the same macro as
// the instruction memory.
// Decision: wiki/decisions/adr-003-memory-plan.md
// Macro: pdk .../sg13g2_sram/verilog/RM_IHPSG13_1P_1024x16_c2_bm_bist.v
//
// WHY THIS EXISTS
//
// 10BASE-T needs to hold a frame. A maximum Ethernet frame is 1,518 bytes and
// the CPU's data memory is 16 bytes, so a frame cannot be received at all
// today -- there is nowhere to put it. ADR-003 chose the 1024x16 macro (the
// SAME part as pe_imem: one macro type to integrate, one timing arc to
// characterise, one set of BIST hooks) which gives 2,048 bytes, and accepts the
// consequence that the memory is 16 bits wide while a frame is a byte stream.
//
// ---------------------------------------------------------------------------
// THE BYTE-PACKING COST, WHICH ADR-003 SAID BELONGS IN THIS HEADER
//
// Two bytes share a word, so a byte address splits into a word address and a
// lane. The interesting part is that the two directions are NOT symmetric, and
// the reason is a macro port most designs leave tied off:
//
//   * WRITES ARE FREE. The macro has a bit-mask port (A_BM) where BM[i]=1 means
//     "write bit i". Driving BM = 16'h00FF writes the low byte and leaves the
//     high byte untouched, IN HARDWARE, in one access. This is byte-select, and
//     the macro already has it. The alternative -- read-modify-write -- would
//     cost an extra cycle and, worse, would need the read path while the write
//     port is busy. Note the polarity trap: BM=0 with WEN=1 writes NOTHING and
//     is not an error, so a lane bug here fails silently as "the byte did not
//     change" rather than as a violation.
//
//   * READS ARE NOT. There is no byte-select on the macro's output; A_DOUT is
//     the whole 16 bits. So the READ path pays an 8-bit 2:1 mux plus a lane
//     register -- and the register is the subtle half. The macro's data is
//     valid one cycle AFTER the address is presented, so the lane must be
//     captured with the address, at the same edge, or the mux selects the lane
//     of the NEXT request. That failure looks like "reads return the wrong byte
//     only when consecutive reads alternate lanes", which is exactly the
//     pattern a sequential frame walk produces, so it would show up in real use
//     and not in a spot check.
//
// So: writes cost nothing extra, reads cost a register and a mux. ADR-003's
// "byte-select logic on the data port" is one third of the story; the mask port
// covers the other two thirds.
//
// ---------------------------------------------------------------------------
// THE MACRO'S CONTRACT (read from the vendor model, shared with pe_imem.v)
//
//   always @(posedge CLK) begin
//     if (MEN && WEN) begin
//        memory[ADDR] <= (memory[ADDR] & ~BM) | (DIN & BM);
//        if (REN) dr_r <= (memory[ADDR] & ~BM) | (DIN & BM);   // WRITE-THROUGH
//     end
//     else if (MEN && REN) dr_r <= memory[ADDR];
//   end
//
//   * READ LATENCY IS ONE CYCLE, so the cycle model is the same as pe_imem's.
//   * REN DURING A WRITE IS WRITE-THROUGH and reads DIN, not memory. This block
//     drives REN = !write, explicitly, so the path is unreachable.
//   * A_DLY must be 1 or the vendor wrapper $stops at time 0.
//
// Port widths repeat the $clog2 expressions inline because Icarus binds port
// dimensions before later localparams are visible -- the same workaround
// pe_imem.v and pe_cpu.v use.

module pe_fbuf #(
  parameter int BYTES = 2048,            // 2048 for the macro; any even size if FLOP=1
  parameter int FLOP  = 0                // 1 = register array (no macro needed)
) (
  input  logic clk,

  // Byte-write port. One byte per cycle, no read-modify-write: the lane is
  // expressed through the macro's bit mask.
  input  logic                     we,
  input  logic [((BYTES <= 2) ? 1 : $clog2(BYTES))-1:0] waddr,
  input  logic [7:0]               wdata,

  // Byte-read port. Address this cycle, data next cycle -- the macro's latency,
  // unchanged from pe_imem so the CPU's expectations carry over.
  input  logic [((BYTES <= 2) ? 1 : $clog2(BYTES))-1:0] raddr,
  output logic [7:0]               rdata
);

  localparam int AW = (BYTES <= 2) ? 1 : $clog2(BYTES);   // byte address width

  // The macro is a fixed 1024x16 shape, so the byte capacity is fixed too.
  // 1024 words x 2 bytes = 2048. A different BYTES would need a different macro
  // part, which is a decision, not a parameter.
  if ((FLOP == 0) && (BYTES != 2048)) begin : g_depth_guard
    $error("pe_fbuf: the SRAM macro is fixed at 1024x16 = 2048 bytes; use BYTES=2048, or FLOP=1 for a register array");
  end

  // BYTES must be even, because a byte lane only exists if two bytes share a
  // word. An odd BYTES would leave the last word's high byte addressable but
  // not backed by anything.
  if ((BYTES % 2) != 0) begin : g_even_guard
    $error("pe_fbuf: BYTES must be even -- bytes are packed two to a word");
  end

  // The lane select, and the reason the write/read asymmetry above exists.
  //   lane 0 -> bits [7:0]    lane 1 -> bits [15:8]
  logic                  rd_lane;
  logic [15:0]           word_rd;

  // A write owns the macro's single port; a read uses it otherwise. This is the
  // same arbitration pe_imem uses for its loader, and it is safe here for the
  // same reason: the frame buffer has one writer at a time by construction.
  logic                  access_is_write;

  assign access_is_write = we;

  wire [AW-1:0] access_addr = access_is_write ? waddr : raddr;

  generate
    if (FLOP == 1) begin : g_flops
      // Fallback: a register array with the SAME one-cycle read latency, so
      // behaviour is identical and only the area differs -- same contract as
      // pe_imem's FLOP path, which is what tb/synth_area.sh prices.
      logic [15:0] mem [0:BYTES/2-1];

      always_ff @(posedge clk) begin
        if (we) begin
          // Byte-granular, exactly like the macro's mask: only the addressed
          // byte moves. A whole-word write here would be a DIFFERENT contract
          // from the macro path and the two would diverge silently.
          if (waddr[0]) mem[waddr[AW-1:1]][15:8] <= wdata;
          else          mem[waddr[AW-1:1]][7:0]  <= wdata;
        end else begin
          word_rd <= mem[raddr[AW-1:1]];
          // The lane is captured with the address, at the same edge that
          // starts the read -- see the header. Registering it later selects
          // the wrong byte whenever consecutive reads alternate lanes.
          //
          // BOTH word and lane are HELD during a write, not just the lane:
          // the macro has REN deasserted for the write cycle and its A_DOUT
          // does not move, so a fallback that read anyway returned the new
          // read address's data where the macro returned the previous word
          // (measured, review 2 R2-5).
          rd_lane <= raddr[0];
        end
      end
    end else begin : g_macro
      logic we_m, re_m;

      assign we_m = access_is_write;
      assign re_m = ~access_is_write;

      // Byte lane -> bit mask and data placement. BM=0 means "do not write this
      // bit", so the opposite lane is masked out and survives untouched.
      logic [15:0] bm_m, din_m;
      assign bm_m  = access_addr[0] ? 16'hFF00 : 16'h00FF;
      assign din_m = access_addr[0] ? {wdata, 8'h00} : {8'h00, wdata};

      RM_IHPSG13_1P_1024x16_c2_bm_bist u_sram (
        .A_CLK       (clk),
        .A_MEN       (1'b1),            // an access is wanted every cycle
        .A_WEN       (we_m),
        .A_REN       (re_m),
        .A_ADDR      (access_addr[AW-1:1]),
        .A_DIN       (din_m),
        .A_BM        (bm_m),            // byte-select, in hardware
        .A_DLY       (1'b1),            // must be 1; the model $stops otherwise
        .A_DOUT      (word_rd),
        // BIST unused: A_BIST_EN=0 muxes this port away inside the macro.
        .A_BIST_CLK  (1'b0),
        .A_BIST_EN   (1'b0),
        .A_BIST_MEN  (1'b0),
        .A_BIST_WEN  (1'b0),
        .A_BIST_REN  (1'b0),
        .A_BIST_ADDR ('0),
        .A_BIST_DIN  ('0),
        .A_BIST_BM   ('0)
      );

      always_ff @(posedge clk) if (re_m) rd_lane <= access_addr[0];
    end
  endgenerate

  // Read mux, by the lane captured with the address.
  assign rdata = rd_lane ? word_rd[15:8] : word_rd[7:0];

endmodule
