// tb_pe_soc_dht11.v — a DHT11 sensor read by firmware, on real RTL, with a
// modelled sensor on the other end of the wire.
//
// WHAT THIS PROVES, AND WHY IT IS THE HARDEST OF THE THREE TIMING ACTS.
// A WS2812 strip and a servo are both WRITE-ONLY protocols: the host decides
// the waveform and the device is passive. The DHT11 is a two-way handshake in
// which the host's only job is to be in the right place in time, twice, and then
// to read 40 bits whose VALUE IS A PULSE WIDTH. So this TB models a sensor and
// drives it at the edges of its own specification: 26 us for a 0's release and
// 70 us for a 1's, which is the worst case of each, not the nominal. A firmware
// that decoded the nominal frame and failed here would be a firmware that works
// on the bench.
//
// THE CHECKS, and the way each could be unfalsified:
//
//   1. THE START SIGNAL, MEASURED ON THE PIN: >= 18 ms of low (the sensor's
//      reset) and a host-high window of 20-40 us. The high window is a separate
//      check because it is the part a firmware can get wrong in a way the low
//      cannot: the DHT11 pulls its own line low to answer, so a host that
//      released without pulling high first never triggers a conversion at all,
//      and a testbench that only measured the low period would pass it.
//   2. THE HOST RELEASES. Checked on the SoC's own pin_oe, so the wire model
//      cannot hide it: a host that kept driving would fight the sensor for the
//      line and read its own writes.
//   3. FORTY BITS, DECODED TO WHAT THE SENSOR SENT, PLUS THE CHECKSUM. The
//      payload is written in the TB and compared, and the DHT11's own byte sum
//      is verified -- the sensor's checksum is a real integrity check and a
//      firmware that shifted the wrong way still produces five plausible bytes.
//   4. THE SAMPLE MARGIN, MEASURED BOTH SIDES. The TB taps the host's port-0
//      reads (the same white-box technique tb_pe_soc_tick uses) to get the exact
//      sample instants, and compares each against the sensor's release window
//      for the bit that was sent. Every sample must be after the LONGEST
//      possible 0-release (28 us) and before the SHORTEST possible 1-release
//      (70 us), and the TB reports the smallest margin on each side. This is
//      the protocol's real specification, expressed as a number.
//   5. THE PAYLOAD IS NOT A CONSTANT. The value is chosen with both bit values
//      in every byte and 24 bits of transitions, so a firmware that returned
//      the previous bit again, or that shifted the wrong way, cannot pass -- and
//      the TB asserts the transition count rather than trusting it.
//   6. THE PROGRAM RAN TO THE END (dmem[15]).
//
// THE COST: 22 ms of 60 MHz, about 1.33 million clocks, roughly 15 seconds.
// The 18 ms start signal is 1.08 million of those clocks and is not negotiable:
// it is the sensor's specification.
//
// Program: firmware/dht11_read.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

// The image under test. Overridable so the mutation harness can compile ONE
// testbench against a mutated image without editing the tree (see
// regress/mutate_timing_tb.sh).
`ifndef DHT11_HEX
  `define DHT11_HEX "../firmware/dht11_read.hex"
