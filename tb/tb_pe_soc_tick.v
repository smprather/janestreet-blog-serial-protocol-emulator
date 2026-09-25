// tb_pe_soc_tick.v — the STATUS flag must not lose ticks.
//
// Runs firmware/tick_count.pe, which counts ticks through the read-and-clear
// STATUS port in a two-instruction loop, and checks the count it assembles
// against the free-running TIMER the same tick counter drives.
//
// WHY THIS TESTBENCH EXISTS.
//
// `tick_flag` in pe_soc.v was driven by two separate always_ff blocks:
// the counter set it, a second process cleared it on the STATUS read. Two
// drivers on one flop is not legal RTL, and the two tools resolved it
// differently -- Icarus raced (measured: 193 of 1156 ticks silently dropped
// with a 3-cycle poll loop) and yosys reported a driver-driver conflict and
// tied tick_flag to a CONSTANT 0, so the netlist had no STATUS port at all.
//
// None of the 16 testbenches caught it, because uart_echo.pe polls the TIMER
// VALUE instead and never reads STATUS. Untested hardware is where this kind
// of defect lives, so the fix comes with the firmware that exercises it.
//
// The pass condition is equality, not "close enough": every tick is reported
// exactly once, so after N ticks the count is N. One tick of slack is allowed
// for a wrap in flight at the moment the testbench looks.

