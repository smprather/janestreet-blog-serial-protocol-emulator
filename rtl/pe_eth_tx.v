// pe_eth_tx.v — 10BASE-T TX frame engine (wiki/plans/eth-tx-frame-path.md).
// Signal meanings: wiki/reference/signal-names.md#pe_eth_tx
//
// WHAT IT IS. Firmware pushes the frame's header and payload bytes into an
// 8-byte staging FIFO and writes the stored length; this block owns everything
// else on the wire: the 56-bit preamble, the SFD, the octets LSB-first, zero
// padding to the 64-byte minimum, the 32-bit FCS, and the 96-bit-time
// inter-frame gap. That division of labour is the project thesis: firmware
// sequences frames, hardware does bits (wiki/concepts/ethernet-scope.md).
//
// THE FRAME, IN WIRE ORDER (stored_bytes = the FIFO-supplied header+payload)
//
//   56 bits  1,0,1,0,... starting with 1   wire pattern, NOT byte 0xAA
//    8 bits  0xD5 LSB-first = 1,0,1,0,1,0,1,1
//   8*N     the stored bytes, each octet LSB-first
//   8*(60-N) zero bits when N < 60         802.3's 64-byte minimum
//   32      FCS field, crc_bit = R[0]^1, one per cell
//   >= 96   idle cells before the next preamble
//
// THE PREAMBLE IS A WIRE PATTERN, NOT A BYTE. Sending 0xAA through an LSB-first
// byte helper emits 0,1,0,1,... -- the inverted phase, whose junction with the
// SFD creates a false 0xD5 window seven bits early. tb_pe_eth_mac documents
// that trap; this block emits the pattern directly and never touches a byte
// helper for the prelude or the FCS.
//
// THE IDLE TRAP. pe_manch's TX is combinational: tx_wire = half_phase ? raw
// : ~raw. A CONSTANT raw under a toggling half_phase is a 10 MHz square wave,
// not an idle line. So whenever the FSM is not mid-frame it drives
// tx_bit = half_phase, which makes tx_wire a constant high level -- 10BASE-T
// idle. An engine that merely "stops driving" fails this and the unit TB
// checks the wire for mid-cell transitions.
//
// THE FCS FIELD-MODE TRAP. pe_crc emits `R[0] ^ cfg_out_inv` and must shift
// PURE (feedback from R[0], not from crc_bit) while `crc_field` is high, so
// the register drains to zero and a receiver folding the same bits agrees.
// The emitted wire bits are IDENTICAL whether the final complement sits on
// the wire or inside the feedback; only the register's end state differs.
// That is why the unit TB checks `dut.u_tx_crc.crc_state == 0` after the
// field, not just the 32 decoded bits. The constants are the generated
// RevEng-checked ones (wiki/reference/crc-config.md): poly_r 0xEDB88320,
// seed 0xFFFFFFFF, out_inv 1.
//
// THE PAD IS DATA. Pad zero bits are folded into the FCS and count toward the
// 64-byte minimum. The receiver folds the pad the same way, so a transmitter
// that skips the fold still looks fine to a byte compare and fails only the
// residue.
//
// RUNT / JABBER POLICY. A start with stored_bytes < 14 or > MAX_STORED is
// REFUSED: the engine stays IDLE and pulses tx_overlong (one pulse; the SoC
// latches it set-beats-clear). A start while busy is refused silently -- the
// caller already sees tx_busy. Stored bytes 14..59 are legal and padded to 60.
//
// THE FIFO AND ITS DEADLINE. The staging FIFO is 8 bytes of flops; firmware
// pushes the first bytes, starts the frame, and keeps pushing with push_ready
// as backpressure. At 100 ns/bit the FIFO buys 8 bytes x 8 bits x 100 ns =
// 6.4 us of CPU latency. If DATA runs out of bytes, that is an UNDERrun:
// tx_underrun pulses and the truncated frame is abandoned to IDLE -- never a
// silent gap in the cell cadence. The push wrap (the SoC's window) must stay
// inside its bank; this module just sees push/push_ready.
//
// GRID ALIGNMENT AND THE WAVEFORM. A start is latched and applied at the next
// cell_start strobe, so the first preamble bit occupies a full 6-clock cell
// at the locked 60 MHz operating point (DIV=6, 100 ns/cell). The same rule
// keeps a start issued during the IFG from shortening the gap: it waits for
// IDLE. cell_start fires on the cell's LAST clock, so `tx_bit` changes on the
// cell boundary together with the codec's half_phase toggle. That matters:
// advancing on the shared codec's registered committing edge (cell_en, one
// clock into the cell) leaves the first clock of every first half showing the
// PREVIOUS bit, and the DRU cannot frame that from a constant idle -- the
// Task-5 wire loopback caught exactly that. With the boundary-aligned advance
// each half is exactly three clocks, textbook Manchester.
//
// ABORT returns to IDLE at the next cell_start, after the current cell. It does
// NOT pulse tx_done and does NOT run an IFG (the plan's Step 3 contract): a
// caller that starts again immediately after an abort owns that choice.