`endif

module tb_pe_soc_dht11;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;

  localparam int  CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;
  localparam real CYC_US = 1e6 / CLK_HZ;
  localparam real NS_PER_CYC = 1e9 / CLK_HZ;

  localparam int DATA_BIT = 6;

  // The DHT11's frame: humidity, temperature, and the checksum byte. Chosen with
  // both bit values in every byte and 24 bit-transitions across the frame, so
  // neither a stuck bit nor a repeated-bit bug can produce it.
  localparam logic [7:0] PAY_HUM  = 8'h2C;   // 40 % RH, a plausible reading
  localparam logic [7:0] PAY_TEMP = 8'h01;   // 40.0 C
  // On a real DHT11 the last two bytes are the temperature's decimal and
  // fractional parts and would be small. They are ALTERNATING here so the frame
  // carries 23 bit-transitions: a firmware that repeats the previous bit, or
  // that shifts the wrong way, cannot produce this by accident, and the TB
  // asserts the transition count rather than taking the firmware's word for it.
  localparam logic [7:0] PAY_TL   = 8'hAA;
  localparam logic [7:0] PAY_TH   = 8'h55;
  localparam logic [7:0] PAY_CKS  = 8'h2C;   // the low byte of 0x2C+0x01+0xAA+0x55

  // The sensor's windows, at the WORST case of each: a 0's release is specified
  // as 26-28 us and a 1's as about 70 us. Driving the 0 at 28 and the 1 at 70
  // is the pair that gives the host the least room in the middle and the most
  // room at the edges -- which is the pair a host has to survive.
  localparam real ACK_LOW_US   = 80.0;
  localparam real ACK_HIGH_US  = 80.0;
  localparam real BIT_LOW_US   = 50.0;
  localparam real BIT_HIGH0_US = 28.0;   // a 0: the shortest-to-longest 0 window
  localparam real BIT_HIGH1_US = 70.0;   // a 1
  localparam real BUS_HOLD_US  = 50.0;   // the bus hold after the 40th bit

  // The host's obligations.
  localparam real START_MIN_US = 18000.0;
  localparam real HOST_HI_MIN_US = 20.0;
  localparam real HOST_HI_MAX_US = 40.0;

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  // THE WIRE. A pull-up on the data line (the DHT11 board has one), the SoC's
  // pads, and the sensor's own open-drain pull-down. Three drivers, and the
  // line is low if ANY of them pulls it: that is the whole reason a DHT11 bus
  // works with the host and the sensor both driving it.
  logic sensor_low = 1'b0;
  wire  soc_drives_low = pin_oe_bus[DATA_BIT] & ~pin_out_bus[DATA_BIT];
  wire  dht_line = (soc_drives_low | sensor_low) ? 1'b0 : 1'b1;

  assign pin_in_bus = {1'b1, dht_line, 6'b111111};

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
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_timer(dbg_timer),
    // R3 debug control, idle. These two ports arrived with the R3 block, and a
    // testbench that predates them leaves them UNCONNECTED -- which arrives as
    // Z, makes the core's execute gate X, and the firmware then never executes
    // a single instruction: every dmem read comes back x and the pin never
    // moves. rtl/pe_cpu.v now defaults them defensively too; this tie-off is
    // the act not DEPENDING on that, so the two repairs cannot mask each other.
    .dbg_hold(1'b0), .dbg_step(1'b0)
  );

  always #(CLK_NS/2) clk = ~clk;

  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  integer errors = 0;

  // Analysis state, hoisted to module scope: no loop declares a variable inside
  // a block (Icarus rejects a multi-declarator statement with initialisers).
  integer i, j, n_rel, idx, t_rel_us, t_hi_us;
  integer start_low_us, host_hi_us, t_fall, t_rise, t_release, t_next_low;
  integer rel_start [0:41];      // the start of each bit's release, in us
  integer rel_len   [0:41];      // its length, in us
  integer samp_us   [0:47];      // the host's sample instants, in us
  logic [7:0] samp_lvl;
  real    m0_us, m1_us, m0_min, m1_min;
  logic [15:0] prog [0:IMEM_WORDS-1];

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;   // NOP fill
    $readmemh(`DHT11_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---- the sensor ----------------------------------------------------------
  //
  // Armed by the host's release -- the moment the DHT11 sees the line go high
  // while it is not driving it, which is the end of the host's start signal.
  // It then runs the acknowledge and the 40 bits on real time, at the worst case
  // of each window, and holds the bus low once more at the end.
  //
  // WHY THE BUS HOLD AT THE END. The host samples 45 us after the line goes
  // high, which is AFTER a 0's release has ended -- that is the only way to tell
  // a 0 from a 1, since a 0's release is high and a 1's is high too. The "the
  // line is low again" that the host relies on is the NEXT bit's 50 us prefix,
  // and after the fortieth bit there is no next bit. So a sensor that released
  // the bus immediately would make the last bit unreadable by every method in
  // use, which is not what the part does: it holds the bus low through the end
  // of the frame. Modelling that hold is therefore modelling the sensor, not
  // bending the test to the firmware -- and the firmware's 45 us choice is
  // checked against the 28 us and 70 us windows either way.
  // The bit value of payload byte `b`, bit `k` (k = 0 is the MSB).
  function [7:0] pay_bit(input integer b, input integer k);
    case (b)
      0: pay_bit = PAY_HUM;
      1: pay_bit = PAY_TEMP;
      2: pay_bit = PAY_TL;
      3: pay_bit = PAY_TH;
      default: pay_bit = PAY_CKS;
    endcase
  endfunction

  localparam int S_IDLE = 0, S_ACK_LO = 1, S_ACK_HI = 2, S_BIT_LO = 3,
                 S_BIT_HI = 4, S_HOLD = 5, S_DONE = 6;
  integer sensor_state = S_IDLE;
  integer sensor_bit   = 0;
  integer state_end_us = 0;
  logic   armed = 1'b0;
  logic   saw_start = 1'b0;   // the host has pulled the line down at least once

  always @(posedge clk) begin
    if (run && rst_n) begin
      // ARMED BY THE HOST'S RELEASE, AND NOT BEFORE. The pin idles RELEASED, so
      // "the host let go" is true from the first cycle; arming on it alone starts
      // the sensor's whole timeline during the host's 18 ms start signal, and the
      // sensor is then long finished (and idle) by the time the host releases.
      // The host's RELEASE only means something after the host has DRIVEN the
      // line low, which is the start signal. Getting this wrong is silent and
      // total: the firmware sits in its "wait for the line to go low" loop for
      // the rest of the simulation, with a perfect-looking wire trace.
      if (soc_drives_low) saw_start = 1'b1;
      if (!armed && saw_start && !pin_oe_bus[DATA_BIT]) begin
        armed         = 1'b1;
        sensor_state  = S_ACK_LO;
        state_end_us  = cyc * CYC_US + ACK_LOW_US;
      end

      if (armed && sensor_state != S_DONE && (cyc * CYC_US) >= state_end_us) begin
        case (sensor_state)
          S_ACK_LO: begin
            sensor_state = S_ACK_HI;
            state_end_us = cyc * CYC_US + ACK_HIGH_US;
            n_rel = n_rel + 1;             // an acknowledge is not a bit
          end
          S_ACK_HI: begin
            sensor_state = S_BIT_LO;
            state_end_us = cyc * CYC_US + BIT_LOW_US;
            n_rel = n_rel + 1;
          end
          S_BIT_LO: begin
            sensor_state = S_BIT_HI;
            // the bit's value: MSB first over the five payload bytes
            samp_lvl    = (pay_bit(sensor_bit / 8, sensor_bit % 8) >>
                           (7 - (sensor_bit % 8))) & 1;
            rel_start[sensor_bit] = cyc * CYC_US;
            rel_len[sensor_bit]   = samp_lvl ? BIT_HIGH1_US : BIT_HIGH0_US;
            state_end_us = cyc * CYC_US + rel_len[sensor_bit];
            n_rel = n_rel + 1;
          end
          S_BIT_HI: begin
            sensor_state = S_BIT_LO;
            state_end_us = cyc * CYC_US + BIT_LOW_US;
            if (sensor_bit == 39) begin
              sensor_state = S_HOLD;
              state_end_us = cyc * CYC_US + BUS_HOLD_US;
            end
            sensor_bit = sensor_bit + 1;
          end
          S_HOLD: begin
            sensor_state = S_DONE;
            sensor_low  = 1'b0;
          end
          default: ;
        endcase
      end

      // the sensor's own drive
      case (sensor_state)
        S_ACK_LO, S_BIT_LO, S_HOLD: sensor_low = 1'b1;
        default:                   sensor_low = 1'b0;   // released: the pull-up
      endcase
    end
  end

  // ---- the host's line events and its port reads --------------------------
  //
  // Both are recorded on the clock edge with $realtime, so the timestamps are
  // on the same grid as everything else and the cycle counter stays a separate
  // cross-check. A clock-triggered monitor that compared levels every cycle
  // would be no more accurate here and would cost 40% of the run.
  localparam int MAXE = 64;
  localparam int MAXS = 64;
  integer n_edge = 0, n_sample = 0, n_oe = 0;
  integer e_cyc [0:MAXE-1];
  bit     e_lvl [0:MAXE-1];
  integer e_oe_cyc [0:MAXE-1];
  bit     e_oe     [0:MAXE-1];

  always @(pin_oe_bus[DATA_BIT]) begin
    if (run && rst_n && n_oe < MAXE) begin
      e_oe_cyc[n_oe] = $realtime * CLK_HZ / 1.0e9;
      e_oe[n_oe]     = pin_oe_bus[DATA_BIT];
      n_oe           = n_oe + 1;
    end
  end

  always @(dht_line) begin
    if (run && rst_n && n_edge < MAXE) begin
      e_cyc[n_edge] = $realtime * CLK_HZ / 1.0e9;
      e_lvl[n_edge] = dht_line;
      n_edge        = n_edge + 1;
    end
  end

  // The host's bit samples are `IN A, PIN`, a read of port 0. Tapping io_re is
  // the same white-box technique tb_pe_soc_tick uses on io_we: the alternative
  // is to infer the sample instant from the line, and the line does not move at
  // a sample.
  //
  // BUT THE HOST ALSO READS THE PIN IN ITS TWO EDGE-WAIT LOOPS, thousands of
  // times, so a naive tap records a few thousand "samples" of which forty are
  // the real ones. They are separable by their SPACING, not by any signal: the
  // spin loops poll every three instructions, so consecutive reads are 3 clocks
  // apart, while the real sample follows the 45 us delay and is ~2,700 clocks
  // after the previous read. A read is therefore recorded only when more than
  // 100 clocks have passed since the last recorded one. The threshold is 33
  // times the spin loop's spacing and 27 times smaller than the delay it has to
  // bridge, so it cannot confuse the two.
  // The test is on the gap AFTER a read, not before it, and that ordering is the
  // whole filter. A spin loop's reads are 3 clocks apart, so each is followed by
  // another read almost immediately; a real sample is followed by the
  // accumulate, the arm and the 45 us delay -- about 2,700 clocks with no read in
  // it. So a read is recorded when the NEXT read turns out to be far away, which
  // is only knowable one read late. Doing it the other way round (record a read
  // when the PREVIOUS one was far away) records the first read of every spin
  // loop instead, because that read is the one preceded by the delay.
  integer last_read_cyc = 0;
  integer trans;
  logic [7:0] cks;
  always @(posedge clk) begin
    if (run && rst_n && dut.io_re && dut.io_port == 4'h0) begin
      if (last_read_cyc > 0 && (cyc - last_read_cyc) > 100 && n_sample < MAXS) begin
        // $realtime is in NANOSECONDS (this module's time unit) and rel_start[]
        // is in MICROSECONDS, so the conversion is /1000 and nothing else. Two
        // wrong factors were tried here -- cycles (a factor of 60 out) and
        // $realtime*1e6/CLK_HZ (a factor of 60 the other way) -- and both produce
        // margins in the hundreds of thousands of microseconds, which look like
        // a real measurement and are neither.
        samp_us[n_sample] = $realtime / 1000.0;
        n_sample          = n_sample + 1;
      end
      last_read_cyc = cyc;
    end
  end

  initial begin
    $dumpfile("tb_pe_soc_dht11.vcd");
    $dumpvars(0, dht_line, pin_out_bus, pin_oe_bus, pin_in_bus, dbg_pc, sensor_low);

    n_edge = 0; n_sample = 0; n_rel = 0; n_oe = 0;

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_firmware();
    // FOUR STOPPED CLOCKS, THEN A `#1`, BEFORE `run` RISES: the instruction
    // memory is a real SRAM macro with a registered read, and without this the
    // first instruction of the program is silently dropped. The `#1` is what
    // makes it deterministic -- rising `run` at the same instant as a clock
    // edge leaves the macro's fetch half updated. See tb_pe_soc_servo.v for the
    // full story and tb_pe_soc_eth_loop.v for the same four clocks.
    repeat (4) @(posedge clk);
    #1;

    $display("\n=== DHT11: start signal + a 40-bit timed read handshake ===\n");
    run = 1'b1;
    repeat (1_400_000) @(posedge clk);

    // ---- 1. the start signal, from the pin --------------------------------
    t_fall = -1; t_rise = -1;
    for (j = 0; j < n_edge; j = j + 1) begin
      if (!e_lvl[j] && t_fall < 0) t_fall = e_cyc[j];
      else if (e_lvl[j] && t_fall >= 0 && t_rise < 0) t_rise = e_cyc[j];
    end
    check(t_fall >= 0, "the host pulled the data line low (the start signal)");
    if (t_fall >= 0 && t_rise > t_fall) begin
      start_low_us = (t_rise - t_fall) * CYC_US;
      $display("    start signal: line low for %.1f us", start_low_us);
      check(start_low_us > START_MIN_US,
            $sformatf("the start signal is >= %.0f us (the sensor's reset) -- got %.1f us",
                      START_MIN_US, start_low_us));
    end

    // THE HOST-HIGH WINDOW CANNOT BE MEASURED FROM THE LINE, and that is worth
    // knowing: the host pulls high, drives high, and then releases, and the
    // pull-up holds the line high throughout -- so the release moves nothing.
    // An edge-based measurement would find the rising edge that STARTED the
    // window and report a window of zero. The release is therefore taken from
    // the SoC's own pin_oe, which is also the stronger source: it is the DUT's
    // output rather than a wire model.
    t_release = -1;
    for (j = 0; j < n_oe; j = j + 1) begin
      if (!e_oe[j] && e_oe_cyc[j] > t_rise) begin t_release = e_oe_cyc[j]; break; end
    end
    if (t_release > t_rise) begin
      host_hi_us = (t_release - t_rise) * CYC_US;
      $display("    host-high window: %.1f us, then released (pin_oe)", host_hi_us);
      check(host_hi_us >= HOST_HI_MIN_US && host_hi_us <= HOST_HI_MAX_US,
            $sformatf("the host-high window is %.0f..%.0f us -- got %.1f",
                      HOST_HI_MIN_US, HOST_HI_MAX_US, host_hi_us));
    end else begin
      check(1'b0, "the host released the data line after its high window");
    end

    // ---- 2. the host released, so the sensor could answer -----------------
    check(!pin_oe_bus[DATA_BIT],
          "the host RELEASED the data line (the sensor drives it from here)");

    // ---- 3. the forty bits and the checksum -------------------------------
    $display("    %0d samples (spin-loop reads filtered), %0d bits sent by the sensor",
             n_sample, sensor_bit);
    check(dut.dmem[15] == 8'h01,
          $sformatf("the firmware read all 40 bits (dmem[15] = %02h)", dut.dmem[15]));
    $display("    bytes: %02h %02h %02h %02h %02h   (humidity, temperature, checksum)",
             dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3], dut.dmem[4]);
    check(dut.dmem[0] == PAY_HUM  && dut.dmem[1] == PAY_TEMP &&
          dut.dmem[2] == PAY_TL   && dut.dmem[3] == PAY_TH,
          $sformatf("the four data bytes are what the sensor sent (got %02h %02h %02h %02h, want %02h %02h %02h %02h)",
                    dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
                    PAY_HUM, PAY_TEMP, PAY_TL, PAY_TH));
    check(dut.dmem[4] == PAY_CKS,
          $sformatf("the checksum byte is what the sensor sent (got %02h, want %02h)",
                    dut.dmem[4], PAY_CKS));
    cks = dut.dmem[0] + dut.dmem[1] + dut.dmem[2] + dut.dmem[3];
    check(cks[7:0] == PAY_CKS,
          $sformatf("the DHT11's own byte sum checks out over the four data bytes (sum low byte %02h, want %02h)",
                    cks[7:0], PAY_CKS));

    // ---- 4. the sample margin, both sides ---------------------------------
    // For every bit: the sample must land AFTER the longest possible 0-release
    // (28 us) and BEFORE the 1-release ends (70 us). Both margins are reported.
    m0_min = 1e9; m1_min = 1e9;
    for (j = 0; j < 40; j = j + 1) begin
      t_rel_us = rel_start[j];
      if (n_sample > j) begin
        t_hi_us = samp_us[j];
        if (rel_len[j] < 30.0) begin
          m0_us = t_hi_us - (t_rel_us + BIT_HIGH0_US);
          if (m0_us < m0_min) m0_min = m0_us;
        end else begin
          m1_us = (t_rel_us + BIT_HIGH1_US) - t_hi_us;
          if (m1_us < m1_min) m1_min = m1_us;
        end
      end
    end
    $display("    sample margin: %0.1f us past the longest 0-release, %0.1f us before the 1-release ends",
             m0_min, m1_min);
    check(m0_min > 0.0,
          $sformatf("every sample is after a 0's release has ended (worst margin %.1f us)", m0_min));
    check(m1_min > 0.0,
          $sformatf("every sample is before a 1's release has ended (worst margin %.1f us)", m1_min));

    // ---- 5. the payload is not a constant ---------------------------------
    // 24 bit-transitions across the frame: a firmware that returned the previous
    // bit, or that shifted the wrong way, cannot produce this and the TB does
    // not have to take the firmware's word for it.
    trans = 0;
    for (i = 0; i < 39; i = i + 1) begin
      if ((rel_len[i] > 30.0) != (rel_len[i+1] > 30.0)) trans = trans + 1;
    end
    $display("    bit-transitions in the frame: %0d of 39", trans);
    check(trans >= 20,
          $sformatf("the frame has enough bit-transitions to catch a repeated-bit or bit-order fault (%0d of 39)", trans));

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  // Watchdog: 22 ms of signal, so 30 ms is the bound.
  initial begin
    #30_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
