#!/usr/bin/env bash
# dev_tb.sh — compile and run ONE testbench in this worktree, for development.
# NOT part of the regression: regress/run_all.sh is the gate. This exists only
# to avoid retyping the 14-file pe_soc source list on every iteration, and it
# is deliberately left untracked -- a second way to run a TB is one more thing
# that can drift from the first.
#
# The unquoted $SOC is intentional and is the only shellcheck complaint here:
# it is a list of source files that must word-split into separate arguments.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="$1"; top="$2"
SOC="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v"
mapfile -t SRAM < <("$REPO/regress/sram_model.sh")
mkdir -p "$REPO/sim"
cd "$REPO/sim" || exit 1
if ! iverilog -g2012 -s "$top" -o "/tmp/$top.vvp" $SOC "${SRAM[@]}" "../tb/$name.v" 2>"/tmp/$top.err"; then
  echo "COMPILE-FAIL"; grep -E "error:" "/tmp/$top.err" | head -8; exit 1
fi
vvp "/tmp/$top.vvp" 2>&1 | grep -vE "^\s*$"
