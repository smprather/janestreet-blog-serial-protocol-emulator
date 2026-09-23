# pe_ctrl (passive SPI load path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `rtl/pe_ctrl.v`, a passive SPI slave that lets a host clock a program into `pe_imem` through the SoC's existing host write port, and prove at the Tiny Tapeout top level that a program loaded through three pads actually executes.

**Architecture:** Three asynchronous pads (SCLK, MOSI, CS_N) go through 2-flop synchronizers; a rising-SCLK-edge detector shifts MSB-first 16-bit words. `CS_N` low resets a word address to 0 and enables the loader; every 16 rising edges emits one `host_we` pulse on the SoC's host port at `imem[addr++]`. `CS_N` high ends the load and discards a partial word. Every path is gated on `run == 0`, so a stray edge during execution cannot corrupt instruction memory. The block is instantiated in `tt_um_protocol_emulator`, between the loader pads and the SoC.

**Tech Stack:** Verilog-2001/2012 RTL, Icarus Verilog, Verilator + yosys lint gate, Tiny Tapeout wrapper conventions.

**Spec:** `wiki/decisions/adr-007-pe-ctrl-passive-slave.md` (the decision: passive slave, wrapper placement, v1 wire contract). `wiki/STATUS.md` "Next steps" item 2 is the work item. `rtl/pe_imem.v` and `rtl/tt_um_protocol_emulator.v` define the host port and pad contract it must satisfy.

## Global Constraints

- **60 MHz operating point is LOCKED.** The loader's synchronizer budget is quoted against it; SCLK is ≤ ~10 MHz.
- **Standing user ruling: do not run physical flow, DRC or LVS.**
- **Every new testbench is self-checking, prints `PASS: <name>`, and is added to `regress/run_all.sh`'s `CASES`.** A TB nothing runs is not a test.
- **`regress/lint.sh` has no accepted warnings.** Unused outputs and pads are sunk with the `wire _unused = &{...}` pattern.
- **Every mutation harness restores by file copy and verifies the restore** — `git checkout` destroys untracked work (the eth_mac harness lesson).
- **Generated docs are drift-gated**: regenerate `wiki/reference/block-diagram.md` and `wiki/reference/signal-names.md` in the same change, and refresh `wiki/reference/.block-diagram-cells` from `synth_area.sh` before regenerating the diagram.
- **No `timescale` in RTL files.** The repo's RTL is timescale-free.
- **Tiny Tapeout rules stay true:** `ena` gates nothing; every output is driven in every state.

## Review Focus

1. **A second load after the first.** `CS_N` low must reset the word address and `words_written`; a reload without a reset must land at word 0. Task 1's TB case 2 and Task 2's `cs-reset` mutation pin it.
2. **An SCLK edge while `run == 1`.** The loader must not write; otherwise an SPI-firmware session on the same pads corrupts executing code. Task 1's TB case 4 and Task 2's `run-gate` mutation pin it.
3. **A partial word at `CS_N` rising.** It must be discarded, not written, and flagged. Task 1's TB case 3 and Task 2's `partial-word-flag` mutation pin it.
4. **More words than instruction memory.** Words past `WORDS-1` must be refused and flagged, not wrapped over word 0. Task 1's TB case 5 and Task 2's `address-increment` mutation cover the boundary.
5. **SCLK much slower than the core clock (a human clicking a scope button).** The synchronizer and edge detector must not depend on a maximum period; low-frequency operation is a functional case, not an afterthought. Task 1's TB runs at 5 MHz; a slower soak is a TB-level knob.

---

### Task 1: `pe_ctrl` RTL + unit TB + wrapper integration + TT-level load proof

