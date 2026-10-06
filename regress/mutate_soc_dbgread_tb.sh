#!/usr/bin/env bash
# mutate_soc_dbgread_tb.sh — mutation-test tb_pe_soc_dbgread.v (the R2 bounded
# host read port in pe_soc, behind the real SRAM macro).
#
# WHY THIS EXISTS. tb_pe_soc_dbgread is the ONLY gate that drives the SoC's
# dbg_rd_* port against pe_imem's registered read: every other pe_soc TB ties
# dbg_rd_req to 1'b0, and tb_pe_ctrl_r2/r3 serve the port combinationally from
# a TB-side image. That hole is where the one-address-stale IMEM defect lived
# from the first day the port existed (plan Amendment A2, fixed 55ab86f), so
# this suite keeps the TB from silently stopping testing what it exists to
# test. Each mutation below is a plausible implementation choice in the read
# port's capture block in rtl/pe_soc.v; the TB must notice every one:
#
#   1. imem-request-edge-capture — dbg_rd_data is captured on the REQUEST edge
#      (the pre-A2 code, 55ab86f^): the macro's read is registered, so the
#      capture copies the PREVIOUS address's word (the historical defect).
#   2. dmem-capture-on-answer-edge — dmem_byte_q is captured when the ANSWER
#      is presented instead of when the request is taken, so the first dmem
#      read presents the reset value, not the byte (the capture-edge
#      asymmetry, in the direction the fix did not go).
#   3. dmem-reads-answer-imem — dbg_rd_data always follows imem_rdata, so a
#      dmem byte read answers an instruction word (one shape, one memory:
#      the one-shape contract's other half).
#   4. dmem-flag-never-held — dbg_rd_dmem_q is cleared on every request
#      instead of capturing the request's memory, so dmem reads are served by
#      the imem path (the flag hold the fix added, dropped).
#   5. valid-never-drops — dbg_rd_valid is held with the request OR'd in, so
#      the answer pulse never falls (the one-cycle-wide contract).
#   6. valid-two-cycles-late — the request is pipelined one extra stage, so
#      the answer arrives two cycles after the request (the one-cycle-late
#      contract).
#
# CONSIDERED AND EXCLUDED, with the reason on record. `dbg_reading = dbg_rd_req`
# (the arbiter releasing imem_addr during the ANSWER cycle) is EQUIVALENT for
# this port: the macro registers the requested word at the same edge the
# request is captured, so imem_rdata in the answer cycle is the requested word
# whether or not the address mux leaves, and the dmem byte was already captured
# on the request edge. It would survive every check, not because the TB is
# weak but because the port genuinely cannot observe it — a mutant reported as
# a survivor there would be a false coverage claim.
#
# RESTORE IS A FILE COPY, verified after every mutation (the eth_mac lesson:
# a failed restore stacks mutations and reports a meaningless perfect score).
set -u
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
RTL="$ROOT/rtl/pe_soc.v"
# MUTABLE — what this harness EDITS inside the repo. Read by
# regress/verify_merge.sh (the merge gate) to decide whether a narrowed gate
# has to run this suite, and by regress/check_mutation_lists.sh to prove the
# list still covers every file the harness writes. Evidence: RTL=.
# An EMPTY value means this suite mutates nothing in the repo and is therefore
# NEVER SKIPPED. A MISSING line is the opposite: unmappable, and the gate
# escalates to running every suite rather than guessing.
MUTABLE="rtl/pe_soc.v"
LOG="$CHIP_WT_DIR"/mutate_soc_dbgread.log
BAK=$(mktemp /tmp/pe_soc_dbgread.XXXXXX.v)

