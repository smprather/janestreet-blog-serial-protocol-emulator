#!/usr/bin/env bash
# mutants.sh — NON-VACUITY EVIDENCE for the formal campaign. Every proof must
# kill the mutant that attacks its claim:
#
#     a property that does not kill its mutant is not a proof.
#
# A proof can pass for the wrong reason: the state it is about may be
# unreachable at the proved depth (the campaign's 3b finding), or the shadow it
# compares against may be blind to the defect it claims to pin (the 3a finding).
# A mutant that removes the guarded behavior MUST make the property FAIL; that
# failure is the evidence that the property is looking at the real behavior.
# Every mutant below is expected to be CAUGHT at the stated depth. Where a
# claim is known to be vacuous at the gate depth, the case declares it and says
# so out loud instead of reporting a green run -- `--deep` runs those too.
#
#   bash formal/mutants.sh          # gate depth, every mutant expected caught
#   bash formal/mutants.sh --deep   # + the deep cases (minutes to hours)
#
# RESTORE DISCIPLINE (the repo's mutation-harness rules, regress/mutate_*.sh):
# pristine snapshot, per-case restore, cmp verification against the snapshot
# (never against git), and a trap that restores on EXIT/INT/TERM, because an
# interrupted harness that leaves mutated RTL poisons every later run. The
# single-run lock is taken for the same reason the regress harnesses take it:
# this worktree is shared.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
# shellcheck source=regress/run_lock.sh
. "$REPO/regress/run_lock.sh"
chip_take_run_lock "formal/mutants.sh"

DEEP=0
[ "${1:-}" = "--deep" ] && DEEP=1

GATE_DEPTH="${FORMAL_DEPTH:-16}"     # must match run_formal.sh's fast depth
DEEP_DEPTH="${FORMAL_DEPTH_DEEP:-700}"
OUT="$REPO/formal/results"
mkdir -p "$OUT"

# Every file any mutation may touch, for the snapshot/restore.
MUTABLE="rtl/pe_pinmux.v rtl/pe_eth_tx.v formal/pe_eth_tx/formal_pe_eth_tx.v"

PRISTINE=$(mktemp -d)
for f in $MUTABLE; do cp "$f" "$PRISTINE/$(basename "$f")"; done

restore_pristine() {
  for f in $MUTABLE; do
    [ -f "$PRISTINE/$(basename "$f")" ] && cp "$PRISTINE/$(basename "$f")" "$f"
  done
  return 0
}
cleanup() { restore_pristine; rm -rf "$PRISTINE"; chip_release_run_lock; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

# restore_and_verify: put the pristine bytes back, then check them byte-exact,
# per case. A harness that fails to restore leaves a mutant on disk and every
# later test measures it; that happened for real on 2026-09-24 (an unrestored
# mutate_i2c_tb m1). Restoring first is the whole point: checking before the
# restore reported a false failure on this script's first run.
restore_and_verify() {
  restore_pristine
  local bad=0
  for f in $MUTABLE; do
    if ! cmp -s "$PRISTINE/$(basename "$f")" "$f"; then
      echo "  RESTORE FAILED -- $f differs from the pristine snapshot"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ] || { echo "  refusing to continue: later results would measure the mutant"; exit 3; }
}

detected=0; survived=0; expected_survive=0; inconclusive=0; unexpected=0

