// pe_soc.v — the smallest processor + RAM that can speak a protocol.
//
// There is no protocol-SPECIFIC hardware in this file. No UART state machine,
// no framing logic, no baud generator that knows what a bit is. There is a CPU,
// a tick counter, a generalised pin port, a shared WORD ENGINE (pe_serdes plus
// two codec pipelines — wiki/plans/serdes-integration.md), and the rest is
// software (firmware/uart_echo.pe).
//
// That is the whole point: swap the program and this speaks I2C, or SWD, or
// something nobody has written yet, with the gates unchanged. The engine is a
// PACING resource, not a mode: it exists because firmware cannot bit-bang
// 20 MHz half-cells or USB's NRZI+stuffing chain. Word width, bit order, line
// code and strobe cadence are registers firmware writes through port 0xF;
// nothing in the engine knows framing, addresses, ACKs, or a protocol name.
// It is disabled at reset and the pad overlay is off, so every baseline
// persona and firmware image stays bit-identical (see the engine section).
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
//   0x8  ETHSTAT r   {5'b0, is_type, bad, valid}; reading CLEARS valid/bad
//   0x9  ETHLEN  r   frame_len[7:0]    (latched with frame_valid)
//   0xA  ETHLENH r   frame_len[15:8]
//   0xB  ETHFLD  r   frame_field[7:0]  (the length/EtherType field as received)
//   0xC  ETHFLDH r   frame_field[15:8]
//   0xD  BUFBYTE r   next byte of the received frame; the read ADVANCES the
//                    window pointer. ONE-CYCLE PIPELINE: fbuf's read data
//                    arrives the cycle after its address, so consecutive
//                    BUFBYTE reads must be at least one cycle apart (a
//                    firmware loop always is; see firmware/eth_rx.pe).
//   0xE  BUFCTRL w   bit0 pulse: release the bytes firmware has consumed --
//                    the MAC's read pointer moves to the current BUFBYTE
//                    window position. Safe while the next frame is arriving:
//                    it never touches the write pointer.
//   0xF  ENGINE  r/w the 32-entry indexed window shared by the word engine
//                    and the 10BASE-T TX frame engine: a write in INDEX phase
//                    sets the 5-bit pointer, a write in DATA phase stores and
//                    auto-increments (a burst is one index write plus N data
//                    writes), and ANY read returns REG[INDEX], auto-
//                    increments, and re-arms INDEX phase. Lower bank (0-15) =
//                    the word engine's registers (CFG/DIV/TXLEN/RXLEN/TXDATA/
//                    RXDATA/STATUS; see the engine section). Upper bank:
//                      16-23  push a byte into the TX engine's 8-byte
//                             staging FIFO; the pointer wraps inside 16-23 so
//                             a burst can never land in TXLEN/TXCTRL
//                      24/25  TXLENL / TXLENH[2:0] (stored bytes, 14..1514)
//                      26     TXCTRL: bit0 frame_start strobe, bit1
//                             frame_abort strobe, bit2 tx_path (persistent
//                             codec owner, reads back). tx_path is a LEVEL:
//                             every TXCTRL write sets it to bit2, and the
//                             clear is refused while tx_busy (the set is not).
//                             A frame_start write therefore includes bit2=1.
//                      27     TXSTAT read: {2'b0, ifg_active, fifo_ready,
//                             tx_overlong, tx_underrun, tx_done, tx_busy}
//                             with the three event bits set-beats-clear on
//                             the read
//                      28-31  spare
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
// tb_pe_soc_uart and tb_pe_soc_tick keep signing off the same behaviour.
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

module pe_soc #(
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

  // ---- R2: the bounded host READ port -----------------------------------
  // A debug-only read path for the host controller (READ_IMEM / READ_DMEM).
  // NOT_READY while run=1 is decided by pe_ctrl, which only issues these
  // requests while the CPU is stopped -- that is what makes the address
  // arbitration below safe: a stopped pe_cpu holds imem_addr at 0 and leaves
  // dmem_addr idle, so the host can take the address bus without fighting the
  // fetch.
  //   dbg_rd_req    1-cycle pulse: start a read of dbg_rd_addr
  //   dbg_rd_dmem   0 = one instruction WORD, 1 = one data BYTE (low 8 bits)
  //   dbg_rd_valid  1-cycle pulse one cycle after the request: dbg_rd_data is
  //                 valid. Instruction memory is a REGISTERED-read macro, so
  //                 its data can only be captured on the following edge; the
  //                 data buffer is a flop array with a combinational read, and
  //                 is given the same one-cycle latency so the host contract
  //                 has ONE shape for both memories.
  input  logic        dbg_rd_req,
  input  logic        dbg_rd_dmem,
  input  logic [15:0] dbg_rd_addr,
  output logic [15:0] dbg_rd_data,
  output logic        dbg_rd_valid,

  // The protocol pin port. Everything else is software.
  // Inputs and outputs are separate buses -- there is no tristate at THIS
  // boundary; `pin_oe` carries the per-pin direction out to the wrapper, which
  // is where the real pads live. PIN_IN_MASK says which bits of pin_in are real
  // at reset; firmware can change any pin's direction afterwards (see the
  // header's matrix note).
  input  logic [7:0]  pin_in,
  output logic [7:0]  pin_out,
  output logic [7:0]  pin_oe,

  // Observability. R2: full native widths, no truncation. dbg_pc used to be
  // 8 bits wide, so a PC above 255 read back as zero in a 1,024-word machine;
  // the host read path must be able to report the real register. dbg_x,
  // dbg_y and dbg_insn are new for the non-halting READ_CPU answer.
  output logic [((IMEM_WORDS <= 2) ? 1 : ((IMEM_WORDS <= 256) ? 8 : $clog2(IMEM_WORDS)))-1:0] dbg_pc,
  output logic [7:0]  dbg_a,
  output logic [7:0]  dbg_x,
  output logic [7:0]  dbg_y,
  output logic [15:0] dbg_insn,
  output logic [7:0]  dbg_timer
