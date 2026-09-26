#!/usr/bin/env bash
# mutate_eth_tx_tb.sh — mutation-test tb/tb_pe_eth_tx.v (the 10BASE-T TX frame
# engine, wiki/plans/eth-tx-frame-path.md G8 / Review Focus 1-6).
#
# WHY THIS EXISTS. The engine makes a dozen claims that no single directed case
# can be trusted to hold: the prelude is a WIRE PATTERN (not 0xAA through a byte
# helper), the SFD is a bit sequence, octets go out LSB-first, pad zeros are
# data (folded into the FCS), the FCS field drains the register to zero, the
# line is CONSTANT while idle, the IFG is >= 96 cells, and runt/jabber/underrun
# are refused loudly. A test that passes on a subtly wrong engine still looks
# green, which is the exact failure this repo already paid for on pe_eth_mac
# and on the two-driver tick_flag. So every claim gets a mutation and the TB
# must FAIL on all of them.
#
# The mutations are the plausible implementation choices, not random damage:
#
#   1.  preamble-short      the SFD lands one cell early, so the last prelude
#                           bit is inverted
#   2.  preamble-long       the preamble runs one cell past the SFD
#   3.  preamble-inverted   the alternation starts with 0 (the 0xAA trap)
#   4.  sfd-order-flipped   the SFD's last bit is 0, not 1
#   5.  crc-not-cleared     the frame start does not clear the TX CRC, so the
#                           SECOND frame folds the first frame's residue
#   6.  fcs-uncomplemented  cfg_out_inv = 0 (the complement never goes on the
#                           wire) -- the residue is still "right" internally
#   7.  field-mode-short    the 32 field cells do not shift the register
#   8.  pad-not-folded      pad cells do not feed the CRC (a byte compare
#                           still passes; the residue does not)
#   9.  field-mode-long     the last pad cell is folded in FIELD mode
#  10.  pad-extra           a 60-byte frame gets one pad byte (wire too long)
#  11.  pad-omitted         a 42-byte frame gets no pad at all
#  12.  ifg-95              the inter-frame gap is 95 cells, one short of spec
#  13.  jabber-accepted     a 1,515-byte request is accepted, not refused
#  14.  runt-accepted       a 13-byte request is accepted, not refused
#  15.  underrun-silent     DATA running dry does not pulse tx_underrun
#  16.  idle-square-wave    idle drives a constant instead of half_phase, so
#                           pe_manch emits a 10 MHz square wave (Review
#                           Focus 1: "idle is a constant, not stop driving")
#  17.  octet-msb-first     the first bit of every byte is bit 7
#  18.  done-before-fcs     tx_done pulses when the field STARTS
#
# RESTORE IS A FILE COPY, cmp-verified after every mutation and snapshotted
# into a temp dir that survives a SIGKILL (the 2026-09-24 18:43 OOM left a
# mutant behind precisely because the restore step never ran; the snapshot is
# the recovery path). `git checkout` is never used (gotcha 63).
set -u
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
RTL="$ROOT/rtl/pe_eth_tx.v"
# MUTABLE — what this harness EDITS inside the repo. Read by
# regress/verify_merge.sh (the merge gate) to decide whether a narrowed gate
# has to run this suite, and by regress/check_mutation_lists.sh to prove the
# list still covers every file the harness writes. Evidence: RTL=; pe_crc appears only in a compile list.
# An EMPTY value means this suite mutates nothing in the repo and is therefore
# NEVER SKIPPED. A MISSING line is the opposite: unmappable, and the gate
# escalates to running every suite rather than guessing.
MUTABLE="rtl/pe_eth_tx.v"
LOG=/tmp/mutate_eth_tx.log
CCLOG=/tmp/mutate_eth_tx_cc.log
PRISTINE=$(mktemp -d /tmp/pristine_eth_tx_tb.XXXXXX)
BAK=$(mktemp -d /tmp/backup_eth_tx_tb.XXXXXX)

