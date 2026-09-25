// pe_ctrl.v — the PE host-control bus: framed command/response over SPI.
// Plan: wiki/plans/host-controller-gui.md, "PE host protocol", phase R1
// (phased per reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md; R0 pad
// ruling: the plan's pad mapping WINS). Phase R2 adds the SoC read path.
//
// WHAT THIS IS
//
// On silicon, instruction memory powers up holding whatever the SRAM macro
// happens to contain, and there is no ROM — so the first program cannot load
// itself. `pe_ctrl` is the chip's side of the host bus: the host (a Pico
// bridge) drives CS_N/MOSI/SCK and reads MISO, and the chip decodes framed
// commands, loads instruction memory, reports status and faults, and drives
// IRQ_N for sticky faults. The wrapper maps the host row to uio[4:7].
//
// THE FRAME CONTRACT (R1)
//
// SPI mode 0, MSB-first, 16-bit words; CS_N low spans one complete
// transaction (request frame + response frame):
//
//   word 0        sync 16'hA55A
//   word 1        {version[3:0], opcode[7:0], target[3:0]}; version is 1
//   word 2        sequence
//   word 3        payload length in 16-bit words
//   word 4..N     payload
//   word N+1      CRC-16/CCITT-FALSE over every preceding word (sync
//                 included): poly 16'h1021, init 16'hFFFF, no reflection,
//                 no final XOR. The constants are catalogue-checked by
//                 tools/gen/crc_config.py; do not retype them.
//
// Responses set opcode bit 7 and echo sequence and target. The first response
// payload word is a status code:
//   0=OK 1=BUSY 2=BAD_FRAME 3=RANGE 4=FAULT 5=UNSUPPORTED 6=NOT_READY
//
// R1 opcodes (phase R2 adds the read ops and the CPU-derived STATUS fields):
//   0x01 PING          -> (OK)
//   0x10 LOAD          -> (status, words_written, faults, echo)
//   0x11 STATUS        -> (OK, state, run, target, faults, words_written)
//                         [R2 inserts pc/a/x/y/timer between target and
//                          faults; the R1 layout deliberately does not
//                          stub those fields, so no response lies]
//   0x16 CLEAR_FAULT   -> (OK, faults after mask)
//   0x20 TARGET        -> (OK, target, capabilities)
//
// THE R2 READ CONTRACT (landed 2026-09-25; manager ruling on the response
// latency 2026-09-25). These are the wire changes a HOST must implement:
//
//   0x12 READ_CPU   -> (OK, pc, a, x, y, insn, run)
//                      The ONLY non-halting read: it answers while run=1,
//                      which is the point of a debugger seeing a live
//                      program. Registers are at their NATIVE widths -- pc is
//                      the full PCW (10 bits in a 1,024-word machine, which
//                      is why the old 8-bit dbg_pc truncation had to go), and
//                      a/x/y are 8 bits, insn 16. A stays 8 bits: the ISA is
//                      the source of truth and no field is invented.
//   0x13 READ_IMEM  -> (OK, word, word, ...)   request (address, count) in
//                      WORDS; ascending. NOT_READY while run=1.
//   0x14 READ_DMEM  -> (OK, word, word, ...)   request (byte address, byte
//                      count) in bytes; two bytes per response word, HIGH
//                      byte first (big-endian within the word), ascending.
//   0x15 DUMP_CORE  -> the STATUS header, word for word, while STOPPED;
//                      NOT_READY while run=1.
//
// THE WAIT-WORD RULE. A bounded read cannot answer inside the request's own
// bit times: the chip must fetch first, and each fetched word or byte is one
// round trip. So during the fetch the chip DRIVES 0xFFFF filler words on MISO
// (it does not float the pad -- the level is deterministic on silicon) and
// the real frame starts at the first NON-0xFFFF word. A host therefore SKIPS
// leading 0xFFFF words and then validates the frame exactly as in R1
// (header, sequence, CRC).
//   * A filler can never be a header: every response sets opcode bit 7 and
//     version/target are bounded, so no header word is all ones.
//   * The skip is LEADING-ONLY, so a 0xFFFF inside a payload is data.
//   * WORST-CASE HOST TIMEOUT: a read returns at most 15 words (16 payload
//     slots minus the status word), one round trip each, so a host must
//     tolerate 15 filler words before the frame begins.
//   * Backward compatible: an R1 response is ready immediately and carries
//     ZERO wait words, so an unchanged host needs no change at all. The
//     response BYTES are unchanged; wait words are transport-level only.
//
// R2 STATUS is ELEVEN payload words: status, state, run, target, pc, a, x, y,
// timer, faults, words_written -- the same layout DUMP_CORE returns.
// An out-of-range READ latches sticky FAULT_RANGE (0x0004) exactly like a
// write, and CLEAR_FAULT clears it; address+count past the end is RANGE and
// is NEVER a wrapped read. A count larger than one response frame can carry
// (15 words / 30 bytes) also answers RANGE: the host splits the transfer.
//
// THE R3 DEBUG CONTRACT (landed 2026-09-25; manager dispatch "R3 debug-control
// phase"). R2 made "observe" real; R3 makes "debug" real. These are the wire
// changes a HOST must implement:
//
//   0x21 DEBUG_STEP   -> (OK, state, pc_next, bp_addr, bp_flags)
//                        ONE request payload word is NOT expected: len must be
//                        0. Executes EXACTLY ONE instruction and returns to the
//                        stopped-with-debug-hold state. Allowed when the core is
//                        stopped (run=0) or already held (a breakpoint hit);
//                        NOT_READY while the core is free-running (run=1), with
//                        NO fault. A step from the normal boot stop (PC=0)
//                        executes imem[0]; a step off a breakpoint CLEARS the
//                        hit unless the step LANDS on the breakpoint again.
//                        The response's state and bp_flags are for the state
//                        AFTER the step; pc_next is the address the next step
//                        will execute from.
//   0x22 DEBUG_BP_SET -> (OK, state, pc, bp_addr, bp_flags)
//                        ONE request payload word: the breakpoint address. The
//                        address must be < IMEM_WORDS, else the answer is RANGE
//                        and the breakpoint is NOT armed and NOT changed (a
//                        rejected op has no side effect). Arming clears a stale
//                        hit. Allowed while running: the armed breakpoint then
//                        stops a LIVE core the cycle its PC matches.
//   0x23 DEBUG_BP_CLR -> (OK, state, pc, bp_addr_before, bp_flags)
//                        len must be 0. Disarms the breakpoint, clears the hit,
//                        and RELEASES the debug hold: with run=1 the core
//                        resumes; with run=0 it returns to the normal boot stop
//                        (PC=0). This is also how a host resumes a core that a
//                        breakpoint stopped. Idempotent (safe when disarmed).
//   0x24 DEBUG_STATUS -> (OK, state, pc, bp_addr, bp_flags, run, a, x, y, insn)
//                        len must be 0. The full debug readback: the common
//                        5-word prefix plus the architectural state, same field
//                        meanings and widths as READ_CPU (run is the STRAP
//                        level). Answered while running and while held.
//
// state (2 bits, low half of the word; the upper bits are ZERO):
//   0 STOPPED       the normal boot stop: run=0, no debug hold, PC held at 0
//   1 RUNNING       the strap is high and no debug hold is asserted
//   2 DEBUG_HOLD    held by the debug controls with the PC PRESERVED (single-
//                   stepping); the core is not executing
//   3 BP_HIT        held by the breakpoint: the PC preserved, the hit latched
// R2's STATUS `state` word carries THE SAME encoding: its old values 0/1 keep
// their meaning, and 2/3 are new states that only debug control can enter. No
// R2 field changes shape.
//
// bp_flags (low bits; the rest ZERO): bit0 = breakpoint ARMED, bit1 = HIT
// latched. bp_addr is the armed address, or 0 when disarmed; a breakpoint at
// address 0 is legal and is distinguished from "disarmed" by bit0.
//
// WAIT WORDS: these four ops are READY-IMMEDIATE -- they are answered from
// registers in the request's own CRC cycle, exactly like READ_CPU, so they emit
// ZERO 0xFFFF filler words. The wait-word rule stays what it is for the bounded
// reads (0x13/0x14) only.
//
// TARGETS: the debug ops are TARGET_HOST only; the loopback target answers
// UNSUPPORTED like any other op it does not implement.
//
// FAULTS: no new fault class. A malformed frame (bad CRC, bad length, bad
// header) answers BAD_FRAME and has NO side effect -- no step, no arming. A
// sequencing refusal answers NOT_READY with no fault, exactly like LOAD while
// running and the bounded reads while running.
//
// WHERE THE LOGIC LIVES (no new pads): pe_ctrl owns the opcode decode, the
// breakpoint register and flags, the hit comparison against the core's PC (it
// already receives dbg_pc), and the debug-hold/step outputs. pe_cpu takes two
// new INPUTS and exposes one new OUTPUT:
//   dbg_hold  MASKS the run strap: while high the core does not execute and
//             PRESERVES its PC (unlike the boot stop, which holds it at 0).
//             The execute gate becomes
//               cpu_exec = dbg_step || (run && !dbg_hold)
//             and the PC updates only on `cpu_exec`, is preserved while
//             dbg_hold, and is zeroed only on the boot stop (run=0, no hold).
//   dbg_step  a one-cycle pulse from pe_ctrl: executes EXACTLY one instruction
//             and advances the PC to next_pc.
//   dbg_next_pc  the combinational next PC (the landing address of the step
//             about to execute). pe_ctrl samples it in the dispatch cycle, so
//             the DEBUG_STEP response reports the landing PC even though the
//             instruction commits at the following edge -- the PC and the
//             fetched instruction are frozen in between, by construction.
// pe_soc routes the three wires. tt_um's pin map is unchanged: the run strap
// remains a pad, and the debug controls are host-bus only.
// READ_CPU is never rejected for size.
// Unknown opcodes, a request with the response bit set, and unknown targets
// answer UNSUPPORTED with no fault. A frame that fails its CRC or header
// answers BAD_FRAME and latches FAULT_CRC / FAULT_PROTOCOL. A word truncated
// by CS_N rising latches FAULT_PROTOCOL (no response is possible).
//
// Target 1 is a deterministic internal loopback target on the same MISO:
// PING -> (OK, 16'h10C0), TARGET -> (OK, 1, 0x0010); everything else on
// target 1 is UNSUPPORTED. It consumes no pad, clock or external MISO.
//
// THE LOAD PATH AND THE A1 SEMANTICS, TRANSFERRED
//
// LOAD payload words stream into the SoC's host write port through the same
// one-cycle `host_we` pulse as v1. The superseded A1 `uio[4]` echo lives in
// the LOAD response instead:
//   * `words_written` and `echo` reset when a LOAD header is accepted, count
//     and echo exactly the words that COMMIT (one host_we pulse each);
//   * the full-image case ends with the final committed word as the response
//     echo -- there is no trailing frame and no undefined-tail write;
//   * a word aborted by `run` never commits, never counts and never echoes,
//     and no later `run` transition resurrects it;
//   * LOAD while `run=1` answers NOT_READY with NO fault and writes nothing
//     (R0 decision; a sequencing rejection, not a fault).
// `faults` is sticky: FAULT_LOAD (0x0001) from a run abort, FAULT_CRC
// (0x0002), FAULT_RANGE (0x0004), FAULT_PROTOCOL (0x0008). CLEAR_FAULT applies
// its mask; a STATUS read reports faults without clearing them. `irq_n` is
// active low and asserted while any fault bit is set, so it releases exactly
// when the command contract clears them.
//
// MISO OWNERSHIP
//
// `miso_oe` (uio[6]) is asserted only while a response frame is shifting, and
// stays asserted through the sampling edge of the last bit; it releases one
// falling edge later, or immediately when CS_N rises. Mode 0 is preserved:
// the pad changes only on the DETECTED falling edge.
//
// THE TRAPS THIS BLOCK STILL GUARDS
//
//   1. SCLK IS ASYNCHRONOUS. Two-flop synchronizer plus an edge detector; do
//      not feed `spi_sclk` anywhere else. The 10 MHz write ceiling (six clk
//      per full period at 60 MHz) is unchanged; the host's first-pass guard
//      is 5 MHz because responses have their own mode-0 margin.
//   2. NOTHING WRITES WHILE THE CORE RUNS. `host_we` is masked by `run`, the
//      write engine checks `run` in every state, and an abort is permanent
//      for that frame. The framed receive path keeps running while `run=1`
//      (STATUS/PING must answer), but the commit path does not.
//
// No `timescale` here (repo convention: RTL is timescale-free).

