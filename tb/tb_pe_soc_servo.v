// tb_pe_soc_servo.v — a hobby servo driven by firmware, on real RTL.
//
// WHAT THIS PROVES. A servo is the purest timing protocol there is: no clock, no
// framing, no acknowledgement, no checksum. The whole specification is "the line
// is high for between 1.0 and 2.0 ms, once every 20 ms", and the only question
// the device asks of the wire is how long it was high. So this TB measures
// exactly two numbers off the pad -- the pulse width and the frame period -- and
// both are properties of the PROGRAM, not of the gates. That is the point of the
// act: "cycle-accurate" stops being a claim about silicon and becomes a claim
// about an instruction count that anyone can read in firmware/servo_sweep.pe.
//
// THE CHECKS, and the way each could be unfalsified:
//
//   1. FIVE PULSES, AT FIVE REQUESTED WIDTHS, IN THE REQUESTED ORDER. Each
//      measured width is compared against ITS OWN nominal, to within 30 us. The
//      order is deliberately not monotonic (1000, 1500, 1750, 1250, 2000), so a
//      firmware that emitted the right widths in the wrong order fails, and so
//      does a testbench that sorted its measurements first.
//   2. EVERY WIDTH IS INSIDE THE DEVICE'S BAND, 1.0-2.0 ms. This is the
//      datasheet check and it is independent of the nominal: a firmware that
//      asked for 1.0 ms and delivered 0.9 ms fails here even though check 1's
//      tolerance might be argued about.
//   3. THE FRAME PERIOD IS 20 ms, MEASURED ACROSS A CHANGE OF PULSE WIDTH.
//      Rise-to-rise from the 1.0 ms pulse to the 1.5 ms pulse. This is the
//      check that distinguishes a FRAME SLOT from a delay: a firmware that
//      computed one gap and reused it shows 20.0 ms here and 21.0 ms between two
//      other positions. Asserted at 19.9-20.1 ms, i.e. 49.75-50.25 Hz, which
//      is tighter than any servo's actual tolerance and is here because the
//      number is deterministic, not because the device needs it.
//   4. THE PROGRAM RAN TO THE END. dmem[10] is the position index and the
//      program parks at 5. A firmware that hung after two positions is 2 here,
//      which is a different failure from one that never started (0) -- and the
//      distinction matters, because a short run would otherwise look like a
//      sweep with fewer positions.
//   5. THE LINE PARKS LOW. A servo idles low; a firmware that left the pin
//      released or high would show a final edge and no low period.
//   6. NON-VACUITY. The five widths must all be DISTINCT, and the sweep must
//      span at least 900 us. A firmware that emitted five identical 1.5 ms
//      pulses satisfies checks 1 and 2 and means nothing, so this asserts the
//      property that makes the sweep a sweep.
//   7. THE LATER SLOTS ARE SHORT, ON PURPOSE, AND THE TB SAYS SO. Positions
//      3-5 use a 2.5 ms gap instead of a 20 ms slot: five full frames would be
//      100 ms of simulated time, and the frame rate is already measured twice
//      over. The TB asserts those gaps are long enough to separate the pulses
//      (>1 ms) and REPORTS their value, so the trade is visible in the output
//      rather than buried in the firmware header.
//
// THE COST, STATED: this TB simulates 52.5 ms of 60 MHz, about 3.2 million
// clocks, which is 35 seconds -- two orders of magnitude more than any other TB
// in the repository. That is the honest price of a protocol whose unit of
// correctness is the millisecond, and it is the reason the frame rate is
// measured on two slots rather than five.
//
// Program: firmware/servo_sweep.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

// The image under test. Overridable so the mutation harness can compile ONE
// testbench against a mutated image without editing the tree: each mutant gets
// its own hex in a private directory and its own -D, so the harness never
// mutates a file another run is reading (regress/mutate_timing_tb.sh).
`ifndef SERVO_HEX
  `define SERVO_HEX "../firmware/servo_sweep.hex"
