#!/usr/bin/env bash
# lint.sh — the static gate on the RTL: Verilator lint + a yosys elaboration check.
#
# Usage:  tb/lint.sh
# Exit:   0 = clean, 1 = at least one finding
#
# WHY THIS EXISTS, AND WHY IT IS NOT OPTIONAL.
#
# Three real defects shipped into the repo and survived a 16/16 green regression,
# because every one of them is invisible to a simulation testbench:
#
#   1. `tick_flag` in pe_uart_soc.v was driven by TWO always_ff blocks. Icarus
#      resolves that as a race (and silently dropped ~17% of ticks); yosys
#      resolved it to a CONSTANT 0, so the STATUS peripheral worked in
#      simulation and was dead in silicon. A testbench cannot see that,
#      because the testbench only ever runs the simulator's resolution.
#   2. `assign dbg_pc = u_cpu.pc` is a hierarchical reference. Icarus accepts
#      it; yosys declares an implicit wire and drives it BACKWARDS, leaving the
#      output port constant-zero above bit 0. Again invisible to simulation.
#   3. Width-mismatch and unused-signal warnings that nobody was reading.
#
# The lesson generalises: a simulator's resolution of illegal RTL is not the
# synthesiser's resolution, so "the testbench passes" says nothing about the
# netlist. The gate below is what catches that class, and it runs in the
# regression rather than on request, because the first two defects were both
# reported by the tools on every single run and discarded unread.

set -u
cd "$(dirname "$0")/.." || exit 1

# RTL_ALL is everything a consumer elaborates. SRAM_BB is the macro's empty
# port shell: yosys needs it to elaborate pe_imem, verilator does not (it
# treats an undefined module as a blackbox already) but passing it is
# harmless and keeps one file list.
#
# WHY pe_eth_mac AND pe_fbuf ARE HERE. They were missing, and the omission was
# a real gate hole: the regression reported "lint clean" while a direct
# `verilator -Wall` on pe_eth_mac produced five findings (a width expansion and
# four unused-signal warnings, two of them dead dst/src register files). A
# block is only covered when it is in RTL_ALL and in the top lists below.
RTL_ALL="rtl/pe_serdes.v rtl/pe_line_codec.v rtl/pe_codec_mux.v rtl/pe_crc.v rtl/pe_dru.v rtl/pe_cpu.v rtl/pe_imem.v rtl/pe_uart_soc.v rtl/pe_pinmux.v rtl/pe_eth_mac.v rtl/pe_fbuf.v rtl/tt_um_protocol_emulator.v"
SRAM_BB="rtl/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v"
rc=0

# ---------------------------------------------------------------- verilator
# -Wall on every top. Verilator exits non-zero on any warning, which is the
# behaviour we want: there are no accepted warnings in this RTL.
if command -v verilator >/dev/null 2>&1; then
  for top in pe_serdes pe_nrzi pe_manch pe_bitstuff pe_codec_mux pe_crc pe_dru pe_cpu \
             pe_imem pe_uart_soc pe_pinmux pe_eth_mac pe_fbuf tt_um_protocol_emulator; do
    if out=$(verilator --lint-only -Wall --timing --top-module "$top" $RTL_ALL $SRAM_BB 2>&1); then
      printf '%-28s lint OK\n' "$top"
    else
      printf '%-28s LINT FAIL\n' "$top"
      sed 's/^/    /' <<< "$out" | head -20
      rc=1
    fi
  done
else
  echo "verilator: NOT INSTALLED (skipped)"
fi

# ------------------------------------------------------------------- yosys
# Elaborate every top and fail on the diagnostics that mean "the netlist will
# not match the RTL you simulated". These are warnings, not errors, in yosys,
# so they have to be grepped for explicitly.
#
# Driver-driver conflict  -> two processes drive one signal; yosys picks one and
#                            the simulator picks the other.
# implicitly declared     -> a hierarchical reference (or a typo) silently
#                            became a new floating wire.
# found and reported .* problems -> hierarchy -check failure.
# ERROR:                  -> a parse/elaboration failure. This one was a REAL
#                            gate hole: the DDR draft used a function returning
#                            a named packed struct, which yosys 0.68 cannot
#                            parse. iverilog and verilator accepted the file, so
#                            the TB passed and the gate said "elaborate OK"
#                            because a syntax ERROR did not match any of the
#                            three patterns above. A gate that lists the errors
#                            it expects misses the ones it has never seen.
if command -v yosys >/dev/null 2>&1; then
  for top in pe_serdes pe_codec_mux pe_crc pe_dru pe_cpu pe_imem pe_uart_soc pe_pinmux pe_eth_mac pe_fbuf tt_um_protocol_emulator; do
    out=$(yosys -p "read_verilog -sv $RTL_ALL $SRAM_BB; hierarchy -check -top $top; proc; opt" 2>&1)
    bad=$(grep -E "ERROR|Driver-driver conflict|implicitly declared|is not part of the design|Warning: Wire .* is used but has no driver" <<< "$out")
    if [ -z "$bad" ]; then
      printf '%-28s elaborate OK\n' "$top"
    else
      printf '%-28s ELABORATE FAIL\n' "$top"
      sed 's/^/    /' <<< "$bad" | head -10
      rc=1
    fi
  done
else
  echo "yosys: NOT INSTALLED (skipped)"
fi

echo
if [ "$rc" -eq 0 ]; then
  echo "lint clean"
else
  echo "LINT FAILURES — see above"
fi
exit "$rc"
