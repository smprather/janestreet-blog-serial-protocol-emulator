#!/usr/bin/env bash
# fv_run.sh — ONE formal proof run, with the campaign's toolchain flags in ONE
# place. Both run_formal.sh and mutants.sh call this, so a flag can never be
# present in one harness and missing from the other: that is exactly how a
# campaign ends up with proofs that silently ignore their assumptions.
#
# usage: fv_run.sh <log-file> <top-module> <depth> <sources...>
# prints:  PROVED | COUNTEREXAMPLE | ERROR
#
# The toolchain (yosys' built-in `sat`; SymbiYosys and every SMT solver are
# absent on this host -- see run_formal.sh):
#
#   -set-init-zero   initial state is defined, not "anything" (without it the
#                    solver starts designs mid-frame and every claim fails for
#                    harness reasons)
#   -set-assumes     $assume cells are CONSTRAINTS. `sat` ignores them without
#                    this flag; verified with a minimal design whose
#                    `assume(1'b0)` changed nothing until the flag was added.
#                    Without it the reset discipline and every contract
#                    assumption in the wrappers are decoration.
#   chformal -assume -early  the reset-discipline assume is combinational and
#                    its enabling FF may be bypassed.
set -u
LOG="$1"; TOP="$2"; DEPTH="$3"; shift 3

# MEMORY BUDGET + SERIALIZATION (manager, 2026-09-25: two yosys runs diverged
# at 6+ GB and tripped the RAM runaway brake). Every proof runs under a hard
# address-space cap and a flock so only ONE yosys exists at a time. A run that
# dies here exits as ERROR with a truncated log - treat that as a STRATEGY
# SIGNAL (go inductive / fix the assertion), never retry deeper. Override with
# FORMAL_MEM_KB if a proof legitimately needs more.
if ( ulimit -v "${FORMAL_MEM_KB:-6000000}" 2>/dev/null; flock -w 14400 9 || exit 75; exec yosys -p "
    read_verilog -formal -sv $*;
    prep -top $TOP -flatten;
    opt -full;
    clk2fflogic; async2sync; dffunmap;
    chformal -assume -early;
    sat -seq $DEPTH -set-init-zero -set-assumes -prove-asserts -verify
  " ) 9>/tmp/chip-formal.lock > "$LOG" 2>&1; then
  if grep -q "no model found: SUCCESS" "$LOG"; then echo PROVED; else echo ERROR; fi
else
  if grep -q "no model found: SUCCESS" "$LOG"; then echo PROVED
  elif grep -q "model found: FAIL" "$LOG"; then echo COUNTEREXAMPLE
  else echo ERROR; fi
fi
