// tb_pe_i2c.v — I2C master framing around pe_serdes (7-bit addressing).
//
// Open-drain wire modeled at logic level: released = 1, driven low = 0.
// The SERDES pumps data bytes MSB-first; the TB generates SCL, models
// START/STOP/ACK. A slave model shift register replies on reads.

`timescale 1ns / 1ps

module tb_pe_i2c;

  localparam int MAXLEN = 32;
  localparam int LENW = $clog2(MAXLEN + 1);
  localparam int H = 8;  // clk cycles per SCL half period

  logic              clk, rst_n;
  logic              cfg_lsb_first, bit_en;
  logic              tx_load, tx_ser, tx_busy, tx_done;
  logic [MAXLEN-1:0] tx_data;
  logic [LENW-1:0]   tx_len;
  logic              rx_ser, rx_start, rx_busy, rx_valid;
  logic [MAXLEN-1:0] rx_data;
  logic [LENW-1:0]   rx_len;
  logic              scl, sda;

  logic [7:0] sl_sr;  // slave shift register (read path)

  pe_serdes #(.MAXLEN(MAXLEN)) dut (.*);

  initial clk = 0;
  always #5 clk = ~clk;

  integer errors = 0;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  task automatic scl_low();   scl = 1'b0; repeat (H) @(posedge clk); #1; endtask
  task automatic scl_high();  scl = 1'b1; repeat (H) @(posedge clk); #1; endtask

  task automatic i2c_start();
    sda = 1'b1; scl_high(); sda = 1'b0; scl_low();  // SDA falls while SCL high
  endtask
  task automatic i2c_stop();
    sda = 1'b0; scl_high(); sda = 1'b1; scl_low();  // SDA rises while SCL high
  endtask

  // Master writes one byte via SERDES, slave ACKs (drives SDA low).
  task automatic m_write(input [7:0] b, input string tag);
    @(posedge clk); #1;
    cfg_lsb_first = 1'b0;  // I2C: MSB first
    tx_data = b; tx_len = 8; tx_load = 1'b1;
    @(posedge clk); #1; tx_load = 1'b0;
    for (int k = 0; k < 8; k++) begin
      scl_low(); sda = tx_ser;  // data staged while SCL low
      check(sda === b[7-k], $sformatf("%s: sda bit %0d", tag, k));
      scl_high();               // slave samples here
      scl_low();
      bit_en = 1'b1; @(posedge clk); #1; bit_en = 1'b0;  // advance tx
    end
    check(tx_done === 1'b1, {tag, ": tx_done"});
    // ACK clock: slave pulls SDA low
    sda = 1'b0; scl_high();
    check(sda === 1'b0, {tag, ": slave ACK"});
    scl_low(); sda = 1'b1;
  endtask

  // Master reads one byte from the slave model; master NACKs (SDA high).
  task automatic m_read(input [7:0] expected, input string tag);
    @(posedge clk); #1;
    cfg_lsb_first = 1'b0;
    rx_len = 8; rx_start = 1'b1;
    @(posedge clk); #1; rx_start = 1'b0;
    for (int k = 0; k < 8; k++) begin
      scl_low();
      sda = sl_sr[7];           // slave presents MSB-first while SCL low
      rx_ser = sda;
      scl_high();               // master samples here
      scl_low();
      sl_sr = {sl_sr[6:0], 1'b0};
      bit_en = 1'b1; @(posedge clk); #1; bit_en = 1'b0;  // capture rx bit
    end
    @(posedge clk); #1;  // delayed RX completion
    check(rx_valid === 1'b1, {tag, ": rx_valid"});
    check(rx_data[7:0] === expected, {tag, ": payload"});
    // NACK clock: master leaves SDA high
    sda = 1'b1; scl_high(); scl_low();
  endtask

  initial begin
    $dumpfile("tb_pe_i2c.vcd");
    $dumpvars(0, tb_pe_i2c);
    rst_n = 0; scl = 1; sda = 1; bit_en = 0;
    cfg_lsb_first = 0; tx_load = 0; tx_data = 0; tx_len = 0;
    rx_ser = 0; rx_start = 0; rx_len = 0; sl_sr = '0;
    repeat (3) @(posedge clk); #1; rst_n = 1;
    @(posedge clk); #1;

    // Write transaction: START, addr 0x50 W (0xA0), data 0x5A, STOP
    i2c_start();
    m_write(8'hA0, "i2c addr-w");
    m_write(8'h5A, "i2c data");
    i2c_stop();
    // Read transaction: START, addr 0x50 R (0xA1), read 0x77, NACK, STOP
    sl_sr = 8'h77;
    i2c_start();
    m_write(8'hA1, "i2c addr-r");
    m_read(8'h77, "i2c read");
    i2c_stop();
    // Repeated start: write then read back-to-back
    sl_sr = 8'h3C;
    i2c_start();
    m_write(8'hA0, "i2c rep addr-w");
    i2c_start();  // repeated START (no STOP)
    m_write(8'hA1, "i2c rep addr-r");
    m_read(8'h3C, "i2c rep read");
    i2c_stop();

    if (errors == 0) $display("PASS: tb_pe_i2c");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
