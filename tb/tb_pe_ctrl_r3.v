// tb_pe_ctrl_r3.v — the R3 DEBUG-CONTROL contract at the host's side of the
// wire: single-step, one hardware breakpoint on PC, and the debug readback.
//
// WHAT IT DRIVES. A REAL pe_ctrl and a REAL pe_cpu, wired exactly as the SoC
// and the top route the three debug wires (dbg_hold / dbg_step / dbg_next_pc),
// with a registered instruction-memory model (the macro's read latency). The
// register state the responses report is therefore the CPU's own.
//
// RED-FIRST. This TB was run against the RTL with the debug PORTS present but
// the opcodes unimplemented: every debug op answered UNSUPPORTED and the run
// failed, which is the evidence that the TB tests the contract and not the
// status quo. It is then GREEN only when the implementation matches
// reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md.
//
// CASES: bp set readback / out of range / wrong length; the two-step sequence
// with the register effects; step-while-running refusal; a live core stopped
// by the breakpoint; stepping off the breakpoint (hit clears); CLEAR releasing
// the hold; a bad-CRC frame with NO side effect; and the STATUS state encoding.
//
// The framing helpers below are the R1 TB's, deliberately: the host side of the
// wire must be the SAME driver for both, so a contract change that breaks the
// framing breaks both TBs.

