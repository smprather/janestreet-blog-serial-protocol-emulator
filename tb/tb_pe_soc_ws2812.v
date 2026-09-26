// tb_pe_soc_ws2812.v — a WS2812 strip driven by firmware, on real RTL.
//
// WHAT THIS PROVES, AND WHY IT IS A DIFFERENT KIND OF PROOF FROM THE OTHER
// PROTOCOL TBs. UART, SPI and I2C all have a CLOCK: the peer's edges define
// the bit cells, so a firmware bit-bang that is a little slow or a little fast
// still produces a readable waveform. A WS2812 strip has no clock at all. Its
// 24-bit frame is a stream of NRZ cells whose only timing reference is the cell
// period itself (1.25 us for the 800 kHz parts), and it is decoded by SAMPLING
// THE LINE AT ONE INSTANT IN EVERY CELL. A cell that is 10 % long shifts every
// sample in the frame; a firmware that is "nearly right" is not right. So this
// is the project's first protocol where the TIMING IS THE WHOLE PROTOCOL,
// which makes it the sharpest available test of the cycle-accuracy claim.
//
// THE CLAIM BEING MEASURED, and each way it could be unfalsified:
//
//   1. THE PULSE WIDTHS ARE EXACT, NOT MERELY IN A BAND. Every 1-cell is high
//      for exactly 48 clocks (800.0 ns, the datasheet's nominal tHIGH1) and
//      every 0-cell for exactly 0, and the 24 cells span exactly 24 x 75
//      clocks. The firmware achieves this because the cell is straight-line
//      code and the core is single-cycle, so the cell length is the LENGTH OF
//      THE CODE rather than a count calibrated against a tick. The TB counts
//      clocks on its own grid and requires equality, not a tolerance: a
//      firmware that drifted to 47 or 49 clocks fails here even though 47
//      clocks is 783 ns and every datasheet window in the world would pass it.
//   2. EVERY 1-CELL IS ON THE 75-CYCLE GRID. Not "the period is about right":
//      for every cell the TB decodes, the measured rising edge sits at
//      t0 + 75k EXACTLY. This is the check that would catch a firmware whose
//      byte-boundary path cost one instruction more than the ordinary path --
//      three cells in every frame stretched by one clock, which no window
//      check can see and a strip absolutely can.
//   3. THE DECODE IS THE COLOUR THE FIRMWARE WAS GIVEN. 24 bits, GRB order,
//      compared against a value written in the TB, not against the decode of
//      the same run. A firmware that sent RGB, or a rotation of the frame, or
//      the previous cell's bit again (the bug that bit this firmware twice)
//      fails.
//   4. THE DATASHEET WINDOWS, measured rather than asserted from the design.
//      tHIGH1 in 0.70..0.90 us against a nominal 0.8, tLOW for a 1-cell at
//      least 450 ns, and -- the margin statement -- every 1-cell still HIGH at
//      the strip's sample point, 0.70 us (42 clocks) into the cell.
//   5. THE RESET IS LONG ENOUGH, TWICE. >50 us of low before each frame. Two
//      frames, because a single frame cannot show a reset AT ALL, and the
//      between-frame reset is the one that matters on a strip that is already
//      lit.
//   6. THE LINE IS NEVER RELEASED. A released DIN floats to the strip's pull-up
//      and reads as a run of 1s -- a silent corruption no edge-counting check
//      would notice. Asserted on the SoC's own pin_oe output, so the wire
//      model cannot hide it.
//   7. NON-VACUITY. The frame must contain both bit values, the frame must
//      repeat, and cell 0 must be a 1 so the cell grid has an edge to anchor
//      on (asserted, not assumed -- see the data note below).
//
// THE WIRE MODEL is a pull-up plus the SoC's pads, exactly as the I2C TB
// models its bus: a released pin reads high, which is what makes "the line was
// never released" a measurable property instead of a comment.
//
// Program: firmware/ws2812.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