module pe_ctrl #(
  parameter int WORDS = 1024,
  // R2: the data buffer's size, so the bounded READ_DMEM can bound-check
  // address+count against the REAL memory (16 bytes at the top level). It
  // must match pe_soc's DMEM_BYTES; the wrapper passes the same value.
  parameter int DMEM_BYTES = 16
) (
  input  logic clk,
  input  logic rst_n,

  // The host pads. Asynchronous host signals: synchronized here.
  input  logic spi_sclk,
  input  logic spi_mosi,
  input  logic spi_cs_n,      // active low

  output logic spi_miso,      // response data (uio[6])
  output logic miso_oe,       // 1 = drive the MISO pad
  output logic irq_n,         // active low: any sticky fault

  // The core's run strap. Loads commit only while this is 0.
  input  logic run,

  // The SoC's host write port, driven by the loader.
  output logic        host_we,
  output logic        host_imem_sel,
  output logic [((((WORDS <= 2) ? 1 : $clog2(WORDS)) > 8)
                 ? ((WORDS <= 2) ? 1 : $clog2(WORDS)) : 8)-1:0] host_addr,
  output logic [15:0] host_wdata,

  // Observability
  output logic        load_active,     // level: selected and run is low
  output logic        load_error,      // faults[FAULT_LOAD], sticky
  output logic [15:0] words_written,
  output logic [15:0] faults,

  // ---- R2: the bounded host READ path -----------------------------------
  // The debug-only reads the host issues while the CPU is stopped. pe_ctrl
  // owns the bounds and the status (RANGE / NOT_READY / sticky FAULT_RANGE);
  // pe_soc owns the address arbitration and returns one word (imem) or one
  // byte (dmem) per request, one cycle later.
  output logic        dbg_rd_req,
  output logic        dbg_rd_dmem,     // 0 = imem word, 1 = dmem byte
  output logic [15:0] dbg_rd_addr,
  input  logic [15:0] dbg_rd_data,
  input  logic        dbg_rd_valid,
  // R2 STATUS/DUMP_CORE: the full-width architectural registers, so the
  // response can report the real PC (no 8-bit truncation) and the whole state
  // while the CPU runs.
  input  logic [9:0]  dbg_pc,
  input  logic [7:0]  dbg_a,
  input  logic [7:0]  dbg_x,
  input  logic [7:0]  dbg_y,
  input  logic [15:0] dbg_insn,
  input  logic [7:0]  dbg_timer
  // ---- R3 DEBUG CONTROL (manager dispatch 2026-09-25; contract frozen in
  // reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md, whose header block lands
  // in this file's header) -------------------------------------------------
  // The host bus can hold the core, advance it exactly one instruction at a
  // time, and stop it on a PC breakpoint. These three wires are the whole
  // interface to the core: no pad is added, and the run strap stays a pin.
  ,input  logic [9:0]  dbg_next_pc   // the CPU's landing address for a step
  ,output logic        dbg_hold      // 1: hold the core, preserving its PC
  ,output logic        dbg_step      // 1-cycle pulse: execute one instruction
`ifdef FORMAL
  // ---- FORMAL-ONLY OBSERVATION PORTS (manager ruling 2026-09-25) --------
  // Guarded instrumentation for formal/pe_ctrl/formal_pe_ctrl.v. These are
  // ALIASES of existing signals plus two 1-cycle event registers, never new
  // datapath: the wrapper needs PORTS because yosys does not resolve
  // hierarchical references into connections (the implicit-wire trap this
  // file's header documents), and modelling the SPI transaction instead
  // requires a clock/delay engine the yosys frontend rejects.
  //
  // FORMAL IS NEVER DEFINED IN SYNTHESIS. tools/check_formal_ifdef.sh fails
  // any synthesis path that defines it, and the area/STA baselines are
  // re-measured with these lines compiled out.
  //
  // Each tap, and the claim it exists for (target 2 in the review):
  //   fv_resp_len/fv_resp_idx/fv_resp_active  P2a no response-index wrap
  //   fv_r_addr/fv_r_left/fv_r_dmem/fv_rstate P2a no walk past the bound
  //   fv_r_slot                               P2a no resp_buf slot overrun
  //   fv_faults/fv_clr_mask                   P2b RANGE sticky
  //   fv_resp_bitpos                          P2c word-aligned serializer
  //   fv_r_imm                                P2a walk-vs-immediate-rejection:
  //                both sit in R_START, and only the immediate one holds stale
  //                r_addr/r_left values
  // R3 taps: fv_dbg_state is the 2-bit state encoding the STATUS/DEBUG
  // responses report; fv_bp_en/fv_bp_hit/fv_bp_addr are the breakpoint
  // register, so the hit claims can be stated over ports.
  ,output logic [1:0]  fv_dbg_state
  ,output logic        fv_bp_en
  ,output logic        fv_bp_hit
  ,output logic [9:0]  fv_bp_addr
  ,output logic        fv_dbg_hold
  ,output logic [15:0] fv_resp_len
  ,output logic [4:0]  fv_resp_idx
  ,output logic        fv_resp_active
  ,output logic [15:0] fv_r_addr
  ,output logic [15:0] fv_r_left
  ,output logic [15:0] fv_r_slot
  ,output logic        fv_r_dmem
  ,output logic [2:0]  fv_rstate
  ,output logic [15:0] fv_faults
  ,output logic [15:0] fv_clr_mask
  ,output logic [3:0]  fv_resp_bitpos
  ,output logic        fv_r_imm
`endif
);

  localparam int IAW = (WORDS <= 2) ? 1 : $clog2(WORDS);
  localparam int AW  = (IAW > 8) ? IAW : 8;   // matches pe_soc's host_addr

  // ---- frame constants ---------------------------------------------------
  localparam logic [15:0] SYNC      = 16'hA55A;
  localparam logic [3:0]  VERSION   = 4'h1;
  localparam logic [7:0]  OP_PING   = 8'h01;
  localparam logic [7:0]  OP_LOAD   = 8'h10;
  localparam logic [7:0]  OP_STATUS = 8'h11;
  localparam logic [7:0]  OP_RDCPU  = 8'h12;   // R2: the non-halting read
  localparam logic [7:0]  OP_RDIMEM = 8'h13;   // R2: bounded instruction read
  localparam logic [7:0]  OP_RDMEM  = 8'h14;   // R2: bounded data read
  localparam logic [7:0]  OP_DUMPCOR= 8'h15;   // R2: core header dump
  localparam logic [7:0]  OP_CLRFLT = 8'h16;
  localparam logic [7:0]  OP_TARGET = 8'h20;
  // R3 debug control (contract: reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md)
  localparam logic [7:0]  OP_DBGSTEP  = 8'h21;   // one instruction, then hold
  localparam logic [7:0]  OP_DBGBPSET = 8'h22;   // arm the PC breakpoint
  localparam logic [7:0]  OP_DBGBPCLR = 8'h23;   // disarm, clear hit, release
  localparam logic [7:0]  OP_DBGSTAT  = 8'h24;   // the debug readback
  localparam logic [7:0]  RESP_BIT  = 8'h80;

  localparam logic [15:0] ST_OK       = 16'd0;
  localparam logic [15:0] ST_BADFRAME = 16'd2;
  localparam logic [15:0] ST_RANGE    = 16'd3;
  localparam logic [15:0] ST_FAULT    = 16'd4;
  localparam logic [15:0] ST_UNSUP    = 16'd5;
  localparam logic [15:0] ST_NOTREADY = 16'd6;

  localparam logic [15:0] FAULT_LOAD     = 16'h0001;
  localparam logic [15:0] FAULT_CRC      = 16'h0002;
  localparam logic [15:0] FAULT_RANGE    = 16'h0004;
  localparam logic [15:0] FAULT_PROTOCOL = 16'h0008;

  localparam logic [15:0] CAP_HOST     = 16'h000F;
  localparam logic [15:0] CAP_LOOPBACK = 16'h0010;
  localparam logic [15:0] LOOPBACK_ID  = 16'h10C0;

  localparam logic [3:0] TARGET_HOST = 4'd0;
  localparam logic [3:0] TARGET_LOOP = 4'd1;

  // ---- R2 read engine ----------------------------------------------------
  // The bounded reads are the one thing that CANNOT be answered in the S_CRC
  // cycle: the answer is the memory contents, and the memory answers one
  // cycle after it is asked. So a read op parks here, walks the requested
  // range one word (imem) or one byte (dmem) at a time, and only then starts
  // the response serializer. Nothing else in the protocol blocks this way --
  // every other response is built from registers available in S_CRC.
  //
  //   15 payload words is the ceiling (16 slots minus the status word). A
  //   read that asks for more cannot be returned in ONE response frame, and
  //   the protocol has no "too large" status, so it answers RANGE and latches
  //   FAULT_RANGE: the host splits the transfer. This is a protocol LIMIT, not
  //   a memory bound, and it is documented as one.
  localparam int MAX_READ_WORDS = 15;
  localparam logic [2:0] R_IDLE = 3'd0, R_START = 3'd1, R_REQ = 3'd2,
                           R_WAIT = 3'd3;
  logic [2:0]  rstate;
  logic        r_dmem;           // 1 = dmem byte walk, 0 = imem word walk
  logic        r_imm;            // 1 = answer now (NOT_READY / RANGE)
  logic [15:0] r_addr;           // next address to request
  logic [15:0] r_left;           // items still to fetch
  logic [15:0] r_slot;           // next resp_buf slot to write
  logic [7:0]  r_half;           // first byte of a dmem pair (big-endian)
  logic        r_first;          // 1 = the next dmem byte opens a pair

