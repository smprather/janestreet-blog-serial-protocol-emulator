// pe_line_codec.v — Tier-1 line-code codecs: NRZI, Manchester, bit-stuffing.
// Signal meanings: wiki/reference/signal-names.md#pe_line_codec
//
// These sit between the SM/SERDES (plain NRZ bits, one per bit_en strobe)
// and the pin matrix (wire levels). Each stage is runtime-bypassable so a
// config register can mux any subset into the pipeline (see pe_codec_mux).
//
//   pe_nrzi      TX: raw 0 -> toggle line, raw 1 -> hold (USB-LS).
//                RX: separate sampled-level register — a receiver cannot
//                see the transmitter's state. raw = wire XOR prev_level.
//   pe_manch     TX: half_phase selects which half-cell is driven;
//                raw 0 -> H then L, raw 1 -> L then H (IEEE 802.3).
//                RX: decodes from the two half-cell samples the DRU
//                captured; equal halves = illegal (no mid-bit edge).
//   pe_bitstuff  Insert/drop a complementary bit after run_cfg identical
//                consecutive bits (5 = CAN, 6 = USB). TX emits the real
//                bit first, then consumes a FOLLOWING strobe for the stuff
//                bit (tx_stuffed flags that strobe; raw input is ignored).
//                RX flags the stuffed bit (rx_raw_valid=0) and errors if
//                the bit after a full run is not complementary.
//
// None of these know protocols; config bits and one runtime parameter only.
//
// Every stage takes `clr`, the frame/SOF boundary reset. NRZI needs it as much
// as the stuffer does: a USB packet starts from idle J, and without a way to
// force that the only route back to a known line state is a chip reset.
//
// Every stage's rx_err is REGISTERED and asserted for one cycle after the
// strobe that produced it. That uniformity is the point -- pe_codec_mux ORs
// them into one output, and a consumer cannot have one sampling rule for a
// combinational error and another for a registered one.

// verilator lint_off DECLFILENAME
// Three codecs share this file on purpose: they are one tier of the pipeline,
// they are configured together, and pe_codec_mux is the only thing that
// instantiates them. Splitting into three files would scatter one idea.

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


module pe_bitstuff (
  input  logic       clk, rst_n,
  input  logic       bit_en,
  input  logic       bypass,
  input  logic       clr,          // frame/SOF boundary: reset run tracking
  input  logic [3:0] run_cfg,      // stuff after this many identical bits
  input  logic       tx_raw,
  output logic       tx_wire,
  output logic       tx_stuffed,   // this strobe emits a stuff bit (raw ignored)
  input  logic       rx_wire,
  output logic       rx_raw,
  output logic       rx_raw_valid, // 0 => this wire bit was a stuff bit
  output logic       rx_err        // bit after a full run not complementary
);
  // ---------------- TX ----------------
  logic [3:0] tx_run;    // identical consecutive raw bits emitted
  logic       tx_lvl;    // value of that run
  logic       tx_pend;   // a stuff bit is owed on the NEXT strobe

  assign tx_stuffed = !bypass && tx_pend;
  assign tx_wire    = bypass ? tx_raw : (tx_pend ? ~tx_lvl : tx_raw);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_run <= 4'd0; tx_lvl <= 1'b0; tx_pend <= 1'b0;
    end else if (clr) begin
      tx_run <= 4'd0; tx_lvl <= 1'b0; tx_pend <= 1'b0;
    end else if (bit_en && !bypass) begin
      if (tx_pend) begin
        tx_pend <= 1'b0;
        tx_run  <= 4'd1;      // the stuff bit opens a new run
        tx_lvl  <= ~tx_lvl;
      end else if (tx_raw == tx_lvl) begin
        if (tx_run == run_cfg - 4'd1) tx_pend <= 1'b1;
        tx_run <= tx_run + 4'd1;
      end else begin
        tx_lvl <= tx_raw;
        tx_run <= 4'd1;
      end
    end
  end

  // ---------------- RX ----------------
  logic [3:0] rx_run;    // identical consecutive WIRE bits seen
  logic       rx_lvl;
  logic       rx_is_stuff;

  assign rx_is_stuff  = !bypass && (rx_run == run_cfg);
  assign rx_raw       = rx_wire;
  assign rx_raw_valid = bypass ? 1'b1 : !rx_is_stuff;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_run <= 4'd0; rx_lvl <= 1'b0; rx_err <= 1'b0;
    end else if (clr) begin
      rx_run <= 4'd0; rx_lvl <= 1'b0; rx_err <= 1'b0;
    end else if (bit_en && !bypass) begin
      rx_err <= 1'b0;
      if (rx_run == run_cfg) begin
        // this wire bit is the stuffed one: it must be complementary
        if (rx_wire == rx_lvl) rx_err <= 1'b1;
        rx_run <= 4'd1;
        rx_lvl <= rx_wire;
      end else if (rx_wire == rx_lvl) begin
        rx_run <= rx_run + 4'd1;
      end else begin
        rx_run <= 4'd1;
        rx_lvl <= rx_wire;
      end
    end
  end
endmodule
