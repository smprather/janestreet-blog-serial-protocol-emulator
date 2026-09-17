// pe_serdes.v — protocol-emulator shared serializer / deserializer.
//
// One shift engine serves every target protocol (UART, SPI, I2C, JTAG, SWD,
// PS/2, CAN, USB-LS, 10BASE-T): firmware works at the word level, this block
// handles bit order and bit counting.
//
// * Runtime bit order: cfg_lsb_first = 1 (UART) or 0 (SPI/I2C/CAN/USB/...).
// * Transfer length 1..MAXLEN bits, captured on load/start.
// * bit_en is the per-bit-cell strobe from the core/DRU timing logic.
//   The RX serial input is expected to be already synchronized (latch-pair
//   dual-edge capture flop, ADR-002); this block is single-edge.
// * tx_ser idles HIGH (suits UART; SPI is CS-gated; I2C/SWD direction is
//   handled by the pin-matrix OE logic, not here).
// * A load/start while busy restarts the transfer. Length 0 is ignored.
// * Valid RX payload lands in rx_data[rx_len-1:0]: first-received bit sits at
//   [0] when LSB-first, at [rx_len-1] when MSB-first.

module pe_serdes #(
  parameter int MAXLEN = 32,
  parameter int LENW   = $clog2(MAXLEN + 1),
  parameter int IDXW   = $clog2(MAXLEN)
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic                 cfg_lsb_first,
  input  logic                 bit_en,

  // Transmit side
  input  logic                 tx_load,
  input  logic [MAXLEN-1:0]    tx_data,
  input  logic [LENW-1:0]      tx_len,
  output logic                 tx_ser,
  output logic                 tx_busy,
  output logic                 tx_done,

  // Receive side
  input  logic                 rx_ser,
  input  logic                 rx_start,
  input  logic [LENW-1:0]      rx_len,
  output logic [MAXLEN-1:0]    rx_data,
  output logic                 rx_busy,
  output logic                 rx_valid
);

  // ---------------- Transmit ----------------
  logic [MAXLEN-1:0] tx_shreg;
  logic [LENW-1:0]   tx_nbits;  // snapshot of tx_len at load
  logic [LENW-1:0]   tx_cnt;    // index of the bit currently on tx_ser

  // Index width only needs $clog2(MAXLEN); LENW expressions truncate cleanly.
  logic [IDXW-1:0] tx_rd_idx;
  assign tx_rd_idx = cfg_lsb_first
    ? IDXW'(tx_cnt)
    : IDXW'(tx_nbits - 1'b1 - tx_cnt);
  assign tx_ser = tx_busy ? tx_shreg[tx_rd_idx] : 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_shreg <= '0;
      tx_nbits <= '0;
      tx_cnt   <= '0;
      tx_busy  <= 1'b0;
      tx_done  <= 1'b0;
    end else begin
      tx_done <= 1'b0;
      if (tx_load && (|tx_len)) begin
        tx_shreg <= tx_data;
        tx_nbits <= tx_len;
        tx_cnt   <= '0;
        tx_busy  <= 1'b1;
      end else if (bit_en && tx_busy) begin
        if (tx_cnt == tx_nbits - 1'b1) begin
          tx_busy <= 1'b0;
          tx_done <= 1'b1;
        end else begin
          tx_cnt <= tx_cnt + 1'b1;
        end
      end
    end
  end

  // ---------------- Receive ----------------
  // Bit-placer (not a shifter): bit k of the transfer is written straight
  // to rx_shreg[pos], with pos counting 0..len-1 when LSB-first and
  // len-1..0 when MSB-first. Payload always ends up in [len-1:0].
  logic [MAXLEN-1:0] rx_shreg;
  logic [LENW-1:0]   rx_nbits;  // snapshot of rx_len at start
  logic [LENW-1:0]   rx_cnt;    // number of bits captured so far
  logic [IDXW-1:0]   rx_pos;    // write position for the incoming bit

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_shreg <= '0;
      rx_nbits <= '0;
      rx_cnt   <= '0;
      rx_pos   <= '0;
      rx_data  <= '0;
      rx_busy  <= 1'b0;
      rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (rx_start && (|rx_len)) begin
        rx_shreg <= '0;
        rx_nbits <= rx_len;
        rx_cnt   <= '0;
        rx_pos   <= cfg_lsb_first ? '0 : IDXW'(rx_len - 1'b1);
        rx_busy  <= 1'b1;
      end else if (bit_en && rx_busy) begin
        rx_shreg[rx_pos] <= rx_ser;
        if (rx_cnt == rx_nbits - 1'b1) begin
          rx_busy <= 1'b0;
          rx_valid <= 1'b1;
          // rx_shreg[rx_pos] takes effect next cycle; forward the last bit.
          rx_data <= rx_shreg | ({{(MAXLEN-1){1'b0}}, rx_ser} << rx_pos);
        end else begin
          rx_cnt <= rx_cnt + 1'b1;
          rx_pos <= cfg_lsb_first ? rx_pos + 1'b1 : rx_pos - 1'b1;
        end
      end
    end
  end

endmodule
