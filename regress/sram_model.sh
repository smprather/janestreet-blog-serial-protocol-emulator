#!/usr/bin/env bash
# sram_model.sh — locate the IHP SRAM behavioural model, or fail loudly.
#
# WHY THIS IS A SCRIPT AND NOT A PATH IN run_all.sh
#
# The SRAM macro is a hard macro: no gates, fixed geometry, supplied as GDS. To
# SIMULATE a design that instantiates it you need the PDK's behavioural model,
# which lives outside the repo. If that model is missing, the tempting fallback
# is pe_imem's FLOP=1 register array -- and a testbench that silently runs against
# the fallback has verified nothing about the memory. So: missing PDK model is a
# LOUD failure, never a quiet substitution.
#
# Usage:  regress/sram_model.sh            -> prints the two file paths, one per line
#         exit 1                     -> model not found (caller must not proceed)

set -u
PDK="${IHP_PDK:-$HOME/pdk/IHP-Open-PDK}"
VDIR="$PDK/ihp-sg13g2/libs.ref/sg13g2_sram/verilog"

WRAPPER="$VDIR/RM_IHPSG13_1P_1024x16_c2_bm_bist.v"
CORE="$VDIR/RM_IHPSG13_1P_core_behavioral_bm_bist.v"

miss=0
[ -f "$WRAPPER" ] || { echo "sram_model.sh: missing $WRAPPER" >&2; miss=1; }
[ -f "$CORE" ]    || { echo "sram_model.sh: missing $CORE" >&2;    miss=1; }
if [ "$miss" -ne 0 ]; then
  echo "sram_model.sh: the SRAM behavioural model is NOT available." >&2
  echo "  The design instantiates a hard macro; without this model it cannot" >&2
  echo "  be simulated. Set IHP_PDK, or clone IHP-Open-PDK to ~/pdk." >&2
  exit 1
fi
printf '%s\n%s\n' "$WRAPPER" "$CORE"
