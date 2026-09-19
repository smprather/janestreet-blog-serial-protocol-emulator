// pe_codec_mux.v — config-driven codec pipeline (SERDES <-> pin matrix).
// Signal meanings: wiki/reference/signal-names.md#pe_codec_mux
//
// Composes the Tier-1 codecs into one pipeline. Every stage is
// runtime-bypassable from the cfg register, so firmware muxes any subset
// in or out:
//
//   cfg[0]    stuff_en     bit stuffing/unstuffing
//   cfg[1]    nrzi_en      NRZI line coding (USB-LS)
//   cfg[2]    manch_en     Manchester line coding (10BASE-T)
//   cfg[3]    half_phase   Manchester half-cell select (SM/timing driven)
//   cfg[7:4]  run_cfg      stuff run length (0 => default 5; CAN 5, USB 6)
//
// TX order:  tx_bit -> [stuff] -> [nrzi] -> [manch] -> tx_wire
// RX order:  rx_wire -> [manch] -> [nrzi] -> [stuff] -> rx_bit
//
// The ORDER is fixed (it is the physically correct composition for these
// codes: stuffing is defined in the raw/encoded domain, line coding last).
// "Arbitrary muxing" therefore means any SUBSET of stages, which covers
// every protocol in the target set. A protocol needing a different order
// needs a different pipeline, not a config bit.
//
// Note: the active codec sets the strobe cadence the timing block must
// supply — one strobe per raw bit for plain/NRZI/stuffed modes, one per
// HALF-cell (with half_phase toggling) for Manchester.

module pe_codec_mux (
  input  logic       clk, rst_n,
  input  logic [7:0] cfg,
  input  logic       bit_en,
  input  logic       clr,
  // TX: from SM/SERDES
  input  logic       tx_bit,
  output logic       tx_wire,
  output logic       tx_stuffed,
  // RX: from pin matrix / DRU
  input  logic       rx_wire,
  input  logic       rx_first,
  input  logic       rx_second,
  output logic       rx_bit,
  output logic       rx_bit_valid,
  output logic       rx_err
);
  logic       stuff_en, nrzi_en, manch_en;
  logic [3:0] run_cfg;

  assign stuff_en = cfg[0];
  assign nrzi_en  = cfg[1];
  assign manch_en = cfg[2];
  assign run_cfg  = (cfg[7:4] == 4'd0) ? 4'd5 : cfg[7:4];

  // ---- TX cascade: stuff -> nrzi -> manch ----
  logic s_wire, n_wire, m_rx_out, n_rx_out, st_rx_err, m_rx_err;

  pe_bitstuff u_stuff (
    .clk(clk), .rst_n(rst_n), .bit_en(bit_en),
    .bypass(~stuff_en), .clr(clr), .run_cfg(run_cfg),
    .tx_raw(tx_bit), .tx_wire(s_wire), .tx_stuffed(tx_stuffed),
    .rx_wire(n_rx_out), .rx_raw(rx_bit), .rx_raw_valid(rx_bit_valid),
    .rx_err(st_rx_err)
  );

  pe_nrzi u_nrzi (
    .clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(~nrzi_en),
    .tx_raw(s_wire), .tx_wire(n_wire), .tx_lvl(),
    .rx_wire(m_rx_out), .rx_raw(n_rx_out)
  );

  pe_manch u_manch (
    .clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(~manch_en),
    .half_phase(cfg[3]),
    .tx_raw(n_wire), .tx_wire(tx_wire),
    .rx_wire(rx_wire), .rx_first(rx_first), .rx_second(rx_second),
    .rx_raw(m_rx_out), .rx_err(m_rx_err)
  );

  // ---- error aggregation ----
  assign rx_err = st_rx_err | m_rx_err;

endmodule
