// tb_tt_um_protocol_emulator.v — the Tiny Tapeout pad contract.
//
// This testbench does not test the UART. tb_pe_soc_uart.v does that, against
// the SoC directly. What this checks is the part that only exists at the top
// level, where the mistakes are made once and discovered after tapeout:
//
//   1. NO OUTPUT IS EVER X. An undriven uo_out bit is a floating pad. Verilog
//      will happily leave one unassigned and simulation will happily not care
//      until somebody reads a waveform.
//   2. `ena` GATES NOTHING. The harness holds ena low for every design it has
//      not selected, and the multiplexer is not glitch-free. A design that
//      gates its clock, its reset or its outputs with ena can come back dead.
//      The check is behavioural: toggle ena, and nothing may move.
//   3. THE OPEN-DRAIN PINS NEVER DRIVE HIGH. uio_out must be 0 on any pin used
//      for I2C, for every cycle, so the only states are "drive low" and
//      "release". Two masters driving an I2C bus high is a short, and this is
//      the property the pin matrix will have to preserve.
//   4. Released pins have uio_oe low, so the external pull-up owns the line.
//
// Points 2 and 3 are the ones worth having a machine check, because both are
// invisible in a functional test that only looks at the protocol.

`timescale 1ns / 1ps

module tb_tt_um_protocol_emulator;
  // Must match the SoC's CLK_HZ: this TB drives the real top level, so its
  // period is the operating point (60 MHz, ADR-005), not an arbitrary stimulus.
  localparam real CLK_NS = 1e9 / 60e6;   // 60 MHz -> 16.667 ns

  logic       clk = 0, rst_n, ena;
  logic [7:0] ui_in, uio_in;
  wire  [7:0] uo_out, uio_out, uio_oe;

  tt_um_protocol_emulator dut (
    .ui_in(ui_in), .uo_out(uo_out),
    .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
    .ena(ena), .clk(clk), .rst_n(rst_n)
  );

  always #(CLK_NS/2) clk = ~clk;

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---- pe_ctrl host-side driver (SPI mode 0) ---------------------------
  task automatic spi_bit(input logic b);
    ui_in[4] = b;             // MOSI, held while SCLK is low
    #(100);
    ui_in[3] = 1'b1;          // SCLK rise: the loader samples MOSI here
    #(100);
    ui_in[3] = 1'b0;
  endtask

  task automatic spi_word(input logic [15:0] w);
    for (int k = 15; k >= 0; k--) spi_bit(w[k]);
  endtask

  bit tx_saw_low = 1'b0, tx_saw_high = 1'b0;
  always @(posedge clk) begin
    if (ui_in[1] && uo_out[0] === 1'b0) tx_saw_low  <= 1'b1;
    if (ui_in[1] && tx_saw_low && uo_out[0] === 1'b1) tx_saw_high <= 1'b1;
  end

  // ---- continuous monitors: these must hold on EVERY cycle --------------
  // Written as always blocks rather than end-of-test samples, because "never
  // drives high" is a property of the whole run, not of one moment.
  always @(posedge clk) begin
    if (rst_n) begin
      if ($isunknown(uo_out))
        check(1'b0, "uo_out has an X bit (floating pad)");
      if ($isunknown(uio_oe))
        check(1'b0, "uio_oe has an X bit");
      if ($isunknown(uio_out))
        check(1'b0, "uio_out has an X bit");
      // Open-drain: SDA and SCL may be released or driven low, never driven high.
      if (uio_oe[0] && uio_out[0])
        check(1'b0, "uio[0]/SDA driven HIGH (open-drain violated)");
      if (uio_oe[1] && uio_out[1])
        check(1'b0, "uio[1]/SCL driven HIGH (open-drain violated)");
      // Pins 7:2 are not claimed by any protocol yet and must stay released.
      if (|uio_oe[7:2])
        check(1'b0, "an unclaimed uio pin is being driven");
    end
  end

  logic [7:0] snap_uo, snap_oe, snap_uio;

  initial begin
    $dumpfile("tb_tt_um_protocol_emulator.vcd");
    $dumpvars(0, tb_tt_um_protocol_emulator);

    ena = 1'b1;
    ui_in = 8'h20;            // CS_N high: the loader is idle
    ui_in[0] = 1'b1;          // UART RX idles high
    uio_in = 8'h00;
    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    repeat (4) @(posedge clk); #1;

    // The UART line idles high out of reset, before any firmware runs.
    check(uo_out[0] === 1'b1, "uo_out[0] (TX) idles high out of reset");

    // ---- ena must gate nothing -----------------------------------------
    // Let the design settle, snapshot every output, then drop ena for a while
    // and confirm nothing moved. The SoC is held with run=0 here so the only
    // thing that could change the outputs is ena itself.
    repeat (20) @(posedge clk); #1;
    snap_uo = uo_out; snap_oe = uio_oe; snap_uio = uio_out;

    ena = 1'b0;
    repeat (20) @(posedge clk); #1;
    check(uo_out  === snap_uo,  "uo_out changed when ena went low (ena gates logic)");
    check(uio_oe  === snap_oe,  "uio_oe changed when ena went low (ena gates logic)");
    check(uio_out === snap_uio, "uio_out changed when ena went low (ena gates logic)");

    ena = 1'b1;
    repeat (20) @(posedge clk); #1;
    check(uo_out === snap_uo, "uo_out changed when ena came back");

    // ---- the design still runs with ena asserted ------------------------
    // Sanity that the monitors above are watching something live: start the
    // core and let it execute. It has no firmware loaded (NOP fill), so the
    // program counter walks, which is visible on uo_out[7:2].
    ui_in[1] = 1'b1;          // run
    repeat (200) @(posedge clk); #1;
    check(uo_out[7:2] !== 6'b000000, "PC never advanced with run asserted");

    // ---- a program loaded through pe_ctrl actually runs ------------------
    // Hold the core, clock five words through the loader pads, release it,
    // and watch the program toggle TX. The words are hand-assembled:
    //   LDI A,1 / OUT 1,A / LDI A,0 / OUT 1,A / JMP 0
    ui_in[1] = 1'b0;          // run low: the loader may write
    #1;
    repeat (4) @(posedge clk); #1;
    ui_in[5] = 1'b0;          // CS_N low: a new load at word 0
    #(200);
    spi_word(16'h0001);       // LDI A, 1
    spi_word(16'h1001);       // OUT 1, A    (TX high)
    spi_word(16'h0000);       // LDI A, 0
    spi_word(16'h1001);       // OUT 1, A    (TX low)
    spi_word(16'h4000);       // JMP 0
    ui_in[5] = 1'b1;          // CS_N high: load done
    #(200);
    check(dut.u_ctrl.load_error === 1'b0, "loader flagged an error on a clean load");
    check(dut.u_ctrl.words_written === 16'd5,
          $sformatf("loader wrote %0d words, want 5", dut.u_ctrl.words_written));
    ui_in[1] = 1'b1;          // run the loaded program
    #1;
    repeat (200) @(posedge clk); #1;
    check(tx_saw_low && tx_saw_high,
          "the program loaded through the pads did not toggle TX");

    // ---- released pins float to the pull-up -----------------------------
    check(uio_oe === 8'h00, "all uio pins released in this revision");

    if (errors == 0) $display("PASS: tb_tt_um_protocol_emulator");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #500_000;
    $display("FAIL: watchdog");
    $finish;
  end
endmodule
