// pe_uart_soc.v — the smallest processor + RAM that can speak a protocol.
//
// There is NO protocol hardware in this file. No UART state machine, no shift
// register, no framing logic, no baud generator that knows what a bit is.
// There is a CPU, a tick counter, one input pin and one output pin, and the
// rest is software (firmware/uart_echo.pe).
//
// That is the whole point: swap the program and this speaks I2C, or SWD, or
// something nobody has written yet, with the gates unchanged.
//
// Memory map — the CPU's entire 4-bit IO space:
//
//   0x0  PIN     r   bit0 = the input pin's level (uart_rx)
//   0x1  TXPIN   w   bit0 = the output pin's level (uart_tx)
//   0x5  TIMER   r   free-running 8-bit counter, one increment per bit period
//   0x7  STATUS  r   bit0 = "a timer tick happened" (cleared by this read)
//
// Sizing rationale: IMEM 128 x 16 = 2048 bits, DMEM 16 x 8 = 128 bits, plus
// 8 bits of timer = ~2.2 kbit of memory for a complete UART. Both memories are
// flops. At 0.9 um^2/flop in sg13g2 that is ~2 kum^2 — comparable to the 539
// standard cells of pe_serdes, and far below one 256x16 SRAM macro (28 kum^2).
// Swapping IMEM to an SRAM macro is the documented next step once the program
// outgrows 128 words; the interface here does not change.

