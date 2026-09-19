#!/usr/bin/env bash
# run_all.sh — full regression: every testbench, one command.
#
# Usage:  tb/run_all.sh            (from anywhere in the repo)
# Exit:   0 = all pass, 1 = at least one failure
#
# VCDs are written into sim/ (gitignored per-run artifacts; the checked-in
# copies are snapshots). Requires iverilog (>= 11, -g2012 support).

set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p sim
cd sim || exit 1

# tb file : rtl files : top module
CASES=(
  "tb_pe_serdes|../rtl/pe_serdes.v|tb_pe_serdes"
  "tb_pe_uart|../rtl/pe_serdes.v|tb_pe_uart"
  "tb_pe_spi|../rtl/pe_serdes.v|tb_pe_spi"
  "tb_pe_i2c|../rtl/pe_serdes.v|tb_pe_i2c"
  "tb_pe_jtag|../rtl/pe_serdes.v|tb_pe_jtag"
  "tb_pe_swd|../rtl/pe_serdes.v|tb_pe_swd"
  "tb_pe_ps2|../rtl/pe_serdes.v|tb_pe_ps2"
  "tb_pe_can|../rtl/pe_serdes.v|tb_pe_can"
  "tb_pe_usb|../rtl/pe_serdes.v|tb_pe_usb"
  "tb_pe_eth|../rtl/pe_serdes.v|tb_pe_eth"
  "tb_pe_line_codec|../rtl/pe_line_codec.v|tb_pe_nrzi"
  "tb_pe_line_codec|../rtl/pe_line_codec.v|tb_pe_manch"
  "tb_pe_line_codec|../rtl/pe_line_codec.v|tb_pe_bitstuff"
  "tb_pe_codec_mux|../rtl/pe_line_codec.v ../rtl/pe_codec_mux.v|tb_pe_codec_mux"
)

pass=0; fail=0; failed_names=()
for c in "${CASES[@]}"; do
  IFS='|' read -r name rtl top <<< "$c"
  tb="../tb/${name}.v"
  if ! iverilog -g2012 -s "$top" -o "/tmp/${top}.vvp" $rtl "$tb" 2>"/tmp/${top}.err"; then
    printf '%-18s COMPILE-FAIL\n' "$top"
    sed -n '1,3p' "/tmp/${top}.err"
    fail=$((fail+1)); failed_names+=("$top(compile)")
    continue
  fi
  out=$(vvp "/tmp/${top}.vvp" 2>&1)
  if grep -q '^PASS' <<< "$out"; then
    printf '%-18s PASS\n' "$top"
    pass=$((pass+1))
  else
    printf '%-18s FAIL\n' "$top"
    grep -E '^FAIL' <<< "$out" | head -5
    fail=$((fail+1)); failed_names+=("$top")
  fi
done

echo
echo "========================================"
echo "TOTAL: $((pass+fail))   PASS: $pass   FAIL: $fail"
[ "$fail" -eq 0 ] || { echo "failed: ${failed_names[*]}"; exit 1; }
echo "all testbenches pass"

# Docs that are generated from the RTL are checked too: a renamed port must not
# leave wiki/reference/signal-names.md describing an interface that no longer
# exists, and a deleted TB must not leave the pin budget claiming coverage.
# Regenerate with: python3 tools/gen_signal_glossary.py / tools/gen_pin_budget.py
cd .. || exit 1
stale=0
if python3 tools/gen_signal_glossary.py --check >/dev/null 2>&1; then
  echo "signal glossary up to date"
else
  echo "STALE: wiki/reference/signal-names.md — run python3 tools/gen_signal_glossary.py"
  stale=1
fi
if python3 tools/gen_pin_budget.py --check >/dev/null 2>&1; then
  echo "protocol pin budget up to date"
else
  echo "STALE: wiki/reference/protocol-pin-budget.md — run python3 tools/gen_pin_budget.py"
  stale=1
fi
[ "$stale" -eq 0 ] || exit 1
