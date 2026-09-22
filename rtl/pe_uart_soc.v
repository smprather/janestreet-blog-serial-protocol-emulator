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
//   0x0  PIN     r   the port's levels: driven pins read back what we wrote,
//                    RELEASED pins read the pad (see the matrix note below)
//   0x1  PINOUT  w   drive the port's output levels
//   0x1  PINOUT  r   readback of those levels
//   0x2  PINOE   w/r per-pin output enable: 1 = drive, 0 = RELEASE (high-Z)
//   0x3  PINOD   w/r per-pin open-drain: with 1, a pin holding 1 is released
//   0x4  I2CTICK r   free-running 1 microsecond counter, for I2C bit timing
//   0x5  TIMER   r   free-running 8-bit counter, one increment per half bit
//   0x6  I2CSTAT r   bit0 = "an I2C tick happened" (cleared by this read)
//   0x7  STATUS  r   bit0 = "a timer tick happened" (cleared by this read)
//
// PORTS 0x2 AND 0x3 ARE THE I2C MILESTONE. Everything before them assumed pin
// direction was a BUILD-TIME decision, and that was true and cheap: UART and
// SPI are both push-pull, so every pin is an input or an output for the whole
// design. I2C breaks that. SDA is driven low, RELEASED (allowed to float up to
// the board's pull-up), and READ BACK -- often within one bit cell, because
// arbitration means the master must compare the level it drove against the
// level the bus actually has. `rtl/pe_pinmux.v` is that register file; it is
// instantiated HERE rather than in the TT wrapper, and the reason is worth
// recording because the plan said otherwise:
//
//   The plan (wiki/plans/through-i2c.md) and wiki/concepts/pin-matrix.md both
//   say "the TT wrapper instantiates the matrix in front of the SoC's port".
//   As written that cannot work: the CPU's IO bus (io_port/io_we/io_wdata/
//   io_rdata) never crosses this module's boundary, so a matrix living in the
//   wrapper would have NO way for firmware to write OE or OD. It would be dead
//   hardware for the one protocol it exists to serve.
//
//   So the matrix lives here, where the IO decode is. The wrapper still owns
//   the pads -- it maps port bits to `uio` and forwards `pad_oe` to `uio_oe`.
//
// THE PORT NUMBERING RULE: outputs low, inputs high.
//
// Bit 0 is the lowest OUTPUT, and the INPUTs occupy a contiguous run of the
// HIGH bits; PIN_IN_MASK records where the split falls. That is the whole rule,
// and the write path below is exactly it: input bits keep their value, output
// bits take the written value.
//
// PIN_IN_MASK is now the RESET DIRECTION rather than the permanent one. It
// seeds the matrix's OE register (`RST_OE = ~PIN_IN_MASK`), so the reset state
// is bit-identical to the fixed-mask SoC this replaces -- which is what lets
// tb_pe_uart_soc and tb_pe_tick_status keep signing off the same behaviour.
// Firmware may change any pin's direction at runtime; UART and SPI simply
// never do.
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
// ASSIGNMENT -- ONE MAP THAT SERVES ALL THREE BASELINE PROTOCOLS:
//
//   bit 0  UART TX      / SPI SCLK
//   bit 1  (spare)      / SPI MOSI
//   bit 2  (spare)      / SPI CS_N
//   bit 3  UART RX      / SPI MISO
//   bit 4  I2C SDA      (bidirectional, open-drain)
//   bit 5  I2C SCL      (bidirectional, open-drain)
//   7:6    unclaimed
//
// so PIN_IN_MASK = 8'hF8 (outputs 0-2, inputs 3-7). All three protocols share
// one reset mask on purpose. The mask seeds a register now, so a program can
// flip any pin at runtime -- which is the one thing this whole design exists
// to demonstrate, and it is why I2C needed no new chip, only new firmware.

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
  // Inputs and outputs are separate buses -- there is no tristate at THIS
  // boundary; `pin_oe` carries the per-pin direction out to the wrapper, which
  // is where the real pads live. PIN_IN_MASK says which bits of pin_in are real
  // at reset; firmware can change any pin's direction afterwards (see the
  // header's matrix note).
  input  logic [7:0]  pin_in,
  output logic [7:0]  pin_out,
  output logic [7:0]  pin_oe,

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

  // ---- the pin port: pe_pinmux, not a fixed mask -------------------------
  // This used to be an always_ff holding pin_out, with PIN_IN_MASK deciding
  // which bits came from the pad and which from the last write. It is now the
  // matrix register file, and the reset seed makes it EQUIVALENT to that logic:
  //
  //     RST_OE  = ~PIN_IN_MASK   (drive the outputs, release the inputs)
  //     RST_OD  = 0              (push-pull everywhere, as before)
  //     RST_OUT = PIN_OUT_RST    (TX idles high; see the note below)
  //
  // so with firmware that never writes PINOE or PINOD, the pad behaviour and
  // the port read-back are IDENTICAL to the old fixed-mask SoC. That is
  // deliberate: it is what lets tb_pe_uart_soc and tb_pe_tick_status keep
  // signing off UART and SPI while I2C gets the runtime direction it needs. A
  // separate, parallel port would have been two mechanisms for one job.
  //
  // One honest difference, recorded rather than glossed: the old logic masked
  // the WRITE (`pin_out <= (pin_out & MASK) | (wdata & ~MASK)`), so pin_out's
  // input bits kept their reset value forever. The matrix stores the whole byte,
  // so pin_out[7:3] now carries whatever was last written. Nothing observes it:
  // those bits are released (so no pad sees the level) and the wrapper routes
  // only bits 0, 4 and 5. The READ-BACK is unaffected, because a released bit
  // reads the pad either way -- which is the property the firmware relies on.
  // If a future protocol routes bit 4/5 while ALSO leaving them released, the
  // pad level is what matters and that is unchanged.
  //
  // Reset OUT is 8'h01 rather than the matrix's own all-ones default: bit 0
  // high is the UART TX idle level, and the SoC is what knows a UART is
  // resident at reset. A low TX line reads to a peer as a start bit. (The
  // matrix cannot guess a protocol from its pins, so it does not try -- see
  // pe_pinmux's header.)
  localparam logic [7:0] PIN_OUT_RST = 8'h01;

  logic [7:0] pinmux_rdata;
  logic       pinmux_we;
  logic [1:0] pinmux_waddr, pinmux_raddr;

  // THE TWO NUMBERING SCHEMES ARE NOT THE SAME, and assuming they were is a bug
  // that hung the UART testbench:
  //
  //   SoC port       matrix register
  //   --------       ---------------
  //   0  PIN   r     A_OUT = 0
  //   1  PINOUT w    A_OE  = 1
  //   2  PINOE      A_IN  = 2   (read-only)
  //   3  PINOD      A_OD  = 3
  //
  // Port 1 is where firmware has always written the output LEVEL, and the
  // matrix keeps that level in register 0. An identity map (`addr = io_port`)
  // therefore pointed `OUT TXPIN, A` straight at the ENABLE register: the write
  // set OE instead of the level, the TX pin was released rather than driven, and
  // tb_pe_uart_soc hung waiting for a start bit that could never be driven.
  //
  // The mapping is explicit rather than clever because the constraint is real:
  // port 0/1 are fixed by the verified UART and SPI firmware (they do
  // read-modify-write on them), and the matrix's register order is fixed by
  // tb_pe_pinmux's 7/7 mutation battery. Neither can be renumbered for
  // cosmetic alignment, so the translation lives here, named.
  localparam logic [1:0] A_OUT = 2'd0,
                         A_OE  = 2'd1,
                         A_IN  = 2'd2,
                         A_OD  = 2'd3;

  // Write address: only ports 1-3 are writable, and each one names its register.
  always_comb begin
    case (io_port)
      4'h1:    begin pinmux_waddr = A_OUT; pinmux_we = io_we; end
      4'h2:    begin pinmux_waddr = A_OE;  pinmux_we = io_we; end
      4'h3:    begin pinmux_waddr = A_OD;  pinmux_we = io_we; end
      // A write to PIN (0x0) is a no-op, and the read-only ports stay
      // read-only, so the write port remains total -- which is what the SoC's
      // IO decode assumes (see pe_pinmux's own note on the same point).
      default: begin pinmux_waddr = A_IN;  pinmux_we = 1'b0;  end
    endcase
  end

  // Read address: ports 2 and 3 read their own register; the matrix's IN
  // register is not exposed on its own port because the pad level is already
  // visible as the released-pin part of port 0.
  always_comb begin
    case (io_port)
      4'h2:    pinmux_raddr = A_OE;
      4'h3:    pinmux_raddr = A_OD;
      default: pinmux_raddr = A_IN;
    endcase
  end

  pe_pinmux #(
    .PINS(8),
    .RST_OE (~PIN_IN_MASK),
    .RST_OUT(PIN_OUT_RST),
    .RST_OD (8'h00)
  ) u_pinmux (
    .clk(clk),
    .rst_n(rst_n),
    .we(pinmux_we),
    .addr(pinmux_we ? pinmux_waddr : pinmux_raddr),
    .wdata(io_wdata),
    .rdata(pinmux_rdata),
    .pad_in(pin_in),
    .pad_out(pin_out),
    .pad_oe(pin_oe)
  );

  // ---- the I2C tick: 1 microsecond ---------------------------------------
  // A SECOND, coarser tick, because I2C's unit is the microsecond and the UART
  // timer's unit is half a bit period. Reusing TIMER for both is not possible:
  // 260 clocks is 4.33 us, which is not a Standard-mode interval, and rescaling
  // it in firmware would put a multiply in every bit cell. One more divider is
  // ~13 flops and makes every I2C constant a small integer (tLOW = 5, tHIGH =
  // 6, tSU;STA = 5 -- see wiki/plans/through-i2c.md).
  //
  // 60 MHz / 1 MHz = 60 exactly, so this divider has no rounding error at all.
  // Same one-process, set-beats-clear structure as the UART tick, for the same
  // reason (two always_ff blocks on one flag is a driver-driver conflict that
  // Icarus and yosys resolve differently -- see the note below).
  localparam int I2C_TICKS = CLK_HZ / 1_000_000;
  localparam int CNTWI     = (I2C_TICKS < 4) ? 2 : $clog2(I2C_TICKS);

  logic [CNTWI-1:0] i2c_cnt;
  logic [7:0]       i2c_val;
  logic             i2c_flag;
  logic             i2c_now, i2cstat_rd;

  assign i2c_now     = (i2c_cnt == CNTWI'(I2C_TICKS - 1));
  assign i2cstat_rd  = io_re && (io_port == 4'h6);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      i2c_cnt  <= '0;
      i2c_val  <= 8'h00;
      i2c_flag <= 1'b0;
    end else begin
      if (i2c_now) begin
        i2c_cnt <= '0;
        i2c_val <= i2c_val + 8'd1;
      end else begin
        i2c_cnt <= i2c_cnt + 1'b1;
      end

      if (i2c_now)         i2c_flag <= 1'b1;   // set beats clear
      else if (i2cstat_rd) i2c_flag <= 1'b0;
    end
  end

  // The port 0/1 view: a pin we are DRIVING reads back what we wrote; a pin we
  // have RELEASED reads the pad. Note the term is `pin_oe` -- the matrix's
  // actual drive enable -- not the OE register, because in open-drain mode a
  // pin holding 1 is released even though its OE bit is set. Using the real
  // enable is what makes arbitration visible on port 0 for free: release SDA
  // to send a 1, read port 0, and bit 4 IS the bus level.
  //
  // This is also EXACTLY the old `(pin_in & PIN_IN_MASK) | (pin_out &
  // ~PIN_IN_MASK)` whenever od=0 and the OE register still equals
  // ~PIN_IN_MASK, which is the UART/SPI case. Same expression, generalised.
  assign pin_rd = (pin_out & pin_oe) | (pin_in & ~pin_oe);

  // The port read mux.
  //
  // Port 0/1 keep the OLD combined view -- driven pins read back what firmware
  // wrote, released pins read the pad -- because SPI firmware does
  // read-modify-write on port 0 (`IN A, PIN` / `OR` / `OUT TXPIN, A`) and a
  // view that differed from the old one would break it silently. The matrix's
  // own IN register is the pure pad level, exposed at port 2 as the enable
  // register when READ.
  //
  //   port 2 read = PINOE, not the pad. The pad level is already available as
  //   the released-pin part of port 0, and giving firmware a read-modify-write
  //   of the enable register matters more for I2C than a second pad view.
  always_comb begin
    case (io_port)
      4'h0:    io_rdata = pin_rd;
      4'h1:    io_rdata = pin_rd;             // same view; writes go to PINOUT
      4'h2:    io_rdata = pinmux_rdata;       // PINOE
      4'h3:    io_rdata = pinmux_rdata;       // PINOD
      4'h4:    io_rdata = i2c_val;
      4'h5:    io_rdata = tick_val;
      4'h6:    io_rdata = {7'b0, i2c_flag};
      4'h7:    io_rdata = {7'b0, tick_flag};
      default: io_rdata = 8'h00;
    endcase
  end

endmodule
