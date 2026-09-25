// tb_pe_soc_spi.v — SPI mode 0 as firmware, end to end on real RTL.
//
// WHY THIS EXISTS. `firmware/spi_xfer.pe` is a mode-0 master with no SPI
// hardware behind it, and until now its ONLY executable specification was
// `tools/fw/peemu.py`. That is a model written from the same understanding as the
// firmware, so it can agree with the firmware about a wrong bit order and pass.
// SPI is one of the blog's three baseline protocols; it should not ship on a
// model's word.
//
// THE TB IS THE SLAVE, and that is the load-bearing decision. A master with no
// slave is not a protocol, it is a pin toggling. Modelling a real mode-0 slave
// here is what makes the master's edge choices checkable:
//
//   CS_N falls  -> selected; present bit 7 of the response on MISO
//   SCLK rises  -> the slave SAMPLES MOSI (the master must have it valid first)
//   SCLK falls  -> the slave shifts and presents the next MISO bit
//   CS_N rises  -> frame over
//
// MISO changes ONLY on the falling edge. That is what makes the firmware's
// sample-immediately-after-the-rise safe with no delay at all, and it is the
// property this TB would catch if the firmware ever drove MOSI on the wrong
// edge or sampled before the rise.
//
// WHAT IS ASSERTED (see the checks at the end):
//   1. the MOSI bit sequence the SLAVE CAPTURED is the byte the firmware meant
//      to send, MSB first — decoded from the pins, not from dmem
//   2. the byte the firmware RECEIVED is the byte the slave sent
//   3. CS_N frames every transfer: low for exactly 8 SCLK rises, high between
//   4. SCLK idles LOW before the first frame (the reset value is HIGH, which is
//      an active-edge level for SPI, so the firmware must state its own idle
//      pattern — this TB fails if that line is ever removed)
//   5. the rolling receive buffer holds the frames IN ORDER
//   6. SCLK period is inside the window the shared 260-clock tick implies
//
// A BIT-PALINDROME WOULD MAKE CHECK 1 VACUOUS. 0x5A reversed is 0x5A, so a
// master that shifted LSB-first would put identical levels on MOSI and this TB
// could not tell. The firmware sends 0x5B (reverses to 0xDA) and the slave
// answers A7 E5 96 C1 (each reverses to something different) for exactly that
// reason — see the note in firmware/spi_xfer.pe and regress/run_firmware_tests.sh.
//
// Program: firmware/spi_xfer.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

