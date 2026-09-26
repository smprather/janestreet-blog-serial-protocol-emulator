#!/usr/bin/env bash
# mutate_ctrl_tb.sh — mutation-test the R1 framed host bus.
#
# Every claim tb_pe_ctrl (and the pad-level tb_tt_um_protocol_emulator) makes
# must be able to fail. Each mutation below is a plausible implementation
# choice in rtl/pe_ctrl.v (or in the wrapper's pad wiring); the matching TB
# must notice every one. Contract: wiki/plans/host-controller-gui.md,
# "PE host protocol", phase R1, phased per
# reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md.
#
# RESTORE IS A FILE COPY, verified with cmp after EVERY mutation — a failed
# restore stacks mutations and reports a meaningless perfect score (the
# eth_mac lesson).
#
# The A1-echo semantics are covered through the framed LOAD response:
#   * echo-at-queue   — the echo latches when a word is queued, so a run-
#                       aborted word reaches the response echo (commit-latched
#                       is the rule).
#
# ONE EQUIVALENT MUTATION IS DELIBERATELY ABSENT. Removing the LOAD-header
# `addr <= 0` alone is not observable: `cs_fall` resets the address as well, so
# the two resets are defence in depth and either one keeps every LOAD starting
# at word 0. The TB's address checks (including the bring-up defect this task
# fixed) fail only if both are broken.
set -u
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
RTL="$ROOT/rtl/pe_ctrl.v"
WRTL="$ROOT/rtl/tt_um_protocol_emulator.v"
# MUTABLE — what this harness EDITS inside the repo. Read by
# regress/verify_merge.sh (the merge gate) to decide whether a narrowed gate
# has to run this suite, and by regress/check_mutation_lists.sh to prove the
# list still covers every file the harness writes. Evidence: RTL= and WRTL=, each backed up and restored.
# An EMPTY value means this suite mutates nothing in the repo and is therefore
# NEVER SKIPPED. A MISSING line is the opposite: unmappable, and the gate
# escalates to running every suite rather than guessing.
MUTABLE="rtl/pe_ctrl.v rtl/tt_um_protocol_emulator.v"
TB="$ROOT/tb/tb_pe_ctrl.v"
SRCS="../rtl/pe_ctrl.v $TB"
WTB_SRCS="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v ../rtl/pe_ctrl.v ../rtl/tt_um_protocol_emulator.v"
LOG=/tmp/mutate_ctrl.log
WTB_LOG=/tmp/mutate_ctrl_tt.log
BAK=$(mktemp /tmp/pe_ctrl.XXXXXX.v)
WBAK=$(mktemp /tmp/tt_um.XXXXXX.v)

