// tb_pe_fbuf.v — the frame buffer: byte-granular writes and lane-correct reads.
//
// WHAT THIS IS GUARDING
//
// Two failure modes, and both are silent in a design review because the code
// looks right:
//
//   1. A WRITE THAT IS NOT BYTE-GRANULAR. The macro has a bit mask (A_BM), so
//      byte-select is available in hardware -- but getting the polarity or the
//      lane wrong writes the whole word and clobbers the neighbouring byte. The
//      macro's own trap makes this silent: BM=0 with WEN=1 writes NOTHING and is
//      not an error, so a mask bug shows up as "the byte did not change", not as
//      a violation. The neighbour test below is what catches both directions.
//
//   2. A LANE REGISTERED TOO LATE. The macro's data is valid one cycle after the
//      address, so the lane must be captured AT THE SAME EDGE as the address. If
//      it is captured a cycle later, the mux selects the NEXT request's lane, and
//      the bug only appears when consecutive reads ALTERNATE lanes. A spot check
//      of one read passes. This is why the interleaved-read check exists and why
//      it reads an odd/even/odd/even pattern rather than sequential addresses.
//
// The FLOP=1 fallback is simulated by the SAME test, because the two paths must
// be indistinguishable. Their whole purpose is that one can stand in for the
// other, so a test that only ran one of them would leave that claim unchecked --
// and pe_imem's FLOP path exists specifically as a stand-in.

