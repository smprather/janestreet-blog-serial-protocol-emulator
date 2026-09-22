// pe_uart_soc.v — the smallest processor + RAM that can speak a protocol.
//
// There is NO protocol hardware in this file. No UART state machine, no shift
// register, no framing logic, no baud generator that knows what a bit is.
// There is a CPU, a tick counter, a generalised pin port, and the rest is
// software (firmware/uart_echo.pe).
//
// That is the whole point: swap the program and this speaks I2C, or SWD, or
// something nobody has written yet, with the gates unchanged.
//
// Memory map — the CPU's entire 4-bit IO space:
//
//   0x0  PIN     r   the port's current levels, one bit per pin
//   0x1  PINOUT  w   drive the port's OUTPUT bits
//   0x1  PINOUT  r   readback (same view as PIN, aids firmware debug)
//   0x5  TIMER   r   free-running 8-bit counter, one increment per bit period
//   0x7  STATUS  r   bit0 = "a timer tick happened" (cleared by this read)
//
// THE PORT NUMBERING RULE: outputs low, inputs high.
//
// Bit 0 is the lowest OUTPUT, and the INPUTs occupy a contiguous run of the
// HIGH bits; PIN_IN_MASK records where the split falls. That is the whole rule,
// and the write path below is exactly it: input bits keep their value, output
// bits take the written value.
//
// The reason for a rule rather than a per-pin convention is that firmware has
// to be able to write a pin value with no arithmetic. Under this rule the first
// output is always bit 0, so `LDI A, 1; OUT PINOUT, A` raises it -- no shift,
// no mask, no table. (The ISA has no shift-LEFT instruction, so "the value
// lives at bit k" would have cost two instructions per bit to fix up.)
//
// The cost of the rule is that firmware must MASK a read, because a read
// returns all 8 bits. The mask is the pin's own bit -- `AND A, 8` for the
// shared input pin below. Every test of a pin is a zero/nonzero test, so the
// mask is a constant, not a shift.
//
// ASSIGNMENT -- ONE MAP THAT SERVES BOTH BASELINE PROTOCOLS:
//
//   bit 0  out  UART TX      / SPI SCLK
//   bit 1  out  (spare)      / SPI MOSI
//   bit 2  out  (spare)      / SPI CS_N
//   bit 3  in   UART RX      / SPI MISO
//   7:4    in   unclaimed
//
// so PIN_IN_MASK = 8'hF8 (outputs 0-2, inputs 3-7). The two protocols share
// one build-time mask on purpose. The mask cannot be changed at run time, so a
// mask that served only one of them would mean the chip could not be
// reprogrammed from UART to SPI without a rebuild -- which is the one thing
// this whole design exists to disprove. SPI needs three outputs and one input,
// and both fit in the three-low-outputs / high-inputs shape.

// WHY THE PORT IS 8 BITS WIDE WHEN A UART USES ONE.
//
// It started as a single pin each way, which is all a UART needs. SPI is the
// second baseline protocol and needs four (SCLK, MOSI, MISO, CS_N) all
// push-pull -- and it needs no pin matrix, because there is no open-drain, no
// arbitration and no clock stretching. Widening the port to 8 bits is the
// smallest change that makes SPI expressible as firmware, and it is what the
// plan calls for: "the SoC's single in/out pin generalised to a multi-bit
// port, which is a fraction of the matrix."
//
// The direction is deliberately still not a per-pin register. Nothing in the
// baseline needs one: UART and SPI are both push-pull, so every pin is an
// input or an output for the whole design and the split is a build-time
// decision (PIN_IN_MASK). The pin MATRIX, which is the next milestone and
// needed for open-drain, is where per-pin direction belongs. Adding a
// direction register now would be hardware nothing exercises -- see
// STATUS gotcha 14.
//
// Sizing rationale: IMEM 1024 x 16 words, DMEM 16 x 8 = 128 bits, plus 8 bits
// of timer. The instruction memory is the SRAM macro (ADR-003/ADR-004).

