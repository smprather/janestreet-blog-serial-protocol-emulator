#!/usr/bin/env bash
# Run from any directory. Exit nonzero when a reviewed defect is still present.
# All builds and the optional DRU experiment are confined to a temporary dir.
# The interruption probe creates and mutates its own archived HEAD copies.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CASES="$ROOT/reviews/2026-09-22/review2"
WORK=$(mktemp -d /tmp/review2-repros.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
failed=0

run_verilog() {
    local label="$1" top="$2" probe="$3"
    shift 3
    echo "=== $label ==="
    if ! iverilog -g2012 -s "$top" -o "$WORK/$label.vvp" "$@" "$CASES/$probe" >"$WORK/compile.log" 2>&1; then
        cat "$WORK/compile.log"
        echo "BUILD FAILED: $label"
        failed=$((failed + 1))
        return
    fi
    if vvp "$WORK/$label.vvp"; then
        echo "PASS: $label"
    else
        echo "FAIL: $label"
        failed=$((failed + 1))
    fi
}

ETH=(rtl/pe_nrzi.v rtl/pe_manch.v rtl/pe_bitstuff.v rtl/pe_crc.v rtl/pe_eth_mac.v rtl/pe_fbuf.v)
run_verilog dru_async tb_pe_eth_mac dru_async.v rtl/pe_dru.v "${ETH[@]}"
run_verilog mac_runt tb_pe_eth_mac mac_runt.v rtl/pe_dru.v "${ETH[@]}"
run_verilog usb_zeros usb_review usb_zeros.v rtl/pe_nrzi.v rtl/pe_manch.v rtl/pe_bitstuff.v rtl/pe_codec_mux.v
run_verilog cpu_restart review_cpu_stop cpu_restart.v rtl/pe_cpu.v

mapfile -t SRAM < <(regress/sram_model.sh)
run_verilog memory_contract review_memory_hold memory_contract.v "${SRAM[@]}" rtl/pe_imem.v rtl/pe_fbuf.v

for probe in uart_monitor mutation_interrupt; do
    echo "=== $probe ==="
    if python3 "$CASES/$probe.py"; then
        echo "PASS: $probe"
    else
        echo "FAIL: $probe"
        failed=$((failed + 1))
    fi
done

# A diagnostic experiment, not a fix to the working checkout.
python3 - "$WORK/pe_dru_nba.v" <<'PY'
import pathlib
import sys
value = pathlib.Path('rtl/pe_dru.v').read_text()
value = value.replace('if (clk) rx_nl = rx_pin;', 'if (clk) rx_nl <= rx_pin;')
pathlib.Path(sys.argv[1]).write_text(value)
PY
run_verilog dru_nba_experiment tb_pe_eth_mac dru_async.v "$WORK/pe_dru_nba.v" "${ETH[@]}"

if [[ "${1:-}" == "--sweep" ]]; then
    run_verilog dru_sweep tb_pe_eth_mac dru_sweep.v rtl/pe_dru.v "${ETH[@]}"
fi
echo "REVIEW PROBES: $failed failed"
[[ "$failed" == 0 ]]
