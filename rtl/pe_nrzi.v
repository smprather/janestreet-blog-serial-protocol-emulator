// pe_nrzi.v — NRZI line codec (USB-LS).
// Signal meanings: wiki/reference/signal-names.md#pe_nrzi
//
// TX: raw 0 -> toggle the line, raw 1 -> hold.
// RX: a separate sampled-level register — a receiver cannot see the
// transmitter's state, so raw = wire XOR previous wire level.
//
// This was split out of the old pe_line_codec.v together with pe_manch and
// pe_bitstuff: one module per file, same tier, same contract.
//
// Registered-error contract: every stage's rx_err is REGISTERED and asserted
// for one cycle after the strobe that produced it. That uniformity is the
// point -- pe_codec_mux ORs the stages into one output, and a consumer cannot
// have one sampling rule for a combinational error and another for a
// registered one.
//
// `clr` is the frame/SOF boundary reset. Every stage takes it: NRZI carries
// state across cells and a USB packet starts from idle J, and the stuffer's
// run tracking must not survive a frame boundary.

module pe_nrzi (
  input  logic clk, rst_n,
  input  logic bit_en,
  input  logic bypass,
  input  logic clr,       // frame/SOF boundary: return to idle J
  input  logic tx_raw,
  output logic tx_wire,
  input  logic rx_wire,
  output logic rx_raw,
  output logic tx_lvl
);
  logic tx_level;   // line level we drive
  logic rx_level;   // last wire level we sampled (receiver state)

  assign tx_lvl  = tx_level;
  assign tx_wire = bypass ? tx_raw : tx_level;
  // Decode: a transition is a 0, no transition is a 1 (XNOR).
  assign rx_raw  = bypass ? rx_wire : ~(rx_wire ^ rx_level);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_level <= 1'b1;   // idle J
      rx_level <= 1'b1;   // idle J
    end else if (clr) begin
      tx_level <= 1'b1;   // idle J
      rx_level <= 1'b1;   // idle J
    end else if (bit_en) begin
      if (!bypass && (tx_raw == 1'b0)) tx_level <= ~tx_level;
      rx_level <= rx_wire;
    end
  end
endmodule
