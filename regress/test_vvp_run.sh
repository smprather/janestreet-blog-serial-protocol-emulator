#!/usr/bin/env bash
# test_vvp_run.sh — prove the wall-clock bound on a simulation, on REAL
# compiled testbenches, before the harness is allowed to depend on it.
#
# WHY THIS TEST EXISTS. On 2026-09-27 a testbench that never reached $finish
# did not fail: vvp spun a core at 100% and printed nothing, for ~10 minutes,
# across a --fast fan-out wide enough to pin all 24 cores. The unbounded
# processes accumulated until user-1000.slice hit TasksMax=84178, the desktop
# could no longer fork, and the graphical session died to a login screen. The
# suite's own record of that period says a run "printed NO summary, NO survivor
# count and no error text" -- i.e. the hang was indistinguishable from silence.
#
# So the thing under test is a NAME, not a number: a hang must arrive as a
# named verdict. Cases below are compiled for real with iverilog and run for
# real with vvp. Nothing is stubbed.
#
# SELF-GUARD. The regression this test exists for is a HANG, so a broken
# implementation would hang the test that proves it. Every case therefore runs
# under its own `timeout`, and the file is designed to be invoked as
#   timeout 120 regress/test_vvp_run.sh
# so a broken vvp_run.sh fails the test instead of wedging the suite.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
VVP_RUN="$HERE/vvp_run.sh"
WORK="$(mktemp -d /tmp/pe-vvprun-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
expect() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

# Build a testbench from a body and return its compiled .vvp on stdout.
# $1 = label, $2 = initial-block body. A body with no $finish is the hang case.
build() {
  local label="$1" body="$2" src="$WORK/$1.v" out="$WORK/$1.vvp"
  # printf, NOT a heredoc. The first version of this test used an unquoted
  # heredoc and wrote `display(...)` without the dollar sign, so iverilog
  # rejected two cases with "Enable of unknown task ``display''" and the test
  # blamed the wall-clock bound for a typo in its own fixture. printf has no
  # expansion hazard at all, whatever the body contains.
  {
    printf 'module %s;\n'     "$label"
    printf '  initial begin\n'
    printf '    %s\n'         "$body"
    printf '  end\n'
    printf 'endmodule\n'
  } >"$src"
  iverilog -g2012 -s "$label" -o "$out" "$src" 2>"$WORK/$label.cc.log" || return 1
  printf '%s' "$out"
}

# Run vvp_run.sh under a hard outer bound, capture verdict (line 1) and seconds.
run_case() { # timeout_seconds vvp_path
  local t0 t1 rc out
  t0=$(date +%s)
  out=$(timeout 30 "$VVP_RUN" "$1" "$2" 2>&1); rc=$?
  t1=$(date +%s)
  printf '%s|%s|%s' "$(printf '%s\n' "$out" | head -1)" "$((t1-t0))" "$rc"
}

echo "vvp_run self-test: $(basename "$0")"
echo "work: $WORK"

# ---- 0. the bound helper must exist and be executable -----------------------
if [ -x "$VVP_RUN" ]; then ok "vvp_run.sh exists and is executable"; else
  bad "vvp_run.sh exists and is executable" "$VVP_RUN not found or not +x"
  echo "vvp_run self-test: FAILED ($FAIL of $((PASS+FAIL)) cases failed)"
  exit 1
fi

# ---- 1. a terminating PASS testbench still passes ---------------------------
if p=$(build ok_tb '$display("PASS"); $finish;'); then
  IFS='|' read -r v el rc <<<"$(run_case 30 "$p")"
  expect "a finishing PASS testbench -> PASS" "PASS" "$v"
  expect "  ...and it is fast (under 30s)" "yes" "$([ "$el" -lt 30 ] && echo yes || echo "no (${el}s)")"
else
  bad "compile the PASS testbench" "$(head -2 "$WORK/ok_tb.cc.log")"
fi

