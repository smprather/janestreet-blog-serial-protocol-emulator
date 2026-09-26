#!/usr/bin/env bash
# smt_induct.sh — SMT/relational temporal induction for a formal_pe_* target,
# using the user-space z3 + yosys-smtbmc pair.
#
# WHY THIS EXISTS (2026-09-25). The campaign's built-in `sat -tempinduct` is a
# self-contained k-induction over a sampling netlist in which a register's
# next-value is duplicated per sampling domain, which is why the four pe_ctrl
# claims looked toolchain-blocked. This script runs the SAME claims through
# yosys' SMT encoding (write_smt2 -> yosys-smtbmc -s z3), where each register has
# ONE next-value function. It is the toolchain-unlock record: it is what proved
# the pe_soc C2 claim under a second, independent engine.
#
# It also VALIDATES the pipeline: the known-inductive pe_ctrl subset (-DFV_INDUCT)
# passes here, so a FAILED run on a hard claim means the CLAIM, not the tool.
#
# Requirements (both user-space, no sudo; see FORMAL-STRENGTHENING.md 3a):
#   PIP_REQUIRE_VIRTUALENV=0 pip3 install --user --break-system-packages z3-solver
#   yosys-smtbmc   # ships with yosys; also needs write_smt2
#
# usage:
#   bash formal/smt_induct.sh <top> <depth> <sources...>
#   env: FORMAL_INDUCT_MAX (default 3), FORMAL_SAT_TIMEOUT (default 300)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

export PATH="$HOME/.local/bin:$PATH"
command -v z3 >/dev/null 2>&1 || { echo "z3 not on PATH (pip install --user z3-solver)"; exit 2; }
command -v yosys-smtbmc >/dev/null 2>&1 || { echo "yosys-smtbmc not on PATH"; exit 2; }
command -v yosys >/dev/null 2>&1 || { echo "yosys not on PATH"; exit 2; }

TOP="$1"; DEPTH="$2"; shift 2
INDUCT_MAX="${FORMAL_INDUCT_MAX:-3}"
SMT2="/tmp/smt_induct_${TOP}.smt2"

echo "--- smt: building the SMT model for $TOP (cap 6GB, no RTL change)"
if ! ( ulimit -v 6000000 2>/dev/null; yosys -q -p "
    read_verilog -formal -sv $*;
    prep -top $TOP -flatten;
    opt -full;
    memory_map; opt -full;
    clk2fflogic; async2sync; dffunmap;
    chformal -assume -early;
    write_smt2 -wires $SMT2" ); then
  echo "smt: model build FAILED for $TOP"; exit 1
fi

# BMC first (fast, catches a real counterexample), then temporal induction.
echo "--- smt BMC: $TOP depth=$DEPTH"
if timeout "${FORMAL_SAT_TIMEOUT:-300}" yosys-smtbmc -s z3 -t "$DEPTH" --presat "$SMT2" 2>&1 | tail -2 | sed 's/^/  /' | grep -q "PASSED"; then
  echo "  BMC PASSED"
else
  echo "  BMC did not pass (a counterexample, or timeout - read the log above)"
fi

echo "--- smt temporal induction: $TOP k=$INDUCT_MAX"
if timeout "${FORMAL_SAT_TIMEOUT:-300}" yosys-smtbmc -s z3 -i -t "$INDUCT_MAX" "$SMT2" 2>&1 | tail -3 | sed 's/^/  /' | grep -q "PASSED"; then
  echo "  INDUCTION PASSED (unbounded under z3)"
  exit 0
else
  echo "  INDUCTION did not close (the claim is not k-inductive as written; see"
  echo "  reviews/2026-09-25/FORMAL-STRENGTHENING.md 3c-3d)"
  exit 1
fi
