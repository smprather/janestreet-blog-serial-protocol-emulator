#!/usr/bin/env bash
# run_host_tests.sh — the one-command gate on the host-controller stack.
#
# Usage:  tools/host_gui/run_host_tests.sh
# Exit:   0 = every host gate green, 1 = at least one failed
#
# WHY THIS EXISTS
#
# The host stack grew across several sessions (contracts, session/server, the
# Pico bridge, the R2 read contract, the acceptance runner), and every
# re-verification so far was a remembered list of five commands. A remembered
# list is exactly how a gate gets skipped or run against the wrong tree: a
# green run proves nothing if it was not the full set. This script is that full
# set, in one place, so "the host is green" is a single reproducible command.
#
# WHAT IT RUNS
#
#   1. host_gui unit tests   (contracts, transport, session, server, fakes)
#   2. host_bridge unit tests (bridge, fake ttboard/machine, host<->bridge,
#                             acceptance runner)
#   3. ruff over both packages
#   4. compileall over both packages (catches import-time syntax drift)
#   5. the acceptance dry run (acceptance.py --fake): the full scripted
#      connect->load->readback->start->stop->dump->fault->reconnect sequence
#      over the real host stack and the real bridge against fakes. It never
#      opens a serial device.
#   6. the R2 verification package drift check (r2_vectors --check): the
#      chip-side golden vectors must still match a fresh build of the model.
#   7. the MicroPython conformance run of the deployed bridge modules, when a
#      `micropython` binary is on PATH (skipped with a note otherwise).
#   8. the deploy helper's dry run (payload manifest; the unit tests also
#      exercise the real install and its refusals).
#
# IT IS NOT A CHIP GATE. Nothing here runs a testbench, the regression, or
# synthesis, and nothing here is evidence about silicon: the PE host protocol
# and the R2 read path are chip-side work (see reviews/2026-09-25/
# HOST-GUI-R2-PREP.md). The chip regression and the physical flow belong to
# the chip-side manager and to regress/run_all.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

failed=0
run() {
    local label="$1"; shift
    printf '\n=== %s ===\n' "$label"
    if "$@"; then
        printf '[ok]   %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        failed=1
    fi
}

run "host_gui tests"    python3 -m unittest discover -s tools/host_gui/tests -v
run "host_bridge tests" python3 -m unittest discover -s tools/host_bridge/tests -v
run "deploy helper (dry run)" tools/host_bridge/deploy.sh --dry-run

if command -v ruff >/dev/null 2>&1; then
    run "ruff" ruff check tools/host_gui tools/host_bridge
else
    printf '\n=== ruff ===\n[skip] ruff (not installed)\n'
fi

run "compileall" python3 -m compileall -q tools/host_gui tools/host_bridge
run "R2 vector package" python3 -m tools.host_gui.r2_vectors --check
run "acceptance --fake" python3 tools/host_bridge/acceptance.py --fake

# The deployed bridge must import and run on MicroPython. This runs the same
# conformance harness on both interpreters when a micropython binary is
# available (build the unix port: git clone micropython && make -C ports/unix).
if command -v micropython >/dev/null 2>&1; then
    run "micropython conformance (bridge)" \
        micropython tools/host_bridge/micropython_check.py
else
    printf '\n=== micropython conformance (bridge) ===\n[skip] micropython (not installed; see the runbook)\n'
fi

printf '\n=== host gate: %s ===\n' "$([ "$failed" -eq 0 ] && echo PASS || echo FAIL)"
exit "$failed"
