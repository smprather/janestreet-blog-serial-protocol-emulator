#!/usr/bin/env bash
# run_sta.sh — regenerate the mapped STA hold-attribution screens.
#
# Run from the repo root:
#   bash reviews/2026-09-24/serdes-sta/run_sta.sh
#
# It synthesises all three screened designs with the synth-*.ys scripts
# (pe_soc, tt_um_protocol_emulator, pe_ctrl) and then runs OpenSTA for
# slow/typ/fast at 16.667 ns in BOTH constraint variants:
#
#   zero  : sta-<design>-<corner>.tcl       -> sta-<design>-<corner>.txt
#   board : sta-<design>-<corner>-board.tcl -> sta-<design>-<corner>-board.txt
#
# The two variants differ ONLY in the min input/output delay screening
# assumption: 0 ns (recorded Task-4 screen) vs the 1.0 ns board-level
# assumption. Both are kept so nothing is hidden and both are re-runnable.
# Every report ends with a full "NEGATIVE-MIN INVENTORY" block
# (report_checks -path_delay min -slack_max 0 -format summary) that
# analyze_hold.py classifies. See
# reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md.
#
# Mapped screens only: no placement, routing, DRC or LVS is involved.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DIR="$ROOT/reviews/2026-09-24/serdes-sta"
cd "$ROOT" || exit 1

rc=0
for design in pe_soc tt_um pe_ctrl; do
  echo "--- yosys: $design"
  if ! yosys -s "$DIR/synth-$design.ys" > "$DIR/synth-$design.log" 2>&1; then
    echo "yosys FAILED for $design (see synth-$design.log)"; rc=1; continue
  fi
  if [ ! -s "$DIR/mapped-$design.v" ]; then
    echo "yosys produced no mapped-$design.v (see synth-$design.log)"; rc=1; continue
  fi
  for corner in slow typ fast; do
    for variant in "" "-board"; do
      out="sta-$design-$corner$variant.txt"
      echo "--- sta: $design/$corner$variant -> $out"
      ( cd "$DIR" && sta "sta-$design-$corner$variant.tcl" > "$out" 2>&1 )
      if ! grep -q "worst slack" "$DIR/$out"; then
        echo "sta FAILED for $design/$corner$variant"; rc=1
      fi
    done
  done
done
exit $rc