`timescale 1ns / 1ps

module tb_pe_fbuf;

  localparam int BYTES = 2048;
  localparam int AW    = $clog2(BYTES);

  // THE FLOP SELECTION IS A PARAMETER, NOT A CONSTANT, and the test runs BOTH
  // paths. pe_fbuf's whole reason for having a FLOP=1 fallback is that it can
  // stand in for the macro (area experiments, and running without the PDK), so
  // if the two paths can diverge the fallback is worse than useless -- it would
  // let a testbench pass against a memory that does not exist in silicon. The
  // same argument ADR-003 makes for using one macro part applies to simulating
  // one implementation.
  //
  //   +define+FLOP=1  -> register array (no PDK needed)
  //   (default)       -> the real macro, via the PDK behavioural model
  `ifdef FLOP
  localparam int FLOP_SEL = `FLOP;
  `else
  localparam int FLOP_SEL = 0;
  `endif

  logic clk = 0;
  logic we;
  logic [AW-1:0] waddr, raddr;
  logic [7:0]    wdata, rdata;

  pe_fbuf #(.BYTES(BYTES), .FLOP(FLOP_SEL)) dut (
    .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
    .raddr(raddr), .rdata(rdata)
  );

  always #(5) clk = ~clk;   // 10 ns period; the macro's latency is what matters

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // One byte write, then settle.
  task automatic wr(input int a, input int d);
    @(negedge clk);
    we = 1'b1; waddr = a[AW-1:0]; wdata = d[7:0];
    @(negedge clk);
    we = 1'b0;
  endtask

  // One byte read: present the address, wait one cycle for the macro's data.
  task automatic rd(input int a, output int d);
    @(negedge clk);
    raddr = a[AW-1:0];
    @(negedge clk);   // data valid for THIS address now
    d = rdata;
  endtask

  integer i;
  // One name per declaration: Icarus rejects `integer a, b;` with
  // "Syntax error in variable list". (Same family as the adjacent-string
  // and literal-bit-select limits hit elsewhere in this file.)
  integer got;
  integer want;

  initial begin
    we = 0; waddr = '0; raddr = '0; wdata = '0;
    repeat (4) @(negedge clk);

    $display("\n=== frame buffer: byte granularity and lane capture ===\n");

    // ---- 1. THE NEIGHBOUR TEST ------------------------------------------
    // Write the SAME word's two lanes separately and check BOTH afterwards. A
    // whole-word write clobbers the other lane; a no-op mask leaves the byte
    // unchanged. Writing lane 0 and then lane 1 means a clobbering write of the
    // SECOND byte would erase the first -- and writing them in both orders
    // catches a mask that never fires as well.
    wr(0, 8'hAA);          // byte 0 = low lane of word 0
    wr(1, 8'h55);          // byte 1 = high lane of word 0
    rd(0, got); check(got === 8'hAA, $sformatf("byte 0 survived byte 1's write (got %02h)", got));
    rd(1, got); check(got === 8'h55, $sformatf("byte 1 written into the high lane (got %02h)", got));

    // the reverse order: write high lane FIRST, then low. A mask that always
    // selected the low lane would pass the test above and fail this one.
    wr(3, 8'h11);
    wr(2, 8'h22);
    rd(2, got); check(got === 8'h22, $sformatf("byte 2 (low, written second) = %02h", got));
    rd(3, got); check(got === 8'h11, $sformatf("byte 3 (high, written first) survived (got %02h)", got));

    // ---- 2. THE ALTERNATING-LANE READ TEST ------------------------------
    // Consecutive reads that alternate lanes. This is the pattern that exposes a
    // lane register captured a cycle late, and it is what a sequential frame
    // walk looks like -- a spot check of one read cannot see it.
    for (i = 0; i < 8; i++) wr(i, i[7:0]);
    for (i = 0; i < 8; i++) begin
      rd(i, got);
      check(got === i[7:0],
            $sformatf("alternating read byte %0d = %02h (wrote %02h)", i, got, i[7:0]));
    end

    // The same pattern across a WORD boundary, which is where a lane bug that
    // keys off the word address would show: bytes 1 and 2 are in different
    // words, bytes 0 and 1 in the same one.
    wr(1, 8'hDE); wr(2, 8'hAD);
    rd(1, got); check(got === 8'hDE, $sformatf("word-crossing read byte 1 = %02h", got));
    rd(2, got); check(got === 8'hAD, $sformatf("word-crossing read byte 2 = %02h", got));

    // ---- 3. FULL CAPACITY: both ends of the array -----------------------
    // The last byte address is 2047 (high lane of word 1023). An address-width
    // or word-address truncation error is invisible at address 0.
    wr(0,          8'h5A);
    wr(BYTES-1,    8'hA5);
    wr(BYTES/2,    8'h3C);
    rd(0,         got); check(got === 8'h5A, $sformatf("byte 0 = %02h after a full sweep", got));
    rd(BYTES-1,   got); check(got === 8'hA5, $sformatf("byte %0d (last) = %02h", BYTES-1, got));
    rd(BYTES/2,   got); check(got === 8'h3C, $sformatf("byte %0d (middle) = %02h", BYTES/2, got));

    // ---- 4. EVERY BYTE IS INDEPENDENT ----------------------------------
    // A distinct value per byte, then verify all. This is the strong form of the
    // neighbour test: a whole-word write would leave PAIRS of bytes equal, and a
    // dropped address bit would alias bytes 2^i apart. Both are visible here and
    // nowhere in the tests above.
    for (i = 0; i < 64; i++) wr(i, (8'h9B + i) & 8'hFF);
    for (i = 0; i < 64; i++) begin
      want = (8'h9B + i) & 8'hFF;
      rd(i, got);
      check(got === want,
            $sformatf("independent byte %0d = %02h (wrote %02h)", i, got, want));
    end

    // ---- 5. PIPELINED READS: the lane must belong to the DATA, not the BUS ---
    // THE TEST THAT WAS MISSING, and mutation testing found the hole: replacing
    // the registered lane with the LIVE address lane (`raddr[0]`) passed every
    // check above, because every read above holds its address stable across the
    // whole access. In a real frame walk the address changes EVERY cycle, and
    // then the two differ:
    //
    //   cycle 1: raddr = A          -> at the next posedge, word_rd = mem[A]
    //   cycle 2: raddr = B (A's data is still on word_rd, because the macro
    //            is one cycle deep) -> rdata must be A's BYTE, selected by the
    //            lane registered with A, not by B's lane.
    //
    // Sampling mid-cycle, after the new address has been presented but before
    // the macro has latched its data, is exactly that instant. Consecutive
    // integers always alternate lanes, so the two answers differ on every
    // iteration and the check cannot pass by luck.
    for (i = 0; i < 16; i++) wr(i, (8'hC0 + i) & 8'hFF);
    @(negedge clk);
    raddr = AW'(0);
    for (i = 1; i <= 16; i++) begin
      @(negedge clk);
      raddr = AW'(i);           // the NEXT request, presented immediately
      #2;                       // mid-cycle: word_rd still holds byte i-1's word
      got = rdata;
      check(got === ((8'hC0 + i - 1) & 8'hFF),
            $sformatf("pipelined read %0d: rdata = %02h, expected byte %0d = %02h (lane taken from the live address, not the data)",
                      i - 1, got, i - 1, (8'hC0 + i - 1) & 8'hFF));
    end

    // ---- 6. A READ MUST NOT DISTURB A WRITE, and vice versa -------------
    // The two ports share one macro, so the arbitration is `we` -- and a design
    // that let a read through during a write could take the macro's
    // WRITE-THROUGH path (REN=1 with WEN=1 returns DIN, not memory). Writing
    // while a read address is presented must return the STORED value, not the
    // byte being written.
    wr(100, 8'h77);
    @(negedge clk);
    raddr = AW'(100);             // present a read of byte 100
    @(negedge clk);
    we = 1'b1; waddr = AW'(100); wdata = 8'h88;   // and write it in the same cycle
    @(negedge clk);
    we = 1'b0;
    check(rdata !== 8'h88,
          "a concurrent read did not return the byte being written (write-through leaked)");
    rd(100, got); check(got === 8'h88, $sformatf("byte 100 = %02h after the concurrent access", got));

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    #100_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
