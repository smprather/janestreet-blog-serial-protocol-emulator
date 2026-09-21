// RM_IHPSG13_1P_1024x16_c2_bm_bist — BLACKBOX stub for synthesis.
//
// This is NOT the macro's model. It is an empty shell with the macro's exact
// port list, so yosys can elaborate a design that instantiates the macro without
// trying to synthesise it (it is a hard macro: fixed 237x336 um geometry, no
// gates, it comes back as GDS from the PDK).
//
//   * For SYNTHESIS (yosys / tb/synth_area.sh): use this file. Add it to the
//     read list. `(* blackbox *)` makes yosys keep the instance and treat its
//     output as an unresolved net, which is what the area report should show.
//   * For SIMULATION (iverilog): use the PDK's real behavioural model instead --
//     .../ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_1024x16_c2_bm_bist.v
//     plus .../RM_IHPSG13_1P_core_behavioral_bm_bist.v. That model is what
//     establishes the one-cycle read latency and the write-through behaviour the
//     wrapper's RTL is written against.
//   * For PLACE AND ROUTE (LibreLane): the macro comes from the PDK's LEF/GDS
//     via the flow's MACROS configuration, not from either file here.
//
// Keeping all three roles in one comment is deliberate: mixing them up is how a
// design ends up "verified" against a stub. If a testbench passes against THIS
// file, it has verified nothing about the memory.

// The lint tool flags every input of this shell as an unused signal, which is
// what a blackbox IS: the ports exist so the instance elaborates, and nothing
// inside reads them. Waived here rather than in tb/lint.sh so the exception
// lives next to the thing it applies to, and so it cannot silently cover real
// RTL -- the waiver ends at this module's `endmodule`.
//
// The alternative (deleting the ports) is not one: yosys matches a blackbox by
// its port list, so a shell with fewer ports would be a different cell.
// NOTE: the word 'verilator' must not appear in prose above the pragma, or the
// tool parses the comment AS a pragma and errors with BADVLTPRAGMA.
// Both waivers are inherent to a shell: nothing inside reads an input, and
// nothing inside drives the output. The REAL model (the PDK's) is what
// simulation uses; this file only ever exists for elaboration.
// verilator lint_off UNUSEDSIGNAL
// verilator lint_off UNDRIVEN

(* blackbox *)
module RM_IHPSG13_1P_1024x16_c2_bm_bist (
  input  wire        A_CLK,
  input  wire        A_MEN,
  input  wire        A_WEN,
  input  wire        A_REN,
  input  wire [9:0]  A_ADDR,
  input  wire [15:0] A_DIN,
  input  wire        A_DLY,
  output wire [15:0] A_DOUT,
  input  wire [15:0] A_BM,
  input  wire        A_BIST_CLK,
  input  wire        A_BIST_EN,
  input  wire        A_BIST_MEN,
  input  wire        A_BIST_WEN,
  input  wire        A_BIST_REN,
  input  wire [9:0]  A_BIST_ADDR,
  input  wire [15:0] A_BIST_DIN,
  input  wire [15:0] A_BIST_BM
);
endmodule
// verilator lint_on UNDRIVEN
// verilator lint_on UNUSEDSIGNAL
