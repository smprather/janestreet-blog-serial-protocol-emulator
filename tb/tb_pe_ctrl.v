// tb_pe_ctrl.v — the passive SPI loader, at the host's side of the wire.
//
// WHAT THIS PROVES
//
// A host can clock 16-bit words into the SoC's host write port: MSB-first,
// mode 0, one word per 16 rising SCLK edges, addresses incrementing, CS_N
// resetting the load, partial words discarded, and nothing written while the
// core runs. The TB drives the three pads and captures every host_we pulse;
// it never inspects pe_ctrl internals.

`timescale 1ns / 1ps

module tb_pe_ctrl;

  localparam int  WORDS   = 16;           // small: the oversize case runs here
  localparam real CLK_NS  = 1e9 / 60e6;   // 60 MHz, the locked operating point
  localparam real HALF_NS = 100.0;        // 5 MHz SCLK: 6 clocks per half period

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic spi_sclk, spi_mosi, spi_cs_n, run;
  wire  host_we, host_imem_sel, load_active, load_error;
  wire [7:0]  host_addr;                  // WORDS=16 -> IAW=4, clamped to 8
  wire [15:0] host_wdata, words_written;

  pe_ctrl #(.WORDS(WORDS)) dut (
    .clk(clk), .rst_n(rst_n),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n),
    .run(run),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .load_active(load_active), .load_error(load_error),
    .words_written(words_written)
  );

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---- host-side capture of every write the loader emits ----------------
  logic [15:0] cap_data [0:63];
  int          cap_addr [0:63];
  int          cap_n;
  int          writes_while_run;
  always @(posedge clk) if (host_we) begin
    if (run) writes_while_run = writes_while_run + 1;
    cap_data[cap_n] = host_wdata;
    cap_addr[cap_n] = host_addr;
    cap_n = cap_n + 1;
  end

  // ---- host-side SPI driver (mode 0: data changes while SCLK is low) ----
  task automatic spi_bit(input logic b);
    spi_mosi = b;
    #(HALF_NS);
    spi_sclk = 1'b1;
    #(HALF_NS);
    spi_sclk = 1'b0;
  endtask

  task automatic spi_word(input logic [15:0] w);
    for (int k = 15; k >= 0; k--) spi_bit(w[k]);
  endtask

  task automatic cs_low;  spi_cs_n = 1'b0; #(HALF_NS); endtask
  task automatic cs_high; spi_cs_n = 1'b1; #(HALF_NS); endtask

  task automatic settle;  repeat (8) @(posedge clk); #1; endtask

  task automatic check_write(input int idx, input logic [15:0] data,
                             input int addr, input string tag);
    check(cap_n > idx, $sformatf("%s: write %0d missing", tag, idx));
    if (cap_n > idx) begin
      check(cap_data[idx] === data,
            $sformatf("%s: write %0d data=%04h want %04h",
                      tag, idx, cap_data[idx], data));
      check(cap_addr[idx] === addr,
            $sformatf("%s: write %0d addr=%0d want %0d",
                      tag, idx, cap_addr[idx], addr));
    end
  endtask

  initial begin
    $dumpfile("tb_pe_ctrl.vcd");
    $dumpvars(0, tb_pe_ctrl);

    spi_sclk = 1'b0; spi_mosi = 1'b0; spi_cs_n = 1'b1; run = 1'b0;
    cap_n = 0;
    writes_while_run = 0;
    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    repeat (2) @(posedge clk); #1;

    // ================= 1: three words, MSB-first, incrementing ==========
    cs_low;
    spi_word(16'hA55A);        // non-palindromic: catches a bit-order flip
    spi_word(16'h1234);
    spi_word(16'hF00D);
    cs_high;
    settle;
    check(cap_n === 3, $sformatf("load 1: %0d writes, want 3", cap_n));
    check_write(0, 16'hA55A, 0, "load 1");
    check_write(1, 16'h1234, 1, "load 1");
    check_write(2, 16'hF00D, 2, "load 1");
    check(words_written === 16'd3, "load 1: words_written");
    check(load_error === 1'b0, "load 1: no error");

    // ================= 2: a new CS low resets the address ===============
    cap_n = 0;
    cs_low;
    spi_word(16'hBEEF);
    cs_high;
    settle;
    check(cap_n === 1, $sformatf("load 2: %0d writes, want 1", cap_n));
    check_write(0, 16'hBEEF, 0, "load 2");
    check(words_written === 16'd1, "load 2: words_written reset");

    // ================= 3: a partial word is discarded and flagged =======
    cap_n = 0;
    cs_low;
    spi_bit(1'b1); spi_bit(1'b0); spi_bit(1'b1);   // 3 bits, then CS high
    cs_high;
    settle;
    check(cap_n === 0, "partial: no write for 3 bits");
    check(load_error === 1'b1, "partial: flagged");

    // ================= 4: a new load clears the sticky error ============
    cap_n = 0;
    cs_low;
    spi_word(16'h5555);
    cs_high;
    settle;
    check(cap_n === 1, "reload: one write");
    check_write(0, 16'h5555, 0, "reload");
    check(load_error === 1'b0, "reload: error cleared by CS low");

    // ================= 5: nothing is written while run == 1 =============
    cap_n = 0;
    run = 1'b1;
    cs_low;
    spi_word(16'hDEAD);
    cs_high;
    settle;
    check(cap_n === 0, "run gate: no write while run=1");
    check(words_written === 16'd0, "run gate: no word counted");
    check(load_error === 1'b0,
          "run gate: an attempted load while running is ignored, not flagged");
    run = 1'b0;

    // ================= 6: words past WORDS are refused ==================
    cap_n = 0;
    cs_low;
    for (int k = 0; k < WORDS; k++) spi_word(16'h1000 + k[15:0]);
    spi_word(16'hFFFF);                    // one past the end
    cs_high;
    settle;
    check(cap_n === WORDS, $sformatf("oversize: %0d writes, want %0d",
                                     cap_n, WORDS));
    check_write(WORDS-1, 16'h1000 + (WORDS - 1), WORDS-1, "oversize");
    check(load_error === 1'b1, "oversize: flagged");

    // ================= 7: run transitions abort the queued word =========
    // Three windows, one requirement: a word queued when run rises must be
    // discarded, flagged, and must not write while run is high or reappear
    // when run falls. 7a is the review's W_PULSE window; 7b keeps a
    // queued-but-unstarted word from waiting for run to fall; 7c has run rise
    // inside W_DONE, where the run mask is what stops the write. The branch
    // waits `@(posedge clk); #1` so it observes the post-edge state, not the
    // pre-edge value the active region still holds.

    // ---- 7a: run rises in W_PULSE ----
    cap_n = 0; writes_while_run = 0; run = 1'b0;
    cs_low;
    fork
      begin
        forever begin
          @(posedge clk); #1;
          if (dut.wstate === 2'd1) break;
        end
        run = 1'b1;                                   // before the next edge
      end
      spi_word(16'hA55A);
    join
    cs_high;
    settle;
    check(cap_n === 0, $sformatf("7a: %0d writes, want 0", cap_n));
    check(writes_while_run === 0, "7a: host_we pulsed while run=1");
    check(words_written === 16'd0, "7a: word counted");
    check(load_error === 1'b1, "7a: abort not flagged");
    run = 1'b0;
    repeat (16) @(posedge clk); #1;
    check(cap_n === 0, "7a: queued word reappeared after run fell");
    check(words_written === 16'd0, "7a: stale word counted");

    // ---- 7b: run rises in W_IDLE with a word queued ----
    cap_n = 0; writes_while_run = 0; run = 1'b0;
    cs_low;
    fork
      begin
        forever begin
          @(posedge clk); #1;
          if (dut.word_ready === 1'b1) break;
        end
        run = 1'b1;                                   // before the FSM starts
      end
      spi_word(16'hA55A);
    join
    cs_high;
    settle;
    check(cap_n === 0, $sformatf("7b: %0d writes, want 0", cap_n));
    check(writes_while_run === 0, "7b: host_we pulsed while run=1");
    check(words_written === 16'd0, "7b: word counted");
    check(load_error === 1'b1, "7b: abort not flagged");
    run = 1'b0;                     // must NOT release a stale queued write
    repeat (16) @(posedge clk); #1;
    check(cap_n === 0, "7b: queued word reappeared after run fell");
    check(words_written === 16'd0, "7b: stale word counted");

    // ---- 7c: run rises inside W_DONE (the host_we mask stops the write) ----
    cap_n = 0; writes_while_run = 0; run = 1'b0;
    cs_low;
    fork
      begin
        forever begin
          @(posedge clk); #1;
          if (dut.wstate === 2'd2) break;
        end
        run = 1'b1;                                   // before the sample edge
      end
      spi_word(16'hA55A);
    join
    cs_high;
    settle;
    check(cap_n === 0, $sformatf("7c: %0d writes, want 0", cap_n));
    check(writes_while_run === 0, "7c: host_we pulsed while run=1");
    check(words_written === 16'd0, "7c: masked word counted");
    check(load_error === 1'b1, "7c: abort not flagged");
    run = 1'b0;
    repeat (16) @(posedge clk); #1;
    check(cap_n === 0, "7c: queued word reappeared after run fell");

    if (errors == 0) $display("PASS: tb_pe_ctrl");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: watchdog — tb_pe_ctrl did not finish");
    $finish;
  end

endmodule