**Files:**
- Create: `rtl/pe_ctrl.v`
- Create: `tb/tb_pe_ctrl.v`
- Modify: `rtl/tt_um_protocol_emulator.v` (host port now driven by `pe_ctrl`; pin map; `_unused`)
- Modify: `tb/tb_tt_um_protocol_emulator.v` (idle `CS_N` high; a load-through-the-pads phase)
- Modify: `regress/run_all.sh` (`tb_pe_ctrl` case; `pe_ctrl.v` in the TT case)
- Modify: `regress/lint.sh` (`RTL_ALL`, both top lists)
- Modify: `regress/synth_area.sh` (`report pe_ctrl`; TT source list)
- Modify: `info.yaml` (`source_files`; pinout `ui[3..5]`)
- Modify: `tools/gen/block_diagram.py` (`pe_ctrl` built; remove it from PLANNED; mermaid)
- Regenerate: `wiki/reference/block-diagram.md`, `wiki/reference/.block-diagram-cells`, `wiki/reference/signal-names.md`, `diagrams/block-diagram.stamp`

**Interfaces:**
- Consumes: `pe_soc`'s host port — `host_we`, `host_imem_sel`, `host_addr[9:0]`, `host_wdata[15:0]` (see `rtl/pe_soc.v`); the `ui_in` pads.
- Produces (Task 3 and the wrapper consume):
  - `pe_ctrl #(.WORDS(1024))` with ports `spi_sclk`, `spi_mosi`, `spi_cs_n`, `run`, `host_we`, `host_imem_sel`, `host_addr`, `host_wdata`, `load_active`, `load_error`, `words_written[15:0]`.
  - `tb_pe_ctrl` (unit) and the TT TB's load phase.

- [ ] **Step 1: Write the failing unit testbench**

Create `tb/tb_pe_ctrl.v` exactly as below. `WORDS=16` keeps the oversize case fast; the address port clamps to 8 bits, exactly like the SoC's.

```verilog
// tb_pe_ctrl.v — the passive SPI loader, at the host's side of the wire.
//
// WHAT THIS PROVES
//
// A host can clock 16-bit words into the SoC's host write port: MSB-first,
// mode 0, one word per 16 rising SCLK edges, addresses incrementing, CS_N
// resetting the load, partial words discarded, and nothing written while the
// core runs. The TB drives the three pads and captures every host_we pulse;
// it never inspects pe_ctrl internals.

`timescale 1ns / 1ps

