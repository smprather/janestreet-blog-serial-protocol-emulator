#!/usr/bin/env bash
# run_formal.sh — the formal verification campaign (reviews/2026-09-25/
# FORMAL-VERIFICATION.md).
#
#   bash formal/run_formal.sh            # the gate: every target, bounded depths
#   bash formal/run_formal.sh --full     # (kept for compatibility; same targets)
#
# TOOLCHAIN, in one place: every proof runs through formal/fv_run.sh, which
# owns the yosys flags, the -set-assumes fix, the memory cap (ulimit -v) and the
# one-yosys-at-a-time flock. Do not run yosys directly for a campaign proof.
#
# TWO PROOF SHAPES:
#   bmc     `sat -seq N` — bounded; the depth is the strength, and a claim that
#           cannot be REACHED at N is VACUOUS there (labelled by the reach
#           targets and by the mutant checks, never silently trusted).
#   induct  `sat -tempinduct` — UNBOUNDED (base case + induction step). This is
#           the shape the manager's 2026-09-25 ruling directs for claims that a
#           frame engine makes deep: a cap-kill on a deep BMC is a STRATEGY
#           SIGNAL, not a reason to retry deeper.
#
# THREE OUTCOMES PER TARGET, reported honestly:
#   prove   PROVED is the pass; COUNTEREXAMPLE / NOTPROVED / ERROR is a failure.
#   reach   the claim is INVERTED (assert the state is never reached):
#           a model = REACHABLE (the corresponding assertion is live here),
#           a proof = VACUOUS at this depth. Informational, never a pass.
#   refute  a claim the RTL is EXPECTED to violate (a recorded FINDING):
#           NOTPROVED / COUNTEREXAMPLE = the finding is confirmed; PROVED = the
#           finding would be closed (informational).
#
# Peak RSS per run is recorded in formal/results/summary.txt: the memory ceiling
# and every run's peak are part of the evidence.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
DEPTH="${FORMAL_DEPTH:-16}"
[ "${1:-}" = "--full" ] && DEPTH="${FORMAL_DEPTH_FULL:-24}"

OUT="$ROOT/formal/results"
mkdir -p "$OUT"
pass=0; fail=0; live=0; vacuous=0; findings=0
declare -a SUMMARY

# What the run's memory story actually was. yosys prints "MEM: x MB peak" in its
# end-of-script line, so a log WITHOUT that line is a run that did not finish --
# and the reason matters, because the old label claimed "MEMCAP" on no evidence
# at all. A proof killed by the cap, one killed by a timeout and one killed by
# the OOM killer all look the same in the log, so the label says only what the
# log shows:
#   * the MEM line            -> the number
#   * "model found", no end   -> killed WHILE PRINTING the counterexample model
#   * otherwise, no end       -> killed before the end of the script
# Claiming a cause the log cannot support is how a memory problem gets
# misdiagnosed as a cap problem, so it is not claimed.
peak_of() {
  local p
  p=$(grep -oE "MEM: [0-9.]+ MB peak" "$1" 2>/dev/null | tail -1)
  if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
  if grep -q "^End of script\." "$1" 2>/dev/null; then
    printf '%s' "no-MEM-line (end of script, but no MEM line?)"
  elif grep -q "model found" "$1" 2>/dev/null; then
    printf '%s' "no-MEM-line (killed while printing the model)"
  else
    printf '%s' "no-MEM-line (killed before end of script)"
  fi
}

# run_target <name> <top> <depth> <mode> <sources...>
run_target() {
  local name="$1" top="$2" depth="$3" mode="$4"; shift 4
  local log="$OUT/$name.log"
  local shape="${FORMAL_SAT_MODE:-bmc}"
  printf '=== %-26s depth=%-4s shape=%-6s ' "$name" "$depth" "$shape"
  local res
  res=$(bash formal/fv_run.sh "$log" "$top" "$depth" "$@")
  local peak; peak=$(peak_of "$log")
  case "$mode:$res" in
    prove:PROVED)
      printf 'PROVED\n'; pass=$((pass+1))
      SUMMARY+=("$name|PROVED|$depth|$shape|$peak") ;;
    prove:COUNTEREXAMPLE)
      printf 'COUNTEREXAMPLE (see %s)\n' "$log"; fail=$((fail+1))
      SUMMARY+=("$name|COUNTEREXAMPLE|$depth|$shape|$peak") ;;
    prove:NOTPROVED)
      printf 'NOT PROVED (the claim set did not close; see %s)\n' "$log"; fail=$((fail+1))
      SUMMARY+=("$name|NOTPROVED|$depth|$shape|$peak") ;;
    prove:*)
      printf 'ERROR (see %s)\n' "$log"; fail=$((fail+1))
      SUMMARY+=("$name|ERROR|$depth|$shape|$peak") ;;
    reach:COUNTEREXAMPLE)
      printf 'REACHABLE (claim live here)\n'; live=$((live+1))
      SUMMARY+=("$name|REACHABLE|$depth|$shape|$peak") ;;
    reach:PROVED)
      printf 'VACUOUS at this depth\n'; vacuous=$((vacuous+1))
      SUMMARY+=("$name|VACUOUS|$depth|$shape|$peak") ;;
    reach:*)
      printf 'ERROR (see %s)\n' "$log"; fail=$((fail+1))
      SUMMARY+=("$name|ERROR|$depth|$shape|$peak") ;;
    refute:PROVED)
      printf 'CLAIM HOLDS (the finding would be closed)\n'
      SUMMARY+=("$name|HOLDS|$depth|$shape|$peak") ;;
    refute:COUNTEREXAMPLE)
      printf 'REFUTED with a witness (finding confirmed)\n'; findings=$((findings+1))
      SUMMARY+=("$name|REFUTED-WITNESS|$depth|$shape|$peak") ;;
    refute:NOTPROVED)
      printf 'REFUTED (finding confirmed: the transition permits it)\n'; findings=$((findings+1))
      SUMMARY+=("$name|REFUTED|$depth|$shape|$peak") ;;
    refute:*)
      printf 'ERROR (see %s)\n' "$log"; fail=$((fail+1))
      SUMMARY+=("$name|ERROR|$depth|$shape|$peak") ;;
  esac
}

