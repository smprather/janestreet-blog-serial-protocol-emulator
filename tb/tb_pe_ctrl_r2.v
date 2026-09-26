// tb_pe_ctrl_r2.v — R2 read-path conformance against the gui-worker golden
// package (reviews/2026-09-25/r2-hex, commit 262a639), consumed through
// $readmemh so every request and response is compared BYTE-EXACTLY, CRC word
// included. Nothing here re-derives the expected bytes: the vectors ARE the
// acceptance spec, and a vector's `chip_confirmed` flag is the manager's to
// flip once this passes.
//
// WHY A SEPARATE TB. tb_pe_ctrl proves the protocol with a hand-built frame
// builder. This TB proves the SAME RTL against the HOST's bytes: the request
// stream comes from the golden .hex and the response stream is compared to the
// golden .hex. A disagreement about framing, ordering, the CRC, the status
// code, the payload layout or byte order cannot hide, because the bytes come
// from the other side of the interface.
//
// THE R2 WAIT-WORD CONTRACT (manager ruling 2026-09-25). A bounded read cannot
// answer inside the request's own bit times, so the chip drives 0xFFFF filler
// words while it fetches and the real frame starts at the first non-0xFFFF
// word. The golden response streams are UNCHANGED by this -- wait words are
// transport-level -- so the comparison is against the frame itself, taken
// after the leading fillers are skipped. Worst case is 15 filler words (a
// 15-word read is one round trip each).
//
// The far side of the read port is a MEMORY IMAGE, because the vectors were
// generated against a model whose instruction memory holds word i = 0x1000+i
// and whose data buffer holds 8*(i*0x11). Reproducing that CONTENT is the
// model's business; what the chip owes is the framing, the ordering, the
// bounds, the status, the byte order and the fault lifecycle -- and every one
// of those is compared byte-exactly below.
`timescale 1ns/1ps

module tb_pe_ctrl_r2;
  localparam int WORDS = 1024;
  localparam int DMEM_BYTES = 16;
  localparam int HALF_NS = 50;            // generous SPI rate, like tb_pe_ctrl
  localparam int MAX_WAIT_WORDS = 16;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
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
  logic [9:0]  dbg_next_pc;
  logic [7:0]  dbg_a, dbg_x, dbg_y, dbg_timer;
  logic [15:0] dbg_insn;

  // The architectural state the golden vectors expect: pc = 0x3FF (10 bits),
  // a/x/y = 0xFF, insn = 0xFFFF, timer = 7, target host, 3 words written.

  // The golden streams, read straight from the package, plus the run state
  // a vector asks for. Declared BEFORE the instance (Icarus binds
  // declaration before use).
  logic [7:0]  r2_req_mem [0:1023];
  logic [7:0]  r2_rsp_mem [0:1023];
  // The MODEL IMAGE, loaded from the golden package (imem.hex/dmem.hex)
  // and then overridden per vector by the manifest's sparse maps. The
  // read port serves THIS, so a data-path read is compared against the
  // bytes the host's own model held.
  logic [15:0] r2_imem_img [0:1023];
  logic [15:0] r2_imem     [0:1023];
  logic [7:0]  r2_dmem_img [0:15];
  logic [7:0]  r2_dmem     [0:15];
  logic        r2_run;

  // ---- the read-port model: the SoC's half of the contract ---------------
  logic        rd_pending, rd_pending_dmem, rd_valid;
  logic [15:0] rd_pending_addr;

  assign dbg_rd_data = rd_pending
      ? (rd_pending_dmem ? {8'h00, r2_dmem[rd_pending_addr[3:0]]}
                         : r2_imem[rd_pending_addr[9:0]])
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
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
    .dbg_insn(dbg_insn), .dbg_timer(dbg_timer),
    .dbg_next_pc(dbg_next_pc)
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
      q = spi_miso;
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

  task automatic check(input bit ok, input string what);
    if (!ok) begin $display("  FAIL: %s", what); errors = errors + 1; end
  endtask

  // Drive the request stream from the golden bytes, then read the response
  // back WORD by WORD, skipping LEADING 0xFFFF wait words, and compare every
  // remaining word -- CRC included -- against the golden response.
  task automatic r2_step(input int req_bytes, input int rsp_bytes,
                        input string tag, input logic [15:0] want_faults);
    int nwords, got, wait_seen;
    logic [15:0] w, golden;

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
        check(0, $sformatf("%s: word %0d = %04h, want %04h", tag, got, w,
                           golden));
      got = got + 1;
    end

    spi_cs_n = 1'b1; half_tick();
    repeat (8) @(posedge clk);
    // The post-step fault register is part of the contract too.
    if (faults !== want_faults)
      check(0, $sformatf("%s: faults = %04h, want %04h", tag, faults,
                         want_faults));
    $display("  [%s] %s", tag, (errors == 0) ? "PASS" : "FAIL");
    if (errors == 0) steps_passed = steps_passed + 1;
  endtask

  // The step table is a plain text file (tb/r2-vectors/r2_steps.txt), generated
  // from the gui-worker's manifest, read with $fgets/$sscanf so Icarus needs no
  // string arrays. Nothing about a vector is re-derived here: the file names
  // point at the golden .hex streams and the numbers are the manifest's.
  localparam int R2_NUM_STEPS = 22;


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

    r2_run = 1'b0;
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
  // (words_written=3) happens once per r2_run_all; this just clears faults
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

    r2_run = 1'b0;
    spi_cs_n = 1'b1; half_tick();
    spi_cs_n = 1'b0; half_tick();
    for (int k = 0; k < 6; k++) send_word(fr[k]);
    // 5 + rlen, not 4 + rlen (fixed 2026-09-25, manager-approved). CLEAR_FAULT
    // answers with TWO payload words (status, faults), so its frame on MISO is
    // 5 + 2 = 7 words: sync, header, sequence, length, two payload, CRC.
    //
    // This under-read was MASKED, which is exactly why it was dangerous: the
    // helper threw the 7th word away, leaving the chip one word from finishing
    // its response when the next CS_N fell -- so the NEXT frame's first word
    // was the tail of THIS one. It passed only because every R2 vector happens
    // to be preceded by a frame whose next read is a leading-filler skip, which
    // swallows the stray word. The R3 conformance harness (same helper shape)
    // hit it for real, with no filler to hide behind, and saw every frame
    // arrive skewed by one word.
    //
    // The evidence that this change is safe is the conformance result itself:
    // the suite is byte-exact, so 18/18 golden steps must still pass, and did
    // (before: 18/18, after: 18/18).
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

  // ---- THE HELD-CORE PRE-STATE (v09 / v10) -------------------------------
  //
  // WHY THIS EXISTS. The two vectors added by the gui-worker's held-core
  // package (reviews/2026-09-25/R2-HELD-STATUS-BYTES.md) report debug states 2
  // and 3 — the compatibility surface R2's 18 shipped steps never exercise, and
  // the chip review's MEDIUM 3. Those states need bp_en / bp_hit / dbg_hold_r,
  // which are INTERNAL registers of pe_ctrl, so a coreless testbench cannot
  // simply assign them.
  //
  // WHAT IS REAL AND WHAT IS MODELLED — the whole point of writing it down.
  //   REAL: the DEBUG_BP_SET decode, the arm, the hit detection (pe_ctrl.v:690,
  //   `bp_en && !dbg_hold_r && (run || dbg_step_r) && (dbg_next_pc ==
  //   bp_addr)`), the DEBUG_STEP hold, the state encoding, and the STATUS /
  //   DUMP_CORE response builders including the `if (run)` gate that makes
  //   step 22 refuse. Every bit of the state these steps read is produced by
  //   the RTL under test.
  //   MODELLED: the CPU itself. This TB has no pe_cpu (the read port is served
  //   from the package's memory IMAGE, which is what the 18 shipped steps
  //   compare against), so the core's own port dbg_next_pc — the landing
  //   address a real core presents — is driven by this testbench.
  //
  // WHY THAT IS NOT THE MEDIUM-2 DEFECT. The chip review's MEDIUM 2 is about a
  // testbench FORCING a pre-state the RTL cannot reach. Nothing here is forced:
  // the values on dbg_next_pc are the ones the package's OWN imem produces
  // (0x0041 LDI A,0x41 at 0, 0x1001 OUT at 1, 0x4002 JMP 2 at 2) after
  // executing the address the vector says it has, and tb_pe_ctrl_r3_conf proves
  // on a REAL pe_cpu that the same two states are reachable by these same
  // opcodes. This is the "drive it, don't force it" route the ask preferred;
  // had it not been reachable, the fallback was to force and RECORD it as
  // forced, and the difference is the difference between a conformance result
  // and a tautology.
  //
  // Each prep ASSERTS the state it just established against the host's
  // model_image.debug, so a prep that silently did nothing fails as
  // "pre-state not reached" instead of as a confusing word mismatch inside a
  // golden response.

  // One real framed request: a debug opcode with its payload, CRC computed the
  // same way the DUT computes it. `len` is the framing rule's own demand
  // (tools/gen/gen_r3_vectors.py OP_LEN, which is transcribed from pe_ctrl's
  // S_LEN): DEBUG_BP_SET carries one payload word, DEBUG_STEP none.
  task automatic r2_debug_req(input logic [7:0] op, input int len,
                              input logic [15:0] pay0, input int seq);
    logic [15:0] fr [0:5];
    logic [15:0] crc;
    int n;
    fr[0] = 16'hA55A;
    fr[1] = {4'h1, op, 4'h0};          // version, opcode, host target
    fr[2] = seq[15:0];
    fr[3] = len;
    fr[4] = pay0;
    n = 4 + len;                       // words before the CRC
    crc = 16'hFFFF;
    for (int k = 0; k < n; k++) crc = r2_crcw(crc, fr[k]);
    fr[n] = crc;
    spi_cs_n = 1'b1; half_tick();
    spi_cs_n = 1'b0; half_tick();
    for (int k = 0; k < n + 1; k++) send_word(fr[k]);
    spi_cs_n = 1'b1; half_tick();
    repeat (8) @(posedge clk);
  endtask

  // Read a debug opcode's response frame and check the status word. The frame
  // is 4 header words + rlen payload + 1 CRC, the same shape r2_clear_faults
  // established; ST_OK is 0, so a frame that did not arrive cleanly reads as
  // a failure here rather than as a mysterious mismatch later.
  task automatic r2_debug_rsp(input int rlen, input string tag);
    logic [15:0] w;
    logic [15:0] status;
    for (int k = 0; k < 4 + rlen + 1; k++) begin
      recv_word(w);
      if (k == 3) status = w;
    end
    if (status !== 16'h0000)
      check(0, $sformatf("prep %s: status = %04h, want 0000 (the opcode was not accepted)", tag, status));
  endtask

  // The state the prep just built, checked against the host's own
  // model_image.debug block. These read pe_ctrl's OWN registers and the state
  // wire, not the testbench's intentions -- a READ of the internals, never an
  // assignment to them. (The fv_* output taps would be the tidier way to say
  // this, but they exist only under `ifdef FORMAL`, and this conformance run
  // must exercise the shipping configuration, not the formal one.)
  task automatic r2_assert_pre_state(input int want_state, input bit want_hit,
                                      input bit want_hold, input string tag);
    check(dut.dbg_state === want_state[1:0],
          $sformatf("prep %s: dbg_state = %0d, want %0d", tag, dut.dbg_state, want_state));
    check(dut.bp_hit === want_hit,
          $sformatf("prep %s: bp_hit = %b, want %b", tag, dut.bp_hit, want_hit));
    check(dut.bp_en === 1'b1,
          $sformatf("prep %s: bp_en = %b, want 1 (the breakpoint must still be armed)", tag, dut.bp_en));
    check(dut.dbg_hold_r === want_hold,
          $sformatf("prep %s: dbg_hold_r = %b, want %b", tag, dut.dbg_hold_r, want_hold));
  endtask

  // A RELEASE first, on both preps, and the reason is an RTL-interface fact
  // the host's model abstraction hides. pe_ctrl's DEBUG_BP_CLR clears bp_en,
  // bp_hit AND dbg_hold_r; DEBUG_BP_SET clears bp_en and bp_hit but NOT
  // dbg_hold_r. So on a DUT that is already held, arming again cannot latch a
  // hit: pe_ctrl's hit condition is `bp_en && !dbg_hold_r && (run ||
  // dbg_step_r) && (dbg_next_pc == bp_addr)` (pe_ctrl.v:690) and the second
  // term is false. The first version of the v10 prep did exactly that and the
  // core sat at state 2 with bp_hit clear -- which the golden step then
  // reported as a word mismatch (state 0002, want 0003) rather than as the
  // pre-state failure it was. Each prep now starts from a defined released
  // state, so neither depends on what ran before it.
  task automatic r2_release_debug;
    r2_debug_req(8'h23, 0, 16'h0000, 16'h00C1);   // DEBUG_BP_CLR
    r2_debug_rsp(5, "BP_CLR");
    repeat (2) @(posedge clk);
    check(dut.dbg_hold_r === 1'b0 && dut.bp_en === 1'b0 && dut.bp_hit === 1'b0,
          "prep: DEBUG_BP_CLR did not release (hold/en/hit must all be clear)");
  endtask

  // v09 — the STEP-PAUSE hold (state 2): one DEBUG_STEP from the boot stop with
  // the strap low, breakpoint armed at 2. The core is at 0 and lands on 1, so
  // dbg_next_pc = 1 != bp_addr = 2 and the step leaves bp_hit clear — which is
  // the whole difference between state 2 and state 3. After it, a = 0x41 (the
  // LDI at 0 retired) and pc = 1, which is the pre-state the package states.
  task automatic r2_prep_hold_step_pause;
    r2_release_debug();
    dbg_pc = 10'h000; dbg_a = 8'h00; dbg_next_pc = 10'h001;
    r2_run = 1'b0;
    r2_debug_req(8'h22, 1, 16'h0002, 16'h00E1);   // DEBUG_BP_SET, address 2
    r2_debug_rsp(5, "v09 BP_SET");
    r2_debug_req(8'h21, 0, 16'h0000, 16'h00E2);   // DEBUG_STEP
    r2_debug_rsp(5, "v09 DEBUG_STEP");
    // The architectural state the step leaves behind, as the package states it.
    dbg_pc = 10'h001; dbg_a = 8'h41;
    repeat (2) @(posedge clk);
    r2_assert_pre_state(2, 1'b0, 1'b1, "v09 step-pause");
  endtask

  // v10 — the LIVE HIT (state 3): armed at 2, strap high, the core's next PC
  // lands on the breakpoint, and pe_ctrl latches the hit and holds the core on
  // the clock edge (pe_ctrl.v:690). Stop-BEFORE, so pc = 2 and the instruction
  // at 2 has not run — which is why a = 0x41 (the LDI at 0 retired) while pc
  // already reads 2. The run strap stays HIGH: the hit holds the core, it does
  // not drop the strap, and step 22 is the step that pins that.
  task automatic r2_prep_hold_bp_hit;
    r2_release_debug();
    dbg_pc = 10'h001; dbg_a = 8'h41; dbg_next_pc = 10'h002;
    r2_run = 1'b1;
    r2_debug_req(8'h22, 1, 16'h0002, 16'h00F1);   // DEBUG_BP_SET, address 2
    r2_debug_rsp(5, "v10 BP_SET");
    repeat (2) @(posedge clk);                     // the hit latches here
    dbg_pc = 10'h002;                              // stop-before: at 2, not past it
    r2_assert_pre_state(3, 1'b1, 1'b1, "v10 bp hit");
  endtask

  `include "../tb/r2-vectors/R2_CONFORMANCE_RUN.vh"

  initial begin
    $dumpfile("tb_pe_ctrl_r2.vcd");
    $dumpvars(0, tb_pe_ctrl_r2);

    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    repeat (2) @(posedge clk); #1;

    r2_run_all;
    $display("R2 conformance: %0d/%0d golden steps pass on the chip",
             steps_passed, R2_NUM_STEPS);
    if (errors == 0) $display("PASS: tb_pe_ctrl_r2");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("FAIL: watchdog — tb_pe_ctrl_r2 did not finish");
    $finish;
  end
endmodule
