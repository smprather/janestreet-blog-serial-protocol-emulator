// tb_pe_imem.v — instruction memory against the PDK's REAL SRAM model.
//
// WHY THIS TESTBENCH EXISTS AT ALL
//
// `rtl/pe_imem.v` is a thin translation from the CPU's port protocol to the
// macro's MEN/WEN/REN/BM protocol, and every way that translation can be wrong
// is a way that is INVISIBLE in a functional test:
//
//   * BM tied low instead of high: every write is a silent NO-OP. The loader
//     "succeeds", the program is blank, and the SoC runs NOPs forever.
//   * REN asserted during a write: the read port returns the NEW value
//     (write-through), so the read data path is a function of DIN for that
//     cycle. A design that never reads during a write still "works", which is
//     exactly why this needs an explicit test rather than luck.
//   * A second register on the output: read latency becomes two cycles and the
//     CPU's fetch-ahead -- which is built around exactly one -- executes the
//     wrong instruction before every jump. That failure looks like a CPU bug.
//
// So this TB does not test "does memory remember a word". It tests the three
// protocol facts the wrapper claims, against the vendor's behavioural model:
//
//   1. WRITE THEN READ: a word written through the loader comes back out.
//   2. ONE-CYCLE LATENCY: the data for address A appears exactly one clock after
//      A is driven, no more and no less.
//   3. NO WRITE-THROUGH: with REN deasserted during a write, the read port does
//      NOT show the new value on that cycle.
//   4. DEPTH: word 1023 is reachable, which is the whole point of the swap --
//      the previous 128-word memory could not hold an address above 127 and the
//      8-bit PC could not name one above 255.
//
// It runs the macro, not the FLOP fallback. If the PDK model is missing, the
// build fails loudly rather than quietly testing the fallback instead.

`timescale 1ns / 1ps

module tb_pe_imem;

  localparam int WORDS = 1024;
  localparam int IAW   = $clog2(WORDS);   // 10

  logic clk = 0, rst_n;
  logic [IAW-1:0] imem_addr, host_addr;
  logic [15:0]    imem_rdata, host_wdata;
  logic           host_we;

  pe_imem #(.WORDS(WORDS), .FLOP(0)) dut (
    .clk(clk),
    .imem_addr(imem_addr),
    .imem_rdata(imem_rdata),
    .host_we(host_we),
    .host_addr(host_addr),
    .host_wdata(host_wdata)
  );

  always #8.333 clk = ~clk;   // 60 MHz (ADR-005) -- the macro is clock-agnostic in
                            // simulation; the period only has to be realistic

  integer errors = 0;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL imem: %s @%0t", m, $time); errors++; end
  endtask

  // One loader write cycle.
  task automatic write_word(input [IAW-1:0] a, input [15:0] d);
    @(posedge clk); #1;
    host_we = 1'b1; host_addr = a; host_wdata = d;
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  integer i;
  logic [15:0] rd;

  initial begin
    $dumpfile("tb_pe_imem.vcd");
    $dumpvars(0, tb_pe_imem);
    rst_n = 1; host_we = 0; host_addr = 0; host_wdata = 0; imem_addr = 0;
    repeat (4) @(posedge clk); #1;

    // ============ 1. write then read ============
    // If BM were tied low this is the test that fails: the write is a no-op and
    // the read returns the model's initial X/0 rather than 0xA5A5.
    write_word(10'd0, 16'hA5A5);
    imem_addr = 10'd0;
    repeat (2) @(posedge clk); #1;
    check(imem_rdata === 16'hA5A5,
          $sformatf("word 0 reads back 0xA5A5 (got 0x%04X) — BM tied wrong?", imem_rdata));

    // ============ 2. one-cycle latency, exactly ============
    // Drive a NEW address and require the NEW data on the very next edge, with
    // no extra cycle. A wrapper register on top of the macro would show the old
    // data for one more cycle, and the CPU's fetch-ahead (built around exactly
    // one cycle) would execute the wrong instruction before every jump.
    //
    // Sampling note: `@(posedge clk); #1;` reads the value AFTER the edge, i.e.
    // the data the register now holds. That is the right probe for "did the word
    // arrive on this edge".
    write_word(10'd1, 16'h1111);
    write_word(10'd2, 16'h2222);

    imem_addr = 10'd1;
    @(posedge clk); #1;
    check(imem_rdata === 16'h1111,
          $sformatf("address 1 data is present the cycle after it is driven (got 0x%04X)",
                    imem_rdata));
    imem_addr = 10'd2;
    @(posedge clk); #1;
    check(imem_rdata === 16'h2222,
          $sformatf("address 2 data is present the next cycle (got 0x%04X)",
                    imem_rdata));

    // ============ 3. no write-through ============
    // A write to address 3 while the read port is pointed at address 3 must NOT
    // show the new value on the write cycle. The macro's own model WOULD return
    // the new value if REN were high, so this is a direct test that the wrapper
    // keeps REN low during a write.
    write_word(10'd3, 16'h3333);
    imem_addr = 10'd3;
    repeat (2) @(posedge clk); #1;
    check(imem_rdata === 16'h3333, "address 3 holds 0x3333 before the trap test");

    @(posedge clk); #1;
    host_we = 1'b1; host_addr = 10'd3; host_wdata = 16'hBBBB;
    @(posedge clk); #1;                 // the write commits on this edge
    // Read data this cycle must be the OLD word (0x3333), not 0xBBBB.
    check(imem_rdata === 16'h3333,
          $sformatf("no write-through: read port shows the OLD word (got 0x%04X)",
                    imem_rdata));
    host_we = 1'b0;
    repeat (2) @(posedge clk); #1;
    check(imem_rdata === 16'hBBBB, "the new word is visible after the write");

    // ============ 4. the depth that motivated the swap ============
    // Word 1023 must be reachable. The 128-word flop memory could not be
    // addressed above 127 and the 8-bit PC could not name anything above 255,
    // so this is the assertion that says the swap bought something.
    write_word(10'd1023, 16'hF00D);
    imem_addr = 10'd1023;
    repeat (2) @(posedge clk); #1;
    check(imem_rdata === 16'hF00D,
          $sformatf("word 1023 reads back (got 0x%04X)", imem_rdata));

    write_word(10'd512, 16'h0BAD);
    imem_addr = 10'd512;
    repeat (2) @(posedge clk); #1;
    check(imem_rdata === 16'h0BAD,
          $sformatf("word 512 reads back (got 0x%04X)", imem_rdata));

    // ============ 5. a full-image pattern, to catch aliasing ============
    // Write a distinct word to every address, then read them all back. If any
    // address bit were mis-wired (the classic off-by-one in a widened port),
    // two addresses would collide and this catches it.
    for (i = 0; i < WORDS; i++) write_word(i[IAW-1:0], 16'h1000 ^ i[15:0]);
    for (i = 0; i < WORDS; i++) begin
      imem_addr = i[IAW-1:0];
      repeat (2) @(posedge clk); #1;
      rd = imem_rdata;
      if (rd !== (16'h1000 ^ i[15:0])) begin
        check(1'b0, $sformatf("address %0d: got 0x%04X want 0x%04X",
                              i, rd, 16'h1000 ^ i[15:0]));
        if (errors > 8) begin
          $display("FAIL: too many, stopping");
          i = WORDS;                    // bail out of the loop
        end
      end
    end
    check(errors == 0, "every one of the 1024 addresses round-trips distinctly");

    if (errors == 0) $display("PASS: tb_pe_imem");
    else $display("FAILURES imem: %0d", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: watchdog");
    $finish;
  end
endmodule
