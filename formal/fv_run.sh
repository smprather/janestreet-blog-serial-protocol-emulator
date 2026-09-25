#!/usr/bin/env bash
# fv_run.sh — ONE formal proof run, with the campaign's toolchain flags in ONE
# place. Both run_formal.sh and mutants.sh call this, so a flag can never be
# present in one harness and missing from the other: that is exactly how a
# campaign ends up with proofs that silently ignore their assumptions.
#
# usage: fv_run.sh <log-file> <top-module> <depth> <sources...>
# prints:  PROVED | COUNTEREXAMPLE | NOTPROVED | ERROR
#
# env: FORMAL_SAT_MODE=bmc|induct (default bmc; induct = unbounded proof)
#      FORMAL_MEM_KB, FORMAL_SAT_TIMEOUT, FORMAL_INDUCT_MAX
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

# PROOF SHAPE (manager ruling 2026-09-25: a cap-kill is a strategy signal, so
# shape the proof to the design instead of deepening). FORMAL_SAT_MODE=induct
# runs temporal induction -- base case AND induction step -- which is an
# UNBOUNDED proof. The induction search is bounded too (-maxsteps): if the
# claims are not inductive within it, that is a FINDING about the modelling,
# not a reason to raise maxsteps.
# SUCCESS IS SPELLED DIFFERENTLY BY THE TWO PROOF SHAPES. BMC prints
# "no model found: SUCCESS"; temporal induction prints "Induction step proven:
# SUCCESS!". Grepping only the BMC spelling made every successful induction
# run report ERROR (caught while bisecting 3b -- the log said SUCCESS while the
# harness said ERROR, which would have sent the next session chasing a proof
# that already closed).
fv_is_success() {
  grep -qE "no model found: SUCCESS|Induction step proven: SUCCESS" "$1"
}
# An INDUCTION FAILURE IS NOT A COUNTEREXAMPLE. yosys reports "Reached maximum
# number of time steps -> proof failed" (or the induction step's model); it
# means the claim set did not close at that length -- a modelling signal, not a
# witness. Distinguishing the two matters: a mutant case wants "not PROVED",
# while a clean proof wants to know the shape is wrong rather than that the RTL
# is broken.
fv_is_notproved() {
  grep -qE "Reached maximum number of time steps|Temporal induction failed|proof failed" "$1"
}

# Some designs (pe_soc) contain $mem cells the SAT engine cannot model; the
# caller sets FORMAL_MEMORY_MAP=1 to lower them to registers first.
MEM_MAP_CMD=""
[ "${FORMAL_MEMORY_MAP:-0}" = 1 ] && MEM_MAP_CMD="memory_map; opt -full;"

case "${FORMAL_SAT_MODE:-bmc}" in
  induct) SAT="sat -tempinduct -seq $DEPTH -initsteps ${FORMAL_INDUCT_INIT:-1} \
                -stepsize ${FORMAL_INDUCT_STEP:-1} -maxsteps ${FORMAL_INDUCT_MAX:-8} \
                -timeout ${FORMAL_SAT_TIMEOUT:-120} \
                -set-init-zero -set-assumes -prove-asserts -verify" ;;
      *)  SAT="sat -seq $DEPTH -set-init-zero -set-assumes -prove-asserts -verify \
                -timeout ${FORMAL_SAT_TIMEOUT:-600}" ;;
esac

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
    ${MEM_MAP_CMD}
    clk2fflogic; async2sync; dffunmap;
    chformal -assume -early;
    $SAT
  " ) 9>/tmp/chip-formal.lock > "$LOG" 2>&1; then
  if fv_is_success "$LOG"; then echo PROVED; else echo ERROR; fi
else
  if fv_is_success "$LOG"; then echo PROVED
  elif grep -q "model found" "$LOG"; then echo COUNTEREXAMPLE
  elif fv_is_notproved "$LOG"; then echo NOTPROVED
  else echo ERROR; fi
fi
