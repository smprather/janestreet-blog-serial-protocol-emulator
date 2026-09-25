#!/usr/bin/env bash
# run_sta.sh — the R3-phase mapped STA screen.
#
# Run from the repo root:
#   bash reviews/2026-09-25/r3-sta/run_sta.sh
#
# THE MATRIX: pe_soc + tt_um_top, at the locked 60 MHz point (16.667 ns),
# slow/typ/fast, in BOTH constraint variants -- 12 screens:
#   zero  : 0 ns min input/output delay (the assumption-free screen)
#   board : 1.0 ns min input/output delay (the labelled board screening floor)
# Slow is also the hold corner. The clock-uncertainty SPLIT (setup 1.0 / hold
# 0.25) is the flow's own: LibreLane's base.sdc applies one number to BOTH, which
# spends jitter on hold as well as setup and cost 1.0 ns of hold slack when
# measured (flow/pe_soc.sdc, and reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md).
#
# WHAT THIS SCREEN IS FOR. R3 added ports and logic to pe_cpu, pe_ctrl and
# pe_soc: the debug hold and the one-cycle step pulse, the PC breakpoint register
# with its landing-address comparator, the three debug response shapes and the
# ten-bit next-PC route back from the core. None of that had ever been through
# STA. The screen has to speak for those classes specifically, so run_sta.sh
# checks that they are PRESENT in the mapped netlists (r3_debug_inventory) and
# reports whether any of them lands among the tightest paths, rather than
# assuming the aggregate numbers cover them.
#
# Mapped screens only: no placement, no routing, no DRC, no LVS. The numbers are
# PRE-ROUTING SCREENING estimates and are not signoff.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DIR="$ROOT/reviews/2026-09-25/r3-sta"
cd "$ROOT" || exit 1

rc=0

# ---------------------------------------------------------------------------
# 1. The debug structures must be IN the netlist, or the screen is not covering
#    what it claims to cover. This is a real check with teeth: it greps the
#    MAPPED netlist for the R3 nets and fails if the phase's own logic is absent
#    (which would mean the screen timed a design without debug control in it).
# ---------------------------------------------------------------------------
r3_debug_inventory() {
  local design="$1" net="$2" out="$3"
  {
    echo "===== R3 DEBUG-PATH INVENTORY: $design ($net)"
    printf '%-14s %s\n' "nets found:" ""
    for n in dbg_hold dbg_step dbg_next_pc bp_addr bp_en bp_hit dbg_hold_r; do
      local c
      c=$(grep -c -- "$n" "$net" 2>/dev/null || true)
      printf '  %-12s %s occurrence(s) in the mapped netlist\n' "$n" "${c:-0}"
    done
    local cells
    cells=$(grep -cE 'sg13g2_[a-z0-9_]+ ' "$net" 2>/dev/null || true)
    echo "  total cell instances: ${cells:-0}"
  } > "$out" 2>&1
  # A netlist with none of the R3 nets is a netlist that is not the R3 design.
  if ! grep -qE 'dbg_hold|dbg_step|dbg_next_pc|bp_addr|bp_hit' "$net"; then
    echo "  !! $design: NO R3 debug nets in the mapped netlist -- the screen"
    echo "     would not be covering the debug paths. See $out"
    rc=1
  else
    echo "  R3 debug nets present in $design (inventory: $(basename "$out"))"
  fi
}

for design in pe_soc tt_um; do
  echo "--- yosys: $design (R3 debug control included)"
  if ! yosys -s "$DIR/synth-$design.ys" > "$DIR/synth-$design.log" 2>&1; then
    echo "yosys FAILED for $design (see synth-$design.log)"; rc=1; continue
  fi
  if [ ! -s "$DIR/mapped-$design.v" ]; then
    echo "yosys produced no mapped-$design.v (see synth-$design.log)"; rc=1; continue
  fi
  # A mapped netlist with a driver conflict or an implicit declaration is a
  # correctness failure, not a number to file quietly.
  if grep -qE "multiple conflicting drivers|Driver conflict|ERROR:" "$DIR/synth-$design.log"; then
    echo "  yosys reported a conflict/ERROR in $design (see synth-$design.log)"; rc=1
  fi
  # OpenSTA 3.1.0's Verilog reader rejects `wire signed [n:0] name;`, which yosys
  # emits for pe_ctrl's function-local crc16_byte state. That is a READER
  # limitation, not a design defect (the signedness of an internal arithmetic
  # temporary is irrelevant to STA, which ignores sign extension through the
  # declared width). Strip it in a scratch copy the screen reads; the pristine
  # mapped netlist stays untouched as the artefact of record.
  if grep -q "^ *wire signed" "$DIR/mapped-$design.v"; then
    sed -E 's/wire signed /wire /' "$DIR/mapped-$design.v" > "$DIR/sta-$design.v"
    echo "  (screen copy: stripped 'signed' from wire decls for the OpenSTA reader)"
  else
    cp "$DIR/mapped-$design.v" "$DIR/sta-$design.v"
  fi
  r3_debug_inventory "$design" "$DIR/sta-$design.v" "$DIR/r3-debug-inventory-$design.txt"

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

# ---------------------------------------------------------------------------
# 2. Do the R3 debug paths appear among the TIGHTEST paths? Aggregate slack can
#    hide a short debug path behind a comfortable register-to-register maximum,
#    so the screen says explicitly which R3 nets appear in the negative-min
#    inventory and in the reported worst paths.
# ---------------------------------------------------------------------------
echo "--- R3 debug paths in the reported timing (per screen)"
: > "$DIR/r3-debug-timing.txt"
for design in pe_soc tt_um; do
  for corner in slow typ fast; do
    for variant in "" "-board"; do
      f="$DIR/sta-$design-$corner$variant.txt"
      [ -s "$f" ] || continue
      {
        echo "== $design/$corner$variant"
        hits=$(grep -cE 'dbg_hold|dbg_step|dbg_next_pc|bp_addr|bp_hit' "$f" || true)
        echo "   R3-named nets appearing in this report: ${hits:-0}"
        if [ "${hits:-0}" != "0" ]; then
          grep -E 'dbg_hold|dbg_step|dbg_next_pc|bp_addr|bp_hit' "$f" | head -6 | sed 's/^/     /'
        fi
        grep -E "^worst slack" "$f" | sed 's/^/   /'
      } >> "$DIR/r3-debug-timing.txt"
    done
  done
done
grep -c "R3-named nets appearing" "$DIR/r3-debug-timing.txt" | sed 's/^/  screens summarised: /'

# ---------------------------------------------------------------------------
# 3. Hold attribution, one section per zero/board pair (the r2-sta classifier).
# ---------------------------------------------------------------------------
echo "--- hold attribution (analyze_hold.py, one section per zero/board pair)"
: > "$DIR/hold-attr-analysis.txt"
for design in pe_soc tt_um; do
  for corner in slow typ fast; do
    python3 "$DIR/analyze_hold.py" \
      "$DIR/sta-$design-$corner.txt" "$DIR/sta-$design-$corner-board.txt" \
      >> "$DIR/hold-attr-analysis.txt" 2>&1 || {
        echo "analyze_hold.py failed for $design/$corner"; rc=1; }
  done
done
exit $rc
