#!/usr/bin/env bash
# synth_area.sh — mapped cell count + area per RTL block (sg13g2, typ corner).
#
# Usage:  regress/synth_area.sh
# Uses the system yosys (native, no container needed) with the IHP liberty.
# For real routed numbers use the LibreLane flow (see wiki/concepts/pdk-toolchain.md).

set -u
cd "$(dirname "$0")/.." || exit 1

PDK="${IHP_PDK:-$HOME/pdk/IHP-Open-PDK}"
LIB="$PDK/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"
[ -f "$LIB" ] || { echo "liberty not found: $LIB"; exit 1; }

rc=0

report() {   # name, rtl files, top, optional chparam
  local name=$1 rtl=$2 top=$3 chparam=${4:-}
  local out
  out=$(yosys -p "read_verilog -sv $rtl; hierarchy -check -top $top $chparam; proc; opt; fsm; opt; memory; opt; techmap; opt; dfflibmap -liberty $LIB; abc -liberty $LIB; stat -liberty $LIB" 2>&1)
  local cells area
  # Hierarchical designs print per-module lines then a design total. The total
  # line is the one WITHOUT a module name in front of it, so match that shape
  # explicitly: a macro instantiation line ("12 cells") would otherwise be picked
  # up as the design total, which is how a 1024-word memory reported 12 cells.
  cells=$(grep -oE '^ +[0-9]+ +[0-9.E+]+ +cells' <<< "$out" | awk '{print $1}' | tail -1)
  # Prefer the WHOLE-DESIGN total. "Chip area for module 'X'" is X's LOCAL
  # area, excluding submodules -- for a wrapper like tt_um_protocol_emulator
  # that is 0.0, which reads as a broken tool rather than as "all the area is
  # one level down". yosys emits "Chip area for top module" with the real
  # total for a hierarchical design; fall back to the local line for a flat one.
  # yosys prints the module name escaped (\pe_serdes), so allow for the
  # backslash; [\\]? keeps it optional in case a future yosys drops it.
  area=$(grep -oE "Chip area for top module '[\\]?$top': [0-9.]+" <<< "$out" | awk '{print $NF}')
  [ -n "$area" ] || area=$(grep -oE "Chip area for module '[\\]?$top': [0-9.]+" <<< "$out" | awk '{print $NF}')
  # A blackbox macro contributes NO cell area to yosys (its area lives in the
  # LEF, not in gates), so a design built on one reports only its glue. Print
  # that honestly and say so, rather than letting "12 cells" read as the memory's
  # cost. The macro's own area is in wiki/reference/sram-budget.md.
  local bb
  bb=$(grep -cE "is not part of the design|blackbox" <<< "$out" || true)
  local note=""
  if grep -qE '^ +1 +RM_IHPSG13' <<< "$out"; then
    note="  (+1 SRAM macro, area from LEF not gates)"
  fi
  printf '%-18s %8s cells  %12s um2%s\n' "$name" "${cells:--}" "${area:--}" "$note"

  # SURFACE THE DIAGNOSTICS. This script used to capture yosys's whole output
  # into $out and grep it only for numbers, so every warning it printed was
  # discarded. Two real defects lived in that blind spot for an entire
  # milestone: a driver-driver conflict on tick_flag (resolved to a constant,
  # so the STATUS port was dead in the netlist) and two hierarchical references
  # that yosys turned into implicit wires driven backwards. Both were reported
  # on every single run. An area report that hides correctness warnings is
  # worse than no area report, because it looks like a check.
  local bad
  bad=$(grep -E "Driver-driver conflict|implicitly declared|Warning: Wire .* is used but has no driver" <<< "$out")
  if [ -n "$bad" ]; then
    sed 's/^/    !! /' <<< "$bad"
    rc=1
  fi
}

