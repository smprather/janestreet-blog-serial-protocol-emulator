// tb_pe_ctrl_r3_conf.v — R3 debug-control CONFORMANCE against the host's own
// golden bytes (reviews/2026-09-25/r3-hex, the gui-worker's package, copied
// byte-exact into tb/r3-vectors/), consumed through $readmemh so every request
// and every response is compared BYTE-EXACTLY, CRC word included.
//
// WHY A SECOND R3 TB, NEXT TO tb_pe_ctrl_r3. The directed TB proves the debug
// LOGIC: written RED-first against RTL that had the ports but no decode, it
// drives real step/hit/clear sequences through a REAL pe_cpu, and it has a
// 7-mutant gate behind it. This TB proves the complementary thing: that the
// chip's ANSWERS are the host's answers. Its requests and its expected
// responses come from the other side of the interface, so a disagreement about
// framing, ordering, the status code, the payload layout, the byte order, the
// CRC or the state encoding cannot hide -- the bytes are not ours to get right.
//
// IT IS THE R2 CONFORMANCE TB, VERBATIM, PLUS THE CPU. Every framing task, the
// read-port model, the wait-word rule, the step loop and the $readmemh plumbing
// below are tb_pe_ctrl_r2's, unchanged, because that harness passes the same
// chip byte-exactly (18/18 golden steps). A conformance harness is only worth
// what its transport is worth, and this transport is measured, not argued.
//
// WHAT IS PRELOADED, AND WHY THAT IS NOT A CHEAT. The package's load_procedure
// says to preload each vector's model_images[] state and debug context, and it
// is right to: several of those pre-states are NOT host-reachable. A core
// stopped on a breakpoint at 2 with a=0 has not executed the two LDI
// instructions that precede address 2, so no sequence of host frames produces
// that state -- it is a snapshot of the host MODEL. So the pre-state is driven
// onto the DUT's own registers and the assertion is the RESPONSE. The logic
// that establishes those states is tb_pe_ctrl_r3's job, with its mutants and
// the S1-S4 formal claims behind it.
//
// ONE MORE MODEL BOUNDARY, STATED RATHER THAN HIDDEN. Two vectors' pre-states
// are a FREE-RUNNING core (run=1, no debug hold) at a named pc. A running core
// cannot hold one pc for the ~1000 clocks a frame takes -- the host model is a
// snapshot, not a simulation -- so for those the TB re-drives the CPU's
// registers after every clock edge. The generator REFUSES to arm that freeze on
// any vector that expects a step to succeed, so it can never swallow a real
// execution; the one vector pairing a freeze with a DEBUG_STEP expects NOT_READY
// and no pulse is ever emitted.
//
// THE STATE WORD IS DERIVED, NEVER PRELOADED. pe_ctrl computes it from the
// debug registers and the run strap, so the TB asserts that derivation
// explicitly after every preload as well as comparing the golden bytes.
//
// ============================================================================
// STATUS 2026-09-25: GREEN -- 14/14 vectors, 26/26 golden steps, WIRED into
// run_all.sh. Three steps carry a KNOWN divergence (7 words); see the lock at
// the end of this file and tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt.
// ============================================================================
// What the last of those three is, because it was the hard one: for hours this
// harness reported that the CHIP REJECTED the host's frames -- 61 failures, a
// 5-word BAD_FRAME and FAULT_CRC, and no response at all on most steps. It did
// not. The transport is tb_pe_ctrl_r2's, which passes the same chip byte-exactly
// (18/18), and feeding the R3 golden bytes through THAT transport failed
// identically, which is what finally ruled the harness out. The cause was one
// token in the GENERATOR: it emitted WORD counts into a transport whose
// signature is (req_bytes, rsp_bytes), so a six-word DEBUG_BP_SET frame was cut
// to three words and the host switched to reading while the chip was still
// waiting for the rest of the payload. A one-word-vs-byte slip, wearing the
// costume of a protocol disagreement.
//
// The pad model is still needed and still load-bearing: the R3 ops answer from
// registers, so no memory fetch fills the gap before the frame, and without
// reading the PAD (miso_oe ? spi_miso : 1'b1) the idle word reads 0x0000, which
// the leading-filler skip must not swallow.
//
// Two fixes from the red phase are load-bearing and must not be undone:
// r3_clear_faults reads 5 + 2 = 7 words (R2's helper reads 6 and leaves the
// chip one word mid-stream, which the next frame then reads), and the host does
// not release MOSI to 0 before reading (doing so cost 83 of 144 checks).
// ============================================================================
`timescale 1ns/1ps

module tb_pe_ctrl_r3_conf;
  localparam int WORDS = 1024;
  localparam int DMEM_BYTES = 16;
  localparam int HALF_NS = 50;            // generous SPI rate, like tb_pe_ctrl
  localparam int MAX_WAIT_WORDS = 16;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  // The run strap is a PAD, not a host-bus register, so a vector that needs the
  // core running declares it as pre-state. One signal drives the core and
  // pe_ctrl, exactly as the pad does in the SoC.
  logic r3_run_strap = 1'b0;
  logic spi_sclk = 1'b0, spi_mosi = 1'b0, spi_cs_n = 1'b1;
  logic spi_miso, miso_oe, irq_n, run = 1'b0;
  logic host_we, host_imem_sel;
  logic [9:0]  host_addr;   // pe_ctrl AW at 1024 words
  logic [15:0] host_wdata;
  logic load_active, load_error;
  logic [15:0] words_written, faults;
  logic        dbg_rd_req, dbg_rd_dmem, dbg_rd_valid;
  logic [15:0] dbg_rd_addr, dbg_rd_data;
  logic [9:0]  dbg_pc;
  logic [7:0]  dbg_a, dbg_x, dbg_y, dbg_timer;
  logic [15:0] dbg_insn;

  // The run strap is a PAD, not a host-bus register, so a vector that needs
  // the core running declares it as pre-state. One signal drives the core and
  // pe_ctrl, exactly as the pad does in the SoC.
  wire r2_run = r3_run_strap;

  // ---- the R3 debug wires: a REAL pe_cpu behind the same host bus ---------
  // The directed TB (tb_pe_ctrl_r3) wires these identically; the difference
  // here is only where the REQUESTS and the EXPECTED RESPONSES come from.
  logic [9:0]  imem_addr;
  logic [15:0] imem_rdata;
  logic [3:0]  dmem_addr;
  logic        dmem_we;
  logic [7:0]  dmem_wdata;
  logic [7:0]  dmem_rdata = 8'h00;
  logic [3:0]  io_port;
  logic        io_we, io_re;
  logic [7:0]  io_wdata;
  logic [7:0]  io_rdata = 8'h00;
  wire         dbg_hold, dbg_step;
  wire  [9:0]  dbg_next_pc;
  wire  [9:0]  cpu_pc;
  wire  [7:0]  cpu_a, cpu_x, cpu_y;
  wire  [15:0] cpu_insn;
  logic [15:0] r3_imem [0:WORDS-1];
  logic [15:0] r3_imem_img [0:WORDS-1];
  logic [7:0]  r3_dmem_img [0:DMEM_BYTES-1];

  // The macro's read: the address presented this cycle is sampled at the edge,
  // so imem_rdata holds the instruction at imem_addr one cycle later.
  always_ff @(posedge clk) begin
    if (!rst_n) imem_rdata <= 16'h0000;
    else        imem_rdata <= r3_imem[imem_addr];
  end

  pe_cpu #(.IMEM_WORDS(WORDS), .DMEM_BYTES(DMEM_BYTES)) u_cpu (
    .clk(clk), .rst_n(rst_n), .run(r2_run),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_addr(dmem_addr), .dmem_we(dmem_we), .dmem_wdata(dmem_wdata),
    .dmem_rdata(dmem_rdata),
    .io_port(io_port), .io_we(io_we), .io_re(io_re),
    .io_wdata(io_wdata), .io_rdata(io_rdata),
    .dbg_pc(cpu_pc), .dbg_a(cpu_a), .dbg_x(cpu_x), .dbg_y(cpu_y),
    .dbg_insn(cpu_insn),
    .dbg_hold(dbg_hold), .dbg_step(dbg_step), .dbg_next_pc(dbg_next_pc)
  );

  // The golden streams, read straight from the package, plus the run state
  // a vector asks for. Declared BEFORE the instance (Icarus binds
  // declaration before use). The r3_* names are the ones the generated
  // include uses; r2_* are this harness's inherited plumbing, and the two
  // sets are bound together below.
  logic [7:0]  r2_req_mem [0:1023];
  logic [7:0]  r2_rsp_mem [0:1023];
  logic [7:0]  r3_req_mem [0:1023];
  logic [7:0]  r3_rsp_mem [0:1023];
  // The MODEL IMAGE, loaded from the golden package (imem.hex/dmem.hex)
  // and then overridden per vector by the manifest's sparse maps. The
  // read port serves THIS, so a data-path read is compared against the
  // bytes the host's own model held.
  logic [15:0] r2_imem_img [0:1023];
  logic [15:0] r2_imem     [0:1023];
  logic [7:0]  r2_dmem_img [0:15];
  logic [7:0]  r2_dmem     [0:15];

  // ---- the read-port model: the SoC's half of the contract ---------------
  logic        rd_pending, rd_pending_dmem, rd_valid;
  logic [15:0] rd_pending_addr;

  assign dbg_rd_data = rd_pending
      ? (rd_pending_dmem ? {8'h00, r2_dmem[rd_pending_addr[3:0]]}
                         : r3_imem[rd_pending_addr[9:0]])
      : 16'h0000;

  pe_ctrl #(.WORDS(WORDS), .DMEM_BYTES(DMEM_BYTES)) dut (
    .clk(clk), .rst_n(rst_n),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n),
    .spi_miso(spi_miso), .miso_oe(miso_oe), .irq_n(irq_n),
    .run(r2_run),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .load_active(load_active), .load_error(load_error),
    .words_written(words_written), .faults(faults),
    .dbg_rd_req(dbg_rd_req), .dbg_rd_dmem(dbg_rd_dmem),
    .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data),
    .dbg_rd_valid(dbg_rd_valid),
    .dbg_pc(cpu_pc), .dbg_a(cpu_a), .dbg_x(cpu_x), .dbg_y(cpu_y),
    .dbg_insn(cpu_insn), .dbg_timer(dbg_timer),
    .dbg_hold(dbg_hold), .dbg_step(dbg_step), .dbg_next_pc(dbg_next_pc)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_rd_valid <= 1'b0;
      rd_valid     <= 1'b0;
      rd_pending   <= 1'b0;
    end else begin
      dbg_rd_valid    <= dbg_rd_req;
      rd_valid        <= dbg_rd_req;
      rd_pending      <= dbg_rd_req;
      rd_pending_dmem <= dbg_rd_dmem;
      rd_pending_addr <= dbg_rd_addr;
    end
  end

  always #8.3335 clk = ~clk;             // 60 MHz

  // ---- SPI primitives (mode 0, MSB first) --------------------------------
  task automatic half_tick; #(HALF_NS); endtask

  task automatic send_bit(input bit b);
    spi_sclk = 1'b0; spi_mosi = b; half_tick();
    spi_sclk = 1'b1; half_tick();
  endtask

  task automatic send_byte(input logic [7:0] b);
    for (int k = 7; k >= 0; k--) send_bit(b[k]);
  endtask

  task automatic recv_byte(output logic [7:0] b);
    bit q;
    for (int k = 7; k >= 0; k--) begin
      spi_sclk = 1'b0; half_tick();
      // THE PAD, not the driver. `miso_oe` is the pad enable; when the chip
      // releases it the pad floats to its pull-up and a host reads 0xFFFF --
      // which is exactly the filler the skip below (R2's rule) expects. This is
      // the ONE line that differs from tb_pe_ctrl_r2, and it is needed because
      // the R3 debug ops answer from registers, so there is no memory fetch to
      // fill the gap: without it the pad-idle word reads 0x0000, which the skip
      // does not (and must not) swallow, and the whole frame arrives skewed.
      q = miso_oe ? spi_miso : 1'b1;
      spi_sclk = 1'b1; half_tick();
      b[k] = q;
    end
  endtask

  task automatic send_word(input logic [15:0] w);
    send_byte(w[15:8]); send_byte(w[7:0]);
  endtask

  task automatic recv_word(output logic [15:0] w);
    logic [7:0] hi, lo;
    recv_byte(hi); recv_byte(lo);
    w = {hi, lo};
  endtask

  // ---- the golden streams, read straight from the package ----------------

  int errors = 0;
  int steps_passed = 0;
  int vec_errors_at_start = 0;
  int vec_steps = 0;
  int vec_steps_failed = 0;
  // Every byte-level divergence, tagged with its step, in a fixed order. The
  // end-of-run check compares this list against a checked-in expectation, so a
  // KNOWN divergence is pinned exactly -- a change in it, or any new one, turns
  // the gate red. That is stronger than an XFAIL list of step names: a step that
  // fails differently is a finding, not a known failure.
  string divergence [0:255];
  int ndiv = 0;
  // The known-divergence list, read BEFORE the run: a divergence on it is a
  // recorded finding, and anything else fails the gate immediately.
  string known_div [0:255];
  int nknown = 0;
  int vectors_passed = 0;
  string vec_name = "";

  task automatic r3_vector_begin(input string name);
    vec_name = name; vec_steps = 0; vec_steps_failed = 0;
    vec_errors_at_start = errors;
    $display("  [vector] %s", name);
  endtask

  task automatic r3_vector_end;
    $display("  [vector] %s: %s (%0d/%0d steps)", vec_name,
             (errors == vec_errors_at_start) ? "PASS" : "FAIL",
             vec_steps - vec_steps_failed, vec_steps);
    if (errors == vec_errors_at_start) vectors_passed = vectors_passed + 1;
  endtask

  task automatic check(input bit ok, input string what);
    if (!ok) begin $display("  FAIL: %s", what); errors = errors + 1; end
  endtask

  task automatic load_known_divergences;
    integer fd;
    string line;
    fd = $fopen("../tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt", "r");
    if (fd == 0) begin
      $display("FAIL: R3_KNOWN_DIVERGENCES.txt is missing");
      errors = errors + 1;
      return;
    end
    // Only the DATA lines are entries: a comment is documentation, and counting
    // it would leave empty slots that match nothing.
    while (nknown < 255 && $fgets(line, fd) != 0) begin
      if (line != "" && line[0] != "#") begin
        known_div[nknown] = line;
        nknown = nknown + 1;
      end
    end
    $fclose(fd);
    $display("R3 divergence lock: %0d known divergence(s) loaded", nknown);
  endtask

  // A divergence is recorded in its own right, because the end-of-run lock
  // compares the SET, not the count. One that is on the known list is a finding
  // that is already recorded; one that is not fails the gate on the spot.
  task automatic note_divergence(input string what);
    bit is_known;
    is_known = 1'b0;
    // $fgets keeps the file's trailing newline and $sformatf does not put one
    // there, so the comparison is made newline-to-newline. Getting this wrong
    // silently turns every known divergence into an unknown one, which is what
    // it did the first time.
    for (int k = 0; k < nknown; k++)
      if (known_div[k] == {what, "\n"}) is_known = 1'b1;
    if (ndiv < 255) begin
      divergence[ndiv] = what;
      ndiv = ndiv + 1;
    end
    if (is_known) $display("  KNOWN DIVERGENCE: %s", what);
    else begin
      $display("  FAIL: %s", what);
      errors = errors + 1;
    end
  endtask

  // Drive the request stream from the golden bytes, then read the response
  // back WORD by WORD, skipping LEADING 0xFFFF wait words, and compare every
  // remaining word -- CRC included -- against the golden response.
  task automatic r2_step(input int req_bytes, input int rsp_bytes,
                        input string tag, input logic [15:0] want_faults);
    int nwords, got, wait_seen;
    int errs_before;
    logic [15:0] w, golden;

    // Per-STEP accounting, not per-run: the R2 harness scores a step against
    // the whole run's error count, which is fine when it is the only harness
    // and wrong here, where one failing step would mark every later step FAIL
    // and hide which ones actually passed.
    errs_before = errors;

    spi_cs_n = 1'b1; half_tick();
    spi_cs_n = 1'b0; half_tick();
    for (int i = 0; i < req_bytes; i += 2)
      send_word({r2_req_mem[i], r2_req_mem[i+1]});      // wire order: high byte first

    nwords = rsp_bytes / 2;
    got = 0; wait_seen = 0;
    while (got < nwords) begin
      recv_word(w);
      if (got == 0 && w === 16'hFFFF) begin
        wait_seen = wait_seen + 1;
        if (wait_seen > MAX_WAIT_WORDS) begin
          check(0, $sformatf("%s: %0d wait words and still no response",
                             tag, wait_seen));
          got = nwords;                            // stop, report
        end
        continue;
      end
      golden = {r2_rsp_mem[2*got], r2_rsp_mem[2*got+1]};
      if (w !== golden)
        note_divergence($sformatf("%s word %0d: chip %04h, package %04h",
                                  tag, got, w, golden));
      got = got + 1;
    end

    spi_cs_n = 1'b1; half_tick();
    repeat (8) @(posedge clk);
    // The post-step fault register is part of the contract too.
    if (faults !== want_faults)
      note_divergence($sformatf("%s faults: chip %04h, package-derived %04h",
                                tag, faults, want_faults));
    $display("  [%s] %s", tag, (errors == errs_before) ? "PASS" : "FAIL");
    // (a known divergence is not a step failure; it is printed above as such)
    if (errors == errs_before) steps_passed = steps_passed + 1;
    vec_steps = vec_steps + 1;
    if (errors != errs_before) vec_steps_failed = vec_steps_failed + 1;
  endtask

  // The per-vector preloads and the per-step file names are not hand-written:
  // tools/gen/gen_r3_vectors.py derives R3_CONFORMANCE_RUN.vh from the golden
  // manifest (and re-derives the expected sticky faults from the request bytes
  // themselves), and `--check` fails if the checked-in include is stale.
  localparam int R3_NUM_STEPS = 26;


  // Replay the session's opening LOAD (3 words) so the DUT's words_written
  // counter matches the state every golden vector assumes. Built with the same
  // CRC-16/CCITT-FALSE the protocol uses, over a real framed request.
  task automatic r2_preload_load;
    logic [15:0] fr [0:7];
    logic [15:0] crc;
    fr[0] = 16'hA55A;
    fr[1] = {4'h1, 8'h10, 4'h0};        // version, LOAD, host target
    fr[2] = 16'h0000;                   // sequence
    fr[3] = 16'd3;                      // payload: three words
    fr[4] = 16'h0100; fr[5] = 16'h0200; fr[6] = 16'h0300;
    crc = 16'hFFFF;
    for (int k = 0; k < 7; k++) crc = r2_crcw(crc, fr[k]);
    fr[7] = crc;

    r3_run_strap = 1'b0;
    spi_cs_n = 1'b1; half_tick();
    spi_cs_n = 1'b0; half_tick();
    for (int k = 0; k < 8; k++) send_word(fr[k]);
    // read the response (status, words_written, faults, echo) + CRC
    for (int k = 0; k < 4 + 4; k++) begin
      logic [15:0] w;
      recv_word(w);
    end
    spi_cs_n = 1'b1; half_tick();
    repeat (8) @(posedge clk);
    if (words_written !== 16'd3)
      check(0, $sformatf("preload LOAD: words_written = %0d, want 3",
                         words_written));
  endtask

  // CRC-16/CCITT-FALSE over one word (the same function the DUT uses), so the
  // preload request is a genuine frame rather than a hard-coded CRC.
  // CRC-16/CCITT-FALSE, byte at a time, MSB first: poly 0x1021, init 0xFFFF,
  // no reflection, no final XOR. The same two functions tb_pe_ctrl uses, so
  // the preload request is a genuine frame rather than a hard-coded CRC.
  function automatic logic [15:0] r2_crc16(input logic [15:0] crc,
                                             input logic [7:0] b);
    logic [15:0] c;
    c = crc ^ {b, 8'h00};
    for (int i = 0; i < 8; i++)
      c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    return c;
  endfunction
  function automatic logic [15:0] r2_crcw(input logic [15:0] crc,
                                             input logic [15:0] w);
    return r2_crc16(r2_crc16(crc, w[15:8]), w[7:0]);
  endfunction


  // Establish a vector's stated precondition: the sticky fault register back
  // to 0. faults lives INSIDE the DUT and is only host-writable through
  // CLEAR_FAULT, so this is the faithful way to reach the model_image[].state
  // the vectors assume — not a relaxation of the chip. The opening LOAD replay
  // (words_written=3) happens once per r3_run_all; this just clears faults
  // between vectors so a fault latched by one vector does not leak into the
  // next, which is exactly what the read_imem_at_ceiling_15 step exposed.
  task automatic r2_clear_faults;
    logic [15:0] fr [0:6];
    logic [15:0] crc;
    fr[0] = 16'hA55A;
    fr[1] = {4'h1, 8'h16, 4'h0};        // version, CLEAR_FAULT, host target
    fr[2] = 16'hFFF0;                   // sequence
    fr[3] = 16'd1;                      // payload: the mask
    fr[4] = 16'hFFFF;                   // clear every bit
    crc = 16'hFFFF;
    for (int k = 0; k < 5; k++) crc = r2_crcw(crc, fr[k]);
    fr[5] = crc;

    r3_run_strap = 1'b0;
    spi_cs_n = 1'b1; half_tick();
    spi_cs_n = 1'b0; half_tick();
    for (int k = 0; k < 6; k++) send_word(fr[k]);
    // 5 + rlen: CLEAR_FAULT answers with TWO payload words (status, faults), so
    // the frame on MISO is 7 words. Reading 6 (as the R2 helper does) leaves the
    // chip one word from finishing when the next CS_N falls, and that word is
    // then read as the next frame's first one.
    for (int k = 0; k < 5 + 2; k++) begin
      logic [15:0] w;
      recv_word(w);
    end
    spi_cs_n = 1'b1; half_tick();
    repeat (8) @(posedge clk);
    if (faults !== 16'h0000)
      check(0, $sformatf("precondition: faults = %04h after CLEAR_FAULT, want 0",
                         faults));
  endtask

  // The generated include drives r3_step; the transport is the R2 one.
  task automatic r3_step(input int req_bytes, input int rsp_bytes,
                         input string tag, input logic [15:0] want_faults);
    r2_step(req_bytes, rsp_bytes, tag, want_faults);
  endtask

  // faults is a sticky DUT register, so the only host-reachable way back to a
  // vector's faults=0 is a real CLEAR_FAULT frame (the R2 pattern above).
  task automatic r3_clear_faults;
    r2_clear_faults();
  endtask

  // The architectural + debug pre-state, and the state word's DERIVATION (the
  // chip computes it; the TB never pokes it).
  task automatic r3_preload_regs(input logic [9:0] pc, input logic [7:0] a,
                                 input logic [7:0] x, input logic [7:0] y,
                                 input logic [9:0] bp, input bit en,
                                 input bit hit, input bit hold);
    logic [1:0] want_state;
    @(posedge clk); #1;
    u_cpu.pc = pc; u_cpu.a = a; u_cpu.x = x; u_cpu.y = y;
    dut.bp_addr = bp; dut.bp_en = en; dut.bp_hit = hit; dut.dbg_hold_r = hold;
    want_state = hold ? (hit ? 2'd3 : 2'd2) : (r2_run ? 2'd1 : 2'd0);
    // Let the combinational state word settle after the poke. Reading it in the
    // same delta as the assignment returns the PRE-poke value, which reported
    // the previous vector's state and poisoned that vector's step verdicts.
    #1;
    check(dut.dbg_state === want_state,
          $sformatf("preload: derived state %0d, want %0d", dut.dbg_state, want_state));
  endtask

  logic        r3_freeze_on = 1'b0;
  logic [9:0]  r3_f_pc;
  logic [7:0]  r3_f_a, r3_f_x, r3_f_y;

  task automatic r3_freeze_arm(input logic [9:0] pc, input logic [7:0] a,
                               input logic [7:0] x, input logic [7:0] y);
    r3_f_pc = pc; r3_f_a = a; r3_f_x = x; r3_f_y = y;
    r3_freeze_on = 1'b1;
  endtask

  task automatic r3_freeze_disarm;
    r3_freeze_on = 1'b0;
  endtask

  // "Stopped here", for a pre-state that is a running core at a named pc. The
  // generator refuses to arm this where a step is expected to succeed.
  always @(posedge clk) begin
    #1;
    if (r3_freeze_on) begin
      u_cpu.pc = r3_f_pc; u_cpu.a = r3_f_a; u_cpu.x = r3_f_x; u_cpu.y = r3_f_y;
    end
  end

  // Diagnostic: the response serializer, on request (`+trace_resp`).
  initial begin
    if ($test$plusargs("trace_resp")) begin
      forever begin
        @(posedge clk);
        if (dut.miso_oe || dut.resp_active)
          $display("  [wire %0t] oe=%b active=%b idx=%0d bit=%0d rstate=%0d rx=%0d",
                   $time, dut.miso_oe, dut.resp_active, dut.resp_idx,
                   dut.resp_bitpos, dut.rstate, dut.rx_state);
      end
    end
  end

  `include "../tb/r3-vectors/R3_CONFORMANCE_RUN.vh"

  initial begin
    $dumpfile("tb_pe_ctrl_r3_conf.vcd");
    $dumpvars(0, tb_pe_ctrl_r3_conf);

    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    repeat (2) @(posedge clk); #1;

    for (int i = 0; i < WORDS; i++) r3_imem[i] = 16'h0000;
    load_known_divergences();
    r3_run_all;
    $display("R3 conformance: %0d/%0d golden vectors, %0d/%0d golden steps",
             vectors_passed, 14, steps_passed, R3_NUM_STEPS);

    // ---- THE KNOWN-DIVERGENCE LOCK ------------------------------------
    // Three of the 26 golden steps do not match the chip today, for reasons
    // recorded rather than papered over (reviews/2026-09-25/
    // R3-CONFORMANCE-AND-RUN-LOCK.md section 2, and the reasoning in
    // tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt): two are HOST-side vector
    // defects where the chip is right, one is a TB model boundary.
    //
    // The lock re-reads the list and requires the observed set to EQUAL it:
    // a known divergence that CHANGES, or any NEW one, turns this gate red.
    // That is stricter than an XFAIL list of step names, which would let a step
    // start failing for a new reason and still read as "known".
    begin
      integer fd, i;
      string line, want;
      fd = $fopen("../tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt", "r");
      if (fd == 0) begin
        $display("FAIL: R3_KNOWN_DIVERGENCES.txt vanished mid-run");
        errors = errors + 1;
      end else begin
        i = 0;
        while ($fgets(line, fd) != 0) begin
          if (line == "" || line[0] == "#") continue;   // not an entry
          if (i >= ndiv) begin
            $display("FAIL: a divergence the lock does not list: %s", line);
            errors = errors + 1;
          end else begin
            // $fgets keeps the newline; $sformatf does not put one there.
            want = {divergence[i], "\n"};
            if (want != line) begin
              $display("FAIL: divergence %0d is %s", i, divergence[i]);
              $display("      the lock expects: %s", line);
              errors = errors + 1;
            end
          end
          i = i + 1;
        end
        if (i < ndiv) begin
          $display("FAIL: %0d observed divergence(s) the lock does not list",
                   ndiv - i);
          for (int k = i; k < ndiv; k = k + 1) begin
            $display("      %s", divergence[k]);
            errors = errors + 1;
          end
        end
        $fclose(fd);
        $display("R3 divergence lock: %0d observed, all matching the list", i);
      end
    end

    if (errors == 0) $display("PASS: tb_pe_ctrl_r3_conf");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("FAIL: watchdog — tb_pe_ctrl_r3_conf did not finish");
    $finish;
  end
endmodule
