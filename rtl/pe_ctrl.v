// pe_ctrl.v — the passive SPI load path: a host clocks a program into
// instruction memory through the SoC's existing host write port.
// Decision: wiki/decisions/adr-007-pe-ctrl-passive-slave.md
//
// WHAT THIS IS
//
// On silicon, instruction memory powers up holding whatever the SRAM macro
// happens to contain, and there is no ROM — so the first program cannot load
// itself. `pe_ctrl` is the hardware that lets a host do it: the host drives
// SCLK/MOSI/CS_N and the chip shifts 16-bit words straight into `pe_imem`
// through the host write port `pe_soc` already exposes.
//
// WHY IT LIVES IN THE WRAPPER, NOT THE SOC
//
// The host write port crosses the SoC boundary and the pads live at the
// wrapper, so the wrapper is the only place both facts are true. See ADR-007.
//
// THE WIRE CONTRACT (v1)
//
//   SPI mode 0: MOSI is sampled on the RISING SCLK edge; SCLK idles low.
//   MSB-first, 16 bits per word.
//   CS_N low resets the word address to 0 and enables the loader.
//   Every 16 rising edges: `imem[addr] <= word`, addr <= addr + 1.
//   CS_N high ends the load; a partial word (bit_cnt != 0) is discarded and
//   flagged in `load_error`.
//
// THE TWO TRAPS THIS BLOCK GUARDS
//
//   1. SCLK IS ASYNCHRONOUS. It goes through a 2-flop synchronizer; the edge
//      detector compares the synchronized level against its own delayed copy.
//      Do not feed `spi_sclk` to anything else: this is the only place in the
//      design that samples a pad without the DRU-style capture. At 60 MHz a
//      10 MHz SCLK gives six clocks per full period (three per half period) —
//      the documented ceiling. That leaves no margin for a synchronized MISO
//      response before the next host sample, so readback may need a slower
//      SCLK ceiling than write-only loading.
//
//   2. THE LOADER MUST NOT WRITE WHILE THE CORE RUNS. `run` is an input, every
//      receive path is gated on it, and `host_we` is MASKED by it at the pin.
//      If run rises with a word already queued in the write pipeline, the
//      loader ABORTS that word -- it is discarded, `load_error` latches, and
//      it does NOT reappear when run falls again. The review reproduced the
//      earlier version writing one word while run was high (E in
//      reviews/2026-09-23/PE-CTRL-REVIEW.md); the abort is the fix, and
//      tb_pe_ctrl raises run inside the exact W_PULSE window.
//
// No `timescale` here (repo convention: RTL is timescale-free).