echo "sg13g2 typ corner (1.20V/25C) — mapped, pre-route"
echo "-----------------------------------------------"
report pe_serdes    "rtl/pe_serdes.v"                            pe_serdes
report pe_nrzi      "rtl/pe_nrzi.v"                        pe_nrzi
report pe_manch     "rtl/pe_manch.v"                        pe_manch
report pe_bitstuff  "rtl/pe_bitstuff.v"                        pe_bitstuff
report pe_codec_mux "rtl/pe_nrzi.v rtl/pe_manch.v rtl/pe_bitstuff.v rtl/pe_codec_mux.v"     pe_codec_mux
# The CRC / LFSR engine. One 32-bit shift register serves every polynomial from
# CRC-5 to CRC-32, so the cell count does not grow with the CRC width -- which is
# the whole reason this is worth doing in hardware instead of firmware.
report pe_crc       "rtl/pe_crc.v"                               pe_crc
# The DRU. Its cost is dominated by the synchronizer, the phase counter and the
# capture register -- no datapath, which is why the wiki's ~60-cell estimate is
# in the right range (see the measured figure in STATUS).
report pe_dru       "rtl/pe_dru.v"                               pe_dru
report pe_cpu       "rtl/pe_cpu.v"                               pe_cpu
# The pin matrix. The plan estimated "8 pins x (2 out + 1 oe + 1 in + 1 cfg) ~
# 40 flops plus a small mux tree, in the low hundreds of cells", and to be
# SMALLER than the SERDES (539) because it has no datapath. The measured figure
# in STATUS is the test of that claim.
report pe_pinmux    "rtl/pe_pinmux.v"                            pe_pinmux
# The passive SPI loader. Small by design: a 16-bit shift register, counters,
# a synchronizer and a write pulse -- no word-engine generality is needed for a
# fixed-width load.
report pe_ctrl      "rtl/pe_ctrl.v"                              pe_ctrl
# Instruction memory, BOTH ways round. This is the swap's whole argument in one
# line each: the flop array at the same 1024-word depth is the number the design
# used to pay, and the macro build has NO synthesised cells at all (yosys keeps
# the instance and its area comes from the macro's LEF, not from gates).
report pe_imem_flop  "rtl/pe_imem.v"                            pe_imem "-chparam FLOP 1"
report pe_imem_macro "rtl/pe_imem.v rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v" pe_imem
# Frame buffer, BOTH ways round, for the same reason as pe_imem above: the
# macro build has no synthesised cells (its area is in the LEF) while the flop
# build is the number the design would pay without it. ADR-003 chose the same
# 1024x16 part as the instruction memory, so the two macro lines differ only in
# the glue around them.
report pe_fbuf_flop   "rtl/pe_fbuf.v"                            pe_fbuf "-chparam FLOP 1"
report pe_fbuf_macro  "rtl/pe_fbuf.v rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v" pe_fbuf

  # The 10BASE-T receive path. No macro of its own -- it is logic plus a
  # write port -- so this is the whole cost of the hardware-vs-firmware
  # decision wiki/concepts/ethernet-scope.md argues for.
  report pe_eth_mac "rtl/pe_eth_mac.v" pe_eth_mac
# Note on the SoC: the instruction memory is the SRAM macro, and the frame
# buffer is the same part; both contribute area from their LEF, not gates. The
# receive chain's logic is part of this build now, so its sources are listed --
# the same list flow/pe_soc.json and info.yaml carry.
report pe_soc  "rtl/pe_cpu.v rtl/pe_imem.v rtl/pe_pinmux.v rtl/pe_dru.v rtl/pe_manch.v rtl/pe_crc.v rtl/pe_eth_mac.v rtl/pe_fbuf.v rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v rtl/pe_soc.v" pe_soc
# The deliverable: the only module Tiny Tapeout will instantiate.
report tt_um_top    "rtl/pe_cpu.v rtl/pe_imem.v rtl/pe_pinmux.v rtl/pe_dru.v rtl/pe_manch.v rtl/pe_crc.v rtl/pe_eth_mac.v rtl/pe_fbuf.v rtl/pe_ctrl.v rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v rtl/pe_soc.v rtl/tt_um_protocol_emulator.v" tt_um_protocol_emulator
echo "-----------------------------------------------"
echo "routed reference: pe_serdes = 17,211 um2 cells / 29,164 um2 die @78% util"
echo "reproduce it with: flow/run_librelane.sh flow/pe_serdes.json"

if [ "$rc" -ne 0 ]; then
  echo
  echo "SYNTHESIS DIAGNOSTICS ABOVE (marked !!) — the netlist will not match"
  echo "the RTL you simulated. Fix them before trusting any number here."
fi
exit "$rc"
