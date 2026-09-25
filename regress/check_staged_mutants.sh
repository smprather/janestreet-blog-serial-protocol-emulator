#!/usr/bin/env bash
# Refuse to stage live mutation-harness leftovers in RTL/TB (the 2026-09-25
# ecb2b13/3d979ba incidents: manager git add -A swept up in-flight mutants).
# Scoped to rtl/ + tb/ paths so tooling that mentions the word is committable.
if git diff --cached -- rtl/ tb/ | grep "^+" | grep -E "MUTANT" | grep -q .; then
  echo "pre-commit: REFUSING - staged rtl/tb additions contain MUTANT (a mutation run is in flight or was interrupted):" >&2
  git diff --cached -- rtl/ tb/ | grep "^+" | grep -E "MUTANT" | head -5 >&2
  echo "  Wait for the run to finish (or restore from the harness snapshot), then re-stage." >&2
  exit 1
fi
