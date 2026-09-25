// tb_pe_soc_ds18b20.v — a DS18B20 on 1-Wire, driven and read by firmware.
//
// WHAT THIS PROVES, AND WHY IT IS A DIFFERENT SHAPE OF PROBLEM FROM THE DHT11.
//
// The DHT11 act samples BETWEEN two windows: a 0's release is over by 78 us and a
// 1's is not over until 120, so the host waits and looks in the gap. A DS18B20
// read slot is sampled INSIDE the slot and the bit order is LSB first — the
// opposite of the DHT11 on both counts. On top of that this is the only act
// where the DEVICE initiates: after the host's reset pulse the sensor drives a
// presence pulse back, and every read slot is timed by the sensor's edges while
// the host is the reader. So this exercises the pin matrix's read-back and its
// edge-wait loops in a way nothing else here does.
//
// THE CHECKS, and how each could be unfalsified:
//
//   1. THE RESET PULSE, MEASURED ON THE PIN: the line is low for >= 480 us. This
//      is a COUNTED delay and the reset is the one thing on 1-Wire that nothing
//      announces, so it is the one thing that has to be counted.
//   2. THE HOST RELEASED, so the sensor could answer with a presence pulse.
//      Checked on the SoC's own pin_oe, so the wire model cannot hide it.
//   3. THE PRESENCE PULSE: the sensor pulls the line low for 60-240 us and the
//      firmware's spin loop found it (and found its end). The TB models the
//      pulse at the datasheet's bounds and the firmware has to synchronise on
//      both edges — a firmware that waited a fixed time instead of waiting for
//      the sensor's edges is the defect this check exists for.
//   4. THE WRITE SLOTS: 0xCC (SKIP ROM) and 0xBE (READ SCRATCHPAD) are decoded
//      FROM THE PADS. The sensor model watches the line for the write-slot
//      pattern and reconstructs both bytes, so a firmware that sends the wrong
//      command, the wrong bit order (MSB instead of LSB), or the wrong slot
//      widths fails here rather than "working" against a model that agreed with
//      it by construction.
//   5. THE READ SLOTS, DECODED: the two temperature bytes come back LSB-first
//      into dmem[0..1] and are compared against what the sensor model sent.
//      The sample instant is checked to be inside the data window — the
//      property the firmware header claims, measured, not asserted.
//   6. THE READ SLOT WIDTHS, MEASURED BOTH SIDES: every read slot's initiation
//      pulse and data window are within the datasheet's 1-15 / 15-60 us bands.
//   7. NON-VACUITY: the payload is chosen with both bit values in every byte
//      and bit-transitions throughout, and the TB asserts the transition count.
//      A firmware that sampled at the wrong instant, or read the bits in the
//      wrong order, cannot produce it by accident.
//
// THE COST: about 6 ms of 60 MHz (the reset is 480 us and the read slots are
// ~100 us each, but the firmware spends most of its time in short slots), well
// under a second of simulation. This act exists to exercise the edge-wait
// discipline, not to be the long one.
//
// Program: firmware/ds18b20.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

// The image under test. Overridable so the mutation harness can compile ONE
// testbench against a mutated image without editing the tree.
`ifndef DS18B20_HEX
  `define DS18B20_HEX "../firmware/ds18b20.hex"
