// tb_tt_um_protocol_emulator.v — the Tiny Tapeout pad contract.
//
// This testbench does not test the UART. tb_pe_soc_uart.v does that, against
// the SoC directly. What this checks is the part that only exists at the top
// level, where the mistakes are made once and discovered after tapeout:
//
//   1. NO OUTPUT IS EVER X, and `ena` GATES NOTHING (toggle it; nothing may
//      move). The harness holds ena low for every design it has not selected,
//      and the multiplexer is not glitch-free.
//   2. THE OPEN-DRAIN PINS NEVER DRIVE HIGH. uio_out must be 0 on any pin used
//      for I2C. Released pins have uio_oe low, so the external pull-up owns
//      the line.
//   3. THE R1 HOST BUS IS uio[4:7] = CS_N / MOSI / MISO / SCK, and
//      uo_out[1] = IRQ_N. The framed protocol is exercised through the real
//      pads: PING, a bad-CRC frame (BAD_FRAME + sticky fault + IRQ_N low +
//      CLEAR_FAULT), a short LOAD whose program then runs and toggles TX, and
//      a full 1,024-word LOAD of firmware/spi_xfer.hex followed by the
//      pad-level SPI persona. MISO (uio[6]) is driven only while a response
//      shifts and released when idle; uio[4]/[5]/[7] are inputs and never
//      driven; ui_in[3:5] no longer load anything.
//   4. THE SPI OUTPUT PADS ARE STILL MATRIX BITS 1 AND 2. uio[2] mirrors
//      pin_out_bus[1]/pin_oe_bus[1] (MOSI) and uio[3] pin_out_bus[2]/
//      pin_oe_bus[2] (CS_N), while SCLK stays on uo_out[0] and MISO on
//      ui_in[0]. The SPI firmware must run a real mode-0 transaction through
//      those pads, loaded over the framed host bus.

