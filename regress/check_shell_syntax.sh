#!/usr/bin/env bash
# check_shell_syntax.sh — every shell script in regress/ must PARSE.
#
# WHY THIS EXISTS, and it is not hypothetical. While wiring the harness-edit
# pre-flight I broke regress/run_lock.sh with a scripted insertion, and my
# verification said "all parse". The reason it lied is the reason this file
# exists:
#
#     bash -n regress/*.sh        # <-- checks ONLY the first file
#
# `bash -n a.sh b.sh` parses a.sh and passes b.sh, c.sh, … as POSITIONAL
# PARAMETERS. So the one-liner every shell script in a project reaches for
# silently validates one file out of twenty, and the ones it does not check are
# exactly the ones a glob puts last. The broken file here was run_lock.sh —
# sourced by all sixteen mutation harnesses — and the visible symptom was not a
# syntax error at all: the suites still ran, still reported their real verdicts,
# and every one of them exited 4. A run that produces correct results and a wrong
# exit code is the shape of thing that gets "worked around".
#
# So: one file per invocation, and the count of files checked is PRINTED, so a
# silently-narrowed check is visible in the log.
set -u
cd "$(dirname "$0")/.." || exit 1

bad=0; n=0
for f in regress/*.sh; do
  n=$((n + 1))
  if ! err=$(bash -n "$f" 2>&1); then
    echo "FAIL $f: $(printf '%s' "$err" | head -2 | tr '\n' ' ')"
    bad=$((bad + 1))
  fi
done
# The count is the point: `bash -n` over a glob checks one file, and a check that
# quietly covered 1 of 20 would look exactly like one that covered 20.
if [ "$n" -lt 5 ]; then
  echo "check_shell_syntax: only $n script(s) found — expected the whole regress/ set" >&2
  exit 1
fi
if [ "$bad" -ne 0 ]; then
  echo "check_shell_syntax: $bad of $n scripts FAILED to parse"
  exit 1
fi
echo "check_shell_syntax: $n scripts, each parsed on its own (one bash -n per file)"