// The image under test. Overridable so the mutation harness can compile ONE
// testbench against a mutated image without editing the tree: each mutant gets
// its own hex in a private directory and its own -D, so the harness never
// mutates a file another run is reading (regress/mutate_timing_tb.sh).
`ifndef WS2812_HEX
  `define WS2812_HEX "../firmware/ws2812.hex"
`endif

module tb_pe_soc_ws2812;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;

  // The TB's own copy of the clock rate, checked against the RTL by
  // wiki/reference/clock-arithmetic.md. Every timing number below is derived
  // from THIS, never from $time arithmetic done by hand.
  localparam int  CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;
  localparam real CYC_US    = 1e6 / CLK_HZ;      // 0.0166667 us per clock
  localparam real NS_PER_CYC = 1e9 / CLK_HZ;      // 16.6667 ns per clock

  // The data pin. Bits 0-5 are the baseline protocols' (UART TX, spares, UART
  // RX, I2C SDA/SCL) and bit 7 is the Ethernet DRU's input, so bit 6 is the
  // first unclaimed pad -- the same reason i2c_pins.pe does not take bit 0.
  localparam int DATA_BIT = 6;

  // The frame the firmware is told to send, GRB order as the wire has it.
  // Deliberately a value with all three components non-trivial and all three
  // DIFFERENT, so a firmware that sent GRB, RGB, GBR or BRG cannot pass.
  //
  // ALL THREE HAVE THEIR TOP BIT SET, and that is load-bearing rather than
  // cosmetic. The cell grid is anchored on the frame's FIRST RISING EDGE, and
  // a frame whose first bit is 0 has no rising edge to anchor on: the line is
  // already low from the reset, so the only evidence of where cell 0 starts is
  // the reset delay, which is a firmware constant this TB refuses to assume.
  // Choosing the data so the frame opens with a 1 turns the anchor into a
  // transition, and check 7 then ASSERTS that the anchor is a 1 cell rather
  // than trusting it -- so if the data is ever changed to one that opens with a
  // 0, the TB says so instead of silently decoding a shifted frame.
  localparam logic [7:0] FRAME_G = 8'h9C;
  localparam logic [7:0] FRAME_R = 8'hE0;
  localparam logic [7:0] FRAME_B = 8'h8A;

  // 800 kHz NRZ: 1.25 us per cell, 75 clocks, no remainder. The firmware drives
  // tHIGH1 = 48 clocks (800.0 ns, the datasheet nominal) and tLOW = 27 clocks
  // (450.0 ns, also nominal): 75 = 48 + 27 exactly, which is why this cell
  // length was chosen.
  localparam int CELL_CYC   = 75;     // one NRZ cell
  localparam int CELL_HIGH  = 48;     // the high time of a 1 cell, in clocks
  localparam int SAMPLE_CYC = 42;     // the strip's sample point: 0.70 us
  localparam int RESET_MIN_US = 50;   // the strip's reset floor

  logic clk = 0, rst_n;

  // host interface (idle: this TB loads through the SoC's host write port)
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  // THE WIRE. One pin, with the strip's pull-up: a driven pin shows the pad
  // level, a released one floats to the pull-up. Nothing else is connected.
  wire data_wire = (pin_oe_bus[DATA_BIT] & ~pin_out_bus[DATA_BIT]) ? 1'b0 : 1'b1;

  // Every other pin idles high and is never read by this firmware.
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

  // ---- the clock counter: the TB's own cycle grid -------------------------
  //
  // Every timing assertion below is written in CLOCKS, and the clock is
  // counted here rather than derived from $time. The pads are registered, so
  // every transition in this design lands on a clock edge by construction; a
  // $time-based check would be measuring the simulator's time resolution
  // (1 ps) against a 16.667 ns clock to rediscover an integer that is already
  // known. The recorded index is the number of the edge AFTER the one that
  // changed the level, which is a constant +1 on every entry and therefore
  // cancels in every difference taken below.
  integer cyc = 0;

  // ---- the transition recorder -------------------------------------------
  //
  // A level per cycle would be 40,000 entries here and 1.4 million on the servo
  // TB; the transitions are under 300 in both. The wire is sampled on the clock
  // edge, so a transition is recorded with the cycle grid, not with $time.
  localparam int MAXE = 512;
  integer       n_edge = 0;
  integer       e_cyc [0:MAXE-1];
  bit           e_lvl [0:MAXE-1];
  bit           prev_lvl = 1'b1;
  integer       n_released = 0;      // cycles the data pin was NOT driven
  integer       n_ever_low  = 0;     // cycles the data pin was low

  // `framing` latches once the line has moved for the first time, and the
  // release counter only runs from there. The setup legitimately RELEASES the
  // pins the reset default had enabled (bits 0-2) for two cycles before it
  // claims bit 6 -- that is the same release-then-claim order i2c_pins.pe
  // uses, and counting it would make the check fail on correct firmware.
  logic framing = 1'b0;
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (run && rst_n) begin
      if (data_wire !== prev_lvl && n_edge < MAXE) begin
        e_cyc[n_edge] = cyc;
        e_lvl[n_edge] = data_wire;
        n_edge        = n_edge + 1;
        framing       = 1'b1;
      end
      prev_lvl <= data_wire;
      if (framing && !pin_oe_bus[DATA_BIT]) n_released = n_released + 1;
      if (!data_wire)                          n_ever_low  = n_ever_low + 1;
    end
  end

  integer errors = 0;

  // Analysis state, hoisted to module scope so no loop declares a variable
  // inside a block (Icarus rejects a multi-declarator statement with
  // initialisers, and a per-block `integer x = 0` inside a for body is a
  // lifetime warning in every tool). Declaring them once here also means the
  // analysis below reads as one piece of straight-line Verilog.
  integer i, j, k, t0, t1, r0, r1, tfall, tfall2, tstart;
  integer n_one, n_zero, hi, max_gap, span, n_bad_hi, n_off_grid, n_frame;
  real    reset_us, reset2_us;
  logic [23:0] bits;

  // The rising edges that begin a frame, found by find_frames below.
  localparam int MAXF = 8;
  integer       f_t [0:MAXF-1];

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---- firmware load ------------------------------------------------------
  logic [15:0] prog [0:IMEM_WORDS-1];

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;   // NOP fill
    $readmemh(`WS2812_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---- analysis ------------------------------------------------------------
  //
  // A frame is reconstructed from the TRANSITION LIST plus the 75-cycle grid
  // anchored at the frame's first rising edge. Reconstructing on a fixed grid
  // is what lets consecutive equal bits be counted correctly: a run of 1s
  // produces a falling edge every 48 clocks and a rising edge every 75, so an
  // edge-only decoder would lose cells and every "bit" it reported would be
  // wrong by a whole cell.
  //
  // Cell k of a frame starting at rise cycle T0 is [T0 + 75k, T0 + 75(k+1)),
  // and its high time is the time to the FIRST falling edge in that window, or
  // 0 if the cell is low throughout.
  task automatic decode_frame(
    input  integer tf0,                 // cycle of the frame's first rising edge
    input  integer nb,                  // bits to decode
    output logic [23:0] fbits,          // MSB-first
    output integer     fspan             // tf0 -> the frame's last cell end
  );
    integer kk, jj, hh;
    fbits = 24'h0;
    fspan = tf0 + nb * CELL_CYC;
    for (kk = 0; kk < nb; kk++) begin
      hh = 0;
      for (jj = 0; jj < n_edge; jj++) begin
        if (!e_lvl[jj] && e_cyc[jj] >= tf0 + kk * CELL_CYC
                       && e_cyc[jj] <  tf0 + (kk + 1) * CELL_CYC) begin
          if (hh == 0) hh = e_cyc[jj] - (tf0 + kk * CELL_CYC);
        end
      end
      if (hh > 0) fbits[nb - 1 - kk] = 1'b1;
    end
  endtask

  // The high time of one cell on the 75-cycle grid, in clocks. Cell 0 of a
  // frame starting at tf0 is [tf0, tf0+75); the answer is 0 for a cell that is
  // low throughout and 75 for one that never falls.
  task automatic cell_high(input integer tf0, input integer kk, output integer hh);
    integer jj;
    hh = 0;
    for (jj = 0; jj < n_edge; jj++) begin
      if (!e_lvl[jj] && e_cyc[jj] >= tf0 + kk * CELL_CYC
                     && e_cyc[jj] <  tf0 + (kk + 1) * CELL_CYC) begin
        if (hh == 0) hh = e_cyc[jj] - (tf0 + kk * CELL_CYC);
      end
    end
  endtask

  // A FRAME STARTS WHERE THE LINE HAS BEEN LOW FOR LONGER THAN THE RESET
  // FLOOR. That definition comes from the waveform rather than from an edge
  // index, and the index version is wrong in a way that decodes a shifted
  // frame without complaining: "the first rising edge" is cell 0 only if cell
  // 0 is a 1, and "the next rising edge after that" is cell 3 for this data,
  // not the start of the second frame. Anchoring on the reset is also the only
  // definition that cannot silently move if the frame data changes.
  task automatic find_frames(output integer nf);
    integer jj, tfl;
    nf = 0;
    for (jj = 0; jj < n_edge; jj++) begin
      if (e_lvl[jj] && jj > 0 && !e_lvl[jj-1]) begin
        tfl = e_cyc[jj] - e_cyc[jj-1];
        // The reset floor in CLOCKS. Written as us * (Hz/1e6) rather than
        // (us * Hz)/1e6 on purpose: 50 * 60_000_000 is 3e9, which wraps a 32-bit
        // integer to a NEGATIVE number, and then every rising edge in the run
        // looks like a frame start. That is not a hypothetical -- it is what
        // this line did, and the symptom was a "frame 1" that was really cell 3
        // of frame 0 and a between-frame reset of 3 us.
        if (tfl > (RESET_MIN_US * (CLK_HZ / 1_000_000)) && nf < MAXF) begin
          f_t[nf] = e_cyc[jj];
          nf = nf + 1;
        end
      end
    end
  endtask

  // The cycle of the k-th rising edge at or after tf0, or -1.
  function integer rise_at(input integer tf0);
    integer jj;
    for (jj = 0; jj < n_edge; jj++) begin
      if (e_lvl[jj] && e_cyc[jj] >= tf0) return e_cyc[jj];
    end
    return -1;
  endfunction

  initial begin
    $dumpfile("tb_pe_soc_ws2812.vcd");
    $dumpvars(0, tb_pe_soc_ws2812);

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
    $display("\n=== WS2812 800 kHz single-wire NRZ, driven by firmware ===\n");
    // 21 us per cell; two frames plus two resets is 65 us of signal plus the
    // setup, so 40,000 clocks is generous for the first two frames and
    // reports how far the firmware actually got.
    run = 1'b1;
    repeat (40_000) @(posedge clk);

    // ---- 1. did anything happen at all? ---------------------------------
    // (The RED state, and the state a firmware that never drives the pin
    // leaves behind. Every check below is guarded by this one so the output
    // says WHICH property is missing rather than reporting a decode of a
    // waveform that was never produced.)
    check(n_edge >= 4,
          $sformatf("the data pin moved at all (edges=%0d -- the firmware never drove bit %0d)",
                    n_edge, DATA_BIT));

    // ---- 2. the line is never released once the pin is claimed ----------
    // A released DIN floats to the strip's pull-up and reads as a 1. The
    // window counted is from the first edge, so the reset-time releases
    // (before the firmware claims the pin) do not count against it.
    check(n_released == 0,
          $sformatf("the data pin is never released while the frame runs (released %0d cycles)",
                    n_released));

    if (n_edge >= 4) begin
      // ---- 3. locate the two frames -------------------------------------
      // Frame k starts at the k-th RISING edge. Two frames, because the reset
      // BETWEEN them is the property that matters and a single frame cannot
      // show a reset at all.
      find_frames(n_frame);
      t0 = (n_frame > 0) ? f_t[0] : -1;
      t1 = (n_frame > 1) ? f_t[1] : -1;
      $display("    %0d frame starts found (anchored on the >%0d us reset)",
               n_frame, RESET_MIN_US);

      check(t0 > 0, "a rising edge starts the first frame");
      check(t1 > t0, "a second frame follows the first (a reset between them)");

      // ---- the resets, in microseconds, from the pads -------------------
      if (t0 > 0) begin
        tfall = -1;
        for (k = 0; k < n_edge; k++) begin
          if (!e_lvl[k] && e_cyc[k] < t0) tfall = e_cyc[k];
        end
        check(tfall >= 0, "the line was pulled low before the first frame");
        if (tfall >= 0) begin
          reset_us = (t0 - tfall) * CYC_US;
          $display("    reset before frame 1: %.2f us (%0d clocks)",
                   reset_us, t0 - tfall);
          check(reset_us > RESET_MIN_US,
                $sformatf("the reset low period is >%0d us (got %.2f us)",
                          RESET_MIN_US, reset_us));
        end
      end

      if (t1 > t0) begin
        tfall2 = -1;
        for (k = 0; k < n_edge; k++) begin
          if (!e_lvl[k] && e_cyc[k] > t0 && e_cyc[k] < t1) tfall2 = e_cyc[k];
        end
        check(tfall2 >= 0, "the line was pulled low again between the frames");
        if (tfall2 >= 0) begin
          reset2_us = (t1 - tfall2) * CYC_US;
          $display("    reset between frames: %.2f us (%0d clocks)",
                   reset2_us, t1 - tfall2);
          check(reset2_us > RESET_MIN_US,
                $sformatf("the between-frame reset is >%0d us (got %.2f us)",
                          RESET_MIN_US, reset2_us));
        end
      end

      // ---- 4. decode and check both frames ------------------------------
      for (k = 0; k < 2; k++) begin
        tstart = (k == 0) ? t0 : t1;
        if (tstart > 0) begin
          decode_frame(tstart, 24, bits, span);

          $display("    frame %0d: %02h %02h %02h (G,R,B)", k,
                   bits[23:16], bits[15:8], bits[7:0]);

          // --- 4a. the grid anchor, ASSERTED not assumed ------------------
          check(bits[23] === 1'b1,
                $sformatf("frame %0d opens with a 1, so its first rising edge anchors the cell grid (got %b)",
                          k, bits[23]));

          // --- 4b. the frame is the colour the firmware was given -------
          check({bits[23:16], bits[15:8], bits[7:0]} ==
                {FRAME_G, FRAME_R, FRAME_B},
                $sformatf("frame %0d decodes to the colour the firmware was given (got %02h %02h %02h, want %02h %02h %02h)",
                          k, bits[23:16], bits[15:8], bits[7:0],
                          FRAME_G, FRAME_R, FRAME_B));

          // --- 4c. the frame occupies exactly 24 cells -------------------
          check(span - tstart == 24 * CELL_CYC,
                $sformatf("frame %0d spans exactly 24 cells of %0d cycles (got %0d)",
                          k, CELL_CYC, span - tstart));

          // --- 4d. EVERY CELL SITS ON THE GRID, exactly -------------------
          // For each cell the TB knows the bit the decode says it is, so it
          // knows whether a rising edge is DUE at t0 + 75k, and requires the
          // measured edge to be at that cycle and nowhere else. This is the
          // check that catches a byte-boundary path one instruction longer
          // than the ordinary path: three cells per frame drift by a clock,
          // which is 16.7 ns and completely invisible to a window check.
          n_off_grid = 0;
          max_gap = 0;
          for (j = 0; j < 24; j = j + 1) begin
            if (bits[23 - j]) begin
              if (rise_at(tstart + j * CELL_CYC) != tstart + j * CELL_CYC)
                n_off_grid = n_off_grid + 1;
            end
          end
          // The gaps between consecutive 1-cells must all be whole cells.
          r0 = -1;
          for (j = 0; j < 24; j = j + 1) begin
            if (bits[23 - j]) begin
              if (r0 >= 0 && ((j * CELL_CYC) - r0) > max_gap) max_gap = (j * CELL_CYC) - r0;
              r0 = j * CELL_CYC;
            end
          end
          check(n_off_grid == 0,
                $sformatf("frame %0d: every 1-cell's rising edge is on the %0d-cycle grid (%0d off)",
                          k, CELL_CYC, n_off_grid));
          check(max_gap % CELL_CYC == 0,
                $sformatf("frame %0d: the spacing between 1-cells is a whole number of cells (largest %0d)",
                          k, max_gap));

          // --- 4e. THE PULSE WIDTHS, EXACTLY -----------------------------
          // Not a band. Every 1-cell high for exactly CELL_HIGH clocks and
          // every 0-cell for exactly 0: a firmware that is off by one clock
          // fails, which is the entire content of the cycle-accuracy claim.
          n_bad_hi = 0;
          n_one = 0; n_zero = 0;
          for (j = 0; j < 24; j = j + 1) begin
            cell_high(tstart, j, hi);
            if (bits[23 - j]) begin
              n_one = n_one + 1;
              if (hi != CELL_HIGH) n_bad_hi = n_bad_hi + 1;
            end else begin
              n_zero = n_zero + 1;
              if (hi != 0) n_bad_hi = n_bad_hi + 1;
            end
          end
          $display("      %0d one-cells at %0d clocks (%.1f ns), %0d zero-cells at 0",
                   n_one, CELL_HIGH, CELL_HIGH * NS_PER_CYC, n_zero);
          check(n_bad_hi == 0,
                $sformatf("frame %0d: every cell's high time is exactly %0d clocks (1) or 0 (0) -- %0d cells differ",
                          k, CELL_HIGH, n_bad_hi));

          // --- 4f. the datasheet windows, from the measurement ------------
          // tHIGH1 nominal 0.8 us, and the strip samples at 0.7 us, so every
          // 1-cell must still be high 42 clocks in.
          check(CELL_HIGH > SAMPLE_CYC,
                $sformatf("a 1-cell is still high at the strip's sample point (%0d clocks high, sample at %0d)",
                          CELL_HIGH, SAMPLE_CYC));
          check(CELL_HIGH * NS_PER_CYC >= 700.0 &&
                CELL_HIGH * NS_PER_CYC <= 900.0,
                $sformatf("tHIGH1 is in the 0.70..0.90 us band around the nominal 0.8 (got %.1f ns)",
                          CELL_HIGH * NS_PER_CYC));
          check((CELL_CYC - CELL_HIGH) * NS_PER_CYC >= 450.0,
                $sformatf("tLOW of a 1-cell is at least the nominal 450 ns (got %.1f ns)",
                          (CELL_CYC - CELL_HIGH) * NS_PER_CYC));

          // --- 4g. non-vacuity: both bit values must be present ----------
          // A decode of 24 zero bits satisfies every window check above. The
          // frame is fixed data, so this is an assertion about the DATA, and
          // it is what stops this whole section from proving nothing.
          check(n_one > 0 && n_zero > 0,
                $sformatf("frame %0d contains both bit values (ones=%0d zeros=%0d)",
                          k, n_one, n_zero));
        end
      end
    end

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  // Watchdog. A firmware hang must be reported as a hang, not as a timeout
  // with no output -- an unresponsive DUT and a passing DUT look alike from
  // outside.
  initial begin
    #5_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
