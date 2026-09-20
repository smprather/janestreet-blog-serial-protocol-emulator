#!/usr/bin/env bash
# synth_area.sh — mapped cell count + area per RTL block (sg13g2, typ corner).
#
# Usage:  tb/synth_area.sh
# Uses the system yosys (native, no container needed) with the IHP liberty.
# For real routed numbers use the LibreLane flow (see wiki/concepts/pdk-toolchain.md).

set -u
cd "$(dirname "$0")/.." || exit 1

PDK="${IHP_PDK:-$HOME/pdk/IHP-Open-PDK}"
LIB="$PDK/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"
[ -f "$LIB" ] || { echo "liberty not found: $LIB"; exit 1; }

report() {   # name, rtl files, top
  local name=$1 rtl=$2 top=$3
  local out
  out=$(yosys -p "read_verilog -sv $rtl; hierarchy -check -top $top; proc; opt; fsm; opt; memory; opt; techmap; opt; dfflibmap -liberty $LIB; abc -liberty $LIB; stat -liberty $LIB" 2>&1)
  local cells area
  # hierarchical designs print per-module lines then a design total: take the last
  cells=$(grep -oE '^ +[0-9]+ +[0-9.E+]+ +cells' <<< "$out" | awk '{print $1}' | tail -1)
  area=$(grep -oE "Chip area for module '\\\\$top': [0-9.]+" <<< "$out" | awk '{print $NF}')
  printf '%-16s %8s cells  %12s um2\n' "$name" "${cells:--}" "${area:--}"
}

echo "sg13g2 typ corner (1.20V/25C) — mapped, pre-route"
echo "-----------------------------------------------"
report pe_serdes    "rtl/pe_serdes.v"                            pe_serdes
report pe_nrzi      "rtl/pe_line_codec.v"                        pe_nrzi
report pe_manch     "rtl/pe_line_codec.v"                        pe_manch
report pe_bitstuff  "rtl/pe_line_codec.v"                        pe_bitstuff
report pe_codec_mux "rtl/pe_line_codec.v rtl/pe_codec_mux.v"     pe_codec_mux
report pe_cpu       "rtl/pe_cpu.v"                               pe_cpu
# Note on the SoC: its IMEM/DMEM are register arrays, and yosys will not map
# flip-flop arrays to an SRAM macro here. They therefore synthesise as thousands
# of individual flops (~2,215 at 48.9 um2 each) and the mapped area is huge
# (~177k um2) for what it does. That is the expected consequence of flop memory,
# not a synthesis failure -- see wiki/reference/sram-budget.md and
# wiki/plans/through-i2c.md (Blocker 3) for the macro that fixes it.
report pe_uart_soc  "rtl/pe_cpu.v rtl/pe_uart_soc.v"             pe_uart_soc
echo "-----------------------------------------------"
echo "routed reference: pe_serdes = 17,211 um2 cells / 29,164 um2 die @78% util"
