// tb_pe_soc_midi.v — a MIDI 1.0 receiver, at 31.25 kbaud, on real RTL, driven
// by firmware/midi_xfer.pe.
//
// WHAT THIS PROVES THAT A BAUD-RATE CHECK WOULD NOT
//
// The claim of firmware/midi_xfer.pe is two things, and they fail differently:
//
//   1. THE RATE. A 31.25 kbaud bit is 32 us and the shared tick is 4.3333 us,
//      so a half-bit is 7.38 ticks and cannot be expressed in them. The
//      program builds the bit cell from WHOLE INSTRUCTIONS instead. This TB
//      MEASURES the bit period on the pin and checks it, because an
//      unmeasured delay in a UART is the classic error that decodes anyway
//      and therefore survives review.
//
//   2. RUNNING STATUS. Six two-data-byte messages cost eighteen bytes if each
//      repeats its status byte and fourteen if it does not. The wire is
//      therefore AMBIGUOUS on its own: a receiver that ignores running status
//      decodes 0x21 0x41 as two meaningless bytes, and nothing on the wire
//      says which reading is right. Only a receiver that implements the rule
//      reconstructs the intended messages, so the receiver below IS the test.
//
// THE RULE THAT IS EASY TO GET WRONG, and what the expected event list is for:
//
//   A NEW STATUS BYTE REPLACES THE RUNNING STATUS. It does not merely add to
//   it. The firmware sends 0x90 (note-on) once and 0x80 (note-off) once, and
//   then relies on running status for the last four messages. A receiver that
//   kept 0x90 would decode messages 4-6 as note-ONS -- six messages, the right
//   notes and velocities, and the wrong directions on half of them. The
//   expected list below has them under 0x80, so that receiver fails.
//
// AND THE SAVING IS ASSERTED, NOT INFERRED. A firmware that repeated the
// status byte would still decode into the right six messages under a receiver
// that ignored running status, so the byte count is checked directly: exactly
// 2 status bytes and exactly 14 bytes on the wire, against 6 messages.
//
// Program: firmware/midi_xfer.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

