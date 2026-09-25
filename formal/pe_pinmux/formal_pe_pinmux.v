// formal_pe_pinmux.v — SAFETY: an open-drain pin NEVER drives high.
//
// THE PROPERTY (pe_pinmux's header claim): "in od mode a pin holding a 1 is
// released rather than driven high", i.e. for every pin i
//     pad_oe[i] -> !(reg_od[i] && eff_out[i])
// with eff_out the effective level after the engine overlay. This is the
// property whose absence from the TEST suite let the 18:43 unrestored m1
// mutant (pad_oe = reg_oe) redden three testbenches for a session: tests can
// OBSERVE a violation, but nothing PROVED the invariant.
//
// WHY A REFERENCE MODEL, NOT A HIERARCHICAL TAP. yosys does not resolve
// cross-module references into connections (the very trap pe_ctrl's header
// documents: "yosys declared \u_cpu.pc as an implicit wire and drove it
// BACKWARDS"). An earlier draft tapped dut.reg_od/reg_oe/eff_out and produced
// a COUNTEREXAMPLE that was pure wrapper artifact - the taps floated, so the
// assertion compared pad_oe against noise. So this wrapper instead SHADOWS the
// register file from the observable inputs and asserts the DUT's outputs
// EQUAL the model for every input sequence. That is a strictly stronger claim
// than the one-line invariant: it pins the whole combinational output, and the
// m1 mutant would fail it immediately.
//
// Inputs are anyseq (every write/overlay/pad sequence, any reset pattern), so
// the proof is over ALL stimuli, not a testbench's schedule.
`default_nettype none

module formal_pe_pinmux #(
  parameter int PINS = 8,
  parameter logic [PINS-1:0] RST_OE  = '0,
  parameter logic [PINS-1:0] RST_OUT = '1,
  parameter logic [PINS-1:0] RST_OD  = '0
) (
  input wire              clk,
  input wire              we,
  input wire [1:0]        addr,
  input wire [PINS-1:0]   wdata,
  input wire [PINS-1:0]   ov_en,
  input wire              ov_bit,
  input wire [PINS-1:0]   pad_in,
  input wire              rst_n
);
  wire [PINS-1:0] pad_out;
  wire [PINS-1:0] pad_oe;

  pe_pinmux #(.PINS(PINS), .RST_OE(RST_OE), .RST_OUT(RST_OUT), .RST_OD(RST_OD)) dut (
    .clk(clk), .rst_n(rst_n),
    .we(we), .addr(addr), .wdata(wdata),
    .ov_en(ov_en), .ov_bit(ov_bit),
    .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe)
  );

  localparam logic [1:0] A_OUT = 2'd0, A_OE = 2'd1, A_IN = 2'd2, A_OD = 2'd3;

  // ---- the reference model: a shadow of the register file ---------------
  reg [PINS-1:0] m_out, m_oe, m_od;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_out <= RST_OUT;
      m_oe  <= RST_OE;
      m_od  <= RST_OD;
    end else if (we) begin
      case (addr)
        A_OUT: m_out <= wdata;
        A_OE:  m_oe  <= wdata;
        A_OD:  m_od  <= wdata;
        default: ;                     // A_IN is read-only: no-op
      endcase
    end
  end
  wire [PINS-1:0] m_eff_out = (m_out & ~ov_en) | ({PINS{ov_bit}} & ov_en);
  wire [PINS-1:0] m_pad_oe  = m_oe & ~(m_od & m_eff_out);

  // ---- reset discipline -------------------------------------------------
  // Assume reset is asserted in the first state; after that it is free, so the
  // proof includes reset being re-asserted at any cycle. Without an initial
  // reset the model's initial state is arbitrary, which would make any
  // post-reset claim vacuous.
  always @(*) begin
    if ($initstate) assume (!rst_n);
  end

  // ---- the properties ---------------------------------------------------
  // P1 (the headline claim): an open-drain pin holding a high effective level
  // is never driven. Stated on the MODEL so it is a claim about the contract,
  // then P2 ties the model to the DUT's actual output.
  always @(*) begin
    for (int i = 0; i < PINS; i = i + 1)
      assert (!(m_pad_oe[i] && m_od[i] && m_eff_out[i]));
  end

  // P2 (equivalence): the DUT's combinational output IS the contract. This is
  // what turns P1 into a statement about the silicon: if the DUT ever widens
  // pad_oe (the m1 mutant) or drops the overlay term, this fails.
  always @(*) begin
    for (int i = 0; i < PINS; i = i + 1) begin
      assert (pad_oe[i] == m_pad_oe[i]);
      assert (pad_out[i] == m_eff_out[i]);
    end
  end

  // P3: pad_oe is never wider than the model's output enable. Kept separate
  // because it is the one-liner a reader of the header checks by eye, and a
  // mutation that ORs in an extra term would trip it even if reg_od/eff_out
  // were themselves broken.
  always @(*) begin
    for (int i = 0; i < PINS; i = i + 1)
      assert (!(pad_oe[i] && !m_oe[i]));
  end
endmodule

`default_nettype wire