cleanup() { cp "$BAK" "$RTL" 2>/dev/null; cp "$WBAK" "$WRTL" 2>/dev/null; rm -f "$BAK" "$WBAK"; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"
cp "$RTL" "$BAK"
cmp -s "$RTL" "$BAK" || { echo "FATAL: could not snapshot $RTL"; exit 2; }
cp "$WRTL" "$WBAK"
cmp -s "$WRTL" "$WBAK" || { echo "FATAL: could not snapshot $WRTL"; exit 2; }

# The pad-level TB loads firmware/spi_xfer.hex; run_all builds it first, but a
# standalone harness run must not silently test a stale or missing image.
if [ ! -f "$ROOT/firmware/spi_xfer.hex" ]; then
  echo "  firmware images missing: building them first"
  ( cd "$ROOT" && ./regress/run_firmware_tests.sh >/tmp/mut_ctrl_fw.log 2>&1 ) \
    || { echo "FATAL: could not build the firmware images"; exit 2; }
fi

pass=0; fail=0; survived=0

run_tb() {
  iverilog -g2012 -s tb_pe_ctrl -o /tmp/mut_ctrl.vvp $SRCS >/tmp/mut_ctrl_cc.log 2>&1 || return 2
  timeout 120 vvp /tmp/mut_ctrl.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

run_wrapper_tb() {
  local sram
  sram=$(bash "$ROOT/regress/sram_model.sh" 2>/dev/null) || return 2
  iverilog -g2012 -s tb_tt_um_protocol_emulator -o /tmp/mut_ctrl_tt.vvp \
    $WTB_SRCS $sram ../tb/tb_tt_um_protocol_emulator.v \
    >/tmp/mut_ctrl_tt_cc.log 2>&1 || return 2
  timeout 300 vvp /tmp/mut_ctrl_tt.vvp >"$WTB_LOG" 2>&1
  grep -qE "^PASS" "$WTB_LOG"
}

restore() { cp "$BAK" "$RTL"; }
wrestore() { cp "$WBAK" "$WRTL"; }
verify_restore() {
  cmp -s "$BAK" "$RTL" || { echo "  FATAL: $RTL does not match the snapshot after restore."; exit 3; }
}
wverify_restore() {
  cmp -s "$WBAK" "$WRTL" || { echo "  FATAL: $WRTL does not match the snapshot after restore."; exit 3; }
}

mutate() {
  python3 - "${3:-$RTL}" "$1" "$2" <<'PYEOF'
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

check_wrapper_mutation() {
  local name="$1"; shift
  if ! mutate "$1" "$2" "$WRTL"; then
    echo "  [$name] HARNESS ERROR: anchor not found"; wrestore; fail=$((fail+1)); return
  fi
  run_wrapper_tb
  local rc=$?
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected"; pass=$((pass+1))
  else                     fail=$((fail+1)); wrestore; return
  fi
  wrestore; wverify_restore
}

echo "=== mutation-testing the R1 framed host bus ==="
run_tb
if [ $? -ne 0 ]; then echo "  FATAL: the TB does not pass on the clean design"; exit 2; fi
echo "  [baseline] passes on the unmutated design"

# ---- frame receive --------------------------------------------------------
check_mutation "sync-value" \
  "  localparam logic [15:0] SYNC      = 16'hA55A;" \
  "  localparam logic [15:0] SYNC      = 16'h5AA5;   // MUTANT: never syncs"

check_mutation "lsb-first" \
  "  wire  [15:0] rx_word = {shreg[14:0], mosi_s1};" \
  "  wire  [15:0] rx_word = {mosi_s1, shreg[14:0]};   // MUTANT: LSB-first"

check_mutation "short-word" \
  "        if (bit_cnt == 4'd15) begin" \
  "        if (bit_cnt == 4'd14) begin   // MUTANT: 15-bit words"

check_mutation "version-accepted" \
  "              if (rx_word[15:12] != VERSION)
                frm_hdr_bad <= 1'b1;" \
  "              if (1'b0)
                frm_hdr_bad <= 1'b1;   // MUTANT: any version accepted"

check_mutation "ping-length-ignored" \
  "                OP_PING, OP_STATUS:
                  if (rx_word != 16'd0) frm_len_bad <= 1'b1;" \
  "                OP_PING, OP_STATUS:
                  if (1'b0) frm_len_bad <= 1'b1;   // MUTANT: length ignored"

check_mutation "crc-skips-payload" \
  "            S_PAYLOAD: begin
              crc_acc  <= crc16_word(crc_acc, rx_word);" \
  "            S_PAYLOAD: begin
              crc_acc  <= crc_acc;   // MUTANT: payload not folded into CRC"

check_mutation "crc-not-compared" \
  "              if (crc_acc != rx_word || frm_hdr_bad || frm_len_bad) begin" \
  "              if (frm_hdr_bad || frm_len_bad) begin   // MUTANT: CRC accepted"

check_mutation "crc-no-fault" \
  "              if (crc_acc != rx_word)
                faults <= faults | FAULT_CRC;" \
  "              if (crc_acc != rx_word)
                faults <= faults;   // MUTANT: no CRC fault latched"

# ---- response framing -----------------------------------------------------
check_mutation "resp-opcode-bit" \
  "              resp_op     <= frm_op | RESP_BIT;" \
  "              resp_op     <= frm_op;   // MUTANT: no response bit"

check_mutation "seq-not-echoed" \
  "              resp_seq    <= frm_seq;" \
  "              resp_seq    <= 16'h0000;   // MUTANT: sequence not echoed"

check_mutation "target-loop-ignored" \
  "              end else if (frm_tgt == TARGET_LOOP) begin" \
  "              end else if (1'b0) begin   // MUTANT: loopback target unreachable"

check_mutation "loopback-id-wrong" \
  "                  resp_buf[1] <= LOOPBACK_ID;" \
  "                  resp_buf[1] <= 16'h0000;   // MUTANT: wrong loopback id"

# ---- LOAD path and A1 semantics -------------------------------------------
check_mutation "stuck-address" \
  "            addr          <= addr + 1'b1;" \
  "            addr          <= addr;   // MUTANT: address never advances"

check_mutation "host-we-mask" \
  "  assign host_we       = we_r & ~run;" \
  "  assign host_we       = we_r;   // MUTANT: no run mask"

check_mutation "range-not-checked" \
  "                  if (load_idx >= 16'(WORDS)) begin" \
  "                  if (1'b0) begin   // MUTANT: no range bound"

check_mutation "range-no-fault" \
  "                    frm_range <= 1'b1;
                    faults    <= faults | FAULT_RANGE;" \
  "                    frm_range <= 1'b1;
                    faults    <= faults;   // MUTANT: no range fault"

check_mutation "echo-at-queue" \
  "                    pay0       <= rx_word;
                    word_ready <= 1'b1;" \
  "                    pay0       <= rx_word;
                    word_ready <= 1'b1;
                    load_echo  <= rx_word;   // MUTANT: echo latched at queue time"

check_mutation "status-fields-zero" \
  "                    resp_buf[10] <= words_written;" \
  "                    resp_buf[10] <= 16'h0000;   // MUTANT: words_written lost"

# ---- faults / IRQ ---------------------------------------------------------
check_mutation "irq-polarity" \
  "  assign irq_n       = ~(|faults);" \
  "  assign irq_n       = (|faults);   // MUTANT: active high"

check_mutation "faults-clear-on-cs" \
  "      if (cs_fall) begin
        rx_state      <= S_SYNC;" \
  "      if (cs_fall) begin
        faults        <= '0;   // MUTANT: a session clears sticky faults
        rx_state      <= S_SYNC;"

check_mutation "clear-mask-ignored" \
  "                    faults      <= faults & ~pay0;" \
  "                    faults      <= faults;   // MUTANT: CLEAR_FAULT clears nothing"

# ---- MISO ownership -------------------------------------------------------
check_mutation "miso-oe-stuck" \
  "  assign miso_oe     = resp_active | resp_hold_oe | r_filling;" \
  "  assign miso_oe     = 1'b1;   // MUTANT: MISO never releases"

check_mutation "resp-never-active" \
  "              resp_active <= 1'b1;" \
  "              resp_active <= 1'b0;   // MUTANT: no response is ever shifted"

# ---- wrapper pad wiring (tb_tt_um_protocol_emulator) ----------------------
run_wrapper_tb
rc=$?
if [ $rc -ne 0 ]; then
  echo "  FATAL: the pad-level TB does not pass on the clean design (exit $rc)"
  [ $rc -eq 2 ] && tail -5 /tmp/mut_ctrl_tt_cc.log /tmp/mut_ctrl_tt.log 2>/dev/null
  exit 2
fi
echo "  [baseline-wrapper] tb_tt_um_protocol_emulator passes on the unmutated design"

check_wrapper_mutation "cs-pad-wrong" \
  "    .spi_sclk(uio_in[7]), .spi_mosi(uio_in[5]), .spi_cs_n(uio_in[4])," \
  "    .spi_sclk(uio_in[7]), .spi_mosi(uio_in[5]), .spi_cs_n(uio_in[3]),   // MUTANT: CS on uio[3]"

check_wrapper_mutation "sck-pad-wrong" \
  "    .spi_sclk(uio_in[7]), .spi_mosi(uio_in[5]), .spi_cs_n(uio_in[4])," \
  "    .spi_sclk(uio_in[6]), .spi_mosi(uio_in[5]), .spi_cs_n(uio_in[4]),   // MUTANT: SCK on uio[6]"

check_wrapper_mutation "miso-oe-stuck-driven" \
  "  assign uio_oe[6]    = ctrl_miso_oe;    // driven only while a response shifts" \
  "  assign uio_oe[6]    = 1'b1;   // MUTANT: MISO pad never releases"

check_wrapper_mutation "miso-out-tied" \
  "  assign uio_out[6]   = ctrl_spi_miso;   // framed response MISO" \
  "  assign uio_out[6]   = 1'b0;   // MUTANT: MISO never reaches the pad"

check_wrapper_mutation "irq-route-wrong" \
  "  assign uo_out[1]   = ctrl_irq_n;        // IRQ_N: active low, sticky faults" \
  "  assign uo_out[1]   = 1'b1;   // MUTANT: IRQ_N never asserts"

check_wrapper_mutation "host-input-driven" \
  "  assign uio_oe[4]    = 1'b0;            // CS_N input" \
  "  assign uio_oe[4]    = 1'b1;   // MUTANT: the chip drives its own CS_N input"

# ---- R2: the read path, the wait-word contract, and the R2 bounds --------
# The 29 mutations above are all R1 behaviour. R2 added a read engine, a
# transport-level wait-word rule, a bounds check and a sticky-fault lifecycle,
# and every one of those is a claim a testbench could be vacuously passing.
# Same house convention: a plausible wrong implementation, and the TB must
# notice. Anchors are quoted verbatim so a rename is a HARNESS ERROR, never a
# silent survivor.

# 1. The filler drives zeros instead of ones. A host skips LEADING 0xFFFF, so
#    0x0000 fillers are not skipped and the frame is read from the wrong place.
check_mutation "r2-filler-not-ones" \
  "          spi_miso  <= 1'b1;" \
  "          spi_miso  <= 1'b0;   // MUTANT: filler is 0x0000, not 0xFFFF"

# 2. The response is released mid-word instead of on a word boundary, so the
#    host's 16-bit reader starts half a word in.
check_mutation "r2-launch-unaligned" \
  "          if (fill_pos == 4'd15) begin" \
  "          if (fill_pos == 4'd7) begin   // MUTANT: launch off a half word"

# 3. The imem bound check is removed: a read past the end WRAPS instead of
#    answering RANGE. This is the "never a wrapped read" obligation.
check_mutation "r2-imem-range-off" \
  "                      if ((32'(pay0) + 32'(pay1)) > 32'(WORDS) ||" \
  "                      if (1'b0 ||   // MUTANT: imem bound check removed"

# 4. The dmem bound check is removed, the byte version of the same promise.
check_mutation "r2-dmem-range-off" \
  "                      if ((32'(pay0) + 32'(pay1)) > 32'(DMEM_BYTES) ||" \
  "                      if (1'b0 ||   // MUTANT: dmem bound check removed"

# 5. An out-of-range READ no longer latches sticky FAULT_RANGE.
check_mutation "r2-range-fault-not-sticky" \
  "                        faults      <= faults | FAULT_RANGE;" \
  "                        faults      <= faults;   // MUTANT: RANGE not latched"

# 6. A bounded read answers while run=1 instead of NOT_READY. The CPU is
#    fetching, and the read would borrow its address bus.
check_mutation "r2-read-not-ready-off" \
  "                    if (run) begin
                      resp_len    <= 16'd1;
                      resp_buf[0] <= ST_NOTREADY;
                      r_imm       <= 1'b1;" \
  "                    if (1'b0) begin   // MUTANT: no run gate on the reads
                      resp_len    <= 16'd1;
                      resp_buf[0] <= ST_NOTREADY;
                      r_imm       <= 1'b1;"

# 7. The trailing byte of an ODD-length dmem read is dropped, leaving the
#    response a word short of its declared length.
check_mutation "r2-dmem-odd-flush-off" \
  "              if (r_dmem && r_first)" \
  "              if (1'b0)   // MUTANT: odd trailing byte dropped"

# 8. DUMP_CORE no longer refuses while run=1, so the core header reports a
#    moving target as if it were a stable one.
check_mutation "r2-dumpcore-notready-off" \
  "                    if (run) begin
                      resp_len    <= 16'd1;
                      resp_buf[0] <= ST_NOTREADY;
                    end else begin" \
  "                    if (1'b0) begin   // MUTANT: DUMP_CORE ignores run
                      resp_len    <= 16'd1;
                      resp_buf[0] <= ST_NOTREADY;
                    end else begin"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
[ $survived -gt 0 ] && { echo "SURVIVORS: the TB does not test what it claims."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every framed-host-bus mutation (R1 + R2 read path) is detected by its testbench."
exit 0

