#!/usr/bin/env bash
# mutate_codec_tb.sh — mutation-test tb_pe_codec_mux.v (the codec pipeline unit).
#
# WHY THIS EXISTS. The SERDES integration (STATUS item 7) instantiated
# pe_codec_mux twice in pe_soc, but the codec pipeline itself had no mutation
# suite: the unit TB was the only evidence for the pipeline order, the bypass
# subsets, the CAN preset, the USB ones-only rule and the frame-boundary clr.
# A TB nobody fault-injects is a TB that can quietly stop testing. This harness
# injects a plausible defect for every behaviour the manager's closeout scope
# names and requires tb_pe_codec_mux to FAIL on each one:
#
#   CAN preset 0x51
#     1. can-default-run-wrong      — the default run length (cfg[6:4]==0 => 5)
#                                     is 6, so 0x01/0x51 never stuff after five.
#     2. can51-explicit-run-ignored — cfg[6:4] is ignored and every config runs
#                                     at length 5, so the USB run-6 config
#                                     stuffs one bit early.
#   ones_only / run-length
#     3. ones-only-ignored          — cfg[7] dropped: zero runs get stuffed.
#    12. stuff-run-off-by-one       — TX arms the stuff bit one run late.
#    13. rx-stuff-run-off-by-one    — RX flags the stuff slot one wire bit late.
#   frame-boundary clr (it reaches every stage)
#     4. stuff-clr-dropped          — run tracking survives a frame boundary.
#     5. nrzi-clr-dropped           — the line level does not return to idle J.
#     6. manch-clr-dropped          — a pending cell error survives clr.
#   registered clr / rx_err
#     7. manch-rx-err-combinational — rx_err goes back to the old unregistered
#                                     expression (the historical idle-line bug).
#    11. stuff-rx-err-never-set     — a non-complementary stuff bit is accepted.
#   pipeline order / bypass subsets / half_phase (the plan's codec scope)
#     8. nrzi-always-on             — enabling stuffing also enables NRZI.
#     9. rx-cascade-skips-nrzi      — the stuffer sees raw wire levels.
#    10. half-phase-inverted        — Manchester selects the wrong half-cell.
#
# RESTORE IS A FILE COPY verified with cmp after EVERY mutation (gotcha 63:
# a restore that silently fails stacks mutations and prints a meaningless
# perfect score). Four RTL files are snapshotted because three mutations live
# in the stage modules the mux composes.
set -u
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
FILES=(rtl/pe_codec_mux.v rtl/pe_bitstuff.v rtl/pe_nrzi.v rtl/pe_manch.v)
# MUTABLE — what this harness EDITS inside the repo. Read by
# regress/verify_merge.sh (the merge gate) to decide whether a narrowed gate
# has to run this suite, and by regress/check_mutation_lists.sh to prove the
# list still covers every file the harness writes. Evidence: the FILES=(...) array it already snapshots and restores.
# An EMPTY value means this suite mutates nothing in the repo and is therefore
# NEVER SKIPPED. A MISSING line is the opposite: unmappable, and the gate
# escalates to running every suite rather than guessing.
MUTABLE="rtl/pe_codec_mux.v rtl/pe_bitstuff.v rtl/pe_nrzi.v rtl/pe_manch.v"
LOG=/tmp/mutate_codec.log
CCLOG=/tmp/mutate_codec_cc.log

