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
# dffunmap, then `sat -seq N -set-init-zero -prove-asserts -verify`.
#
# TWO THINGS THIS FLOW LEARNED THE HARD WAY, both encoded below:
#   * `-set-init-zero` is REQUIRED. Without it the flip-flops' initial values
#     are unconstrained, so the solver can "start" a design mid-frame (e.g. the
#     TX engine already in S_FCS) and every safety property fails for reasons
#     that are harness artifacts, not defects. Three of the first four
#     "counterexamples" were exactly this.
#   * hierarchical references (dut.reg_od) do NOT become connections in yosys,
#     even under -flatten -- the same implicit-wire trap pe_ctrl's header
#     documents. A tap-based wrapper compares the DUT against NOISE and
#     produces a confident, meaningless FAIL. So these wrappers use REFERENCE
#     MODELS built from the observable ports, which also makes the claim
#     stronger (they assert equivalence, not just an invariant).
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
DEPTH="${FORMAL_DEPTH:-16}"   # fast subset; see the review for what each depth reaches
FULL=0
[ "${1:-}" = "--full" ] && { FULL=1; DEPTH="${FORMAL_DEPTH_FULL:-24}"; }

OUT="$ROOT/formal/results"
mkdir -p "$OUT"
pass=0; fail=0; skip=0
declare -a SUMMARY

# run_target <name> <top> <depth> <sources...>
run_target() {
  local name="$1" top="$2" depth="$3"; shift 3
  local log="$OUT/$name.log"
  printf '=== %-22s depth=%-3s ' "$name" "$depth"
  if ! yosys -p "
      read_verilog -formal -sv $*;
      prep -top $top -flatten;
      opt -full;
      clk2fflogic; async2sync; dffunmap;
      chformal -assume -early;
      sat -seq $depth -set-init-zero -prove-asserts -verify
    " > "$log" 2>&1; then
    # distinguish a real FAIL (counterexample) from a broken build
    if grep -q "SAT proof finished - no model found: SUCCESS" "$log"; then
      printf 'PROVED (bounded, %s)\n' "$depth"; pass=$((pass+1))
      SUMMARY+=("$name|PROVED|$depth")
    else
      printf 'COUNTEREXAMPLE (see %s)\n' "$log"; fail=$((fail+1))
      SUMMARY+=("$name|COUNTEREXAMPLE|$depth")
    fi
  elif grep -q "no model found: SUCCESS" "$log"; then
    printf 'PROVED (bounded, %s)\n' "$depth"; pass=$((pass+1))
    SUMMARY+=("$name|PROVED|$depth")
  else
    printf 'ERROR (see %s)\n' "$log"; fail=$((fail+1))
    SUMMARY+=("$name|ERROR|$depth")
  fi
}

echo "=== formal campaign (yosys $(yosys -V | head -1 | cut -d' ' -f2)), depth $DEPTH ==="
echo "--- target 1: pe_pinmux open-drain safety"
run_target pinmux_od_invariant formal_pe_pinmux "$DEPTH" \
  formal/pe_pinmux/formal_pe_pinmux.v rtl/pe_pinmux.v

echo "--- target 3: pe_eth_tx frame bounds / IFG / underrun"
run_target eth_tx_safety formal_pe_eth_tx "$DEPTH" \
  formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v

# Targets 2 (pe_ctrl R2 no-wrap / sticky RANGE / word-aligned serializer) and 4
# (pe_soc tx_path owner-mux exclusivity) are NOT proved. Their subjects are
# INTERNAL state (resp_len/resp_buf/faults/rstate; eth_tx_owner) and yosys does
# not resolve cross-module references into connections -- the exact implicit-wire
# trap pe_ctrl's header documents. Modelling the SPI transaction instead needs a
# synthesizable clock/delay engine, which yosys' frontend rejects outright
# (verified: the task-with-#delay wrapper fails to parse). Both need RTL
# observation points (`ifdef FORMAL` ports) before they can be proved, which is
# an RTL change and therefore the manager's call, not a worker's. See
# reviews/2026-09-25/FORMAL-VERIFICATION.md for the exact instrumentation each
# needs and the property it would unlock.
printf '%-24s %s\n' "pe_ctrl_r2 / soc_owner_mux" "NOT PROVED (needs RTL observation ports; see review)"

echo
echo "=== $pass proved, $fail counterexample/error, $skip skipped (depth $DEPTH) ==="
printf '%s\n' "${SUMMARY[@]:-}" > "$OUT/summary.txt"
[ "$fail" -eq 0 ] || exit 1
exit 0