echo "=== formal campaign (yosys $(yosys -V | head -1 | cut -d' ' -f2)) — see the review for per-claim status ==="

echo "--- target 1: pe_pinmux open-drain safety"
run_target pinmux_od_invariant formal_pe_pinmux "$DEPTH" prove \
  formal/pe_pinmux/formal_pe_pinmux.v rtl/pe_pinmux.v

echo "--- target 3: pe_eth_tx frame bounds / underrun (P1a/P1b/P3), + vacuity labels"
run_target eth_tx_safety formal_pe_eth_tx "$DEPTH" prove \
  formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v
for sel in 0 1; do
  case $sel in
    0) label="reach_busy" ;;
    1) label="reach_tx_done" ;;
  esac
  run_target "eth_tx_$label" formal_pe_eth_tx_reach "$DEPTH" reach \
    -DREACH_SEL=$sel formal/pe_eth_tx/formal_pe_eth_tx_reach.v rtl/pe_eth_tx.v rtl/pe_crc.v
done

echo "--- target 3b: the IFG floor, INDUCTIVELY (unbounded)"
FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX="${FORMAL_INDUCT_MAX:-6}" \
  run_target eth_tx_ifg_floor formal_pe_eth_tx_ifg 1 prove \
  formal/pe_eth_tx/formal_pe_eth_tx_ifg.v rtl/pe_eth_tx.v rtl/pe_crc.v
unset FORMAL_SAT_MODE FORMAL_INDUCT_MAX

echo "--- target 2 + R3: pe_ctrl (R2 read claims; R3 hit/hold/state/bound)"
run_target pe_ctrl_r2 formal_pe_ctrl "$DEPTH" prove \
  formal/pe_ctrl/formal_pe_ctrl.v rtl/pe_ctrl.v
echo "    (the inductive subset: the claims that close by k-induction; the rest"
echo "     are gate-depth only and are labelled as such in the review)"
FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX="${FORMAL_INDUCT_MAX:-6}" \
  run_target pe_ctrl_r2_induct formal_pe_ctrl 1 prove \
  -DFV_INDUCT formal/pe_ctrl/formal_pe_ctrl.v rtl/pe_ctrl.v
unset FORMAL_SAT_MODE FORMAL_INDUCT_MAX

echo "--- R3 debug control: the core's hold/step invariants (UNBOUNDED)"
FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX="${FORMAL_INDUCT_MAX:-8}" \
  run_target pe_cpu_debug_hold formal_pe_cpu 1 prove \
  formal/pe_cpu/formal_pe_cpu.v rtl/pe_cpu.v
unset FORMAL_SAT_MODE FORMAL_INDUCT_MAX

echo "--- target 4: pe_soc owner-mux exclusivity"
SRAM_STUB="formal/pe_soc/sram_model_formal.v"
SOC_RTL="rtl/pe_soc.v rtl/pe_eth_tx.v rtl/pe_serdes.v rtl/pe_nrzi.v rtl/pe_bitstuff.v \
         rtl/pe_codec_mux.v rtl/pe_manch.v rtl/pe_dru.v rtl/pe_crc.v rtl/pe_fbuf.v \
         rtl/pe_cpu.v rtl/pe_imem.v rtl/pe_eth_mac.v rtl/pe_pinmux.v"
# C1 (the clear-side guard) is UNBOUNDED. C2 (the set-side guard, finding F2's
# fix) is stated and gate-depth checked, but not inductive on this toolchain --
# see the label in formal_pe_soc.v. F2's enforcement evidence is the directed TB
# case + its mutation in regress/mutate_eth_tx_loop_tb.sh.
FORMAL_MEMORY_MAP=1 run_target pe_soc_owner_gate_depth formal_pe_soc "$DEPTH" prove \
  formal/pe_soc/formal_pe_soc.v $SRAM_STUB $SOC_RTL
FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX="${FORMAL_INDUCT_MAX:-3}" FORMAL_MEMORY_MAP=1 \
  run_target pe_soc_owner_guard formal_pe_soc 1 prove \
  -DFV_INDUCT formal/pe_soc/formal_pe_soc.v $SRAM_STUB $SOC_RTL
unset FORMAL_SAT_MODE FORMAL_INDUCT_MAX FORMAL_MEMORY_MAP

echo
echo "=== $pass proved, $fail failed, $live reachable-at-depth, $vacuous vacuous-at-depth, $findings findings confirmed ==="
{
  printf 'name|result|depth|shape|peak_rss\n'
  printf '%s\n' "${SUMMARY[@]:-}"
} > "$OUT/summary.txt"
[ "$fail" -eq 0 ] || exit 1
exit 0