cleanup() { cp "$BAK" "$RTL" 2>/dev/null; rm -f "$BAK"; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"
cp "$RTL" "$BAK"
cmp -s "$RTL" "$BAK" || { echo "FATAL: could not snapshot $RTL"; exit 2; }

# Same source list as run_all.sh's tb_pe_soc_dbgread case.
SRCS="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v"

run_tb() {
  local sram
  sram=$(bash "$ROOT/regress/sram_model.sh" 2>/dev/null) || return 2
  iverilog -g2012 -s tb_pe_soc_dbgread -o "$CHIP_WT_DIR"/mut_soc_dbgread.vvp \
    $SRCS $sram ../tb/tb_pe_soc_dbgread.v >"$CHIP_WT_DIR"/mut_soc_dbgread_cc.log 2>&1 || return 2
  timeout 300 vvp "$CHIP_WT_DIR"/mut_soc_dbgread.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

restore() { cp "$BAK" "$RTL"; chip_dep_expect pristine $MUTABLE; }
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

pass=0; fail=0; survived=0

check_mutation() {
  local name="$1"; shift
  if ! mutate "$1" "$2"; then
    echo "  [$name] HARNESS ERROR: anchor not found"; restore; fail=$((fail+1)); return
  fi
  chip_dep_expect mutated $MUTABLE
  run_tb
  local rc=$?
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected"; pass=$((pass+1))
  else                     echo "  [$name] HARNESS ERROR: exit $rc"; tail -5 "$CHIP_WT_DIR"/mut_soc_dbgread_cc.log "$LOG" 2>/dev/null; fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing tb_pe_soc_dbgread ==="
run_tb
rc=$?
if [ $rc -ne 0 ]; then
  echo "  FATAL: the TB does not pass on the clean design (exit $rc)"
  [ $rc -eq 2 ] && tail -5 "$CHIP_WT_DIR"/mut_soc_dbgread_cc.log
  exit 2
fi
echo "  [baseline] passes on the unmutated design"

# 1. The historical defect, restored: dbg_rd_data captured on the REQUEST edge
#    (exactly the pre-A2 block, 55ab86f^), presenting the previous word.
check_mutation "imem-request-edge-capture" \
  "      if (dbg_rd_req) begin
        dmem_byte_q   <= dmem_byte;    // dmem reads combinationally; imem does not
        dbg_rd_dmem_q <= dbg_rd_dmem;
      end
    end
  end

  assign dbg_rd_data = dbg_rd_dmem_q ? {8'h00, dmem_byte_q} : imem_rdata;" \
  "      if (dbg_rd_req) begin
        dmem_byte_q   <= dmem_byte;    // dmem reads combinationally; imem does not
        dbg_rd_dmem_q <= dbg_rd_dmem;
        dbg_rd_data   <= dbg_rd_dmem ? {8'h00, dmem_byte}
                                     : imem_rdata;   // MUTANT: request-edge capture
      end
    end
  end

  // MUTANT: no assign — dbg_rd_data is captured on the REQUEST edge"

# 2. The dmem byte captured on the ANSWER edge instead of the request edge:
#    the first dmem read then presents the reset value (8'h00).
check_mutation "dmem-capture-on-answer-edge" \
  "      if (dbg_rd_req) begin
        dmem_byte_q   <= dmem_byte;    // dmem reads combinationally; imem does not
        dbg_rd_dmem_q <= dbg_rd_dmem;
      end" \
  "      if (dbg_rd_valid) begin
        dmem_byte_q   <= dmem_byte;    // MUTANT: captured on the ANSWER edge
        dbg_rd_dmem_q <= dbg_rd_dmem;
      end"

# 3. One shape, one memory: dmem reads answer the imem word.
check_mutation "dmem-reads-answer-imem" \
  "  assign dbg_rd_data = dbg_rd_dmem_q ? {8'h00, dmem_byte_q} : imem_rdata;" \
  "  assign dbg_rd_data = imem_rdata;   // MUTANT: one shape, one memory"

# 4. The dmem flag hold dropped: every request clears the select, so dmem
#    reads are served by the imem path.
check_mutation "dmem-flag-never-held" \
  "        dbg_rd_dmem_q <= dbg_rd_dmem;" \
  "        dbg_rd_dmem_q <= 1'b0;   // MUTANT: the request's memory is never held"

# 5. The answer pulse never falls: valid is held with the request OR'd in.
check_mutation "valid-never-drops" \
  "      dbg_rd_valid <= dbg_rd_req;      // the answer, one cycle later" \
  "      dbg_rd_valid <= dbg_rd_req | dbg_rd_valid;   // MUTANT: the answer never drops"

# 6. The answer two cycles late: one extra stage of request pipelining.
check_mutation "valid-two-cycles-late" \
  "  logic       dbg_rd_dmem_q;   // the request's memory, held to the answer cycle
  logic [7:0] dmem_byte_q;     // the request's dmem byte, held to the answer cycle

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_rd_valid  <= 1'b0;
      dbg_rd_dmem_q <= 1'b0;
      dmem_byte_q   <= 8'h00;
    end else begin
      dbg_rd_valid <= dbg_rd_req;      // the answer, one cycle later" \
  "  logic       dbg_rd_dmem_q;   // the request's memory, held to the answer cycle
  logic [7:0] dmem_byte_q;     // the request's dmem byte, held to the answer cycle
  logic       dbg_rd_req_q1;   // MUTANT: an extra stage of request pipelining

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_rd_valid  <= 1'b0;
      dbg_rd_dmem_q <= 1'b0;
      dmem_byte_q   <= 8'h00;
      dbg_rd_req_q1 <= 1'b0;
    end else begin
      dbg_rd_valid <= dbg_rd_req_q1;   // MUTANT: the answer, two cycles later
      dbg_rd_req_q1 <= dbg_rd_req;"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
[ $survived -gt 0 ] && { echo "SURVIVORS: the TB does not test what it claims."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every host-read-port mutation is detected by tb_pe_soc_dbgread."
  # THE HARNESS-EDIT PRE-FLIGHT (regress/dep_guard.sh). Stamped when this
  # harness took the run lock; verified HERE, because this is the only place it
  # can be: the harness sets its own `trap cleanup EXIT` after sourcing
  # run_lock.sh, and a second EXIT trap replaces the first, so a check installed
  # over there would be silently discarded. If this script — or the lock helper it
  # sources — changed while we were running, bash's incremental read means our
  # verdict is untrustworthy in EITHER direction, so exit 4 (INCONCLUSIVE) rather
  # than report a possibly-false pass.
  chip_dep_check "run_$(basename "$0")" || exit 4

exit 0