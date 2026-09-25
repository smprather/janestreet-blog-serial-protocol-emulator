// tb_pe_ctrl.v — the R1 framed PE host protocol, at the host's side of the wire.
//
// WHAT THIS PROVES (phase R1, wiki/plans/host-controller-gui.md "PE host
// protocol", phased per reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md):
//
//   * frame decode: sync 16'hA55A, {version,opcode,target}, sequence, payload
//     length, payload, CRC-16/CCITT-FALSE (poly 16'h1021, init 16'hFFFF);
//   * every R1 opcode: PING 0x01, LOAD 0x10, STATUS 0x11, CLEAR_FAULT 0x16,
//     TARGET 0x20; response opcodes set bit 7 and echo sequence and target;
//   * status codes 0=OK 1=BUSY 2=BAD_FRAME 3=RANGE 4=FAULT 5=UNSUPPORTED
//     6=NOT_READY, first response payload word;
//   * the A1 echo semantics, transferred into the framed LOAD response:
//     per-word commit (every payload word lands on host_we), final-word echo
//     for a full image, and an aborted word never commits, counts or echoes;
//   * run gating: LOAD while run=1 answers NOT_READY with no fault; a run
//     rising inside a load aborts the queued word (FAULT + FAULT_LOAD) and
//     nothing resurrects when run falls;
//   * IRQ_N: active low, high when no sticky fault, low after a fault, and
//     sticky until CLEAR_FAULT (a STATUS read does not clear it);
//   * target 1: a deterministic loopback responder (PING -> OK + 0x10C0;
//     TARGET -> OK + caps) on the same MISO, no pads; unknown targets and
//     unknown opcodes answer UNSUPPORTED without a fault;
//   * MISO ownership: miso_oe is low when idle, high only while a response is
//     being shifted, and released again; mode-0 changes happen on falling
//     edges, so the pre-sampling stability checks below must hold.
//
// The TB never inspects pe_ctrl internals except the two run-abort windows
// (dut.word_ready / dut.wstate), which exist to place `run` exactly where the
// contract's abort rule is exercised.

