#!/usr/bin/env bash
# run_one_tb.sh — compile and run ONE testbench case, in isolation.
#
# Exists so tb/run_all.sh --fast can run the suite in parallel. The serial loop
# in run_all.sh is unchanged for the default path; this script is what the
# parallel path invokes once per case, in its own process, writing its own
# result file.
#
# WHY A HELPER SCRIPT AND NOT A BACKGROUND SUBSHELL
#
# The reason is RESULT COLLECTION, not working directories. run_all.sh's output
# is a table in CASES order; letting 24 processes write to stdout would produce
# a shuffled mess and, worse, a verdict from one case could land under another's
# name. Each run writes $workdir/<top>.result, which the parent reads back in
# the original order.
#
# The CWD is deliberately SHARED (sim/), not private, because testbenches write
# their VCDs relative to the process cwd and `--fast` must not change where
# artifacts appear -- only how fast they appear. The serial path leaves dumps in
# sim/, so this does too. That is safe because all 24 `$dumpfile` names in tb/
# are distinct (checked, not assumed); if that ever stops being true, --fast
# would produce interleaved dumps rather than a clean error, so it is worth
# re-checking whenever a testbench is added by copying another one.
#
# Usage: tb/run_one_tb.sh "name|rtl|top" <workdir>
# Always exits 0: the verdict travels in the result file, so one failing case
# cannot abort the parallel batch and hide the others.
set -u

case_spec="$1"
work="$2"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$work"

IFS='|' read -r name rtl top <<< "$case_spec"

# The SRAM behavioural model, resolved per-worker. Cheap (a couple of stat
# calls) and it keeps this script self-contained -- the alternative is threading
# the flags through xargs, where a quoting bug would silently compile against
# pe_imem's FLOP fallback instead of the real macro.
if ! SRAM_MODEL=$(cd "$REPO/sim" && "$REPO/tb/sram_model.sh"); then
  printf 'COMPILE-FAIL\nsram model unavailable\n' > "$work/$top.result"
  exit 0
fi
readarray -t SRAM_FLAGS <<< "$SRAM_MODEL"

cd "$REPO/sim" || { printf 'COMPILE-FAIL\ncannot enter sim/\n' > "$work/$top.result"; exit 0; }

err_file="$work/$top.err"
if ! iverilog -g2012 -s "$top" -o "$work/$top.vvp" $rtl "${SRAM_FLAGS[@]}" "../tb/${name}.v" 2>"$err_file"; then
  {
    printf 'COMPILE-FAIL\n'
    sed -n '1,3p' "$err_file"
  } > "$work/$top.result"
  exit 0
fi

# Run from the case's own private directory. The TB's $readmemh paths are
# "../firmware/*.hex", which resolve relative to the SIM directory, so the
# binary is invoked from sim/ and the dump lands in $work via the cwd below.
#
# NOTE: $dumpfile writes relative to the PROCESS cwd, and we are in sim/, so
# dumps land in sim/ exactly as the serial path leaves them. That is deliberate:
# --fast must not change where artifacts appear, only how fast they get there.
out=$(vvp "$work/$top.vvp" 2>&1)

{
  if grep -q '^PASS' <<< "$out"; then
    printf 'PASS\n'
  else
    printf 'FAIL\n'
    grep -E '^FAIL' <<< "$out" | head -5
  fi
} > "$work/$top.result"

exit 0