# fv_case <name> <expect> <depth> <top> <sources...>
#   expect = caught    the mutant must produce a COUNTEREXAMPLE
#   expect = vacuous   the claim is known unreachable at this depth, so the
#                      mutant legitimately survives; reported, not counted as a
#                      pass of the property (it is exactly the finding)
fv_case() {
  local name="$1" expect="$2" depth="$3" top="$4"; shift 4
  local log="$OUT/mutant_$name.log"
  printf '=== mutant %-22s depth=%-4s ' "$name" "$depth"
  local res
  res=$(bash formal/fv_run.sh "$log" "$top" "$depth" "$@")
  case "$res:$expect" in
    ERROR:*) echo "INCONCLUSIVE (build/solver error -- see $log)"; inconclusive=$((inconclusive+1)) ;;
    COUNTEREXAMPLE:caught)  echo "CAUGHT (property FAILS on the mutated design -- evidence it is live)"; detected=$((detected+1)) ;;
    PROVED:caught)          echo "SURVIVED -- the mutant is NOT killed: this property is a blind spot"; survived=$((survived+1)) ;;
    PROVED:vacuous)         echo "survives AS LABELLED (claim vacuous at this depth -- see the vacuity targets)"; expected_survive=$((expected_survive+1)) ;;
    COUNTEREXAMPLE:vacuous) echo "CAUGHT EARLIER THAN EXPECTED (good news -- the depth estimate was pessimistic)"; detected=$((detected+1)) ;;
    *) echo "UNEXPECTED ($res)"; unexpected=$((unexpected+1)) ;;
  esac
}

# apply_mutation <python-file> -> 0 applied, non-zero if the pattern was absent.
apply_mutation() {
  python3 "$1" || { echo "  MUTATION DID NOT APPLY -- pattern absent (INCONCLUSIVE)"; return 1; }
  return 0
}

TMP=$(mktemp -d)

# ---------------------------------------------------------------- 1. pinmux
# The real 2026-09-24 defect: pad_oe ignores the open-drain term, so a pin in
# open-drain mode CAN drive high. Target 1 must catch it (it did in the first
# campaign; this reruns it under the -set-assumes flow).
cat > "$TMP/m1.py" <<'PY'
import pathlib, re, sys
p = pathlib.Path('rtl/pe_pinmux.v'); t = p.read_text()
m = re.search(r'assign\s+pad_oe\s*=\s*([^;]+);', t)
if not m: sys.exit("no pad_oe assignment found")
print(f"  pad_oe: {m.group(1).strip()!r} -> 'reg_oe' (od term removed)")
p.write_text(t[:m.start()] + "assign pad_oe  = reg_oe;" + t[m.end():])
PY
if apply_mutation "$TMP/m1.py"; then
  fv_case pinmux_od_m1 caught "$GATE_DEPTH" formal_pe_pinmux \
    formal/pe_pinmux/formal_pe_pinmux.v rtl/pe_pinmux.v
  restore_and_verify
fi

# ---------------------------------------------------------------- 2. runt
# len_ok loses its lower bound: frame_len < 14 is accepted. The runt/jabber
# guard is the claim; P1a must fail at the apply edge (shallow -- this is the
# gap the first campaign left open, where the runt mutant survived at depth 240).
cat > "$TMP/runt.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_eth_tx.v'); t = p.read_text()
if "(frame_len >= 12'd14)" not in t: sys.exit("no lower bound found")
print("  len_ok: lower bound 14 -> 0 (runt accepted)")
p.write_text(t.replace("(frame_len >= 12'd14)", "(frame_len >= 12'd0)"))
PY
if apply_mutation "$TMP/runt.py"; then
  fv_case eth_tx_runt caught "$GATE_DEPTH" formal_pe_eth_tx \
    formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v
  restore_and_verify
fi

# ---------------------------------------------------------------- 3. jabber
# len_ok loses its upper bound: frame_len > MAX_STORED is accepted.
cat > "$TMP/jabber.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_eth_tx.v'); t = p.read_text()
if "(frame_len <= 12'(MAX_STORED))" not in t: sys.exit("no upper bound found")
print("  len_ok: upper bound MAX_STORED -> 4095 (jabber accepted)")
p.write_text(t.replace("(frame_len <= 12'(MAX_STORED))", "(frame_len <= 12'd4095)"))
PY
if apply_mutation "$TMP/jabber.py"; then
  fv_case eth_tx_jabber caught "$GATE_DEPTH" formal_pe_eth_tx \
    formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v
  restore_and_verify
fi

