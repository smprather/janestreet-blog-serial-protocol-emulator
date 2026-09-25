// pe_cpu.v — the protocol emulator's firmware processor.
//
// Thesis: protocol logic belongs in software. This core is the smallest thing
// that can run it, so a protocol becomes a *program* — patchable, reloadable,
// shareable across protocols — instead of a state machine in gates.
//
// Deliberate minimums, each of which costs area to relax:
//   * one 8-bit accumulator A, one 8-bit scratch Y, one 8-bit pointer X
//   * PC width derived from instruction memory depth (8 bits at 128 words,
//     10 at 1024) -- it must be able to NAME every word it can fetch
//   * instruction memory parameterised (128 words by default)
//   * 16-bit fixed-width instructions, 16 opcodes, no addressing modes
//   * Harvard: instruction port and data buffer are separate memories
//   * no stack, no interrupts, no subroutine call, no multiply
//   * single cycle: instruction fetch and IO read are combinational
//
// IO is a 4-bit port space; the peripherals hang off it in pe_soc.
//
// Register discipline the firmware relies on:
//   X  = the long-lived index (line buffer pointer). STS/LDS address through it
//        with no offset, so it is never used as a scratch loop counter.
//   Y  = transient scratch.
//   RAM (LDM/STM) = loop counters and fixed-slot variables.
// That split is why the ISA has both X-indexed and immediate-addressed memory
// ops: one register cannot serve as both pointer and counter.
//
// Instruction encoding — [15:12] opcode, [11:0] operand:
//
//   0x0 LDI  a, imm8     a = imm8
//   0x1 OUT  port, a     io[port] = a
//   0x2 IN   a, port     a = io[port]
//   0x3 MOV  sel         sel: 0 a<-y, 1 y<-a, 2 x<-a, 3 a<-x
//   0x4 JMP  addr8       pc = addr8
//   0x5 JZ   addr8       if (a == 0) pc = addr8
//   0x6 JNZ  addr8       if (a != 0) pc = addr8
//   0x7 ALU  sub, imm8   sub: 0 add, 1 sub, 2 and, 3 or
//   0x8 INCX             x = x + 1
//   0x9 DECX             x = x - 1
//   0xA SHR  a           a = a >> 1
//   0xB LDS  a, [x]      a = ram[x]
//   0xC STS  [x], a      ram[x] = a
//   0xD LDM  a, addr8    a = ram[addr8]
//   0xE STM  addr8, a    ram[addr8] = a
//   0xF NOP
//
// Flags: only "a == 0", tested by JZ/JNZ. There is no carry and no overflow
// flag; SUBI is only ever used as "subtract an immediate and branch if the
// result hit zero", which is how every loop and every byte comparison in the
// firmware is written.

