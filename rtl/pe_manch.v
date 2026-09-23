// pe_manch.v — Manchester line codec (10BASE-T, PS/2 framing).
// Signal meanings: wiki/reference/signal-names.md#pe_manch
//
// TX: half_phase selects which half-cell is driven; raw 0 -> H then L,
// raw 1 -> L then H (IEEE 802.3).
// RX: decodes from the two half-cell samples the DRU captured; EQUAL halves
// mean there was no mid-bit transition, which is a code violation and is
// reported as rx_err.
//
// This was split out of the old pe_line_codec.v together with pe_nrzi and
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

module pe_manch (
  input  logic clk, rst_n,
  input  logic bit_en,
  input  logic bypass,
  input  logic clr,             // frame boundary: drop any pending error
  input  logic half_phase,      // 0 = first half-cell, 1 = second half-cell
  input  logic tx_raw,
  output logic tx_wire,
  input  logic rx_wire,
  input  logic rx_first,        // DRU half-cell sample, first half
  input  logic rx_second,       // DRU half-cell sample, second half
  output logic rx_raw,
  output logic rx_err
);
  // TX: raw 0 -> first half high, second low (H->L mid-bit).
  //     raw 1 -> first half low,  second high (L->H mid-bit).
  assign tx_wire = bypass ? tx_raw : (half_phase ? tx_raw : ~tx_raw);
  // RX: the second-half level carries the bit (a 0's second half is low).
  assign rx_raw  = bypass ? rx_wire : rx_second;

  // rx_err is REGISTERED and strobe-gated, matching pe_bitstuff.
  //
  // It used to be `assign rx_err = bypass ? 0 : (rx_first == rx_second)`, which
  // is true of an IDLE line as much as of a corrupt bit cell: with no strobe
  // qualifying it, the output sat high between frames and whenever another
  // protocol ran with Manchester bypassed. pe_codec_mux ORs this with the
  // stuffer's registered rx_err, so the two must agree on when to be read --
  // a consumer cannot have one sampling rule per source.
  //
  // Equal half-cells mean no mid-bit transition, which is a code violation
  // (IEEE 802.3 guarantees one per cell). Only a committed cell can be one.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     rx_err <= 1'b0;
    else if (clr)   rx_err <= 1'b0;
    else            rx_err <= bit_en && !bypass && (rx_first == rx_second);
  end
endmodule
