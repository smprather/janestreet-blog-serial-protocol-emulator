// tb_pe_eth.v — 10BASE-T Manchester framing around pe_serdes.
//
// Manchester (802.3): 0 = H->L mid-bit, 1 = L->H. Preamble (56
// alternating) + SFD + MAC frame. The SERDES carries ONE 32-bit word
// (4 bytes, MSB-first) per transfer — longer payloads chunk per word,
// which is how the core drives it. FCS/CRC-32 is computed in the model
// (hardware LFSR block's job, not the SERDES').

`timescale 1ns / 1ps

module tb_pe_eth;

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
  logic              wire_lvl;

  pe_serdes #(.MAXLEN(MAXLEN)) dut (.*);

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

  task automatic man_send(input bit b);
    if (b == 1'b0) begin
      wire_lvl = 1'b1; bit_cell();
      wire_lvl = 1'b0; bit_cell();  // H->L mid-bit
    end else begin
      wire_lvl = 1'b0; bit_cell();
      wire_lvl = 1'b1; bit_cell();  // L->H mid-bit
    end
  endtask

  // CRC-32 (FCS: reflected, init FFFFFFFF, final xor).
  function automatic [31:0] crc32(input [127:0] bits, input int n);
    logic [31:0] crc;
    logic b, fb;
    crc = 32'hFFFFFFFF;
    for (int i = n - 1; i >= 0; i--) begin
      b   = bits[i];
      fb  = b ^ crc[0];
      crc = {1'b0, crc[31:1]};
      if (fb) crc ^= 32'hEDB88320;
    end
    return ~crc;
  endfunction

  // One frame: preamble + SFD + dst/src/len header + 4-byte payload
  // (one SERDES word, MSB-first) + FCS. Loopback checks payload.
  logic [127:0] fcs_seq;
  int           fcs_n;
  logic [31:0]  fcs;

  task automatic eth_frame(input [31:0] payload, input string tag);
    for (int i = 0; i < 28; i++) begin
      man_send(1'b1); man_send(1'b0);  // preamble
    end
    man_send(1'b1); man_send(1'b1);    // SFD
    fcs_seq = '0; fcs_n = 0;
    for (int i = 0; i < 6; i++)         // dst FF:FF:FF:FF:FF:FF
      for (int k = 7; k >= 0; k--) begin
        fcs_seq[fcs_n++] = 1'b1; man_send(1'b1);
      end
    for (int i = 0; i < 6; i++)         // src 02:00:00:00:00:00
      for (int k = 7; k >= 0; k--) begin
        fcs_seq[fcs_n++] = (i == 0 && k == 1);
        man_send((i == 0 && k == 1));
      end
    for (int k = 15; k >= 0; k--) begin // length = 4
      fcs_seq[fcs_n++] = (k == 2);      // 0x0004
      man_send((k == 2));
    end
    // payload: one 32-bit SERDES word, MSB-first
    @(posedge clk); #1;
    cfg_lsb_first = 1'b0;
    tx_data = payload; tx_len = 32; tx_load = 1'b1;
    rx_len = 32; rx_start = 1'b1;
    tx_done_seen = 1'b0; rx_valid_seen = 1'b0;
    @(posedge clk); #1; tx_load = 1'b0; rx_start = 1'b0;
    for (int k = 31; k >= 0; k--) begin
      rx_ser = tx_ser;  // loopback at the bit level
      fcs_seq[fcs_n++] = tx_ser;
      man_send(tx_ser);
      bit_en = 1'b1; @(posedge clk); #1; bit_en = 1'b0;
    end
    // FCS on the wire
    fcs = crc32(fcs_seq, fcs_n);
    for (int k = 31; k >= 0; k--) man_send(fcs[k]);
    // IPG
    wire_lvl = 1'b0; repeat (8) bit_cell();

    repeat (2) @(posedge clk); #1;
    check(rx_valid_seen === 1'b1, {tag, ": rx_valid"});
    check(tx_done_seen === 1'b1, {tag, ": tx_done"});
    check(rx_data[31:0] === payload, {tag, ": payload word"});
  endtask

  initial begin
    $dumpfile("tb_pe_eth.vcd");
    $dumpvars(0, tb_pe_eth);
    rst_n = 0; wire_lvl = 0; bit_en = 0;
    cfg_lsb_first = 0; tx_load = 0; tx_data = 0; tx_len = 0;
    rx_ser = 0; rx_start = 0; rx_len = 0; fcs_seq = '0; fcs_n = 0;
    repeat (3) @(posedge clk); #1; rst_n = 1;
    @(posedge clk); #1;

    eth_frame(32'h11223344, "eth w1");
    eth_frame(32'h000000FF, "eth w2");
    eth_frame(32'hFFFFFFFF, "eth w3");
    eth_frame(32'h80000001, "eth w4");

    if (errors == 0) $display("PASS: tb_pe_eth");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