# ------------------------------------------------------ 4. the TXLEN window
# This mutant does NOT touch the RTL: it removes the TXLEN hold assumption from
# the wrapper. The property must then FAIL on the unmodified design, which is
# the machine-checked form of the recorded finding ("the guard is a start-pulse
# check against a boundary-time latch"). If this case ever starts passing
# (i.e. the property holds WITH the assumption removed), the assumption is
# redundant and should be deleted -- a proof should not carry decoration.
cat > "$TMP/window.py" <<'PY'
import pathlib, sys
p = pathlib.Path('formal/pe_eth_tx/formal_pe_eth_tx.v'); t = p.read_text()
needle = "    if (rst_n && hold) assume (frame_len == hold_len);"
if needle not in t: sys.exit("no TXLEN hold assumption found")
print("  wrapper: TXLEN hold assumption removed (must now FAIL on clean RTL)")
p.write_text(t.replace(needle, "    // assumption removed by formal/mutants.sh"))
PY
if apply_mutation "$TMP/window.py"; then
  fv_case eth_tx_len_window caught "$GATE_DEPTH" formal_pe_eth_tx \
    formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v
  restore_and_verify
fi

# ------------------------------------------------------------- 5. IFG floor
# The gap is shortened to 90 cells. At the gate depth the claim cannot even be
# reached (a frame needs ~576 cells and the gap closes at ~672), so the mutant
# legitimately survives -- that is a LABEL, reported as such. --deep runs it at
# the depth where the claim becomes live; it must then be CAUGHT.
cat > "$TMP/ifg90.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_eth_tx.v'); t = p.read_text()
if "if (ifg_cnt == 7'd95)" not in t: sys.exit("no ifg terminal count found")
print("  ifg_cnt terminal 95 -> 89 (gap 96 cells -> 90)")
p.write_text(t.replace("if (ifg_cnt == 7'd95)", "if (ifg_cnt == 7'd89)"))
PY
if apply_mutation "$TMP/ifg90.py"; then
  fv_case eth_tx_ifg90 vacuous "$GATE_DEPTH" formal_pe_eth_tx \
    formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v
  restore_and_verify
  if [ "$DEEP" -eq 1 ]; then
    # baseonly is the fast path for large bounds (yosys sat's own hint): it
    # checks the base case step by step instead of one unrolled instance.
    if apply_mutation "$TMP/ifg90.py"; then
      printf '=== mutant %-22s depth=%-4s ' "eth_tx_ifg90_deep" "$DEEP_DEPTH"
      if timeout "${FORMAL_DEEP_TIMEOUT:-5400}" yosys -p "
          read_verilog -formal -sv formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v;
          prep -top formal_pe_eth_tx -flatten;
          opt -full; clk2fflogic; async2sync; dffunmap;
          chformal -assume -early;
          sat -tempinduct-baseonly -maxsteps $DEEP_DEPTH -set-init-zero -set-assumes -prove-asserts -verify
        " > "$OUT/mutant_eth_tx_ifg90_deep.log" 2>&1; then
        echo "INCONCLUSIVE/timeout (see $OUT/mutant_eth_tx_ifg90_deep.log)"; inconclusive=$((inconclusive+1))
      elif grep -q "model found: FAIL" "$OUT/mutant_eth_tx_ifg90_deep.log"; then
        echo "CAUGHT (the gap floor is a real proof at this depth)"; detected=$((detected+1))
      elif grep -q "no model found: SUCCESS" "$OUT/mutant_eth_tx_ifg90_deep.log"; then
        echo "SURVIVED even at depth $DEEP_DEPTH -- the claim is VACUOUS even there"; survived=$((survived+1))
      else
        echo "INCONCLUSIVE (see $OUT/mutant_eth_tx_ifg90_deep.log)"; inconclusive=$((inconclusive+1))
      fi
      restore_and_verify
    fi
  fi
fi

rm -rf "$TMP"
echo
echo "=== mutants: $detected caught, $survived SURVIVED (blind spots), $expected_survive survived-as-labelled, $inconclusive inconclusive, $unexpected unexpected ==="
printf 'pinmux_od_m1|eth_tx_runt|eth_tx_jabber|eth_tx_len_window|eth_tx_ifg90(gate=labelled-vacuous)\n' \
  > "$OUT/mutants.txt"
[ $((survived + inconclusive + unexpected)) -eq 0 ] || exit 1
exit 0
