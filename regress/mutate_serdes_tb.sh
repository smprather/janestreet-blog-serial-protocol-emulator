#!/usr/bin/env bash
# mutate_serdes_tb.sh — mutation-test tb_pe_serdes.v (the shared word engine).
#
# WHY THIS EXISTS. The integration split `pe_serdes.bit_en` into tx_bit_en /
# rx_bit_en (wiki/plans/serdes-integration.md), so the unit TB and its
# evidence changed with it: every mutation below is a plausible implementation
# choice in rtl/pe_serdes.v, and the TB must notice all of them:
#
#   1. tx-on-rx-en      — the TX side advances on the RX enable (the split is
#                         cosmetic; the directed case proves independence);
#   2. rx-on-tx-en      — the RX side advances on the TX enable;
#   3. lsb-snapshot     — TX ignores cfg_lsb_first and always sends MSB-first;
#   4. rx-pos-init      — the RX bit placer starts from the wrong end;
#   5. rx-data-copy     — rx_valid fires without copying the shifter, so
#                         rx_data returns the PREVIOUS word;
#   6. len0-load        — a zero-length load restarts the engine anyway
#                         (0 is out of contract and must be ignored);
#   7. tx-idle-low      — tx_ser idles LOW instead of HIGH (a UART start bit
#                         to a listening peer).
#
# RESTORE IS A FILE COPY, verified after every mutation.
set -u
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
RTL="$ROOT/rtl/pe_serdes.v"
# MUTABLE — what this harness EDITS inside the repo. Read by
# regress/verify_merge.sh (the merge gate) to decide whether a narrowed gate
# has to run this suite, and by regress/check_mutation_lists.sh to prove the
# list still covers every file the harness writes. Evidence: RTL=.
# An EMPTY value means this suite mutates nothing in the repo and is therefore
# NEVER SKIPPED. A MISSING line is the opposite: unmappable, and the gate
# escalates to running every suite rather than guessing.
MUTABLE="rtl/pe_serdes.v"
LOG=/tmp/mutate_serdes.log
BAK=$(mktemp /tmp/pe_serdes.XXXXXX.v)

cleanup() { cp "$BAK" "$RTL" 2>/dev/null; rm -f "$BAK"; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"
cp "$RTL" "$BAK"
cmp -s "$RTL" "$BAK" || { echo "FATAL: could not snapshot $RTL"; exit 2; }

SRCS="../rtl/pe_serdes.v ../tb/tb_pe_serdes.v"

run_tb() {
  iverilog -g2012 -s tb_pe_serdes -o /tmp/mut_serdes.vvp $SRCS \
    >/tmp/mut_serdes_cc.log 2>&1 || return 2
  timeout 120 vvp /tmp/mut_serdes.vvp >"$LOG" 2>&1
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

pass=0; fail=0; survived=0

check_mutation() {
  local name="$1"; shift
  if ! mutate "$1" "$2"; then
    echo "  [$name] HARNESS ERROR: anchor not found"; restore; fail=$((fail+1)); return
  fi
  run_tb
  local rc=$?
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected"; pass=$((pass+1))
  else                     echo "  [$name] HARNESS ERROR: exit $rc"; fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing tb_pe_serdes ==="
run_tb
if [ $? -ne 0 ]; then echo "  FATAL: the TB does not pass on the clean design"; exit 2; fi
echo "  [baseline] passes on the unmutated design"

check_mutation "tx-on-rx-en" \
  "      end else if (tx_bit_en && tx_busy) begin" \
  "      end else if (rx_bit_en && tx_busy) begin   // MUTANT: TX keyed to the RX enable"

check_mutation "rx-on-tx-en" \
  "      end else if (rx_bit_en && rx_busy) begin" \
  "      end else if (tx_bit_en && rx_busy) begin   // MUTANT: RX keyed to the TX enable"

check_mutation "lsb-snapshot" \
  "        cfg_lsb_tx <= cfg_lsb_first;" \
  "        cfg_lsb_tx <= 1'b0;   // MUTANT: TX ignores cfg_lsb_first"

check_mutation "rx-pos-init" \
  "        rx_pos     <= cfg_lsb_first ? '0 : IDXW'(rx_len - 1'b1);" \
  "        rx_pos     <= cfg_lsb_first ? IDXW'(rx_len - 1'b1) : '0;   // MUTANT: placer from the wrong end"

check_mutation "rx-data-copy" \
  "        rx_data  <= rx_shreg;" \
  "        rx_data  <= rx_data;   // MUTANT: rx_valid without the shifter copy"

check_mutation "len0-load" \
  "      if (tx_load && (|tx_len)) begin" \
  "      if (tx_load) begin   // MUTANT: zero-length load accepted"

check_mutation "tx-idle-low" \
  "  assign tx_ser = tx_busy ? tx_shreg[tx_rd_idx] : 1'b1;" \
  "  assign tx_ser = tx_busy ? tx_shreg[tx_rd_idx] : 1'b0;   // MUTANT: idles low"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
[ $survived -gt 0 ] && { echo "SURVIVORS: the TB does not test what it claims."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every pe_serdes mutation (including the split enables) is detected by tb_pe_serdes."
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
