// tb_pe_tick_status.v — the STATUS flag must not lose ticks.
//
// Runs firmware/tick_count.pe, which counts ticks through the read-and-clear
// STATUS port in a two-instruction loop, and checks the count it assembles
// against the free-running TIMER the same tick counter drives.
//
// WHY THIS TESTBENCH EXISTS.
//
// `tick_flag` in pe_uart_soc.v was driven by two separate always_ff blocks:
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

module tb_pe_tick_status;
  localparam int IMEM_WORDS = 1024;   // SRAM swap, ADR-004
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int TICKS_PER_BIT = 173;    // 40 MHz / 115200 / 2
  localparam int CLK_NS = 25;            // 40 MHz

  logic clk = 0, rst_n;
  logic host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0] host_wdata;
  logic pin_in = 1, pin_out;
  logic [7:0] dbg_pc, dbg_a, dbg_timer;

  pe_uart_soc #(.IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES)) dut (
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata), .run(run),
    .pin_in(pin_in), .pin_out(pin_out),
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
    $dumpfile("tb_pe_tick_status.vcd");
    $dumpvars(0, tb_pe_tick_status);

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

    if (errors == 0) $display("PASS: tb_pe_tick_status");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: watchdog");
    $finish;
  end
endmodule