module tb_pe_soc_spi;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;

  // The TB's own copy of the clock rate. CLK_HZ is a localparam inside
  // pe_soc (see the header there); this is a TEST FACT about the board,
  // checked against the RTL by reference/clock-arithmetic.md.
  localparam int CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;

  // The SPI pin map, from firmware/spi_xfer.pe:
  //   bit 0 out SCLK   bit 1 out MOSI   bit 2 out CS_N   bit 3 in MISO
  localparam int SCLK_BIT = 0;
  localparam int MOSI_BIT = 1;
  localparam int CS_BIT   = 2;
  localparam int MISO_BIT = 3;

  // What the firmware transmits. 0x5B reverses to 0xDA, so it is not a
  // palindrome and the bit order is visible on the pins.
  localparam logic [7:0] TX_BYTE = 8'h5B;

  // What the slave answers, one byte per frame, and WHY EIGHT DISTINCT BYTES:
  //
  //   * the firmware's receive buffer is EIGHT entries deep (peasm wraps the
  //     write pointer with `AND A, 0x07`) and it loops forever, so the buffer
  //     always holds a ROLLING window of the last 8 frames. Answering with 4
  //     bytes made the expected contents ambiguous -- frame 8's buffer holds
  //     frames 1-8, not frames 1-4 -- and the first version of this check
  //     compared against the wrong window. Eight distinct bytes means every
  //     frame's byte is different, so a misaligned window cannot look correct.
  //   * every byte here reverses to a DIFFERENT byte (A7->E5, E5->A7, 96->69,
  //     C1->83, 3D->BC, 7B->DE, D2->4B, 4F->F2), so an LSB-first master puts a
  //     visibly different pattern on MOSI. A palindromic byte would make the
  //     bit-order check vacuous.
  //   * E5 is the reverse of A7 on purpose: a slave whose MISO bit index is off
  //     by one position cannot accidentally produce the right sequence.
  localparam int N_FRAMES = 8;
  // Icarus supports neither unpacked array parameters nor `'{...}` assignment
  // to them ("sorry: unpacked array parameters are not supported yet"), so the
  // response sequence is one packed vector indexed a byte at a time.
  localparam logic [8*N_FRAMES-1:0] RX_SEQ =
      {8'h4F, 8'hD2, 8'h7B, 8'h3D, 8'hC1, 8'h96, 8'hE5, 8'hA7};

  // The shared tick, from rtl/pe_soc.v: TICKS_PER_BIT = CLK_HZ/BAUD/2
  // = 260 clocks = 4.333 us. The firmware waits "(0,1] ticks" for a half
  // period, so a half period lands in roughly (0, 2] ticks -- measured, not
  // assumed: see the assertion below.
  localparam int TICK_CLKS = 260;
  localparam real TICK_NS = 1e9 * TICK_CLKS / CLK_HZ;

  logic clk = 0, rst_n;

  // host interface
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  // ---- the bus ------------------------------------------------------------
  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  wire sclk = pin_out_bus[SCLK_BIT];
  wire mosi = pin_out_bus[MOSI_BIT];
  wire cs_n = pin_out_bus[CS_BIT];

  // ---- the slave ----------------------------------------------------------
  // A real mode-0 slave. MISO is combinational off the bit index so it is
  // stable the whole time SCLK is high, which is what lets the master sample
  // with no delay after the rise.
  logic [7:0] slave_tx;          // the byte this frame is shifting out
  logic [7:0] slave_rx;          // what MOSI was, assembled MSB-first
  logic [3:0] slave_bit;         // 0..7 within the frame
  logic       slave_active;
  integer     frame;             // frames completed

  wire miso = slave_active ? slave_tx[7 - slave_bit[2:0]] : 1'b1;
  // Idle-high when deselected, standing in for a pull-up. The firmware samples
  // MISO only after a rising edge inside a frame, so this level is never read;
  // it is high rather than low because a deselected slave driving low would
  // look like a start-of-frame glitch on a shared bus.

  assign pin_in_bus = {4'b0, miso, 3'b0};    // MISO on bit 3, same as UART RX

  logic [9:0] dbg_pc;   // R2: full PC width (pe_soc exposes PCW bits)
  logic [7:0] dbg_a, dbg_timer;

  pe_soc #(
    .IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES), .BAUD(BAUD)
  ) dut (
    .dbg_hold(1'b0), .dbg_step(1'b0),  // R3: debug control idle here
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata), .run(run),
    // R2: the host read port is idle in this TB (tied low, not floating:
    // an undriven input would make the address mux X and break the CPU read).
    .dbg_rd_req(1'b0), .dbg_rd_dmem(1'b0), .dbg_rd_addr(16'h0000),
    .dbg_rd_data(), .dbg_rd_valid(),
    .pin_in(pin_in_bus), .pin_out(pin_out_bus), .pin_oe(pin_oe_bus),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_timer(dbg_timer)
  );

  always #(CLK_NS/2) clk = ~clk;

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------- firmware load ----------------
  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;   // NOP fill
    $readmemh("../firmware/spi_xfer.hex", prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---------------- slave behaviour ----------------
  // Edge-driven, exactly as the mode-0 contract says.
  //
  // SPLIT ACROSS THE TWO EDGES, AND THE SPLIT IS THE WHOLE POINT. MOSI is
  // captured on the RISING edge (when the slave samples it) but the response's
  // bit index advances on the FALLING edge (when the slave is allowed to change
  // MISO). Doing both on the rise is a RACE: the master samples MISO on the
  // same edge, sees the already-advanced value, and the frame comes back
  // shifted. That is not hypothetical -- the first version of this slave
  // advanced on the rise and the master received 00 for every frame, because
  // bit 7 of the response was skipped before it was ever read.
  //
  // This is also why a real slave may change MISO only on the fall, and why the
  // master's sample-immediately-after-the-rise needs no delay at all.
  integer n_mosi_captured = 0;

  always @(posedge sclk) if (run && rst_n && slave_active && slave_bit < 4'd8) begin
    slave_rx = {slave_rx[6:0], mosi};
    n_mosi_captured = n_mosi_captured + 1;
  end

  always @(negedge sclk) if (run && rst_n && slave_active)
    // Guard with the same bound the capture uses: bit 8 would index
    // slave_tx[-1] and read x, which would then be reported as a wrong byte
    // rather than as an over-clocked frame.
    if (slave_bit < 4'd8) slave_bit = slave_bit + 1'b1;

  always @(negedge cs_n) if (run && rst_n) begin
    slave_active = 1'b1;
    slave_bit = 4'd0;
    slave_rx = 8'h00;
    // Byte `frame` of the packed sequence: the frames answer A7, E5, 96, C1
    // in order. Bit-select on a packed vector, because an unpacked array
    // parameter does not elaborate under Icarus.
    slave_tx = (frame < N_FRAMES)
               ? RX_SEQ[8*(frame+1)-1 -: 8] : 8'h00;
    $display("    CS_N low  -> frame %0d begins, slave will answer %02h",
             frame, slave_tx);
  end

  always @(posedge cs_n) if (run && rst_n && slave_active) begin
    slave_active = 1'b0;
    $display("    CS_N high -> frame %0d done: slave received %02h (%0d clocks)",
             frame, slave_rx, slave_bit);
    check(slave_bit == 4'd8,
          $sformatf("frame %0d had exactly 8 SCLK rises (got %0d)", frame, slave_bit));
    check(slave_rx === TX_BYTE,
          $sformatf("frame %0d: slave captured %02h on MOSI, firmware meant %02h",
                    frame, slave_rx, TX_BYTE));
    // Stop counting at N_FRAMES. The firmware loops forever, so without this
    // bound `frame` keeps climbing past the number of bytes in RX_SEQ and the
    // buffer check's expected contents would drift. The counter is the test's
    // clock, not the firmware's, and the test is over after N_FRAMES.
    if (frame < N_FRAMES) frame = frame + 1;
  end

  // ---------------- monitors ----------------
  // SCLK idle level, sampled before the first frame. The reset value of the
  // output register is bit 0 HIGH, which for SPI is an ACTIVE edge level, not
  // an idle one -- so this checks that the firmware states its own idle pattern
  // rather than inheriting the resident protocol's.
  logic sclk_before_frame = 1'b1;
  time  t_first_cs_fall;
  always @(posedge clk) if (run && rst_n && frame == 0 && !slave_active) begin
    sclk_before_frame <= sclk;
  end
  always @(negedge cs_n) if (t_first_cs_fall == 0) t_first_cs_fall = $time;

  // SCLK edges, for the period measurement.
  time  t_rise [0:63];
  time  t_fall [0:63];
  integer n_rise = 0, n_fall = 0;

  always @(posedge sclk) if (run && rst_n) begin
    if (n_rise < 64) t_rise[n_rise] = $time;
    n_rise = n_rise + 1;
  end
  always @(negedge sclk) if (run && rst_n) begin
    if (n_fall < 64) t_fall[n_fall] = $time;
    n_fall = n_fall + 1;
  end

  // ---------------- debugging trace ----------------
  // OFF BY DEFAULT, and worth explaining rather than just gating: the failure
  // this whole TB was written to catch is a silent one. Every trace below was
  // added while chasing a REAL bug -- the master stored 0xFF as its first byte
  // and the buffer looked one frame late -- and the three traces that mattered
  // are kept because that bug is not diagnosable from the summary checks alone.
  // They cost nothing when off.
  //
  // Run with `vvp ... +trace` to see them.
  //
  // The three, and what each one answered:
  //
  //   [ev]  one INTERLEAVED timeline of SCLK/CS_N/PC events. Reading three
  //         separate logs side by side is how the wrong conclusion gets drawn:
  //         the PC trace said the firmware reached its first OUT at 17 us while
  //         the CS_N trace said the first frame edge was at 52 us, and only an
  //         interleaved view shows they describe different runs of the program.
  //
  //   [w]   the write path, SAMPLED ONE TIME STEP AFTER THE EDGE. Printing at
  //         posedge clk showed `OUT` executing with a=0x00 instead of 0x04 and
  //         looked like a CPU bug; imem_rdata (the ROM's registered output) and
  //         pc both update AT that edge, so a racing $display sees a mixture of
  //         old and new state. Two contradictory readings in one line. The #1
  //         delay makes each line a consistent snapshot.
  //
  //   [cs]  the CS_N level at the moment `run` rises. At reset the SoC DRIVES
  //         this pin low, so a slave that arms on a FALLING edge never sees one
  //         -- the value is 0 here, and a model that assumed an edge would
  //         silently never arm.
  bit trace_on = 0;
  initial trace_on = $test$plusargs("trace");

  task automatic ev(input string what);
    if (trace_on) $display("      [ev] %0d ns  %-6s pc=%0d cs_n=%b sclk=%b act=%b",
                           $time, what, dbg_pc, cs_n, sclk, slave_active);
  endtask

  always @(posedge sclk) if (trace_on && run && rst_n) ev("SCLK^");
  always @(negedge sclk) if (trace_on && run && rst_n) ev("SCLKv");
  always @(cs_n)         if (trace_on && run && rst_n) ev("CS");

  always @(posedge clk) if (trace_on && run && rst_n) begin
    #1;
    $display("      [w] t=%0d pc=%0d insn=%04h a=%02h we=%b port=%h wdata=%02h | out=%02h oe=%02h | bus=%02h",
             $time, dbg_pc, dut.u_cpu.insn, dut.u_cpu.a, dut.io_we, dut.io_port,
             dut.io_wdata, dut.u_pinmux.reg_out, dut.u_pinmux.reg_oe, pin_out_bus);
  end

  initial begin
    wait (run === 1'b1);
    @(posedge clk);
    if (trace_on)
      $display("      [cs] at run rise: cs_n=%b (0 = a slave arming on a falling edge never sees one)",
               cs_n);
  end

  // ---------------- stimulus ----------------
  initial begin
    // VCD is OPT-IN. It was unconditional, which meant every regression run paid
    // for a multi-megabyte dump nobody read -- and it also made this TB
    // unmeasurable against Verilator, which ignores $dumpvars unless it is built
    // with --trace. Gating it keeps the two simulators comparable and stops
    // run_all.sh writing files it never looks at. Run with `+dump` to get one.
    if ($test$plusargs("dump")) begin
      $dumpfile("tb_pe_soc_spi.vcd");
      $dumpvars(0, tb_pe_soc_spi);
    end

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    slave_active = 1'b0; slave_bit = 4'd0; slave_rx = 8'h00;
    slave_tx = 8'h00; frame = 0;
    t_first_cs_fall = 0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_firmware();

    // THE ROM MUST BE ALLOWED TO LOAD imem[0] BEFORE THE CPU IS RELEASED, and
    // the reason is not obvious from either module alone.
    //
    // While the loader owns the bus, host_we is high and pe_imem drives the
    // macro's read-enable LOW (`assign re = ~host_we`), so the macro's A_DOUT
    // is NOT tracking the address -- it is frozen. Dropping host_we starts the
    // read, but a registered output needs one more edge before A_DOUT holds
    // imem[0]. Releasing the CPU in the same instant skips that edge: the CPU
    // decodes a STALE instruction as pc=0, so the first real instruction at
    // imem[0] is never executed and the PC lands on imem[1] with the reset
    // value still in A.
    //
    // The symptom was misleading in two directions at once. The pins showed the
    // firmware's INIT write landing as 0x00 instead of 0x04 (CS_N never went
    // high, so the SPI slave was never selected and clocked MISO idle-high =
    // 0xFF as the first received byte), which reads like a CPU bug. And the
    // slave still counted its eight frames, because the frame the master clocked
    // into an unselected slave was invisible from the slave's side -- so the
    // summary checks blamed a one-frame lag that did not exist. Sampling the
    // trace at posedge clk showed pc already at 1 while wdata still held the
    // previous instruction, another half-updated reading.
    //
    // tb_pe_soc_uart has the same four-clock gap (`repeat (4) @(posedge clk)`
    // before `run = 1'b1`) and the comment there does not say why. It is
    // required, and the reason is above.
    repeat (4) @(posedge clk); #1;

    $display("\n=== SPI mode 0 master on the shared port (no SPI hardware) ===\n");
    run = 1'b1;

    // The firmware loops forever (main -> 4 frames is the test's business, not
    // the program's), so run a bounded window that comfortably covers 4 frames
    // and then stop.
    //
    // Run until frame N_FRAMES completes, rather than for a fixed wall time.
    //
    // This is what makes the buffer check below deterministic. The firmware
    // loops forever, so a fixed window stops it wherever it lands and the
    // buffer holds an arbitrary rolling window. Waiting for the LAST frame the
    // slave needs instead means the buffer provably holds exactly frames 1-8,
    // in order, with frame 8 in slot 7. (The slave stops incrementing `frame`
    // at N_FRAMES for the same reason -- see the guard in the CS_N monitor.)
    //
    // Budget, measured rather than guessed: a frame is ~35 us (8 bits x 2 half
    // periods at ~4.3 us, plus framing), so 8 frames is ~280 us. The cap is
    // generous; the `frame` condition is what normally ends the wait.
    begin : run_window
      integer waited = 0;
      while (frame < N_FRAMES && waited < 400 * 60) begin
        @(posedge clk);
        waited = waited + 1;
      end
      $display("    ran %0d us waiting for %0d frames", waited / 60, N_FRAMES);
    end

    // THE FIRMWARE STORES THE BYTE *AFTER* IT RAISES CS_N, so stopping the
    // window at the frame edge reads the buffer one byte short. The store is
    // the sequence `LDM A,14 / MOV X,A / LDM A,15 / STS [X],A`, several
    // instructions past the CS_N rise that ended the frame -- so the last
    // frame's byte is genuinely not in dmem yet at that instant.
    //
    // A frame is ~35 us and this drains ~10 instructions, so 1 us is ample.
    // Waiting on the write pointer would be tighter but couples the test to the
    // firmware's internal register allocation; a bounded drain is honest about
    // being a settle time.
    repeat (60) @(posedge clk);   // 1 us

    $display("\n  frames completed: %0d", frame);
    // The write pointer is the DISCRIMINATOR. Two failure shapes fit the
    // observed buffer -- a master that receives one frame late (pointer
    // ends at 0 after 8 frames) and a master whose pointer started at 1
    // (pointer ends at 1). The bytes alone cannot tell them apart, so the
    // pointer is printed rather than inferred.
    $display("    dmem: ptr=%0d last=%02h slots %02h %02h %02h %02h %02h %02h %02h %02h",
             dut.dmem[14], dut.dmem[15], dut.dmem[0], dut.dmem[1], dut.dmem[2],
             dut.dmem[3], dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7]);

    // ---- 1. every frame's MOSI sequence, decoded from the pins -----------
    check(frame >= N_FRAMES,
          $sformatf("at least %0d frames completed (got %0d)", N_FRAMES, frame));

    // ---- 2. the byte the firmware received, from dmem -------------------
    // dmem[15] holds the last byte received; dmem[0..3] are the rolling buffer.
    // The slave sent A7 E5 96 C1, so the buffer must hold them IN ORDER -- a
    // master with a broken write pointer would overwrite slot 0, which is
    // exactly the bug the emulator's --expect-buffer check caught for the UART.
    for (int k = 0; k < N_FRAMES; k++) begin
      check(dut.dmem[k] === RX_SEQ[8*(k+1)-1 -: 8],
            $sformatf("buffer[%0d] = %02h, slave sent %02h",
                      k, dut.dmem[k], RX_SEQ[8*(k+1)-1 -: 8]));
    end
    // dmem[15] IS NOT CHECKED HERE, deliberately: it is the receive ACCUMULATOR,
    // which the firmware clears to 0 at the start of every frame, so after the
    // last frame it holds 0 by construction and says nothing about what was
    // received. The eight buffer slots above are the durable record, and they
    // are checked byte for byte. (The first version of this TB asserted
    // dmem[15] against the last response byte and failed -- with the RTL and
    // tools/fw/peemu.py agreeing perfectly on dmem, which is what identified the
    // ASSERTION as the wrong thing rather than the design.)

    // ---- 3. SCLK idles LOW ----------------------------------------------
    check(sclk_before_frame === 1'b0,
          $sformatf("SCLK idles LOW before the first frame (saw %b)", sclk_before_frame));
    // NOT asserted: the SCLK/CS_N level at the END of the run. The firmware
    // loops forever by design (four frames is the TEST's business, not the
    // program's), so the window stops it wherever it happens to be -- possibly
    // mid-frame. Asserting the final level would test where the run stopped,
    // not the protocol. Framing is instead asserted per frame: the CS_N falling
    // and rising monitors above require exactly 8 SCLK rises inside every
    // frame, which is the real property.

    // ---- 4. the clock period, inside the window the tick implies ---------
    // This is what ties the firmware's chosen tick to the pin behaviour: 260
    // clocks is 4.333 us, and the firmware's wait returns after (0,1] ticks, so
    // a half period is between about 0 and 2 ticks.
    //
    // PAIR A RISE WITH THE *NEXT* FALL, not with t_fall[0]. The first SCLK
    // event of the whole run is a FALL, because reset drives the output
    // register's bit 0 HIGH (the UART's idle TX level) and the firmware's
    // first act is to pull it LOW for the SPI idle state. So t_fall[0] precedes
    // t_rise[0], and `t_fall[0] - t_rise[0]` is NEGATIVE -- which in the
    // unsigned `time` type wraps to ~1.8e19 and printed as
    // "18446744073709552.000 us". That is gotcha 53 verbatim, reproduced in a
    // brand new TB hours after writing the gotcha down. The search below finds
    // the first fall AFTER the first rise, so the difference is positive by
    // construction, and the plausibility bound is what would catch it if the
    // search were ever wrong again.
    if (n_rise >= 2 && n_fall >= 1) begin
      real half_us, period_us;
      time first_fall_after_rise;
      first_fall_after_rise = 0;
      for (int k = 0; k < n_fall; k++)
        if (t_fall[k] > t_rise[0] && first_fall_after_rise == 0)
          first_fall_after_rise = t_fall[k];

      half_us   = (first_fall_after_rise - t_rise[0]) / 1000.0;
      period_us = (t_rise[1] - t_rise[0]) / 1000.0;
      $display("    measured: SCLK high %.3f us, period %.3f us (tick = %.3f us)",
               half_us, period_us, TICK_NS / 1000.0);
      check(period_us > 0.0 && period_us < 5.0 * (TICK_NS / 1000.0),
            $sformatf("SCLK period %.3f us is within 5 ticks (%.3f us)",
                      period_us, 5.0 * TICK_NS / 1000.0));
      // Non-vacuity, two ways: a zero period would satisfy "less than 5 ticks"
      // while measuring nothing, and a wrapped negative would satisfy it too.
      check(half_us > 0.0 && half_us < 10.0,
            $sformatf("SCLK high time %.3f us is a plausible positive interval",
                      half_us));
    end else begin
      check(1'b0, $sformatf("enough SCLK edges to measure (rise=%0d fall=%0d)",
                            n_rise, n_fall));
    end

    // ---- 5. MOSI must not move while SCLK is high ------------------------
    // In mode 0 the master presents MOSI with SCLK low and holds it through the
    // high pulse. That discipline is already asserted transitively by check 1
    // (a MOSI change on the rising edge shifts the captured byte), and the
    // slave's capture point is the rising edge itself, so a separate
    // pin-discipline monitor would be re-testing the same thing. Noted here
    // rather than written, because a second check that can only fail when the
    // first one does adds no evidence.

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  // Watchdog. A firmware hang must be reported as a hang, not as a silent
  // timeout that looks like a pass from outside.
  initial begin
    #8_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
