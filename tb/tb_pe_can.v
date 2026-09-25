// tb_pe_can.v — CAN 2.0 classic frame bit-level model around pe_serdes.
//
// NRZ + bit stuffing (after 5 identical consecutive bits a complementary
// stuff bit is inserted). The SERDES carries ONE DATA BYTE (8 bits,
// MSB-first) per word — multi-byte payloads are chunked per byte, which
// is exactly how the core will drive it. The TB models the full frame:
// SOF, arbitration (11b), control (6b), data (1 byte here), 15-bit CRC
// over destuffed bits, ACK slot, EOF. Stuffing spans SOF..CRC.

`timescale 1ns / 1ps

module tb_pe_can;

  localparam int MAXLEN = 32;
  localparam int LENW = $clog2(MAXLEN + 1);
  localparam int H = 8;

  logic              clk, rst_n;
  logic              cfg_lsb_first, bit_en;
  logic              tx_load, tx_ser, tx_busy, tx_done;
  logic [MAXLEN-1:0] tx_data;
  logic [LENW-1:0]   tx_len;
  logic              rx_ser, rx_start, rx_busy, rx_valid;
  logic [MAXLEN-1:0] rx_data;
  logic [LENW-1:0]   rx_len;
  logic              can_rx;

  pe_serdes #(.MAXLEN(MAXLEN)) dut (.*, .tx_bit_en(bit_en), .rx_bit_en(bit_en));

  initial clk = 0;
  always #5 clk = ~clk;

  integer errors = 0;

  logic tx_done_seen, rx_valid_seen;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin tx_done_seen <= 0; rx_valid_seen <= 0; end
    else begin
      if (tx_done)  tx_done_seen  <= 1'b1;
      if (rx_valid) rx_valid_seen <= 1'b1;
    end

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  task automatic bit_cell();
    repeat (H) @(posedge clk); #1;
  endtask

  // CRC-15 CAN poly: x^15+x^14+x^10+x^8+x^7+x^4+x^3+1 (0x4599).
  // bits[] is MSB-first: index n-1 = first bit on the wire.
  function automatic [14:0] crc15(input [63:0] bits, input int n);
    logic [14:0] crc;
    logic b, fb;
    crc = '0;
    for (int i = n - 1; i >= 0; i--) begin
      b   = bits[i];
      fb  = b ^ crc[14];
      crc = {crc[13:0], 1'b0};
      if (fb) crc ^= 15'h4599;
    end
    return crc;
  endfunction

  // Stuffed-wire sender: pushes a destuffed bit sequence onto the wire,
  // inserting stuff bits; returns the stuffed stream + count.
  logic run_last;
  int   run_len;
  logic run_last_before_data;  // snapshots for the receiver's tracker
  int   run_len_before_data;
  task automatic stuff_send(input [63:0] bits, input int n,
                            inout logic [127:0] stuffed, inout int sc);
    for (int i = n - 1; i >= 0; i--) begin
      can_rx = bits[i];
      stuffed[sc] = bits[i]; sc++;
      if (bits[i] == run_last) begin
        run_len++;
        if (run_len == 5) begin
          can_rx = ~run_last;      // stuff bit
          stuffed[sc] = ~run_last; sc++;
          run_last = ~run_last; run_len = 1;
        end
      end else begin
        run_last = bits[i]; run_len = 1;
      end
      bit_cell();
    end
  endtask

  // One CAN frame with a single data byte (chunked per byte by design).
  task automatic can_frame(input [10:0] arb, input [7:0] data,
                           input string tag);
    logic [63:0] seq;      // destuffed SOF..CRC (1+11+6+8+15 = 41 bits)
    logic [127:0] stuffed;
    int sc, seq_n;
    logic [14:0] crc;

    seq = '0; seq_n = 0;
    seq[seq_n++] = 1'b0;                              // SOF
    for (int i = 10; i >= 0; i--) seq[seq_n++] = arb[i];
    for (int i = 0; i < 6; i++)                        // IDE,r0,DLC=1
      seq[seq_n++] = (i >= 3) ? (i == 5) : 1'b0;      // DLC bits 3..0 -> 0001
    for (int i = 7; i >= 0; i--) seq[seq_n++] = data[i];
    crc = crc15(seq, seq_n);
    for (int i = 14; i >= 0; i--) seq[seq_n++] = crc[i];

    // SERDES word = the single data byte, MSB-first
    @(posedge clk); #1;
    cfg_lsb_first = 1'b0;
    tx_data = data; tx_len = 8; tx_load = 1'b1;
    rx_len = 8; rx_start = 1'b1;
    tx_done_seen = 1'b0; rx_valid_seen = 1'b0;
    @(posedge clk); #1; tx_load = 1'b0; rx_start = 1'b0;

    // Wire: SOF+arb+ctrl stuffed, then data (strobe per DESTUFFED bit),
    // then CRC stuffed. Receiver destuffs on the fly: it mirrors the
    // run-length tracker and skips stuff bits.
    stuffed = '0; sc = 0;
    run_last = 1'b1; run_len = 1;  // bus idle recessive counts as run of 1s
    stuff_send(seq, 1 + 11 + 6, stuffed, sc);
    run_last_before_data = run_last; run_len_before_data = run_len;
    begin : data_phase
      int sc0;
      sc0 = sc;
      stuff_send(seq >> (1 + 11 + 6), 8, stuffed, sc);
      // Walk the stuffed stream, skipping inserted stuff bits. Mirror
      // the TX run tracker: when the run of identical bits reaches 5,
      // the CURRENT bit is still real data — the NEXT wire bit is the
      // stuff bit and must be skipped.
      begin
        logic lv, b; int rl, k;
        lv = run_last_before_data; rl = run_len_before_data;
        k = 0;  // destuffed data bit index
        for (int i = sc0; i < sc; i++) begin
          b = stuffed[i];
          if (b == lv) rl++;
          else begin lv = b; rl = 1; end
          rx_ser = b;  // real data bit k
          bit_en = 1'b1; @(posedge clk); #1; bit_en = 1'b0;
          k++;
          if (rl == 5) begin
            i++;            // skip the stuff bit that follows
            lv = ~b; rl = 1;
          end
        end
        check(k == 8, {tag, ": 8 destuffed data bits"});
      end
    end
    stuff_send(seq >> (1 + 11 + 6 + 8), 15, stuffed, sc);
    // CRC delimiter, ACK slot (a receiver drives dominant), ACK delim,
    // EOF x7, intermission x3 — all recessive except the ACK slot.
    can_rx = 1'b1; bit_cell();
    can_rx = 1'b0; bit_cell();
    check(can_rx === 1'b0, {tag, ": ACK slot dominant"});
    can_rx = 1'b1; bit_cell();
    repeat (10) bit_cell();

    repeat (2) @(posedge clk); #1;
    check(rx_valid_seen === 1'b1, {tag, ": rx_valid"});
    check(tx_done_seen === 1'b1, {tag, ": tx_done"});
    check(rx_data[7:0] === data, {tag, ": data byte"});
  endtask

  initial begin
    $dumpfile("tb_pe_can.vcd");
    $dumpvars(0, tb_pe_can);
    rst_n = 0; can_rx = 1; bit_en = 0;
    cfg_lsb_first = 0; tx_load = 0; tx_data = 0; tx_len = 0;
    rx_ser = 0; rx_start = 0; rx_len = 0;
    repeat (3) @(posedge clk); #1; rst_n = 1;
    @(posedge clk); #1;

    can_frame(11'h5A3, 8'h3C, "can 3C");
    can_frame(11'h123, 8'h00, "can 00");  // stuffing edge case: zero byte
    can_frame(11'h7FF, 8'hFF, "can FF");  // stuffing edge case: ones byte

    if (errors == 0) $display("PASS: tb_pe_can");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