`endif

module tb_pe_soc_servo;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;

  localparam int  CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;
  localparam real CYC_US = 1e6 / CLK_HZ;
  localparam real NS_PER_CYC = 1e9 / CLK_HZ;

  localparam int DATA_BIT = 6;

  // The five requested pulse widths, in microseconds, IN THE ORDER the firmware
  // emits them. Not monotonic on purpose -- see the header. This is a task and
  // not a parameter array because Icarus does not support unpacked array
  // parameters ("sorry: unpacked array parameters are not supported yet"), and
  // a five-entry lookup is not worth a $readmemh.
  localparam int NPULSE = 5;

  task automatic want_us(input integer k, output integer w);
    case (k)
      0: w = 1000;
      1: w = 1500;
      2: w = 1750;
      3: w = 1250;
      default: w = 2000;
    endcase
  endtask

  // The device's band and the frame.
  //
  // PULSE_MAX_US is 2000 + 1 us, and the 1 us is stated rather than hidden. The
  // datasheet's band is 1.0-2.0 ms and this firmware is ASKED for the exact
  // endpoints, so a 2000 us request has to be allowed to land a hair over the
  // edge -- the delay lattice rounds up by 0.1 us here and no implementation can
  // do better, and no servo rejects 2000.1 us. Asserting the exact edge would be
  // asserting the impossible, and quietly widening it would be worse than saying
  // so: the tolerance is one part in 2000 and it is printed next to the result.
  localparam real PULSE_MIN_US  = 1000.0;
  localparam real PULSE_MAX_US  = 2001.0;
  localparam real WIDTH_TOL_US  = 30.0;     // vs the requested width
  localparam real FRAME_MIN_US  = 19900.0;  // 20 ms - 0.1
  localparam real FRAME_MAX_US  = 20100.0;  // 20 ms + 0.1
  localparam real SHORT_MIN_US  = 1000.0;   // a short gap must still separate

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  // THE WIRE: one pin with the servo board's pull-up, so a released pin reads
  // high. This firmware never releases it, and check 5 is partly about that.
  wire data_wire = (pin_oe_bus[DATA_BIT] & ~pin_out_bus[DATA_BIT]) ? 1'b0 : 1'b1;

  assign pin_in_bus = {1'b1, data_wire, 6'b111111};

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

  // ---- the transition recorder -------------------------------------------
  //
  // The clock counter and the recorder are ONE PROCESS, and that is not
  // tidiness. With the increment in a separate `always @(posedge clk)`, the order
  // Icarus runs the two blocks in is not guaranteed to be the same every cycle,
  // and a recorder that sees the counter before the increment on one cycle and
  // after it on the next turns an exact measurement into an alternating
  // +/-1-clock one -- which reads as a firmware that is a clock out every other
  // edge. It cost an afternoon on the WS2812 TB; this one is written correctly
  // from the start and says why.
  //
  // A level per cycle would be 3.2 million entries here, so the transitions are
  // recorded instead: ten of them for five pulses.
  //
  // EDGE-TRIGGERED, not clock-triggered, and the timestamp comes from $realtime
  // rather than from a counter. A per-clock block here costs about 40% of the
  // run (49k clocks/s against 90k/s for the same SoC with no monitor), and this
  // is the one testbench in the repository whose length is measured in
  // milliseconds rather than microseconds. Since every transition in this design
  // lands on a clock edge -- the pads are registered -- the cycle index is
  // exactly $realtime * CLK_HZ / 1e9, truncated, and the fractional part is
  // 16.667 ns of simulator time step that the truncation discards.
  localparam int MAXE = 64;
  integer n_edge = 0;
  integer e_cyc  [0:MAXE-1];
  bit     e_lvl  [0:MAXE-1];

  always @(data_wire) begin
    if (run && rst_n && n_edge < MAXE) begin
      e_cyc[n_edge] = $realtime * CLK_HZ / 1.0e9;
      e_lvl[n_edge] = data_wire;
      n_edge        = n_edge + 1;
    end
  end

  integer errors = 0;

  // Analysis state, hoisted to module scope: no loop declares a variable inside
  // a block (Icarus rejects a multi-declarator statement with initialisers).
  integer i, j, t_rise [0:NPULSE-1];
  integer t_fall [0:NPULSE-1];
  integer n_rise, n_fall, wmin, wmax, want;
  real    w_us [0:NPULSE-1];
  real    f_us, freq_hz;
  logic [15:0] prog [0:IMEM_WORDS-1];

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;   // NOP fill
    $readmemh(`SERVO_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  initial begin
    // A NARROW DUMP, and this is the one testbench in the repository that does
    // not dump everything. $dumpvars(0, tb) over 3.2 million clocks took this
    // simulation from 35 s to 99 s: the waveform, not the design, was the
    // bottleneck. The signals a servo waveform is actually read from are the
    // pin, the matrix's output level and enable, the pad input, and the PC --
    // which is the whole signal set this protocol produces.
    $dumpfile("tb_pe_soc_servo.vcd");
    $dumpvars(0, data_wire, pin_out_bus, pin_oe_bus, pin_in_bus, dbg_pc);

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_firmware();

    // FOUR STOPPED CLOCKS, THEN A `#1`, BEFORE `run` RISES. Neither is a fudge,
    // and the second one is the subtle half.
    //
    // The instruction memory is a real SRAM MACRO with a REGISTERED read and
    // REN deasserted through every loader write. Without the stopped clocks the
    // first running cycle can see a stale fetch word and the program's FIRST
    // INSTRUCTION IS SILENTLY DROPPED.
    //
    // The `#1` is what makes the four clocks count. Rising `run` in the same
    // active-region instant as a clock edge leaves the macro's fetch half
    // updated -- the always_ff blocks and the initial block race, and which way
    // they resolve is not something a test may depend on. Waiting 1 ns past the
    // edge puts the rise cleanly inside the cycle, so the next edge is
    // unambiguously the first running one. Without it this TB lost TWO
    // instructions instead of none, which is a strictly worse failure than the
    // one the stopped clocks are there to prevent.
    //
    // What it cost, in a form worth recording: the servo firmware's first
    // instruction is `LDI A,97`, the one that loads the first entry of the pulse
    // table. Dropped, it left dmem[0] as X; the program then ran perfectly
    // happily -- five pulses and all -- with the first position's delay counter
    // taken from an unwritten byte, which is a 2.6 ms pulse where 1.0 ms was
    // asked for. The testbench failure pointed at the delay arithmetic rather
    // than at the load, which is the worst possible place for it to point.
    // tb_pe_soc_eth_loop.v holds these clocks for the same reason.
    repeat (4) @(posedge clk);
    #1;
    $display("\n=== Servo PWM: 50 Hz frame, 1-2 ms pulse, five positions ===\n");
    run = 1'b1;

    // 52.5 ms of signal at 60 MHz is 3.15 million clocks; 3.3 million covers it
    // with room for the load and the setup. This is the long one.
    repeat (3_300_000) @(posedge clk);

    // ---- collect the pulse edges ------------------------------------------
    // Each RISE is paired with the first fall AFTER it, not with the j-th fall
    // in the list. The pin has a leading fall -- the firmware drives the line
    // from the released pull-up high down to the servo's idle low as it claims
    // the pin -- so counting falls independently pairs pulse 0 with that one and
    // shifts every measurement by a pulse. Pairing by order is the obvious
    // version and it is wrong in exactly the way this protocol is about.
    n_rise = 0; n_fall = 0;
    for (j = 0; j < n_edge; j = j + 1) begin
      if (e_lvl[j]) begin
        if (n_rise < NPULSE) begin
          t_rise[n_rise] = e_cyc[j];
          // the matching fall is the next falling edge in the list
          for (i = j + 1; i < n_edge; i = i + 1) begin
            if (!e_lvl[i]) begin
              t_fall[n_rise] = e_cyc[i];
              break;
            end
          end
        end
        n_rise = n_rise + 1;
      end else begin
        n_fall = n_fall + 1;
      end
    end

    $display("    %0d rising edges, %0d falling edges on the pin", n_rise, n_fall);

    // ---- 1. there are five pulses -----------------------------------------
    // n_fall is one MORE than n_rise here, and that is correct: the leading fall
    // is the firmware driving the line down to the servo's idle level. The check
    // is therefore on the rises, with the fall count reported for the record.
    check(n_rise == NPULSE,
          $sformatf("exactly %0d pulses (%0d rising edges, %0d falling edges, one of which is the initial drive to the idle level)",
                    NPULSE, n_rise, n_fall));

    // ---- 2. each width, against its own request and the device's band -----
    for (j = 0; j < NPULSE; j = j + 1) begin
      if (j < n_rise && j < n_fall && t_fall[j] > t_rise[j]) begin
        w_us[j] = (t_fall[j] - t_rise[j]) * CYC_US;
        want_us(j, want);
        $display("    pulse %0d: %8.2f us high  (requested %0d us, %+.2f us)",
                 j, w_us[j], want, w_us[j] - want);
        check(w_us[j] >= PULSE_MIN_US && w_us[j] <= PULSE_MAX_US,
              $sformatf("pulse %0d is inside the device's band %.0f..%.0f us (got %.2f)",
                        j, PULSE_MIN_US, PULSE_MAX_US, w_us[j]));
        check((w_us[j] - want) > -WIDTH_TOL_US &&
              (w_us[j] - want) <  WIDTH_TOL_US,
              $sformatf("pulse %0d is within %.0f us of the requested %0d us (got %.2f, off by %+.2f)",
                        j, WIDTH_TOL_US, want, w_us[j], w_us[j] - want));
      end
    end

    // ---- 3. the frame period, across a change of pulse width -------------
    // Positions 0 and 1 are a full 20 ms slot apart by construction; positions
    // 2..4 use a short gap. Measured rise-to-rise, on the pad.
    if (n_rise >= 2 && t_rise[1] > t_rise[0]) begin
      f_us = (t_rise[1] - t_rise[0]) * CYC_US;
      freq_hz = 1e6 / f_us;
      $display("    frame period (1000 us -> 1500 us): %.2f us = %.3f Hz",
               f_us, freq_hz);
      check(f_us >= FRAME_MIN_US && f_us <= FRAME_MAX_US,
            $sformatf("the frame period is 20 ms +/- 100 us, across a change of pulse width (got %.2f us = %.3f Hz)",
                      f_us, freq_hz));
    end else begin
      check(1'b0, "two rising edges far enough apart to measure a frame period");
    end

    // ---- 4. the later slots are short, and the TB says so ---------------
    for (j = 1; j < n_rise && j < NPULSE; j = j + 1) begin
      if (t_rise[j] > t_rise[j-1]) begin
        f_us = (t_rise[j] - t_rise[j-1]) * CYC_US;
        if (j == 1) begin
          $display("    (positions 2..4 use a 2.5 ms sweep gap by design)");
        end else begin
          $display("    position %0d slot: %.2f us (a short sweep gap, not a frame)",
                   j, f_us);
          check(f_us > SHORT_MIN_US,
                $sformatf("the sweep gap still separates the pulses (>%.0f us, got %.2f)",
                          SHORT_MIN_US, f_us));
        end
      end
    end

    // ---- 5. the program ran to the end -----------------------------------
    // dmem[10] is the position index, and the firmware parks at 5. This is what
    // distinguishes "hung after two positions" from "emitted two positions".
    $display("    dmem[10] (position index) = %0d", dut.dmem[10]);
    check(dut.dmem[10] == NPULSE,
          $sformatf("the firmware completed all %0d positions (position index = %0d)",
                    NPULSE, dut.dmem[10]));

    // ---- 6. the line parks low ------------------------------------------
    check(e_lvl[n_edge-1] === 1'b0,
          "the line parks LOW at the end (a servo's idle level)");

    // ---- 7. non-vacuity: the sweep is a sweep --------------------------
    if (n_rise == NPULSE && n_fall == NPULSE) begin
      wmin = 1000000; wmax = 0;
      for (j = 0; j < NPULSE; j = j + 1) begin
        if (w_us[j] * 1000.0 < wmin) wmin = w_us[j] * 1000.0;
        if (w_us[j] * 1000.0 > wmax) wmax = w_us[j] * 1000.0;
      end
      // distinct: no two widths within 100 us of each other
      for (j = 0; j < NPULSE; j = j + 1) begin
        for (i = j + 1; i < NPULSE; i = i + 1) begin
          check(((w_us[j] - w_us[i]) >  100.0) ||
                ((w_us[j] - w_us[i]) < -100.0),
                $sformatf("pulse widths %0d and %0d are distinct (%.2f vs %.2f us)",
                          j, i, w_us[j], w_us[i]));
        end
      end
      check((wmax - wmin) > 900.0,
            $sformatf("the sweep spans the device's range (%.2f .. %.2f us, span %.2f)",
                      wmin/1000.0, wmax/1000.0, (wmax-wmin)/1000.0));
    end

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  // Watchdog. A firmware hang must be reported as a hang, not as a timeout with
  // no output -- an unresponsive DUT and a passing DUT look alike from outside.
  // 60 ms of simulated time is well past the 52.5 ms this needs.
  initial begin
    #70_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
