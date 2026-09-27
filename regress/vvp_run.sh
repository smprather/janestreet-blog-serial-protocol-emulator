#!/usr/bin/env bash
# vvp_run.sh — run ONE compiled Icarus simulation under a wall-clock bound and
# print a NAMED verdict.
#
# WHY THIS EXISTS (2026-09-27, the session-death incident). A testbench that
# never reaches $finish does not fail. vvp spins one core at 100% and prints
# nothing, and nothing in the suite noticed for ten minutes across a --fast
# fan-out. Those unbounded processes accumulated until user-1000.slice hit its
# pids limit (TasksMax=84178), the desktop could no longer fork a thread, and
# the graphical session was torn down to a login screen. The suite's own record
# of that window says a run "printed NO summary, NO survivor count and no error
# text" - a hang was indistinguishable from silence, which is why the cause took
# a forensic session to attribute.
#
# A hang is a defect WITH A NAME. This gives it one. The bound is not only a
# safety rail, it is a correctness fix: without it, "hung" and "passed" and
# "crashed" all look like the same silence.
#
# The bound kills the child, not the caller: `timeout` is deliberately run
# WITHOUT --foreground so the command gets its own process group and the TERM
# reaches any grandchildren too. A half-killed simulation that leaves an orphan
# vvp behind would reproduce the very leak this file exists to stop.
#
# Usage:
#   vvp_run.sh <timeout-seconds> <compiled.vvp>
#
# Contract:
#   stdout line 1  the verdict: PASS | FAIL | TIMEOUT
#   stdout rest    detail (the testbench's own FAIL lines, or why it hung)
#   exit 0         ALWAYS for a verdict. The VERDICT carries the result, so a
#                  caller reading stdout is never misled by a non-zero status
#                  that only means "the bound fired". Exit 2 is reserved for a
#                  usage error, which is a bug in the CALLER, not a test result.
set -u

usage() { echo "usage: $(basename "$0") <timeout-seconds> <compiled.vvp>" >&2; }

tmo="${1:-}"
bin="${2:-}"
if [ $# -ne 2 ]; then usage; exit 2; fi
case "$tmo" in
  ''|*[!0-9]*) echo "$(basename "$0"): timeout must be a positive integer, got '$tmo'" >&2; exit 2;;
esac
if [ "$tmo" -le 0 ]; then
  echo "$(basename "$0"): timeout must be greater than zero, got '$tmo'" >&2; exit 2
fi

# A missing binary is a named failure, not a hang: the bound must not be spent
# waiting for something that was never going to run.
if [ ! -f "$bin" ]; then
  printf 'FAIL\n'
  printf 'no compiled simulation at %s -- nothing was run\n' "$bin"
  exit 0
fi

# -k 5: if the child ignores TERM it still dies 5s later. A simulation that
# survives its own bound is exactly the leak this guards against.
out=$(timeout -k 5 "$tmo" vvp "$bin" 2>&1); rc=$?

# 124 = the bound fired. 137 = the child needed the -k SIGKILL. Both are hangs.
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  printf 'TIMEOUT\n'
  printf 'did not finish within %ss: no $finish was reached, so the testbench is hung.\n' "$tmo"
  printf 'It was stopped here rather than left spinning a core. Treat this as a\n'
  printf 'testbench defect (an unbounded wait or a clock that never advances),\n'
  printf 'not as a slow pass.\n'
  # Whatever it managed to print before the bound is still evidence.
  grep -E '^(FAIL|ERROR|Warning)' <<<"$out" | head -5 | sed 's/^/  /'
  exit 0
fi

if grep -q '^PASS' <<<"$out"; then
  printf 'PASS\n'
else
  printf 'FAIL\n'
  grep -E '^FAIL' <<<"$out" | head -5 | sed 's/^/  /'
  # A simulation that exited non-zero without printing a single FAIL line has
  # still told us something; say so rather than printing nothing at all.
  if [ "$rc" -ne 0 ] && ! grep -qE '^FAIL' <<<"$out"; then
    printf '  (vvp exited %s with no FAIL line)\n' "$rc"
    head -3 <<<"$out" | sed 's/^/  /'
  fi
fi
exit 0
