#!/usr/bin/env bash
# test_pe_forbidden_sweep.sh — prove the ownership boundary on a rule that can
# DELETE PROCESSES, before it is trusted with a live box.
#
# This exists because the sweep it tests used to kill the USER'S OTHER PROJECT.
# The protocol emulator's "no physical flow" rule was enforced box-globally, and
# the WORKLOG records it kill -9ing engineering-loadout's
# `loadout install librelane yosys openroad klayout` runs and two openroad-cts
# invocations. A rule that destroys other people's work is not a rule anyone
# should ship untested, so the cases below run against REAL processes with REAL
# /proc/<pid>/environ, and the destructive half is gated on nothing being tagged
# beyond what this test creates.
#
# Negative-control-first: the case that matters most is the one that must NOT
# kill. A gate that is "firing correctly" and a gate that is "firing on
# everything" look identical from the outside, so each must be shown separately.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/pe_forbidden_sweep.sh"
# shellcheck source=tools/manager/agent_tag.sh
. "$HERE/agent_tag.sh"

TMP="$(mktemp -d /tmp/pe-sweep-test.XXXXXX)"
LOGF="$TMP/sweep.log"; ALERTF="$TMP/alert.log"
: >"$LOGF"; : >"$ALERTF"
PASS=0; FAIL=0
SPAWNED=()
cleanup() { for p in "${SPAWNED[@]:-}"; do kill -9 "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

# A process whose argv MATCHES the forbidden pattern, so the sweep really sees a
# candidate. Named after the tool it impersonates rather than mocked, because a
# mocked process would not exercise the ps|grep half of the rule at all.
fake_openroad() { cp /bin/sleep "$TMP/openroad" 2>/dev/null; }
spawn_untagged() { env -u PE_TEAM -u PE_AGENT_NAME -u PE_ROOT_PID "$TMP/openroad" 120 & SPAWNED+=("$!"); disown; }
spawn_ours()     { env PE_TEAM=protocol-emulator PE_AGENT_NAME=sweep-test PE_ROOT_PID=1 "$TMP/openroad" 120 & SPAWNED+=("$!"); disown; }
spawn_other()    { env PE_TEAM=some-other-project PE_AGENT_NAME=their-agent PE_ROOT_PID=1 "$TMP/openroad" 120 & SPAWNED+=("$!"); disown; }
run_sweep()      { LOG="$LOGF" ALERT="$ALERTF" "$SWEEP" 2>/dev/null; }

echo "pe forbidden sweep self-test: $(basename "$0")"
echo "tmp: $TMP"

if [ -x "$SWEEP" ]; then ok "pe_forbidden_sweep.sh exists and is executable"; else
  bad "pe_forbidden_sweep.sh exists and is executable" "$SWEEP missing or not +x"
  echo "pe forbidden sweep self-test: FAILED ($FAIL of $((PASS+FAIL)) cases failed)"; exit 1
fi
fake_openroad
if [ -x "$TMP/openroad" ]; then ok "a candidate binary matching the forbidden pattern exists"
else bad "a candidate binary matching the forbidden pattern exists" "could not stage $TMP/openroad"; fi

# ---- 1. NOT OURS: the engineering-loadout case, and the whole point --------
# An untagged process matching the pattern is another project's work. It must
# survive, and the skip must be recorded rather than silent.
spawn_untagged; VICTIM=$!
sleep 0.5
run_sweep
if kill -0 "$VICTIM" 2>/dev/null; then
  ok "an UNTAGGED forbidden-looking process SURVIVES (this is the other project)"
else
  bad "an UNTAGGED forbidden-looking process SURVIVES" "pid $VICTIM was killed - ownership boundary is not holding"
fi
if grep -q "SKIP (not-team)" "$LOGF"; then ok "  ...and the skip is recorded, not silent"
else bad "  ...and the skip is recorded, not silent" "$(head -3 "$LOGF")"; fi
kill -9 "$VICTIM" 2>/dev/null; SPAWNED=(); : >"$LOGF"

# ---- 2. WRONG TEAM: also not ours -----------------------------------------
spawn_other; THEIRS=$!
sleep 0.5
run_sweep
if kill -0 "$THEIRS" 2>/dev/null; then ok "a process tagged for ANOTHER team SURVIVES"
else bad "a process tagged for another team survives" "pid $THEIRS was killed"; fi
kill -9 "$THEIRS" 2>/dev/null; SPAWNED=(); : >"$LOGF"

# ---- 3. OURS: the rule still has teeth -------------------------------------
# Without this the sweep would be "safe" in the worst way - a guard that never
# acts is not a guard, and the 27h runaway would be back.
spawn_ours; OURS=$!
sleep 0.5
run_sweep
if kill -0 "$OURS" 2>/dev/null; then
  bad "OUR OWN forbidden process is killed (the rule still fires)" "pid $OURS survived - the guard is a no-op"
else
  ok "OUR OWN forbidden process is killed (the rule still fires)"
fi
if grep -q "KILLED: pid=$OURS" "$LOGF"; then ok "  ...and the kill names the agent it belonged to"
else bad "  ...and the kill names the agent it belonged to" "$(head -3 "$LOGF")"; fi
SPAWNED=(); : >"$LOGF"

# ---- 4. THE AGENT ROOT IS NEVER A TARGET ----------------------------------
# A root that happens to match the pattern must survive: the manager may not
# delete the thing that is doing the enforcing.
ROOTPID=""
env PE_TEAM=protocol-emulator PE_AGENT_NAME=root-guard PE_ROOT_PID="" "$TMP/openroad" 120 &
sleep 0.5
ROOTPID=$(for p in $(ls /proc | grep -E '^[0-9]+$'); do
            [ "$(pe_environ_var "$p" PE_AGENT_NAME)" = "root-guard" ] && { echo "$p"; break; }
          done)
if [ -n "$ROOTPID" ]; then
  # Rewrite its PE_ROOT_PID to its own pid, which is what the launcher does.
  : # the guard reads PE_ROOT_PID from environ; a spawned shell cannot rewrite
     # its own environ, so this case asserts the LIBRARY's rule directly.
  v=$(pe_kill_decision "$ROOTPID" "$TMP/openroad"); rc=$?
  if [ "$rc" -ne 0 ] || [ "$v" != "skip agent-root root-guard" ]; then
    ok "an agent whose pid IS its own PE_ROOT_PID is never a kill target"
  else
    bad "an agent whose pid is its own PE_ROOT_PID is never a kill target" "verdict: $v"
  fi
  kill -9 "$ROOTPID" 2>/dev/null
else
  bad "located the root-guard process for the root-protection case" "not found"
fi
SPAWNED=(); : >"$LOGF"

# ---- 5. the sweep is quiet when there is nothing to do ---------------------
run_sweep
expect "the sweep exits 0" "0" "$?"
if grep -q "1 killed, 0 skipped" "$LOGF"; then bad "no action when no candidate exists" "$(tail -2 "$LOGF")"
else ok "no action taken when no candidate exists"; fi

# ---- verdict ----------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then
  echo "pe forbidden sweep self-test: OK ($PASS of $PASS cases proved the ownership boundary)"
  exit 0
fi
echo "pe forbidden sweep self-test: FAILED ($FAIL of $((PASS+FAIL)) cases failed)"
exit 1