BAKDIR=$(mktemp -d /tmp/mutate_codec.XXXXXX)
cleanup() {
  # THE HARNESS-EDIT PRE-FLIGHT (regress/dep_guard.sh). Stamped when this
  # harness took the run lock; verified HERE, because this is the only place it
  # can be: the harness sets its own `trap cleanup EXIT` after sourcing
  # run_lock.sh, and a second EXIT trap replaces the first, so a check installed
  # over there would be silently discarded. If this script — or the lock helper it
  # sources — changed while we were running, bash's incremental read means our
  # verdict is untrustworthy in EITHER direction, so exit 4 (INCONCLUSIVE) rather
  # than report a possibly-false pass.
  chip_dep_check "run_$(basename "$0")" || exit 4
  for f in "${FILES[@]}"; do cp "$BAKDIR/$(basename "$f")" "$ROOT/$f" 2>/dev/null; done
  rm -rf "$BAKDIR"
}
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
for f in "${FILES[@]}"; do
  cp "$ROOT/$f" "$BAKDIR/" || { echo "FATAL: could not snapshot $f"; exit 2; }
done
for f in "${FILES[@]}"; do
  cmp -s "$ROOT/$f" "$BAKDIR/$(basename "$f")" || { echo "FATAL: snapshot mismatch $f"; exit 2; }
done

cd "$ROOT/sim"
SRCS="../rtl/pe_nrzi.v ../rtl/pe_manch.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v"