module pe_eth_tx #(
  parameter int MAX_STORED = 1514
) (
  input  logic        clk, rst_n,

  input  logic        enable,        // tx_path: owns the shared TX codec
  input  logic        cell_start,    // advance strobe on the cell boundary (DIV=6)
  input  logic        half_phase,    // Manchester half-cell level

  // frame source: staging FIFO write side, fed by the SoC's 0xF window
  input  logic        push,
  input  logic [7:0]  push_byte,
  output logic        push_ready,
  input  logic [11:0] frame_len,     // stored bytes, 14..MAX_STORED

  input  logic        start,
  input  logic        frame_abort,   // 'abort' is a C++ reserved word (SYMRSVDWORD)

  // status
  output logic        tx_busy,       // high from preamble through IFG
  output logic        tx_done,       // one pulse at the end of the FCS
  output logic        tx_underrun,   // one pulse: DATA ran out of bytes
  output logic        tx_overlong,   // one pulse: start refused (runt/jabber)
  output logic        ifg_active,    // state == IFG (busy, but no frame on wire)

  // raw bit into u_tx_codec (Manchester, cfg = 0x04)
  output logic        tx_bit
);

  // ---- state and counters ------------------------------------------------
  localparam logic [2:0] S_IDLE     = 3'd0,
                         S_PREAMBLE = 3'd1,
                         S_DATA     = 3'd2,
                         S_PAD      = 3'd3,
                         S_FCS      = 3'd4,
                         S_IFG      = 3'd5;

  logic [2:0]  state;
  logic [5:0]  pre_cnt;          // 0..63 within PREAMBLE
  logic [2:0]  bit_idx;          // current bit within the DATA byte
  logic [14:0] data_bits_left;   // frame_len * 8, counted down per cell
  logic [9:0]  pad_bits_left;    // (60 - frame_len) * 8
  logic [5:0]  fcs_left;         // 32 field cells
  logic [6:0]  ifg_cnt;          // 0..95 (96 idle cells)
  logic [11:0] stored_bytes;     // frame_len snapshot at start

  logic        tx_reg;           // raw bit for the current cell (non-FCS)
  logic        start_pend;
  logic        abort_pend;

  // ---- staging FIFO (8 bytes) -------------------------------------------
  localparam int FDEPTH = 8;
  logic [7:0] fifo_mem [0:FDEPTH-1];
  logic [2:0] fifo_wp, fifo_rp;
  logic [3:0] fifo_cnt;
  wire  [7:0] fifo_head  = fifo_mem[fifo_rp];
  wire  [7:0] fifo_after = fifo_mem[fifo_rp + 3'd1];   // wraps mod 8

  assign push_ready = (fifo_cnt != 4'd8);

  // ---- the TX-dedicated CRC ---------------------------------------------
  // A second instance, not a share of pe_eth_mac's: TX and RX are independent
  // directions, and time-sharing one LFSR would let a transmit corrupt an
  // in-flight receive. Constants from wiki/reference/crc-config.md.
  logic        crc_bit, crc_zero;
  logic [31:0] crc_state;
  logic        crc_clr;
  wire  crc_bit_en = cell_start && (state == S_DATA || state == S_PAD
                                 || state == S_FCS);
  wire  crc_field  = (state == S_FCS);
  wire  crc_bit_in = (state == S_FCS) ? crc_bit : tx_reg;

  pe_crc #(.W(32)) u_tx_crc (
    .clk(clk), .rst_n(rst_n),
    .bit_en(crc_bit_en), .clr(crc_clr),
    .crc_field(crc_field), .bit_in(crc_bit_in),
    .cfg_poly_r(32'hEDB88320),     // rev(0x04C11DB7, 32)
    .cfg_seed(32'hFFFFFFFF),
    .cfg_out_inv(1'b1),            // Ethernet's xorout is all ones
    .crc_bit(crc_bit), .crc_zero(crc_zero), .crc_state(crc_state)
  );

  wire _unused = &{1'b0, crc_zero, crc_state, fifo_after[7:1]};

  // ---- status and the wire bit ------------------------------------------
  assign tx_busy    = (state != S_IDLE);
  assign ifg_active = (state == S_IFG);

  // Mid-frame the wire bit is the registered data bit (or the CRC field bit);
  // everywhere else it tracks half_phase, which turns the Manchester encoder's
  // square wave into a constant idle level (see the header's idle trap).
  always_comb begin
    case (state)
      S_FCS:                   tx_bit = crc_bit;
      S_PREAMBLE, S_DATA, S_PAD: tx_bit = tx_reg;
      default:                 tx_bit = half_phase;
    endcase
  end

  // 64-bit prelude: 56 alternating bits starting with 1, then 1,0,1,0,1,0,1,1.
  // n == 63 is the SFD's last bit (the only place the alternation breaks).
  // yosys 0.69+post cannot parse `return` in a function (the R1 pe_ctrl
  // lesson), so this uses the old-style function-name assignment.
  function automatic logic pre_bit(input logic [5:0] n);
    pre_bit = (n == 6'd63) ? 1'b1 : ~n[0];
  endfunction

  wire len_ok = (frame_len >= 12'd14) && (frame_len <= 12'(MAX_STORED));

  // ---- the FSM and both FIFO ports --------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= S_IDLE;
      pre_cnt        <= 6'd0;
      bit_idx        <= 3'd0;
      data_bits_left <= 15'd0;
      pad_bits_left  <= 10'd0;
      fcs_left       <= 6'd0;
      ifg_cnt        <= 7'd0;
      stored_bytes   <= 12'd0;
      tx_reg         <= 1'b0;
      start_pend     <= 1'b0;
      abort_pend     <= 1'b0;
      fifo_wp        <= 3'd0;
      fifo_rp        <= 3'd0;
      fifo_cnt       <= 4'd0;
      for (int i = 0; i < FDEPTH; i++) fifo_mem[i] <= 8'h00;
      tx_done        <= 1'b0;
      tx_underrun    <= 1'b0;
      tx_overlong    <= 1'b0;
      crc_clr        <= 1'b0;
    end else begin
      // status pulses are one cycle wide unless set below
      tx_done     <= 1'b0;
      tx_underrun <= 1'b0;
      tx_overlong <= 1'b0;
      crc_clr     <= 1'b0;

      // ---- FIFO write side ----
      if (push && push_ready) begin
        fifo_mem[fifo_wp] <= push_byte;
        fifo_wp           <= fifo_wp + 3'd1;
        fifo_cnt          <= fifo_cnt + 4'd1;
      end

      // ---- control strobes (independent of the cell cadence) ----
      if (start) begin
        if (!enable) begin
          // not our path: the owner mux still selects the SERDES
        end else if (state != S_IDLE) begin
          // refused: busy. tx_busy already tells the caller.
        end else if (start_pend) begin
          // already queued for the next cell boundary
        end else if (!len_ok) begin
          tx_overlong <= 1'b1;           // runt (<14) or jabber (>MAX_STORED)
        end else begin
          start_pend <= 1'b1;
        end
      end

      if (frame_abort) begin
        start_pend <= 1'b0;
        if (state != S_IDLE) abort_pend <= 1'b1;
      end

      if (!enable) begin
        // Losing the path mid-frame abandons the frame without a fault: the
        // SoC refuses to clear tx_path while tx_busy, so this is a guard.
        state      <= S_IDLE;
        start_pend <= 1'b0;
        abort_pend <= 1'b0;
      end else if (cell_start) begin
        if (abort_pend) begin
          abort_pend <= 1'b0;
          state      <= S_IDLE;
        end else begin
          case (state)
            // ---- IDLE: wait for a start, applied on a cell boundary ----
            S_IDLE: begin
              if (start_pend) begin
                start_pend     <= 1'b0;
                state          <= S_PREAMBLE;
                tx_reg         <= pre_bit(6'd0);     // 1
                pre_cnt        <= 6'd0;
                stored_bytes   <= frame_len;         // snapshot the length
                data_bits_left <= {frame_len, 3'b000};
                crc_clr        <= 1'b1;              // prelude never folds
              end
            end

            // ---- PREAMBLE: 56 alternating bits + the SFD ----
            S_PREAMBLE: begin
              if (pre_cnt == 6'd63) begin
                if (fifo_cnt == 4'd0) begin
                  tx_underrun <= 1'b1;               // no header byte
                  state       <= S_IDLE;
                end else begin
                  state   <= S_DATA;
                  tx_reg  <= fifo_head[3'd0];
                  bit_idx <= 3'd0;
                end
              end else begin
                pre_cnt <= pre_cnt + 6'd1;
                tx_reg  <= pre_bit(pre_cnt + 6'd1);
              end
            end

            // ---- DATA: stored bytes LSB-first, every bit folded ----
            S_DATA: begin
              if (data_bits_left == 15'd1) begin
                // last stored bit: pop its byte and leave DATA
                fifo_rp        <= fifo_rp + 3'd1;
                fifo_cnt       <= fifo_cnt - 4'd1;
                bit_idx        <= 3'd0;
                data_bits_left <= 15'd0;
                if (stored_bytes < 12'd60) begin
                  state          <= S_PAD;
                  tx_reg         <= 1'b0;
                  pad_bits_left  <= (10'd60 - stored_bytes[9:0]) << 3;
                end else begin
                  state    <= S_FCS;
                  fcs_left <= 6'd32;
                end
              end else begin
                data_bits_left <= data_bits_left - 15'd1;
                if (bit_idx == 3'd7) begin
                  // byte boundary: pop the finished byte and check for the
                  // next one. fifo_cnt includes the byte just finished, so
                  // >= 2 means a successor exists.
                  fifo_rp  <= fifo_rp + 3'd1;
                  fifo_cnt <= fifo_cnt - 4'd1;
                  bit_idx  <= 3'd0;
                  if (fifo_cnt <= 4'd1) begin
                    tx_underrun <= 1'b1;             // never a silent gap
                    state       <= S_IDLE;
                  end else begin
                    tx_reg <= fifo_after[3'd0];
                  end
                end else begin
                  bit_idx <= bit_idx + 3'd1;
                  tx_reg  <= fifo_head[bit_idx + 3'd1];
                end
              end
            end

            // ---- PAD: zero bits to the 64-byte minimum, folded ----
            S_PAD: begin
              tx_reg <= 1'b0;
              if (pad_bits_left == 10'd1) begin
                state    <= S_FCS;
                fcs_left <= 6'd32;
              end else begin
                pad_bits_left <= pad_bits_left - 10'd1;
              end
            end

            // ---- FCS: 32 pure-shift field cells ----
            S_FCS: begin
              if (fcs_left == 6'd1) begin
                state   <= S_IFG;
                ifg_cnt <= 7'd0;
                tx_done <= 1'b1;
              end else begin
                fcs_left <= fcs_left - 6'd1;
              end
            end

            // ---- IFG: 96 idle cells before the next preamble ----
            S_IFG: begin
              if (ifg_cnt == 7'd95) state <= S_IDLE;
              else                  ifg_cnt <= ifg_cnt + 7'd1;
            end

            default: state <= S_IDLE;
          endcase
        end
      end
    end
  end

endmodule