`timescale 1ns / 1ps

module tb_tt_um_protocol_emulator;
  // Must match the SoC's CLK_HZ: this TB drives the real top level, so its
  // period is the operating point (60 MHz, ADR-005), not arbitrary stimulus.
  localparam real CLK_NS = 1e9 / 60e6;   // 60 MHz -> 16.667 ns
  localparam real HALF_NS = 100.0;       // 5 MHz host SCLK (the R1 guard rate)

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

  // ---- fault/status constants, mirrored from the RTL contract -----------
  localparam logic [15:0] FAULT_CRC      = 16'h0002;
  localparam logic [15:0] FAULT_PROTOCOL = 16'h0008;

  // ---- pad-level framed host driver (SPI mode 0) ------------------------
  // CS_N = uio_in[4], MOSI = uio_in[5], SCK = uio_in[7]; MISO is uio_out[6]
  // while uio_oe[6] drives it, otherwise the board pull-up (released MISO
  // idles high, like a real bus).
  real sclk_low_ns  = HALF_NS;
  real sclk_high_ns = HALF_NS;
  // Pad-level CS_N-to-first-SCLK-rise setup. The default reproduces the old
  // timing exactly (the old `#(HALF_NS)` after CS low plus the first bit's
  // `sclk_low_ns` phase); the P21 sweep below varies it.
  real cs_setup_ns  = HALF_NS + sclk_low_ns;
  wire miso_pad = uio_oe[6] ? uio_out[6] : 1'b1;

  task automatic set_sclk(input real low_ns, input real high_ns);
    sclk_low_ns = low_ns; sclk_high_ns = high_ns;
  endtask

  task automatic spi_bit(input logic b);
    uio_in[5] = b;            // MOSI, held while SCLK is low
    #(sclk_low_ns);
    uio_in[7] = 1'b1;         // SCK rise: the chip samples MOSI here
    #(sclk_high_ns);
    uio_in[7] = 1'b0;
  endtask

  // First bit of a transaction: its low phase is the CS_N-to-first-rise setup.
  task automatic spi_bit_first(input logic b, input real setup_ns);
    uio_in[5] = b;
    #(setup_ns);
    uio_in[7] = 1'b1;
    #(sclk_high_ns);
    uio_in[7] = 1'b0;
  endtask

  task automatic send_word(input logic [15:0] w);
    for (int k = 15; k >= 0; k--) spi_bit(w[k]);
  endtask

  task automatic read_word(output logic [15:0] w);
    logic q, pre;
    w = 16'h0000;
    for (int k = 15; k >= 0; k--) begin
      uio_in[5] = 1'b0;       // mode 0: MOSI set while SCLK is low
      #(sclk_low_ns - 20.0);
      pre = miso_pad;
      #20.0;
      uio_in[7] = 1'b1;
      q = miso_pad;
      check(uio_oe[6] === 1'b1,
            "uio[6] (MISO) oe is low at a response sampling edge");
      check(q === pre,
            "mode-0: MISO changed within 20 ns before the sampling edge");
      #(100.0);
      check(miso_pad === q,
            "mode-0: MISO changed during the high phase (must change on the fall)");
      #(sclk_high_ns - 100.0);
      uio_in[7] = 1'b0;
      w = {w[14:0], q};
    end
  endtask

  function automatic logic [15:0] crc16(input logic [15:0] crc, input logic [7:0] b);
    logic [15:0] c;
    c = crc ^ {b, 8'h00};
    for (int i = 0; i < 8; i++)
      c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    return c;
  endfunction
  function automatic logic [15:0] crc_word(input logic [15:0] crc, input logic [15:0] w);
    return crc16(crc16(crc, w[15:8]), w[7:0]);
  endfunction

  logic [15:0] txp [0:1023];
  logic [15:0] body [0:1029];
  logic [15:0] rxf [0:63];
  int          plen, rlen;

  // Build and send one request frame, then read the full response frame.
  task automatic exchange(input logic [7:0] op, input logic [15:0] seq,
                          input logic [3:0] tgt, input bit bad_crc);
    logic [15:0] crc, w;
    int total, k;
    body[0] = 16'hA55A;
    body[1] = {4'h1, op, tgt};
    body[2] = seq;
    body[3] = plen[15:0];
    for (k = 0; k < plen; k++) body[4+k] = txp[k];
    crc = 16'hFFFF;
    for (k = 0; k < 4 + plen; k++) crc = crc_word(crc, body[k]);
    body[4+plen] = bad_crc ? (crc ^ 16'h0001) : crc;

    uio_in[4] = 1'b0;         // CS_N low
    // The first bit's low phase IS this transaction's pad-level
    // CS-to-first-rise setup; the remaining 15 bits and words use the normal
    // mode-0 cadence.
    w = body[0];
    spi_bit_first(w[15], cs_setup_ns);
    for (k = 14; k >= 0; k--) spi_bit(w[k]);
    for (k = 1; k < 5 + plen; k++) begin
      w = body[k];
      send_word(w);
    end
    for (k = 0; k < 4; k++) begin
      read_word(w);
      rxf[k] = w;
    end
    rlen = rxf[3];
    total = 5 + rlen;
    for (k = 4; k < total; k++) begin
      read_word(w);
      rxf[k] = w;
    end
    uio_in[4] = 1'b1;         // CS_N high
    #(HALF_NS);
    if (rxf[0] !== 16'hA55A) begin
      $display("FAIL: response sync = %04h @%0t", rxf[0], $time); errors++;
    end else begin
      crc = 16'hFFFF;
      for (k = 0; k < total - 1; k++) crc = crc_word(crc, rxf[k]);
      check(crc === rxf[total-1],
            $sformatf("response CRC = %04h, computed %04h", rxf[total-1], crc));
      check(rxf[1][11:4] === (op | 8'h80), "response opcode");
      check(rxf[2] === seq, "response sequence echo");
    end
  endtask

  task automatic ping_ok(input string tag);
    plen = 0;
    exchange(8'h01, 16'h1234, 4'h0, 1'b0);
    check(rxf[4] === 16'd0, $sformatf("%s: status = %0d, want OK", tag, rxf[4]));
    check(uo_out[1] === 1'b1, $sformatf("%s: IRQ_N high with no fault", tag));
  endtask

  // ---- pad-contract monitors: these must hold on EVERY cycle ------------
  always @(posedge clk) begin
    if (rst_n) begin
      if ($isunknown(uo_out))
        check(1'b0, "uo_out has an X bit (floating pad)");
      if ($isunknown(uio_oe))
        check(1'b0, "uio_oe has an X bit");
      if ($isunknown(uio_out))
        check(1'b0, "uio_out has an X bit");
      // Open-drain: SDA and SCL may be released or driven low, never high.
      if (uio_oe[0] && uio_out[0])
        check(1'b0, "uio[0]/SDA driven HIGH (open-drain violated)");
      if (uio_oe[1] && uio_out[1])
        check(1'b0, "uio[1]/SCL driven HIGH (open-drain violated)");
      // The host-bus inputs are never driven by the chip.
      if (uio_oe[7] | uio_oe[5] | uio_oe[4])
        check(1'b0, "a host-bus input pin (uio[4],[5],[7]) is being driven");
      // The uo_out[2] reclaim (Task 4, G6): while the matrix drives port bit 7
      // the pad IS that level; otherwise uo_out[7:2] is dbg_pc[5:0] exactly,
      // which is the reset-bit-identical rule. Checked on EVERY cycle, so the
      // fallback cannot be true only at reset.
      if (dut.pin_oe_bus[7]) begin
        if (uo_out[2] !== dut.pin_out_bus[7])
          check(1'b0, "uo_out[2] is not the eth_tx pad while port bit 7 drives");
        if (uo_out[7:3] !== dut.dbg_pc[5:1])
          check(1'b0, "uo_out[7:3] moved off dbg_pc[5:1]");
      end else begin
        if (uo_out[7:2] !== dut.dbg_pc[5:0])
          check(1'b0, "uo_out[7:2] is not dbg_pc[5:0] while the TX persona is off");
      end
    end
  end

  // ---- pad-level 10BASE-T TX decode (Task 4) ----------------------------
  // The reclaimed uo_out[2] pad carries the Manchester waveform while port
  // bit 7 is matrix-driven. Sample it at the SoC cadence's half-cell centres
  // (ph2/ph5 via cell_en/half_phase) and record each cell as idle or a decoded
  // bit, exactly as the SoC TX TB does -- but at the PAD, so the pad mux, the
  // matrix overlay and the wrapper alias are all in the decoded path.
  localparam int MAXCELLS = 4096;
  localparam int NEED     = 64 + 8*60 + 32;   // ARP-42 -> 60 stored + FCS
  logic [1:0] cellrec [0:MAXCELLS-1];   // {is_bit, decoded_bit}; 2'b00 = idle
  int         ncells;
  logic       mh1, mh2;
  bit         tx_persona_active;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ncells <= 0; mh1 <= 1'b0; mh2 <= 1'b0;
    end else begin
      if (dut.u_soc.cell_en && !dut.u_soc.half_phase) begin
        if (mh1 === mh2) begin
          if (ncells < MAXCELLS) cellrec[ncells] <= 2'b00;
        end else begin
          check(mh1 === ~mh2, "eth_tx pad: Manchester halves are not complementary");
          if (ncells < MAXCELLS) cellrec[ncells] <= {1'b1, mh2};
        end
        if (ncells < MAXCELLS) ncells <= ncells + 1;
        mh1 <= uo_out[2];
      end else if (!dut.u_soc.half_phase) begin
        mh1 <= uo_out[2];
      end else begin
        mh2 <= uo_out[2];
      end
      // Push-pull driven while the persona owns the pad: every frame cell
      // must have the matrix driving port bit 7.
      if (dut.u_soc.cell_en && tx_persona_active && !dut.pin_oe_bus[7])
        check(1'b0, "eth_tx persona: pad not driven mid-frame (pin_oe_bus[7] low)");
    end
  end

  // ---- expected frame (byte-identical to firmware/eth_tx_arp.pe) --------
  logic [7:0] arp    [0:41];
  logic [7:0] stored [0:59];
  logic       got    [0:NEED-1];
  logic [31:0] fcs_want;

  task automatic fill_arp;
    arp[0]=8'hFF; arp[1]=8'hFF; arp[2]=8'hFF; arp[3]=8'hFF;
    arp[4]=8'hFF; arp[5]=8'hFF;
    arp[6]=8'h02; arp[7]=8'h00; arp[8]=8'h00; arp[9]=8'h00;
    arp[10]=8'h00; arp[11]=8'h01;
    arp[12]=8'h08; arp[13]=8'h06;
    arp[14]=8'h00; arp[15]=8'h01; arp[16]=8'h08; arp[17]=8'h00;
    arp[18]=8'h06; arp[19]=8'h04; arp[20]=8'h00; arp[21]=8'h01;
    arp[22]=8'h02; arp[23]=8'h00; arp[24]=8'h00; arp[25]=8'h00;
    arp[26]=8'h00; arp[27]=8'h01;
    arp[28]=8'hC0; arp[29]=8'hA8; arp[30]=8'h01; arp[31]=8'h0A;
    arp[32]=8'h00; arp[33]=8'h00; arp[34]=8'h00; arp[35]=8'h00;
    arp[36]=8'h00; arp[37]=8'h00;
    arp[38]=8'hC0; arp[39]=8'hA8; arp[40]=8'h01; arp[41]=8'h14;
    for (int k = 0; k < 42; k++) stored[k] = arp[k];
    for (int k = 42; k < 60; k++) stored[k] = 8'h00;   // hardware pad
  endtask

  function automatic logic [31:0] ref_crc32(input int nbytes);
    logic [31:0] c;
    c = 32'hFFFFFFFF;
    for (int k = 0; k < nbytes; k++) begin
      c = c ^ stored[k];
      for (int b = 0; b < 8; b++)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    end
    return ~c;
  endfunction

  logic [7:0] snap_uo, snap_oe, snap_uio;

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
  bit         spi_mon_en = 1'b0;   // SPI-pad slave only watches its own run
  integer     frame;

  always @(posedge sclk_pad)
    if (spi_mon_en && run && rst_n && slave_active && slave_bit < 4'd8)
      slave_rx = {slave_rx[6:0], mosi_pad};
  always @(negedge sclk_pad)
    if (spi_mon_en && run && rst_n && slave_active) begin
      if (slave_bit < 4'd8) slave_bit = slave_bit + 1'b1;
      ui_in[0] = (slave_bit < 4'd8) ? slave_tx[7 - slave_bit[2:0]] : 1'b1;
    end
  always @(negedge cs_n_pad)
    if (spi_mon_en && run && rst_n) begin
      slave_active = 1'b1;
      slave_bit    = 4'd0;
      slave_rx     = 8'h00;
      slave_tx     = (frame < N_FRAMES) ? RX_SEQ[8*(frame+1)-1 -: 8] : 8'h00;
      ui_in[0]     = slave_tx[7];
    end
  always @(posedge cs_n_pad)
    if (spi_mon_en && run && rst_n && slave_active) begin
      slave_active = 1'b0;
      ui_in[0]     = 1'b1;
      check(slave_bit == 4'd8,
            $sformatf("SPI frame %0d had exactly 8 SCLK rises (got %0d)",
                      frame, slave_bit));
      check(slave_rx === TX_BYTE,
            $sformatf("SPI frame %0d: pad-level slave captured %02h on uio[2]/MOSI, firmware meant %02h",
                      frame, slave_rx, TX_BYTE));
      if (frame < N_FRAMES) frame = frame + 1;
    end

  logic [15:0] spi_prog [0:1023];
  integer      spi_words;
  bit tx_saw_low = 1'b0, tx_saw_high = 1'b0;
  always @(posedge clk) begin
    if (ui_in[1] && uo_out[0] === 1'b0) tx_saw_low  <= 1'b1;
    if (ui_in[1] && tx_saw_low && uo_out[0] === 1'b1) tx_saw_high <= 1'b1;
  end

  initial begin
    $dumpfile("tb_tt_um_protocol_emulator.vcd");
    $dumpvars(0, tb_tt_um_protocol_emulator);

    ena = 1'b1;
    ui_in = 8'h00;
    ui_in[0] = 1'b1;          // UART RX idles high
    uio_in = 8'h10;           // CS_N high (bit 4)
    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    repeat (4) @(posedge clk); #1;

    check(uo_out[0] === 1'b1, "uo_out[0] (TX) idles high out of reset");
    check(uo_out[1] === 1'b1, "uo_out[1] (IRQ_N) idles high");
    check(uio_oe[6] === 1'b0, "MISO is released out of reset");
    check(dut.pin_oe_bus[7] === 1'b0, "port bit 7 is driven out of reset");
    check(uo_out[7:2] === dut.dbg_pc[5:0],
          "uo_out[7:2] is not dbg_pc[5:0] at reset (bit-identical rule)");

    // ---- ena must gate nothing -----------------------------------------
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

    // ---- PING through the real pads ------------------------------------
    ping_ok("pad ping");
    check(uio_oe[6] === 1'b0, "MISO not released after the response");
    check(uio_oe[7:4] === 4'b0000, "host-bus input pins must stay released");

    // ---- a frame clocked while host CS_N is HIGH must be ignored --------
    // This pins the CS_N pad wiring: with CS_N stuck selected (e.g. the wrong
    // uio bit), the chip answers a frame it was never addressed by.
    begin
      logic [15:0] w;
      int k;
      w = crc_word(crc_word(crc_word(crc_word(16'hFFFF, 16'hA55A),
                                     {4'h1, 8'h01, 4'h0}), 16'h5555), 16'h0000);
      for (k = 0; k < 5; k++) begin
        case (k)
          0: send_word(16'hA55A);
          1: send_word({4'h1, 8'h01, 4'h0});
          2: send_word(16'h5555);
          3: send_word(16'h0000);
          default: send_word(w);
        endcase
      end
      repeat (8) @(posedge clk); #1;
      check(uio_oe[6] === 1'b0,
            "the chip answered a frame with host CS_N high (CS_N pad miswired)");
    end

    // ---- bad CRC -> BAD_FRAME + IRQ_N, then CLEAR_FAULT -----------------
    plen = 0;
    exchange(8'h01, 16'h2222, 4'h0, 1'b1);
    check(rxf[4] === 16'd2, "bad crc: BAD_FRAME");
    check(dut.u_ctrl.faults === FAULT_CRC, "bad crc: FAULT_CRC latched");
    check(uo_out[1] === 1'b0, "bad crc: IRQ_N asserted (active low)");
    exchange(8'h11, 16'h2223, 4'h0, 1'b0);
    check(rxf[8] === FAULT_CRC, "status: fault reported");
    check(uo_out[1] === 1'b0, "status read must not clear the fault");
    txp[0] = FAULT_CRC;
    plen = 1;
    exchange(8'h16, 16'h2224, 4'h0, 1'b0);
    check(rxf[4] === 16'd0 && rxf[5] === 16'h0000, "clear fault: empty");
    check(uo_out[1] === 1'b1, "clear fault: IRQ_N released");

    // ---- P21: CS_N-to-first-SCLK-rise boundary sweep --------------------
    // The CS_N synchronizer needs 2 clk (~33 ns at 60 MHz) before the first
    // SCLK rise is accepted. Sweep the pad-level setup from just above that
    // bound to a comfortable value; every point must answer a PING and leave
    // MISO released (the boundary RB L58-60 asked to sweep).
    begin
      real sweep[0:3];
      int sk;
      sweep[0] = 40.0; sweep[1] = 60.0; sweep[2] = 150.0; sweep[3] = 400.0;
      for (sk = 0; sk < 4; sk++) begin
        cs_setup_ns = sweep[sk];
        ping_ok($sformatf("cs-setup %0.0f ns", sweep[sk]));
        check(uio_oe[6] === 1'b0,
              $sformatf("cs-setup %0.0f ns: MISO not released", sweep[sk]));
      end
      cs_setup_ns = HALF_NS + sclk_low_ns;
    end

    // ---- ui_in[3:5] no longer load anything -----------------------------
    check(dut.u_ctrl.words_written === 16'd0, "no writes before the first LOAD");
    ui_in[3] = 1'b1; ui_in[4] = 1'b1; ui_in[5] = 1'b1;
    repeat (40) @(posedge clk);
    ui_in[3] = 1'b0; ui_in[4] = 1'b0; ui_in[5] = 1'b0;
    check(dut.u_ctrl.words_written === 16'd0,
          "the freed ui_in[3:5] pads still write instruction memory");

    // ---- a short program loaded through the pads actually runs ----------
    txp[0] = 16'h0001;        // LDI A, 1
    txp[1] = 16'h1001;        // OUT 1, A   (TX high)
    txp[2] = 16'h0000;        // LDI A, 0
    txp[3] = 16'h1001;        // OUT 1, A   (TX low)
    txp[4] = 16'h4000;        // JMP 0
    plen = 5;
    exchange(8'h10, 16'h3333, 4'h0, 1'b0);
    check(rxf[4] === 16'd0, "short load: OK");
    check(rxf[5] === 16'd5, "short load: 5 words written");
    check(rxf[7] === 16'h4000, "short load: final-word echo");
    check(dut.u_ctrl.faults === 16'h0000, "short load: no fault");
    ui_in[1] = 1'b1;          // run the loaded program
    #1;
    repeat (200) @(posedge clk); #1;
    check(tx_saw_low && tx_saw_high,
          "the program loaded through the pads did not toggle TX");
    ui_in[1] = 1'b0;
    #1;
    repeat (4) @(posedge clk); #1;

    // ---- the SPI persona runs through the real pads ----------------------
    // Load firmware/spi_xfer.hex as a full 1,024-word framed LOAD (NOP fill,
    // then the file), run it, and act as a mode-0 slave on the SPI pads. This
    // proves the whole R1 path: frame -> CRC -> payload -> imem -> CPU ->
    // matrix pads.
    for (spi_words = 0; spi_words < 1024; spi_words++)
      spi_prog[spi_words] = 16'hF000;
    $readmemh("../firmware/spi_xfer.hex", spi_prog);
    for (spi_words = 0; spi_words < 1024; spi_words++) txp[spi_words] = spi_prog[spi_words];
    plen = 1024;
    exchange(8'h10, 16'h4444, 4'h0, 1'b0);
    check(rxf[4] === 16'd0, "full load: OK");
    check(rxf[5] === 16'd1024, "full load: 1024 words written");
    check(rxf[6] === 16'h0000, "full load: no fault");
    check(rxf[7] === spi_prog[1023],
          $sformatf("full load: final-word echo = %04h, want %04h",
                    rxf[7], spi_prog[1023]));
    check(dut.u_ctrl.words_written === 16'd1024, "full load: counter");
    check(uio_oe[6] === 1'b0, "MISO released after the full-image response");
    $display("    loaded %0d words through the framed host bus", plen);

    frame = 0;
    slave_active = 1'b0; slave_bit = 4'd0;
    slave_rx = 8'h00; slave_tx = 8'h00;
    spi_mon_en = 1'b1;
    ui_in[1] = 1'b1;          // run the SPI firmware
    #1;
    wait (frame >= N_FRAMES); // the watchdog catches a transaction that never frames
    // THE FIRMWARE STORES THE BYTE *AFTER* IT RAISES CS_N (the store sequence
    // is several instructions past the frame edge), so drop run after a drain.
    repeat (60) @(posedge clk);
    ui_in[1] = 1'b0;
    spi_mon_en = 1'b0;
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

    // ---- the eth_tx persona on the reclaimed uo_out[2] pad (Task 4) ------
    // Load firmware/eth_tx_arp.pe through the framed host bus (NOP fill), run
    // it, and decode the REAL Manchester waveform that reaches the pad. The
    // per-cycle mux checks above are the reset-bit-identical proof and the
    // "returns to dbg_pc[0]" proof; this section is the pad-level waveform.
    fill_arp;
    for (spi_words = 0; spi_words < 1024; spi_words++)
      spi_prog[spi_words] = 16'hF000;
    $readmemh("../firmware/eth_tx_arp.hex", spi_prog);
    for (spi_words = 0; spi_words < 1024; spi_words++)
      txp[spi_words] = spi_prog[spi_words];
    plen = 1024;
    exchange(8'h10, 16'h5555, 4'h0, 1'b0);
    check(rxf[4] === 16'd0, "eth_tx load: OK");
    check(rxf[5] === 16'd1024, "eth_tx load: 1024 words written");
    check(rxf[7] === spi_prog[1023], "eth_tx load: final-word echo");

    tx_persona_active = 1'b1;
    ncells = 0;
    ui_in[1] = 1'b1;          // run the eth_tx firmware
    #1;
    begin
      int guard = 0;
      while ((dut.u_soc.dmem[8] !== 8'hA5) && (guard < 400_000)) begin
        @(posedge clk); guard++;
      end
      check(dut.u_soc.dmem[8] === 8'hA5,
            $sformatf("eth_tx firmware never reported done (pc=%0d)", dut.dbg_pc));
    end
    repeat (24) @(posedge clk);
    ui_in[1] = 1'b0;
    #1;
    check(dut.pin_oe_bus[7] === 1'b1,
          "the TX persona never claimed port bit 7");

    begin
      int i0;
      i0 = -1;
      for (int k = 0; k < ncells; k++)
        if (cellrec[k][1] === 1'b1) begin i0 = k; break; end
      check(i0 >= 0, "eth_tx pad: no encoded bits ever appeared on uo_out[2]");
      if (i0 >= 0) begin
        for (int k = 0; k < NEED; k++) begin
          if (i0 + k >= ncells || cellrec[i0+k][1] !== 1'b1)
            check(1'b0, $sformatf("eth_tx pad: idle cell inside the frame at bit %0d", k));
          got[k] = cellrec[i0+k][0];
        end
        for (int k = 0; k < 64; k++) begin
          bit e;
          e = (k == 63) ? 1'b1 : ~k[0];
          check(got[k] === e,
                $sformatf("eth_tx pad: prelude bit %0d=%b want %b", k, got[k], e));
        end
        for (int b = 0; b < 60; b++) begin
          logic [7:0] gb;
          for (int j = 0; j < 8; j++) gb[j] = got[64 + 8*b + j];
          check(gb === stored[b],
                $sformatf("eth_tx pad: stored byte %0d=%02h want %02h", b, gb, stored[b]));
        end
        fcs_want = ref_crc32(60);
        for (int k = 0; k < 32; k++)
          check(got[64 + 480 + k] === fcs_want[k],
                $sformatf("eth_tx pad: FCS bit %0d=%b want %b", k,
                          got[64 + 480 + k], fcs_want[k]));
        $display("    eth_tx pad: decoded %0d wire bits, FCS %08h", NEED, fcs_want);
      end
    end

    // ---- the persona releases the pad: uo_out[2] returns to dbg_pc[0] -----
    // A tiny program clears PINOE and spins at a NONZERO PC, so the fallback
    // is the program counter and not a coincidental 0.
    txp[0] = 16'h0007;        // LDI A, 7 (clear PINOE[7]; keep the baseline drive)
    txp[1] = 16'h1002;        // OUT PINOE, A
    txp[2] = 16'h005A;        // LDI A, 0x5A
    txp[3] = 16'h4003;        // JMP 3 (spin; dbg_pc = 3)
    plen = 4;
    exchange(8'h10, 16'h5556, 4'h0, 1'b0);
    check(rxf[4] === 16'd0, "persona-off load: OK");
    tx_persona_active = 1'b0;
    ui_in[1] = 1'b1;
    #1;
    repeat (40) @(posedge clk); #1;
    check(dut.pin_oe_bus[7] === 1'b0, "PINOE bit 7 did not release the pad");
    check(dut.dbg_pc === 8'h03,
          $sformatf("persona-off PC = %0d, want 3", dut.dbg_pc));
    check(uo_out[2] === dut.dbg_pc[0],
          "uo_out[2] did not return to dbg_pc[0] when the persona was disabled");
    check(uo_out[7:2] === dut.dbg_pc[5:0],
          "uo_out[7:2] did not return to dbg_pc[5:0] when the persona was disabled");
    ui_in[1] = 1'b0;
    #1;

    // ---- released pins ------------------------------------------------
    check(uio_oe[7:4] === 4'b0000, "host-bus pins are not released");
    check(uio_oe[3:2] === 2'b11, "SPI MOSI/CS_N pads are not driven by the matrix");

    if (errors == 0) $display("PASS: tb_tt_um_protocol_emulator");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #30_000_000;              // full 1024-word framed load + the SPI persona
    $display("FAIL: watchdog");
    $finish;
  end
endmodule