run_tb() {
  iverilog -g2012 -s tb_pe_codec_mux -o /tmp/mutate_codec.vvp \
    $SRCS ../tb/tb_pe_codec_mux.v >"$CCLOG" 2>&1 || return 2
  timeout 120 vvp /tmp/mutate_codec.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

restore() {
  for f in "${FILES[@]}"; do cp "$BAKDIR/$(basename "$f")" "$ROOT/$f"; done
chip_dep_expect pristine $MUTABLE
}
verify_restore() {
  for f in "${FILES[@]}"; do
    cmp -s "$BAKDIR/$(basename "$f")" "$ROOT/$f" || {
      echo "  FATAL: $f does not match the snapshot after restore."; exit 3; }
  done
}

mutate() {   # mutate <file> <anchor> <replacement>
  python3 - "$ROOT/$1" "$2" "$3" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
if sys.argv[2] not in t:
    sys.exit(4)
p.write_text(t.replace(sys.argv[2], sys.argv[3], 1))
PYEOF
}

pass=0; fail=0; survived=0

check_mutation() {   # check_mutation <name> <file> <anchor> <replacement>
  local name="$1" file="$2" anchor="$3" repl="$4"
  if ! mutate "$file" "$anchor" "$repl"; then
    echo "  [$name] HARNESS ERROR: anchor not found in $file"
    restore; verify_restore; fail=$((fail+1)); return
  fi
    chip_dep_expect mutated $MUTABLE
  run_tb
  local rc=$?
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected"; pass=$((pass+1))
  else                     echo "  [$name] HARNESS ERROR: vvp/compile exit $rc";
                           tail -5 "$CCLOG" "$LOG" 2>/dev/null; fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing tb_pe_codec_mux ==="
run_tb
rc=$?
if [ $rc -ne 0 ]; then
  echo "  FATAL: the TB does not pass on the clean design (exit $rc)"
  [ $rc -eq 2 ] && tail -5 "$CCLOG"
  exit 2
fi
echo "  [baseline] passes on the unmutated design"

# 1. Default run length (cfg[6:4]==0 => 5) becomes 6.
check_mutation "can-default-run-wrong" rtl/pe_codec_mux.v \
  "assign run_cfg  = (cfg[6:4] == 3'd0) ? 4'd5 : {1'b0, cfg[6:4]};" \
  "assign run_cfg  = (cfg[6:4] == 3'd0) ? 4'd6 : {1'b0, cfg[6:4]};   // MUTANT: default run 6"

# 2. The explicit cfg[6:4] run length is ignored (always 5).
check_mutation "can51-explicit-run-ignored" rtl/pe_codec_mux.v \
  "assign run_cfg  = (cfg[6:4] == 3'd0) ? 4'd5 : {1'b0, cfg[6:4]};" \
  "assign run_cfg  = 4'd5;   // MUTANT: cfg[6:4] ignored"

# 3. cfg[7] dropped: stuffing is symmetric, so zero runs are stuffed.
check_mutation "ones-only-ignored" rtl/pe_codec_mux.v \
  "assign ones_only = cfg[7];" \
  "assign ones_only = 1'b0;   // MUTANT: symmetric stuffing"

# 4. clr does not reach the stuffer: the run survives the frame boundary.
check_mutation "stuff-clr-dropped" rtl/pe_codec_mux.v \
  ".bypass(~stuff_en), .clr(clr), .run_cfg(run_cfg)," \
  ".bypass(~stuff_en), .clr(1'b0), .run_cfg(run_cfg),   // MUTANT: no frame clr"

# 5. clr does not reach the NRZI line level: no return to idle J.
check_mutation "nrzi-clr-dropped" rtl/pe_codec_mux.v \
  ".clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(~nrzi_en), .clr(clr)," \
  ".clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(~nrzi_en), .clr(1'b0),   // MUTANT: no frame clr"

# 6. clr does not reach Manchester: a pending cell error survives it.
check_mutation "manch-clr-dropped" rtl/pe_codec_mux.v \
  ".clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(~manch_en), .clr(clr)," \
  ".clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(~manch_en), .clr(1'b0),   // MUTANT: no frame clr"

# 7. Manchester rx_err goes back to the unregistered expression.
check_mutation "manch-rx-err-combinational" rtl/pe_manch.v \
  "  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     rx_err <= 1'b0;
    else if (clr)   rx_err <= 1'b0;
    else            rx_err <= bit_en && !bypass && (rx_first == rx_second);
  end" \
  "  always_comb begin
    rx_err = !bypass && (rx_first == rx_second);   // MUTANT: combinational
  end"

# 8. Enabling stuffing also enables NRZI (bypass subset wrong).
check_mutation "nrzi-always-on" rtl/pe_codec_mux.v \
  "assign nrzi_en  = cfg[1];" \
  "assign nrzi_en  = cfg[1] | cfg[0];   // MUTANT: NRZI on with stuff"

# 9. The RX cascade skips the NRZI decode: the stuffer sees raw levels.
check_mutation "rx-cascade-skips-nrzi" rtl/pe_codec_mux.v \
  ".rx_wire(n_rx_out), .rx_raw(rx_bit), .rx_raw_valid(rx_bit_valid)," \
  ".rx_wire(m_rx_out), .rx_raw(rx_bit), .rx_raw_valid(rx_bit_valid),   // MUTANT: skips NRZI"

# 10. Manchester selects the wrong half-cell.
check_mutation "half-phase-inverted" rtl/pe_codec_mux.v \
  ".half_phase(cfg[3])," \
  ".half_phase(~cfg[3]),   // MUTANT: inverted half phase"

# 11. A non-complementary stuff bit is accepted (rx_err never set).
check_mutation "stuff-rx-err-never-set" rtl/pe_bitstuff.v \
  "        if (rx_wire == rx_lvl) rx_err <= 1'b1;" \
  "        // MUTANT: violated stuff bit never sets rx_err"

# 12. The TX stuff bit is armed one run late.
check_mutation "stuff-run-off-by-one" rtl/pe_bitstuff.v \
  "        if (tx_run == run_cfg - 4'd1 && (tx_lvl == 1'b1 || !ones_only))" \
  "        if (tx_run == run_cfg && (tx_lvl == 1'b1 || !ones_only))   // MUTANT: late arm"

# 13. RX flags the stuff slot one wire bit late.
check_mutation "rx-stuff-run-off-by-one" rtl/pe_bitstuff.v \
  "  assign rx_is_stuff  = !bypass && (rx_run == run_cfg) &&" \
  "  assign rx_is_stuff  = !bypass && (rx_run == run_cfg - 4'd1) &&   // MUTANT: early slot"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
[ $survived -gt 0 ] && { echo "SURVIVORS: the TB does not test what it claims."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every codec-pipeline mutation is detected by tb_pe_codec_mux."
exit 0
