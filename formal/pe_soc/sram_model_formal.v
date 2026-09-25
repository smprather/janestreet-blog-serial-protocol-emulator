// sram_model_formal.v — a yosys-readable behavioural stand-in for the PDK SRAM
// macro used by pe_fbuf (RM_IHPSG13_1P_1024x16_c2_bm_bist).
//
// WHY A STAND-IN. The PDK model contains a `specify` block with
// `$setuphold(...)` timing checks that the yosys frontend rejects
// ("unexpected ','" at the first $setuphold), so the real model cannot be
// elaborated by this flow. The simulation regression keeps using the real PDK
// model (regress/sram_model.sh) -- this file is used ONLY by the formal targets
// that need pe_soc to elaborate.
//
// WHAT IT DOES NOT CHANGE. Target 4's claims are about the codec owner mux
// (tx_path and the two engines' busy wires). No claim reads or reasons about
// memory CONTENTS, so the array below only has to present the macro's
// interface and its one-cycle registered read. `-set-init-zero` makes the array
// deterministic; nothing in the properties depends on its values.
`default_nettype none

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
  // 16 entries, not 1024: no claim reads memory, and every bit of this array
  // becomes a SAT variable once the memory is lowered for the SAT engine, so a
  // full-size array would only make the proof heavier for nothing.
  reg [15:0] mem [0:15];
  reg [15:0] rdata;
  wire [3:0] a = A_ADDR[3:0];

  always @(posedge A_CLK) begin
    if (A_MEN && A_WEN) begin
      for (int i = 0; i < 16; i++)
        if (A_BM[i]) mem[a] <= A_DIN;   // bit-mask semantics, simplified
    end
    if (A_MEN && A_REN) rdata <= mem[a];
  end

  assign A_DOUT = rdata;

  // BIST port is unused by the design.
  wire _unused = &{1'b0, A_DLY, A_BIST_CLK, A_BIST_EN, A_BIST_MEN, A_BIST_WEN,
                   A_BIST_REN, A_BIST_ADDR, A_BIST_DIN, A_BIST_BM};
endmodule

`default_nettype wire
