// pe_imem.v — instruction memory: a real SRAM macro, behind a testable wrapper.
// Decision: wiki/decisions/adr-004-program-counter-width.md
// Macro: pdk .../sg13g2_sram/verilog/RM_IHPSG13_1P_1024x16_c2_bm_bist.v
//
// WHY THIS EXISTS RATHER THAN INSTANTIATING THE MACRO INLINE
//
// Three reasons, in order of how much trouble they save:
//
//   1. The macro is a HARD MACRO with a fixed shape (237x336 um, 1024x16). It
//      cannot be synthesised, only instantiated, so it has to be blackboxed for
//      yosys and supplied as a PDK model for simulation. Putting that boundary
//      in one file keeps it out of pe_soc.
//   2. The macro's port protocol is not the CPU's. The CPU wants "address in,
//      data out next cycle, plus a loader write port". The macro wants
//      MEN/WEN/REN/BM with a specific combination for each operation, and two
//      of those combinations are traps (below). That translation is this file.
//   3. A FALLBACK is then one parameter, not a rewrite: FLOP=1 synthesises a
//      register array with identical behaviour, so a testbench or an area
//      experiment can run without the macro at all.
//
// ---------------------------------------------------------------------------
// THE MACRO'S CONTRACT, READ FROM THE VENDOR MODEL (not from a datasheet guess)
//
// From RM_IHPSG13_1P_core_behavioral_bm_bist.v:
//
//   always @(posedge CLK) begin
//     if (MEN && WEN) begin
//        memory[ADDR] <= (memory[ADDR] & ~BM) | (DIN & BM);
//        if (REN) dr_r <= (memory[ADDR] & ~BM) | (DIN & BM);   // WRITE-THROUGH
//     end
//     else if (MEN && REN) dr_r <= memory[ADDR];
//   end
//
// Three facts, and the two traps:
//
//   * A_BM[i] = 1 means "write bit i". All-ones writes the whole word; all-zeros
//     writes NOTHING even with WEN asserted. This block always writes all 16
//     bits, so BM is tied high -- but it is tied high deliberately and named,
//     because "BM=0 with WEN=1" is a silent no-op, not an error.
//   * READ LATENCY IS ONE CYCLE. That matches the datasheet's "one-cycle
//     data-access" and it is what pe_cpu's fetch-ahead was designed around
//     (rtl/pe_cpu.v drives next_pc at the ROM precisely so the word arrives on
//     time). The cycle model therefore does NOT change with the swap.
//   * REN=1 DURING A WRITE IS WRITE-THROUGH: the read port returns the NEW
//     value, and the expression reads DIN, not memory. Leaving REN asserted
//     through a loader write corrupts the read path for that cycle. This block
//     drives REN = !write, explicitly.
//
// A_DLY must be tied to 1; the vendor wrapper $stops at time 0 otherwise. BIST
// is unused: A_BIST_EN=0 muxes the whole BIST port away inside the macro.
//
// ---------------------------------------------------------------------------
// WHY THERE IS NO OUTPUT REGISTER HERE
//
// The macro already registers its output. A wrapper register on top would add a
// second cycle of latency and break the CPU's fetch-ahead, which assumes exactly
// one. imem_rdata is the macro's A_DOUT, wire to wire.
//
// The port width repeats the $clog2 expression inline because Icarus binds port
// dimensions before later localparams are visible -- the same workaround
// pe_cpu.v uses.

module pe_imem #(
  parameter int WORDS = 1024,            // 1024 for the macro; any depth if FLOP=1
  parameter int FLOP  = 0                // 1 = register array (no macro needed)
) (
  input  logic clk,

  // CPU fetch port: address this cycle, data next cycle.
  input  logic [((WORDS <= 2) ? 1 : $clog2(WORDS))-1:0] imem_addr,
  output logic [15:0] imem_rdata,

  // Loader port: one word per cycle. Highest priority, and by construction it
  // cannot collide with a fetch -- the SoC holds the CPU at PC=0 while run=0,
  // and the loader owns that window.
  input  logic host_we,
  input  logic [((WORDS <= 2) ? 1 : $clog2(WORDS))-1:0] host_addr,
  input  logic [15:0] host_wdata
);

  // The macro is a HARD MACRO with a fixed 1024x16 shape -- it cannot be
  // parameterised, only instantiated. So FLOP=0 is only legal at WORDS=1024, and
  // saying so here is better than an address bus that silently mismatches.
  if ((FLOP == 0) && (WORDS != 1024)) begin : g_depth_guard
    $error("pe_imem: the SRAM macro is fixed at 1024x16; use WORDS=1024, or FLOP=1 for a register array at any depth");
  end

  generate
    if (FLOP == 1) begin : g_flops
      // Fallback: a register array with the SAME one-cycle read latency, so
      // behaviour is identical and only the area differs. This is what
      // regress/synth_area.sh measures to price the swap, and what lets a testbench
      // run when the PDK (or the macro's model) is not available.
      logic [15:0] mem [0:WORDS-1];
      // Reads are disabled during a host write, exactly like the macro's
      // `re = ~host_we`: the macro deasserts REN for the write cycle and holds
      // A_DOUT, so a fallback that kept reading would diverge whenever the
      // fetch address changed across a write (measured, review 2 R2-5).
      always_ff @(posedge clk) begin
        if (host_we) mem[host_addr] <= host_wdata;
        else         imem_rdata <= mem[imem_addr];
      end
    end else begin : g_macro
      // Write-enable decode. MEN is high for either operation; WEN and REN are
      // mutually exclusive so the write-through path can never be taken.
      logic we, re;

      assign we = host_we;
      assign re = ~host_we;

      RM_IHPSG13_1P_1024x16_c2_bm_bist u_sram (
        .A_CLK       (clk),
        .A_MEN       (1'b1),            // an access is wanted every cycle
        .A_WEN       (we),
        .A_REN       (re),
        .A_ADDR      (host_we ? host_addr : imem_addr),
        .A_DIN       (host_wdata),
        .A_DLY       (1'b1),            // must be 1; the model $stops otherwise
        .A_DOUT      (imem_rdata),
        .A_BM        ({16{1'b1}}),      // write every bit (BM=0 would be a no-op)
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
    end
  endgenerate

endmodule