cleanup() { cp "$BAK/pe_eth_tx.v" "$RTL" 2>/dev/null; rm -rf "$BAK"; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"
cp "$RTL" "$PRISTINE/pe_eth_tx.v"
cp "$RTL" "$BAK/pe_eth_tx.v"
cmp -s "$RTL" "$PRISTINE/pe_eth_tx.v" || { echo "FATAL: could not snapshot $RTL"; exit 2; }

# Same source list as run_all.sh's tb_pe_eth_tx case (no SRAM model: the
# engine + the CRC engine are the whole design here).
run_tb() {
  iverilog -g2012 -s tb_pe_eth_tx -o /tmp/mut_eth_tx.vvp \
    ../rtl/pe_eth_tx.v ../rtl/pe_crc.v ../tb/tb_pe_eth_tx.v >"$CCLOG" 2>&1 || return 2
  timeout 300 vvp /tmp/mut_eth_tx.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

restore() { cp "$BAK/pe_eth_tx.v" "$RTL"; }
verify_restore() {
  cmp -s "$PRISTINE/pe_eth_tx.v" "$RTL" || {
    echo "  FATAL: $RTL does not match the pristine snapshot after restore."; exit 3; }
}

mutate() {
  python3 - "$RTL" "$1" "$2" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
if t.count(sys.argv[2]) != 1:
    sys.exit(f"anchor count {t.count(sys.argv[2])} != 1")
p.write_text(t.replace(sys.argv[2], sys.argv[3], 1))
PYEOF
}

pass=0; fail=0; survived=0

check_mutation() {
  local name="$1"; shift
  if ! mutate "$1" "$2"; then
    echo "  [$name] HARNESS ERROR: anchor not found/unique"; restore; fail=$((fail+1)); return
  fi
  run_tb
  local rc=$?
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected"; pass=$((pass+1))
  else                     echo "  [$name] HARNESS ERROR: exit $rc"; tail -3 "$CCLOG" "$LOG" 2>/dev/null; fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing tb_pe_eth_tx (pristine snapshot: $PRISTINE) ==="
run_tb
rc=$?
if [ $rc -ne 0 ]; then
  echo "  FATAL: the TB does not pass on the clean design (exit $rc)"
  [ $rc -eq 2 ] && tail -5 "$CCLOG"
  exit 2
fi
echo "  [baseline] passes on the unmutated design"

# 1. SFD one cell early: the final prelude bit is inverted.
check_mutation "preamble-short" \
  "    pre_bit = (n == 6'd63) ? 1'b1 : ~n[0];" \
  "    pre_bit = (n == 6'd62) ? 1'b1 : ~n[0];   // MUTANT: SFD one cell early"

# 2. The preamble runs one cell past the SFD.
check_mutation "preamble-long" \
  "              if (pre_cnt == 6'd63) begin" \
  "              if (pre_cnt == 6'd62) begin   // MUTANT: one cell past the SFD"

# 3. The alternation starts with 0 — the 0xAA-through-a-byte-helper trap.
check_mutation "preamble-inverted" \
  "    pre_bit = (n == 6'd63) ? 1'b1 : ~n[0];" \
  "    pre_bit = (n == 6'd63) ? 1'b1 : n[0];   // MUTANT: inverted phase"

# 4. The SFD's last bit is 0, not 1 (Review Focus 4: no byte compare).
check_mutation "sfd-order-flipped" \
  "    pre_bit = (n == 6'd63) ? 1'b1 : ~n[0];" \
  "    pre_bit = (n == 6'd63) ? 1'b0 : ~n[0];   // MUTANT: SFD bit flipped"

# 5. The frame start does not clear the TX CRC: frame 2 folds frame 1's residue.
check_mutation "crc-not-cleared" \
  "                crc_clr        <= 1'b1;              // prelude never folds" \
  "                crc_clr        <= 1'b0;              // MUTANT: CRC not cleared"

# 6. The FCS complement never reaches the wire (Review Focus 2).
check_mutation "fcs-uncomplemented" \
  "    .cfg_out_inv(1'b1),            // Ethernet's xorout is all ones" \
  "    .cfg_out_inv(1'b0),            // MUTANT: FCS un-complemented"

# 7. The 32 field cells do not shift the register: the field repeats one bit.
check_mutation "field-mode-short" \
  "  wire  crc_bit_en = cell_start && (state == S_DATA || state == S_PAD
                                 || state == S_FCS);" \
  "  wire  crc_bit_en = cell_start && (state == S_DATA || state == S_PAD);   // MUTANT: field cells not folded"

# 8. Pad cells are not folded (Review Focus 3: a byte compare would pass).
check_mutation "pad-not-folded" \
  "  wire  crc_bit_en = cell_start && (state == S_DATA || state == S_PAD
                                 || state == S_FCS);" \
  "  wire  crc_bit_en = cell_start && (state == S_DATA || state == S_FCS);   // MUTANT: pad not folded"

# 9. The last pad cell is folded in FIELD mode (complement on the feedback).
check_mutation "field-mode-long" \
  "  wire  crc_field  = (state == S_FCS);" \
  "  wire  crc_field  = (state == S_FCS) || (state == S_PAD);   // MUTANT: field mode reaches PAD"

# 10. A 60-byte frame gets one pad byte it does not need.
check_mutation "pad-extra" \
  "                if (stored_bytes < 12'd60) begin" \
  "                if (stored_bytes < 12'd61) begin   // MUTANT: one pad byte too many"

# 11. A 42-byte frame gets no pad at all.
check_mutation "pad-omitted" \
  "                if (stored_bytes < 12'd60) begin" \
  "                if (stored_bytes < 12'd0) begin   // MUTANT: pad omitted"

# 12. The inter-frame gap is one cell short of the 96 the plan fixes.
check_mutation "ifg-95" \
  "              if (ifg_cnt == 7'd95) state <= S_IDLE;" \
  "              if (ifg_cnt == 7'd94) state <= S_IDLE;   // MUTANT: IFG 95 cells"

# 13. A jabber is accepted instead of refused.
check_mutation "jabber-accepted" \
  "  wire len_ok = (frame_len >= 12'd14) && (frame_len <= 12'(MAX_STORED));" \
  "  wire len_ok = (frame_len >= 12'd14) && (frame_len <= 12'hFFF);   // MUTANT: jabber accepted"

# 14. A runt is accepted instead of refused.
check_mutation "runt-accepted" \
  "  wire len_ok = (frame_len >= 12'd14) && (frame_len <= 12'(MAX_STORED));" \
  "  wire len_ok = (frame_len >= 12'd1) && (frame_len <= 12'(MAX_STORED));   // MUTANT: runt accepted"

# 15. DATA running dry is a SILENT gap instead of a fault.
check_mutation "underrun-silent" \
  "                    tx_underrun <= 1'b1;             // never a silent gap" \
  "                    tx_underrun <= 1'b0;             // MUTANT: silent underrun"

# 16. Idle drives a constant, so the Manchester encoder emits a square wave.
check_mutation "idle-square-wave" \
  "      default:                 tx_bit = half_phase;" \
  "      default:                 tx_bit = 1'b0;   // MUTANT: square-wave idle"

# 17. The first bit of every byte is bit 7, not bit 0.
check_mutation "octet-msb-first" \
  "                  tx_reg  <= fifo_head[3'd0];" \
  "                  tx_reg  <= fifo_head[3'd7];   // MUTANT: MSB-first octets"

# 18. tx_done pulses when the FCS field STARTS, not when it ends.
check_mutation "done-before-fcs" \
  "              if (fcs_left == 6'd1) begin" \
  "              if (fcs_left == 6'd32) begin   // MUTANT: done before the FCS"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
echo "    pristine snapshot kept for forensics: $PRISTINE"
[ $survived -gt 0 ] && { echo "SURVIVORS: the TB does not test what it claims."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every pe_eth_tx engine mutation is detected by tb_pe_eth_tx."
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
