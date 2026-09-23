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
//   5. THE SPI OUTPUT PADS ARE MATRIX BITS 1 AND 2. uio[2] must mirror
//      pin_out_bus[1]/pin_oe_bus[1] (MOSI) and uio[3] pin_out_bus[2]/
//      pin_oe_bus[2] (CS_N), while SCLK stays on uo_out[0] and MISO on
//      ui_in[0]. The SPI firmware must run a real mode-0 transaction through
//      those pads, loaded over the pe_ctrl loader pads, or the mapping is
//      only a comment.
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

  // ---- pin-level SPI slave (modelled on the PADS, not the SoC port) -------
  // SCLK is port bit 0 (uo_out[0], shared with UART TX), MOSI is port bit 1
  // (uio[2]), CS_N is port bit 2 (uio[3]), and MISO is port bit 3 read from
  // ui_in[0] (shared with UART RX). The slave below watches those pads, so an
  // alias bug in the wrapper fails the same checks tb_pe_soc_spi.v applies to
  // the SoC's port bus.
  localparam logic [7:0] TX_BYTE = 8'h5B;
  localparam int N_FRAMES = 8;
  localparam logic [8*N_FRAMES-1:0] RX_SEQ =
      {8'h4F, 8'hD2, 8'h7B, 8'h3D, 8'hC1, 8'h96, 8'hE5, 8'hA7};

  wire run      = ui_in[1];
  wire sclk_pad = uo_out[0];
  wire mosi_pad = uio_oe[2] ? uio_out[2] : uio_in[2];
  wire cs_n_pad = uio_oe[3] ? uio_out[3] : 1'b1;   // released -> pull-up high

  logic [7:0] slave_tx, slave_rx;
  logic [3:0] slave_bit;
  logic       slave_active;
  integer     frame;

  // Edge split matters: the slave samples MOSI on the rise and changes MISO
  // on the fall (a rise-time change would race the master's sample).
  always @(posedge sclk_pad)
    if (run && rst_n && slave_active && slave_bit < 4'd8)
      slave_rx = {slave_rx[6:0], mosi_pad};
  always @(negedge sclk_pad)
    if (run && rst_n && slave_active) begin
      if (slave_bit < 4'd8) slave_bit = slave_bit + 1'b1;
      ui_in[0] = (slave_bit < 4'd8) ? slave_tx[7 - slave_bit[2:0]] : 1'b1;
    end
  always @(negedge cs_n_pad)
    if (run && rst_n) begin
      slave_active = 1'b1;
      slave_bit    = 4'd0;
      slave_rx     = 8'h00;
      slave_tx     = (frame < N_FRAMES) ? RX_SEQ[8*(frame+1)-1 -: 8] : 8'h00;
      ui_in[0]     = slave_tx[7];
    end
  always @(posedge cs_n_pad)
    if (run && rst_n && slave_active) begin
      slave_active = 1'b0;
      ui_in[0]     = 1'b1;
      check(slave_bit == 4'd8,
            $sformatf("SPI frame %0d had exactly 8 SCLK rises (got %0d)",
                      frame, slave_bit));
      check(slave_rx === TX_BYTE,
            $sformatf("SPI frame %0d: pad-level slave captured %02h on uio[2]/MOSI, firmware meant %02h", frame, slave_rx, TX_BYTE));
      if (frame < N_FRAMES) frame = frame + 1;
    end

  // The real firmware, read from the same hex the SoC TB and the emulator use.
  logic [15:0] spi_prog [0:1023];
  integer      spi_words;

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
      // uio[7:4] are not claimed by any protocol yet and must stay released.
      // uio[0:1] are the I2C open-drain pair; uio[2:3] the SPI MOSI/CS_N pair.
      if (|uio_oe[7:4])
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

    // ---- the SPI persona runs through the real pads ----------------------
    // Load firmware/spi_xfer.hex over the pe_ctrl loader pads (the image is
    // 70 words; the loop stops at the first uninitialised entry), then act as
    // a mode-0 slave on the SPI pads and check the same contract as
    // tb_pe_soc_spi.v: eight frames, 0x5B captured each, eight clocks per
    // CS_N frame, and the rolling receive buffer -- which proves MISO got in
    // through ui_in[0]/port bit 3.
    ui_in[1] = 1'b0;          // run low: the loader may write
    #1;
    repeat (4) @(posedge clk); #1;
    ui_in[5] = 1'b0;          // CS_N low: a new load at word 0
    #(200);
    // Load the full image the way the emulator does: NOP fill, then the file.
    // ($readmemh still notes the file is shorter than the array; the NOP fill
    // is what the core would fetch past the image.)
    for (spi_words = 0; spi_words < 1024; spi_words++)
      spi_prog[spi_words] = 16'hF000;
    $readmemh("../firmware/spi_xfer.hex", spi_prog);
    for (spi_words = 0; spi_words < 1024; spi_words++)
      spi_word(spi_prog[spi_words]);
    ui_in[5] = 1'b1;          // CS_N high: load done
    #(200);
    $display("    loaded %0d words (image + NOP fill) through the loader pads",
             spi_words);
    check(spi_words == 1024, "the full program image did not load through the pads");

    frame = 0;
    slave_active = 1'b0; slave_bit = 4'd0;
    slave_rx = 8'h00; slave_tx = 8'h00;
    ui_in[1] = 1'b1;          // run the SPI firmware
    #1;
    wait (frame >= N_FRAMES); // the watchdog catches a transaction that never frames
    // THE FIRMWARE STORES THE BYTE *AFTER* IT RAISES CS_N (the store sequence is
    // several instructions past the frame edge), so dropping run here would
    // read slot 7 as x -- tb_pe_soc_spi.v drains the same 60 clocks for the
    // same reason.
    repeat (60) @(posedge clk);
    ui_in[1] = 1'b0;
    #(200);

    check(frame >= N_FRAMES,
          $sformatf("at least %0d SPI frames completed (got %0d)", N_FRAMES, frame));

    // ---- the aliases the mapping promises --------------------------------
    check(uo_out[0] === dut.pin_out_bus[0],
          "uo_out[0] is not the port bit 0 alias (SCLK / UART TX)");
    check(uio_oe[2] === 1'b1 && uio_out[2] === dut.pin_out_bus[1],
          "uio[2] does not mirror port bit 1 (MOSI)");
    check(uio_oe[3] === 1'b1 && uio_out[3] === dut.pin_out_bus[2],
          "uio[3] does not mirror port bit 2 (CS_N)");
    check(dut.pin_in_bus[3] === ui_in[0],
          "pin_in_bus[3] is not the ui_in[0] alias (MISO / UART RX)");

    // ---- the byte the firmware received, from dmem -----------------------
    for (int k = 0; k < N_FRAMES; k++)
      check(dut.u_soc.dmem[k] === RX_SEQ[8*(k+1)-1 -: 8],
            $sformatf("SPI buffer[%0d] = %02h, pad-level slave sent %02h",
                      k, dut.u_soc.dmem[k], RX_SEQ[8*(k+1)-1 -: 8]));

    // ---- released pins ------------------------------------------------
    // uio[2:3] are the SPI outputs and stay claimed by the matrix.
    check(uio_oe[7:4] === 4'b0000, "uio[7:4] are not released");
    check(uio_oe[3:2] === 2'b11, "SPI MOSI/CS_N pads are not driven by the matrix");

    if (errors == 0) $display("PASS: tb_tt_um_protocol_emulator");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #6_000_000;               // 1024-word load + eight SPI frames at the 4.33 us tick
    $display("FAIL: watchdog");
    $finish;
  end
endmodule
