// tb_pe_soc_dbgread.v -- the R2 bounded host read port at the SoC level,
// against the REAL pe_imem (the SRAM macro's registered read), driven the way
// pe_ctrl's read engine drives it.
//
// WHY THIS TB EXISTS, and it is the hole the one-address-stale defect lived in
// (rtl/pe_soc.v, plan Amendment A, found 2026-10-04 by the tb_pe_soc_extspi
// dev lane; fixed by plan Amendment A2 the same day): every other pe_soc-level
// TB ties dbg_rd_req to 1'b0, and the two TBs that DO drive the read port
// (tb_pe_ctrl_r2, tb_pe_ctrl_r3) instantiate pe_ctrl WITHOUT pe_soc, serving
// the port from a TB-side memory image combinationally -- so pe_imem's
// registered read latency ("READ LATENCY IS ONE CYCLE", pe_imem.v) was in no
// gate at all, and the SoC's request-edge capture went unnoticed from the
// first day the port existed.
//
// WHAT IT PINS, all through the real SoC and the real macro:
//   * IMEM reads at addresses 0..3 return EXACTLY the words loaded there, at
//     a spaced cadence AND at pe_ctrl's own tight cadence (R_REQ, answer,
//     R_REQ again, no idle cycle between);
//   * a read at a high address returns the address-encoded filler there, so
//     a read that lands anywhere but its own word is wrong, not only one off;
//   * the same address read twice gives the same word both times;
//   * a DMEM byte read returns that byte zero-extended (the dmem half of the
//     one-shape contract, which the fix must not disturb);
//   * dbg_rd_valid is high exactly one cycle after the request and exactly
//     one cycle wide, and never asserts without a request.
//
// NOT A GATE FOR THE RANGE CHECKS. pe_soc does not range-check by design (the
// bounds and the sticky FAULT_RANGE live in pe_ctrl, pe_soc.v's port comment);
// the refusal statuses are pe_ctrl's business and are pinned on the pe_ctrl
// TBs. This TB reads only in-range, which is the SoC+macro path's business.
`timescale 1ns / 1ps

module tb_pe_soc_dbgread;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;
  localparam real CLK_NS = 1e9 / 60_000_000;

  // The words this TB loads and expects back. W0..W2 are the session's
  // canonical image (the same words the host-bridge lane loads); W3 and the
  // address-encoded filler make every other address distinguishable from
  // every word around it, so a mis-aimed read is wrong wherever it lands.
  localparam logic [15:0] W0 = 16'h0041, W1 = 16'h1001;
  localparam logic [15:0] W2 = 16'h4002, W3 = 16'h7C3D;

  // a filler word that names its own address: read(0x0300) must see A300
  function automatic logic [15:0] filler(input integer a);
    filler = 16'hA000 | a[15:0];
  endfunction

  localparam int HIGH_ADDR = 'h0300;   // an address far from 0..3

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;
  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  logic        dbg_rd_req, dbg_rd_dmem;
  logic [15:0] dbg_rd_addr;
  wire  [15:0] dbg_rd_data;
  wire         dbg_rd_valid;

  pe_soc #(
    .IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES), .BAUD(BAUD)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata), .run(run),
    .dbg_rd_req(dbg_rd_req), .dbg_rd_dmem(dbg_rd_dmem),
    .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data),
    .dbg_rd_valid(dbg_rd_valid),
    .pin_in(pin_in_bus), .pin_out(pin_out_bus), .pin_oe(pin_oe_bus),
    .dbg_pc(), .dbg_a(), .dbg_timer(),
    .dbg_hold(1'b0), .dbg_step(1'b0)
  );
  always #(CLK_NS/2) clk = ~clk;

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---- load, through the REAL loader port, exactly as the host loads it ----
  integer i;
  logic [15:0] prog [0:IMEM_WORDS-1];
  task automatic load_image();
    begin
      for (i = 0; i < IMEM_WORDS; i = i + 1)
        prog[i] = (i == 0) ? W0 : (i == 1) ? W1
                       : (i == 2) ? W2 : (i == 3) ? W3 : filler(i);
      for (i = 0; i < IMEM_WORDS; i = i + 1) begin
        @(posedge clk); #1;
        host_we = 1'b1; host_imem_sel = 1'b1;
        host_addr = i[IAW-1:0]; host_wdata = prog[i];
      end
      @(posedge clk); #1; host_we = 1'b0;
    end
  endtask

  // ---- one dmem byte store, through the same host port --------------------
  task automatic dmem_store(input logic [7:0] a, input logic [7:0] b);
    begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b0;   // dmem: the byte lane
      host_addr = a; host_wdata = {8'h00, b};
      @(posedge clk); #1; host_we = 1'b0;
    end
  endtask

  // ---- ONE IMEM read, SPACED cadence ---------------------------------------
  // Driven exactly as pe_ctrl's engine drives it (pe_ctrl.v, "R2 read engine"):
  // a ONE-CYCLE dbg_rd_req pulse, then the answer. Sampling one #1 past the
  // request-capture edge reads the same pair pe_ctrl reads at the posedge
  // that ends the valid cycle: both dbg_rd_valid and imem_rdata settle at that
  // edge, and dbg_reading holds the address through the whole answer cycle.
  // SPACED means one idle cycle between reads, during which dbg_reading is 0
  // and imem_addr goes back to the halted CPU's fetch -- the address mux
  // switching away and back is the harder of the two cases for the arbiter.
  task automatic read_one(input bit dmem, input logic [15:0] a,
                          output logic [15:0] data);
    begin
      @(posedge clk); #1;
      dbg_rd_dmem = dmem; dbg_rd_addr = a;
      dbg_rd_req  = 1'b1;                 // R_REQ: one cycle, like pe_ctrl
      @(posedge clk); #1;                 // this edge captures the request
      dbg_rd_req  = 1'b0;                 // R_WAIT from here
      check(dbg_rd_valid === 1'b1,
            $sformatf("dbg_rd_valid is high exactly one cycle after the request (dmem=%0d addr=%0d)",
                      dmem, a));
      data = dbg_rd_data;                 // the answer cycle's presented word
      @(posedge clk); #1;
      check(dbg_rd_valid === 1'b0,
            "dbg_rd_valid is exactly one cycle wide");
    end
  endtask

  // ---- a RUN of reads at pe_ctrl's OWN cadence -----------------------------
  // R_REQ, answer, R_REQ again: no idle cycle between reads, which is what the
  // engine actually does while walking a range (R_WAIT samples the answer and
  // R_REQ follows immediately). Consecutive requests are two cycles apart, and
  // imem_addr never leaves the host between them.
  logic [15:0] run_got [0:7];
  task automatic read_run(input bit dmem, input logic [15:0] first_addr,
                          input integer n);
    begin
      @(posedge clk); #1;
      dbg_rd_dmem = dmem;
      for (integer k = 0; k < n; k = k + 1) begin
        dbg_rd_addr = first_addr + k;
        dbg_rd_req  = 1'b1;               // R_REQ cycle
        @(posedge clk); #1;               // edge T: the request is captured
        dbg_rd_req  = 1'b0;               // R_WAIT
        check(dbg_rd_valid === 1'b1,
              $sformatf("tight cadence: dbg_rd_valid one cycle after request %0d", k));
        run_got[k] = dbg_rd_data;
        @(posedge clk); #1;               // edge T+1 ends the answer cycle
      end
    end
  endtask

  // ---- the stimulus --------------------------------------------------------
  logic [15:0] got;

  initial begin
    $dumpfile("tb_pe_soc_dbgread.vcd");
    $dumpvars(0, dbg_rd_req, dbg_rd_valid, dbg_rd_data, dbg_rd_addr);

    rst_n = 1'b0; run = 1'b0;
    host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0; pin_in_bus = 8'h00;
    dbg_rd_req = 1'b0; dbg_rd_dmem = 1'b0; dbg_rd_addr = 16'h0000;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_image();
    repeat (2) @(posedge clk);

    $display("=== R2 read port at the SoC level: the real pe_imem behind the real pe_soc ===");

    // (1) IMEM, spaced cadence, the canonical image words at 0..3.
    read_one(1'b0, 16'd0, got);
    check(got === W0, $sformatf("spaced IMEM read of 0 = %04h, expected %04h", got, W0));
    read_one(1'b0, 16'd1, got);
    check(got === W1, $sformatf("spaced IMEM read of 1 = %04h, expected %04h", got, W1));
    read_one(1'b0, 16'd2, got);
    check(got === W2, $sformatf("spaced IMEM read of 2 = %04h, expected %04h", got, W2));
    read_one(1'b0, 16'd3, got);
    check(got === W3, $sformatf("spaced IMEM read of 3 = %04h, expected %04h", got, W3));

    // (2) a high address: the filler names its own address, so a read that
    // lands one word off (the defect this TB exists for) is wrong here too.
    read_one(1'b0, HIGH_ADDR[15:0], got);
    check(got === filler(HIGH_ADDR),
          $sformatf("spaced IMEM read of %03h = %04h, expected %04h (the address-encoded filler)",
                    HIGH_ADDR, got, filler(HIGH_ADDR)));

    // (3) the same address twice: the answer must not depend on what the
    // previous request asked for.
    read_one(1'b0, 16'd1, got);
    check(got === W1, $sformatf("repeat IMEM read of 1 = %04h, expected %04h", got, W1));
    read_one(1'b0, 16'd1, got);
    check(got === W1, $sformatf("second repeat IMEM read of 1 = %04h, expected %04h", got, W1));

    // (4) IMEM at pe_ctrl's own tight cadence, 0..3 in one run: the answer
    // for request k must not be the word request k-1 asked for.
    read_run(1'b0, 16'd0, 4);
    check(run_got[0] === W0, $sformatf("tight cadence read 0 = %04h, expected %04h", run_got[0], W0));
    check(run_got[1] === W1, $sformatf("tight cadence read 1 = %04h, expected %04h", run_got[1], W1));
    check(run_got[2] === W2, $sformatf("tight cadence read 2 = %04h, expected %04h", run_got[2], W2));
    check(run_got[3] === W3, $sformatf("tight cadence read 3 = %04h, expected %04h", run_got[3], W3));

    // (5) DMEM, the other half of the one-shape contract: a byte written
    // through the host port, read back zero-extended. The fix touched the
    // capture path both memories share, so the byte half must be re-proved.
    dmem_store(8'd0, 8'h5A);
    dmem_store(8'd1, 8'hC3);
    read_one(1'b1, 16'd0, got);
    check(got === 16'h005A, $sformatf("dmem read of 0 = %04h, expected 005A", got));
    read_one(1'b1, 16'd1, got);
    check(got === 16'h00C3, $sformatf("dmem read of 1 = %04h, expected 00C3", got));

    // (6) no spurious valid: with no request, dbg_rd_valid never asserts.
    for (i = 0; i < 20; i = i + 1) begin
      @(posedge clk); #1;
      check(dbg_rd_valid === 1'b0,
            $sformatf("dbg_rd_valid asserted with no request (cycle %0d)", i));
    end

    $display("");
    if (errors == 0) $display("PASS: all checks (the real pe_imem answered every read with its own word)");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    // The image load is 1024 cycles; everything after is ~60. 5000 cycles is
    // a bound with 4x margin, not a timeout anyone should live near.
    #(CLK_NS * 5000);
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
