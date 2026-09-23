// pe_bitstuff.v — bit stuffing / unstuffing (CAN, USB-LS).
// Signal meanings: wiki/reference/signal-names.md#pe_bitstuff
//
// Insert/drop a complementary bit after run_cfg identical consecutive bits
// (5 = CAN, 6 = USB). `ones_only` selects the protocol's rule: CAN stuffs a
// run of EQUAL bits at either polarity, while USB stamps a 0 only after six
// consecutive ONES (USB 1.1 §7.1.9) — before NRZI, so the stuffer sees the
// raw bits. Getting this wrong made eight zeroes decode as seven bits with an
// error (measured, review 2 R2-3). Counters SATURATE on a run that cannot be
// stuffed, because a USB zero run is unbounded.
//
// TX emits the real bit first, then consumes a FOLLOWING strobe for the stuff
// bit (tx_stuffed flags that strobe; the raw input is ignored on it).
// RX flags the stuffed bit (rx_raw_valid=0) and errors if the bit after a full
// run is not complementary. `bypass` passes every bit through untouched.
//
// This was split out of the old pe_line_codec.v together with pe_nrzi and
// pe_manch: one module per file, same tier, same contract.
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

module pe_bitstuff (
  input  logic       clk, rst_n,
  input  logic       bit_en,
  input  logic       bypass,
  input  logic       clr,          // frame/SOF boundary: reset run tracking
  input  logic [3:0] run_cfg,      // stuff after this many identical bits
  input  logic       ones_only,    // 1 = only runs of 1 are stuffed (USB)
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
        // Only a qualifying run arms the stuff bit. A zero run under
        // `ones_only` never does, so the counter SATURATES at run_cfg instead
        // of wrapping -- a long zero run has no bound in USB data.
        if (tx_run == run_cfg - 4'd1 && (tx_lvl == 1'b1 || !ones_only))
          tx_pend <= 1'b1;
        if (tx_run != run_cfg) tx_run <= tx_run + 4'd1;
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

  assign rx_is_stuff  = !bypass && (rx_run == run_cfg) &&
                        (rx_lvl == 1'b1 || !ones_only);
  assign rx_raw       = rx_wire;
  assign rx_raw_valid = bypass ? 1'b1 : !rx_is_stuff;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_run <= 4'd0; rx_lvl <= 1'b0; rx_err <= 1'b0;
    end else if (clr) begin
      rx_run <= 4'd0; rx_lvl <= 1'b0; rx_err <= 1'b0;
    end else if (bit_en && !bypass) begin
      rx_err <= 1'b0;
      if (rx_run == run_cfg && (rx_lvl == 1'b1 || !ones_only)) begin
        // this wire bit is the stuffed one: it must be complementary
        if (rx_wire == rx_lvl) rx_err <= 1'b1;
        rx_run <= 4'd1;
        rx_lvl <= rx_wire;
      end else if (rx_wire == rx_lvl) begin
        // Saturate: a non-stuffable run (zeroes under ones_only) is unbounded.
        if (rx_run != run_cfg) rx_run <= rx_run + 4'd1;
      end else begin
        rx_run <= 4'd1;
        rx_lvl <= rx_wire;
      end
    end
  end
endmodule
