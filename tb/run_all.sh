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
# Capture the repo root NOW, as an absolute path. This script cds into sim/ and
# then back to the root, and `$0` may itself be relative ("./tb/run_all.sh"), so
# any later `dirname "$0"` resolves against the wrong directory. Gates that are
# invoked mid-script use this. (The param-guard gate failed exactly this way.)
REPO_ROOT="$(pwd)"
mkdir -p sim

# Firmware first: it assembles firmware/*.hex, and tb_pe_uart_soc.v $readmemh's
# one of them. Running it here means the RTL test can never simulate a stale
# image without the regression saying so.
echo "=== firmware (assemble + emulator) ==="
if ./tb/run_firmware_tests.sh; then
  fw_rc=0
else
  fw_rc=1
fi
echo
echo "=== RTL testbenches ==="

cd sim || exit 1

# The SRAM macro's behavioural model lives in the PDK, outside the repo. Every
# case that elaborates pe_imem needs it. A missing model is a HARD failure here,
# not a silent fall back to pe_imem's FLOP array -- a testbench that runs against
# the fallback has verified nothing about the memory that will actually ship.
if ! SRAM_MODEL=$(../tb/sram_model.sh); then
  echo "FATAL: SRAM behavioural model unavailable; cannot simulate the SoC." 
  exit 1
fi
SRAM_FLAGS=$(printf '%s ' $SRAM_MODEL)

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
  # The CRC / LFSR engine. Its constants are checked against the RevEng
  # catalogue (tools/gen_crc_config.py), and this TB is the only place the
  # "one right-shift datapath serves both CRC families" claim is measured.
  "tb_pe_crc|../rtl/pe_crc.v|tb_pe_crc"
  # Instruction memory against the PDK's REAL SRAM model: one-cycle latency, the
  # BM write no-op, and the REN write-through trap. Mutation-checked.
  "tb_pe_imem|../rtl/pe_imem.v|tb_pe_imem"
  # The DRU (oversampled Manchester receive). Its TB is the only place the
  # "phase 2 and 6 of an edge-reset counter are the half-cell centres" claim is
  # measured -- against every Manchester transition pattern.
  "tb_pe_dru|../rtl/pe_line_codec.v ../rtl/pe_dru.v|tb_pe_dru"
  # The pin matrix: runtime per-pin direction, open-drain, read-back. The I2C
  # gate -- it makes arbitration (reading a pin we are also driving) and
  # bus-contention safety structural rather than a firmware convention.
  "tb_pe_pinmux|../rtl/pe_pinmux.v|tb_pe_pinmux"
  # The firmware processor, its unit TB, and the software-UART SoC TB. The SoC TB
  # $readmemh's firmware/uart_echo.hex, so run_firmware_tests.sh (below) must have
  # assembled a current copy -- it runs first for exactly that reason.
  "tb_pe_cpu|../rtl/pe_cpu.v|tb_pe_cpu"
  "tb_pe_uart_soc|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_uart_soc.v|tb_pe_uart_soc"
  # The STATUS port. Nothing exercised it until firmware/tick_count.pe existed,
  # which is how a two-driver tick_flag survived a green regression: it raced
  # in Icarus and synthesised to a constant 0, and no test read the port.
  "tb_pe_tick_status|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_uart_soc.v|tb_pe_tick_status"
  # The Tiny Tapeout top level: the pad contract (no X on an output, ena gates
  # nothing, open-drain pins never drive high). This is the only submittable
  # module in the repo.
  "tb_tt_um_protocol_emulator|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_uart_soc.v ../rtl/tt_um_protocol_emulator.v|tb_tt_um_protocol_emulator"
)

pass=0; fail=0; failed_names=()
for c in "${CASES[@]}"; do
  IFS='|' read -r name rtl top <<< "$c"
  tb="../tb/${name}.v"
  if ! iverilog -g2012 -s "$top" -o "/tmp/${top}.vvp" $rtl $SRAM_FLAGS "$tb" 2>"/tmp/${top}.err"; then
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
if [ "$fw_rc" -ne 0 ]; then
  echo "firmware regression: FAILED (see above)"
  fail=$((fail+1))
fi