`timescale 1ns / 1ps

module tb_pe_soc_tick;
  localparam int IMEM_WORDS = 1024;   // SRAM swap, ADR-004
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  // Derived from the same expression the RTL uses, so a clock change cannot
  // leave this TB simulating at one rate while the SoC thinks it is at another.
  // CLK_NS must be `real`: the period is 16.667 ns, and an integer here would
  // round the half-period to 8 ns and silently simulate at 62.5 MHz instead.
  // The TB generates the clock, so it keeps its own copy of the rate. It is a
  // TEST FACT about the board, not a second configuration -- see
  // tb_pe_soc_uart.v's note and reference/clock-arithmetic.md.
  localparam int  CLK_HZ       = 60_000_000;
  localparam int  BAUD         = 115_200;
  localparam int  TICKS_PER_BIT = CLK_HZ / BAUD / 2;   // 260
  localparam real CLK_NS        = 1e9 / CLK_HZ;        // 16.667 ns

  logic clk = 0, rst_n;
  logic host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0] host_wdata;
  logic pin_in_bit = 1;
  wire [7:0] pin_in_bus  = {4'b0, pin_in_bit, 3'b0};   // port bit 3 = UART RX
  wire [7:0] pin_out_bus;
  wire [7:0] pin_oe_bus;
  logic [9:0] dbg_pc;   // R2: full PC width (pe_soc exposes PCW bits)
  logic [7:0] dbg_a, dbg_timer;

  pe_soc #(.IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES),
                .BAUD(BAUD)) dut (
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

  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;
  integer observed, expected;

  initial begin
    $dumpfile("tb_pe_soc_tick.vcd");
    $dumpvars(0, tb_pe_soc_tick);

    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;   // NOP fill
    $readmemh("../firmware/tick_count.hex", prog);

    rst_n = 0; run = 0; host_we = 0; host_imem_sel = 0;
    host_addr = 0; host_wdata = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;

    // Load the whole window, not part of it: a short load leaves the program's
    // own loop-back target as a NOP and the program runs off the end.
    host_imem_sel = 1;
    for (i = 0; i < IMEM_WORDS; i++) begin
      host_addr  = i[IAW-1:0];
      host_wdata = prog[i];
      host_we    = 1;
      @(posedge clk); #1;
    end
    host_we = 0;
    @(posedge clk); #1;

    // PULSE RESET AGAIN after the load, and this is not cosmetic.
    //
    // The timer free-runs from the release of reset, so it has already advanced
    // during the load window. At 128 words that window was 128 cycles -- SHORTER
    // than one 173-cycle tick -- so the timer happened to still be at 0 when the
    // core started, and this test's "observed vs free-running TIMER" comparison
    // was true by accident of timing, not by construction.
    //
    // At 1024 words the load is 1024 cycles (~6 ticks), the free-running counter
    // is ahead before the first instruction executes, and the comparison fails
    // by exactly the number of ticks the loader consumed. See the SRAM swap
    // (decisions/adr-004-program-counter-width.md): this is the first place the
    // longer load window changes observable behaviour, and a real loader would
    // take longer still.
    //
    // Resetting here makes the assumption true instead of lucky. It is safe
    // because pe_imem has NO reset: the SRAM keeps its contents, so the program
    // survives while pc, the registers and the timer all return to 0 together.
    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;

    run = 1;

    // Let it count. 100 ticks is well inside the 8-bit wrap of both counters.
    repeat (100 * TICKS_PER_BIT) @(posedge clk);
    #1;

    observed = dut.dmem[0];
    expected = dbg_timer;

    $display("  ticks reported via STATUS = %0d, free-running TIMER = %0d",
             observed, expected);

    // Equality, with one tick of slack for a wrap the firmware has seen but
    // not yet banked (it is 4 instructions from the IN to the STM).
    check(observed >= expected - 1,
          $sformatf("STATUS lost ticks: counted %0d of %0d", observed, expected));
    check(observed <= expected,
          $sformatf("STATUS double-reported: counted %0d of %0d", observed, expected));

    // A constant-zero flag is the synthesis failure mode, and it looks like
    // "counted 0". Call it out separately so the message names the cause.
    check(observed != 0, "STATUS never reported a tick (flag stuck at 0?)");

    // ================= directed: the read/wrap overlap =================
    // The one-cycle case a poll loop cannot hit on purpose, and the one the
    // emulator got wrong (it ticked BEFORE the instruction, so an `IN STATUS`
    // landing on the wrap read the new flag and cleared it, and `IN TIMER`
    // read the post-increment value). The RTL rule is: a read is combinational
    // from the PRE-edge register, and when the wrap and the read share an edge
    // `tick_now` wins (set beats clear). White-box on purpose -- forcing the
    // counter onto the wrap cycle is the only way to make the overlap certain.
    run = 0;
    @(negedge clk); #1;
    rst_n = 0;
    repeat (2) @(negedge clk); #1;
    rst_n = 1;
    run = 1;

    // (a) wrap + STATUS read, no prior flag: A must see 0, the event survives.
    force dut.imem_rdata = 16'h2007;          // IN A, STATUS
    dut.tick_cnt = 259; dut.tick_val = 8'd7; dut.tick_flag = 1'b0;
    @(posedge clk); #1;
    check(dbg_a === 8'd0,
          $sformatf("wrap+read: A = %0d, want the PRE-edge flag 0", dbg_a));
    check(dut.tick_flag === 1'b1, "wrap+read: set-beats-clear lost the tick");
    check(dut.tick_val === 8'd8, "wrap+read: the counter did not advance");

    // (b) wrap + STATUS read with the flag already pending: report it AND keep
    // it. Clearing here would drop a tick the firmware had not banked.
    @(negedge clk);
    dut.tick_cnt = 259; dut.tick_val = 8'd7; dut.tick_flag = 1'b1;
    @(posedge clk); #1;
    check(dbg_a === 8'd1, $sformatf("pending flag: A = %0d, want 1", dbg_a));
    check(dut.tick_flag === 1'b1, "pending flag: the read cleared a same-edge tick");

    // (c) TIMER on the wrap cycle returns the value BEFORE the increment.
    @(negedge clk);
    force dut.imem_rdata = 16'h2005;          // IN A, TIMER
    dut.tick_cnt = 259; dut.tick_val = 8'd7;
    @(posedge clk); #1;
    check(dbg_a === 8'd7,
          $sformatf("TIMER read: A = %0d, want the pre-increment 7", dbg_a));
    check(dut.tick_val === 8'd8, "TIMER read: the counter did not advance");
    release dut.imem_rdata;
    run = 0;

    if (errors == 0) $display("PASS: tb_pe_soc_tick");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: watchdog");
    $finish;
  end
endmodule
