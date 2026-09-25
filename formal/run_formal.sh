#!/usr/bin/env bash
# run_formal.sh — the formal verification campaign (reviews/2026-09-25/
# FORMAL-VERIFICATION.md).
#
#   bash formal/run_formal.sh            # the fast subset (also in run_all)
#   bash formal/run_formal.sh --full     # every target, deeper
#
# TOOLCHAIN (documented, because the usual one is absent here). SymbiYosys is
# NOT installed and pip refuses to install it (no virtualenv on this host), and
# there is NO SMT solver on the system at all (boolector/yices/z3/cvc* all
# absent), so sby could not have run even if installed. We therefore use yosys'
# BUILT-IN `sat` engine: read_verilog -formal, prep, clk2fflogic, async2sync,
# dffunmap, then `sat -seq N -set-init-zero -set-assumes -prove-asserts -verify`.
#
# FOUR THINGS THIS FLOW LEARNED THE HARD WAY, all encoded below:
#   * `-set-init-zero` is REQUIRED. Without it the flip-flops' initial values
#     are unconstrained, so the solver can "start" a design mid-frame (e.g. the
#     TX engine already in S_FCS, tx_done high) and every safety property fails
#     for reasons that are harness artifacts, not defects.
#   * `-set-assumes` is REQUIRED FOR ANY ASSUMPTION TO EXIST AT ALL. `sat`
#     ignores $assume cells unless it is passed; without it the reset-discipline
#     assume (and every contract assumption) is decoration. Found while
#     debugging an assumption that provably was not constraining the solver
#     (a minimal design proved FAIL with `assume(1'b0)` in force). The earlier
#     campaign's proofs ran without it; every result here is with it.
#   * hierarchical references (dut.reg_od) do NOT become connections in yosys,
#     even under -flatten -- the same implicit-wire trap pe_ctrl's header
#     documents. A tap-based wrapper compares the DUT against NOISE and
#     produces a confident, meaningless FAIL. So the wrappers use REFERENCE
#     MODELS built from the observable ports (or, where the subject is internal
#     state, the guarded `ifdef FORMAL` observation ports the manager approved) --
#     never an unguarded hierarchical tap.
#   * VACUITY IS PART OF THE RESULT. `sat` cannot model $cover cells on this
#     build, so each target with a deep-only claim has a companion
#     reachability target that asserts the state is NEVER reached: a model
#     means the state is reachable (the claim is live), a proof means the
#     claim is VACUOUS at that depth. Those labels are printed, not hidden.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
DEPTH="${FORMAL_DEPTH:-16}"   # fast subset; see the review for what each depth reaches
[ "${1:-}" = "--full" ] && DEPTH="${FORMAL_DEPTH_FULL:-240}"

OUT="$ROOT/formal/results"
mkdir -p "$OUT"
pass=0; fail=0; live=0; vacuous=0
declare -a SUMMARY

# run_target <name> <top> <depth> <mode> <sources...>
#   mode = prove  : expect a proof; FAIL exits non-zero
#   mode = reach  : invert the claim (assert the state is NEVER reached);
#                   a model is the interesting outcome and is reported as
#                   REACHABLE (claim live), a proof as UNREACHABLE (vacuous)
run_target() {
  local name="$1" top="$2" depth="$3" mode="$4"; shift 4
  local log="$OUT/$name.log"
  printf '=== %-24s depth=%-4s ' "$name" "$depth"
  local res
  res=$(bash formal/fv_run.sh "$log" "$top" "$depth" "$@")
  case "$res" in
    PROVED)
      if [ "$mode" = reach ]; then
        printf 'UNREACHABLE (claim vacuous at this depth)\n'; vacuous=$((vacuous+1))
        SUMMARY+=("$name|UNREACHABLE|$depth|vacuous at this depth")
      else
        printf 'PROVED (bounded, %s)\n' "$depth"; pass=$((pass+1))
        SUMMARY+=("$name|PROVED|$depth|live")
      fi ;;
    COUNTEREXAMPLE)
      if [ "$mode" = reach ]; then
        printf 'REACHABLE (claim live here; witness in %s)\n' "$log"; live=$((live+1))
        SUMMARY+=("$name|REACHABLE|$depth|live")
      else
        printf 'COUNTEREXAMPLE (see %s)\n' "$log"; fail=$((fail+1))
        SUMMARY+=("$name|COUNTEREXAMPLE|$depth|FAILED")
      fi ;;
    *)
      printf 'ERROR (see %s)\n' "$log"; fail=$((fail+1))
      SUMMARY+=("$name|ERROR|$depth|build/solver error") ;;
  esac
}

echo "=== formal campaign (yosys $(yosys -V | head -1 | cut -d' ' -f2)), depth $DEPTH ==="
echo "--- target 1: pe_pinmux open-drain safety"
run_target pinmux_od_invariant formal_pe_pinmux "$DEPTH" prove \
  formal/pe_pinmux/formal_pe_pinmux.v rtl/pe_pinmux.v

echo "--- target 3: pe_eth_tx frame bounds / IFG / underrun"
run_target eth_tx_safety formal_pe_eth_tx "$DEPTH" prove \
  formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v

echo "--- vacuity labels for target 3 (what the proof above actually reached)"
for sel in 0 1 2 3; do
  case $sel in
    0) label="reach_busy" ;;
    1) label="reach_tx_done" ;;
    2) label="reach_ifg_active" ;;
    3) label="reach_ifg_close" ;;
  esac
  run_target "eth_tx_$label" formal_pe_eth_tx_reach "$DEPTH" reach \
    -DREACH_SEL=$sel formal/pe_eth_tx/formal_pe_eth_tx_reach.v rtl/pe_eth_tx.v rtl/pe_crc.v
done

echo "--- target 2: pe_ctrl R2 (no wrap / sticky RANGE / word-aligned serializer)"
if [ -f formal/pe_ctrl/formal_pe_ctrl.v ]; then
  run_target pe_ctrl_r2 formal_pe_ctrl "$DEPTH" prove \
    formal/pe_ctrl/formal_pe_ctrl.v rtl/pe_ctrl.v
else
  printf '%-24s %s\n' "pe_ctrl_r2" "MISSING WRAPPER (formal/pe_ctrl/formal_pe_ctrl.v)"
  SUMMARY+=("pe_ctrl_r2|MISSING|$DEPTH|wrapper absent")
fi

echo "--- target 4: pe_soc tx_path owner-mux exclusivity"
if [ -f formal/pe_soc/formal_pe_soc.v ]; then
  run_target pe_soc_owner_mux formal_pe_soc "$DEPTH" prove \
    formal/pe_soc/formal_pe_soc.v rtl/pe_soc.v rtl/pe_eth_tx.v rtl/pe_serdes.v \
    rtl/pe_nrzi.v rtl/pe_bitstuff.v rtl/pe_codec_mux.v rtl/pe_manch.v \
    rtl/pe_dru.v rtl/pe_crc.v rtl/pe_fbuf.v rtl/pe_cpu.v rtl/pe_imem.v
else
  printf '%-24s %s\n' "pe_soc_owner_mux" "MISSING WRAPPER (formal/pe_soc/formal_pe_soc.v)"
  SUMMARY+=("pe_soc_owner_mux|MISSING|$DEPTH|wrapper absent")
fi

echo
echo "=== $pass proved, $fail counterexample/error, $live live-at-depth, $vacuous vacuous-at-depth (depth $DEPTH) ==="
printf '%s\n' "${SUMMARY[@]:-}" > "$OUT/summary.txt"
[ "$fail" -eq 0 ] || exit 1
exit 0
