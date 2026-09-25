#!/usr/bin/env bash
# check_formal_ifdef.sh — THE GATE: `ifdef FORMAL` may never be defined on a
# synthesis path (manager ruling 2026-09-25, when the observation ports for
# targets 2 and 4 were approved: "must compile out of every synthesis and
# regression path; add a gate/lint check that FORMAL is never defined during
# synthesis").
#
# WHY A CHECK AND NOT A CONVENTION. The formal taps in rtl/pe_ctrl.v,
# rtl/pe_eth_tx.v and rtl/pe_soc.v add ports and (in pe_ctrl) two 1-cycle
# observation registers. They are harmless under `ifdef FORMAL` -- and a silent
# area/behaviour change the moment anything defines that macro on a synthesis or
# simulation path. A convention would be forgotten; this gate fails loudly.
#
# THREE CHECKS, because "the macro is not defined" is not directly observable:
#   1. no build/regression/synthesis script may pass -DFORMAL or -formal
#      (the yosys frontend's own `-formal` flag is what defines FORMAL);
#   2. a REAL elaboration with synthesis flags must contain no fv_* port or
#      wire -- the taps must vanish, not merely be ignored;
#   3. the guarded regions are listed, so the audit trail names what is at stake.
#
# Usage: tools/check_formal_ifdef.sh    (exit 0 = clean)
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 2
rc=0

echo "--- formal-ifdef gate: FORMAL must never be defined on a synthesis path"

# ---- 1. nobody defines it --------------------------------------------------
hits=$(grep -rnE -- "-DFORMAL|-dformal|-formal\b" \
        regress/ tools/ flow/ sim/ 2>/dev/null \
      | grep -v "tools/check_formal_ifdef.sh" \
      | grep -v "formal/" || true)
if [ -n "$hits" ]; then
  echo "FAIL: a build/regression script defines FORMAL (or passes yosys -formal):"
  printf '%s\n' "$hits" | sed 's/^/    /'
  rc=1
else
  echo "  OK   no build/regression script defines FORMAL"
fi

# ---- 2. the taps vanish in a real elaboration ------------------------------
# `read_verilog` WITHOUT -formal is exactly the synthesis frontend call
# (regress/synth_area.sh uses the same), so this is the synthesis view.
if yosys -p "
      read_verilog -sv rtl/*.v;
      hierarchy -top tt_um_protocol_emulator;
      proc; opt -fast;
      select -count w:fv_*;
    " > /tmp/check_formal_ifdef.log 2>&1; then
  count=$(grep -oE "^[0-9]+ objects" /tmp/check_formal_ifdef.log | tail -1 | awk '{print $1}')
  if [ "${count:-1}" = "0" ]; then
    echo "  OK   0 fv_* wires in a synthesis elaboration (taps compiled out)"
  else
    echo "FAIL: ${count} fv_* wires exist without FORMAL defined -- the taps leak"
    rc=1
  fi
else
  echo "FAIL: the synthesis elaboration did not complete (see /tmp/check_formal_ifdef.log)"
  tail -5 /tmp/check_formal_ifdef.log | sed 's/^/    /'
  rc=1
fi

# ---- 3. name the guarded regions (audit trail) -----------------------------
echo "  guarded regions (inert unless FORMAL is defined):"
grep -rn "ifdef FORMAL" rtl/ | sed 's/^/    /'

exit "$rc"
