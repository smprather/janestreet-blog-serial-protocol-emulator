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
    .dbg_insn(dbg_insn), .dbg_timer(dbg_timer)
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
  localparam int R2_NUM_STEPS = 18;


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
    for (int k = 0; k < 4 + 2; k++) begin
      logic [15:0] w;
      recv_word(w);
    end
    spi_cs_n = 1'b1; half_tick();
    repeat (8) @(posedge clk);
    if (faults !== 16'h0000)
      check(0, $sformatf("precondition: faults = %04h after CLEAR_FAULT, want 0",
                         faults));
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