`timescale 1ns / 1ps

module tb_pe_ctrl;

  localparam int  WORDS   = 16;           // small: the oversize case runs here
  localparam real CLK_NS  = 1e9 / 60e6;   // 60 MHz, the locked operating point
  localparam real HALF_NS = 100.0;        // 5 MHz SCLK: the host guard rate

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic spi_sclk, spi_mosi, spi_cs_n, run;
  wire  spi_miso, miso_oe, irq_n;
  wire  host_we, host_imem_sel, load_active, load_error;
  wire [7:0]  host_addr;                  // WORDS=16 -> IAW=4, clamped to 8
  wire [15:0] host_wdata, words_written, faults;

  // ---- R2 read-port model (the SoC's half of the contract) ---------------
  // One cycle of latency, one word for imem and one byte for dmem, exactly as
  // pe_soc implements it. The read path is held in flight until a request
  // arrives, so a dropped or doubled strobe shows up as a wrong answer rather
  // than as silence.
  logic        dbg_rd_req, dbg_rd_dmem, dbg_rd_valid;
  logic [15:0] dbg_rd_addr, dbg_rd_data;
  logic [9:0]  dbg_pc;
  logic [7:0]  dbg_a, dbg_x, dbg_y, dbg_timer;
  logic [15:0] dbg_insn;
  logic [15:0] model_imem [0:WORDS-1];
  logic [7:0]  model_dmem [0:15];
  logic        rd_pending;
  logic        rd_pending_dmem;
  logic        rd_valid;
  logic [15:0] rd_pending_addr;

  assign dbg_rd_data = rd_pending
      ? (rd_pending_dmem ? {8'h00, model_dmem[rd_pending_addr[3:0]]}
                         : model_imem[rd_pending_addr[9:0]])
      : 16'h0000;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_valid <= 1'b0;
      rd_pending <= 1'b0;
      for (int i = 0; i < WORDS; i++) model_imem[i] <= 16'h0000;
      for (int i = 0; i < 16; i++)  model_dmem[i] <= 8'h00;
    end else begin
      dbg_rd_valid <= dbg_rd_req;
      rd_valid     <= dbg_rd_req;
      rd_pending   <= dbg_rd_req;         // the answer lands next cycle
      rd_pending_dmem <= dbg_rd_dmem;
      rd_pending_addr <= dbg_rd_addr;
    end
  end

  pe_ctrl #(.WORDS(WORDS)) dut (
    .clk(clk), .rst_n(rst_n),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n),
    .spi_miso(spi_miso), .miso_oe(miso_oe), .irq_n(irq_n),
    .run(run),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .load_active(load_active), .load_error(load_error),
    .words_written(words_written), .faults(faults),
    // R2: the read port and the architectural registers. This unit TB models
    // the SoC side with a tiny imem/dmem so the opcodes can be checked
    // WITHOUT a CPU; the integrated path is tb_tt_um_protocol_emulator's.
    .dbg_rd_req(dbg_rd_req), .dbg_rd_dmem(dbg_rd_dmem),
    .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data),
    .dbg_rd_valid(dbg_rd_valid),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
    .dbg_insn(dbg_insn), .dbg_timer(dbg_timer)
  );

  // Captured DUMP_CORE header for the word-for-word comparison below.
  logic [15:0] dump_words [0:10];

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

  initial begin
    $dumpfile("tb_pe_ctrl.vcd");
    $dumpvars(0, tb_pe_ctrl);

    spi_sclk = 1'b0; spi_mosi = 1'b0; spi_cs_n = 1'b1; run = 1'b0;
    cap_n = 0; writes_while_run = 0;
    rlen = 0;
    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    // Seed the read model so the R2 reads answer with KNOWN contents (and
    // the STATUS pc field is deterministic). This is a MODEL, not the chip:
    // the integrated path is tb_tt_um_protocol_emulator.
    dbg_pc = 10'd7; dbg_a = 8'h11; dbg_x = 8'h22; dbg_y = 8'h33;
    dbg_timer = 8'h44; dbg_insn = 16'hBEEF;
    for (int i = 0; i < WORDS; i++) model_imem[i] = 16'h1000 + i[15:0];
    for (int i = 0; i < 16; i++)       model_dmem[i] = 8'(i * 8'h11);
    repeat (2) @(posedge clk); #1;

    // ================= 1: IDLE + PING + response CRC ====================
    check(irq_n === 1'b1, "idle: irq_n default high");
    check(miso_oe === 1'b0, "idle: MISO released");
    check(faults === 16'h0000, "idle: no faults");
    exchange(8'h01, 16'h0007, 4'h0, 0, 1'b0);
    check_status(16'd0, "ping");
    check(rlen === 1, $sformatf("ping: payload len %0d, want 1", rlen));
    check(irq_n === 1'b1, "ping: no fault -> irq high");

    // ================= 2: LOAD — writes, count, echo ====================
    cap_n = 0; run = 1'b0;
    txp[0] = 16'hA55A; txp[1] = 16'h1234; txp[2] = 16'hF00D;
    exchange(8'h10, 16'h0100, 4'h0, 3, 1'b0);
    check_status(16'd0, "load");
    check(rlen === 4, $sformatf("load: payload len %0d, want 4", rlen));
    check(rxf[5] === 16'd3, "load: words_written");
    check(rxf[6] === 16'h0000, "load: no faults");
    check(rxf[7] === 16'hF00D, "load: final-word echo");
    check(cap_n === 3, $sformatf("load: %0d writes, want 3", cap_n));
    check_write(0, 16'hA55A, 0, "load");
    check_write(1, 16'h1234, 1, "load");
    check_write(2, 16'hF00D, 2, "load");
    check(words_written === 16'd3, "load: words_written port");
    check(host_imem_sel === 1'b1, "load: imem selected");

    // ================= 3: a full WORDS-word image =======================
    cap_n = 0;
    for (int k = 0; k < WORDS; k++) txp[k] = 16'h1000 + k[15:0];
    exchange(8'h10, 16'h0101, 4'h0, WORDS, 1'b0);
    check_status(16'd0, "full load");
    check(rxf[5] === WORDS[15:0], "full load: words_written");
    check(rxf[7] === (16'h1000 + (WORDS-1)),
          $sformatf("full load: echo = %04h, want %04h", rxf[7], 16'h1000 + (WORDS-1)));
    check(cap_n === WORDS, $sformatf("full load: %0d writes, want %0d", cap_n, WORDS));
    // A LOAD is an image from address 0: the address counter must restart on
    // the LOAD header, not continue from the previous session (a bring-up
    // defect this check now pins).
    check_write(0, 16'h1000, 0, "full load");
    check_write(WORDS-1, 16'h1000 + (WORDS-1), WORDS-1, "full load");

    // ================= 4: oversize -> RANGE, extra word not written =====
    cap_n = 0;
    for (int k = 0; k <= WORDS; k++) txp[k] = 16'h2000 + k[15:0];
    exchange(8'h10, 16'h0102, 4'h0, WORDS+1, 1'b0);
    check_status(16'd3, "oversize: RANGE");
    check(rxf[5] === WORDS[15:0], "oversize: only WORDS commits");
    check(rxf[6][0] === 1'b0 && rxf[6][2] === 1'b1, "oversize: FAULT_RANGE set");
    check(cap_n === WORDS, $sformatf("oversize: %0d writes, want %0d", cap_n, WORDS));
    check(faults === FAULT_RANGE, "oversize: sticky range fault");
    check(irq_n === 1'b0, "oversize: IRQ asserted");
    check(rxf[7] === (16'h2000 + (WORDS-1)), "oversize: echo is the last committed word");

    // ================= 5: STATUS reports, does not clear ================
    // R2: the cpu-derived registers are inserted between target and faults,
    // so the header is 11 payload words and faults/words_written move from
    // slots 4/5 to 9/10. The fields that used to be stubs are now real
    // registers, which is the whole point of the R2 layout.
    exchange(8'h11, 16'h0103, 4'h0, 0, 1'b0);
    check_status(16'd0, "status");
    check(rlen === 11, $sformatf("status: payload len %0d, want 11 (R2)", rlen));
    check(rxf[5] === 16'd0, "status: state stopped");
    check(rxf[6] === 16'd0, "status: run low");
    check(rxf[7] === 16'd0, "status: selected target host");
    check(rxf[8] === 16'd7, "status: pc");
    check(rxf[13] === FAULT_RANGE, "status: faults reported");
    check(rxf[14] === WORDS[15:0], "status: words_written");
    check(faults === FAULT_RANGE, "status: fault is sticky across a read");
    check(irq_n === 1'b0, "status: IRQ stays asserted after a read");

    // ================= 6: CLEAR_FAULT mask ==============================
    txp[0] = FAULT_RANGE;
    exchange(8'h16, 16'h0104, 4'h0, 1, 1'b0);
    check_status(16'd0, "clear range");
    check(rlen === 2, "clear: payload len");
    check(rxf[5] === 16'h0000, "clear: faults empty");
    check(faults === 16'h0000, "clear: sticky register cleared");
    check(irq_n === 1'b1, "clear: IRQ released");

    // ================= 7: BAD CRC -> BAD_FRAME + FAULT_CRC ==============
    cap_n = 0;
    txp[0] = 16'hCAFE;
    exchange(8'h01, 16'h0200, 4'h0, 0, 1'b1);
    check_status(16'd2, "bad crc: BAD_FRAME");
    check(rxf[1][11:4] === 8'h81, "bad crc: response opcode echoes request");
    check(rxf[2] === 16'h0200, "bad crc: sequence salvaged");
    check(faults === FAULT_CRC, "bad crc: CRC fault");
    check(cap_n === 0, "bad crc: nothing written");

    // A STATUS read does not clear it; LOAD while run=1 does not either.
    exchange(8'h11, 16'h0201, 4'h0, 0, 1'b0);
    check(rxf[13] === FAULT_CRC, "bad crc: STATUS reports the fault");
    check(irq_n === 1'b0, "bad crc: IRQ still asserted");

    // ================= 8: CLEAR_FAULT all ===============================
    txp[0] = 16'hFFFF;
    exchange(8'h16, 16'h0202, 4'h0, 1, 1'b0);
    check_status(16'd0, "clear all");
    check(rxf[5] === 16'h0000, "clear all: empty");
    check(irq_n === 1'b1, "clear all: IRQ released");

    // ================= 9: version rejection =============================
    // Send a frame whose header says version 2, with a VALID CRC.
    begin
      logic [15:0] crc, w;
      body[0] = 16'hA55A;
      body[1] = {4'h2, 8'h01, 4'h0};
      body[2] = 16'h0300;
      body[3] = 16'h0000;
      crc = 16'hFFFF;
      for (int k = 0; k < 4; k++) crc = crc_word(crc, body[k]);
      body[4] = crc;
      cs_low;
      for (int k = 0; k < 5; k++) begin
        w = body[k];
        send_word(w);
      end
      for (int k = 0; k < 4; k++) begin
        read_word(w);
        rxf[k] = w;
      end
      rlen = rxf[3];
      for (int k = 4; k < 5 + rlen; k++) begin
        read_word(w);
        rxf[k] = w;
      end
      cs_high;
      settle;
      check(rxf[0] === 16'hA55A && rxf[4] === 16'd2, "version: BAD_FRAME");
      check(rxf[2] === 16'h0300, "version: sequence salvaged");
      check(faults === FAULT_PROTOCOL, "version: protocol fault");
      check(irq_n === 1'b0, "version: IRQ asserted");
    end
    txp[0] = 16'hFFFF;
    exchange(8'h16, 16'h0301, 4'h0, 1, 1'b0);
    check(faults === 16'h0000, "version: cleared");

    // ================= 10: bad sync is ignored, next frame works ========
    begin
      logic [15:0] w;
      cs_low;
      send_word(16'h0000);                  // garbage word: no frame
      send_word(16'hA55A);                  // a fresh frame starts here
      send_word({4'h1, 8'h01, 4'h0});
      send_word(16'h0400);
      send_word(16'h0000);
      w = crc_word(crc_word(crc_word(crc_word(16'hFFFF, 16'hA55A),
                                     {4'h1, 8'h01, 4'h0}), 16'h0400), 16'h0000);
      send_word(w);
      for (int k = 0; k < 4; k++) begin
        read_word(w);
        rxf[k] = w;
      end
      rlen = rxf[3];
      for (int k = 4; k < 5 + rlen; k++) begin
        read_word(w);
        rxf[k] = w;
      end
      cs_high;
      settle;
    end
    check(rxf[0] === 16'hA55A && rxf[2] === 16'h0400 && rxf[4] === 16'd0,
          "bad sync: the next A55A frame is answered");

    // ================= 11: LOAD while run=1 -> NOT_READY, no fault ======
    cap_n = 0; run = 1'b1;
    txp[0] = 16'hDDDD;
    exchange(8'h10, 16'h0500, 4'h0, 1, 1'b0);
    check_status(16'd6, "run gate: NOT_READY");
    check(cap_n === 0, "run gate: nothing written while running");
    check(faults === 16'h0000, "run gate: no fault");
    check(irq_n === 1'b1, "run gate: IRQ stays high");
    run = 1'b0;

    // ================= 12: run-abort inside a LOAD ======================
    // Words 0..1 commit; run rises while the third payload word is queued in
    // the write engine; that word is aborted, nothing commits after it, the
    // frame still completes with FAULT + FAULT_LOAD, and run falling must
    // not resurrect it.
    cap_n = 0; writes_while_run = 0; run = 1'b0;
    txp[0] = 16'h1111; txp[1] = 16'h2222;
    txp[2] = 16'h3333; txp[3] = 16'h4444;
    fork
      begin
        forever begin
          @(posedge clk); #1;
          if (dut.load_idx === 16'd3) break;   // the third word is queued
        end
        run = 1'b1;                            // abort it in the write engine
      end
      exchange(8'h10, 16'h0600, 4'h0, 4, 1'b0);
    join
    check_status(16'd4, "abort: FAULT");
    check(rxf[5] === 16'd2, $sformatf("abort: words_written = %0d, want 2", rxf[5]));
    check(rxf[6][0] === 1'b1, "abort: FAULT_LOAD set");
    check(rxf[7] === 16'h2222, "abort: echo is the last committed word");
    check(cap_n === 2, $sformatf("abort: %0d writes, want 2", cap_n));
    check(writes_while_run === 0, "abort: no write while run=1");
    check(words_written === 16'd2, "abort: not counted");
    run = 1'b0;
    repeat (16) @(posedge clk); #1;
    check(cap_n === 2, "abort: the queued word did not resurrect");
    check(load_error === 1'b1, "abort: load_error mirrors FAULT_LOAD");
    txp[0] = 16'hFFFF;
    exchange(8'h16, 16'h0601, 4'h0, 1, 1'b0);
    check(faults === 16'h0000, "abort: cleared");

    // ================= 12b: run-abort inside W_PULSE ===================
    // The host_we mask is the property under test here: run rises while the
    // write pulse is being asserted, so the word must not reach the SoC.
    cap_n = 0; writes_while_run = 0; run = 1'b0;
    txp[0] = 16'hAAAA; txp[1] = 16'hBBBB;
    fork
      begin
        forever begin
          @(posedge clk); #1;
          if (dut.wstate === 2'd2) break;   // W_DONE: we_r is asserted
        end
        run = 1'b1;
      end
      exchange(8'h10, 16'h0602, 4'h0, 2, 1'b0);
    join
    check_status(16'd4, "abort-done: FAULT");
    check(writes_while_run === 0, "abort-done: host_we pulsed while run=1");
    check(cap_n === 0, $sformatf("abort-done: %0d writes, want 0", cap_n));
    check(words_written === 16'd0, "abort-done: masked word counted");
    check(rxf[6][0] === 1'b1, "abort-done: FAULT_LOAD set");
    run = 1'b0;
    repeat (16) @(posedge clk); #1;
    check(cap_n === 0, "abort-done: the queued word did not resurrect");
    txp[0] = 16'hFFFF;
    exchange(8'h16, 16'h0603, 4'h0, 1, 1'b0);
    check(faults === 16'h0000, "abort-done: cleared");

    // ================= 13: TARGET selection and target 1 ================
    txp[0] = 16'h0000;
    exchange(8'h20, 16'h0700, 4'h0, 1, 1'b0);
    check_status(16'd0, "target host: OK");
    check(rxf[5] === 16'd0, "target host: selected");
    check(rxf[6] === CAP_HOST, "target host: capabilities");

    txp[0] = 16'h0001;
    exchange(8'h20, 16'h0701, 4'h0, 1, 1'b0);
    check_status(16'd0, "target 1: OK");
    check(rxf[5] === 16'd1, "target 1: selected");
    check(rxf[6] === CAP_LOOPBACK, "target 1: capabilities");

    // PING routed to target 1 returns the deterministic identification word.
    exchange(8'h01, 16'h0702, 4'h1, 0, 1'b0);
    check_status(16'd0, "loopback ping: OK");
    check(rlen === 2 && rxf[5] === LOOPBACK_ID, "loopback ping: id");

    // A LOAD routed to target 1 is UNSUPPORTED and writes nothing.
    cap_n = 0;
    txp[0] = 16'hEEEE;
    exchange(8'h10, 16'h0703, 4'h1, 1, 1'b0);
    check_status(16'd5, "loopback load: UNSUPPORTED");
    check(cap_n === 0, "loopback load: nothing written");
    check(faults === 16'h0000, "loopback load: no fault");

    // Unknown target -> UNSUPPORTED, no fault.
    exchange(8'h01, 16'h0704, 4'h2, 0, 1'b0);
    check_status(16'd5, "unknown target: UNSUPPORTED");
    check(faults === 16'h0000, "unknown target: no fault");

    // STATUS while target 1 is selected reports the selected target.
    exchange(8'h11, 16'h0705, 4'h0, 0, 1'b0);
    check(rxf[7] === 16'd1, "status: selected target is 1");
    txp[0] = 16'h0000;
    exchange(8'h20, 16'h0706, 4'h0, 1, 1'b0);
    check(rxf[5] === 16'd0, "target host: reselected");

    // ================= 14: unsupported requests ========================
    exchange(8'h33, 16'h0800, 4'h0, 0, 1'b0);
    check_status(16'd5, "unknown opcode: UNSUPPORTED");
    check(rxf[1][11:4] === (8'h33 | 8'h80), "unknown opcode: echoed");
    check(faults === 16'h0000, "unknown opcode: no fault");

    exchange(8'h81, 16'h0801, 4'h0, 0, 1'b0);
    check_status(16'd5, "response opcode as request: UNSUPPORTED");

    // Wrong opcode payload length -> BAD_FRAME + protocol fault.
    txp[0] = 16'h1234;
    exchange(8'h01, 16'h0802, 4'h0, 1, 1'b0);
    check_status(16'd2, "ping with payload: BAD_FRAME");
    check(faults === FAULT_PROTOCOL, "ping with payload: protocol fault");
    txp[0] = 16'hFFFF;
    exchange(8'h16, 16'h0803, 4'h0, 1, 1'b0);

    // ================= 15: MISO ownership ===============================
    check(miso_oe === 1'b0 && irq_n === 1'b1, "ownership: idle released");
    cs_low;
    send_word(16'hA55A);
    check(miso_oe === 1'b0, "ownership: MISO released during the request");
    begin
      logic [15:0] w;
      send_word({4'h1, 8'h01, 4'h0});
      send_word(16'h0900);
      send_word(16'h0000);
      w = crc_word(crc_word(crc_word(crc_word(16'hFFFF, 16'hA55A),
                                     {4'h1, 8'h01, 4'h0}), 16'h0900), 16'h0000);
      send_word(w);
      repeat (4) @(posedge clk); #1;
      check(miso_oe === 1'b1, "ownership: MISO driven while the response shifts");
      for (int k = 0; k < 4; k++) begin
        read_word(w);
        rxf[k] = w;
      end
      rlen = rxf[3];
      for (int k = 4; k < 5 + rlen; k++) begin
        read_word(w);
        rxf[k] = w;
      end
    end
    #(HALF_NS);
    check(miso_oe === 1'b0, "ownership: MISO released after the response");
    cs_high;
    settle;

    // ================= 16: rate/duty variants ===========================
    // Mode 0 is preserved at 2.5 MHz (200/200) and at the 100 ns minimum low
    // phase (100/300, a 25% duty 2.5 MHz clock): the pre-sampling and
    // high-phase stability checks inside read_word must hold.
    set_sclk(200.0, 200.0);
    exchange(8'h01, 16'h0A00, 4'h0, 0, 1'b0);
    check_status(16'd0, "2.5 MHz ping");
    set_sclk(100.0, 300.0);
    exchange(8'h01, 16'h0A01, 4'h0, 0, 1'b0);
    check_status(16'd0, "100 ns low phase ping");
    set_sclk(HALF_NS, HALF_NS);

    // ================= R2: the read opcodes ==============================
    // READ_IMEM: a bounded, ascending word read. The model serves
    // model_imem[i] = 16'h1000 + i, so words 1,2 must come back 0x1001,0x1002.
    txp[0] = 16'd1; txp[1] = 16'd2;
    exchange(8'h13, 16'h0B00, 4'h0, 2, 1'b0);
    check_status(16'd0, "read_imem");
    check(rlen === 3, $sformatf("read_imem: payload len %0d, want 3", rlen));
    check(rxf[5] === 16'h1001, "read_imem: word 1 ascending");
    check(rxf[6] === 16'h1002, "read_imem: word 2 ascending");

    // The LAST word is readable (the bound is inclusive) and one past it is
    // RANGE, never a wrapped read: the golden vector reads 0x3FF and then
    // asks for 0x400.
    txp[0] = 16'(WORDS-1); txp[1] = 16'd1;
    exchange(8'h13, 16'h0B01, 4'h0, 2, 1'b0);
    check_status(16'd0, "read_imem last word");
    check(rxf[5] === 16'h1000 + WORDS-1, "read_imem: last word value");
    txp[0] = 16'(WORDS-1); txp[1] = 16'd2;
    exchange(8'h13, 16'h0B02, 4'h0, 2, 1'b0);
    check_status(16'd3, "read_imem past end");
    check(rlen === 1, "read_imem past end: no data words");
    check(faults === FAULT_RANGE,
          "read_imem past end: latched sticky FAULT_RANGE");

    // CLEAR_FAULT clears exactly that bit (it was the only one set here).
    txp[0] = FAULT_RANGE;
    exchange(8'h16, 16'h0B03, 4'h0, 1, 1'b0);
    check(faults === 16'd0, "clear_fault: RANGE cleared");

    // READ_DMEM: bytes, packed big-endian per word, ascending. Re-enabled
    // after the wait-word contract (manager ruling 2026-09-25) made the
    // read's variable latency visible to the host as 0xFFFF filler words.
    // The model serves model_dmem[i] = 8'(i*0x11), so bytes 0..3 are
    // 00 11 22 33 and the two data words must be 0x0011, 0x2233.
    txp[0] = 16'd0; txp[1] = 16'd4;
    exchange(8'h14, 16'h0B05, 4'h0, 2, 1'b0);
    check_status(16'd0, "read_dmem");
    check(rlen === 3, $sformatf("read_dmem: payload len %0d, want 3", rlen));
    check(rxf[5] === 16'h0011, "read_dmem: bytes 0,1 big-endian");
    check(rxf[6] === 16'h2233, "read_dmem: bytes 2,3 big-endian");

    // An ODD byte count: the last byte lands in the low half of its word.
    txp[0] = 16'd0; txp[1] = 16'd3;
    exchange(8'h14, 16'h0B06, 4'h0, 2, 1'b0);
    check_status(16'd0, "read_dmem odd count");
    check(rxf[5] === 16'h0011, "read_dmem odd: first word");
    check(rxf[6] === 16'({8'h00, 8'h22}), "read_dmem odd: trailing byte alone");

    // dmem bounds are bytes: 15 + 2 is past the 16-byte buffer.
    txp[0] = 16'd15; txp[1] = 16'd2;
    exchange(8'h14, 16'h0B07, 4'h0, 2, 1'b0);
    check_status(16'd3, "read_dmem past end");
    check(faults === FAULT_RANGE, "read_dmem past end: sticky RANGE");
    txp[0] = FAULT_RANGE;
    exchange(8'h16, 16'h0B08, 4'h0, 1, 1'b0);

    // READ_CPU is the ONLY non-halting read: it answers while run=1.
    run = 1'b1;
    exchange(8'h12, 16'h0B09, 4'h0, 0, 1'b0);
    check_status(16'd0, "read_cpu while running");
    check(rlen === 7, $sformatf("read_cpu: payload len %0d, want 7", rlen));
    check(rxf[5] === {6'b0, 10'd7},  "read_cpu: pc full width");
    check(rxf[6] === 16'h0011, "read_cpu: a");
    check(rxf[7] === 16'h0022, "read_cpu: x");
    check(rxf[8] === 16'h0033, "read_cpu: y");
    check(rxf[9] === 16'hBEEF, "read_cpu: insn 16 bits");
    check(rxf[10] === 16'd1,    "read_cpu: run reported high");
    // ... while the bounded reads are NOT_READY while run=1, with NO fault.
    txp[0] = 16'd0; txp[1] = 16'd1;
    exchange(8'h13, 16'h0B0A, 4'h0, 2, 1'b0);
    check_status(16'd6, "read_imem while running");
    check(rlen === 1, "read_imem while running: no data");
    check(faults === 16'd0, "read_imem while running: NO fault (rejection)");
    txp[0] = 16'd0; txp[1] = 16'd1;
    exchange(8'h14, 16'h0B0B, 4'h0, 2, 1'b0);
    check_status(16'd6, "read_dmem while running");
    exchange(8'h15, 16'h0B0C, 4'h0, 0, 1'b0);
    check_status(16'd6, "dump_core while running");
    run = 1'b0;

    // DUMP_CORE while stopped equals the STATUS header, word for word. The
    // golden vectors assert exactly this, so the comparison is real: the dump
    // is captured first, then STATUS is fetched and the two are compared.
    exchange(8'h15, 16'h0B0D, 4'h0, 0, 1'b0);
    check_status(16'd0, "dump_core");
    check(rlen === 11, $sformatf("dump_core: payload len %0d, want 11", rlen));
    check(rxf[5]  === 16'd0,    "dump_core: state");
    check(rxf[6]  === 16'd0,    "dump_core: run low");
    check(rxf[7]  === 16'd0,    "dump_core: target host");
    check(rxf[8]  === {6'b0, 10'd7}, "dump_core: pc");
    check(rxf[9]  === 16'h0011, "dump_core: a");
    check(rxf[10] === 16'h0022, "dump_core: x");
    check(rxf[11] === 16'h0033, "dump_core: y");
    check(rxf[12] === 16'h0044, "dump_core: timer");
    for (int k = 0; k < 11; k++) dump_words[k] = rxf[4+k];
    exchange(8'h11, 16'h0B0E, 4'h0, 0, 1'b0);
    check(rlen === 11, "status header len after dump");
    for (int k = 0; k < 11; k++)
      check(rxf[4+k] === dump_words[k],
            $sformatf("dump_core == status header at word %0d", k));

    if (errors == 0) $display("PASS: tb_pe_ctrl");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #10_000_000;
    $display("FAIL: watchdog — tb_pe_ctrl did not finish");
    $finish;
  end

endmodule
