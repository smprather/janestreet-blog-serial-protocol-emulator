#!/usr/bin/env bash
# run_all.sh — full regression: every testbench, one command.
#
# Usage:  tb/run_all.sh            (from anywhere in the repo)
#         tb/run_all.sh --fast     parallel testbench loop (see below)
#         tb/run_all.sh --fast -j8 explicit job count
# Exit:   0 = all pass, 1 = at least one failure
#
# VCDs are written into sim/ (gitignored per-run artifacts; the checked-in
# copies are snapshots). Requires iverilog (>= 11, -g2012 support).
#
# WHAT --fast ACTUALLY DOES, because the name invites the wrong assumption: it
# runs the SAME 4-state iverilog simulation, in parallel. It does NOT switch to
# Verilator. Measured, a Verilator swap would make this suite 69.6x SLOWER --
# Verilator builds per --top-module with no shared cache (median 5.6 s per
# testbench), so 24 testbenches cost 167 s of compilation against 2.4 s for all
# 24 iverilog compiles AND runs. The per-run 12-19x speedup only pays back at
# ~27 runs of the same testbench, and this suite runs each one once.
#
# So --fast buys concurrency, not a different simulator, and the default path is
# byte-identical in what it simulates. tb_pe_pinmux is the hard blocker for a
# Verilator path anyway: it models the bus at strength levels to test the od
# bit's contention property, and Verilator aborts it with DIDNOTCONVERGE.

set -u
cd "$(dirname "$0")/.." || exit 1
# Capture the repo root NOW, as an absolute path. This script cds into sim/ and
# then back to the root, and `$0` may itself be relative ("./tb/run_all.sh"), so
# any later `dirname "$0"` resolves against the wrong directory. Gates that are
# invoked mid-script use this. (The param-guard gate failed exactly this way.)
REPO_ROOT="$(pwd)"
mkdir -p sim

# ---- options ---------------------------------------------------------------
FAST=0
JOBS=$(nproc 2>/dev/null || echo 4)
while [ $# -gt 0 ]; do
  case "$1" in
    --fast)   FAST=1 ;;
    -j*)      JOBS="${1#-j}" ;;
    -j)       shift; JOBS="${1:-$JOBS}" ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "run_all.sh: unknown option '$1' (try --help)" >&2
      exit 2 ;;
  esac
  shift
done
# A bad -j would make xargs fail in a way that reads like a test failure.
case "$JOBS" in
  ''|*[!0-9]*) echo "run_all.sh: -j needs a positive integer, got '$JOBS'" >&2; exit 2 ;;
  0)           echo "run_all.sh: -j 0 would run nothing" >&2; exit 2 ;;
esac

if [ "$FAST" -eq 1 ]; then
  echo "(--fast: parallel testbench loop, $JOBS jobs, same 4-state simulation)"
