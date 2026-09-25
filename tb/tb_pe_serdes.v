// tb_pe_serdes.v — self-checking testbench for pe_serdes.
// Covers: UART-style LSB-first TX, SPI-style MSB-first TX (8/16/32b),
// TX+RX loopback both orders, 1-bit and 32-bit boundaries, zero-length
// ignore, busy flags, idle-high tx_ser.
//
// Discipline: inputs driven with BLOCKING assignments after a #1 settle
// past the posedge, so checks always observe settled (post-NBA) values.

`timescale 1ns / 1ps

module tb_pe_serdes;

  localparam int MAXLEN = 32;
  localparam int LENW = $clog2(MAXLEN + 1);

  logic              clk;
  logic              rst_n;
  logic              cfg_lsb_first;
  // The enable was ONE port; the integration splits it (pe_serdes.v header).
  // Most cases here drive both in lockstep (the old single bit_en behaviour);
  // the directed split case at the end drives them DIFFERENTLY, because with
  // stuffing TX holds on inserted cells while RX skips received ones.
  logic              tx_bit_en;
  logic              rx_bit_en;
  logic              tx_load;
  logic [MAXLEN-1:0] tx_data;
  logic [LENW-1:0]   tx_len;
  logic              tx_ser;
  logic              tx_busy;
  logic              tx_done;
  logic              rx_ser;
  logic              rx_start;
  logic [LENW-1:0]   rx_len;
  logic [MAXLEN-1:0] rx_data;
  logic              rx_busy;
  logic              rx_valid;

  pe_serdes #(.MAXLEN(MAXLEN)) dut (.*);

  initial clk = 0;
  always #5 clk = ~clk;  // 100 MHz sim clock; the bit_en strobes are per side

  integer errors = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s @%0t", msg, $time);
      errors++;
    end
  endtask

  // Advance one full bit cell: both side enables high across exactly one
  // posedge, then settle so the DUT outputs can be checked.
  task automatic strobe();
    #1;
    tx_bit_en = 1'b1;
    rx_bit_en = 1'b1;
    @(posedge clk);
    #1;
    tx_bit_en = 1'b0;
    rx_bit_en = 1'b0;
  endtask

  // One side at a time: these are what the split-port directed case uses.
  task automatic tx_stroke(input int n);
    repeat (n) begin
      #1;
      tx_bit_en = 1'b1; rx_bit_en = 1'b0;
      @(posedge clk);
      #1;
      tx_bit_en = 1'b0;
    end
  endtask

  task automatic rx_stroke(input int n);
    repeat (n) begin
      #1;
      rx_bit_en = 1'b1; tx_bit_en = 1'b0;
      @(posedge clk);
      #1;
      rx_bit_en = 1'b0;
    end
  endtask

  // Expected TX bit k for given order (only low len bits of data are sent).
  function automatic bit tx_bit(input bit lsb, input [MAXLEN-1:0] d,
                               input int len, input int k);
    return lsb ? d[k] : d[len - 1 - k];
  endfunction

  // Full TX-only transfer check.
  task automatic check_tx(input bit lsb, input [MAXLEN-1:0] d,
                          input int len, input string tag);
    @(posedge clk);
    #1;
    cfg_lsb_first = lsb;
    tx_data = d;
    tx_len = LENW'(len);
    tx_load = 1'b1;
    @(posedge clk);  // DUT captures load here
    #1;
    tx_load = 1'b0;
    check(tx_busy === 1'b1, {tag, ": busy after load"});
    for (int k = 0; k < len; k++) begin
      check(tx_ser === tx_bit(lsb, d, len, k),
            $sformatf("%s: tx bit %0d", tag, k));
      strobe();
    end
    check(tx_done === 1'b1, {tag, ": done pulses"});
    check(tx_busy === 1'b0, {tag, ": busy drops"});
    @(posedge clk);
    #1;
    check(tx_done === 1'b0, {tag, ": done is single-cycle"});
  endtask

  // TX+RX loopback: rx_ser follows tx_ser each cell.
  task automatic check_loopback(input bit lsb, input [MAXLEN-1:0] d,
                                input int len, input string tag);
    logic [MAXLEN-1:0] mask;
    mask = (len == MAXLEN) ? '1 : ((36'b1 << len) - 1'b1);
    @(posedge clk);
    #1;
    cfg_lsb_first = lsb;
    tx_data = d;
    tx_len = LENW'(len);
    rx_len = LENW'(len);
    tx_load = 1'b1;
    rx_start = 1'b1;
    @(posedge clk);  // DUT captures load/start here
    #1;
    tx_load = 1'b0;
    rx_start = 1'b0;
    check(tx_busy && rx_busy, {tag, ": both busy"});
    for (int k = 0; k < len; k++) begin
      rx_ser = tx_ser;  // loopback wire
      strobe();
    end
    check(tx_done === 1'b1, {tag, ": tx done"});
    // RX completion is delayed one cycle past the final strobe (by design).
    @(posedge clk);
    #1;
    check(rx_valid === 1'b1, {tag, ": rx valid"});
    check((rx_data & mask) === (d & mask), {tag, ": payload matches"});
    check(rx_busy === 1'b0, {tag, ": rx busy drops"});
  endtask

  initial begin
    $dumpfile("pe_serdes.vcd");
    $dumpvars(0, tb_pe_serdes);
    // init
    rst_n = 0; cfg_lsb_first = 0; tx_bit_en = 0; rx_bit_en = 0;
    tx_load = 0; tx_data = 0; tx_len = 0;
    rx_ser = 0; rx_start = 0; rx_len = 0;
    repeat (3) @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk);
    #1;

    check(tx_ser === 1'b1, "idle: tx_ser high");
    check(!tx_busy && !rx_busy, "idle: not busy");

    // UART-style: LSB-first 8b
    check_tx(1'b1, 32'hA5, 8, "uart8");
    // SPI-style: MSB-first 8b / 16b / 32b
    check_tx(1'b0, 32'h3C, 8, "spi8");
    check_tx(1'b0, 32'hCAFE, 16, "spi16");
    check_tx(1'b0, 32'hDEADBEEF, 32, "spi32");
    // 1-bit boundary, both orders
    check_tx(1'b1, 32'h1, 1, "lsb1");
    check_tx(1'b0, 32'h80000000, 1, "msb1");
    // odd I2C-ish length, MSB-first 9b (8b + ACK slot shape)
    check_tx(1'b0, 32'h1A5, 9, "i2c9");

    // loopbacks
    check_loopback(1'b1, 32'hA5, 8, "lb-uart8");
    check_loopback(1'b0, 32'hCAFE, 16, "lb-spi16");
    check_loopback(1'b0, 32'hDEADBEEF, 32, "lb-spi32");
    check_loopback(1'b1, 32'h1, 1, "lb-lsb1");

    // zero length ignored
    @(posedge clk);
    #1;
    tx_len = 0; tx_load = 1'b1;
    @(posedge clk);
    #1;
    tx_load = 1'b0;
    check(!tx_busy && !tx_done, "len0: tx ignored");
    @(posedge clk);
    #1;
    rx_len = 0; rx_start = 1'b1;
    @(posedge clk);
    #1;
    rx_start = 1'b0;
    check(!rx_busy && !rx_valid, "len0: rx ignored");

    // restart-while-busy
    @(posedge clk);
    #1;
    cfg_lsb_first = 1'b0; tx_data = 32'hFF; tx_len = 8; tx_load = 1'b1;
    @(posedge clk);
    #1;
    tx_load = 1'b0;
    strobe(); strobe();
    tx_data = 32'h00; tx_load = 1'b1;  // restart mid-transfer
    @(posedge clk);
    #1;
    tx_load = 1'b0;
    check(tx_ser === 1'b0, "restart: new data bit0 out");

    // ---- split enables: the two sides advance INDEPENDENTLY -------------
    // This is the port split's whole reason: TX holds/skips on its own
    // payload-only sequence while RX runs a different one (stuffed loopback,
    // DRU decode latency, independent TXLEN/RXLEN). Each side must ignore
    // the other's strobes completely.
    @(posedge clk);
    #1;
    cfg_lsb_first = 1'b1;
    tx_data = 32'hF0; tx_len = 8; tx_load = 1'b1;   // TX: 0,0,0,0,1,1,1,1
    rx_len  = 8;      rx_start = 1'b1;
    @(posedge clk);
    #1;
    tx_load = 1'b0; rx_start = 1'b0;
    rx_ser  = 1'b0;
    tx_stroke(4);                            // TX advances alone
    check(tx_ser === 1'b1, "split: TX advanced to bit4 (0xF0 lsb-first) with RX quiet");
    check(tx_busy && !tx_done, "split: TX not done after 4 of 8");
    check(rx_busy && !rx_valid, "split: RX did NOT advance on TX-only strobes");
    rx_stroke(4);                            // RX captures 0000 alone
    check(!tx_done && tx_ser === 1'b1,
          "split: TX did NOT advance on RX-only strobes");
    rx_ser = 1'b1;
    tx_stroke(4);                            // TX completes alone
    check(tx_done === 1'b1 && tx_busy === 1'b0,
          "split: TX done after exactly 8 TX strobes");
    rx_stroke(4);                            // RX completes: bits 4..7 = 1
    @(posedge clk);
    #1;
    check(rx_valid === 1'b1, "split: RX valid after exactly 8 RX strobes");
    check(rx_data[7:0] === 8'hF0,
          $sformatf("split: rx_data = %02h, want F0 (4 zeros then 4 ones)", rx_data[7:0]));

    if (errors == 0) $display("PASS: all pe_serdes checks");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