module pe_uart_soc #(
  parameter int IMEM_WORDS = 128,
  parameter int DMEM_BYTES = 16,
  parameter int CLK_HZ     = 40_000_000,
  parameter int BAUD       = 115_200
) (
  input  logic        clk,
  input  logic        rst_n,

  // Firmware loading + control (the host interface)
  input  logic        host_we,
  input  logic        host_imem_sel,   // 1: host_addr indexes imem, 0: dmem
  input  logic [7:0]  host_addr,
  input  logic [15:0] host_wdata,
  input  logic        run,

  // One protocol pin each way. Everything else is software.
  input  logic        pin_in,
  output logic        pin_out,

  // Observability
  output logic [7:0]  dbg_pc,
  output logic [7:0]  dbg_a,
  output logic [7:0]  dbg_timer
);

  localparam int IAW = (IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS);
  localparam int DAW = (DMEM_BYTES <= 2) ? 1 : $clog2(DMEM_BYTES);

  // The timer runs at 2x the baud rate: one increment per HALF bit period.
  // Half-bit resolution is required, not a luxury -- sampling on whole-bit
  // ticks can only land on bit BOUNDARIES, which is the worst place to
  // sample a serial line. Firmware counts 2 ticks per bit to stay mid-cell.
  // 40 MHz / 115200 / 2 = 173.61, so TICKS_PER_BIT is 173 (integer division)
  // and the delivered baud is 115,607 (+0.35% -- inside the ~2% UART budget,
  // but it is an approximation, not an exact integer like the 10BASE-T plan).
  localparam int TICKS_PER_BIT = (CLK_HZ / BAUD) < 4 ? 4 : (CLK_HZ / BAUD / 2);
  localparam int CNTW = $clog2(TICKS_PER_BIT);

  // ---- CPU <-> memory ---------------------------------------------------
  logic [IAW-1:0] imem_addr;
  logic [15:0]    imem_rdata;
  logic [DAW-1:0] dmem_addr;
  logic           dmem_we;
  logic [7:0]     dmem_wdata, dmem_rdata;
  logic [3:0]     io_port;
  logic           io_we, io_re;
  logic [7:0]     io_wdata, io_rdata;

  // Instruction memory, one registered read port + host write port.
  //
  // `ram_style` is an FPGA synthesis pragma and has NO effect in this flow:
  // yosys targeting sg13g2 has no block RAM to infer and no SRAM compiler to
  // call (the PDK ships fixed macros only). Both arrays therefore become
  // flops, which is where pe_uart_soc's ~8.7k cells come from. The attributes
  // are kept only as a statement of intent for the SRAM swap
  // ([[reference/sram-budget]]); they are not doing anything today, and
  // reading them as "this is a RAM" is how the area number gets misread.
  (* ram_style = "block" *) logic [15:0] imem [0:IMEM_WORDS-1];
  always_ff @(posedge clk) begin
    if (host_we && host_imem_sel) imem[host_addr[IAW-1:0]] <= host_wdata;
    imem_rdata <= imem[imem_addr];
  end

  // Data buffer: 16 bytes of distributed RAM, one read/write port plus a host
  // write port. The read is COMBINATIONAL on purpose. A registered read is
  // what a real SRAM macro does, but at 16 bytes distributed RAM is smaller --
  // and, more importantly, a registered read is stale for an immediate-address
  // load: `LDM addr` changes the address on the very cycle it wants the data,
  // so the register would return whatever the previous instruction addressed.
  (* ram_style = "distributed" *) logic [7:0] dmem [0:DMEM_BYTES-1];
  assign dmem_rdata = dmem[dmem_addr];

  always_ff @(posedge clk) begin
    if (dmem_we) dmem[dmem_addr] <= dmem_wdata;
    if (host_we && !host_imem_sel && (32'(host_addr) < DMEM_BYTES))
      dmem[host_addr[DAW-1:0]] <= host_wdata[7:0];
  end

  pe_cpu #(.IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES)) u_cpu (
    .clk(clk), .rst_n(rst_n), .run(run),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_addr(dmem_addr), .dmem_we(dmem_we),
    .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
    .io_port(io_port), .io_we(io_we), .io_re(io_re),
    .io_wdata(io_wdata), .io_rdata(io_rdata),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a)
  );

  // ---- tick counter -----------------------------------------------------
  // tick_cnt, tick_val and tick_flag are ONE register process. They used to be
  // two: the counter set tick_flag and a second always_ff cleared it on the
  // STATUS read. That is two drivers on one flop, and the two tools disagreed
  // about what it meant -- Icarus raced (dropping ~17% of ticks when the poll
  // loop happened to align with the counter wrap) and yosys reported a
  // driver-driver conflict and resolved tick_flag to a CONSTANT 0, so the
  // STATUS port was dead in the netlist while working in simulation.
  //
  // One process, and set-beats-clear when a tick and its STATUS read land on
  // the same cycle. Set wins because losing a tick costs the firmware a whole
  // bit period, while re-reporting one it has already seen costs it one extra
  // poll iteration.
  logic [CNTW-1:0] tick_cnt;
  logic [7:0]      tick_val;
  logic            tick_flag;
  logic            tick_now, status_rd;

  assign tick_now  = (tick_cnt == CNTW'(TICKS_PER_BIT - 1));
  assign status_rd = io_re && (io_port == 4'h7);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tick_cnt  <= '0;
      tick_val  <= 8'h00;
      tick_flag <= 1'b0;
    end else begin
      if (tick_now) begin
        tick_cnt <= '0;
        tick_val <= tick_val + 8'd1;
      end else begin
        tick_cnt <= tick_cnt + 1'b1;
      end

      if (tick_now)        tick_flag <= 1'b1;   // set beats clear
      else if (status_rd)  tick_flag <= 1'b0;
    end
  end

  assign dbg_timer = tick_val;

  // ---- the pin ----------------------------------------------------------
  // Registered so firmware sees a clean level and the TB can observe it.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pin_out <= 1'b1;                    // idle high
    else if (io_we && io_port == 4'h1) pin_out <= io_wdata[0];
  end

  // Only bit 0 of a CPU write reaches a pin today (one output pin, one bit).
  // Sink the rest explicitly rather than leaving a lint warning that a reader
  // has to be told is expected. The pin matrix will consume all eight.
  logic [6:0] _unused_io_wdata;
  assign _unused_io_wdata = io_wdata[7:1];

  // ---- IO read mux ------------------------------------------------------
  always_comb begin
    case (io_port)
      4'h0:    io_rdata = {7'b0, pin_in};
      4'h1:    io_rdata = {7'b0, pin_out};    // readback, aids firmware debug
      4'h5:    io_rdata = tick_val;
      4'h7:    io_rdata = {7'b0, tick_flag};
      default: io_rdata = 8'h00;
    endcase
  end

endmodule