`ifdef FORMAL
  // Observation register for the formal target (see the port list): what a
  // CLEAR_FAULT applied. It OBSERVES an existing branch -- it does not
  // re-decide anything, so no proof leans on a copy of the logic under test.
  logic [15:0] fv_clr_mask_r;
`endif

  // The bounded reads are the ONLY opcodes whose response cannot be built in
  // the S_CRC cycle, so the read engine below -- not the generic trailer --
  // starts the serializer for them. This one wire keeps that decision in ONE
  // place for every read outcome (OK, NOT_READY, RANGE); duplicating the
  // conditions in the trailer is how a rejected read would end up emitting an
  // empty response. (`r_is_read` is declared beside the frame signals, below,
  // because it reads frm_op.)

  // ---- R2 read datapath: driven by the read engine ----------------------
  // The bounded reads are the only client of the memory read port: READ_CPU
  // and DUMP_CORE read registers directly, so they never touch it. Idle = no
  // request.
  assign dbg_rd_req  = (rstate == R_REQ);
  assign dbg_rd_dmem = r_dmem;
  assign dbg_rd_addr = r_addr;
  wire _unused_r2 = &{1'b0, dbg_rd_valid,
                       dbg_pc, dbg_a, dbg_x, dbg_y, dbg_insn, dbg_timer};

  // CRC-16/CCITT-FALSE over a byte, forward (MSB-first) datapath. The
  // polynomial and seed come from tools/gen/crc_config.py's checked
  // catalogue entry (CRC-16/CCITT-FALSE, check 0x29B1); tb_pe_ctrl and the
  // generator both assert that, so these are never hand-typed constants.
  //
  // Old-style function declarations ON PURPOSE: yosys 0.69+post's
  // `read_verilog -sv` frontend rejects a `return` statement inside a
  // function (it was the one construct in this file the lint gate could not
  // parse), and the function-name assignment is the portable form. The
  // datapath is bit-identical -- same mask, same loop, same result.
  function automatic [15:0] crc16_byte;
    input [15:0] crc;
    input [7:0]  b;
    reg [15:0] c;
    integer i;
    begin
      c = crc ^ {b, 8'h00};
      for (i = 0; i < 8; i = i + 1)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      crc16_byte = c;
    end
  endfunction

  function automatic [15:0] crc16_word;
    input [15:0] crc;
    input [15:0] w;
    begin
      crc16_word = crc16_byte(crc16_byte(crc, w[15:8]), w[7:0]);
    end
  endfunction

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
  wire sclk_fall = ~sclk_s1 &  sclk_s1d;   // mode-0 change edge
  wire cs_fall   = ~cs_s1 &  cs_s1d;
  wire cs_rise   =  cs_s1 & ~cs_s1d;

  // ---- receive ----------------------------------------------------------
  // `shreg` holds the LAST 15 bits of the word being assembled; the 16th bit
  // is `mosi_s1` at the completing strobe (the same 15-bit construction as
  // pe_eth_mac's `sr`; a 16th register bit would be shifted in and never
  // read). The frame FSM consumes each completed word in the same cycle.
  logic [14:0] shreg;
  logic [3:0]  bit_cnt;
  logic        word_ready;      // a LOAD payload word is queued for commit
  wire  [15:0] rx_word = {shreg[14:0], mosi_s1};

  localparam logic [2:0] S_SYNC = 3'd0, S_HEADER = 3'd1, S_SEQ = 3'd2,
                         S_LEN = 3'd3, S_PAYLOAD = 3'd4, S_CRC = 3'd5;
  logic [2:0]  rx_state;
  logic [3:0]  frm_tgt;
  logic [7:0]  frm_op;
  logic [15:0] frm_seq, rx_ntogo;
  // The bounded reads are the only opcodes whose response is built outside
  // the S_CRC cycle, so the read engine (not the generic trailer) starts the
  // serializer for them -- for EVERY read outcome. One wire, one decision.
  wire  r_is_read = (frm_op == OP_RDIMEM) || (frm_op == OP_RDMEM);

  // ---- R2 wait-word contract (manager ruling 2026-09-25) ----------------
  // A bounded read cannot answer inside the request's own bit times: the chip
  // must fetch first, and the fetch costs one round trip per item. Rather than
  // floating MISO (undefined on a real pad) or leaving the host to guess, the
  // chip DRIVES 0xFFFF filler words for the whole fetch and the real frame
  // starts at the first non-0xFFFF word. A filler can never be mistaken for
  // the response: the response header sets opcode bit 7 and its version and
  // target are bounded, so no header word is all ones; and the skip applies to
  // LEADING words only, so a 0xFFFF inside a payload is data.
  // R1 responses are unaffected -- they are ready immediately, so they carry
  // ZERO wait words. This is a transport-level addition: the response bytes
  // themselves are unchanged.
  //
  // WORST-CASE HOST TIMEOUT: a read returns at most 15 words, one round trip
  // each, so a host must tolerate 15 filler words before the frame begins.
  logic [3:0]  fill_pos;          // bit position inside the filler word
  logic        r_launch;          // fetch done; start at the next word edge
  wire         r_filling = (rstate != R_IDLE) && !r_imm && !r_launch;
  logic [15:0] crc_acc;
  logic        frm_hdr_bad, frm_len_bad;
  logic        frm_not_ready, frm_aborted, frm_range;
  logic [15:0] pay0;
  logic        pay0_valid;
  logic [15:0] pay1;             // R2: the read ops carry (address, count)
  logic        pay1_valid;
  logic [15:0] load_idx;        // payload words offered to this LOAD

  // ---- R3 debug control: the breakpoint and the hold/step outputs ---------
  // The registers are host-bus only; the DECODE that writes them and the HIT
  // logic live with the response dispatch. `dbg_hold` masks the run strap in
  // pe_cpu (the core stops and PRESERVES its PC); `dbg_step` is a one-cycle
  // pulse that executes exactly one instruction. No pad, no ISA change.
  logic [9:0]  bp_addr;       // the armed breakpoint address
  logic        bp_en;         // armed
  logic        bp_hit;        // hit latched: the core is stopped ON the bp
  logic        dbg_hold_r;    // the debug-hold level
  logic        dbg_step_r;    // the one-cycle step pulse
  assign dbg_hold = dbg_hold_r;
  assign dbg_step = dbg_step_r;

  // The state/flag encoding the STATUS and DEBUG responses report. 0/1 keep
  // their R1/R2 meaning (stopped/running); 2/3 are the debug states, which
  // only a debug hold can enter.
  wire [1:0] dbg_state = dbg_hold_r ? (bp_hit ? 2'd3 : 2'd2)
                                    : (run ? 2'd1 : 2'd0);
  wire [1:0] bp_flags  = {bp_hit, bp_en};   // bit0 = armed, bit1 = hit

  // ---- response ---------------------------------------------------------
  logic        resp_active, resp_hold_oe;
  logic [4:0]  resp_idx;
  logic [3:0]  resp_bitpos;
  logic [7:0]  resp_op;
  logic [3:0]  resp_tgt;
  logic [15:0] resp_seq, resp_len, resp_crc;
  // R2: 16 payload slots. The R1 buffer was 8 entries, sized for the longest
  // R1 response (STATUS's 6 payload words -> frame indices 4..9). R2's
  // STATUS/DUMP_CORE header is ELEVEN payload words, and a bounded read is
  // variable length, so the buffer and the index map below grew together. The
  // frame carries 4 header words, so 16 payload words reach index 19, which
  // resp_idx's 5 bits address (0..31).
  logic [15:0] resp_buf [0:15];
  logic [15:0] resp_shreg;
  logic [15:0] resp_w;          // combinational view of resp_word(resp_idx)

  // ---- echo / counters / target -----------------------------------------
  logic [15:0] load_echo;
  logic [15:0] selected_target;

  // ---- write engine -----------------------------------------------------
  logic [AW-1:0] addr;
  logic          we_r;
  logic [1:0]    wstate;
  localparam logic [1:0] W_IDLE = 2'd0, W_PULSE = 2'd1, W_DONE = 2'd2;


  assign host_we       = we_r & ~run;
  assign host_imem_sel = 1'b1;        // R1: instruction memory only
  assign host_addr     = addr;
  assign host_wdata    = pay0;        // the queued payload word

  assign load_active = ~cs_s1 && !run;
  assign irq_n       = ~(|faults);
  assign load_error  = faults[0];
  assign miso_oe     = resp_active | resp_hold_oe | r_filling;

  // The response word presented at index `idx` of the current frame:
  // 0 sync, 1 header, 2 sequence, 3 length, 4.. payload, last CRC.
  always_comb begin
    case (resp_idx)
      5'd0:    resp_w = SYNC;
      5'd1:    resp_w = {VERSION, resp_op, resp_tgt};
      5'd2:    resp_w = resp_seq;
      5'd3:    resp_w = resp_len;
      default: begin
        if ({11'b0, resp_idx} >= resp_len + 16'd4) begin
          resp_w = resp_crc;
        end else begin
          // A fixed index per payload slot, not the 5-bit dynamic
          // `resp_idx - 4` expression Verilator flagged (WIDTHTRUNC: an array
          // indexed by 5 bits). The map is exhaustive for every implemented
          // response: 16 payload slots at frame indices 4..19. Bit-identical
          // to the dynamic index on that range.
          case (resp_idx)
            5'd4:    resp_w = resp_buf[0];
            5'd5:    resp_w = resp_buf[1];
            5'd6:    resp_w = resp_buf[2];
            5'd7:    resp_w = resp_buf[3];
            5'd8:    resp_w = resp_buf[4];
            5'd9:    resp_w = resp_buf[5];
            5'd10:   resp_w = resp_buf[6];
            5'd11:   resp_w = resp_buf[7];
            5'd12:   resp_w = resp_buf[8];
            5'd13:   resp_w = resp_buf[9];
            5'd14:   resp_w = resp_buf[10];
            5'd15:   resp_w = resp_buf[11];
            5'd16:   resp_w = resp_buf[12];
            5'd17:   resp_w = resp_buf[13];
            5'd18:   resp_w = resp_buf[14];
            5'd19:   resp_w = resp_buf[15];
            default: resp_w = resp_crc;
          endcase
        end
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shreg         <= '0;
      bit_cnt       <= '0;
      word_ready    <= 1'b0;
      rx_state      <= S_SYNC;
      frm_tgt       <= '0; frm_op <= '0;
      frm_seq       <= '0; rx_ntogo <= '0;
      crc_acc       <= '0;
      frm_hdr_bad   <= 1'b0; frm_len_bad <= 1'b0;
      frm_not_ready <= 1'b0; frm_aborted <= 1'b0; frm_range <= 1'b0;
      pay0          <= '0; pay0_valid <= 1'b0; load_idx <= '0;
      rstate        <= R_IDLE; r_imm <= 1'b0; r_dmem <= 1'b0; r_first <= 1'b1;
      resp_active   <= 1'b0; resp_hold_oe <= 1'b0; resp_idx <= '0;
      // R2 wait-word machinery must start from DEFINED values: r_filling feeds
      // miso_oe, so an X here would put an X on the host pad before the first
      // frame (the pad-level TB checks uio_oe for X at time 0).
      fill_pos      <= 4'd0;
      r_launch      <= 1'b0;
      resp_bitpos   <= '0; resp_op <= '0; resp_tgt <= '0;
      resp_seq      <= '0; resp_len <= '0; resp_crc <= 16'hFFFF;
      resp_shreg    <= '0;
      addr          <= '0;
      we_r          <= 1'b0;
      wstate        <= W_IDLE;
      words_written <= '0;
      load_echo     <= '0;
      faults        <= '0;
      selected_target <= '0;
      spi_miso      <= 1'b0;
      bp_addr <= 10'd0; bp_en <= 1'b0; bp_hit <= 1'b0;
      dbg_hold_r <= 1'b0; dbg_step_r <= 1'b0;
      for (int i = 0; i < 16; i++) resp_buf[i] <= '0;
    end else begin
`ifdef FORMAL
      fv_clr_mask_r <= 16'h0000;   // formal-only: default = no CLEAR_FAULT
`endif
      // R3: the step pulse is one cycle wide unless the debug decode sets it.
      // A transaction does NOT clear the breakpoint or the hold: CS_N is a
      // frame boundary, not a debug-state boundary.
      dbg_step_r <= 1'b0;
      // R3 breakpoint: stop BEFORE the instruction at the armed address runs.
      // The comparison is on the LANDING address, so the core halts at the
      // breakpoint with that instruction UNEXECUTED; the decode below can
      // override the hit in the same cycle (a step's landing rule).
      //
      // BOTH HALVES, because stating only one of them is how a reader ends up
      // with the wrong model. Stop-before protects the instruction AT the
      // breakpoint: it has NOT run, and no io_we / dmem_we / a/x/y effect of it
      // occurred. It does NOT mean the step is a no-op: the step DOES retire the
      // instruction it executed on the way there, exactly as a step always does.
      // Stepping from 1 to 2 with the breakpoint armed at 2 therefore executes
      // the LDI at 1 (so `a` becomes its value) and leaves the instruction at 2
      // untouched -- the one the debugger is about to inspect. The host vectors
      // are reconciled to this: a step onto an armed address retires the
      // instruction stepped FROM and protects the one AT the breakpoint.
      if (bp_en && !dbg_hold_r && (run || dbg_step_r) &&
          (dbg_next_pc == bp_addr)) begin
        bp_hit     <= 1'b1;
        dbg_hold_r <= 1'b1;
      end
      // CS falling edge: a new transaction. Frame state resets; the sticky
      // faults, words_written, echo and selected target persist.
      if (cs_fall) begin
        rx_state      <= S_SYNC;
        bit_cnt       <= '0;
        shreg         <= '0;
        word_ready    <= 1'b0;
        we_r          <= 1'b0;
        wstate        <= W_IDLE;
        addr          <= '0;
        frm_hdr_bad   <= 1'b0; frm_len_bad <= 1'b0;
        frm_not_ready <= 1'b0; frm_aborted <= 1'b0; frm_range <= 1'b0;
        pay0_valid    <= 1'b0; load_idx <= '0;
        resp_active   <= 1'b0; resp_hold_oe <= 1'b0;
        spi_miso      <= 1'b0;
      end

      // CS rising edge: the transaction is over. A word truncated mid-shift
      // is a protocol fault; the response is released.
      if (cs_rise) begin
        if (bit_cnt != 4'd0) faults <= faults | FAULT_PROTOCOL;
        bit_cnt      <= '0;
        word_ready   <= 1'b0;
        we_r         <= 1'b0;
        wstate       <= W_IDLE;
        resp_active  <= 1'b0;
        resp_hold_oe <= 1'b0;
      end

      // ---- receive one bit per rising SCLK edge (never gated by run) -----
      if (sclk_rise && !cs_s1 && !word_ready) begin
        if (bit_cnt == 4'd15) begin
          bit_cnt <= '0;
          // The completed word, MSB first.
          case (rx_state)
            S_SYNC: begin
              if (rx_word == SYNC) begin
                rx_state      <= S_HEADER;
                crc_acc       <= crc16_word(16'hFFFF, SYNC);
                frm_not_ready <= 1'b0;
                frm_aborted   <= 1'b0;
                frm_range     <= 1'b0;
                frm_hdr_bad   <= 1'b0;
                frm_len_bad   <= 1'b0;
                pay0_valid    <= 1'b0;
                pay1_valid    <= 1'b0;
                load_idx      <= '0;
              end
            end
            S_HEADER: begin
              frm_op  <= rx_word[11:4];
              frm_tgt <= rx_word[3:0];
              crc_acc <= crc16_word(crc_acc, rx_word);
              if (rx_word[15:12] != VERSION)
                frm_hdr_bad <= 1'b1;
              // A LOAD on the host target is a fresh session: counters and
              // echo restart, unless the run gate already rejects it.
              if (rx_word[11:4] == OP_LOAD && rx_word[3:0] == TARGET_HOST) begin
                if (run) begin
                  frm_not_ready <= 1'b1;
                end else begin
                  words_written <= '0;
                  load_echo     <= '0;
                  load_idx      <= '0;
                  addr          <= '0;
                end
              end
              rx_state <= S_SEQ;
            end
            S_SEQ: begin
              frm_seq <= rx_word;
              crc_acc <= crc16_word(crc_acc, rx_word);
              rx_state <= S_LEN;
            end
            S_LEN: begin
              rx_ntogo <= rx_word;
              crc_acc  <= crc16_word(crc_acc, rx_word);
              case (frm_op)
                OP_PING, OP_STATUS:
                  if (rx_word != 16'd0) frm_len_bad <= 1'b1;
                // R2: these take no payload. READ_CPU and DUMP_CORE are the
                // register reads; the two bounded reads DO take a payload
                // ((address, count) for READ_IMEM, (byte address, byte count)
                // for READ_DMEM) and are checked when that word pair is read.
                OP_RDCPU, OP_DUMPCOR:
                  if (rx_word != 16'd0) frm_len_bad <= 1'b1;
                // The bounded reads carry exactly (address, count).
                OP_RDIMEM, OP_RDMEM:
                  if (rx_word != 16'd2) frm_len_bad <= 1'b1;
                OP_CLRFLT, OP_TARGET:
                  if (rx_word != 16'd1) frm_len_bad <= 1'b1;
                // R3: DEBUG_STEP / BP_CLR / DEBUG_STATUS take no payload;
                // DEBUG_BP_SET carries exactly the address word.
                OP_DBGSTEP, OP_DBGBPCLR, OP_DBGSTAT:
                  if (rx_word != 16'd0) frm_len_bad <= 1'b1;
                OP_DBGBPSET:
                  if (rx_word != 16'd1) frm_len_bad <= 1'b1;
                default: ;   // LOAD bound by range; unknown ops consume
              endcase
              if (rx_word == 16'd0) rx_state <= S_CRC;
              else                  rx_state <= S_PAYLOAD;
            end
            S_PAYLOAD: begin
              crc_acc  <= crc16_word(crc_acc, rx_word);
              rx_ntogo <= rx_ntogo - 16'd1;
              if (rx_ntogo == 16'd1) rx_state <= S_CRC;

              if (frm_op == OP_LOAD) begin
                if (frm_tgt == TARGET_HOST && !frm_not_ready && !frm_aborted &&
                    !frm_range && !frm_hdr_bad && !frm_len_bad) begin
                  if (load_idx >= 16'(WORDS)) begin
                    frm_range <= 1'b1;
                    faults    <= faults | FAULT_RANGE;
                  end else if (run) begin
                    frm_aborted <= 1'b1;
                    faults      <= faults | FAULT_LOAD;
                  end else begin
                    pay0       <= rx_word;
                    word_ready <= 1'b1;
                    load_idx   <= load_idx + 16'd1;
                  end
                end
              end else if (frm_op == OP_CLRFLT || frm_op == OP_TARGET ||
                           frm_op == OP_DBGBPSET) begin
                if (!pay0_valid) begin
                  pay0       <= rx_word;
                  pay0_valid <= 1'b1;
                end
              end else if (frm_op == OP_RDIMEM || frm_op == OP_RDMEM) begin
                // (address, count): the bounded read's request pair.
                if (!pay0_valid) begin
                  pay0       <= rx_word;
                  pay0_valid <= 1'b1;
                end else if (!pay1_valid) begin
                  pay1       <= rx_word;
                  pay1_valid <= 1'b1;
                end
              end
            end
            S_CRC: begin
              // ---- faults for this frame ---------------------------------
              if (crc_acc != rx_word)
                faults <= faults | FAULT_CRC;
              else if (frm_hdr_bad || frm_len_bad)
                faults <= faults | FAULT_PROTOCOL;

              // ---- response dispatch (defaults overridden by the cases) ---
              resp_op     <= frm_op | RESP_BIT;
              resp_seq    <= frm_seq;
              resp_tgt    <= frm_tgt;
              resp_len    <= 16'd1;
              resp_buf[0] <= ST_UNSUP;
              resp_buf[1] <= 16'h0000;
              resp_buf[2] <= 16'h0000;
              resp_buf[3] <= 16'h0000;
              resp_buf[4] <= 16'h0000;
              resp_buf[5] <= 16'h0000;

              if (crc_acc != rx_word || frm_hdr_bad || frm_len_bad) begin
                resp_len    <= 16'd1;
                resp_buf[0] <= ST_BADFRAME;
              end else if (frm_op[7]) begin
                resp_len    <= 16'd1;
                resp_buf[0] <= ST_UNSUP;
              end else if (frm_tgt == TARGET_LOOP) begin
                if (frm_op == OP_PING) begin
                  resp_len    <= 16'd2;
                  resp_buf[0] <= ST_OK;
                  resp_buf[1] <= LOOPBACK_ID;
                end else if (frm_op == OP_TARGET) begin
                  resp_len    <= 16'd3;
                  resp_buf[0] <= ST_OK;
                  resp_buf[1] <= 16'd1;
                  resp_buf[2] <= CAP_LOOPBACK;
                  selected_target <= 16'd1;
                end else begin
                  resp_len    <= 16'd1;
                  resp_buf[0] <= ST_UNSUP;
                end
              end else if (frm_tgt != TARGET_HOST) begin
                resp_len    <= 16'd1;
                resp_buf[0] <= ST_UNSUP;
              end else begin
                case (frm_op)
                  OP_PING: begin
                    resp_len    <= 16'd1;
                    resp_buf[0] <= ST_OK;
                  end
                  OP_STATUS: begin
                    // R2 layout: the cpu-derived registers are inserted
                    // between `target` and `faults` (11 payload words), so no
                    // field lies about a register the R1 layout omitted.
                    resp_len    <= 16'd11;
                    resp_buf[0] <= ST_OK;
                    resp_buf[1] <= {14'b0, dbg_state};       // state (R3: 2/3 = debug)
                    resp_buf[2] <= {15'b0, run};             // run
                    resp_buf[3] <= selected_target;
                    resp_buf[4] <= {6'b0, dbg_pc};           // pc, FULL width
                    resp_buf[5] <= {8'b0, dbg_a};
                    resp_buf[6] <= {8'b0, dbg_x};
                    resp_buf[7] <= {8'b0, dbg_y};
                    resp_buf[8] <= {8'b0, dbg_timer};
                    resp_buf[9] <= faults;                   // sticky bits
                    resp_buf[10] <= words_written;
                  end
                  OP_DUMPCOR: begin
                    // The core header. While STOPPED it equals the STATUS
                    // register header (the golden vectors assert the two are
                    // byte-identical); while run=1 it answers NOT_READY with
                    // no fault, because the values would be a moving target.
                    if (run) begin
                      resp_len    <= 16'd1;
                      resp_buf[0] <= ST_NOTREADY;
                    end else begin
                      resp_len    <= 16'd11;
                      resp_buf[0] <= ST_OK;
                      resp_buf[1] <= {14'b0, dbg_state};     // state (R3: 2/3 = debug)
                      resp_buf[2] <= {15'b0, run};           // run
                      resp_buf[3] <= selected_target;
                      resp_buf[4] <= {6'b0, dbg_pc};
                      resp_buf[5] <= {8'b0, dbg_a};
                      resp_buf[6] <= {8'b0, dbg_x};
                      resp_buf[7] <= {8'b0, dbg_y};
                      resp_buf[8] <= {8'b0, dbg_timer};
                      resp_buf[9] <= faults;
                      resp_buf[10] <= words_written;
                    end
                  end
                  OP_RDCPU: begin
                    // The ONLY non-halting read: it answers while run=1,
                    // which is the whole point of the opcode (a debugger must
                    // be able to see a running program). 7 payload words.
                    resp_len    <= 16'd7;
                    resp_buf[0] <= ST_OK;
                    resp_buf[1] <= {6'b0, dbg_pc};            // pc, FULL width
                    resp_buf[2] <= {8'b0, dbg_a};
                    resp_buf[3] <= {8'b0, dbg_x};
                    resp_buf[4] <= {8'b0, dbg_y};
                    resp_buf[5] <= dbg_insn;                 // 16-bit insn
                    resp_buf[6] <= {15'b0, run};             // run
                  end
                  OP_LOAD: begin
                    resp_len    <= 16'd4;
                    if (frm_not_ready)      resp_buf[0] <= ST_NOTREADY;
                    else if (frm_range)     resp_buf[0] <= ST_RANGE;
                    else if (frm_aborted)   resp_buf[0] <= ST_FAULT;
                    else                    resp_buf[0] <= ST_OK;
                    resp_buf[1] <= words_written;
                    resp_buf[2] <= faults;
                    resp_buf[3] <= load_echo;
                  end
                  OP_CLRFLT: begin
                    resp_len    <= 16'd2;
                    resp_buf[0] <= ST_OK;
                    resp_buf[1] <= faults & ~pay0;
                    faults      <= faults & ~pay0;
`ifdef FORMAL
                    fv_clr_mask_r <= pay0;   // formal-only observation
`endif
                  end
                  OP_TARGET: begin
                    if (pay0 == 16'd0) begin
                      resp_len    <= 16'd3;
                      resp_buf[0] <= ST_OK;
                      resp_buf[1] <= 16'd0;
                      resp_buf[2] <= CAP_HOST;
                      selected_target <= 16'd0;
                    end else if (pay0 == 16'd1) begin
                      resp_len    <= 16'd3;
                      resp_buf[0] <= ST_OK;
                      resp_buf[1] <= 16'd1;
                      resp_buf[2] <= CAP_LOOPBACK;
                      selected_target <= 16'd1;
                    end else begin
                      resp_len    <= 16'd1;
                      resp_buf[0] <= ST_UNSUP;
                    end
                  end
                  OP_RDIMEM, OP_RDMEM: begin
                    // Bounded reads. While run=1 they answer NOT_READY with NO
                    // fault (a sequencing rejection, like LOAD) -- the CPU is
                    // fetching and the read would borrow its address bus. The
                    // bounds are checked BEFORE any read is issued, so a
                    // rejected read never touches memory, and an
                    // address+count past the end is RANGE, never a wrap.
                    if (run) begin
                      resp_len    <= 16'd1;
                      resp_buf[0] <= ST_NOTREADY;
                      r_imm       <= 1'b1;
                      rstate      <= R_START;
                    end else if (frm_op == OP_RDIMEM) begin
                      // imem: address is a WORD index, count in words.
                      //
                      // count == 0 is RANGE, deliberately, NOT a zero-length
                      // frame: an empty read is a host bug, and answering OK
                      // with no words would leave the host unable to tell
                      // "nothing requested" from "read refused". This is pinned
                      // by the read_ceiling_and_zero_count golden vector, so
                      // the chip and the host model cannot drift apart on it.
                      if ((32'(pay0) + 32'(pay1)) > 32'(WORDS) ||
                          pay1 == 16'd0 || pay1 > 16'(MAX_READ_WORDS)) begin
                        resp_len    <= 16'd1;
                        resp_buf[0] <= ST_RANGE;
                        faults      <= faults | FAULT_RANGE;
                        r_imm       <= 1'b1;
                        rstate      <= R_START;
                      end else begin
                        resp_buf[0] <= ST_OK;
                        resp_len    <= 16'd1 + pay1;   // status + data words
                        r_dmem      <= 1'b0;
                        r_addr      <= pay0;
                        r_left      <= pay1;
                        r_slot      <= 16'd1;
                        r_half      <= 8'h00;
                        r_first     <= 1'b1;
                        r_imm       <= 1'b0;
                        rstate      <= R_START;
                      end
                    end else begin
                      // dmem: address is a BYTE index, count in bytes; two
                      // bytes pack per response word (ceil(count/2) words).
                      if ((32'(pay0) + 32'(pay1)) > 32'(DMEM_BYTES) ||
                          pay1 == 16'd0 || pay1 > 16'(2 * MAX_READ_WORDS)) begin
                        resp_len    <= 16'd1;
                        resp_buf[0] <= ST_RANGE;
                        faults      <= faults | FAULT_RANGE;
                        r_imm       <= 1'b1;
                        rstate      <= R_START;
                      end else begin
                        resp_buf[0] <= ST_OK;
                        // One status word plus ceil(count/2) data words.
                        resp_len    <= 16'd1 + ((pay1 + 16'd1) >> 1);
                        r_dmem      <= 1'b1;
                        r_addr      <= pay0;
                        r_left      <= pay1;
                        r_slot      <= 16'd1;
                        r_half      <= 8'h00;
                        r_first     <= 1'b1;      // next byte opens a pair
                        r_imm       <= 1'b0;
                        rstate      <= R_START;
                      end
                    end
                  end
                  // ---- R3 debug control ---------------------------------
                  OP_DBGSTEP: begin
                    // One instruction. The response reports the state and PC
                    // AFTER the step: state 2 (held) or 3 when the step LANDS
                    // on the armed breakpoint, and pc_next is where the core
                    // will resume. A free-running core cannot be stepped:
                    // NOT_READY with no side effect (no instruction executes).
                    resp_len    <= 16'd5;
                    resp_buf[0] <= ST_OK;
                    resp_buf[1] <= {14'b0, (bp_en && (dbg_next_pc == bp_addr))
                                          ? 2'd3 : 2'd2};
                    resp_buf[2] <= {6'b0, dbg_next_pc[9:0]};
                    resp_buf[3] <= {6'b0, bp_addr};
                    // POST-step flags: bit0 armed, bit1 the hit the step leaves
                    // (a step away from the bp clears it; a landing sets it).
                    // `bp_flags` is the PRE-edge latch and would report the
                    // hit the step is clearing.
                    resp_buf[4] <= {14'b0, (bp_en && (dbg_next_pc == bp_addr))
                                          ? 2'b11 : {1'b0, bp_en}};
                    if (run && !dbg_hold_r) begin
                      resp_buf[0] <= ST_NOTREADY;
                      resp_buf[1] <= {14'b0, dbg_state};
                      resp_buf[2] <= {6'b0, dbg_pc};
                      resp_buf[4] <= {14'b0, bp_flags};
                    end else begin
                      dbg_step_r <= 1'b1;
                      dbg_hold_r <= 1'b1;
                      bp_hit     <= bp_en && (dbg_next_pc == bp_addr);
                    end
                  end
                  OP_DBGBPSET: begin
                    // Arm (or re-arm). Past the end of instruction memory is
                    // RANGE and changes NOTHING -- a rejected op has no side
                    // effect. Arming clears a stale hit.
                    resp_len    <= 16'd5;
                    resp_buf[0] <= ST_OK;
                    resp_buf[1] <= {14'b0, dbg_state};
                    resp_buf[2] <= {6'b0, dbg_pc};
                    resp_buf[3] <= {6'b0, pay0[9:0]};
                    resp_buf[4] <= {14'b0, 2'b01};
                    if (32'(pay0) >= 32'(WORDS)) begin
                      resp_buf[0] <= ST_RANGE;
                      resp_buf[3] <= {6'b0, bp_addr};
                      resp_buf[4] <= {14'b0, bp_flags};
                    end else begin
                      bp_addr <= pay0[9:0];
                      bp_en   <= 1'b1;
                      bp_hit  <= 1'b0;
                    end
                  end
                  OP_DBGBPCLR: begin
                    // Disarm, clear the hit, and RELEASE the hold. The state
                    // word is the released state: RUNNING when the strap is
                    // high, STOPPED (boot stop) otherwise. The pc field is the
                    // PC at the request; with run=0 the core re-zeroes at this
                    // same edge, so a following STATUS reads 0.
                    resp_len    <= 16'd5;
                    resp_buf[0] <= ST_OK;
                    resp_buf[1] <= {14'b0, run ? 2'd1 : 2'd0};
                    resp_buf[2] <= {6'b0, dbg_pc};
                    resp_buf[3] <= {6'b0, bp_addr};
                    resp_buf[4] <= {14'b0, 2'b00};
                    bp_en      <= 1'b0;
                    bp_hit     <= 1'b0;
                    dbg_hold_r <= 1'b0;
                  end
                  OP_DBGSTAT: begin
                    // The common 5-word prefix plus the architectural state,
                    // the same fields and widths READ_CPU reports.
                    resp_len    <= 16'd10;
                    resp_buf[0] <= ST_OK;
                    resp_buf[1] <= {14'b0, dbg_state};
                    resp_buf[2] <= {6'b0, dbg_pc};
                    resp_buf[3] <= {6'b0, bp_addr};
                    resp_buf[4] <= {14'b0, bp_flags};
                    resp_buf[5] <= {15'b0, run};
                    resp_buf[6] <= {8'b0, dbg_a};
                    resp_buf[7] <= {8'b0, dbg_x};
                    resp_buf[8] <= {8'b0, dbg_y};
                    resp_buf[9] <= dbg_insn;
                  end
                  default: begin
                    resp_len    <= 16'd1;
                    resp_buf[0] <= ST_UNSUP;
                  end
                endcase
              end

              // ---- start the response serializer --------------------------
              // NOT for the bounded reads: their answer is the memory, so the
              // read engine starts the serializer itself -- for EVERY read
              // outcome, including the immediate NOT_READY and RANGE ones.
              if (!r_is_read) begin
                resp_idx    <= '0;
                resp_bitpos <= '0;
                resp_crc    <= 16'hFFFF;
                resp_active <= 1'b1;
              end
              rx_state    <= S_SYNC;
              // A new request frame restarts the filler word: the host's skip
              // counts leading 0xFFFF words from this frame's first bit.
              fill_pos    <= 4'd0;
              r_launch    <= 1'b0;
            end
            default: rx_state <= S_SYNC;
          endcase
        end else begin
          shreg   <= {shreg[13:0], mosi_s1};
          bit_cnt <= bit_cnt + 4'd1;
        end
      end

      // ---- write engine: one host_we cycle per committed payload word -----
      // `run` is checked in EVERY state: a word queued when run rises is
      // ABORTED (discarded, faulted) and never reappears. The frame engine
      // also stops offering words after the first abort, so the rest of the
      // load cannot resurrect it.
      case (wstate)
        W_IDLE: begin
          we_r <= 1'b0;
          if (word_ready) begin
            if (run) begin
              word_ready  <= 1'b0;
              frm_aborted <= 1'b1;
              faults      <= faults | FAULT_LOAD;
            end else begin
              wstate <= W_PULSE;
            end
          end
        end
        W_PULSE: begin
          if (run) begin
            we_r        <= 1'b0;
            word_ready  <= 1'b0;
            frm_aborted <= 1'b1;
            faults      <= faults | FAULT_LOAD;
            wstate      <= W_IDLE;
          end else begin
            we_r   <= 1'b1;
            wstate <= W_DONE;
          end
        end
        W_DONE: begin
          we_r       <= 1'b0;
          word_ready <= 1'b0;
          if (run) begin
            frm_aborted <= 1'b1;
            faults      <= faults | FAULT_LOAD;
            wstate      <= W_IDLE;
          end else begin
            words_written <= words_written + 16'd1;
            load_echo     <= pay0;      // commit-latched echo
            addr          <= addr + 1'b1;
            wstate        <= W_IDLE;
          end
        end
        default: wstate <= W_IDLE;
      endcase

      // ---- R2 read engine: walk the requested range, then serialize -------
      // The host asked for a bounded read; answer it from the memory, not
      // from a register, so the response cannot start until the last word is
      // in. Each R_REQ pulses one address; R_WAIT collects the answer.
      case (rstate)
        R_IDLE: begin end
        R_START: begin
          // Every read outcome passes here exactly once, so the serializer
          // start lives in ONE place: an immediate rejection starts it now, a
          // walk starts it when its last word has landed.
          if (r_imm) begin
            resp_idx    <= '0;
            resp_bitpos <= '0;
            resp_crc    <= 16'hFFFF;
            resp_active <= 1'b1;
            rstate      <= R_IDLE;
          end else begin
            rstate      <= R_REQ;
          end
        end
        R_REQ: begin
          rstate <= R_WAIT;
        end
        R_WAIT: begin
          if (dbg_rd_valid) begin
            // dmem arrives ONE BYTE per read; two bytes pack big-endian into
            // one response word (high byte first). The first byte of a pair
            // is held in r_half and only written to the slot once its partner
            // arrives, so there is NO read-modify-write of resp_buf (which
            // would not be a real register). imem arrives one word per read
            // and is stored as-is.
            if (r_dmem) begin
              if (r_first) begin                   // first byte: hold it
                r_half  <= dbg_rd_data[7:0];
                r_first <= 1'b0;
              end else begin                       // second byte: emit word
                resp_buf[r_slot[3:0]] <= {r_half, dbg_rd_data[7:0]};
                r_slot  <= r_slot + 16'd1;
                r_first <= 1'b1;
              end
            end else begin
              resp_buf[r_slot[3:0]] <= dbg_rd_data;
              r_slot <= r_slot + 16'd1;
            end
            r_addr <= r_addr + 16'd1;
            r_left <= r_left - 16'd1;
            if (r_left == 16'd1) begin
              // A dmem read with an ODD byte count ends holding its last byte
              // in r_half (it never got a partner), so flush it as a word with
              // that byte in the LOW half. Without this the trailing byte is
              // silently dropped and the response is a word short of its
              // declared length. The value is dbg_rd_data, NOT r_half: this
              // byte is the one that just arrived and is still in flight
              // (r_half holds the PREVIOUS byte until the non-blocking
              // assignment lands next cycle).
              if (r_dmem && r_first)
                resp_buf[r_slot[3:0]] <= {8'h00, dbg_rd_data[7:0]};
              // The fetch is done, but the frame must begin on a WORD
              // boundary or the host's 16-bit reader would start half a word
              // in. Wait for fill_pos to wrap to 0 (the end of the filler
              // word) and start the real serializer there. That is exactly
              // the first non-0xFFFF word the host sees.
              r_launch <= 1'b1;
              rstate   <= R_IDLE;
            end else begin
              rstate <= R_REQ;
            end
          end
        end
        default: rstate <= R_IDLE;
      endcase

      // ---- response serializer (mode 0: changes on the detected fall) -----
      if (sclk_fall && !cs_s1) begin
        if (r_filling) begin
          // One filler bit per SPI falling edge, every bit a 1, so the word
          // the host assembles is 0xFFFF. No shift register is needed: the
          // value is constant.
          spi_miso  <= 1'b1;
          fill_pos  <= fill_pos + 4'd1;
        end else if (r_launch) begin
          // The fetch finished, but the frame must begin on a WORD boundary
          // or the host's 16-bit reader would start half a word in. Keep
          // driving filler until fill_pos wraps, then hand the line to the
          // real serializer -- that boundary is exactly the first non-0xFFFF
          // word the host sees. (This branch CANNOT live inside the r_filling
          // arm: setting r_launch clears r_filling, so the arm is skipped
          // exactly when the launch is needed.)
          spi_miso  <= 1'b1;
          if (fill_pos == 4'd15) begin
            r_launch    <= 1'b0;
            fill_pos    <= 4'd0;
            resp_idx    <= '0;
            resp_bitpos <= '0;
            resp_crc    <= 16'hFFFF;
            resp_active <= 1'b1;
          end else begin
            fill_pos    <= fill_pos + 4'd1;
          end
        end else if (resp_active) begin
          if (resp_bitpos == 4'd0) begin
            spi_miso   <= resp_w[15];
            resp_shreg <= {resp_w[14:0], 1'b0};
          end else begin
            spi_miso   <= resp_shreg[15];
            resp_shreg <= {resp_shreg[14:0], 1'b0};
          end
          if (resp_bitpos == 4'd15) begin
            if ({11'b0, resp_idx} < resp_len + 16'd4)
              resp_crc <= crc16_word(resp_crc, resp_w);
            if ({11'b0, resp_idx} == resp_len + 16'd4) begin
              // The CRC word was just presented; hold the OE through its
              // sampling rise, then release on the next fall.
              resp_active  <= 1'b0;
              resp_hold_oe <= 1'b1;
            end else begin
              resp_idx    <= resp_idx + 5'd1;
              resp_bitpos <= 4'd0;
            end
          end else begin
            resp_bitpos <= resp_bitpos + 4'd1;
          end
        end else if (resp_hold_oe) begin
          resp_hold_oe <= 1'b0;
        end
      end
    end
  end

`ifdef FORMAL
  // ---- formal-only observation aliases (see the port list) --------------.
  // Pure aliases plus the two event registers: no logic, no state, and the
  // whole block disappears when FORMAL is undefined.
  assign fv_resp_len    = resp_len;
  assign fv_resp_idx    = resp_idx;
  assign fv_resp_active = resp_active;
  assign fv_r_addr      = r_addr;
  assign fv_r_left      = r_left;
  assign fv_r_slot      = r_slot;
  assign fv_r_dmem      = r_dmem;
  assign fv_rstate      = rstate;
  assign fv_faults      = faults;
  assign fv_clr_mask    = fv_clr_mask_r;
  assign fv_resp_bitpos = resp_bitpos;
  assign fv_r_imm       = r_imm;
  // R3 debug taps: the state encoding and the breakpoint register, so the
  // debug claims can be stated over ports (form/pe_ctrl/formal_pe_ctrl.v).
  assign fv_dbg_state   = dbg_state;
  assign fv_bp_en       = bp_en;
  assign fv_bp_hit      = bp_hit;
  assign fv_bp_addr     = bp_addr;
  assign fv_dbg_hold    = dbg_hold_r;
`endif

endmodule