module pe_ctrl #(
  parameter int WORDS = 1024
) (
  input  logic clk,
  input  logic rst_n,

  // The loader pads. Asynchronous host signals: synchronized here.
  input  logic spi_sclk,
  input  logic spi_mosi,
  input  logic spi_cs_n,      // active low

  // The core's run strap. Loading is only legal while this is 0.
  input  logic run,

  // The SoC's host write port, driven by the loader.
  output logic        host_we,
  output logic        host_imem_sel,
  output logic [((((WORDS <= 2) ? 1 : $clog2(WORDS)) > 8)
                 ? ((WORDS <= 2) ? 1 : $clog2(WORDS)) : 8)-1:0] host_addr,
  output logic [15:0] host_wdata,

  // Observability
  output logic        load_active,     // level: selected and run is low
  output logic        load_error,      // sticky: partial word, oversize load,
                                       // or a run-abort of a queued word
  output logic [15:0] words_written
);

  localparam int IAW = (WORDS <= 2) ? 1 : $clog2(WORDS);
  localparam int AW  = (IAW > 8) ? IAW : 8;   // matches pe_soc's host_addr

  // ---- synchronizers ----------------------------------------------------
  logic sclk_s0, sclk_s1, sclk_s1d;
  logic mosi_s0, mosi_s1;
  logic cs_s0, cs_s1, cs_s1d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_s0 <= 1'b0; sclk_s1 <= 1'b0; sclk_s1d <= 1'b0;
      mosi_s0 <= 1'b0; mosi_s1 <= 1'b0;
      cs_s0   <= 1'b1; cs_s1   <= 1'b1; cs_s1d   <= 1'b1;
    end else begin
      sclk_s0  <= spi_sclk;
      sclk_s1  <= sclk_s0;
      sclk_s1d <= sclk_s1;
      mosi_s0  <= spi_mosi;
      mosi_s1  <= mosi_s0;
      cs_s0    <= spi_cs_n;
      cs_s1    <= cs_s0;
      cs_s1d   <= cs_s1;
    end
  end

  wire sclk_rise =  sclk_s1 & ~sclk_s1d;
  wire cs_fall   = ~cs_s1 &  cs_s1d;
  wire cs_rise   =  cs_s1 & ~cs_s1d;

  assign load_active = ~cs_s1 && !run;

  // ---- receive ----------------------------------------------------------
  // `shreg` holds the LAST 15 bits of the word being assembled, oldest at
  // bit 14; the 16th bit is the current `mosi_s1` at the completing strobe.
  // It is 15 bits, not 16, because the 16th bit of a 16-bit register would be
  // shifted in and never read -- Verilator's UNUSEDSIGNAL, and this repo has
  // no accepted lint warnings. Same construction as pe_eth_mac's `sr`.
  logic [14:0] shreg;
  logic [3:0]  bit_cnt;
  logic [15:0] word_data;
  logic        word_ready;

  // ---- write engine -----------------------------------------------------
  logic [AW-1:0] addr;
  logic          we_r;
  logic [1:0]    wstate;
  localparam logic [1:0] W_IDLE = 2'd0, W_PULSE = 2'd1, W_DONE = 2'd2;

  // host_we is MASKED by run as well as gated by the state machine: even if a
  // pipeline window put we_r high while run is high, pe_imem must not commit a
  // host write during execution. The state machine independently aborts the
  // queued word (below), so the mask is belt-and-braces, not the only gate.
  assign host_we       = we_r & ~run;
  assign host_imem_sel = 1'b1;        // v1: instruction memory only
  assign host_addr     = addr;
  assign host_wdata    = word_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shreg         <= '0;
      bit_cnt       <= '0;
      word_data     <= '0;
      word_ready    <= 1'b0;
      addr          <= '0;
      we_r          <= 1'b0;
      wstate        <= W_IDLE;
      load_error    <= 1'b0;
      words_written <= '0;
    end else begin
      // CS falling edge: a new load starts at word 0.
      if (cs_fall) begin
        addr          <= '0;
        bit_cnt       <= '0;
        shreg         <= '0;
        word_ready    <= 1'b0;
        words_written <= '0;
        load_error    <= 1'b0;
        wstate        <= W_IDLE;
        we_r          <= 1'b0;
      end

      // CS rising edge: the load is over. A partial word is discarded and
      // flagged; completed words are already committed.
      if (cs_rise) begin
        if (bit_cnt != 4'd0) load_error <= 1'b1;
        bit_cnt    <= '0;
        word_ready <= 1'b0;
      end

      // Receive one bit per rising SCLK edge while selected, stopped, and
      // not already in error.
      if (sclk_rise && !run && !cs_s1 && !word_ready && !load_error) begin
        if (bit_cnt == 4'd15) begin
          word_data  <= {shreg[14:0], mosi_s1};
          bit_cnt    <= 4'd0;
          word_ready <= 1'b1;
        end else begin
          shreg   <= {shreg[13:0], mosi_s1};
          bit_cnt <= bit_cnt + 4'd1;
        end
      end

      // Write engine: one host_we cycle per completed word. host_addr and
      // host_wdata are registered and stable through W_PULSE/W_DONE, so the
      // single-cycle pulse is sampled by pe_imem exactly once.
      //
      // run is checked in EVERY state, not just when the write starts: a word
      // that has queued when run rises is ABORTED (discarded, flagged) rather
      // than written late. The reviewer's probe raised run after word_ready
      // moved the FSM to W_PULSE; the W_PULSE branch is what closes that
      // window, and the W_IDLE branch keeps a queued-but-unstarted word from
      // reappearing when run falls again.
      case (wstate)
        W_IDLE: begin
          we_r <= 1'b0;
          if (word_ready) begin
            if (run) begin
              word_ready <= 1'b0;
              load_error <= 1'b1;      // aborted: the image is incomplete
            end else begin
              wstate <= W_PULSE;
            end
          end
        end
        W_PULSE: begin
          if (run) begin
            we_r       <= 1'b0;
            word_ready <= 1'b0;
            load_error <= 1'b1;        // abort before the pulse is sampled
            wstate     <= W_IDLE;
          end else begin
            we_r   <= 1'b1;
            wstate <= W_DONE;
          end
        end
        W_DONE: begin
          we_r       <= 1'b0;
          word_ready <= 1'b0;
          if (run) begin
            // run rose at the sampling edge: host_we was masked, so nothing
            // was written and nothing is counted.
            load_error <= 1'b1;
            wstate     <= W_IDLE;
          end else begin
            words_written <= words_written + 16'd1;
            if (addr == AW'(WORDS - 1)) begin
              load_error <= 1'b1;      // more words than instruction memory
              wstate     <= W_IDLE;
            end else begin
              addr   <= addr + 1'b1;
              wstate <= W_IDLE;
            end
          end
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

endmodule