`ifdef FORMAL
  // ---- FORMAL-ONLY OBSERVATION PORTS (manager ruling 2026-09-25) --------
  // Target 4: the codec owner mux. The subject is internal (tx_path and the two
  // engines' busy wires), and the window writes that move the owner come from
  // the CPU's IO bus, so the claims are stated as one-step transitions over
  // these aliases rather than by modelling a firmware program. FORMAL is never
  // defined in synthesis (tools/check_formal_ifdef.sh enforces it).
  //
  // fv_ser_busy_seen / fv_eth_busy_seen are the values THE GUARD ITSELF saw,
  // sampled inside the window-write always_ff. A port alias of the same wires
  // is a DIFFERENT sampled copy after clk2fflogic, and an arbitrary induction
  // state can set the copies inconsistently -- exactly what made the
  // owner-guard claims non-inductive until this tap existed.
  ,output logic        fv_tx_path
  ,output logic        fv_eth_tx_owner
  ,output logic        fv_ser_busy_seen
  ,output logic        fv_eth_busy_seen
  ,output logic        fv_set_took
`endif
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
  // flops, which is where pe_soc's ~8.7k cells come from. The attributes
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
  // The CPU's own address buses. Declared before the data-buffer write above
  // (Icarus binds declaration before use) and before the instance below.
  wire [IAW-1:0] cpu_imem_addr;
  wire [DAW-1:0] cpu_dmem_addr;

  // The data buffer's read address is arbitrated too (dmem_rd_addr), because
  // the R2 host read borrows the same flop array. dmem_byte is the selected
  // byte; dmem_rdata is what the CPU sees.
  wire [DAW-1:0] dmem_rd_addr;
  wire [7:0]     dmem_byte = dmem[dmem_rd_addr];
  assign dmem_rdata = dmem_byte;

  always_ff @(posedge clk) begin
    if (dmem_we) dmem[cpu_dmem_addr] <= dmem_wdata;
    if (host_we && !host_imem_sel && (32'(host_addr) < DMEM_BYTES))
      dmem[host_addr[DAW-1:0]] <= host_wdata[7:0];
  end

  pe_cpu #(.IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES)) u_cpu (
    .clk(clk), .rst_n(rst_n), .run(run),
    .imem_addr(cpu_imem_addr), .imem_rdata(imem_rdata),
    .dmem_addr(cpu_dmem_addr), .dmem_we(dmem_we),
    .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
    .io_port(io_port), .io_we(io_we), .io_re(io_re),
    .io_wdata(io_wdata), .io_rdata(io_rdata),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
    .dbg_insn(dbg_insn)
  );

  // ---- R2: the bounded host read port ------------------------------------
  // One request/answer shape for both memories, one cycle of latency:
  //   imem  -> the addressed instruction WORD (the macro read is registered,
  //            so the answer can only be captured on the next edge);
  //   dmem  -> the addressed BYTE in dbg_rd_data[7:0] (the flop array reads
  //            combinationally; it is given the same latency so the host
  //            contract has one shape, and so a byte pair can be assembled
  //            from two consecutive answers).
  // The request is held for one cycle by the caller through dbg_rd_req; the
  // answer pulses dbg_rd_valid. pe_soc does NOT range-check: R2 puts the
  // bounds in pe_ctrl, which owns the response status and the sticky
  // FAULT_RANGE, so the check lives in exactly one place.
  wire dbg_reading = dbg_rd_req | dbg_rd_valid;
  wire [15:0] dbg_addr = dbg_rd_dmem ? {8'b0, dbg_rd_addr[7:0]}
                                     : dbg_rd_addr;
  wire _unused_dbg_addr_hi = &{1'b0, dbg_addr[15:10]};

  // Address arbitration: the host owns the read address while a read is in
  // flight. run=0 is the precondition enforced by pe_ctrl, so the CPU's own
  // address is not being fetched from at that moment.
  assign imem_addr = dbg_reading && !dbg_rd_dmem ? dbg_addr[IAW-1:0]
                                                 : cpu_imem_addr;
  assign dmem_rd_addr = dbg_reading && dbg_rd_dmem ? dbg_addr[DAW-1:0]
                                                   : cpu_dmem_addr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_rd_valid <= 1'b0;
      dbg_rd_data  <= 16'h0000;
    end else begin
      dbg_rd_valid <= dbg_rd_req;      // the answer, one cycle later
      if (dbg_rd_req)
        dbg_rd_data <= dbg_rd_dmem ? {8'h00, dmem_byte}
                                   : imem_rdata;
    end
  end

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
  // deliberate: it is what lets tb_pe_soc_uart and tb_pe_soc_tick keep
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

  // The word engine's pad overlay (declared HERE because the matrix sits
  // above the engine section, which comes after the 10BASE-T chain): a
  // per-pin level override feeding the matrix BEFORE its open-drain gate.
  // eng_ov_en is all-zero unless the engine is enabled, so the matrix is
  // bit-identical at reset and for every baseline persona.
  wire [7:0] eng_ov_en;
  wire       eng_tx_wire;

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
  // tb_pe_soc_uart hung waiting for a start bit that could never be driven.
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
    .ov_en(eng_ov_en),
    .ov_bit(eng_tx_wire),
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

  // =========================================================================
  // 10BASE-T receive: pe_dru -> pe_manch -> pe_eth_mac, + pe_crc + pe_fbuf
  // =========================================================================
  //
  // WHY IT IS HERE. pe_eth_mac was built and TB-proven while instantiated
  // NOWHERE, and it is the block that ties four other orphans (pe_dru,
  // pe_manch, pe_crc, pe_fbuf) into one signal path. An orphan block is a
  // claim that has never been exercised inside a design, so the SoC instance
  // is what retires the claim. This is also the first protocol in the project
  // that is NOT firmware: wiki/concepts/ethernet-scope.md's arithmetic (48
  // instructions per byte at 100 ns/bit, ~240 for a software CRC-32) is why
  // the bit work is hardware and the firmware only sequences frames.
  //
  // WHY PORT BIT 7. The port rule is "outputs low, inputs high" and the
  // baseline protocols already claim bits 0-5 (UART TX/RX, SPI, I2C SDA/SCL
  // -- see the header's assignment table). Bit 7 is unclaimed and is an input
  // under the reset mask 8'hF8, so the DRU gets a released pad to listen to.
  // The DRU takes the RAW pin and does its own synchronizing (a two-flop
  // synchronizer plus the latch-pair DDR front end, ADR-002) -- it must not
  // take a registered level.
  //
  // WHY THE WINDOW IS REGISTERS AND NOT A FIFO. The MAC owns the ring's
  // lifetime and the CPU is 16 bytes of data memory; firmware cannot hold a
  // frame. So frame_valid latches the header and arms a read pointer at the
  // frame's FIRST STORED BYTE, and BUFBYTE walks it. On frame_valid the MAC's
  // pointer has already been wound back for a type frame, so `ptr - len` is
  // the start for BOTH frame kinds (type: ptr = start + pay_cnt - 4 and
  // len = pay_cnt - 4; length: ptr = start + pay_cnt and len = pay_cnt).
  //
  // THE LIMITS, STATED. There is ONE window, not a queue: a second frame that
  // completes before firmware has read the first overwrites the latched
  // header (the bytes stay in the ring). A frame landing mid-walk also wins
  // the fbuf port over the walk read (the write path has priority in
  // pe_fbuf), so that read returns the previous byte. Firmware consumes a
  // frame in ~500 cycles against a ~50 us wire time, so neither is reachable
  // here; a general stack would need a producer/consumer handshake that this
  // milestone does not.
  localparam int ETH_RX_BIT = 7;
  localparam int FBUF_BYTES = 2048;
  localparam int FBUF_AW    = 11;      // $clog2(2048)

  logic              eth_bit_en, eth_rx_first, eth_rx_second, eth_rx_wire;
  logic              eth_locked;
  logic [3:0]        eth_phase;
  logic              eth_rx_raw, eth_rx_err;
  // The chain's transmit-side outputs. This integration is RECEIVE-ONLY, so
  // they have no consumer -- but an empty connection is a Verilator
  // PINCONNECTEMPTY warning and this repo accepts none, so they are sunk like
  // the other unused observability below.
  logic              eth_manch_tx_wire, eth_crc_bit;

  logic              eth_crc_bit_en, eth_crc_clr, eth_crc_bit_in;
  logic              eth_crc_field_out, eth_crc_zero;
  logic [31:0]       eth_crc_state;

  logic              eth_fbuf_we;
  logic [FBUF_AW-1:0] eth_fbuf_waddr;
  logic [7:0]        eth_fbuf_wdata;

  logic               eth_frame_valid, eth_frame_bad, eth_frame_is_type;
  logic [15:0]        eth_frame_len, eth_frame_field;
  logic [FBUF_AW-1:0] eth_frame_ptr;
  logic [2:0]         eth_dbg_state;

  logic               eth_buf_consume;
  logic [FBUF_AW-1:0] eth_buf_raddr;
  logic [7:0]         eth_buf_rdata;
  logic [FBUF_AW-1:0] eth_frame_start;

  logic               eth_valid, eth_bad, eth_is_type;
  logic [15:0]        eth_len, eth_field;
  logic               ethstat_rd, bufbyte_rd;

  // Signals the chain exposes that this integration does not consume. RTL
  // lint has no waivers in this repo, so they are sunk explicitly (the same
  // pattern tt_um_protocol_emulator uses).
  wire _unused_eth = &{1'b0, eth_locked, eth_phase, eth_crc_zero,
                       eth_dbg_state, eth_manch_tx_wire, eth_crc_bit};

  assign ethstat_rd = io_re && (io_port == 4'h8);
  assign bufbyte_rd = io_re && (io_port == 4'hD);
  // BUFCTRL: release everything firmware has consumed. The address is the
  // current BUFBYTE window position, so the MAC's READ pointer advances to the
  // end of the frame just walked and the WRITE pointer is untouched -- a frame
  // already arriving keeps its own start and count (E1,
  // reviews/2026-09-23/ETHERNET-SOC-REVIEW.md).
  assign eth_buf_consume = io_we && (io_port == 4'hE) && io_wdata[0];
  assign eth_frame_start = eth_frame_ptr - eth_frame_len[FBUF_AW-1:0];

  pe_dru #(.SPB(12)) u_eth_dru (
    .clk(clk), .rst_n(rst_n),
    .rx_pin(pin_in[ETH_RX_BIT]),
    .cfg_filter_en(1'b0),          // the pin is driven cleanly in every TB
    .cfg_lock_bits(8'd4),          // the default confidence threshold
    .bit_en(eth_bit_en),
    .rx_first(eth_rx_first), .rx_second(eth_rx_second), .rx_wire(eth_rx_wire),
    .locked(eth_locked), .dbg_phase(eth_phase)
  );

  pe_manch u_eth_manch (
    .clk(clk), .rst_n(rst_n),
    .bit_en(eth_bit_en), .bypass(1'b0), .clr(1'b0), .half_phase(1'b0),
    .tx_raw(1'b0), .tx_wire(eth_manch_tx_wire),
    .rx_wire(eth_rx_wire),
    .rx_first(eth_rx_first), .rx_second(eth_rx_second),
    .rx_raw(eth_rx_raw), .rx_err(eth_rx_err)
  );

  // The receiver folds the field AS TRANSMITTED and compares against the
  // catalogue residue -- so crc_field_out is held LOW by the MAC and the
  // verdict is `crc_state == CRC_RESIDUE`, never `crc_zero`. Constants from
  // the generated wiki/reference/crc-config.md; do not hand-edit.
  pe_crc #(.W(32)) u_eth_crc (
    .clk(clk), .rst_n(rst_n),
    .bit_en(eth_crc_bit_en), .clr(eth_crc_clr),
    .crc_field(eth_crc_field_out), .bit_in(eth_crc_bit_in),
    .cfg_poly_r(32'hEDB88320),     // rev(0x04C11DB7, 32)
    .cfg_seed(32'hFFFFFFFF),
    .cfg_out_inv(1'b1),            // Ethernet's xorout is all ones
    .crc_bit(eth_crc_bit), .crc_zero(eth_crc_zero), .crc_state(eth_crc_state)
  );

  pe_eth_mac #(.BUF_BYTES(FBUF_BYTES)) u_eth_mac (
    .clk(clk), .rst_n(rst_n),
    .bit_en(eth_bit_en), .rx_raw(eth_rx_raw), .rx_err(eth_rx_err),
    .rx_first(eth_rx_first), .rx_second(eth_rx_second),
    .buf_reset(1'b0),              // the SoC never whole-ring-resets in traffic
    .buf_consume(eth_buf_consume),
    .buf_consume_addr(eth_buf_raddr),
    .crc_bit_en(eth_crc_bit_en), .crc_clr(eth_crc_clr),
    .crc_bit_in(eth_crc_bit_in), .crc_field_out(eth_crc_field_out),
    .crc_state(eth_crc_state),
    .fbuf_we(eth_fbuf_we), .fbuf_waddr(eth_fbuf_waddr),
    .fbuf_wdata(eth_fbuf_wdata),
    .frame_valid(eth_frame_valid), .frame_bad(eth_frame_bad),
    .frame_len(eth_frame_len), .frame_field(eth_frame_field),
    .frame_is_type(eth_frame_is_type), .frame_ptr(eth_frame_ptr),
    .dbg_state(eth_dbg_state)
  );

  pe_fbuf #(.BYTES(FBUF_BYTES), .FLOP(0)) u_eth_fbuf (
    .clk(clk),
    .we(eth_fbuf_we), .waddr(eth_fbuf_waddr), .wdata(eth_fbuf_wdata),
    .raddr(eth_buf_raddr), .rdata(eth_buf_rdata)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      eth_valid     <= 1'b0;
      eth_bad       <= 1'b0;
      eth_is_type   <= 1'b0;
      eth_len       <= '0;
      eth_field     <= '0;
      eth_buf_raddr <= '0;
    end else begin
      // A completed frame owns the window: latch the header and arm the byte
      // walk at the frame's first stored byte.
      if (eth_frame_valid) begin
        eth_valid     <= 1'b1;
        eth_is_type   <= eth_frame_is_type;
        eth_len       <= eth_frame_len;
        eth_field     <= eth_frame_field;
        eth_buf_raddr <= eth_frame_start;
      end
      // Set beats clear, for the same reason STATUS's tick flag does: a frame
      // landing on the cycle firmware reads the status must not be lost. A
      // dropped frame costs 100 us of wire time; re-reporting one costs one
      // extra poll.
      if (ethstat_rd) begin
        if (!eth_frame_valid) eth_valid <= 1'b0;
        if (!eth_frame_bad)   eth_bad   <= 1'b0;
      end
      if (eth_frame_bad) eth_bad <= 1'b1;
      // BUFBYTE advances the window. See the memory-map note on the
      // one-cycle read pipeline, and the header note on the read/write port
      // race.
      if (bufbyte_rd && !eth_frame_valid)
        eth_buf_raddr <= eth_buf_raddr + 1'b1;
    end
  end

  // =========================================================================
  // The word engine: pe_serdes + TWO pe_codec_mux instances + the 0xF window
  // =========================================================================
  //
  // WHY IT EXISTS AND WHY IT IS NOT "PROTOCOL HARDWARE". Firmware cannot
  // bit-bang 10BASE-T's 20 MHz half-cells or USB's NRZI+stuffing chain, so
  // the bit pacing is hardware -- but everything protocol-shaped (word
  // length, bit order, line code, cadence) is a register firmware writes
  // through the last free IO port, and the engine is DISABLED at reset with
  // the pad overlay off, so every baseline TB and firmware image is
  // bit-identical. See wiki/plans/serdes-integration.md and
  // reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md.
  //
  // TOPOLOGY (the follow-up review's amended shape):
  //   * ONE pe_serdes with SPLIT payload-only enables (tx_bit_en/rx_bit_en):
  //     with stuffing, TX must HOLD on each inserted cell while RX SKIPS
  //     each received one, and the wire loopback runs both directions at
  //     once, so one shared strobe cannot serve both sides;
  //   * TWO pe_codec_mux instances, unmodified -- one bit_en per ENCODED
  //     cell (payload + stuff slots), never per half-cell;
  //   * half_phase is a LEVEL (2x toggle from the divider) presented in the
  //     TX instance's cfg[3]; the RX instance carries 0 there (Manchester RX
  //     decodes from rx_first/rx_second);
  //   * the payload gates are CURRENT-cycle semantics, source-grounded in
  //     rtl/pe_bitstuff.v: during an inserted stuff cell tx_stuffed is the
  //     combinational output of the registered tx_pend for that whole
  //     strobe, and rx_bit_valid is low for a received stuff cell;
  //   * ONE capture path: the RX side takes the EXISTING DRU (u_eth_dru) for
  //     Manchester (strobe = eth_bit_en, halves = rx_first/rx_second) and
  //     the divider's cell strobe over the DRU's synchronized level for
  //     plain/NRZI/stuffed. Plain RX has NO phase acquisition -- self-timed
  //     wire-loopback scope only (the recommended default; recorded limit);
  //   * the TX wire reaches the pad through the matrix's level overlay
  //     (ov_en/ov_bit) BEFORE the open-drain gate; firmware still owns oe/od.
  //
  // CONTROL/STATUS: a 32-entry indexed window on port 0xF (the only free
  // port). INDEX-phase writes set the pointer, DATA-phase writes burst and
  // auto-increment, any read returns REG[INDEX]/auto-increments/re-arms INDEX
  // phase. tx_load, rx_start and clr are ONE-CYCLE write-triggered strobes
  // (the engines treat a held level as a restart or a permanent clear).
  // tx_done / rx_valid / rx_err event pulses are LATCHED for CPU polling
  // with set-beats-clear on a STATUS (index 6) read, so a poll loop cannot
  // miss them. The divider free-runs while the engine is enabled, which is
  // what keeps the timing block active through a possible TRAILING stuff
  // cell after serdes.tx_busy falls.
  //
  // START ALIGNMENT: tx_load/rx_start wait for the next cell boundary
  // (tx_load_pend/rx_start_pend), so bit0 occupies a full cell and the plain
  // RX path -- which samples the DRU's synchronized level a few clocks behind
  // the pad -- always sees it.
  //
  // THE 10BASE-T TX FRAME ENGINE shares this cadence and ONE codec instance.
  // pe_eth_tx (below, after the codecs) owns u_tx_codec.tx_bit while its
  // `tx_path` bit is set (owner mux below), and is otherwise held in IDLE by
  // `enable = eng_en && tx_path`. A frame start is refused while ser_tx_busy
  // so the two owners can never interleave mid-cell, and tx_path refuses to
  // clear while the frame engine is busy, so the owner cannot change under a
  // running frame. 10BASE-T personas select DIV=6 (100 ns/cell at the locked
  // 60 MHz) and cfg=0x04 (Manchester, no stuffing); the extended window's
  // upper bank above is how firmware feeds it. Reset keeps tx_path=0, so the
  // mux selects the SERDES and every pre-existing persona is bit-identical.

  localparam int SERDES_LENW = 6;   // 1..32 bits: LENW = clog2(MAXLEN+1) = 6

  // ---- the 0xF indexed window -------------------------------------------
  logic       win_phase;              // 0 = INDEX, 1 = DATA
  logic [4:0] win_index;
  logic [7:0] win_regs [0:31];
  logic [7:0] win_rdata;
  wire        win_we = io_we && (io_port == 4'hF);
  wire        win_re = io_re && (io_port == 4'hF);

  // ---- engine control state ---------------------------------------------
  logic eng_en, eng_lsb, eng_txsel;
  logic tx_load_strb, rx_start_strb, eng_clr_strb;

  // ---- 10BASE-T TX frame engine control/status --------------------------
  // tx_path is the codec owner bit; the two *_strb wires are one-cycle
  // strobes decoded from TXCTRL (index 26); push is a one-cycle strobe from
  // the window's push bank (16-23). The engine's outputs are declared with
  // the other instance wires below; eth_tx_busy must be visible to the
  // window process above them.
  logic       tx_path;
  logic       tx_frame_start_strb, tx_frame_abort_strb;
  logic       eth_push;
  logic [7:0] eth_push_byte;
  wire        eth_tx_bit, eth_tx_busy, eth_tx_done, eth_tx_underrun,
              eth_tx_overlong, eth_ifg_active, eth_fifo_ready, eth_start;
  wire        eth_tx_owner;
  wire        ser_tx, ser_tx_busy, ser_tx_done;   // declared with the owner wires:
                                                // the TXCTRL guard reads ser_tx_busy

  logic [7:0]  cfg_w;
  logic [15:0] div_w;
  logic [5:0]  tx_len_w, rx_len_w;
  logic [31:0] tx_word_w;
  always_comb begin
    cfg_w     = win_regs[1];                              // 1 CFG
    div_w     = {win_regs[3], win_regs[2]};               // 3:2 DIVH:DIVL
    tx_len_w  = win_regs[4][5:0];                         // 4 TXLEN
    rx_len_w  = win_regs[5][5:0];                         // 5 RXLEN
    tx_word_w = {win_regs[10], win_regs[9], win_regs[8], win_regs[7]};
  end

  wire manch_mode = cfg_w[2];

  // Window write/read + the control strobes. One process: the strobes are
  // one-cycle pulses (default-clear, set only by a CTRL/TXCTRL write bit),
  // and the readbacks store only the persistent bits (strobe bits read 0).
  // The upper bank's push/strobes are decoded here, not in a second process,
  // so there is exactly one writer per window register.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      win_phase    <= 1'b0;
      win_index    <= '0;
      for (int i = 0; i < 32; i++) win_regs[i] <= '0;
      eng_en       <= 1'b0;
      eng_lsb      <= 1'b0;
      eng_txsel    <= 1'b0;
      tx_load_strb <= 1'b0;
      rx_start_strb<= 1'b0;
      eng_clr_strb <= 1'b0;
      tx_path          <= 1'b0;
      tx_frame_start_strb <= 1'b0;
      tx_frame_abort_strb <= 1'b0;
      eth_push         <= 1'b0;
      eth_push_byte    <= 8'h00;
    end else begin
      tx_load_strb  <= 1'b0;
      rx_start_strb <= 1'b0;
      eng_clr_strb  <= 1'b0;
      tx_frame_start_strb <= 1'b0;
      tx_frame_abort_strb <= 1'b0;
      eth_push            <= 1'b0;
`ifdef FORMAL
      // formal-only: the busy values this block's guard sees at this edge,
      // and whether a TXCTRL SET write was actually TAKEN this edge (the
      // guard's own decision, not a re-derivation).
      fv_ser_busy_seen <= ser_tx_busy;
      fv_eth_busy_seen <= eth_tx_busy;
      fv_set_took      <= io_we && win_phase && (win_index == 5'd26)
                          && io_wdata[2] && !ser_tx_busy;
`endif

      if (win_we) begin
        if (!win_phase) begin
          win_index <= io_wdata[4:0];           // INDEX phase: set the pointer
          win_phase <= 1'b1;
        end else begin
          // DATA phase. CTRL (index 0) splits into the stored enables plus
          // the one-cycle strobes; 16-23 push into the TX staging FIFO and
          // wrap inside their own bank; TXCTRL (26) splits into strobes, the
          // persistent tx_path owner bit and its readback; everything else
          // stores the byte and the burst advances (phase stays DATA).
          if (win_index == 5'd0) begin
            eng_en        <= io_wdata[0];
            tx_load_strb  <= io_wdata[1];
            rx_start_strb <= io_wdata[2];
            eng_clr_strb  <= io_wdata[3];
            eng_lsb       <= io_wdata[4];
            eng_txsel     <= io_wdata[5];
            win_regs[0]   <= {2'b00, io_wdata[5], io_wdata[4],
                              3'b000, io_wdata[0]};
            win_index     <= 5'd1;
          end else if (win_index >= 5'd16 && win_index <= 5'd23) begin
            eth_push      <= 1'b1;
            eth_push_byte <= io_wdata;
            win_index     <= (win_index == 5'd23) ? 5'd16 : win_index + 5'd1;
          end else if (win_index == 5'd26) begin
            tx_frame_start_strb <= io_wdata[0];
            tx_frame_abort_strb <= io_wdata[1];
            // Persistent owner bit. NEITHER direction may move the owner while
            // an engine is mid-frame (manager ruling 2026-09-25, finding F2):
            //   * a SET is refused while the SERDES is transmitting, exactly as
            //     a frame start is gated on !ser_tx_busy -- without this the
            //     codec was stolen mid-frame;
            //   * a CLEAR is refused while the frame engine is busy.
            // A refused write reads back the ACTUAL owner, not the request.
            if (io_wdata[2]) begin
              if (!ser_tx_busy) tx_path <= 1'b1;
            end else if (!eth_tx_busy) begin
              tx_path <= 1'b0;
            end
            win_regs[26] <= {5'b0,
                             io_wdata[2] ? (ser_tx_busy ? tx_path : 1'b1)
                                         : (eth_tx_busy ? tx_path : 1'b0),
                             2'b00};
            win_index    <= 5'd27;
          end else begin
            win_regs[win_index] <= io_wdata;
            win_index           <= win_index + 5'd1;
          end
        end
      end
      if (win_re) begin
        win_index <= win_index + 5'd1;
        win_phase <= 1'b0;                         // any read re-arms INDEX
      end
    end
  end
  // ---- the timing/cadence block: cell strobe + half-cell level ----------
  // The divider sets the ENCODED-cell period; half_phase is derived from it,
  // not from a second divisor. It free-runs while eng_en is set, which keeps
  // the timing block active through a possible trailing stuff cell after
  // serdes.tx_busy falls (the plan's directed trailing-stuff requirement).
  // cell_div < 2 (including the reset value 0) holds the block quiet.
  logic [15:0] cell_cnt;
  logic        cell_en;
  logic        half_phase;
  wire  [15:0] cell_div = div_w;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cell_cnt   <= '0;
      cell_en    <= 1'b0;
      half_phase <= 1'b0;
    end else begin
      cell_en <= 1'b0;
      if (!eng_en || eng_clr_strb || cell_div < 16'd2) begin
        cell_cnt   <= '0;
        half_phase <= 1'b0;
      end else begin
        if (cell_cnt == cell_div - 16'd1) begin
          cell_cnt <= '0;
          cell_en  <= 1'b1;                  // one pulse per encoded cell
        end else begin
          cell_cnt <= cell_cnt + 16'd1;
        end
        if (!manch_mode) begin
          half_phase <= 1'b0;                // only Manchester TX toggles it
        end else if (cell_cnt == ((cell_div >> 1) - 16'd1)
                     || cell_cnt == cell_div - 16'd1) begin
          // TWO toggles per cell: at the mid-cell boundary AND at the cell
          // boundary (the cell-boundary toggle lands on the cell_en cycle,
          // so the wire's first half starts exactly where a cell starts --
          // which is what phases the DRU's grid at the load boundary).
          half_phase <= ~half_phase;         // a LEVEL: 2 toggles per cell
        end
      end
    end
  end

  // ---- grid-aligned starts ----------------------------------------------
  // The load/start strobes from a CTRL write wait for the next cell boundary,
  // so bit0 occupies a full cell and the plain RX path (which samples the
  // DRU's synchronized level a few clocks behind the pad) always sees it.

  // The frame engine's advance strobe: high on the cell's LAST clock, one
  // clock before the shared codec's registered committing edge (cell_en).
  // Pacing the engine on cell_en instead put its raw-bit transition one clock
  // INTO each first half, so the DRU could not frame the engine's Manchester
  // from a constant idle; the Task-5 wire loopback caught it. The codec's own
  // timing is untouched -- only the frame engine's advance point moves, which
  // makes each Manchester half exactly three clocks (textbook waveform).
  wire eth_cell_start = eng_en && !eng_clr_strb && (cell_div >= 16'd2)
                        && (cell_cnt == cell_div - 16'd1);
  //
  // Manchester start is anchored one step further: the DRU emits a decode
  // for the IDLE cell in flight just after the load boundary (it fires at
  // load+2 clk with pre-word content). If the serdes started at the load,
  // that decode would be captured as payload bit 0 and shift the whole word.
  // So rx_start is applied at the FIRST DRU decode after the grid-aligned
  // load: the start pulse consumes exactly that decode (serdes start beats a
  // same-cycle capture) and the first captured cell is decode(cell0).
  logic tx_load_pend, rx_start_pend, rx_anchor;
  wire  tx_load_grid  = tx_load_pend  && cell_en;
  wire  rx_start_grid = rx_start_pend
                        && (manch_mode ? (rx_anchor && eth_bit_en) : cell_en);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_load_pend  <= 1'b0;
      rx_start_pend <= 1'b0;
      rx_anchor     <= 1'b0;
    end else begin
      if (tx_load_grid)  tx_load_pend  <= 1'b0;
      if (rx_start_grid) rx_start_pend <= 1'b0;
      if (tx_load_grid)  rx_anchor     <= 1'b1;   // the load is applied
      if (rx_start_grid) rx_anchor     <= 1'b0;
      if (tx_load_strb)  tx_load_pend  <= 1'b1;   // a strb wins a same-cycle tie
      if (rx_start_strb) rx_start_pend <= 1'b1;
    end
  end

  // ---- instance wires (declared before the gates that consume them) ------
  wire        ser_rx_busy, ser_rx_valid;
  wire [31:0] ser_rx_word;
  wire        tx_stuffed_w;                  // u_tx_codec
  wire        rx_bit_w, rx_bit_valid_w, rx_err_w;   // u_rx_codec
  wire        tx_rx_bit_u, tx_rx_valid_u, tx_rx_err_u;   // TX codec's dead RX side
  wire        rx_tx_wire_u, rx_tx_stuffed_u;           // RX codec's dead TX side

  // The 10BASE-T TX engine's owner arbitration: a start waits for the SERDES
  // TX to be idle (never interleave mid-cell), and the mux swaps u_tx_codec's
  // raw input. Reset keeps tx_path=0 so this is bit-identical to the
  // pre-TX topology (the additive proof).
  assign eth_start    = tx_frame_start_strb && !ser_tx_busy;
  assign eth_tx_owner = tx_path ? eth_tx_bit : ser_tx;

  // ---- cell strobes and payload-only gates (the cadence handshake) -------
  // MUTATION ANCHORS (regress/mutate_soc_serdes_tb.sh): removing either
  // payload gate, doubling the cell enable, or cross-wiring the RX strobe to
  // the TX cadence must fail tb_pe_soc_serdes.
  wire tx_cell_en  = cell_en;
  wire rx_cell_en  = eng_en && (manch_mode ? eth_bit_en : cell_en);
  wire serdes_tx_bit_en = tx_cell_en && !tx_stuffed_w;
  wire serdes_rx_bit_en = rx_cell_en && rx_bit_valid_w;

  wire [7:0] cfg_tx = {cfg_w[7:4], half_phase, cfg_w[2:0]};
  wire [7:0] cfg_rx = {cfg_w[7:4], 1'b0,       cfg_w[2:0]};

  pe_serdes #(.MAXLEN(32), .LENW(SERDES_LENW)) u_serdes (
    .clk(clk), .rst_n(rst_n),
    .cfg_lsb_first(eng_lsb),
    .tx_bit_en(serdes_tx_bit_en),
    .tx_load(tx_load_grid), .tx_data(tx_word_w), .tx_len(tx_len_w),
    .tx_ser(ser_tx), .tx_busy(ser_tx_busy), .tx_done(ser_tx_done),
    .rx_bit_en(serdes_rx_bit_en),
    .rx_ser(rx_bit_w), .rx_start(rx_start_grid), .rx_len(rx_len_w),
    .rx_data(ser_rx_word), .rx_busy(ser_rx_busy), .rx_valid(ser_rx_valid)
  );

  pe_codec_mux u_tx_codec (
    .clk(clk), .rst_n(rst_n),
    .cfg(cfg_tx), .bit_en(tx_cell_en), .clr(eng_clr_strb),
    .tx_bit(eth_tx_owner), .tx_wire(eng_tx_wire), .tx_stuffed(tx_stuffed_w),
    .rx_wire(1'b0), .rx_first(1'b0), .rx_second(1'b0),
    .rx_bit(tx_rx_bit_u), .rx_bit_valid(tx_rx_valid_u), .rx_err(tx_rx_err_u)
  );

  // The 10BASE-T TX frame engine: pacing from the SAME divider (but on the
  // cell-BOUNDARY strobe, above) and encoding from the SAME u_tx_codec as the
  // SERDES (the owner mux above). Its own 12-bit frame_len comes from the
  // extended window's TXLEN bank; start waits for ser_tx_busy to fall
  // (eth_start above); abort is a write-triggered strobe. Enabled only when
  // the engine is on AND tx_path owns the codec.
  pe_eth_tx #(.MAX_STORED(1514)) u_eth_tx (
    .clk(clk), .rst_n(rst_n),
    .enable(eng_en && tx_path),
    .cell_start(eth_cell_start), .half_phase(half_phase),
    .push(eth_push), .push_byte(eth_push_byte), .push_ready(eth_fifo_ready),
    .frame_len({1'b0, win_regs[25][2:0], win_regs[24]}),   // 11 bits -> 12
    .start(eth_start), .frame_abort(tx_frame_abort_strb),
    .tx_busy(eth_tx_busy), .tx_done(eth_tx_done),
    .tx_underrun(eth_tx_underrun), .tx_overlong(eth_tx_overlong),
    .ifg_active(eth_ifg_active),
    .tx_bit(eth_tx_bit)
  );

  // One capture path: the EXISTING DRU (u_eth_dru) feeds this instance.
  // Manchester takes the DRU's per-decoded-cell strobe and half-cell levels;
  // plain/NRZI/stuffed take the divider's cell strobe over the DRU's
  // synchronized level (self-timed loopback scope -- no phase acquisition).
  pe_codec_mux u_rx_codec (
    .clk(clk), .rst_n(rst_n),
    .cfg(cfg_rx), .bit_en(rx_cell_en), .clr(eng_clr_strb),
    .tx_bit(1'b0), .tx_wire(rx_tx_wire_u), .tx_stuffed(rx_tx_stuffed_u),
    .rx_wire(eth_rx_wire), .rx_first(eth_rx_first), .rx_second(eth_rx_second),
    .rx_bit(rx_bit_w), .rx_bit_valid(rx_bit_valid_w), .rx_err(rx_err_w)
  );

  // ---- status: live levels + LATCHED events (set beats clear) -----------
  logic tx_done_lat, rx_valid_lat, rx_err_lat;
  logic eth_done_lat, eth_underrun_lat, eth_overlong_lat;
  wire  status_idx_rd = win_re && (win_index == 5'd6);
  wire  txstat_idx_rd = win_re && (win_index == 5'd27);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_done_lat  <= 1'b0;
      rx_valid_lat <= 1'b0;
      rx_err_lat   <= 1'b0;
    end else begin
      if (status_idx_rd) begin
        if (!ser_tx_done)  tx_done_lat  <= 1'b0;
        if (!ser_rx_valid) rx_valid_lat <= 1'b0;
        if (!rx_err_w)     rx_err_lat   <= 1'b0;
      end
      if (ser_tx_done)  tx_done_lat  <= 1'b1;   // set beats clear
      if (ser_rx_valid) rx_valid_lat <= 1'b1;
      if (rx_err_w)     rx_err_lat   <= 1'b1;
    end
  end

  // TXSTAT (index 27): the frame engine's events, latched for CPU polling
  // with the same set-beats-clear rule as STATUS (index 6). The engine emits
  // one-cycle pulses; a poll loop must not miss them.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      eth_done_lat     <= 1'b0;
      eth_underrun_lat <= 1'b0;
      eth_overlong_lat <= 1'b0;
    end else begin
      if (txstat_idx_rd) begin
        if (!eth_tx_done)     eth_done_lat     <= 1'b0;
        if (!eth_tx_underrun) eth_underrun_lat <= 1'b0;
        if (!eth_tx_overlong) eth_overlong_lat <= 1'b0;
      end
      if (eth_tx_done)     eth_done_lat     <= 1'b1;   // set beats clear
      if (eth_tx_underrun) eth_underrun_lat <= 1'b1;
      if (eth_tx_overlong) eth_overlong_lat <= 1'b1;
    end
  end

  // STATUS (index 6), TXSTAT (index 27) and RXDATA (11-14) are computed
  // views, not stored registers; everything else reads back what was written.
  always_comb begin
    case (win_index)
      5'd6:    win_rdata = {1'b0, eng_en, eth_locked, rx_err_lat,
                            rx_valid_lat, tx_done_lat, ser_rx_busy,
                            ser_tx_busy};
      5'd11:   win_rdata = ser_rx_word[7:0];
      5'd12:   win_rdata = ser_rx_word[15:8];
      5'd13:   win_rdata = ser_rx_word[23:16];
      5'd14:   win_rdata = ser_rx_word[31:24];
      5'd27:   win_rdata = {2'b00, eth_ifg_active, eth_fifo_ready,
                            eth_overlong_lat, eth_underrun_lat,
                            eth_done_lat, eth_tx_busy};
      default: win_rdata = win_regs[win_index];
    endcase
  end

  // The pad overlay: ONE selected pin carries the TX wire while the engine
  // is enabled; oe/od remain firmware's. All-zero when disabled -- which is
  // bit-identical to the matrix without an overlay (reset default).
  assign eng_ov_en = eng_en ? (eng_txsel ? 8'h01 : 8'h80) : 8'h00;

  // Unused-direction sinks: this repo accepts no lint waivers. cfg_w[3] is
  // deliberately overridden on BOTH instances (half_phase on TX, 0 on RX --
  // see the plan), so firmware's cfg[3] is not consumed anywhere.
  wire _unused_engine = &{1'b0, tx_rx_bit_u, tx_rx_valid_u, tx_rx_err_u,
                          rx_tx_wire_u, rx_tx_stuffed_u, cfg_w[3]};

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
  //
  // The 10BASE-T window is read-only here (0x8-0xD) and BUFCTRL is write-only
  // (0xE); the receive chain above declares those registers.
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
      4'h8:    io_rdata = {5'b0, eth_is_type, eth_bad, eth_valid};
      4'h9:    io_rdata = eth_len[7:0];
      4'hA:    io_rdata = eth_len[15:8];
      4'hB:    io_rdata = eth_field[7:0];
      4'hC:    io_rdata = eth_field[15:8];
      4'hD:    io_rdata = eth_buf_rdata;      // pe_fbuf's registered read output
      4'hE:    io_rdata = 8'h00;              // BUFCTRL is write-only
      4'hF:    io_rdata = win_rdata;          // the word-engine window
      default: io_rdata = 8'h00;
    endcase
  end

`ifdef FORMAL
  // ---- formal-only registers sampled by the window-write block ----------
  logic fv_ser_busy_seen, fv_eth_busy_seen, fv_set_took;

  // ---- formal-only observation aliases (see the port list) --------------
  assign fv_tx_path       = tx_path;
  assign fv_eth_tx_owner  = eth_tx_owner;
`endif

endmodule
