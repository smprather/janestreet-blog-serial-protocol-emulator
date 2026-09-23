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
//      10 MHz SCLK gives six clocks per half period — the documented ceiling.
//
//   2. THE LOADER MUST NOT WRITE WHILE THE CORE RUNS. `run` is an input and
//      every receive and write path is gated on it. The host loads with
//      `run=0`, then raises it; a stray SCLK edge during execution cannot
//      corrupt instruction memory.
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
  output logic        load_error,      // sticky until the next CS falling edge
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

  assign host_we       = we_r;
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
      case (wstate)
        W_IDLE: begin
          we_r <= 1'b0;
          if (word_ready && !run) wstate <= W_PULSE;
        end
        W_PULSE: begin
          we_r   <= 1'b1;
          wstate <= W_DONE;
        end
        W_DONE: begin
          we_r          <= 1'b0;
          word_ready    <= 1'b0;
          words_written <= words_written + 16'd1;
          if (addr == AW'(WORDS - 1)) begin
            load_error <= 1'b1;      // more words than instruction memory
            wstate     <= W_IDLE;
          end else begin
            addr   <= addr + 1'b1;
            wstate <= W_IDLE;
          end
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

endmodule