`timescale 1ns / 1ps

module tb_pe_ctrl_r3;

  localparam int  WORDS   = 16;
  localparam real CLK_NS  = 1e9 / 60e6;
  localparam real HALF_NS = 100.0;

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic spi_sclk, spi_mosi, spi_cs_n, run;
  wire  spi_miso, miso_oe, irq_n;
  wire  host_we, host_imem_sel, load_active, load_error;
  wire [7:0]  host_addr;
  wire [15:0] host_wdata, words_written, faults;

  // ---- the CPU + its instruction memory (the registered-read model) ------
  logic [3:0]  imem_addr;
  logic [15:0] imem_rdata;
  logic [3:0]  dmem_addr;
  logic        dmem_we;
  logic [7:0]  dmem_wdata;
  logic [7:0]  dmem_rdata = 8'h00;
  logic [3:0]  io_port;
  logic        io_we, io_re;
  logic [7:0]  io_wdata;
  logic [7:0]  io_rdata = 8'h00;

  logic [7:0]  cpu_pc;
  logic [7:0]  cpu_a, cpu_x, cpu_y;
  logic [15:0] cpu_insn;
  wire         dbg_hold, dbg_step;      // pe_ctrl -> pe_cpu
  wire [7:0]   dbg_next_pc;             // pe_cpu -> pe_ctrl (zero-extended below)

  logic [15:0] prog [0:WORDS-1];

  // The macro's read: the address presented this cycle is sampled at the edge,
  // so imem_rdata holds the instruction at imem_addr one cycle later.
  always_ff @(posedge clk) begin
    if (!rst_n) imem_rdata <= 16'h0000;
    else        imem_rdata <= prog[imem_addr];
  end

  pe_cpu #(.IMEM_WORDS(WORDS), .DMEM_BYTES(16)) u_cpu (
    .clk(clk), .rst_n(rst_n), .run(run),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_addr(dmem_addr), .dmem_we(dmem_we), .dmem_wdata(dmem_wdata),
    .dmem_rdata(dmem_rdata),
    .io_port(io_port), .io_we(io_we), .io_re(io_re),
    .io_wdata(io_wdata), .io_rdata(io_rdata),
    .dbg_pc(cpu_pc), .dbg_a(cpu_a), .dbg_x(cpu_x), .dbg_y(cpu_y),
    .dbg_insn(cpu_insn),
    .dbg_hold(dbg_hold), .dbg_step(dbg_step), .dbg_next_pc(dbg_next_pc)
  );

  // ---- pe_ctrl: the host bus, with the debug wires routed ----------------
  logic        dbg_rd_req, dbg_rd_dmem, dbg_rd_valid;
  logic [15:0] dbg_rd_addr, dbg_rd_data;
  logic [7:0]  dbg_timer = 8'h00;
  logic [15:0] dbg_insn_wire;

  pe_ctrl #(.WORDS(WORDS)) dut (
    .clk(clk), .rst_n(rst_n),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n),
    .spi_miso(spi_miso), .miso_oe(miso_oe), .irq_n(irq_n),
    .run(run),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .load_active(load_active), .load_error(load_error),
    .words_written(words_written), .faults(faults),
    .dbg_rd_req(dbg_rd_req), .dbg_rd_dmem(dbg_rd_dmem),
    .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data),
    .dbg_rd_valid(dbg_rd_valid),
    .dbg_pc({2'b00, cpu_pc}), .dbg_a(cpu_a), .dbg_x(cpu_x), .dbg_y(cpu_y),
    .dbg_insn(cpu_insn), .dbg_timer(dbg_timer),
    .dbg_hold(dbg_hold), .dbg_step(dbg_step), .dbg_next_pc({2'b00, dbg_next_pc})
  );

  // Read-port model (only used by the READ_CPU cross-check).
  assign dbg_rd_data = 16'h0000;
  assign dbg_rd_valid = 1'b0;

  // ---- state encoding, mirrored from the contract ------------------------
  localparam logic [1:0] ST_STOPPED = 2'd0, ST_RUNNING = 2'd1,
                         ST_DEBUG   = 2'd2, ST_BP_HIT  = 2'd3;

  task automatic load_prog;
    prog[0] = 16'h0055;   // LDI A,0x55
    prog[1] = 16'h00AA;   // LDI A,0xAA
    prog[2] = 16'hF000;   // NOP
    prog[3] = 16'h000F;   // LDI A,0x0F
    prog[4] = 16'h4002;   // JMP 2
  endtask


  // Fault bits, mirrored from the RTL/R0 contract.
  localparam logic [15:0] FAULT_LOAD     = 16'h0001;
  localparam logic [15:0] FAULT_CRC      = 16'h0002;
  localparam logic [15:0] FAULT_RANGE    = 16'h0004;
  localparam logic [15:0] FAULT_PROTOCOL = 16'h0008;
  localparam logic [15:0] CAP_HOST       = 16'h000F;
  localparam logic [15:0] CAP_LOOPBACK   = 16'h0010;
  localparam logic [15:0] LOOPBACK_ID    = 16'h10C0;

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

  // ---- independent CRC-16/CCITT-FALSE reference --------------------------
  function automatic logic [15:0] crc16(input logic [15:0] crc, input logic [7:0] b);
    logic [15:0] c;
    c = crc ^ {b, 8'h00};
    for (int i = 0; i < 8; i++)
      c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    return c;
  endfunction
  function automatic logic [15:0] crc_word(input logic [15:0] crc, input logic [15:0] w);
    return crc16(crc16(crc, w[15:8]), w[7:0]);
  endfunction

  // ---- host-side SPI driver (mode 0: data changes while SCLK is low) ----
  real sclk_low_ns  = HALF_NS;
  real sclk_high_ns = HALF_NS;

  task automatic set_sclk(input real low_ns, input real high_ns);
    sclk_low_ns = low_ns; sclk_high_ns = high_ns;
  endtask

  task automatic spi_bit(input logic b);
    spi_mosi = b;
    #(sclk_low_ns);
    spi_sclk = 1'b1;
    #(sclk_high_ns);
    spi_sclk = 1'b0;
  endtask

  // A response bit: sample MISO on the rise, with the mode-0 stability checks
  // (stable >= 20 ns before the sampling edge; no movement in the first
  // 100 ns of the high phase -- a change there belongs to the rising edge).
  task automatic spi_bit_rb(input logic b, output logic q);
    logic pre;
    spi_mosi = b;
    #(sclk_low_ns - 20.0);
    pre = spi_miso;
    #20.0;
    spi_sclk = 1'b1;
    q = spi_miso;
    check(q === pre, "mode-0: MISO changed within 20 ns before the sampling edge");
    #(100.0);
    check(spi_miso === q, "mode-0: MISO changed during the high phase");
    #(sclk_high_ns - 100.0);
    spi_sclk = 1'b0;
  endtask

  task automatic send_word(input logic [15:0] w);
    for (int k = 15; k >= 0; k--) spi_bit(w[k]);
  endtask

  // R2 WAIT-WORD CONTRACT (manager ruling 2026-09-25). A bounded read cannot
  // answer inside the request's own bit times, so the chip DRIVES 0xFFFF
  // filler words while it fetches and the real frame starts at the first
  // non-0xFFFF word. The reader therefore SKIPS leading 0xFFFF words instead
  // of waiting: a filler is never a header (the response sets opcode bit 7 and
  // its version/target are bounded, so no header word is all ones), and the
  // skip is LEADING-only, so a 0xFFFF inside a payload is data. An R1
  // response carries zero wait words and is read exactly as before.
  //
  // The bound is the documented worst case: a read returns at most 15 words,
  // one round trip each, so at most 15 filler words precede a response.
  localparam int MAX_WAIT_WORDS = 16;
  bit resp_wait;                 // 1 = the next read_word skips leading fillers

  task automatic read_word(output logic [15:0] w);
    logic q;
    w = 16'h0000;
    if (resp_wait) begin
      resp_wait = 1'b0;
      for (int k = 0; k < MAX_WAIT_WORDS; k++) begin
        for (int b = 15; b >= 0; b--) begin
          spi_bit_rb(1'b0, q);
          w = {w[14:0], q};
        end
        if (w !== 16'hFFFF) return;          // first non-filler: the frame
      end
      $display("FAIL: read_word: %0d wait words with no response (t=%0t)",
               MAX_WAIT_WORDS, $time);
      errors = errors + 1;
    end else begin
      for (int k = 15; k >= 0; k--) begin
        spi_bit_rb(1'b0, q);
        w = {w[14:0], q};
      end
    end
  endtask

  task automatic cs_low;  spi_cs_n = 1'b0; #(HALF_NS); endtask
  task automatic cs_high; spi_cs_n = 1'b1; #(HALF_NS); endtask
  task automatic settle;  repeat (8) @(posedge clk); #1; endtask

  // ---- frame helpers ------------------------------------------------------
  logic [15:0] txp [0:31];       // request payload words the case sets
  logic [15:0] rxf [0:63];       // response words read back
  logic [15:0] body [0:63];      // frame under construction
  int          rlen;             // response payload length from its header

  // Send a request frame with CS low, then read exactly the response frame.
  // The TB knows the response length only after its header, so it reads 4
  // words first, then the declared payload + CRC.
  task automatic exchange(input logic [7:0] op, input logic [15:0] seq,
                          input logic [3:0] tgt, input int plen,
                          input bit bad_crc);
    logic [15:0] crc, w;
    int total;
    body[0] = 16'hA55A;
    body[1] = {4'h1, op, tgt};
    body[2] = seq;
    body[3] = plen[15:0];
    for (int k = 0; k < plen; k++) body[4+k] = txp[k];
    crc = 16'hFFFF;
    for (int k = 0; k < 4 + plen; k++) crc = crc_word(crc, body[k]);
    body[4+plen] = bad_crc ? (crc ^ 16'h0001) : crc;

    cs_low;
    for (int k = 0; k < 5 + plen; k++) begin
      w = body[k];
      send_word(w);
    end
    for (int k = 0; k < 4; k++) begin
      resp_wait = 1'b1;              // only the first word may be late
      read_word(w);
      rxf[k] = w;
    end
    rlen = rxf[3];
    total = 5 + rlen;
    for (int k = 4; k < total; k++) begin
      read_word(w);
      rxf[k] = w;
    end
    cs_high;
    settle;
    if (rxf[0] !== 16'hA55A) begin
      $display("FAIL: response sync = %04h @%0t", rxf[0], $time); errors++;
    end else begin
      crc = 16'hFFFF;
      for (int k = 0; k < total - 1; k++) crc = crc_word(crc, rxf[k]);
      check(crc === rxf[total-1],
            $sformatf("response CRC = %04h, computed %04h", rxf[total-1], crc));
      check(rxf[1][15:12] === 4'h1, "response version");
      check(rxf[1][11:4] === (op | 8'h80),
            $sformatf("response opcode = %02h, want %02h", rxf[1][11:4], op | 8'h80));
      check(rxf[1][3:0] === tgt,
            $sformatf("response target = %0d, want %0d", rxf[1][3:0], tgt));
      check(rxf[2] === seq, "response sequence echo");
    end
  endtask

  task automatic check_status(input logic [15:0] want, input string tag);
    check(rxf[4] === want, $sformatf("%s: status = %0d, want %0d", tag, rxf[4], want));
  endtask

  task automatic check_write(input int idx, input logic [15:0] data,
                             input int addr, input string tag);
    check(cap_n > idx, $sformatf("%s: write %0d missing", tag, idx));
    if (cap_n > idx) begin
      check(cap_data[idx] === data,
            $sformatf("%s: write %0d data=%04h want %04h", tag, idx, cap_data[idx], data));
      check(cap_addr[idx] === addr,
            $sformatf("%s: write %0d addr=%0d want %0d", tag, idx, cap_addr[idx], addr));
    end
  endtask

  // ===================== the R3 cases =====================
  localparam logic [15:0] ST_OK = 16'd0, ST_BADFRAME = 16'd2, ST_RANGE = 16'd3,
                         ST_UNSUP = 16'd5, ST_NOTREADY = 16'd6;
  localparam logic [7:0] OP_STEP = 8'h21, OP_BPSET = 8'h22, OP_BPCLR = 8'h23,
                         OP_DBGSTAT = 8'h24, OP_STATUS = 8'h11;

  // Payload aliases: the common debug prefix is {status,state,pc,bp_addr,flags}
  // at rxf[4..8]; DEBUG_STATUS extends it with {run,a,x,y,insn}.
  task automatic dbg_prefix(input logic [15:0] want_state, input logic [15:0] want_pc,
                            input logic [15:0] want_addr, input logic [15:0] want_flags,
                            input string tag);
    check(rlen === 5 || rlen === 10, $sformatf("%s: payload len %0d", tag, rlen));
    check(rxf[5] === want_state, $sformatf("%s: state=%0d want %0d", tag, rxf[5], want_state));
    check(rxf[6] === want_pc,    $sformatf("%s: pc=%0d want %0d", tag, rxf[6], want_pc));
    check(rxf[7] === want_addr,  $sformatf("%s: bp_addr=%0d want %0d", tag, rxf[7], want_addr));
    check(rxf[8] === want_flags, $sformatf("%s: flags=%0d want %0d", tag, rxf[8], want_flags));
  endtask

  initial begin
    $dumpfile("tb_pe_ctrl_r3.vcd");
    $dumpvars(0, tb_pe_ctrl_r3);

    spi_sclk = 1'b0; spi_mosi = 1'b0; spi_cs_n = 1'b1; run = 1'b0;
    load_prog();
    cap_n = 0; rlen = 0;
    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    repeat (2) @(posedge clk); #1;

    // ============ C1: DEBUG_BP_SET readback (stopped) ============
    txp[0] = 16'h0002;
    exchange(OP_BPSET, 16'h2101, 4'h0, 1, 1'b0);
    check_status(ST_OK, "bp_set");
    dbg_prefix(16'd0, 16'd0, 16'd2, 16'd1, "bp_set");

    // ============ C2: past the end -> RANGE, no arming change ============
    txp[0] = 16'h0010;                    // WORDS=16: address 16 is out
    exchange(OP_BPSET, 16'h2102, 4'h0, 1, 1'b0);
    check_status(ST_RANGE, "bp_set range");
    check(rlen === 5, "bp_set range: payload len");
    check(rxf[8] === 16'd1, "bp_set range: flags must be unchanged (still armed)");
    check(rxf[7] === 16'd2, "bp_set range: address must be unchanged");

    // ============ C3: wrong payload length -> BAD_FRAME ============
    exchange(OP_BPSET, 16'h2103, 4'h0, 0, 1'b0);
    check_status(ST_BADFRAME, "bp_set len0");

    // ============ C3b: move the breakpoint OFF the step path ============
    // (the C1 arming at 2 would legitimately catch step 2 landing there; that
    // scenario has its own case below)
    exchange(OP_BPCLR, 16'h2104, 4'h0, 0, 1'b0);
    check_status(ST_OK, "pre-step bp_clr");
    txp[0] = 16'h0004;
    exchange(OP_BPSET, 16'h2105, 4'h0, 1, 1'b0);
    check_status(ST_OK, "pre-step re-arm at 4");
    check(rxf[7] === 16'd4, "pre-step: armed at 4");
    check(rxf[8] === 16'd1, "pre-step: armed, no hit");

    // ============ C4/C5/C6: the step sequence ============
    // Step 1 executes LDI A,0x55 at pc=0 -> pc=1, a=0x55, held at state 2.
    exchange(OP_STEP, 16'h2110, 4'h0, 0, 1'b0);
    check_status(ST_OK, "step1");
    dbg_prefix(16'd2, 16'd1, 16'd4, 16'd1, "step1");
    repeat (4) @(posedge clk); #1;
    check(u_cpu.dbg_pc === 8'd1, $sformatf("step1: cpu pc=%0d want 1", u_cpu.dbg_pc));
    check(u_cpu.dbg_a === 8'h55, $sformatf("step1: cpu a=%02h want 55", u_cpu.dbg_a));

    // Step 2 executes LDI A,0xAA at pc=1.
    exchange(OP_STEP, 16'h2111, 4'h0, 0, 1'b0);
    check_status(ST_OK, "step2");
    dbg_prefix(16'd2, 16'd2, 16'd4, 16'd1, "step2");
    repeat (4) @(posedge clk); #1;
    check(u_cpu.dbg_a === 8'hAA, $sformatf("step2: cpu a=%02h want AA", u_cpu.dbg_a));

    // Step 3 executes the NOP at pc=2: a is unchanged, pc=3.
    exchange(OP_STEP, 16'h2112, 4'h0, 0, 1'b0);
    check_status(ST_OK, "step3");
    dbg_prefix(16'd2, 16'd3, 16'd4, 16'd1, "step3");
    repeat (4) @(posedge clk); #1;
    check(u_cpu.dbg_a === 8'hAA, "step3: a unchanged by NOP");

    // DEBUG_STATUS: the common prefix plus run/a/x/y/insn.
    exchange(OP_DBGSTAT, 16'h2120, 4'h0, 0, 1'b0);
    check_status(ST_OK, "dbg_status held");
    check(rlen === 10, $sformatf("dbg_status: payload len %0d, want 10", rlen));
    check(rxf[5] === 16'd2, "dbg_status: state DEBUG_HOLD");
    check(rxf[6] === 16'd3, "dbg_status: pc");
    check(rxf[9] === 16'd0, "dbg_status: run strap is low");
    check(rxf[10] === 16'h00AA, "dbg_status: a");

    // ============ C7: step while free-running -> NOT_READY ============
    // A fresh start: the strap high and NO debug hold (the step cases above
    // left the core held, and a HELD core may be stepped even while run=1 --
    // that is the step-off-a-breakpoint path).
    rst_n = 0; repeat (4) @(posedge clk); #1; rst_n = 1;
    repeat (2) @(posedge clk); #1;
    run = 1'b1;
    repeat (2) @(posedge clk); #1;
    exchange(OP_STEP, 16'h2130, 4'h0, 0, 1'b0);
    check_status(ST_NOTREADY, "step while running");
    run = 1'b0;

    // ============ C8: the breakpoint stops a LIVE core (stop-before) ============
    rst_n = 0; repeat (4) @(posedge clk); #1; rst_n = 1;
    repeat (2) @(posedge clk); #1;
    txp[0] = 16'h0002;                    // arm at 2 again (reset cleared it)
    exchange(OP_BPSET, 16'h2140, 4'h0, 1, 1'b0);
    check_status(ST_OK, "live bp arm");
    run = 1'b1;
    wait (dbg_hold === 1'b1);
    repeat (2) @(posedge clk); #1;
    check(u_cpu.dbg_pc === 8'd2,
          $sformatf("live hit: cpu pc=%0d want 2 (stop BEFORE the instruction at the bp)",
                    u_cpu.dbg_pc));
    check(u_cpu.dbg_a === 8'hAA,
          $sformatf("live hit: a=%02h -- the LDI at 1 ran, nothing at 2 did", u_cpu.dbg_a));
    exchange(OP_DBGSTAT, 16'h2141, 4'h0, 0, 1'b0);
    check_status(ST_OK, "live hit status");
    check(rxf[5] === 16'd3, $sformatf("live hit: state=%0d want 3 (BP_HIT)", rxf[5]));
    check(rxf[6] === 16'd2, "live hit: pc is the breakpoint");
    check(rxf[8] === 16'd3, $sformatf("live hit: flags=%0d want 3", rxf[8]));
    check(rxf[9] === 16'd1, "live hit: the STRAP is still high");
    // ---- M3: the R2 STATUS opcode must also report the HIT state ----------
    // C12 covers STATUS in states 0/1 and C13 covers it in state 2, but the
    // live-hit case above reads DEBUG_STATUS (0x24). Before this case the R2
    // golden vectors and this TB never drove OP_STATUS while the core was in
    // BP_HIT, so a chip that reported the debug states correctly on 0x24 but
    // wrongly on 0x11 would have passed everything. The core is still held on
    // the breakpoint here, so this reads the same state through the other op.
    //
    // The R2 STATUS layout is {status, state, run, target, pc, a, x, y, ...}
    // (pe_ctrl.v:885-897) -- it does NOT carry bp_addr/flags; those belong to
    // the debug ops, and asserting them here would be asserting the wrong
    // contract. The state word is rxf[5], run is rxf[6], pc is rxf[8].
    exchange(OP_STATUS, 16'h2142, 4'h0, 0, 1'b0);
    check_status(ST_OK, "r2 status while BP_HIT");
    check(rxf[5] === 16'd3, $sformatf("r2 status BP_HIT: state=%0d want 3", rxf[5]));
    check(rxf[6] === 16'd1, $sformatf("r2 status BP_HIT: run=%0d want 1 (hit holds the core, not the strap)", rxf[6]));
    check(rxf[8] === 16'd2, $sformatf("r2 status BP_HIT: pc=%0d want 2", rxf[8]));

    // ============ C9: stepping off the breakpoint clears the hit ============
    exchange(OP_STEP, 16'h2150, 4'h0, 0, 1'b0);
    check_status(ST_OK, "step off bp");
    dbg_prefix(16'd2, 16'd3, 16'd2, 16'd1, "step off bp");
    repeat (4) @(posedge clk); #1;
    check(u_cpu.dbg_pc === 8'd3, "step off bp: cpu pc=3");

    // ============ C10: DEBUG_BP_CLR disarms and releases ============
    exchange(OP_BPCLR, 16'h2160, 4'h0, 0, 1'b0);
    check_status(ST_OK, "bp_clr");
    check(rlen === 5, "bp_clr: payload len");
    check(rxf[5] === 16'd1, $sformatf("bp_clr: state=%0d want 1 (RUNNING, strap high)", rxf[5]));
    check(rxf[7] === 16'd2, "bp_clr: echoes the address it cleared");
    check(rxf[8] === 16'd0, "bp_clr: flags cleared");
    // The response must not be the only evidence: the HOLD itself has to drop,
    // or the state word would be lying while the core stays frozen.
    check(dut.dbg_hold === 1'b0, "bp_clr: the debug hold must be released");
    // The program wraps (JMP 2 at address 4), so "resumed" means the PC MOVED,
    // not that it grew. Capture and compare.
    // The program is a short loop (LDI at 3, JMP 2 at 4, NOP at 2), so a
    // fixed-cycle comparison can alias. Watch a window instead: the PC must
    // LEAVE the value it was held at.
    begin
      bit moved;
      moved = 1'b0;
      for (int k = 0; k < 8; k++) begin
        @(posedge clk); #1;
        if (u_cpu.dbg_pc !== 8'd3) moved = 1'b1;
      end
      check(moved, "bp_clr: the core must resume (the PC never left the held value)");
    end

    // ============ C11: a bad CRC changes nothing ============
    run = 1'b0;
    rst_n = 0; repeat (4) @(posedge clk); #1; rst_n = 1;
    repeat (2) @(posedge clk); #1;
    txp[0] = 16'h0003;
    exchange(OP_BPSET, 16'h2170, 4'h0, 1, 1'b1);   // corrupt CRC
    check_status(ST_BADFRAME, "bad crc");
    exchange(OP_DBGSTAT, 16'h2171, 4'h0, 0, 1'b0);
    check_status(ST_OK, "after bad crc");
    check(rxf[8] === 16'd0, $sformatf("bad crc: flags=%0d want 0 (no side effect)", rxf[8]));
    check(rxf[7] === 16'd0, "bad crc: no address armed");

    // ============ C12: the STATUS state encoding ============
    exchange(OP_STATUS, 16'h2180, 4'h0, 0, 1'b0);
    check_status(ST_OK, "status stopped");
    check(rxf[5] === 16'd0, $sformatf("status: state=%0d want 0 (STOPPED)", rxf[5]));
    run = 1'b1;
    repeat (2) @(posedge clk); #1;
    exchange(OP_STATUS, 16'h2181, 4'h0, 0, 1'b0);
    check_status(ST_OK, "status running");
    check(rxf[5] === 16'd1, $sformatf("status: state=%0d want 1 (RUNNING)", rxf[5]));
    run = 1'b0;

    // ============ C13: the STATUS state field while HELD ============
    // The debug states must be distinguishable through the R2 opcode too, not
    // only through DEBUG_STATUS. A step holds the core; STATUS must say 2.
    exchange(OP_STEP, 16'h2190, 4'h0, 0, 1'b0);
    check_status(ST_OK, "status-while-held step");
    exchange(OP_STATUS, 16'h2191, 4'h0, 0, 1'b0);
    check_status(ST_OK, "status while held");
    check(rxf[5] === 16'd2, $sformatf("status-while-held: state=%0d want 2 (DEBUG_HOLD)", rxf[5]));
    check(rxf[6] === 16'd0, "status-while-held: run strap low");
    exchange(OP_BPCLR, 16'h2192, 4'h0, 0, 1'b0);   // release for tidiness
    check_status(ST_OK, "final release");

    if (errors == 0) $display("PASS: tb_pe_ctrl_r3");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: watchdog -- tb_pe_ctrl_r3 did not finish");
    $finish;
  end

endmodule
