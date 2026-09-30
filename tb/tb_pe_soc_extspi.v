// tb_pe_soc_extspi.v — an EXTERNALLY-PACED SPI testbench for the framed host
// bus, on the real RTL. The first bite of the v1.0 simulation path.
//
// WHY THIS EXISTS, AND WHY IT IS NOT tb_pe_soc_spi3.v WITH A FLAG
//
// tb_pe_soc_spi3.v hardcodes ONE specific transaction (a 3-word payload plus a
// per-word CRC-8) in a bit-level slave model, and its MISO is a register THIS
// testbench drives. That is a master-mode, self-contained test: it proves the
// SoC's own SPI master firmware, and it decides for itself what to send.
//
// VvpTTAdapter needs the opposite. The Pico bridge is an SPI MASTER and the chip
// is the SLAVE, and the bridge decides the frame and the pace, from Python. So
// the physical layer has to be externally supplied: read a request from a file,
// clock it out, capture what comes back, write it out. This testbench is that
// physical layer and nothing else.
//
// WHICH CHIP, AND WHY IT IS THE WRAPPER (this is the load-bearing decision)
// pe_soc does NOT contain the SPI slave. pe_ctrl is the slave, and pe_soc.v's own
// comments say "pe_ctrl, outside this block" - it is instantiated in the
// top-level wrapper rtl/tt_um_protocol_emulator.v. The wrapper is what exposes
// the framed host bus on its uio pads:
//
//   uio[4]  host CS_N    in    framed host bus
//   uio[5]  host MOSI    in    framed host bus
//   uio[6]  host MISO    out   response, RELEASED when idle
//   uio[7]  host SCK     in    framed host bus
//   uo_out[1]  IRQ_N     out   active low, sticky faults
//   ui_in[1]    run       in    1 = execute, 0 = hold at PC 0
//
// and it wires them straight to pe_ctrl (wrapper lines 294-295):
//
//   assign uio_out[6] = ctrl_spi_miso;   // framed response MISO
//   assign uio_oe[6]  = ctrl_miso_oe;    // driven only while a response shifts
//
// Instantiating the 14-file pe_soc list instead would build a chip with NO
// pe_ctrl in it, and a smoke test against that would pass on a part that cannot
// answer. tb_tt_um_protocol_emulator (run_all.sh:189) uses the SAME 14-file
// source list as the tb_pe_soc_* cases, so the compile line is the one the suite
// already uses; only the top differs.
//
// A NOTE ON THE PAD MAP IN THE ORIGINAL TASK, because it is a real discrepancy
// and not a typo. SCLK=0, MOSI=1, CS=2, MISO=3 is tb_pe_soc_spi3.v:78, and
// pe_soc.v:115-118 names the same four bits. That is the SoC-AS-MASTER map:
// the SoC drives SCLK/MOSI/CS_N out and reads MISO in, which is what the UART/SPI
// firmware uses. The host bridge is the other direction, so this testbench uses
// the wrapper's uio[4:7] instead. Both are correct for their own direction; only
// one of them is the bridge's.
//
// THE MISO CONTRACT, which is why this is not a bit-banger
// pe_ctrl asserts miso_oe ONLY while a response frame is shifting (pe_ctrl.v:593:
// `assign miso_oe = resp_active | resp_hold_oe | r_filling;`). When the pad is
// released, this testbench reads IDLE, exactly as hardware would - and that is
// the wait-word contract: a bounded read cannot answer inside the request's bit
// times, so the chip may drive up to MAX_WAIT_WORDS=15 leading 0xFFFF filler
// words before the real frame (pe_frame.py:102-135). A testbench that modelled
// MISO as always-driven would silently pass a host that never saw a release.
//
// SPI MODE 0, CS-FRAMED, from firmware/spi_xfer.pe and pe_ctrl.v:463-485:
// sclk_rise is the capture edge, and the mode-0 change edge is the fall. So:
//   CS_N falls -> selected
//   SCLK rises -> THE SLAVE CAPTURES MOSI. We drive MOSI and sample MISO here.
//   SCLK falls  -> nothing
//   CS_N rises  -> frame over
//
// TIMING. Bit period comes from +period= in nanoseconds (default 100). The
// chip's own clock is separate and faster; a host is not obliged to clock at the
// chip's rate, and VvpTTAdapter will want to vary it.
//
// FILES. +req=<path>  whitespace-separated 4-hex-digit words, MSB-first on the
// wire; one frame. +resp=<path>  one 4-hex-digit word per line, exactly what
// was clocked out of MISO, including the wait-word fillers. A missing +resp
// prints the captured words to stdout instead.
//
// NOT A GATE. This is a dev/acceptance tool for the VvpTTAdapter work. It is
// deliberately not registered in run_all.sh, and it is not covered by
// check_harness_preflight. It is proven by hand, by the commands in the WORKLOG
// entry, and the round-trip against pe_frame.py is the NEXT bite.
`timescale 1ns / 1ps

module tb_pe_soc_extspi;

  // ---- configuration from plusargs -----------------------------------------
  // The host SPI bus on the wrapper uio pad, named from tt_um_protocol_emulator.v:57-63.
  localparam int CS_BIT  = 4;   // uio[4] host CS_N   (in)
  localparam int MOSI_BIT = 5;   // uio[5] host MOSI   (in)
  localparam int MISO_BIT = 6;   // uio[6] host MISO   (out, released when idle)
  localparam int SCK_BIT  = 7;   // uio[7] host SCK    (in)
  localparam int RUN_BIT  = 1;   // ui_in[1] run       (in)
  localparam int IRQ_BIT  = 1;   // uo_out[1] IRQ_N     (out, active low)

  localparam int CLK_HZ     = 60_000_000;
  localparam real CLK_NS    = 1e9 / CLK_HZ;
  localparam int  MAX_BITS   = 4096;   // a sanity ceiling on one frame
  localparam int  MAX_WORDS  = 512;    // and on the capture

  // MISO IDLE is what a RELEASED pad reads on a board with a pull-up. It is the
  // value the wait-word filler is expected to be contrasted against, so it is a
  // named constant rather than a literal buried in the read.
  localparam logic [7:0] MISO_IDLE = 8'hFF;

  // ---- DUT -----------------------------------------------------------------
  reg         clk = 1'b0;
  reg         rst_n = 1'b0;
  reg  [7:0]  ui_in = 8'h00;
  wire [7:0]  uo_out;
  reg  [7:0]  uio_in = 8'h00;
  wire [7:0]  uio_out;
  wire [7:0]  uio_oe;

  // Master-side pad wires. The chip samples the three INPUT bits out of uio_in,
  // and drives MISO out of uio_out under uio_oe.
  wire cs_n  = uio_in[CS_BIT];
  wire mosi  = uio_in[MOSI_BIT];
  wire sck   = uio_in[SCK_BIT];
  wire miso  = (uio_oe[MISO_BIT] === 1'b1) ? uio_out[MISO_BIT] : MISO_IDLE[0];
  wire irq_n = uo_out[IRQ_BIT];

  always #(CLK_NS/2.0) clk = ~clk;

  tt_um_protocol_emulator dut (
    .ui_in  (ui_in),
    .uo_out (uo_out),
    .uio_in (uio_in),
    .uio_out(uio_out),
    .uio_oe (uio_oe),
    .ena    (1'b0),   // design select, NOT a reset (wrapper header)
    .clk    (clk),
    .rst_n  (rst_n)
  );

  // ---- request / response plumbing ----------------------------------------
  integer n_req, n_rsp, i, bit_i, errors;
  reg [1023:0] req_path, resp_path;
  reg have_req, have_resp;
  integer period_ns;
  integer n_clocked, n_captured;
  reg [15:0] rx_shift;
  reg [7:0]  tx_word;
  reg [15:0] cap_words [0:MAX_WORDS-1];

  // Drive one bit pair per bit period. Mode 0: MOSI is presented while SCLK is
  // low and the chip samples on the RISE, so the value must be stable across
  // THE SAMPLING POINT, taken from the testbench that already drives this slave
  // correctly, tb_pe_ctrl_r2.v:116-133:
  //
  //     send: sclk=0, mosi=b, half, sclk=1, half
  //     recv: sclk=0, half, q=miso, sclk=1, half
  //
  // Mode 0 means the SLAVE changes its output on the falling edge and the MASTER
  // samples during the following LOW phase, before the next rise. My first two
  // attempts both sampled at the rise: the first after the fall (one bit late) and
  // the second just after the rise (one bit early, because the non-blocking
  // assignments had already advanced the serializer). Neither showed in bite 1
  // because the capture was all-0xFF and a shifted 0xFF is still 0xFF; with a real
  // frame coming back the slip read as a corrupted SYNC word (a518 instead of
  // a55a). So one task does both directions, sampling on the low phase exactly
  // as the working testbench does.
  task bit_xchg(input logic out_bit, output logic in_bit);
    begin
      // low phase: present the next response bit, and drive our out bit
      uio_in[SCK_BIT]  = 1'b0;
      uio_in[MOSI_BIT] = out_bit;
      #(period_ns/2);
      in_bit = miso;                 // sample while SCLK is LOW
      #(period_ns/2);
      uio_in[SCK_BIT]  = 1'b1;      // rising edge: the chip captures MOSI
      #(period_ns/2);
    end
  endtask

  // Clock one 16-bit word out MSB-first and capture 16 bits back, MSB-first.
  task word_xchg(input [15:0] w_out, output [15:0] w_in);
    integer k;
    logic mbit;
    begin
      w_in = 16'h0;
      for (k = 15; k >= 0; k = k - 1) begin
        bit_xchg(w_out[k], mbit);
        w_in = {w_in[14:0], mbit};
      end
    end
  endtask

  // ---- plusargs ------------------------------------------------------------
  initial begin
    have_req = 0; have_resp = 0; period_ns = 100;
    n_req = 0; n_rsp = 0; n_clocked = 0; n_captured = 0; errors = 0;
    for (i = 0; i < MAX_WORDS; i = i + 1) cap_words[i] = 16'h0000;
    if (!$value$plusargs("period=%d", period_ns) || period_ns <= 0) period_ns = 100;
    if ($value$plusargs("req=%s", req_path))  have_req  = 1;
    if ($value$plusargs("resp=%s", resp_path)) have_resp = 1;
    // Read budget. The default is the host's worst case for a zero-data
    // response: 6 overhead + 0 data + 15 wait words (main.py:317-328,
    // pe_frame.MAX_WAIT_WORDS=15). A caller can override with +nresp=<n>.
    if (!$value$plusargs("nresp=%d", n_rsp) || n_rsp <= 0) n_rsp = 6 + 15;
  end

  // ---- main ----------------------------------------------------------------
  integer fh, scan, req_fd, resp_fd, code, w_in_tmp;
  reg [15:0] w_in;
  reg [15:0] words [0:MAX_WORDS-1];

  initial begin
    $display("tb_pe_soc_extspi: period=%0dns  host bus uio[4]=CS_N uio[5]=MOSI uio[6]=MISO uio[7]=SCK", period_ns);
    $display("tb_pe_soc_extspi: request %0d word(s) + read budget %0d word(s), all inside one CS-low frame", n_req, n_rsp);

    // Release the host bus to a defined idle: CS high, SCLK low (mode 0 idle).
    uio_in[CS_BIT] = 1'b1;
    uio_in[SCK_BIT] = 1'b0;
    uio_in[MOSI_BIT] = 1'b0;

    // ---- read the request ---------------------------------------------------
    if (have_req) begin
      fh = $fopen(req_path, "r");
      if (fh == 0) begin
        $display("FAIL: cannot open +req=%0s", req_path);
        $finish;
      end
      scan = $fscanf(fh, "%h", w_in);
      while (scan == 1 && n_req < MAX_WORDS) begin
        words[n_req] = w_in;
        n_req = n_req + 1;
        scan = $fscanf(fh, "%h", w_in);
      end
      $fclose(fh);
      $display("tb_pe_soc_extspi: request %0d word(s) from %0s", n_req, req_path);
    end else begin
      // SMOKE TEST with no +req: one known word, A55A (the pe_frame SYNC), so
      // the CS/SCK/MOSI path is exercised and MISO is captured.
      words[0] = 16'hA55A;
      n_req = 1;
      $display("tb_pe_soc_extspi: no +req, smoke word 0xA55A");
    end

    // ---- reset, then release ------------------------------------------------
    rst_n = 1'b0;
    ui_in = 8'h00;                 // run low through reset, per the bridge contract
    #(20 * CLK_NS);
    rst_n = 1'b1;
    #(20 * CLK_NS);
    $display("tb_pe_soc_extspi: out of reset, run=%0d, irq_n=%0d", ui_in[RUN_BIT], irq_n);

  // ---- the transaction: REQUEST, then READ BUDGET, all inside one CS-low ----
    //
    // THE HALF-DUPLEX SHARED-CLOCK CONTRACT, and why bite 1 saw all-0xFF.
    // pe_ctrl launches the response serializer when the last request word lands
    // (pe_ctrl.v:1132-1136) and shifts it out on the SAME rising SCLK edges that
    // carried the request. It RELEASES the pad on the CS RISING edge
    // (pe_ctrl.v:716-723, resp_active/resp_hold_oe -> 0). So the host must:
    //   CS low  -> clock the request words  -> KEEP CS LOW and keep clocking
    //            to read the response     -> raise CS to end the frame.
    // Bite 1 raised CS immediately after the request, which released the pad
    // before a single response bit was clocked, so every capture read idle. The
    // read budget is the one main.py:317-328 computes: 6 overhead words (sync,
    // header, sequence, length, CRC, one slack) + data + 15 worst-case wait
    // words. We read that many and let pe_frame.strip_wait_words drop the
    // leading 0xFFFF fillers, exactly as the host does.
    uio_in[CS_BIT] = 1'b0;              // CS low: select the slave
    #(period_ns);

    // request words
    for (i = 0; i < n_req; i = i + 1) begin
      word_xchg(words[i], w_in);
      n_clocked = n_clocked + 1;
    end

    // ONE settle word after the request, captured like any other. pe_ctrl launches
    // the response serializer on the rising edge that completes the last request
    // word (pe_ctrl.v:1132-1136, resp_active<=1), so the first read clock lands ON
    // the launch edge: resp_active and resp_idx are being assigned that same edge and
    // the pad has not yet presented the first RESPONSE bit. Sampling there captured
    // the launch transient (the first byte came back a5 - the real SYNC high byte -
    // followed by garbage, because the serializer had not yet shifted). A settle
    // word lets the launch complete; if the chip is genuinely answering, the first
    // settle word is a wait word (0xFFFF) that strip_wait_words removes, and if the
    // chip is NOT answering, the settle word is 0xFFFF too and the decode still
    // fails - so this costs correctness nothing and only removes a race.
    word_xchg(16'h0000, w_in);          // settle/launch clock, MOSI idle
    n_clocked = n_clocked + 1;
    if (n_captured < MAX_WORDS) begin
      cap_words[n_captured] = w_in;      // the WHOLE word, not just its high byte
      n_captured = n_captured + 1;
    end

    // read budget: keep CS low, keep clocking. The response words are captured
    // from here on. n_rsp defaults to the worst case the host uses.
    for (i = 0; i < n_rsp; i = i + 1) begin
      word_xchg(16'h0000, w_in);        // MOSI idle during the read
      n_clocked = n_clocked + 1;
      if (n_captured < MAX_WORDS) begin
        cap_words[n_captured] = w_in;    // the WHOLE word
        n_captured = n_captured + 1;
      end
    end

    uio_in[CS_BIT] = 1'b1;               // CS high ends the frame
    #(period_ns);

    // ---- report -------------------------------------------------------------
    $display("tb_pe_soc_extspi: clocked %0d word(s), captured %0d", n_clocked, n_captured);
    for (i = 0; i < n_captured; i = i + 1)
      $display("  resp[%0d] = 0x%04h", i, cap_words[i]);

    if (have_resp) begin
      resp_fd = $fopen(resp_path, "w");
      if (resp_fd == 0) begin
        $display("FAIL: cannot open +resp=%0s for writing", resp_path);
        $finish;
      end
      for (i = 0; i < n_captured; i = i + 1) $fdisplay(resp_fd, "%04h", cap_words[i]);
      $fclose(resp_fd);
      $display("tb_pe_soc_extspi: wrote %0d word(s) to %0s", n_captured, resp_path);
    end

    if (n_clocked == (n_req + n_rsp + 1) && n_req > 0) begin
      $display("PASS: %0d word(s) clocked out (request %0d + settle 1 + read budget %0d), %0d captured", n_clocked, n_req, n_rsp, n_captured);
    end else begin
      $display("FAIL: clocked %0d, expected %0d (request %0d + settle 1 + read budget %0d)", n_clocked, n_req + n_rsp + 1, n_req, n_rsp);
    end
    $finish;
  end

  // A frame that never ends is a hang, and a hang in an acceptance tool is the
  // failure this whole bite exists to prevent. Fail loudly instead.
  initial begin
    #50_000_000;
    $display("FAIL: tb_pe_soc_extspi TIMEOUT (the 50 ms wall clock expired)");
    $finish;
  end

endmodule
