// tb_pe_cpu.v — unit test for pe_cpu alone. Instruction-by-instruction.
//
// Two implementations of this ISA exist: rtl/pe_cpu.v and tools/peemu.py.
// They WILL drift; this test pins the RTL's behaviour to the documented
// semantics so a divergence shows up here, at the instruction, rather than as
// a mysteriously stuck program three layers up.
//
// The hazard this exists to catch: IN/LDI/LDS/etc. write A one cycle after the
// instruction executes, so a branch immediately after a load must test the
// value being LOADED, not the stale register. Without forwarding, `IN A, PIN`
// + `JZ` branches on the previous sample and every poll loop misbehaves.

`timescale 1ns / 1ps

module tb_pe_cpu;
  localparam int IMEM_WORDS = 128;
  localparam int DMEM_BYTES = 16;

  logic clk = 0, rst_n, run;
  logic [6:0]   imem_addr;
  logic [15:0]  imem_rdata;
  logic [3:0]   dmem_addr;
  logic         dmem_we;
  logic [7:0]   dmem_wdata, dmem_rdata;
  logic [3:0]   io_port;
  logic         io_we, io_re;
  logic [7:0]   io_wdata, io_rdata;

  // testbench-side memories and IO
  logic [15:0] imem [0:IMEM_WORDS-1];
  logic [7:0]  dmem [0:DMEM_BYTES-1];
  logic [7:0]  io_regs [0:15];

  pe_cpu #(.IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES)) dut (
    .clk(clk), .rst_n(rst_n), .run(run),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_addr(dmem_addr), .dmem_we(dmem_we),
    .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
    .io_port(io_port), .io_we(io_we), .io_re(io_re),
    .io_wdata(io_wdata), .io_rdata(io_rdata)
  );

  always #8.333 clk = ~clk;   // 60 MHz (ADR-005) -- these blocks are clock-agnostic;
                            // the period only has to be realistic

  // Instruction ROM: registered read (it models a ROM macro, and the CPU's
  // fetch-ahead depends on this one-cycle latency).
  always_ff @(posedge clk) imem_rdata <= imem[imem_addr];

  // Data scratchpad: COMBINATIONAL read, matching rtl/pe_uart_soc.v. A
  // registered read is stale for an immediate-address load.
  assign dmem_rdata = dmem[dmem_addr];

  always_ff @(posedge clk) begin
    if (dmem_we) dmem[dmem_addr] <= dmem_wdata;
    if (io_we) io_regs[io_port] <= io_wdata;
  end

  assign io_rdata = io_regs[io_port];

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // Encodings (must match rtl/pe_cpu.v's header)
  function automatic [15:0] LDI(input [7:0] v);  LDI  = 16'h0000 | v; endfunction
  function automatic [15:0] OUT_(input [3:0] p); OUT_ = 16'h1000 | p; endfunction
  function automatic [15:0] IN_(input [3:0] p);  IN_  = 16'h2000 | p; endfunction
  function automatic [15:0] MOV_(input [1:0] s); MOV_ = 16'h3000 | s; endfunction
  function automatic [15:0] JMP_(input [7:0] a); JMP_ = 16'h4000 | a; endfunction
  function automatic [15:0] JZ_(input [7:0] a);  JZ_  = 16'h5000 | a; endfunction
  function automatic [15:0] JNZ_(input [7:0] a); JNZ_ = 16'h6000 | a; endfunction
  function automatic [15:0] ALU_(input [1:0] s, input [7:0] v); ALU_ = 16'h7000 | (s<<10) | v; endfunction
  function automatic [15:0] ALU_X(input [1:0] s); ALU_X = 16'h7000 | (s<<10) | (1<<9); endfunction
  function automatic [15:0] INCX();  INCX = 16'h8000; endfunction
  function automatic [15:0] DECX();  DECX = 16'h9000; endfunction
  function automatic [15:0] SHR_();  SHR_ = 16'hA000; endfunction
  function automatic [15:0] LDS_();  LDS_ = 16'hB000; endfunction
  function automatic [15:0] STS_();  STS_ = 16'hC000; endfunction
  function automatic [15:0] LDM_(input [7:0] a); LDM_ = 16'hD000 | (a & 8'hFF); endfunction
  function automatic [15:0] LDMX(input [3:0] a); LDMX = 16'hD000 | 8'h80 | a; endfunction
  function automatic [15:0] STM_(input [7:0] a); STM_ = 16'hE000 | (a & 8'hFF); endfunction
  function automatic [15:0] NOP_();  NOP_ = 16'hF000; endfunction

  task automatic load(input int idx, input [15:0] w);
    imem[idx] = w;
  endtask

  // Clear the whole instruction image before each test. Without this, a test
  // that loads only instructions 0..3 executes into the PREVIOUS test's code
  // afterwards -- the ISA has no HALT, so the program simply keeps going.
  task automatic clear_program();
    for (int i = 0; i < IMEM_WORDS; i++) imem[i] = NOP_();
  endtask

  task automatic reset_cpu();
    // Sequence matters. Instruction fetch is REGISTERED, so after releasing run
    // the CPU must have a valid imem_rdata before pc advances, or the first
    // instruction executed is whatever the fetch register happened to hold.
    // Drive two clocks with run LOW (letting the fetch settle at pc=0), then
    // raise run on the third.
    rst_n = 0; run = 0;
    repeat (3) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;              // fetch at pc=0 registers here
    run = 1;                         // release: the NEXT edge executes insn 0
  endtask

  task automatic step(input int n);
    repeat (n) @(posedge clk); #1;
  endtask

  // Run until the PC reaches `stop`, or give up. The fetch is registered, so
  // pc trails the executing instruction by one cycle -- waiting for a PC is
  // therefore still an internal-timing claim. Running a fixed budget and then
  // checking the OBSERVABLE (A, dmem, io) is the robust formulation.
  task automatic run_budget(input int n);
    repeat (n) @(posedge clk); #1;
  endtask

  initial begin
    $dumpfile("tb_pe_cpu.vcd");
    $dumpvars(0, tb_pe_cpu);

    for (int i = 0; i < IMEM_WORDS; i++) imem[i] = NOP_();
    for (int i = 0; i < DMEM_BYTES; i++) dmem[i] = 8'h00;
    for (int i = 0; i < 16; i++) io_regs[i] = 8'h00;

    clear_program();
    // ---- 1. LDI then branch: the load/branch hazard, in isolation --------
    // Program (indices matter -- an off-by-one here tests the wrong thing):
    //   0: LDI A,1        1: JZ 4        2: LDI A,0x11
    //   3: JMP 5          4: LDI A,0xEE  5: NOP   <- "done"
    // A=1, so JZ at 1 must NOT be taken; execution runs 2, 3 -> jumps to 5.
    // A ends 0x11. If the branch hazard were wrong, A would end 0xEE.
    load(0, LDI(8'h01));
    load(1, JZ_(8'h04));
    load(2, LDI(8'h11));
    load(3, JMP_(8'h05));
    load(4, LDI(8'hEE));
    load(5, NOP_());
    reset_cpu();
    // Trace this one test: the fetch is registered, so pc/op in any single
    // $display are one cycle apart, and reasoning about them from outside is
    // how this test was wrong three times.
    for (int i = 0; i < 10; i++) begin
      @(posedge clk); #1;
      $display("    t1 cyc %0d: pc=%0d op=%h a=%02h", i, dut.pc, dut.op, dut.a);
    end
    check(dut.a === 8'h11,
          $sformatf("LDI 1 + JZ: not taken, A=0x11 (got %02h)", dut.a));

    clear_program();
    // ---- 2. LDI A,0 then JZ: branch TAKEN -------------------------------
    load(0, LDI(8'h00));
    load(1, JZ_(8'h03));
    load(2, LDI(8'hEE));       // skipped
    load(3, LDI(8'h77));
    reset_cpu();
    run_budget(12);
    check(dut.a === 8'h77, "LDI 0 + JZ: branch taken, A=0x77");

    clear_program();
    // ---- 3. IN then branch: the real-world case -------------------------
    // IN A, PIN(0) ; JZ skip ; LDI A,0xEE ; skip: LDI A,0x55
    load(0, IN_(4'h0));
    load(1, JZ_(8'h03));
    load(2, LDI(8'hEE));
    load(3, LDI(8'h55));
    io_regs[0] = 8'h00;                        // pin reads 0 -> branch taken
    reset_cpu();
    run_budget(12);
    check(dut.a === 8'h55, "IN(0) + JZ: branch taken on a zero read");

    clear_program();
    // ---- 4. IN then JNZ: pin high --------------------------------------
    load(0, IN_(4'h0));
    load(1, JNZ_(8'h03));
    load(2, LDI(8'hEE));
    load(3, LDI(8'h66));
    io_regs[0] = 8'h01;                        // pin reads 1
    reset_cpu();
    run_budget(12);
    check(dut.a === 8'h66, "IN(1) + JNZ: branch taken on a one read");

    clear_program();
    // ---- 5. OUT writes the port ----------------------------------------
    load(0, LDI(8'hA5));
    load(1, OUT_(4'h3));
    io_regs[3] = 8'h00;
    reset_cpu();
    run_budget(12);
    check(io_regs[3] === 8'hA5, "OUT: port 3 got 0xA5");

    clear_program();
    // ---- 6. ALU with a register operand (SUB A, X) ----------------------
    // LDI A,5 ; MOV X,A ; LDI A,9 ; SUB A,X ; -> A = 4
    load(0, LDI(8'h05));
    load(1, MOV_(2'd2));       // X <- A
    load(2, LDI(8'h09));
    load(3, ALU_X(2'd1));      // SUB A, X
    reset_cpu();
    run_budget(12);
    check(dut.a === 8'h04, "SUB A,X: 9-5 = 4");

    clear_program();
    // ---- 7. memory: STS through X, LDM by address ----------------------
    // LDI A,3 ; MOV X,A ; LDI A,0x5A ; STS [X],A ; LDI A,0 ; LDM A,3
    load(0, LDI(8'h03));
    load(1, MOV_(2'd2));
    load(2, LDI(8'h5A));
    load(3, STS_());
    load(4, LDI(8'h00));
    load(5, LDM_(8'h03));
    reset_cpu();
    run_budget(16);
    check(dmem[3] === 8'h5A, "STS: wrote 0x5A to dmem[3]");
    check(dut.a === 8'h5A, "LDM: read 0x5A back from dmem[3]");

    clear_program();
    // ---- 8. LDM X, addr (the index load used by the tick-wait idiom) ----
    // dmem is reset between tests, so set it AFTER reset_cpu().
    load(0, LDMX(4'h8));       // X <- dmem[8]
    load(1, LDI(8'h00));       // spacer: let the X write land
    load(2, MOV_(2'd3));       // A <- X
    reset_cpu();
    dmem[8] = 8'h3C;           // must be set after reset (a reset clears dmem)
    run_budget(20);
    check(dut.a === 8'h3C,
          $sformatf("LDM X,8: X loaded, A reads 0x3C (got %02h, x=%02h)", dut.a, dut.x));

    clear_program();
    // ---- 9. INCX / DECX / SHR ------------------------------------------
    load(0, LDI(8'h02));
    load(1, MOV_(2'd2));       // X=2
    load(2, INCX());
    load(3, DECX());
    load(4, DECX());             // X=1
    load(5, MOV_(2'd3));       // A=X
    load(6, SHR_());           // A = A>>1 = 0
    reset_cpu();
    run_budget(14);
    check(dut.a === 8'h00, "INCX/DECX/SHR: A=0 after halving 1");

    if (errors == 0) $display("PASS: tb_pe_cpu");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #500000;
    $display("FAIL: tb_pe_cpu watchdog — pc=%0d", dut.pc);
    $finish;
  end
endmodule