fi

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
  "tb_pe_uart_soc|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_uart_soc.v|tb_pe_uart_soc"
  # The STATUS port. Nothing exercised it until firmware/tick_count.pe existed,
  # which is how a two-driver tick_flag survived a green regression: it raced
  # in Icarus and synthesised to a constant 0, and no test read the port.
  "tb_pe_tick_status|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_uart_soc.v|tb_pe_tick_status"
  # The Tiny Tapeout top level: the pad contract (no X on an output, ena gates
  # nothing, open-drain pins never drive high). This is the only submittable
  # module in the repo.
  "tb_tt_um_protocol_emulator|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_uart_soc.v ../rtl/tt_um_protocol_emulator.v|tb_tt_um_protocol_emulator"
  # I2C on the pin matrix: the runtime direction file driven by firmware, and
  # the open-drain property checked on the RTL's own pin_oe output. This is the
  # test that makes "the matrix is enough to speak I2C" a measured claim.
  "tb_pe_i2c_soc|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_uart_soc.v|tb_pe_i2c_soc"
  # SPI mode 0 as firmware, with a real mode-0 SLAVE modelled in the TB. SPI is
  # a baseline protocol whose only executable spec was tools/peemu.py -- a model
  # written from the same understanding as the firmware, so it can agree with it
  # about a wrong bit order and pass. The slave here decodes MOSI from the pins.
  "tb_pe_spi_soc|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_uart_soc.v|tb_pe_spi_soc"
  # The frame buffer: 2 KB behind a byte interface, on the same SRAM macro
  # as the instruction memory (ADR-003). Byte granularity comes from the
  # macro's bit-mask port and the read lane is a register -- two silent
  # failure modes, both mutation-tested.
  "tb_pe_fbuf|../rtl/pe_fbuf.v|tb_pe_fbuf"

  # The 10BASE-T receive path, end to end on real RTL: raw Manchester
  # levels into pe_dru, through pe_manch and pe_crc, into pe_fbuf. Every
  # other Ethernet TB models the framing in the testbench; this drives a
  # wire, so the bytes checked are the bytes a real receiver recovers.
  "tb_pe_eth_mac|../rtl/pe_dru.v ../rtl/pe_line_codec.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v|tb_pe_eth_mac"
)

pass=0; fail=0; failed_names=()

if [ "$FAST" -eq 1 ]; then
  # ---- parallel path --------------------------------------------------------
  # PARALLELISM, NOT A DIFFERENT SIMULATOR, and that is a measured decision.
  #
  # The obvious reading of "fast mode" is to swap iverilog for Verilator, which
  # is 12-19x faster per run. Measured, that makes THIS SUITE 69.6x SLOWER:
  # Verilator compiles one testbench at a time (median 5.6 s, max 33.7 s, no
  # shared cache across --top-module), so 24 testbenches need 24 builds -- 167 s
  # against 2.4 s for all 24 iverilog compiles AND runs. The per-run speedup is
  # real but it is paid back at ~27 runs of the SAME testbench, and a regression
  # suite runs each testbench once. See wiki/reference/simulator-bakeoff.md.
  #
  # What the suite is actually short of is CONCURRENCY: 24 independent cases on
  # 24 hardware threads, run one at a time. That is the win, and it needs no new
  # simulator, so it cannot weaken verification by being 2-state.
  #
  # VERILATOR'S ONE HARD BLOCKER, recorded here because it is the reason a
  # `--fast --verilator` flag does not exist: tb_pe_pinmux.v models the bus at
  # STRENGTH LEVELS (pull-up vs strong 0/1, so the od bit's contention property
  # is testable) and Verilator aborts it with
  #   %Error-DIDNOTCONVERGE ... Active region did not converge
  # 2-state simulation cannot express the weak/strong distinction the TB is
  # built on. So the fast path stays on the 4-state simulator, where it belongs.
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT

  printf '%s\n' "${CASES[@]}" \
    | xargs -P "$JOBS" -I{} "$REPO_ROOT/tb/run_one_tb.sh" "{}" "$work"

  # Read the verdicts back IN CASES ORDER. Collecting into files and printing
  # afterwards is what keeps one table row per case: letting the workers print
  # directly would interleave, and a verdict could appear under another case's
  # name.
  for c in "${CASES[@]}"; do
    IFS='|' read -r name rtl top <<< "$c"
    result="$work/$top.result"
    if [ ! -f "$result" ]; then
      printf '%-18s NO-RESULT (worker died without writing one)\n' "$top"
      fail=$((fail+1)); failed_names+=("$top(no-result)")
      continue
    fi
    verdict=$(head -1 "$result")
    if [ "$verdict" = "PASS" ]; then
      printf '%-18s PASS\n' "$top"
      pass=$((pass+1))
    else
      printf '%-18s %s\n' "$top" "$verdict"
      tail -n +2 "$result" | sed 's/^/  /'
      fail=$((fail+1)); failed_names+=("$top")
    fi
  done