# Elaboration guards are only real if they actually reject. A parameterised
# block is only tested at the values something instantiates, so the BOUNDARY is
# where silent breakage hides -- pe_dru's 4-bit phase counter truncated above
# SPB=16 and the block went completely dead with no error at all. This gate
# compiles each guarded block at an out-of-range parameter and requires a hard
# failure, plus an in-range compile at the boundary itself.
#
# Invoked via REPO_ROOT captured at the top: this file cds into sim/ and back,
# and $0 may be relative, so any later `dirname "$0"` resolves wrongly.
if "$REPO_ROOT/tb/param_guards.sh" > /tmp/param_guards.log 2>&1; then
  echo "param guards: OK"
else
  echo "param guards: FAILED"
  cat /tmp/param_guards.log
  fail=$((fail+1))
  failed_names+=("param_guards")
fi

[ "$fail" -eq 0 ] || { echo "failed: ${failed_names[*]}"; exit 1; }
echo "all testbenches pass"

# The static gate. It runs HERE, in the regression, and not on request, because
# the two defects it was written for (a two-driver flop that yosys resolved to a
# constant, and a hierarchical reference that yosys drove backwards) were both
# reported by the tools on every single run and discarded unread. A simulator's
# resolution of illegal RTL is not the synthesiser's, so a green testbench says
# nothing about the netlist.
cd .. || exit 1
if ./tb/lint.sh; then
  lint_rc=0
else
  lint_rc=1
fi
echo

# Docs that are generated from the RTL are checked too: a renamed port must not
# leave wiki/reference/signal-names.md describing an interface that no longer
# exists, and a deleted TB must not leave the pin budget claiming coverage.
# Regenerate with: python3 tools/gen_signal_glossary.py / tools/gen_pin_budget.py
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
# The SRAM budget reads the PDK, which lives outside the repo. Skip it (loudly)
# when the PDK is not cloned rather than failing a regression on a missing
# dependency.
if [ -d "$HOME/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/lef" ]; then
  if python3 tools/gen_sram_budget.py --check >/dev/null 2>&1; then
    echo "sram budget up to date"
  else
    echo "STALE: wiki/reference/sram-budget.md — run python3 tools/gen_sram_budget.py"
    stale=1
  fi
else
  echo "sram budget: SKIPPED (PDK not at ~/pdk/IHP-Open-PDK)"
fi
# The CRC constants are checked against the RevEng catalogue on every run, not
# just regenerated on request: a wrong polynomial or seed is a silent wrong
# answer on the wire, and it is cheap to catch here (the script also derives
# every constant before it writes anything).
if python3 tools/gen_crc_config.py --check >/dev/null 2>&1; then
  echo "crc config up to date"
else
  echo "STALE: wiki/reference/crc-config.md — run python3 tools/gen_crc_config.py"
  stale=1
fi
# The clock arithmetic is READ FROM THE RTL by the generator, so this gate is
# what makes the locked 60 MHz operating point stick: if pe_uart_soc's CLK_HZ
# moves and the derived constants elsewhere are not updated with it, the page
# regenerates differently and this fails. It also asserts SPB=12 and
# TICKS_PER_BIT=260, which are the two constants the DRU and the UART firmware
# hardcode in other languages.
if python3 tools/gen_clock_arithmetic.py --check >/dev/null 2>&1; then
  echo "clock arithmetic up to date"
else
  echo "STALE: wiki/reference/clock-arithmetic.md — run python3 tools/gen_clock_arithmetic.py"
  stale=1
fi
# The block diagram is checked against rtl/ and run_all.sh: a block is drawn as
# instantiated only if some RTL names it, and as verified only if its TB is in
# run_all.sh. The hand-drawn ASCII version this replaces claimed a pin matrix
# that did not exist and a flop memory that had been replaced by an SRAM.
if python3 tools/gen_block_diagram.py --check >/dev/null 2>&1; then
  echo "block diagram up to date"
else
  echo "STALE: wiki/reference/block-diagram.md — run python3 tools/gen_block_diagram.py"
  stale=1
fi
[ "$stale" -eq 0 ] || exit 1
[ "$lint_rc" -eq 0 ] || { echo "lint gate FAILED (see above)"; exit 1; }