module tb_pe_soc_midi;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD       = 115_200;          // the SoC's, NOT MIDI's
  localparam int CLK_HZ     = 60_000_000;
  localparam real CLK_NS   = 1e9 / CLK_HZ;

  // The MIDI rate. This is the whole point of the act: it is a 31.25 kbaud
  // UART on a SoC whose tick was sized for 115200.
  //
  // THE TOLERANCE IS 0.3%, NOT MIDI's 2%, and the reason is arithmetic rather
  // than caution. The transmitter is a counted-instruction divider on a known
  // 60 MHz clock, so the only bit periods it CAN produce near 32 us are the
  // ones on a 13-clock grid: 31.783 us (1907 clocks), 32.000 us (1920) and
  // 32.217 us (1933) -- 0.68% apart. A 2% window would admit all three and the
  // rate check would be decorative. A 0.3% window admits exactly one of them,
  // which is what makes the counted-delay-constant mutation in
  // regress/mutate_fwbus_tb.sh detectable: that mutation moves the loop count
  // by one and the cell by 0.68%, and 0.68% > 0.3% is the whole reason the
  // window is this narrow. Nothing here depends on the firmware's arithmetic:
  // the cell is measured from the pin (see MEASURED INSIDE EACH FRAME below)
  // and the window is a property of the wire.
  localparam real MIDI_BIT_NS  = 32_000.0;       // 1 / 31.25 kHz
  localparam real RATE_TOL     = 0.003;           // +/-0.3%, see above
  localparam int N_MSG = 6;
  localparam int N_WIRE_BYTES = 14;              // not 18: that is the point

  localparam int TX_BIT = 0;

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus = 8'hFF;
  wire tx_pin = pin_out_bus[TX_BIT];

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

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------- firmware load ----------------
  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;
  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh("../firmware/midi_xfer.hex", prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // =========================================================================
  // THE RECEIVER: a free-running oversampling 8N1 decoder.
  //
  // WHY THIS SHAPE. Four earlier versions of this testbench decoded the wire
  // with EDGES, and every one of them failed on a back-to-back 8N1 stream for
  // the same reason: IN A BACK-TO-BACK 8N1 STREAM A FALLING EDGE IS NOT A
  // START BIT AND A RISING EDGE IS NOT A STOP BIT. A data bit going 1->0 falls
  // exactly like a start bit, and one going 0->1 rises exactly like a stop bit.
  // The failures that produced that lesson are worth keeping, because each one
  // looked like a protocol defect rather than a receiver defect:
  //
  //   v1  @(negedge tx_pin) starts a decode: a data transition starts a decode
  //       mid-frame and it returned 0xa8 where 0x90 went out.
  //   v2  a `decoding` flag blocking 9.5 bit periods: it consumed the REAL
  //       start bit whenever a data edge woke it early, and missed ~2 frames
  //       in 3.
  //   v3  require >=1.5 bit periods of HIGH before a fall: for the data
  //       pattern 1,1,0 the preceding high run is two whole bits, which is
  //       indistinguishable from a stop bit.
  //   v4  anchor on the stop bit, measured: the rate check differenced
  //       consecutive POSEDGES, and data-bit rises were counted, so the
  //       measured frame period came out 5x short and 12 of 14 stop bits read
  //       low -- a phase-error detector wearing a rate check's clothes.
  //
  // THE THREE PROPERTIES THAT FIX ALL FOUR.
  //
  // (1) FREE-RUNNING. The sampler is a background process on its own
  //     timeline; it never waits for the decoder and the decoder never waits
  //     for it. A candidate frame that turns out to be a data transition
  //     therefore costs the search NOTHING: there is no timeline to abandon.
  //
  // (2) THE STOP BIT IS VERIFIED BEFORE A FRAME IS ACCEPTED. A data
  //     transition inside a frame produces a candidate whose stop sample reads
  //     LOW, and that candidate is discarded. This is the whole safety
  //     argument, and it is why the search can be allowed to latch onto any
  //     falling edge at all.
  //
  // (3) EVERY FRAME RE-ANCHORS ON AN EDGE, NEVER ON AN ACCUMULATED COUNT. The
  //     transmitter's rate error is -0.00% today, but a grid that accumulates
  //     walks out of its cell within eight bits at 1.85%, which is exactly
  //     what the first run of this testbench did.
  //
  // AND THE ONE PLACE AN EDGE MONITOR IS STILL USED, because it is not the
  // same thing as trusting edges: the falling-edge monitor below timestamps
  // transitions to the picosecond. It does not decide that any of them is a
  // start bit -- the stop-bit sample does that. Using it for TIMING and the
  // verified stop sample for DECIDING is the distinction the four failures
  // above were about; a receiver that takes both decisions from edges is v1.
  // =========================================================================
  localparam int OVERSAMPLE = 8;                 // strobes per bit
  real quarter = MIDI_BIT_NS / OVERSAMPLE;      // 4 us
  real bit_ns  = MIDI_BIT_NS;                   // refined from verified frames
  logic s_tick = 1'b0;                          // toggles: EVERY edge is a strobe

  // The strobe. Declared before the decoder, which reads it: Icarus binds
  // identifiers at elaboration and a forward reference from a task body is a
  // hard error rather than a warning.
  //
  // `#(quarter)` re-reads quarter on every iteration, so the refinement below
  // takes effect on the next strobe without restarting anything.
  initial forever #(quarter) s_tick = ~s_tick;

  // The exact time of the most recent falling edge. The search has already
  // decided (on a verified stop bit) that the transition it is looking at is
  // a start bit by the time this value is used, so this is a clock, not a
  // belief.
  realtime t_last_fall = -1.0;
  always @(negedge tx_pin) if (run && rst_n) t_last_fall = $realtime;

  localparam int S_SEARCH = 0, S_DATA = 1, S_STOP = 2;
  integer state = S_SEARCH;
  integer k     = 0;
  logic [7:0] b = 8'h00;
  realtime t_start = 0.0;          // the accepted start bit's leading edge
  realtime t_target = 0.0;         // the next sample point
  logic prev_level = 1'b1;
  logic cur_level  = 1'b1;

  integer n_framing_errors = 0;
  logic [7:0] wire_bytes [0:31];
  integer     n_wire = 0;
  logic [7:0] run_status = 8'h00;         // MIDI calls it "running status"
  logic [7:0] msg_status [0:7];
  logic [7:0] msg_d1     [0:7];
  logic [7:0] msg_d2     [0:7];
  integer     n_msg = 0;
  integer     n_status_bytes = 0;

  // THE EXACT EDGE LOG, and the rate measurement built on it.
  //
  // WHY NOT "DIFFERENCE CONSECUTIVE START BITS", which is the obvious
  // measurement and is WRONG here. Consecutive start bits are ten cells plus
  // the MESSAGE LAYER'S INTER-FRAME GAP, and that gap depends on which branch
  // the message layer takes -- sending a status byte costs more instructions
  // than running status does -- so the interval wobbles by a couple of clocks
  // from frame to frame. Measured that way this testbench reported 32.0437 us
  // for a transmitter that is putting 32.000 us on the wire: the 0.0437 is the
  // message layer, not the transmitter. A rate check built on it would be
  // measuring the wrong program.
  //
  // WHAT IS EXACT IS A PAIR OF EDGES INSIDE ONE FRAME, because the cells of a
  // single frame are all one length and nothing else comes between them. So
  // the measurement is: take the start bit's falling edge (the frame's
  // anchor), take the NEXT edge on the wire, count how many cells apart the
  // two are from the byte that was just decoded, and divide. The cell count
  // comes from the decoded byte, which the verified stop bit has already
  // vouched for and which the expected-byte checks below hold to a fixed
  // list, so the measurement is not circular: the bytes are known before the
  // rate is asked for.
  real    edge_t   [0:31];
  integer edge_w   = 0;
  always @(tx_pin) if (run && rst_n) begin
    edge_t[edge_w] = $realtime;
    edge_w = (edge_w == 31) ? 0 : edge_w + 1;
  end

  // The level a cell of an accepted frame is supposed to be on: cell 0 is the
  // start bit, cells 1..8 are the data bits LSB first, cell 9 is the stop.
  function automatic bit cell_level(input integer c, input [7:0] by);
    if (c == 0)      cell_level = 1'b0;
    else if (c == 9) cell_level = 1'b1;
    else             cell_level = by[c-1];
  endfunction

  // The first cell boundary at or after the anchor where the level changes,
  // and therefore how many cells the anchor and the next edge are apart.
  function automatic integer first_transition(input [7:0] by);
    integer c;
    first_transition = -1;
    for (c = 1; c <= 9; c = c + 1)
      if (cell_level(c, by) !== cell_level(c-1, by)) begin
        first_transition = c;
        c = 99;                       // leave the loop; Icarus wants no break
      end
  endfunction

  // The per-frame cell time, measured as above, and the per-frame period for
  // the drift check. n_meas counts frames that yielded a usable measurement.
  real    cell_meas [0:15];
  real    t_prev_start = -1.0;
  integer n_meas = 0;

  // The six messages the firmware is supposed to produce. NOTE THE DIRECTION
  // FLIP at message 3: messages 0-2 are 0x90 note-on, 3-5 are 0x80 note-off.
  //
  // PACKED VECTORS, NOT UNPACKED ARRAYS, and that is Icarus talking: it rejects
  // an unpacked array localparam outright ("unpacked array parameters are not
  // supported yet"), which is the same wall tb_pe_soc_spi.v documented when it
  // hit it. Index k lives at [8*k +: 8], and a concatenation is MSB-FIRST, so
  // the LAST literal is message 0 -- which is the opposite end from where a
  // reading of the source would put it, and is worth stating rather than
  // leaving to be discovered.
  localparam logic [8*N_MSG-1:0] EXP_STATUS =
      {8'h80, 8'h80, 8'h80, 8'h90, 8'h90, 8'h90};
  localparam logic [8*N_MSG-1:0] EXP_D1 =
      {8'h25, 8'h24, 8'h23, 8'h22, 8'h21, 8'h20};
  localparam logic [8*N_MSG-1:0] EXP_D2 =
      {8'h45, 8'h44, 8'h43, 8'h42, 8'h41, 8'h40};

  // The MIDI layer, ABOVE the byte decoder -- and this is the receiver that
  // makes the act's claim checkable:
  //
  //   byte >= 0x80  -> a status byte; it REPLACES the running status
  //   byte <  0x80  -> data, under whatever status is currently running
  //   two data bytes -> one message, emitted against the running status
  //
  // Kept as its own task so the two layers can be read -- and mutated --
  // independently. A receiver that did not implement the rule would produce
  // different MESSAGES, not merely a different byte count, and that is what
  // the expected event list is for.
  logic [7:0] pending_d1 = 8'h00;
  logic       have_d1 = 1'b0;

  task automatic on_byte(input [7:0] by);
    if (by[7]) begin
      // A status byte: it becomes the running status for everything after it,
      // REPLACING whatever was running. Counting it here is what makes the
      // "2 status bytes for 6 messages" claim measurable from the wire.
      run_status = by;
      n_status_bytes = n_status_bytes + 1;
      have_d1 = 1'b0;               // a status byte abandons a half message
    end else if (!have_d1) begin
      pending_d1 = by;
      have_d1 = 1'b1;
    end else begin
      if (n_msg < 8) begin
        msg_status[n_msg] = run_status;
        msg_d1[n_msg]     = pending_d1;
        msg_d2[n_msg]     = by;
        n_msg = n_msg + 1;
      end
      pending_d1 = 8'h00;
      have_d1 = 1'b0;
    end
  endtask

  // The decoder. One process, clocked by the strobe, so every strobe is
  // serviced exactly once and the search never loses time.
  always @(s_tick) begin : receiver
    realtime t_now;
    t_now     = $realtime;
    cur_level = tx_pin;
    if (run && rst_n) begin
      case (state)
        // ---- search: any high->low transition is a CANDIDATE start bit ----
        S_SEARCH: begin
          if (prev_level && !cur_level) begin
            t_start  = t_last_fall;
            t_target = t_start + 1.5 * bit_ns;   // data bit 0's CENTRE
            k        = 0;
            b        = 8'h00;
            state    = S_DATA;
          end
        end

        // ---- eight data bits, one bit period apart ----
        //
        // THE SAMPLE POINT IS THE STROBE NEAREST THE TARGET, not the first
        // strobe at or after it. `t_now + quarter/2 >= t_target` is that test,
        // and it bounds the sampling error at half a strobe (2 us = 6% of a
        // cell) instead of a whole one. Every target then falls 8 strobes
        // later, so the comparison cannot fire twice for one target.
        S_DATA: if (t_now + quarter * 0.5 >= t_target) begin
          b[k] = tx_pin;
          k        = k + 1;
          t_target = t_target + bit_ns;
          if (k == 8) state = S_STOP;
        end

        // ---- the stop bit: THE VERIFICATION ----
        S_STOP: if (t_now + quarter * 0.5 >= t_target) begin
          if (tx_pin) begin
            // accepted. Measure the cell time from this frame's own edges,
            // and refine the strobe period from the same number so the next
            // frame is sampled on the wire's grid rather than on the nominal.
            if (n_wire < 32) begin
              wire_bytes[n_wire] = b;
              n_wire = n_wire + 1;
            end
            on_byte(b);
            if (n_meas < 16) begin
              integer k1, e;
              real t1, span;
              k1 = first_transition(b);
              t1 = -1.0;
              for (e = 0; e < 32; e = e + 1)
                if (edge_t[e] > t_start && (t1 < 0.0 || edge_t[e] < t1)) t1 = edge_t[e];
              if (k1 > 0 && t1 > 0.0) begin
                span = (t1 - t_start) / k1;
                cell_meas[n_meas] = span;
                bit_ns  = span;
                quarter = span / OVERSAMPLE;
                n_meas  = n_meas + 1;
              end
            end
            t_prev_start = t_start;
            $display("    wire byte %0d = %02h  (running status now %02h)",
                     n_wire, b, run_status);
          end else begin
            // A framing error is DISCARDED, not repaired: the candidate was
            // a data transition, the line was sampled back at the search, and
            // the timeline was never committed to anything.
            n_framing_errors = n_framing_errors + 1;
          end
          state = S_SEARCH;
        end
      endcase
    end
    prev_level = cur_level;
  end

  // =========================================================================
  // Stimulus
  // =========================================================================
  task automatic reset_and_load;
    run = 1'b0; rst_n = 1'b0;
    repeat (4) @(posedge clk); #1;
    n_wire = 0; n_msg = 0; n_status_bytes = 0; n_meas = 0;
    n_framing_errors = 0;
    run_status = 8'h00; pending_d1 = 8'h00; have_d1 = 1'b0;
    state = S_SEARCH; k = 0; b = 8'h00; prev_level = 1'b1;
    t_prev_start = -1.0; t_last_fall = -1.0;
    bit_ns = MIDI_BIT_NS; quarter = MIDI_BIT_NS / OVERSAMPLE;
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    load_firmware();
    // The four-clock gap before `run` rises is required: the SRAM macro's read
    // output is registered, so releasing the CPU in the same instant as the
    // loader's last write makes it decode a stale word as pc=0.
    repeat (4) @(posedge clk); #1;
    run = 1'b1;
  endtask

  initial begin
    $dumpfile("tb_pe_soc_midi.vcd");
    $dumpvars(0, tb_pe_soc_midi);

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;

    $display("\n=== MIDI 31.25 kbaud 8N1, running status, on a 115200 tick ===");
    reset_and_load();

    // Drain the frames. The firmware loops for ever, so the test's own clock
    // decides when to stop -- and the window is DERIVED FROM THE RATE, which
    // is the discipline this testbench learned the hard way. Fourteen 8N1
    // bytes at 31.25 kbaud is 14 x 10 x 32 us = 4480 us; a 25% margin gives
    // 5600 us. The first version of this receiver allowed 900 us -- five
    // times too little -- so the run stopped after two and a half messages
    // and every check below failed on a truncated stream that looked exactly
    // like a protocol defect. A cap that is not derived from the rate is a
    // cap that will be wrong.
    #(N_WIRE_BYTES * 10 * MIDI_BIT_NS * 1.25);
    // Settle past the last stop bit and the final park.
    repeat (4000) @(posedge clk);

    // ---- 1. the bytes, and the SAVING running status makes ------------
    check(n_framing_errors == 0,
          $sformatf("every frame's stop bit read high (%0d did not)",
                    n_framing_errors));
    check(n_wire == N_WIRE_BYTES,
          $sformatf("exactly %0d bytes on the wire (got %0d)", N_WIRE_BYTES, n_wire));
    check(n_status_bytes == 2,
          $sformatf("exactly 2 status bytes for %0d messages (got %0d)",
                    N_MSG, n_status_bytes));
    // The negative form of the same claim, spelled out: 18 bytes would be a
    // firmware that repeated the status and still decoded the same messages
    // under a receiver that ignored running status.
    check(n_wire < N_MSG * 3,
          $sformatf("the stream is shorter than %0d bytes, so running status is in use (%0d)",
                    N_MSG * 3, n_wire));

    // ---- 2. the messages, as a running-status receiver reconstructs them
    check(n_msg == N_MSG,
          $sformatf("the receiver reconstructed %0d messages (got %0d)",
                    N_MSG, n_msg));
    for (int j = 0; j < N_MSG; j++) begin
      if (j < n_msg) begin
        check(msg_status[j] == EXP_STATUS[8*j +: 8],
              $sformatf("message %0d: status %02h, expected %02h (a new status byte must REPLACE the running one)",
                        j, msg_status[j], EXP_STATUS[8*j +: 8]));
        check(msg_d1[j] == EXP_D1[8*j +: 8],
              $sformatf("message %0d: first data byte %02h, expected %02h",
                        j, msg_d1[j], EXP_D1[8*j +: 8]));
        check(msg_d2[j] == EXP_D2[8*j +: 8],
              $sformatf("message %0d: second data byte %02h, expected %02h",
                        j, msg_d2[j], EXP_D2[8*j +: 8]));
      end
    end

    // ---- 3. the RATE, measured INSIDE each frame on the pin -----------
    // This is the check the act exists for. Every frame's measurement is
    // checked, not just the mean, so a transmitter whose cells SLOW across
    // the stream cannot hide inside an average.
    if (n_meas >= 1) begin
      real cmin, cmax, csum;
      cmin = cell_meas[0];
      cmax = cell_meas[0];
      csum = 0.0;
      for (int j = 0; j < n_meas; j++) begin
        if (cell_meas[j] < cmin) cmin = cell_meas[j];
        if (cell_meas[j] > cmax) cmax = cell_meas[j];
        csum = csum + cell_meas[j];
      end
      $display("    measured over %0d frames: cell %.4f us (%.0f baud), spread %.4f us -- nominal 31250",
               n_meas, (csum / n_meas) / 1000.0, 1.0e9 / (csum / n_meas),
               (cmax - cmin) / 1000.0);
      for (int j = 0; j < n_meas; j++) begin
        check(cell_meas[j] > MIDI_BIT_NS * (1.0 - RATE_TOL) &&
              cell_meas[j] < MIDI_BIT_NS * (1.0 + RATE_TOL),
              $sformatf("frame %0d: cell %.4f us is outside 32.000 us +/- %.1f%%",
                        j + 1, cell_meas[j] / 1000.0, RATE_TOL * 100.0));
      end
      // EVERY CELL IS THE SAME LENGTH, and this is a separate check from the
      // window above because it catches a different defect. The window is
      // +/-0.3% and the delay loop's quantisation is 0.68%, so the window sees
      // a change in the LOOP COUNT and is blind to a change of one or two
      // clocks in a single cell's PADDING. The spread does see it: with three
      // NOPs in sb_start, adding a fourth makes the start cell one clock
      // longer than the rest, every measurement that starts there moves, and
      // the measurements stop agreeing. One picosecond of spread is the
      // assertion, and the clean firmware measures exactly zero -- the
      // transmitter is a pure divider, so there is nothing to be inexact about.
      check((cmax - cmin) < 0.001,
            $sformatf("every cell is the same length (the measurements span %.4f us)",
                      (cmax - cmin) / 1000.0));
    end else begin
      check(1'b0, $sformatf("enough measured frames to check a rate (%0d)", n_meas));
    end

    // ---- 4. the firmware's own record ----------------------------------
    check(dut.dmem[4] == N_WIRE_BYTES,
          $sformatf("the firmware counted %0d bytes (got %0d)",
                    N_WIRE_BYTES, dut.dmem[4]));
    check(dut.dmem[5] == 2,
          $sformatf("the firmware counted 2 status bytes (got %0d)", dut.dmem[5]));
    check(dut.dmem[11] == 8'hA5,
          $sformatf("the firmware finished (got %02h)", dut.dmem[11]));
    $display("    dmem: bytes=%0d status_bytes=%0d finished=%02h",
             dut.dmem[4], dut.dmem[5], dut.dmem[11]);

    $display("");
    if (errors == 0) $display("PASS: tb_pe_soc_midi");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: watchdog -- the test did not complete");
    $display("  pc=%0d bytes=%0d", dbg_pc, n_wire);
    $finish;
  end

endmodule
