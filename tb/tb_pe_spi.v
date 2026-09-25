// tb_pe_spi.v — SPI mode 0 (CPOL=0, CPHA=0) full duplex around pe_serdes.
//
// Master: MOSI from SERDES tx (MSB-first), MISO into SERDES rx.
// Slave model: shift registers; samples MOSI on SCLK rising, presents
// MISO during the low phase. CS gates the frame. Self-checking.

`timescale 1ns / 1ps

module tb_pe_spi;

  localparam int MAXLEN = 32;
  localparam int LENW = $clog2(MAXLEN + 1);
  localparam int H = 8;  // clk cycles per SCLK half period

  logic              clk, rst_n;
  logic              cfg_lsb_first, bit_en;
  logic              tx_load, tx_ser, tx_busy, tx_done;
  logic [MAXLEN-1:0] tx_data;
  logic [LENW-1:0]   tx_len;
  logic              rx_ser, rx_start, rx_busy, rx_valid;
  logic [MAXLEN-1:0] rx_data;
  logic [LENW-1:0]   rx_len;
  logic              sclk, cs_n, mosi, miso;

  // Sticky event flags: single-cycle pulses get missed behind trailing
  // protocol timing; the core would latch interrupts the same way.
  logic tx_done_seen, rx_valid_seen;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin tx_done_seen <= 0; rx_valid_seen <= 0; end
    else begin
      if (tx_done)  tx_done_seen  <= 1'b1;
      if (rx_valid) rx_valid_seen <= 1'b1;
    end

  logic [MAXLEN-1:0] sl_rx_sr;  // slave->master shadow (data master sent)
  logic [MAXLEN-1:0] sl_tx_sr;  // master->slave response shift

  pe_serdes #(.MAXLEN(MAXLEN)) dut (.*, .tx_bit_en(bit_en), .rx_bit_en(bit_en));

  initial clk = 0;
  always #5 clk = ~clk;

  integer errors = 0;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // Full-duplex transfer of n bits. rsp must be pre-shifted into the
  // slave sr top bits by the caller.
  task automatic xfer(input [MAXLEN-1:0] mw, input int n,
                      input [MAXLEN-1:0] rsp,
                      output [MAXLEN-1:0] mr);
    cs_n = 1'b0;
    tx_done_seen = 1'b0; rx_valid_seen = 1'b0;
    @(posedge clk); #1;
    cfg_lsb_first = 1'b0;  // SPI: MSB first
    tx_data = mw; tx_len = LENW'(n); tx_load = 1'b1;
    rx_len = LENW'(n); rx_start = 1'b1;
    @(posedge clk); #1; tx_load = 1'b0; rx_start = 1'b0;
    for (int k = 0; k < n; k++) begin
      // low phase: present bit k
      sclk = 1'b0; #1;
      mosi = tx_ser;                  // master bit k (MSB-first)
      miso = sl_tx_sr[MAXLEN-1];      // slave response bit k
      rx_ser = miso;
      check(mosi === mw[n-1-k], $sformatf("spi: mosi bit %0d", k));
      // rising edge: slave samples MOSI
      repeat (H) @(posedge clk); #1;
      sclk = 1'b1;
      sl_rx_sr = {sl_rx_sr[MAXLEN-2:0], mosi};
      // falling edge: slave advances response
      repeat (H) @(posedge clk); #1;
      sclk = 1'b0;
      sl_tx_sr = {sl_tx_sr[MAXLEN-2:0], 1'b0};
      // strobe SERDES: rx captures response bit k, tx advances
      bit_en = 1'b1; @(posedge clk); #1; bit_en = 1'b0;
    end
    @(posedge clk); #1;  // delayed RX completion
    repeat (2) @(posedge clk); #1;
    check(rx_valid_seen === 1'b1, "spi: rx_valid");
    check(tx_done_seen === 1'b1, "spi: tx_done");
    mr = rx_data;
    cs_n = 1'b1;
    repeat (H) @(posedge clk);
  endtask

  logic [MAXLEN-1:0] mr;

  initial begin
    $dumpfile("tb_pe_spi.vcd");
    $dumpvars(0, tb_pe_spi);
    rst_n = 0; cs_n = 1; sclk = 0; bit_en = 0; mosi = 0; miso = 0;
    cfg_lsb_first = 0; tx_load = 0; tx_data = 0; tx_len = 0;
    rx_ser = 0; rx_start = 0; rx_len = 0;
    sl_rx_sr = '0; sl_tx_sr = '0;
    repeat (3) @(posedge clk); #1; rst_n = 1;
    @(posedge clk); #1;

    // 8-bit exchange
    sl_tx_sr = 8'hA7 << (MAXLEN - 8);
    xfer(8'hC3, 8, 8'hA7, mr);
    check(sl_rx_sr[7:0] === 8'hC3, "spi8: slave got master word");
    check(mr[7:0] === 8'hA7, "spi8: master got slave word");
    // 16-bit exchange
    sl_rx_sr = '0;
    sl_tx_sr = 16'hBEEF << (MAXLEN - 16);
    xfer(16'hCAFE, 16, 16'hBEEF, mr);
    check(sl_rx_sr[15:0] === 16'hCAFE, "spi16: slave got master word");
    check(mr[15:0] === 16'hBEEF, "spi16: master got slave word");
    // 32-bit exchange
    sl_rx_sr = '0;
    sl_tx_sr = 32'h0BADF00D;
    xfer(32'hDEADBEEF, 32, 32'h0BADF00D, mr);
    check(sl_rx_sr[31:0] === 32'hDEADBEEF, "spi32: slave got master word");
    check(mr[31:0] === 32'h0BADF00D, "spi32: master got slave word");

    if (errors == 0) $display("PASS: tb_pe_spi");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