else
  # ---- serial path (default) ------------------------------------------------
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
fi

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
# The RENDERED form in diagrams/ is what a reader can actually look at (the page
# carries mermaid source, which a terminal cannot draw). Timestamp check only:
# mermaid-cli output embeds a generated id and is not byte-stable across runs.
# Skipped when npx is absent rather than failing a regression on a tool the repo
# does not otherwise need -- the page is still correct, just not re-rendered.
if command -v npx >/dev/null 2>&1; then
  if python3 tools/render_block_diagram.py --check >/dev/null 2>&1; then
    echo "rendered block diagrams up to date"
  else
    echo "STALE: diagrams/block-diagram-*.svg — run python3 tools/render_block_diagram.py"
    stale=1
  fi
else
  echo "rendered block diagrams: SKIPPED (no npx for mermaid-cli)"
fi

# The Canvas viewer's own arithmetic. It renders every diagram in diagrams/, so
# a sizing bug there makes a correct diagram look broken -- which is exactly what
# happened: width="100%" was parsed as an intrinsic 100 px. This checks the
# shipped FRAME_SCRIPT by running it, and mutation-tests both fixes.
if python3 tools/check_canvas_viewer.py > /tmp/canvas_viewer.log 2>&1; then
  echo "canvas viewer: OK"
else
  echo "canvas viewer: FAILED"
  cat /tmp/canvas_viewer.log
  stale=1
fi

# The I2C pin timing, measured on the wire across all 60 tick phases against the
# standard-mode table. This is a SPEC check, so it runs every time rather than on
# request -- a firmware edit that shortens a delay is exactly the change that
# looks harmless in review.
if python3 tools/measure_i2c_timing.py > /tmp/i2c_timing.log 2>&1; then
  echo "i2c pin timing: OK (tLOW/tHIGH/period clear their floors)"
else
  echo "i2c pin timing: FAILED"
  cat /tmp/i2c_timing.log
  stale=1
fi

# The I2C testbench's own mutation suite. It is slower than the rest, but a
# testbench nobody mutation-tests is a testbench that quietly stops testing --
# and this one has already been caught being vacuous twice (a wrong edge index
# that made both interval checks unfailable, and a missing interval check).
if ./tb/mutate_i2c_tb.sh > /tmp/mutate_i2c.log 2>&1; then
  echo "i2c TB mutations: OK (no unexplained survivors)"
else
  echo "i2c TB mutations: FAILED"
  tail -20 /tmp/mutate_i2c.log
  stale=1
fi

# The SPI testbench's mutation suite. Same reasoning: SPI is a baseline protocol
# and its TB makes a strong claim (the slave decodes the master's byte MSB-first
# from the pins), so the claim is tested by making it false.
if ./tb/mutate_spi_tb.sh > /tmp/mutate_spi.log 2>&1; then
  echo "spi TB mutations: OK (no unexplained survivors)"
else
  echo "spi TB mutations: FAILED"
  tail -20 /tmp/mutate_spi.log
  stale=1
fi

# The frame buffer's TB, mutation-tested on BOTH implementations (the macro and
# the FLOP=1 fallback), because the fallback exists to stand in for the macro --
# so a test that only covered one would leave that claim unchecked.
if ./tb/mutate_fbuf_tb.sh > /tmp/mutate_fbuf.log 2>&1; then
  echo "fbuf TB mutations: OK (no unexplained survivors)"
else
  echo "fbuf TB mutations: FAILED"
  tail -20 /tmp/mutate_fbuf.log
  stale=1
fi

if ./tb/mutate_eth_mac_tb.sh > /tmp/mutate_eth_mac.log 2>&1; then
  echo "eth_mac TB mutations: OK (no unexplained survivors)"
else
  echo "eth_mac TB mutations: FAILED"
  tail -20 /tmp/mutate_eth_mac.log
  stale=1
fi

[ "$stale" -eq 0 ] || exit 1
[ "$lint_rc" -eq 0 ] || { echo "lint gate FAILED (see above)"; exit 1; }
