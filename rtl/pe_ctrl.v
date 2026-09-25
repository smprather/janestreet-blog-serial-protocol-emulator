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
  parameter int WORDS = 1024
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
  output logic [15:0] faults
);

  localparam int IAW = (WORDS <= 2) ? 1 : $clog2(WORDS);
  localparam int AW  = (IAW > 8) ? IAW : 8;   // matches pe_soc's host_addr

  // ---- frame constants ---------------------------------------------------
  localparam logic [15:0] SYNC      = 16'hA55A;
  localparam logic [3:0]  VERSION   = 4'h1;
  localparam logic [7:0]  OP_PING   = 8'h01;
  localparam logic [7:0]  OP_LOAD   = 8'h10;
  localparam logic [7:0]  OP_STATUS = 8'h11;
  localparam logic [7:0]  OP_CLRFLT = 8'h16;
  localparam logic [7:0]  OP_TARGET = 8'h20;
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
  logic [15:0] crc_acc;
  logic        frm_hdr_bad, frm_len_bad;
  logic        frm_not_ready, frm_aborted, frm_range;
  logic [15:0] pay0;
  logic        pay0_valid;
  logic [15:0] load_idx;        // payload words offered to this LOAD

  // ---- response ---------------------------------------------------------
  logic        resp_active, resp_hold_oe;
  logic [4:0]  resp_idx;
  logic [3:0]  resp_bitpos;
  logic [7:0]  resp_op;
  logic [3:0]  resp_tgt;
  logic [15:0] resp_seq, resp_len, resp_crc;
  logic [15:0] resp_buf [0:7];
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
  assign miso_oe     = resp_active | resp_hold_oe;

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
          // A fixed 3-bit index per payload slot, not the 5-bit dynamic
          // `resp_idx - 4` expression Verilator flagged (WIDTHTRUNC: an
          // 8-entry array indexed by 5 bits). resp_len never exceeds 6 (the
          // longest response is STATUS's 6 payload words), so the payload
          // slots are exactly indices 4..9 -> resp_buf[0..5] and this case
          // is exhaustive for every implemented response. Bit-identical to
          // the dynamic index on that range.
          case (resp_idx)
            5'd4:    resp_w = resp_buf[0];
            5'd5:    resp_w = resp_buf[1];
            5'd6:    resp_w = resp_buf[2];
            5'd7:    resp_w = resp_buf[3];
            5'd8:    resp_w = resp_buf[4];
            5'd9:    resp_w = resp_buf[5];
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
      resp_active   <= 1'b0; resp_hold_oe <= 1'b0; resp_idx <= '0;
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
      for (int i = 0; i < 8; i++) resp_buf[i] <= '0;
    end else begin
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
                OP_CLRFLT, OP_TARGET:
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
              end else if (frm_op == OP_CLRFLT || frm_op == OP_TARGET) begin
                if (!pay0_valid) begin
                  pay0       <= rx_word;
                  pay0_valid <= 1'b1;
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
                    resp_len    <= 16'd6;
                    resp_buf[0] <= ST_OK;
                    resp_buf[1] <= {15'b0, run};             // state
                    resp_buf[2] <= {15'b0, run};             // run
                    resp_buf[3] <= selected_target;
                    resp_buf[4] <= faults;                   // sticky bits
                    resp_buf[5] <= words_written;
                    // R2 inserts pc/a/x/y/timer before the faults word.
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
                  default: begin
                    resp_len    <= 16'd1;
                    resp_buf[0] <= ST_UNSUP;
                  end
                endcase
              end

              // ---- start the response serializer --------------------------
              resp_idx    <= '0;
              resp_bitpos <= '0;
              resp_crc    <= 16'hFFFF;
              resp_active <= 1'b1;
              rx_state    <= S_SYNC;
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

      // ---- response serializer (mode 0: changes on the detected fall) -----
      if (sclk_fall && !cs_s1) begin
        if (resp_active) begin
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

endmodule
