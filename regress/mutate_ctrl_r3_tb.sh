#!/usr/bin/env bash
# mutate_ctrl_r3_tb.sh — mutation-test tb_pe_ctrl_r3.v: the R3 debug contract
# must FAIL when the invariants it claims break. A TB that passes on broken RTL
# is worse than no TB, because it manufactures confidence.
#
# THREE OUTCOMES, NOT TWO (the house rule): a mutation that does not COMPILE is
# INCONCLUSIVE and fails the run -- reporting "not detected" for a build error
# would be a false accusation against the TB and would hide a surviving mutant.
#
# Each mutant attacks one R3 claim:
#   * step-no-hold      the step does not HOLD the core          (S1/S2)
#   * step-stuck-pulse  the step pulse never clears (free run)   (S1)
#   * bp-hit-no-hold    the hit does not stop the core           (S3)
#   * bp-stop-after     the hit uses pc, not the landing address (S3, stop-before)
#   * bp-set-no-range   a past-the-end address arms anyway       (S5)
#   * bp-clr-no-release the release never happens                (S4/contract)
#   * status-state-old  STATUS stops reporting the debug states  (S3 observability)
#
# Usage: regress/mutate_ctrl_r3_tb.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
# shellcheck source=regress/run_lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"

MUTABLE="rtl/pe_ctrl.v"
SRCS="$REPO/rtl/pe_ctrl.v $REPO/rtl/pe_cpu.v $REPO/tb/tb_pe_ctrl_r3.v"

PRISTINE=$(mktemp -d)
for f in $MUTABLE; do cp "$f" "$PRISTINE/$(basename "$f")"; done

restore_pristine() { for f in $MUTABLE; do cp "$PRISTINE/$(basename "$f")" "$f"; done; return 0; }
cleanup() { restore_pristine; rm -rf "$PRISTINE" "$TMP"; chip_release_run_lock; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
TMP=$(mktemp -d)
trap cleanup EXIT
trap on_signal INT TERM

restore_and_verify() {
  restore_pristine
  for f in $MUTABLE; do
    cmp -s "$PRISTINE/$(basename "$f")" "$f" || {
      echo "  RESTORE FAILED -- $f differs from the pristine snapshot"; exit 3; }
  done
}

detected=0; survived=0; inconclusive=0

mutate() { # <file> <old> <new>  (exactly one occurrence required)
  python3 - "$REPO" "$1" "$2" "$3" <<'PYEOF'
import sys, pathlib
root, rel, old, new = sys.argv[1:5]
p = pathlib.Path(root) / rel
t = p.read_text()
if t.count(old) != 1:
    sys.exit(f"anchor count {t.count(old)} != 1 in {rel}")
p.write_text(t.replace(old, new, 1))
PYEOF
}

run_one() { # <name> <old> <new>
  local name="$1" old="$2" new="$3"
  echo "=== mutation: $name ==="
  if ! mutate rtl/pe_ctrl.v "$old" "$new"; then
    echo "  MUTATION DID NOT APPLY -> INCONCLUSIVE"; inconclusive=$((inconclusive+1))
    restore_and_verify; return
  fi
  local cc=0
  iverilog -g2012 -s tb_pe_ctrl_r3 -o "$TMP/mut.vvp" $SRCS >"$TMP/cc.log" 2>&1 || cc=$?
  if [ "$cc" -ne 0 ] || [ ! -s "$TMP/mut.vvp" ]; then
    echo "  INCONCLUSIVE: the mutated design did not compile (iverilog exit $cc)"
    grep -E "error:" "$TMP/cc.log" | head -3 | sed 's/^/    /'
    inconclusive=$((inconclusive+1)); restore_and_verify; return
  fi
  timeout 300 vvp "$TMP/mut.vvp" >"$TMP/run.log" 2>&1 || true
  if grep -q "^PASS: tb_pe_ctrl_r3" "$TMP/run.log"; then
    echo "  SURVIVED -- the TB passed on the mutated design (blind spot)"
    survived=$((survived+1))
  else
    echo "  DETECTED (TB failed on the mutated design)"
    grep -E "^FAIL" "$TMP/run.log" | head -3 | sed 's/^/    /'
    detected=$((detected+1))
  fi
  restore_and_verify
}

echo "=== mutation-testing the R3 debug contract (pristine snapshot: $PRISTINE) ==="

# --- baseline: the clean design must PASS first, or nothing below means anything
iverilog -g2012 -s tb_pe_ctrl_r3 -o "$TMP/base.vvp" $SRCS >"$TMP/cc.log" 2>&1
timeout 300 vvp "$TMP/base.vvp" >"$TMP/run.log" 2>&1
if ! grep -q "^PASS: tb_pe_ctrl_r3" "$TMP/run.log"; then
  echo "  FATAL: the TB does not pass on the unmutated design"
  grep -E "^FAIL" "$TMP/run.log" | head -5 | sed 's/^/    /'
  exit 2
fi
echo "  [baseline] the TB passes on the unmutated design"

run_one "step-no-hold" \
  "                      dbg_step_r <= 1'b1;
                      dbg_hold_r <= 1'b1;
                      bp_hit     <= bp_en && (dbg_next_pc == bp_addr);" \
  "                      dbg_step_r <= 1'b1;
                      bp_hit     <= bp_en && (dbg_next_pc == bp_addr);"

run_one "step-stuck-pulse" "      dbg_step_r <= 1'b0;" "      dbg_step_r <= 1'b1;"

run_one "bp-hit-no-hold" \
  "        bp_hit     <= 1'b1;
        dbg_hold_r <= 1'b1;
      end" \
  "        bp_hit     <= 1'b1;
      end"

run_one "bp-stop-after" \
  "      if (bp_en && !dbg_hold_r && (run || dbg_step_r) &&
          (dbg_next_pc == bp_addr)) begin" \
  "      if (bp_en && !dbg_hold_r && (run || dbg_step_r) &&
          (dbg_pc == bp_addr)) begin"

run_one "bp-set-no-range" \
  "                    if (32'(pay0) >= 32'(WORDS)) begin" \
  "                    if (1'b0) begin"

run_one "bp-clr-no-release" \
  "                    bp_en      <= 1'b0;
                    bp_hit     <= 1'b0;
                    dbg_hold_r <= 1'b0;" \
  "                    bp_en      <= 1'b0;
                    bp_hit     <= 1'b0;"

run_one "status-state-old" \
  "                    resp_buf[1] <= {14'b0, dbg_state};       // state (R3: 2/3 = debug)" \
  "                    resp_buf[1] <= {15'b0, run};"

echo
echo "=== mutants: $detected detected, $survived SURVIVED, $inconclusive inconclusive ==="
[ $((survived + inconclusive)) -eq 0 ] || exit 1
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
