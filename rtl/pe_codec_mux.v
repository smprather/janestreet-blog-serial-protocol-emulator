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
//   cfg[6:4]  run_cfg      stuff run length (0 => default 5; CAN 5, USB 6)
//   cfg[7]    ones_only    stuff only runs of 1 (USB); 0 = either polarity
//                          (CAN). USB 1.1 7.1.9 stamps a 0 after six ones; a
//                          symmetric counter mis-stuffs zero runs (review 2).
//                          USB's config byte is therefore 0xE3, not 0x63.
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
  logic       stuff_en, nrzi_en, manch_en, ones_only;
  logic [3:0] run_cfg;

  assign stuff_en = cfg[0];
  assign nrzi_en  = cfg[1];
  assign manch_en = cfg[2];
  assign ones_only = cfg[7];
  // 3 bits, not 4: bit 7 carries the stuffing polarity rule. The default run
  // length is still 5 so a legacy cfg byte with the high nibble unused keeps
  // its CAN-style behaviour.
  assign run_cfg  = (cfg[6:4] == 3'd0) ? 4'd5 : {1'b0, cfg[6:4]};

  // ---- TX cascade: stuff -> nrzi -> manch ----
  logic s_wire, n_wire, m_rx_out, n_rx_out, st_rx_err, m_rx_err, n_tx_lvl;

  pe_bitstuff u_stuff (
    .clk(clk), .rst_n(rst_n), .bit_en(bit_en),
    .bypass(~stuff_en), .clr(clr), .run_cfg(run_cfg),
    .ones_only(ones_only),
    .tx_raw(tx_bit), .tx_wire(s_wire), .tx_stuffed(tx_stuffed),
    .rx_wire(n_rx_out), .rx_raw(rx_bit), .rx_raw_valid(rx_bit_valid),
    .rx_err(st_rx_err)
  );

  // clr reaches EVERY stage, not just the stuffer. NRZI carries a TX line
  // level and an RX sampled level across bit cells; a USB packet begins from
  // idle J, and before this the only way to get there was a chip reset.
  pe_nrzi u_nrzi (
    .clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(~nrzi_en), .clr(clr),
    .tx_raw(s_wire), .tx_wire(n_wire), .tx_lvl(n_tx_lvl),
    .rx_wire(m_rx_out), .rx_raw(n_rx_out)
  );

  pe_manch u_manch (
    .clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(~manch_en), .clr(clr),
    .half_phase(cfg[3]),
    .tx_raw(n_wire), .tx_wire(tx_wire),
    .rx_wire(rx_wire), .rx_first(rx_first), .rx_second(rx_second),
    .rx_raw(m_rx_out), .rx_err(m_rx_err)
  );

  // ---- error aggregation ----
  // Both sources are now registered one-cycle pulses aligned to the committing
  // edge, so this OR has a single sampling rule. It did not before: pe_manch's
  // rx_err was combinational and ungated, so it sat high on an idle line and
  // permanently high whenever Manchester was bypassed for another protocol.
  assign rx_err = st_rx_err | m_rx_err;

  // The NRZI line level is a debug tap the codec pipeline does not consume;
  // tb_pe_line_codec drives it directly on a bare pe_nrzi.
  logic _unused_n_tx_lvl;
  assign _unused_n_tx_lvl = n_tx_lvl;

endmodule