module pe_uart_soc #(
  parameter int IMEM_WORDS = 1024,
  parameter int DMEM_BYTES = 16,
  parameter int BAUD       = 115_200,
  parameter int IMEM_FLOP  = 0,    // 0 = SRAM macro, 1 = register array
  // Which of the 8 port bits are INPUTS. Outputs are the low bits starting at
  // bit 0; inputs are the remaining high bits. Default 8'hF8 = outputs 0-2,
  // inputs 3-7, which is the shared UART/SPI map (see the header).
  //
  // A build-time constant rather than a register on purpose: the baseline
  // protocols are all push-pull, so direction never changes at runtime.
  parameter logic [7:0] PIN_IN_MASK = 8'hF8
) (
  input  logic        clk,
  input  logic        rst_n,

  // Firmware loading + control (the host interface)
  input  logic        host_we,
  input  logic        host_imem_sel,   // 1: host_addr indexes imem, 0: dmem
  // Wide enough to name any instruction word -- it was 8 bits when IMEM was
  // 128 deep, which would silently alias the loader past word 255. The width
  // expression is repeated inline because Icarus binds port dimensions before
  // later localparams are visible (same workaround as pe_cpu.v).
  input  logic [((((IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS)) > 8)
                 ? ((IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS)) : 8)-1:0] host_addr,
  input  logic [15:0] host_wdata,
  input  logic        run,

  // The protocol pin port. Everything else is software.
  // Inputs and outputs are separate buses -- there is no tristate and no
  // per-pin direction register (see the header). PIN_IN_MASK says which bits of
  // pin_in are real; the rest are ignored.
  input  logic [7:0]  pin_in,
  output logic [7:0]  pin_out,

  // Observability
  output logic [7:0]  dbg_pc,
  output logic [7:0]  dbg_a,
  output logic [7:0]  dbg_timer
);

  localparam int IAW = (IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS);
  localparam int DAW = (DMEM_BYTES <= 2) ? 1 : $clog2(DMEM_BYTES);

  // ---- THE OPERATING POINT IS LOCKED AT 60 MHz ---------------------------
  //
  // CLK_HZ was a parameter. It is a module-local constant now, and that is a
  // deliberate downgrade in flexibility, because the flexibility was never
  // real: NOTHING instantiated this SoC at any other rate. The TT top level
  // passed 60_000_000 -- the same value as the default it was overriding --
  // and every testbench passed 60_000_000.
  //
  // A parameter nobody varies is not a knob. It is a second place for the
  // derived arithmetic to disagree with the first, and this project has paid
  // for that twice already: the 40 -> 60 MHz switch left the tick at 173 in
  // comments across four files, and the I2C plan carried "1 us = 40 clocks"
  // long after the tick had become 60.
  //
  // 60 MHz is a property of the BOARD and of the protocol arithmetic, not of a
  // build. It is exact for every hard protocol -- 50 ns half-UI is exactly 3
  // ticks, USB-LS 666.67 ns is exactly 40 -- and the demo board generates it
  // directly (ADR-005). There is no configuration in which this number is
  // different, so it is written once, here, and derived from everywhere else.
  localparam int CLK_HZ = 60_000_000;

  // The timer runs at 2x the baud rate: one increment per HALF bit period.
  // Half-bit resolution is required, not a luxury -- sampling on whole-bit
  // ticks can only land on bit BOUNDARIES, which is the worst place to
  // sample a serial line. Firmware counts 2 ticks per bit to stay mid-cell.
  // 60 MHz / 115200 / 2 = 260.42, so TICKS_PER_BIT is 260 (integer division)
  // and the delivered baud is 115,385 (+0.16% -- inside the ~2% UART budget).
  // Still an approximation rather than an exact integer like the 10BASE-T
  // plan, and it is the ONE protocol constant here that is not exact at
  // 60 MHz; see reference/clock-arithmetic.md for the whole table.
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
  // Instruction memory: pe_imem owns the storage. It is a REAL SRAM macro
  // (1P_1024x16_c2_bm_bist) by default, with a register-array fallback behind
  // IMEM_FLOP for tests and area experiments.
  //
  // `ram_style` used to sit here as an FPGA pragma that did nothing in this flow;
  // it is gone, because the memory is no longer inferred -- it is instantiated.
  // See decisions/adr-004-program-counter-width.md for the macro's contract and
  // the two traps (BM=0 is a silent write no-op; REN during a write is
  // write-through), and rtl/pe_imem.v for how they are handled.
  pe_imem #(.WORDS(IMEM_WORDS), .FLOP(IMEM_FLOP)) u_imem (
    .clk(clk),
    .imem_addr(imem_addr),
    .imem_rdata(imem_rdata),
    .host_we(host_we && host_imem_sel),
    .host_addr(host_addr[IAW-1:0]),
    .host_wdata(host_wdata)
  );

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
  logic [7:0]      pin_rd;        // pad state: inputs from pin_in, outputs read back

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

  // ---- the pin port ------------------------------------------------------
  // Registered so firmware sees clean levels and the TB can observe them. All
  // 8 bits are driven; the mask decides which bits come from pin_in rather
  // than from the last write.
  //
  // A write drives ALL the output bits at once -- there is no per-pin set or
  // clear. That is the natural consequence of one write port, and it is why
  // firmware keeps the output byte as a single value and composes each change
  // (OR to raise a pin, AND-mask to lower one) rather than imagining it can
  // poke a single pin. Reading PINOUT back gives the current byte for
  // read-modify-write, so no shadow copy is required in dmem.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pin_out <= 8'h01;
      // Reset drives bit 0 high, which is the UART TX idle level -- the safe
      // state for the protocol that is resident at reset, since a low TX line
      // reads to a peer as a start bit. It is NOT a sensible SPI idle (mode 0
      // wants SCLK low and CS_N high) and it does not need to be: SPI firmware
      // writes the port's idle pattern as its first act, before it asserts CS_N.
      // A reset value that cannot serve both protocols is the honest
      // consequence of one shared port, not a defect to paper over with a
      // value that is wrong for the protocol actually running.
    else if (io_we && io_port == 4'h1)
      // A write sets the OUTPUT bits only. Driving an input bit here would
      // make pin_out disagree with the pad the input comes from, and firmware
      // reading PINOUT back would see a value the outside world never had.
      pin_out <= (pin_out & PIN_IN_MASK) | (io_wdata & ~PIN_IN_MASK);
  end

  // Input bits mirror the pad; output bits read back what was written. That
  // makes a single read give firmware the whole port state -- inputs it can
  // act on and outputs it can verify, in one instruction.
  assign pin_rd = (pin_in & PIN_IN_MASK) | (pin_out & ~PIN_IN_MASK);

  // ---- IO read mux ------------------------------------------------------
  always_comb begin
    case (io_port)
      4'h0:    io_rdata = pin_rd;
      4'h1:    io_rdata = pin_rd;             // same view; writes go to pin_out
      4'h5:    io_rdata = tick_val;
      4'h7:    io_rdata = {7'b0, tick_flag};
      default: io_rdata = 8'h00;
    endcase
  end

endmodule
