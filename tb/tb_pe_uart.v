// tb_pe_uart.v — 8N1 UART framing around pe_serdes.
//
// The SERDES pumps the 8-bit data field; the testbench models the
// start/stop framing (in the real design that's the core/DRU's job).
// LSB-first, line idles high. Self-checking both directions.

`timescale 1ns / 1ps

module tb_pe_uart;

  localparam int MAXLEN = 32;
  localparam int LENW = $clog2(MAXLEN + 1);
  localparam int BP = 16;  // clk cycles per bit cell

  logic              clk, rst_n;
  logic              cfg_lsb_first, bit_en;
  logic              tx_load, tx_ser, tx_busy, tx_done;
  logic [MAXLEN-1:0] tx_data;
  logic [LENW-1:0]   tx_len;
  logic              rx_ser, rx_start, rx_busy, rx_valid;
  logic [MAXLEN-1:0] rx_data;
  logic [LENW-1:0]   rx_len;
  logic              line;  // UART wire

  // Sticky event flags: tx_done/rx_valid are single-cycle pulses, and
  // protocol framing (stop bits etc.) runs past them before we check.
  logic tx_done_seen, rx_valid_seen;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin tx_done_seen <= 0; rx_valid_seen <= 0; end
    else begin
      if (tx_done)  tx_done_seen  <= 1'b1;
      if (rx_valid) rx_valid_seen <= 1'b1;
    end

  pe_serdes #(.MAXLEN(MAXLEN)) dut (.*, .tx_bit_en(bit_en), .rx_bit_en(bit_en));

  initial clk = 0;
  always #5 clk = ~clk;

  integer errors = 0;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // One bit cell with the SERDES strobe at its start.
  task automatic bitcell();
    #1; bit_en = 1'b1; @(posedge clk); #1; bit_en = 1'b0;
    repeat (BP - 1) @(posedge clk);
  endtask

  task automatic idle_cell();
    repeat (BP) @(posedge clk);
  endtask

  // Host sends a byte: start(0) + 8 data via SERDES + stop(1).
  task automatic uart_send(input [7:0] b);
    line = 1'b0; idle_cell();  // start bit
    @(posedge clk); #1;
    cfg_lsb_first = 1'b1; tx_data = b; tx_len = 8; tx_load = 1'b1;
    tx_done_seen = 1'b0;
    @(posedge clk); #1; tx_load = 1'b0;
    for (int k = 0; k < 8; k++) begin
      line = tx_ser;  // bit k (LSB-first)
      check(line === b[k], $sformatf("uart tx: bit %0d wire", k));
      bitcell();
      check(line === b[k], $sformatf("uart tx: bit %0d held", k));
    end
    repeat (2) @(posedge clk); #1;
    check(tx_done_seen === 1'b1, "uart tx: done after last data cell");
    check(tx_busy === 1'b0, "uart tx: busy drops");
    line = 1'b1; idle_cell();  // stop bit
    check(line === 1'b1, "uart tx: stop high");
  endtask

  // Far end sends a byte; DUT receives the data field.
  task automatic uart_recv(input [7:0] b, input string tag);
    @(posedge clk); #1;
    line = 1'b0; idle_cell();  // start
    cfg_lsb_first = 1'b1; rx_len = 8; rx_start = 1'b1;
    rx_valid_seen = 1'b0;
    @(posedge clk); #1; rx_start = 1'b0;
    for (int k = 0; k < 8; k++) begin
      line = b[k];
      rx_ser = line;
      bitcell();
    end
    line = 1'b1; idle_cell();  // stop
    repeat (2) @(posedge clk); #1;
    check(rx_valid_seen === 1'b1, {tag, ": rx_valid"});
    check(rx_data[7:0] === b, {tag, ": payload"});
  endtask

  initial begin
    $dumpfile("tb_pe_uart.vcd");
    $dumpvars(0, tb_pe_uart);
    rst_n = 0; line = 1; bit_en = 0;
    cfg_lsb_first = 1; tx_load = 0; tx_data = 0; tx_len = 0;
    rx_ser = 0; rx_start = 0; rx_len = 0;
    repeat (3) @(posedge clk); #1; rst_n = 1;
    @(posedge clk); #1;

    uart_send(8'h55);
    uart_send(8'hA5);
    uart_send(8'h00);
    uart_send(8'hFF);
    uart_recv(8'h3C, "uart rx 3C");
    uart_recv(8'hC3, "uart rx C3");
    uart_recv(8'hFF, "uart rx FF");
    uart_recv(8'h00, "uart rx 00");

    if (errors == 0) $display("PASS: tb_pe_uart");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
