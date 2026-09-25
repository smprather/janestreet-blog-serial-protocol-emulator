#!/usr/bin/env bash
# run_sta.sh — mapped STA screen for the 10BASE-T TX frame path
# screen as the eth-tx close-out, re-run AFTER the R2 read port, the full-
#
# Run from the repo root:
#   bash reviews/2026-09-25/r2-sta/run_sta.sh
#
# WHAT IS NEW HERE versus reviews/2026-09-24/serdes-sta/ (Task 5b):
# MISO timing are in these netlists for the first time. The new classes are:
#   * the read-port address arbitration in pe_soc (host borrow vs the CPU fetch)
#   * the debug bus at full width (pc 10b, a/x/y 8b, insn 16b)
#   * the wait-word filler/launch path in pe_ctrl (0xFFFF drive, word-edge launch)
#   * the response serializer feeding uio[6] MISO
#
# The new classes the screen has to speak for:
#   * the frame FSM + its counters (pre_cnt / data_bits_left / pad_bits_left /
#     fcs_left / ifg_cnt),
#   * the staging FIFO read path (fifo_mem -> fifo_head/fifo_after -> tx_reg),
#   * the FCS/CRC path (crc_state feedback -> crc_bit -> tx_bit),
#   * the shared TX owner mux (tx_path ? eth_tx_bit : ser_tx),
#   * the pad mux (pin_oe_bus[7] ? pin_out_bus[7] : dbg_pc[0] -> uo_out[2]).
#
# Both designs are run at 16.667 ns (the locked 60 MHz point), slow/typ/fast,
# in BOTH constraint variants:
#   zero  : 0 ns min input/output delay (the assumption-free screen)
#   board : 1.0 ns min input/output delay (the labelled board screening floor)
# Every report ends with the full NEGATIVE-MIN INVENTORY that analyze_hold.py
# classifies. Slow is also the hold corner.
#
# Mapped screens only: no placement, no routing, no DRC, no LVS.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DIR="$ROOT/reviews/2026-09-25/r2-sta"
cd "$ROOT" || exit 1

rc=0
for design in pe_soc tt_um; do
  echo "--- yosys: $design (with pe_eth_tx)"
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
  # OpenSTA 3.1.0's Verilog reader rejects the `wire signed [n:0] name;`
  # declarations yosys emits for pe_ctrl's function-local crc16_byte state
  # (the R1 rewrite added `logic signed` locals). This is a READER limitation,
  # not a design defect — synthesis reports 0 problems and the signedness of
  # these internal arithmetic temporaries is irrelevant to STA (the tools
  # ignore sign extension through the declared width). Strip the `signed`
  # keyword from a scratch copy the screen reads; the pristine mapped netlist
  # is left untouched as the artifact of record.
  if grep -q "^ *wire signed" "$DIR/mapped-$design.v"; then
    sed -E 's/wire signed /wire /' "$DIR/mapped-$design.v" > "$DIR/sta-$design.v"
    echo "  (screen copy: stripped 'signed' from wire decls for the OpenSTA reader)"
  else
    cp "$DIR/mapped-$design.v" "$DIR/sta-$design.v"
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