module tb_pe_ctrl;

  localparam int  WORDS   = 16;           // small: the oversize case runs here
  localparam real CLK_NS  = 1e9 / 60e6;   // 60 MHz, the locked operating point
  localparam real HALF_NS = 100.0;        // 5 MHz SCLK: 6 clocks per half period

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic spi_sclk, spi_mosi, spi_cs_n, run;
  wire  host_we, host_imem_sel, load_active, load_error;
  wire [7:0]  host_addr;                  // WORDS=16 -> IAW=4, clamped to 8
  wire [15:0] host_wdata, words_written;

  pe_ctrl #(.WORDS(WORDS)) dut (
    .clk(clk), .rst_n(rst_n),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n),
    .run(run),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .load_active(load_active), .load_error(load_error),
    .words_written(words_written)
  );

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---- host-side capture of every write the loader emits ----------------
  logic [15:0] cap_data [0:63];
  int          cap_addr [0:63];
  int          cap_n;
  always @(posedge clk) if (host_we) begin
    cap_data[cap_n] = host_wdata;
    cap_addr[cap_n] = host_addr;
    cap_n = cap_n + 1;
  end

  // ---- host-side SPI driver (mode 0: data changes while SCLK is low) ----
  task automatic spi_bit(input logic b);
    spi_mosi = b;
    #(HALF_NS);
    spi_sclk = 1'b1;
    #(HALF_NS);
    spi_sclk = 1'b0;
  endtask

  task automatic spi_word(input logic [15:0] w);
    for (int k = 15; k >= 0; k--) spi_bit(w[k]);
  endtask

  task automatic cs_low;  spi_cs_n = 1'b0; #(HALF_NS); endtask
  task automatic cs_high; spi_cs_n = 1'b1; #(HALF_NS); endtask

  task automatic settle;  repeat (8) @(posedge clk); #1; endtask

  task automatic check_write(input int idx, input logic [15:0] data,
                             input int addr, input string tag);
    check(cap_n > idx, $sformatf("%s: write %0d missing", tag, idx));
    if (cap_n > idx) begin
      check(cap_data[idx] === data,
            $sformatf("%s: write %0d data=%04h want %04h",
                      tag, idx, cap_data[idx], data));
      check(cap_addr[idx] === addr,
            $sformatf("%s: write %0d addr=%0d want %0d",
                      tag, idx, cap_addr[idx], addr));
    end
  endtask

  initial begin
    $dumpfile("tb_pe_ctrl.vcd");
    $dumpvars(0, tb_pe_ctrl);

    spi_sclk = 1'b0; spi_mosi = 1'b0; spi_cs_n = 1'b1; run = 1'b0;
    cap_n = 0;
    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    repeat (2) @(posedge clk); #1;

    // ================= 1: three words, MSB-first, incrementing ==========
    cs_low;
    spi_word(16'hA55A);        // non-palindromic: catches a bit-order flip
    spi_word(16'h1234);
    spi_word(16'hF00D);
    cs_high;
    settle;
    check(cap_n === 3, $sformatf("load 1: %0d writes, want 3", cap_n));
    check_write(0, 16'hA55A, 0, "load 1");
    check_write(1, 16'h1234, 1, "load 1");
    check_write(2, 16'hF00D, 2, "load 1");
    check(words_written === 16'd3, "load 1: words_written");
    check(load_error === 1'b0, "load 1: no error");

    // ================= 2: a new CS low resets the address ===============
    cap_n = 0;
    cs_low;
    spi_word(16'hBEEF);
    cs_high;
    settle;
    check(cap_n === 1, $sformatf("load 2: %0d writes, want 1", cap_n));
    check_write(0, 16'hBEEF, 0, "load 2");
    check(words_written === 16'd1, "load 2: words_written reset");

    // ================= 3: a partial word is discarded and flagged =======
    cap_n = 0;
    cs_low;
    spi_bit(1'b1); spi_bit(1'b0); spi_bit(1'b1);   // 3 bits, then CS high
    cs_high;
    settle;
    check(cap_n === 0, "partial: no write for 3 bits");
    check(load_error === 1'b1, "partial: flagged");

    // ================= 4: a new load clears the sticky error ============
    cap_n = 0;
    cs_low;
    spi_word(16'h5555);
    cs_high;
    settle;
    check(cap_n === 1, "reload: one write");
    check_write(0, 16'h5555, 0, "reload");
    check(load_error === 1'b0, "reload: error cleared by CS low");

    // ================= 5: nothing is written while run == 1 =============
    cap_n = 0;
    run = 1'b1;
    cs_low;
    spi_word(16'hDEAD);
    cs_high;
    settle;
    check(cap_n === 0, "run gate: no write while run=1");
    check(words_written === 16'd0, "run gate: no word counted");
    run = 1'b0;

    // ================= 6: words past WORDS are refused ==================
    cap_n = 0;
    cs_low;
    for (int k = 0; k < WORDS; k++) spi_word(16'h1000 + k[15:0]);
    spi_word(16'hFFFF);                    // one past the end
    cs_high;
    settle;
    check(cap_n === WORDS, $sformatf("oversize: %0d writes, want %0d",
                                     cap_n, WORDS));
    check_write(WORDS-1, 16'h1000 + (WORDS-1)[15:0], WORDS-1, "oversize");
    check(load_error === 1'b1, "oversize: flagged");

    if (errors == 0) $display("PASS: tb_pe_ctrl");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: watchdog — tb_pe_ctrl did not finish");
    $finish;
  end

endmodule
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd sim && iverilog -g2012 -s tb_pe_ctrl -o /tmp/tb_pe_ctrl.vvp ../rtl/pe_ctrl.v ../tb/tb_pe_ctrl.v`
Expected: compile fails with `Unknown module type: pe_ctrl` (or "no such file" for `rtl/pe_ctrl.v`). That is RED.

- [ ] **Step 3: Write the loader**

Create `rtl/pe_ctrl.v` exactly as below.

```verilog
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
  logic [15:0] shreg;
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
          shreg   <= {shreg[14:0], mosi_s1};
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
```

- [ ] **Step 4: Run the unit TB and watch it pass**

Run: `cd sim && iverilog -g2012 -s tb_pe_ctrl -o /tmp/tb_pe_ctrl.vvp ../rtl/pe_ctrl.v ../tb/tb_pe_ctrl.v && vvp /tmp/tb_pe_ctrl.vvp`
Expected: `PASS: tb_pe_ctrl`. On a failure, the message names the write index: a wrong word value is bit order or the 16-bit boundary; a wrong address is the counter/CS-reset; `no write` is the pulse or the CS gate.

- [ ] **Step 5: Integrate the loader into the TT wrapper**

In `rtl/tt_um_protocol_emulator.v`:

(a) header PIN MAP — replace the `ui_in[7:3] unused` block with:

```verilog
//   ui_in[3]    SPI SCLK       (pe_ctrl loader clock; ADR-007)
//   ui_in[4]    SPI MOSI       (loader data, MSB-first)
//   ui_in[5]    SPI CS_N       (active-low loader select)
//   ui_in[7:6]  unused
```

(b) replace the tied-off host interface block:

```verilog
  // ---- firmware load window --------------------------------------------
  // Not brought out to pads in this revision: the SoC boots from whatever the
  // host interface last wrote, and the testbench drives that interface
  // directly. Tying the port off here keeps the pad budget for protocol pins
  // (wiki/reference/protocol-pin-budget.md: 24 usable, and a load port would
  // cost 10 of them). A real bring-up loads over a serial shift path; that is
  // a separate block and a separate decision record.
  wire        host_we       = 1'b0;
  wire        host_imem_sel = 1'b0;
  // Width follows the SoC's loader port, which follows IMEM_WORDS. Written as
  // the same expression the SoC uses so the two cannot drift apart.
  localparam int TT_IMEM_WORDS = 1024;
  wire [((((TT_IMEM_WORDS <= 2) ? 1 : $clog2(TT_IMEM_WORDS)) > 8)
         ? ((TT_IMEM_WORDS <= 2) ? 1 : $clog2(TT_IMEM_WORDS)) : 8)-1:0]
       host_addr = '0;
  wire [15:0] host_wdata    = 16'h0000;
```

with:

```verilog
  // ---- firmware load window: pe_ctrl, the passive SPI slave ------------
  // The host clocks a program into instruction memory before `run` rises.
  // This was tied off until ADR-007; the loader now owns the SoC's host
  // write port. Pads: ui_in[3]=SCLK, ui_in[4]=MOSI, ui_in[5]=CS_N. The
  // protocol bits 0-3, UART/ETH RX and `run` keep their assignments.
  //
  // Width follows the SoC's loader port, which follows IMEM_WORDS. Written as
  // the same expression the SoC uses so the two cannot drift apart.
  localparam int TT_IMEM_WORDS = 1024;

  wire        host_we;
  wire        host_imem_sel;
  wire [((((TT_IMEM_WORDS <= 2) ? 1 : $clog2(TT_IMEM_WORDS)) > 8)
         ? ((TT_IMEM_WORDS <= 2) ? 1 : $clog2(TT_IMEM_WORDS)) : 8)-1:0]
       host_addr;
  wire [15:0] host_wdata;
  wire        ctrl_load_active, ctrl_load_error;
  wire [15:0] ctrl_words_written;

  pe_ctrl #(.WORDS(TT_IMEM_WORDS)) u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .spi_sclk(ui_in[3]), .spi_mosi(ui_in[4]), .spi_cs_n(ui_in[5]),
    .run(run),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .load_active(ctrl_load_active), .load_error(ctrl_load_error),
    .words_written(ctrl_words_written)
  );
```

(c) in the `_unused` sink, replace `ui_in[7:3]` with `ui_in[7:6]` and add the loader's observability outputs:

```verilog
  wire _unused = &{ena, ui_in[7:6], uio_in[7:2],
                   pin_out_bus[7:6], pin_out_bus[3:1],
                   pin_oe_bus[7:6], pin_oe_bus[3:0],
                   dbg_a, dbg_timer[6:0], dbg_pc[7:6],
                   ctrl_load_active, ctrl_load_error, ctrl_words_written, 1'b0};
```

- [ ] **Step 6: Extend the TT TB with a load-through-the-pads phase**

In `tb/tb_tt_um_protocol_emulator.v`:

(a) start with `CS_N` idle high: replace

```verilog
    ena = 1'b1;
    ui_in = 8'h00;
    ui_in[0] = 1'b1;          // UART RX idles high
```

with

```verilog
    ena = 1'b1;
    ui_in = 8'h20;            // CS_N high: the loader is idle
    ui_in[0] = 1'b1;          // UART RX idles high
```

(b) add the load phase between the `PC never advanced` check and the released-pins check, plus the host driver tasks and a TX-toggle monitor near the top of the module:

```verilog
  // ---- pe_ctrl host-side driver (SPI mode 0) ---------------------------
  task automatic spi_bit(input logic b);
    ui_in[4] = b;             // MOSI, held while SCLK is low
    #(100);
    ui_in[3] = 1'b1;          // SCLK rise: the loader samples MOSI here
    #(100);
    ui_in[3] = 1'b0;
  endtask

  task automatic spi_word(input logic [15:0] w);
    for (int k = 15; k >= 0; k--) spi_bit(w[k]);
  endtask

  bit tx_saw_low = 1'b0, tx_saw_high = 1'b0;
  always @(posedge clk) begin
    if (run && uo_out[0] === 1'b0) tx_saw_low  <= 1'b1;
    if (run && tx_saw_low && uo_out[0] === 1'b1) tx_saw_high <= 1'b1;
  end
```

and, in the initial block after the PC check:

```verilog
    // ---- a program loaded through pe_ctrl actually runs ------------------
    // Hold the core, clock five words through the loader pads, release it,
    // and watch the program toggle TX. The words are hand-assembled:
    //   LDI A,1 / OUT 1,A / LDI A,0 / OUT 1,A / JMP 0
    ui_in[1] = 1'b0;          // run low: the loader may write
    #1;
    repeat (4) @(posedge clk); #1;
    ui_in[5] = 1'b0;          // CS_N low: a new load at word 0
    #(200);
    spi_word(16'h0001);
    spi_word(16'h1001);
    spi_word(16'h0000);
    spi_word(16'h1000);
    spi_word(16'h4000);
    ui_in[5] = 1'b1;          // CS_N high: load done
    #(200);
    check(dut.u_ctrl.load_error === 1'b0, "loader flagged an error on a clean load");
    ui_in[1] = 1'b1;          // run the loaded program
    #1;
    repeat (200) @(posedge clk); #1;
    check(tx_saw_low && tx_saw_high,
          "the program loaded through the pads did not toggle TX");
```

- [ ] **Step 7: Wire the new sources into every runner**

(a) `regress/run_all.sh`, in `CASES`, after the `tb_pe_soc_eth` entry:

```bash
  # The passive SPI loader: pads in, host write port out. Unit TB first; the
  # TT top-level TB then proves a program loaded through the pads executes.
  "tb_pe_ctrl|../rtl/pe_ctrl.v|tb_pe_ctrl"
```

and append `../rtl/pe_ctrl.v` to the `tb_tt_um_protocol_emulator` case.

(b) `regress/lint.sh`: add `rtl/pe_ctrl.v` to `RTL_ALL` and `pe_ctrl` to both `for top in ...` lists.

(c) `regress/synth_area.sh`: add `report pe_ctrl "rtl/pe_ctrl.v" pe_ctrl` after the `pe_pinmux` report, and append `rtl/pe_ctrl.v` to the `tt_um_top` source list.

(d) `info.yaml`: add `"rtl/pe_ctrl.v"` to `source_files`, and set `ui[3]`/`ui[4]`/`ui[5]` to `"SPI SCLK (pe_ctrl loader)"` / `"SPI MOSI (pe_ctrl loader)"` / `"SPI CS_N (pe_ctrl loader, active low)"`.

- [ ] **Step 8: Teach the block-diagram generator about the loader**

In `tools/gen/block_diagram.py`:

(a) add a `pe_ctrl` entry to `BLOCKS` (before `pe_serdes`):

```python
    dict(
        name="pe_ctrl",
        source_file="pe_ctrl.v",
        role="passive SPI load path: host clocks words into imem",
        instantiated_in="tt_um_protocol_emulator.v",
        tb="tb_pe_ctrl.v",
    ),
```

(b) delete the `("pe_ctrl (SPI load path)", ...)` tuple from `PLANNED` and its adjacent `# Removed as BUILT` comment line if it names pe_ctrl.

(c) in the hand-written mermaid: update the `HOST` node label and add the loader between host and instruction memory:

```
        HOST["SPI host<br/><i>loads imem through pe_ctrl</i>"]
```
and inside the `TT` subgraph, after the `SOC` subgraph closes:

```
        CTRL["<b>pe_ctrl</b><br/>passive SPI load"]
```

with edges:

```
    HOST -->|"SCLK/MOSI/CS_N"| CTRL
    CTRL -->|"host write port"| IMEM
```

replacing the old `HOST -.->|"imem/dmem write port"| IMEM` edge, and add `CTRL` to the built class list.

- [ ] **Step 9: Refresh cell counts and regenerate the gated docs**

Run: `./regress/synth_area.sh | awk 'NF>=3 && $2 ~ /^[0-9]+$/ {print $1, $2}' > wiki/reference/.block-diagram-cells`
Then: `python3 tools/gen/block_diagram.py && python3 tools/gen/signal_glossary.py`
If `npx` is available: `python3 tools/gen/render_block_diagram.py`
Expected: every command exits 0; the diagram shows `pe_ctrl` as built and the orphan list shrinks to `pe_serdes`/`pe_codec_mux`.

- [ ] **Step 10: Run the task's verification**

Run: `./regress/run_all.sh --fast -j8`
Expected: `TOTAL: 28   PASS: 28   FAIL: 0`, `FIRMWARE: 19 PASS: 19`, `lint clean` (15 verilator tops / 12 yosys elaborations), five existing mutation suites + all doc gates green.

- [ ] **Step 11: Commit**

```bash
git add rtl/pe_ctrl.v tb/tb_pe_ctrl.v rtl/tt_um_protocol_emulator.v \
        tb/tb_tt_um_protocol_emulator.v regress/run_all.sh regress/lint.sh \
        regress/synth_area.sh info.yaml tools/gen/block_diagram.py \
        wiki/reference/block-diagram.md wiki/reference/.block-diagram-cells \
        wiki/reference/signal-names.md diagrams/block-diagram.stamp
git commit -m "pe_ctrl: a host can clock a program into imem through the pads"
```

---

### Task 2: Mutation-test `tb_pe_ctrl.v`

**Files:**
- Create: `regress/mutate_ctrl_tb.sh`
- Modify: `regress/run_all.sh` (register the sixth suite)

**Interfaces:**
- Consumes: `tb_pe_ctrl.v` and the `pe_ctrl` lines it checks (Task 1).
- Produces: a sixth mutation suite.

- [ ] **Step 1: Write the harness**

Create `regress/mutate_ctrl_tb.sh`:

```bash
#!/usr/bin/env bash
# mutate_ctrl_tb.sh — mutation-test tb_pe_ctrl.v.
#
# The loader is the only way a program reaches silicon, so every claim its TB
# makes must be able to fail. Each mutation is a plausible implementation
# choice in pe_ctrl.v; the TB must notice every one.
#
# RESTORE IS A FILE COPY, verified after every mutation — a failed restore
# stacks mutations and reports a meaningless perfect score (the eth_mac
# harness lesson).
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
RTL="$ROOT/rtl/pe_ctrl.v"
TB="$ROOT/tb/tb_pe_ctrl.v"
SRCS="../rtl/pe_ctrl.v $TB"
LOG=/tmp/mutate_ctrl.log
BAK=$(mktemp /tmp/pe_ctrl.XXXXXX.v)

cleanup() { cp "$BAK" "$RTL" 2>/dev/null; rm -f "$BAK"; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"
cp "$RTL" "$BAK"
cmp -s "$RTL" "$BAK" || { echo "FATAL: could not snapshot $RTL"; exit 2; }

pass=0; fail=0; survived=0

run_tb() {
  iverilog -g2012 -s tb_pe_ctrl -o /tmp/mut_ctrl.vvp $SRCS >/tmp/mut_ctrl_cc.log 2>&1 || return 2
  timeout 120 vvp /tmp/mut_ctrl.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

restore() { cp "$BAK" "$RTL"; }
verify_restore() {
  cmp -s "$BAK" "$RTL" || { echo "  FATAL: $RTL does not match the snapshot after restore."; exit 3; }
}

mutate() {
  python3 - "$RTL" "$1" "$2" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
if sys.argv[2] not in t: sys.exit(4)
p.write_text(t.replace(sys.argv[2], sys.argv[3], 1))
PYEOF
}

check_mutation() {
  local name="$1"; shift
  if ! mutate "$1" "$2"; then
    echo "  [$name] HARNESS ERROR: anchor not found"; restore; fail=$((fail+1)); return
  fi
  run_tb
  local rc=$?
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected"; pass=$((pass+1))
  else                     fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing tb_pe_ctrl ==="
run_tb
if [ $? -ne 0 ]; then echo "  FATAL: the TB does not pass on the clean design"; exit 2; fi
echo "  [baseline] passes on the unmutated design"

# 1. Bit order: shift the other way (LSB-first). The TB's 0xA55A catches it.
check_mutation "lsb-first" \
  "          word_data  <= {shreg[14:0], mosi_s1};" \
  "          word_data  <= {mosi_s1, shreg[15:1]};   // MUTANT: LSB-first"

# 2. Word boundary: 15 bits per word instead of 16.
check_mutation "short-word" \
  "        if (bit_cnt == 4'd15) begin" \
  "        if (bit_cnt == 4'd14) begin   // MUTANT: 15-bit words"

# 3. The CS reset: a second load continues where the last one stopped.
check_mutation "no-cs-reset" \
  "        addr          <= '0;
        bit_cnt       <= '0;
        shreg         <= '0;
        word_ready    <= 1'b0;
        words_written <= '0;" \
  "        bit_cnt       <= '0;
        shreg         <= '0;
        word_ready    <= 1'b0;   // MUTANT: address and count survive a reload"

# 4. The run gate: writes are accepted while the core executes.
check_mutation "run-gate" \
  "      if (sclk_rise && !run && !cs_s1 && !word_ready && !load_error) begin" \
  "      if (sclk_rise && !cs_s1 && !word_ready && !load_error) begin   // MUTANT: no run gate"

# 5. Address increment: every word lands on word 0.
check_mutation "stuck-address" \
  "            addr   <= addr + 1'b1;" \
  "            addr   <= addr;   // MUTANT: address never advances"

# 6. The write pulse: completed words are never handed to the SoC.
check_mutation "no-write-pulse" \
  "        W_PULSE: begin
          we_r   <= 1'b1;
          wstate <= W_DONE;
        end" \
  "        W_PULSE: begin
          we_r   <= 1'b0;   // MUTANT: no host write
          wstate <= W_DONE;
        end"

# 7. The partial-word flag: a load ending mid-word is silently discarded.
check_mutation "partial-word-flag" \
  "        if (bit_cnt != 4'd0) load_error <= 1'b1;" \
  "        ;   // MUTANT: partial word not flagged"

# 8. The oversize guard: a long load wraps over word 0.
check_mutation "wraparound" \
  "          if (addr == AW'(WORDS - 1)) begin
            load_error <= 1'b1;      // more words than instruction memory
            wstate     <= W_IDLE;
          end else begin
            addr   <= addr + 1'b1;
            wstate <= W_IDLE;
          end" \
  "          addr   <= addr + 1'b1;
          wstate <= W_IDLE;   // MUTANT: wraps over word 0"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
[ $survived -gt 0 ] && { echo "SURVIVORS: the TB does not test what it claims."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every mutation is detected by tb_pe_ctrl."
exit 0
```

- [ ] **Step 2: Make it executable and run it**

Run: `chmod +x regress/mutate_ctrl_tb.sh && ./regress/mutate_ctrl_tb.sh`
Expected: `8 detected, 0 survived, 0 harness errors`, exit 0. A survivor means the TB needs the missing check; an anchor error means the RTL text drifted.

- [ ] **Step 3: Register the suite**

In `regress/run_all.sh`, after the `eth_soc` mutation block:

```bash
# The loader is how a program reaches silicon; its TB gets the same gate.
if ./regress/mutate_ctrl_tb.sh > /tmp/mutate_ctrl.log 2>&1; then
  echo "ctrl TB mutations: OK (no unexplained survivors)"
else
  echo "ctrl TB mutations: FAILED"
  tail -20 /tmp/mutate_ctrl.log
  stale=1
fi
```

- [ ] **Step 4: Run the task's verification**

Run: `./regress/run_all.sh --fast -j8`
Expected: all green, including `ctrl TB mutations: OK`.

- [ ] **Step 5: Commit**

```bash
git add regress/mutate_ctrl_tb.sh regress/run_all.sh
git commit -m "regress: mutation-test the passive SPI loader testbench"
```

---

### Task 3: Wiki record + full regression

**Files:**
- Modify: `wiki/STATUS.md` (item 2 → DONE; table row; counts; tree)
- Modify: `wiki/log.md`
- Modify: `HANDOFF.md` (resume text: the loader exists)
- Possibly regenerate: nothing new (Task 1 already did the generated pages)

**Interfaces:**
- Consumes: the verified Task 1/2 state and the regression counts.
- Produces: the resume-here record, true.

- [ ] **Step 1: Update `wiki/STATUS.md`**

- Turn "### 2. `pe_ctrl` — the SPI load path" into `### 2. pe_ctrl — the SPI load path — DONE 2026-09-23`, with: the loader is `rtl/pe_ctrl.v` in the wrapper, pads `ui_in[3:5]`, protocol summary, `run` remains the strap, `tb_pe_ctrl` + `tb_tt_um_protocol_emulator`'s load phase + `regress/mutate_ctrl_tb.sh` (8/8).
- Add a `pe_ctrl` row to the "What is built and verified" table (cells from the Task 1 synth_area output; note the wrapper's row count changes).
- Add `pe_ctrl` to the one-line tree; update regression counts to the Task 3 run's real numbers (expect RTL 28/28, firmware 19/19, six mutation suites).
- The orphan list stays `pe_serdes` / `pe_codec_mux`.

- [ ] **Step 2: Update the other records**

- `HANDOFF.md` "Current work list": the loader now exists; the remaining top item is the I2C transaction layer, then the `uo_out[7:2]` reclaim.
- `wiki/log.md`: append a dated entry (change, files, regression result, traps).

- [ ] **Step 3: Run the full regression one last time**

Run: `./regress/run_all.sh --fast -j8`
Expected: all green; use its counts in Step 1.

- [ ] **Step 4: Commit**

```bash
git add wiki/STATUS.md wiki/log.md HANDOFF.md
git commit -m "Docs: the passive SPI loader is built; STATUS next-steps item 2 closed"
```

---

## Self-Review

**1. Spec coverage.** ADR-007 asks for: a passive SPI slave (Task 1 Steps 3/5), hardware not firmware (Step 3), wrapper placement (Step 5), the v1 wire contract — mode 0, MSB-first, 16-bit, CS framing, run gate, ≤10 MHz, imem only (Step 3 + TB Steps 1/4), pads `ui_in[3:5]` (Step 5 + `info.yaml` Step 7). STATUS item 2's "the one blocking a real chip from booting" is answered by the TT-level load proof (Step 6) and the mutation gate (Task 2).

**2. Placeholder scan.** Every code step carries the actual code; the only non-exact text is the STATUS prose in Task 3, which depends on measured numbers the regression prints.

**3. Type consistency.** `pe_ctrl`'s `host_addr` width expression is copied from `pe_soc`'s port so the two cannot drift; `AW'(WORDS-1)` matches the counter width; the wrapper instantiates with `.WORDS(TT_IMEM_WORDS)`; `tb_pe_ctrl` uses `WORDS=16` and the clamped 8-bit address; `load_error`/`words_written` names are consistent across RTL, TB, wrapper and mutations.

**4. Review Focus.** Item 1 → TB case 2 + `no-cs-reset`; item 2 → TB case 5 + `run-gate`; item 3 → TB case 3 + `partial-word-flag`; item 4 → TB case 6 + `wraparound`; item 5 → the 5 MHz TB is already 6 clk per half period; the synchronizer is a level detector with no minimum-frequency assumption, and the unit TB can be slowed by changing `HALF_NS`.