module pe_cpu #(
  parameter int IMEM_WORDS = 128,
  parameter int DMEM_BYTES = 16
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             run,        // 1: execute. 0: held at PC=0 (boot)

  // R3 debug control (manager dispatch 2026-09-25). `dbg_hold` MASKS the run
  // strap: while high the core does not execute and PRESERVES its PC -- the
  // dual of the boot stop above, which holds it at 0 for the loader. `dbg_step`
  // is a one-cycle pulse that executes exactly one instruction. Both come from
  // pe_ctrl (the host bus); no pad is added for either.
  input  logic             dbg_hold,
  input  logic             dbg_step,

  // Instruction memory (combinational read, registered writes by the loader).
  // The width expressions repeat the localparam definitions inline because
  // iverilog binds port dimensions before later localparams are visible.
  output logic [((IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS))-1:0] imem_addr,
  input  logic [15:0]      imem_rdata,

  // Data buffer
  output logic [((DMEM_BYTES <= 2) ? 1 : $clog2(DMEM_BYTES))-1:0] dmem_addr,
  output logic             dmem_we,
  output logic [7:0]       dmem_wdata,
  input  logic [7:0]       dmem_rdata,

  // Memory-mapped IO
  output logic [3:0]       io_port,
  output logic             io_we,
  output logic             io_re,
  output logic [7:0]       io_wdata,
  input  logic [7:0]       io_rdata,

  // Observability. These are real ports, not hierarchical references from the
  // parent: `assign dbg_pc = u_cpu.pc` in pe_soc.v simulated correctly in
  // Icarus but yosys declared `\u_cpu.pc` as an implicit wire and drove it
  // BACKWARDS, leaving the SoC's dbg_pc constant-zero above bit 0 in the
  // netlist. A cross-module reference is not synthesisable; a port is.
  // They cost nothing: pc and a exist regardless, and an unloaded output is
  // removed by the synthesiser at the top level.
  //
  // R2 (the host read path): the registers are exposed at their NATIVE
  // widths, not truncated. `dbg_pc` used to be 8 bits, which silently hid
  // two PC bits above address 255 in a 1,024-word machine -- exactly the
  // "no response may lie about a register" rule the R1 STATUS layout was
  // written to honour, so the truncation had to go rather than be reported
  // as a value. `dbg_x`/`dbg_y`/`dbg_insn` are new: the host's READ_CPU
  // answers while `run=1` and needs the whole architectural state, not just
  // PC and A.
  output logic [((IMEM_WORDS <= 2) ? 1 : ((IMEM_WORDS <= 256) ? 8 : $clog2(IMEM_WORDS)))-1:0] dbg_pc,
  output logic [7:0]       dbg_a,
  output logic [7:0]       dbg_x,
  output logic [7:0]       dbg_y,
  output logic [15:0]      dbg_insn,
  // R3: the landing address of the step about to execute. pe_ctrl samples it
  // in the dispatch cycle, so the DEBUG_STEP response can report where the core
  // resumes even though the instruction commits at the following edge (the PC
  // and the fetched instruction are frozen in between, by construction).
  output logic [((IMEM_WORDS <= 2) ? 1 : ((IMEM_WORDS <= 256) ? 8 : $clog2(IMEM_WORDS)))-1:0] dbg_next_pc
);

  localparam int IAW = (IMEM_WORDS <= 2) ? 1 : $clog2(IMEM_WORDS);
  localparam int DAW = (DMEM_BYTES <= 2) ? 1 : $clog2(DMEM_BYTES);

  // PC width. The program counter must be able to NAME every word in
  // instruction memory, so it is derived from IMEM_WORDS rather than fixed at 8.
  //
  // This used to be a fixed `logic [7:0] pc`, which silently capped the
  // reachable program at 256 words no matter how deep the memory was: at
  // IMEM_WORDS=1024 the expression `next_pc[IAW-1:0]` became an out-of-range
  // part-select on an 8-bit vector, and the memory below word 256 was not
  // addressable at all. See decisions/adr-004-program-counter-width.md.
  //
  // PCW is at least 8 for compatibility with the original ISA (a 128-word
  // program still gets an 8-bit PC, and every existing fixture is unchanged).
  localparam int PCW = (IAW > 8) ? IAW : 8;

  // The jump target field. JMP/JZ/JNZ carry it in arg[PCW-1:0] when the PC is
  // wider than 8 bits; at PCW=8 the field is arg[7:0] exactly as before, so the
  // encoding of every existing program is bit-identical.
  //
  // arg[11:8] were unused by these three opcodes, so a 10-bit target costs no
  // encoding and breaks no other instruction. If PCW ever exceeds 12 this needs
  // a second instruction word instead -- guarded below.

  localparam logic [3:0] OP_LDI  = 4'h0,
                         OP_OUT  = 4'h1,
                         OP_IN   = 4'h2,
                         OP_MOV  = 4'h3,
                         OP_JMP  = 4'h4,
                         OP_JZ   = 4'h5,
                         OP_JNZ  = 4'h6,
                         OP_ALU  = 4'h7,
                         OP_INCX = 4'h8,
                         OP_DECX = 4'h9,
                         OP_SHR  = 4'hA,
                         OP_LDS  = 4'hB,
                         OP_STS  = 4'hC,
                         OP_LDM  = 4'hD,
                         OP_STM  = 4'hE,
                         OP_NOP  = 4'hF;

  localparam logic [1:0] ALU_ADD = 2'd0,
                         ALU_SUB = 2'd1,
                         ALU_AND = 2'd2,
                         ALU_OR  = 2'd3;

  logic [7:0] a, y, x;
  logic [PCW-1:0] pc;
  // Declared before the debug assigns below (Icarus binds declaration
  // before use); it is assigned from imem_rdata in the fetch section.
  logic [15:0] insn;

  // Full width, NOT truncated: dbg_pc was `pc[7:0]`, which reported 0 for a PC
  // above 255 in a 1,024-word machine. R2 exposes the real register.
  assign dbg_pc   = pc;
  assign dbg_a    = a;
  assign dbg_x    = x;
  assign dbg_y    = y;
  assign dbg_insn = insn;

  // ---- fetch (fetch-ahead) ----------------------------------------------
  // The instruction ROM has a REGISTERED output (it models a real ROM macro,
  // and the testbench registers its read the same way). So the address driven
  // this cycle is the address whose data will be ready NEXT cycle -- which must
  // be next_pc, not pc.
  //
  // The bug this replaces: driving imem_addr with `pc` made imem_rdata hold
  // imem[pc-1] while `pc` had already advanced, so every jump executed the
  // instruction at the FALL-THROUGH address before reaching its target. It
  // showed up as wait loops that walked past themselves.
  //
  //   cycle C   : pc=P, imem_rdata=imem[P]. Compute next_pc=N. Drive addr=N.
  //               The ROM registers imem[N] at the edge ending C; pc <= N.
  //   cycle C+1 : imem_rdata=imem[N]=imem[pc]. Correct instruction, no lag.
  logic [3:0]  op;
  logic [11:0] arg;
  assign insn = imem_rdata;
  assign op   = insn[15:12];
  assign arg  = insn[11:0];

  logic [PCW-1:0] next_pc;
  always_comb begin
    next_pc = pc + 1'b1;               // default: fall through
    case (op)
      OP_JMP: next_pc = arg[PCW-1:0];
      OP_JZ:  if (a == 8'h00) next_pc = arg[PCW-1:0];
      OP_JNZ: if (a != 8'h00) next_pc = arg[PCW-1:0];
      default: ;
    endcase
  end

  // Elaboration guard: the jump target lives in the operand's low bits, and
  // arg[11:8] are only free for these opcodes. A PC wider than 12 bits would
  // need a second instruction word, which this ISA does not have -- failing here
  // is better than a target that silently truncates.
  if (PCW > 12) begin : g_pcw_guard
    $error("pe_cpu: PCW exceeds the 12-bit operand field; the ISA needs a second instruction word before the PC can widen further");
  end

  // ---- R3 debug glue: execute, hold, step ---------------------------------
  // `cpu_exec` is the single execute gate: the strap, masked by the debug hold,
  // plus the step pulse. Everything that commits (the PC and every side effect)
  // hangs off it, so a held core is inert by construction.
  // THE DEFENSIVE DEFAULT, and it is load-bearing. dbg_hold and dbg_step are
  // module INPUTS, and every instantiation that predates them leaves them
  // unconnected: the port arrives as Z, `!dbg_hold` is X, and this gate is X,
  // so the core never executes an instruction and every observable in the
  // system stays at its reset value. That is not a hypothetical -- it is what
  // happened to the six timing acts when R3 landed, and the symptom
  // (dmem = xx, zero edges, a watchdog) looks like a firmware bug in six
  // unrelated programs at once.
  //
  // Tested with CASE equality so that anything which is not a HARD one reads
  // as "not held" / "no step": the debug interface is inactive unless
  // something actively asserts it. In synthesis this is identical to the
  // plain expression (x and z do not exist in hardware), so nothing about the
  // netlist changes -- the convention is that a debug input defaults to
  // inactive, and it is enforced where the input is consumed rather than at
  // every call site, which is the only place a new call site cannot forget it.
  wire cpu_exec = (dbg_step === 1'b1) || (run && !(dbg_hold === 1'b1));
  assign dbg_next_pc = next_pc;

  // While !run the core holds pc at 0 (the boot loader owns the window), and
  // the ROM must be pre-loading imem[0] so the first instruction is ready the
  // moment run rises. The address is ZERO, not `pc`: pc becomes 0 at the first
  // stopped edge, but a registered ROM samples the address presented during
  // that cycle, which was still the old pc. A one-clock stop then resumed with
  // a stale fetched word (measured: `LDI A,55; LDI A,AA; JMP 2`, stopped for
  // one clock, resumed at JMP 2 with A=AA instead of executing LDI A,55;
  // review 2 R2-4). Addressing zero immediately makes a one-clock stop safe.
  //
  // R3 adds the same argument for the DEBUG HOLD: while held the address is
  // `pc`, so the ROM keeps presenting imem[pc] and the instruction the host
  // sees in dbg_insn is exactly the one a step will execute. During the step
  // cycle the address switches to next_pc, refilling the fetch for the resumed
  // PC -- the three modes (running / boot stop / debug hold) each keep the
  // pipeline invariant `imem_rdata == imem[pc]`.
  assign imem_addr = cpu_exec ? next_pc[IAW-1:0]
                   : dbg_hold ? pc[IAW-1:0]
                   : {IAW{1'b0}};

  // ---- address / data bus ----------------------------------------------
  // One write port, muxed: STS addresses through X, STM through an immediate.
  assign dmem_addr  = (op == OP_STM) ? arg[DAW-1:0]
                    : (op == OP_LDM) ? arg[DAW-1:0]
                    : x[DAW-1:0];
  assign dmem_wdata = a;
  assign dmem_we    = cpu_exec && ((op == OP_STS) || (op == OP_STM));

  assign io_port  = arg[3:0];
  assign io_wdata = a;
  assign io_we    = cpu_exec && (op == OP_OUT);
  assign io_re    = cpu_exec && (op == OP_IN);

  // ---- ALU --------------------------------------------------------------
  // The second operand is normally an immediate, but arg[9] selects X instead.
  // That one bit is the whole reason the ISA has a register-register subtract:
  // "wait for the timer to move" needs (current - snapshot), and an immediate
  // cannot express it. Bits 11:10 pick the operation, bit 9 picks the source,
  // bits 7:0 carry the immediate when bit 9 is clear.
  logic [7:0] alu_rhs;
  assign alu_rhs = arg[9] ? x : arg[7:0];

  // arg[8] was the one encoding bit no instruction read. That is no longer true
  // when the PC is wider than 8 bits: arg[8] and arg[9] are now part of the jump
  // target for JMP/JZ/JNZ (see PCW above). It is still unused for every OTHER
  // opcode, so it stays sunk -- but the sink is now honest about being
  // opcode-dependent rather than a statement that the bit is dead.
  // gate stays clean and so "unused" is a statement in the RTL rather than a
  // warning somebody has to remember is expected.
  logic _unused_arg8;
  assign _unused_arg8 = arg[8];

  logic [7:0] alu_q;
  always_comb begin
    case (arg[11:10])
      ALU_ADD: alu_q = a + alu_rhs;
      ALU_SUB: alu_q = a - alu_rhs;
      ALU_AND: alu_q = a & alu_rhs;
      ALU_OR:  alu_q = a | alu_rhs;
      default: alu_q = a;
    endcase
  end

  // ---- execute ----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= '0;
      a  <= 8'h00;
      y  <= 8'h00;
      x  <= 8'h00;
    end else if (cpu_exec) begin
      // next_pc is computed combinationally above (fetch-ahead) and the ROM
      // address already follows it; commit it here. This is the ONLY place the
      // PC advances, so a step commits exactly one update.
      pc <= next_pc;
      case (op)
        OP_LDI:  a <= arg[7:0];
        OP_OUT:  ;                     // side effect: io_we this cycle
        OP_IN:   a <= io_rdata;
        OP_MOV:  case (arg[1:0])
                   2'd0: a <= y;
                   2'd1: y <= a;
                   2'd2: x <= a;
                   2'd3: a <= x;
                   default: ;
                 endcase
        OP_JMP:  ;                     // pc handled by next_pc
        OP_JZ:   ;                     // pc handled by next_pc
        OP_JNZ:  ;                     // pc handled by next_pc
        OP_ALU:  a <= alu_q;
        OP_INCX: x <= x + 8'd1;
        OP_DECX: x <= x - 8'd1;
        OP_SHR:  a <= {1'b0, a[7:1]};
        OP_LDS:  a <= dmem_rdata;
        OP_STS:  ;                     // side effect: dmem_we this cycle
        OP_LDM:  if (arg[7]) x <= dmem_rdata;   // LDM X, addr: load the index
                 else        a <= dmem_rdata;   // LDM A, addr
        OP_STM:  ;                     // side effect: dmem_we this cycle
        OP_NOP:  ;
        default: ;
      endcase
    end else if (!dbg_hold) begin
      pc <= '0;                        // boot stop: held by the loader
    end
    // else: debug hold -- pc keeps its value (R3)
  end

endmodule