# ---- 2. a failing testbench still fails, and keeps its FAIL detail ----------
if p=$(build bad_tb '$display("FAIL: something broke"); $finish;'); then
  IFS='|' read -r v el rc <<<"$(run_case 30 "$p")"
  expect "a failing testbench -> FAIL" "FAIL" "$v"
  out=$(timeout 30 "$VVP_RUN" 30 "$p" 2>&1)
  if grep -q 'something broke' <<<"$out"; then ok "  ...and the FAIL detail survives the bound"
  else bad "  ...and the FAIL detail survives the bound" "$(printf '%s' "$out" | head -3)"; fi
else
  bad "compile the FAIL testbench" "$(head -2 "$WORK/bad_tb.cc.log")"
fi

# ---- 3. THE CASE THAT MATTERS: a hang is named, and is bounded in time ------
# No $finish anywhere. Before the bound existed this ran forever and said
# nothing at all, which is the failure mode this whole file exists for.
if p=$(build hang_tb 'forever #1;'); then
  IFS='|' read -r v el rc <<<"$(run_case 3 "$p")"
  expect "a testbench that never terminates -> TIMEOUT" "TIMEOUT" "$v"
  expect "  ...and it RETURNS (bounded, not wedged)" "yes" \
         "$([ "$el" -le 12 ] && echo yes || echo "no (${el}s for a 3s bound)")"
  out=$(timeout 30 "$VVP_RUN" 3 "$p" 2>&1)
  if grep -qiE 'never terminated|hung|no \$finish|did not finish' <<<"$out"; then
    ok "  ...and the detail says WHY, in words"
  else
    bad "  ...and the detail says WHY, in words" "$(printf '%s' "$out" | head -3)"
  fi
else
  bad "compile the hanging testbench" "$(head -2 "$WORK/hang_tb.cc.log")"
fi

# ---- 4. a hang is a verdict, not a crash: the runner still exits 0 ----------
# The contract is that the VERDICT carries the result. A caller reading stdout
# must never mistake the bound firing for the harness itself erroring.
if p=$(build hang_tb2 'forever #1;'); then
  out=$(timeout 30 "$VVP_RUN" 3 "$p" 2>&1); rc=$?
  expect "a TIMEOUT still exits 0 (verdict carries the result)" "0" "$rc"
else
  bad "compile the second hanging testbench" "$(head -2 "$WORK/hang_tb2.cc.log")"
fi

# ---- 5. a missing binary is a FAIL verdict, not a hang and not a crash -----
IFS='|' read -r v el rc <<<"$(run_case 5 "$WORK/does_not_exist.vvp")"
expect "a missing .vvp -> FAIL (named, immediate)" "FAIL" "$v"
expect "  ...and it does not wait for the timeout" "yes" \
       "$([ "$el" -le 3 ] && echo yes || echo "no (${el}s)")"

# ---- 6. the bound is configurable, not hard-wired --------------------------
# The mutation harnesses already use 120/300/600s; the main suite needs its
# own ceiling. A single fixed number in the helper would be wrong for both.
if p=$(build hang_tb3 'forever #1;'); then
  IFS='|' read -r v1 el1 rc <<<"$(run_case 2 "$p")"
  IFS='|' read -r v2 el2 rc <<<"$(run_case 8 "$p")"
  expect "a 2s bound and an 8s bound both yield TIMEOUT" "TIMEOUT|TIMEOUT" "$v1|$v2"
  if [ "$el2" -gt "$el1" ]; then ok "  ...and the larger bound measurably waits longer"
  else bad "  ...and the larger bound measurably waits longer" "2s->${el1}s, 8s->${el2}s"; fi
else
  bad "compile the third hanging testbench" "$(head -2 "$WORK/hang_tb3.cc.log")"
fi

# ---- verdict ----------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then
  echo "vvp_run self-test: OK ($PASS of $PASS cases proved the bound)"
  exit 0
fi
echo "vvp_run self-test: FAILED ($FAIL of $((PASS+FAIL)) cases failed)"
exit 1