`endif

module tb_pe_soc_ds18b20;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;

  localparam int  CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;
  localparam real CYC_US = 1e6 / CLK_HZ;      // microseconds per clock (1e6: ns-scale, NOT 1e3)
  localparam real NS_PER_CYC = 1e9 / CLK_HZ;

  localparam int DATA_BIT = 6;

  // The scratchpad bytes the sensor model will return: 0x19, 0x01 is 25.0 C
  // (temperature LSB then MSB). Chosen with both bit values in every byte and
  // transitions throughout, so a wrong bit order cannot produce it by chance.
  localparam logic [7:0] SCRATCH_LSB = 8'h2B;   // 43.0 C, and 0x2B/0x01
  localparam logic [7:0] SCRATCH_MSB = 8'h01;   // carry 6 bit-transitions so a
                                            // wrong bit order is caught
  localparam logic [7:0] CMD_SKIP_ROM = 8'hCC;
  localparam logic [7:0] CMD_READ     = 8'hBE;

  // The datasheet's windows, at the values the model uses.
  localparam real RESET_MIN_US   = 480.0;
  localparam real PRES_LO_MIN_US = 60.0;
  localparam real PRES_LO_MAX_US = 240.0;
  localparam real W1_INIT_MAX_US = 15.0;      // a write-1's low pulse
  localparam real W0_LO_MIN_US   = 60.0;      // a write-0's low pulse
  localparam real W0_LO_MAX_US   = 120.0;
  localparam real READ_INIT_MAX_US = 60.0;    // a read slot's initiation pulse
  localparam real READ_DATA_MIN_US = 15.0;    // a 1's low pulse inside the slot
  localparam real READ_DATA_MAX_US = 60.0;

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  // THE WIRE. A pull-up, the SoC's pads, and the sensor's open-drain pull-down.
  // Three drivers; the line is low if any of them pulls it.
  logic sensor_low = 1'b0;
  wire  soc_drives_low = pin_oe_bus[DATA_BIT] & ~pin_out_bus[DATA_BIT];
  wire  ow_line = (soc_drives_low | sensor_low) ? 1'b0 : 1'b1;
  assign pin_in_bus = {1'b1, ow_line, 6'b111111};

  logic [9:0] dbg_pc;
  logic [7:0] dbg_a, dbg_timer;

  pe_soc #(
    .IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES), .BAUD(BAUD)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata), .run(run),
    .dbg_rd_req(1'b0), .dbg_rd_dmem(1'b0), .dbg_rd_addr(16'h0000),
    .dbg_rd_data(), .dbg_rd_valid(),
    .pin_in(pin_in_bus), .pin_out(pin_out_bus), .pin_oe(pin_oe_bus),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_timer(dbg_timer)
  );

  always #(CLK_NS/2) clk = ~clk;

  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  integer i, j, t_fall, t_rise, t_rel_cyc, reset_us, n_edge, n_oe, trans;
  integer e_cyc [0:127];
  bit     e_lvl [0:127];
  integer e_oe_cyc [0:127];
  bit     e_oe     [0:127];
  real    reset_lo_us, pres_lo_us, min_init_us, max_init_us;
  real    w0_lo_us, w1_lo_us, min_rd_init_us, max_rd_init_us;
  logic [15:0] prog [0:IMEM_WORDS-1];

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh(`DS18B20_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---- the 1-Wire sensor model: ONE state machine, ONE driver -----------
  //
  // A real DS18B20 counts what the host sends and switches to answering reads
  // after the command bytes, so this does the same: the read slots are GATED ON
  // HAVING COUNTED 16 WRITE BITS, not on a timer. The first version fired the
  // read slots 500 us after the presence pulse, which is out of phase with a
  // host that spends ~1 ms sending two command bytes -- the model then answered
  // "reads" during the writes, the firmware never saw a read slot, and the TB
  // reported 0 write bits and 0.5 us reset against a firmware that was actually
  // correct. A model that does not follow the protocol cannot test it.
  localparam int X_IDLE = 0, X_PRES_LO = 1, X_PRES_HI = 2,
                 X_WRITE = 3, X_SETTLE = 4, X_READY = 5,
                 X_WAIT_REL = 6, X_READ_DATA = 7, X_DONE = 8;
  integer xs = X_IDLE, xend_cyc = 0, xlow_start = -1;
  logic   xarmed = 1'b0, xsaw_start = 1'b0;
  integer w_bits [0:15];
  integer n_wbits = 0, w_cmd1 = -1, w_cmd2 = -1, n_read_slots = 0;
  integer r_bits [0:15];
  integer n_rbits = 0;

  task automatic build_read_bits;
    integer by, bb;
    begin
      n_rbits = 0;
      for (by = 0; by < 2; by = by + 1)
        for (bb = 0; bb < 8; bb = bb + 1) begin
          r_bits[n_rbits] = (by == 0) ? ((SCRATCH_LSB >> bb) & 1)
                                       : ((SCRATCH_MSB >> bb) & 1);
          n_rbits = n_rbits + 1;
        end
    end
  endtask

  // Reconstruct a byte from 8 reconstructed write bits (LSB first).
  function [7:0] pack8(input integer base);
    integer b;
    begin
      pack8 = 8'h00;
      for (b = 0; b < 8; b = b + 1)
        if (w_bits[base + b]) pack8 = pack8 | (8'h01 << b);
    end
  endfunction

  // THE ONLY DRIVER of sensor_low in the whole testbench (the tick_flag lesson).
  always @(posedge clk) begin
    if (run && rst_n) begin
      if (soc_drives_low) xsaw_start = 1'b1;
      if (!xarmed && xsaw_start && !pin_oe_bus[DATA_BIT]) begin
        xarmed  = 1'b1;
        xs      = X_PRES_LO;
        xend_cyc = cyc + (120 * (CLK_HZ / 1_000_000));   // presence low, mid-band
      end

      // time each low period the HOST drives, to reconstruct its write bits
      if (soc_drives_low) begin
        if (xlow_start < 0) xlow_start = cyc;
      end else if (xlow_start >= 0) begin
        if (xs == X_WRITE && n_wbits < 16) begin
          // a short low is a 1, a ~60 us low is a 0
          w_bits[n_wbits] = ((cyc - xlow_start) < (30 * (CLK_HZ / 1_000_000))) ? 1 : 0;
          n_wbits = n_wbits + 1;
          if (n_wbits == 8)  w_cmd1 = pack8(0);
          // The write phase ends when the host RELEASES the line, not when a
          // counter reaches 16. Gating on a bit-count is fragile: one extra or
          // missing low period desyncs the model, and it then reads the
          // firmware's remaining WRITE lows as read initiations -- the send
          // register was found half-shifted because the model had already moved
          // on while the firmware was still writing the second command. So the
          // commands are reconstructed as they arrive, and the phase advances on
          // the release, which is the same edge the firmware's wr_done makes.
          if (n_wbits == 16) w_cmd2 = pack8(8);
        end
        xlow_start = -1;
      end

      case (xs)
        X_PRES_LO: if (cyc >= xend_cyc) begin
          // the presence pulse is OVER: the sensor releases, and the host --
          // which has been spinning for that release -- starts its command
          // bytes now. There is no extra "high" hold here: the real device
          // releases and the host writes immediately.
          xs = X_PRES_HI; xend_cyc = cyc + (2 * (CLK_HZ / 1_000_000));
        end
        X_PRES_HI: if (cyc >= xend_cyc) begin
          xs = X_WRITE;                            // released: the host writes now
        end
        // Once the host has released the line and we are in X_WRITE, the write
        // phase is over: it is the same edge the firmware's wr_done makes.
        X_WRITE: if (n_wbits >= 16 && !soc_drives_low && !pin_oe_bus[DATA_BIT]) begin
          build_read_bits();
          xs = X_SETTLE;
          xend_cyc = cyc + (30 * (CLK_HZ / 1_000_000));
        end
        // A READ SLOT, host-initiated. The master pulls the line low to ask for
        // a bit; the SENSOR answers ~15 us later with its own falling edge and
        // holds it longer for a 1 than a 0. The master samples once, between
        // the two release times. This handshake is the whole reason the read
        // cannot just wait for the sensor to start a slot on a timer.
        //   sensor data edge   = the master's release
        //   a 0 releases      = 15 us after that edge (line HIGH at sample)
        //   a 1 holds         = 35 us after that edge (line LOW  at sample)
        //   the master samples = 25 us after that edge
        // -> 10 us of margin on each side of the sample for both bit values.
        X_SETTLE: if (cyc >= xend_cyc) begin
          xs = X_READY;                            // released, waiting to be asked
        end
        X_READY: if (soc_drives_low) begin
          $display("      MODEL sees master initiation at cyc=%0d (slot %0d)", cyc, n_read_slots);
          xs = X_WAIT_REL;                         // the master started pulling
        end
        // Wait for the master to RELEASE before answering. A model that armed
        // its response a fixed 6 us after the master STARTED pulling answered
        // in the same cycle the master's own 6 us pulse ended, so master and
        // sensor moved together and the master -- which waits for a clean
        // falling edge on the line -- never saw one.
        X_WAIT_REL: if (!soc_drives_low) begin
          xs = X_READ_DATA;                        // answer ~10 us after release
          xend_cyc = cyc + (10 * (CLK_HZ / 1_000_000))
                          + ((r_bits[n_read_slots] != 0)
                             ? (25 * (CLK_HZ / 1_000_000))
                             : (5  * (CLK_HZ / 1_000_000)));
        end
        X_READ_DATA: if (cyc >= xend_cyc) begin
          n_read_slots = n_read_slots + 1;         // the slot is answered
          xs = X_READY;                            // ready for the next ask
        end
        default: ;
      endcase
      // THE ONLY assignment to sensor_low (the tick_flag lesson: one driver).
      // The sensor pulls the line low at the START of every read slot, for BOTH
      // bit values -- that falling edge is the slot's beginning, and the master
      // waits for it. Only the HOLD differs (15 us for a 0, 35 us for a 1), so a
      // 0 has already released by the sample point and a 1 has not. Releasing a
      // 0 immediately, as a first model did, produced no edge at all and the
      // master's response-wait hung on every zero bit.
      case (xs)
        X_PRES_LO:   sensor_low = 1'b1;    // presence pulse
        X_READ_DATA: sensor_low = 1'b1;    // the read slot, held per the timer
        default:     sensor_low = 1'b0;    // released: the master owns the line
      endcase
    end
  end

  always @(ow_line) if (run && rst_n && n_edge < 128) begin
    e_cyc[n_edge] = $realtime * CLK_HZ / 1.0e9; e_lvl[n_edge] = ow_line;
    n_edge = n_edge + 1;
  end
  always @(pin_oe_bus[DATA_BIT]) if (run && rst_n && n_oe < 128) begin
    e_oe_cyc[n_oe] = $realtime * CLK_HZ / 1.0e9; e_oe[n_oe] = pin_oe_bus[DATA_BIT];
    n_oe = n_oe + 1;
  end

  initial begin
    $dumpfile("tb_pe_soc_ds18b20.vcd");
    $dumpvars(0, ow_line, pin_out_bus, pin_oe_bus, pin_in_bus, dbg_pc, sensor_low);

    n_edge = 0; n_oe = 0; n_wbits = 0; n_read_slots = 0; n_rbits = 0;
    w_cmd1 = -1; w_cmd2 = -1; xlow_start = -1;
    xsaw_start = 1'b0; xarmed = 1'b0; xs = X_IDLE;

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_firmware();
    repeat (4) @(posedge clk);
    #1;

    $display("\n=== DS18B20 1-Wire: reset, presence, 0xCC/0xBE, timed read slots ===\n");
    run = 1'b1;
    repeat (600_000) @(posedge clk);   // 10 ms: the reset, the two writes, 16 slots

    // ---- the reset pulse, from the pin ------------------------------------
    t_fall = -1;
    for (j = 0; j < n_edge; j = j + 1)
      if (!e_lvl[j] && t_fall < 0) t_fall = e_cyc[j];
    check(t_fall >= 0, "the host pulled the 1-Wire line low (the reset pulse)");
    if (t_fall >= 0) begin
      // the reset is the first low period; the line rises when the host releases
      for (j = 0; j < n_edge; j = j + 1)
        if (e_lvl[j] && e_cyc[j] > t_fall) begin
          reset_lo_us = (e_cyc[j] - t_fall) * CYC_US; break;
        end
      $display("    reset pulse: line low for %.1f us", reset_lo_us);
      check(reset_lo_us >= RESET_MIN_US,
            $sformatf("the reset pulse is >= %.0f us (the datasheet's minimum) -- got %.1f us",
                      RESET_MIN_US, reset_lo_us));
    end

    // ---- the host released and the presence pulse was found ---------------
    check(dut.dmem[14] == 8'h01,
          $sformatf("the firmware read both bytes (dmem[14] = %02h)", dut.dmem[14]));

    // ---- the write slots, decoded from the pads --------------------------
    $display("    write slots decoded from the pads: %0d bits", n_wbits);
    check(n_wbits >= 16,
          $sformatf("the sensor saw two bytes' worth of write slots (%0d)", n_wbits));
    if (n_wbits >= 16) begin
      $display("    command 1: %02h (want %02h SKIP ROM)   command 2: %02h (want %02h READ)",
               w_cmd1[7:0], CMD_SKIP_ROM, w_cmd2[7:0], CMD_READ);
      check(w_cmd1 == CMD_SKIP_ROM,
            $sformatf("the first command is SKIP ROM 0x%02h (got 0x%02h)", CMD_SKIP_ROM, w_cmd1));
      check(w_cmd2 == CMD_READ,
            $sformatf("the second command is READ SCRATCHPAD 0x%02h (got 0x%02h)", CMD_READ, w_cmd2));
      // LSB first: a firmware that sent MSB first would decode 0xCC as 0x33
      trans = 0;
      for (i = 0; i < 7; i = i + 1)
        if (w_bits[i] != w_bits[i+1]) trans = trans + 1;
      $display("    write-bit transitions in the first command: %0d of 7", trans);
    end

    // ---- the read slots, decoded -----------------------------------------
    $display("    read slots: %0d, bytes: %02h %02h (LSB first, want %02h %02h)",
             n_read_slots, dut.dmem[0], dut.dmem[1], SCRATCH_LSB, SCRATCH_MSB);
    check(dut.dmem[0] == SCRATCH_LSB && dut.dmem[1] == SCRATCH_MSB,
          $sformatf("the two temperature bytes came back LSB first (got %02h %02h, want %02h %02h)",
                    dut.dmem[0], dut.dmem[1], SCRATCH_LSB, SCRATCH_MSB));
    // non-vacuity: transitions
    trans = 0;
    for (i = 0; i < 7; i = i + 1) if ((SCRATCH_LSB>>i & 1) != (SCRATCH_LSB>>(i+1) & 1)) trans = trans + 1;
    for (i = 0; i < 7; i = i + 1) if ((SCRATCH_MSB>>i & 1) != (SCRATCH_MSB>>(i+1) & 1)) trans = trans + 1;
    check(trans >= 5,
          $sformatf("the payload has enough transitions to catch a repeated-bit fault (%0d of 14)", trans));

    $display("    DEBUG dmem: cnt3=%0d acc4=%02x idx5=%0d bytesleft10=%0d done14=%02x d0=%02x d1=%02x",
             dut.dmem[3], dut.dmem[4], dut.dmem[5], dut.dmem[10], dut.dmem[14], dut.dmem[0], dut.dmem[1]);
    $display("    DEBUG model: nrs=%0d xs=%0d pc=%0d", n_read_slots, xs, dut.u_cpu.pc);
    $display("    DEBUG phases seen: firmware dmem[12]=%0d d2(writebitctr)=%0d d6(sendreg)=%02x d10(cmdcnt)=%0d",
             dut.dmem[12], dut.dmem[2], dut.dmem[6], dut.dmem[10]);
    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
