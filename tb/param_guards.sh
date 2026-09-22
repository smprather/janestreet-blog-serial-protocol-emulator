#!/usr/bin/env bash
# tb/param_guards.sh — verify that the blocks with elaboration guards actually
# REJECT the parameters they claim to reject.
#
# WHY THIS EXISTS
#
# A guard that never fires is indistinguishable from no guard, and a guard whose
# bound is wrong is worse than none because it reads as protection. `pe_dru`
# grew a second constraint the hard way: `phase` is 4 bits and the wrap constant
# is `4'(SPB - 1)`, which SILENTLY TRUNCATES above 16. At SPB=20 the counter
# wraps at phase 3 instead of 19, never reaches either capture phase, and the
# block emits nothing at all -- no error, no output, no failing signal. The
# existing `SPB % 4 == 0` guard did not cover it, and every testbench pinned
# SPB at its default, so nothing noticed.
#
# The lesson generalises: **a parameterised block is only tested at the
# parameter values something actually instantiates.** This script closes the
# boundary explicitly, for each guarded parameter, by compiling the block at
# an out-of-range value and requiring a hard failure.
#
# Usage: ./tb/param_guards.sh     (wired into run_all.sh)

set -u
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0

# check_rejects <name> <expected substring> <rtl files...> -- <iverilog args for the override>
# Compiles a throwaway TB that instantiates the DUT with an out-of-range
# parameter and requires iverilog to FAIL, mentioning <expected substring>.
check_rejects() {
  local name="$1" expect="$2" src="$3" override="$4"
  local tmpdir
  tmpdir=$(mktemp -d)
  # A minimal TB whose only job is to elaborate the DUT at the bad parameter.
  cat > "$tmpdir/elab.v" <<EOF
\`timescale 1ns / 1ps
module elab_top;
  logic clk = 0, rst_n = 0, rx_pin = 1, cfg_filter_en = 0;
  logic [7:0] cfg_lock_bits = 0;
  logic bit_en, rx_first, rx_second, rx_wire, locked;
  logic [3:0] dbg_phase;
  $override dut (.clk(clk), .rst_n(rst_n), .rx_pin(rx_pin),
                 .cfg_filter_en(cfg_filter_en), .cfg_lock_bits(cfg_lock_bits),
                 .bit_en(bit_en), .rx_first(rx_first), .rx_second(rx_second),
                 .rx_wire(rx_wire), .locked(locked), .dbg_phase(dbg_phase));
endmodule
EOF
  if out=$(iverilog -g2012 -s elab_top -o "$tmpdir/elab.vvp" $src "$tmpdir/elab.v" 2>&1); then
    printf '%-34s FAIL (compiled -- guard did not reject)\n' "$name"
    fail=$((fail + 1))
  elif grep -q "$expect" <<< "$out"; then
    printf '%-34s rejected OK\n' "$name"
    pass=$((pass + 1))
  else
    printf '%-34s FAIL (rejected, but not with the expected message)\n' "$name"
    grep -E 'ERROR|sorry' <<< "$out" | head -2
    fail=$((fail + 1))
  fi
  rm -rf "$tmpdir"
}

# pe_dru: SPB must be a multiple of 4 (the capture-phase constraint).
check_rejects "pe_dru SPB=9 (not %4)" \
  "SPB must be a multiple of 4" \
  "rtl/pe_dru.v" \
  "pe_dru #(.SPB(9))"

# pe_dru: SPB must be <= 16 (the 4-bit phase-counter constraint). This is the
# one that was missing, and the failure it caused was silent.
check_rejects "pe_dru SPB=20 (> 16, truncates)" \
  "SPB must be <= 16" \
  "rtl/pe_dru.v" \
  "pe_dru #(.SPB(20))"

# pe_dru: the boundary itself must be ACCEPTED, or the guard is off by one.
check_accepts() {
  local name="$1" src="$2" override="$3"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/elab.v" <<EOF
\`timescale 1ns / 1ps
module elab_top;
  logic clk = 0, rst_n = 0, rx_pin = 1, cfg_filter_en = 0;
  logic [7:0] cfg_lock_bits = 0;
  logic bit_en, rx_first, rx_second, rx_wire, locked;
  logic [3:0] dbg_phase;
  $override dut (.clk(clk), .rst_n(rst_n), .rx_pin(rx_pin),
                 .cfg_filter_en(cfg_filter_en), .cfg_lock_bits(cfg_lock_bits),
                 .bit_en(bit_en), .rx_first(rx_first), .rx_second(rx_second),
                 .rx_wire(rx_wire), .locked(locked), .dbg_phase(dbg_phase));
endmodule
EOF
  if out=$(iverilog -g2012 -s elab_top -o "$tmpdir/elab.vvp" $src "$tmpdir/elab.v" 2>&1); then
    printf '%-34s accepted OK\n' "$name"
    pass=$((pass + 1))
  else
    printf '%-34s FAIL (should have been accepted)\n' "$name"
    grep -E 'ERROR|sorry' <<< "$out" | head -2
    fail=$((fail + 1))
  fi
  rm -rf "$tmpdir"
}

check_accepts "pe_dru SPB=16 (the boundary)" "rtl/pe_dru.v" "pe_dru #(.SPB(16))"
# The 60 MHz turbo grid. If this ever starts failing, ADR-005's RX plan is dead.
check_accepts "pe_dru SPB=12 (60 MHz turbo)" "rtl/pe_dru.v" "pe_dru #(.SPB(12))"

# ------------------------------------------------------------------ pe_pinmux
# check_pinmux <name> <expect|ACCEPT> <PINS value>
#
# pe_pinmux needs its own harness because its port list is nothing like the
# DRU's. It is written out longhand rather than generalised: parameterising the
# existing helpers over arbitrary port lists would make the DRU cases (the ones
# that caught a REAL silent truncation) harder to read, and these three cases
# are not worth that.
#
# The guard matters because the register file is addressed by 2 bits and the
# vectors go to [-1:0] at PINS=0 -- a reversed range that iverilog accepts
# without a word, so without the guard the module would elaborate and quietly
# do the wrong thing.
check_pinmux() {
  local name="$1" expect="$2" pins="$3"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/elab.v" <<EOF
\`timescale 1ns / 1ps
module elab_top;
  localparam int P = $pins;
  logic clk = 0, rst_n = 0, we = 0;
  logic [1:0] addr = 0;
  logic [P-1:0] wdata = 0, rdata, pad_in = 0, pad_out, pad_oe;
  pe_pinmux #(.PINS(P)) dut (.clk(clk), .rst_n(rst_n), .we(we), .addr(addr),
                             .wdata(wdata), .rdata(rdata), .pad_in(pad_in),
                             .pad_out(pad_out), .pad_oe(pad_oe));
endmodule
EOF
  if out=$(iverilog -g2012 -s elab_top -o "$tmpdir/elab.vvp" rtl/pe_pinmux.v "$tmpdir/elab.v" 2>&1); then
    if [ "$expect" = "ACCEPT" ]; then
      printf '%-34s accepted OK\n' "$name"; pass=$((pass + 1))
    else
      printf '%-34s FAIL (compiled -- guard did not reject)\n' "$name"; fail=$((fail + 1))
    fi
  else
    if [ "$expect" = "ACCEPT" ]; then
      printf '%-34s FAIL (should have been accepted)\n' "$name"
      grep -E 'ERROR|sorry' <<< "$out" | head -2
      fail=$((fail + 1))
    elif grep -q "$expect" <<< "$out"; then
      printf '%-34s rejected OK\n' "$name"; pass=$((pass + 1))
    else
      printf '%-34s FAIL (rejected, but not with the expected message)\n' "$name"
      grep -E 'ERROR|sorry' <<< "$out" | head -2
      fail=$((fail + 1))
    fi
  fi
  rm -rf "$tmpdir"
}

check_pinmux "pe_pinmux PINS=0 (reversed range)" "PINS must be >= 1" 0
check_pinmux "pe_pinmux PINS=9 (> 8)"            "PINS must be <= 8" 9
check_pinmux "pe_pinmux PINS=8 (the boundary)"   "ACCEPT"            8
check_pinmux "pe_pinmux PINS=1 (the other end)"  "ACCEPT"            1

echo
echo "param guards: $pass rejected/accepted as specified, $fail wrong"
[ "$fail" -eq 0 ] || exit 1
