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
#   6. the R2 AND R3 verification package drift checks (r2_vectors/r3_vectors
#      --check): the chip-side golden vectors must still match a fresh build
#      of the model. R3 is the debug-control package (opcodes 0x21-0x24),
#      reconciled against the implemented pe_ctrl.v contract; like R2 it is a
#      gate the chip must pass, NOT evidence that it does, and every R3 step
#      is chip_confirmed=false until tb_pe_ctrl_r3 passes it byte-exactly.
#   7. the MicroPython conformance run of the deployed bridge modules, when a
#      `micropython` interpreter is available - on PATH, or named by
#      $MICROPYTHON (skipped with a note otherwise). A check that only runs when
#      someone happens to have it on PATH is a check that mostly does not run:
#      this environment has a built unix port that is NOT on PATH, so the step
#      skipped while the thing it guards was perfectly runnable.
#   8. the deploy helper's dry run (payload manifest; the unit tests also
#      exercise the real install and its refusals).
#   9. a bounded protocol-fuzz campaign against both frame decoders and the
#      chip-side model (hostile frames/requests; every crash or misdecode is
#      a finding).
#  10. a bounded server/API-fuzz campaign against the FastAPI routes, the
#      session state machine, a hostile bridge and concurrent requests
#      (wrong-state sequences, huge/malformed bodies, reconnect storms,
#      crossed/stolen replies; every crash or misdecode is a finding).
#  11. a soak smoke run of the bridge+session+API loop under the RSS watch
#      (the runner and its analysis; the full 20-minute soak is a manual,
#      recorded run - see reviews/2026-09-25/HOST-SOAK-API-FUZZ.md).
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
run "R3 debug vector package" python3 -m tools.host_gui.r3_vectors --check
run "protocol fuzz" python3 -m tools.host_gui.fuzz_protocol -n 2000
run "server fuzz" python3 -m tools.host_gui.fuzz_server -n 120 --rounds 10
run "soak smoke" python3 -m tools.host_gui.soak_host --minutes 0 --cycles 300 \
    --sample-every 50 --sample-seconds 1 --max-growth-mb 64 \
    --max-object-growth 200000
run "acceptance --fake" python3 tools/host_bridge/acceptance.py --fake

# The deployed bridge must import and run on MicroPython. This runs the same
# conformance harness on both interpreters when a micropython binary is
# available (build the unix port: git clone micropython && make -C ports/unix).
# The interpreter to use when one is not on PATH. A unix-port build is a local
# artifact at an arbitrary path, so this is opt-in and the default is unchanged.
MICROPYTHON_BIN="${MICROPYTHON:-micropython}"
if command -v "$MICROPYTHON_BIN" >/dev/null 2>&1; then
    run "micropython conformance (bridge)" \
        "$MICROPYTHON_BIN" tools/host_bridge/micropython_check.py
else
    printf '\n=== micropython conformance (bridge) ===\n[skip] no MicroPython interpreter (build the unix port, or set MICROPYTHON=/path/to/micropython)\n'
fi

printf '\n=== host gate: %s ===\n' "$([ "$failed" -eq 0 ] && echo PASS || echo FAIL)"
exit "$failed"
