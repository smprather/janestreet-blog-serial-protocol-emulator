#!/usr/bin/env bash
# test_agent_tag.sh — prove the ownership gate the user ruled on 2026-09-27
# ("the manager can only kill processes launched by one of the protocol emulator
# team"), BEFORE the manager's brakes are trusted with it.
#
# WHY THIS TEST IS A NEGATIVE-CONTROL-FIRST TEST. The thing being tested is a
# KILL SWITCH. runaway_watch shipped once already, unproven, and on its first
# scan it kill -9'd the manager's own pi session (40056s of CPU over 60 hours -
# the cost of being the manager, not a runaway). A brake that "isn't firing" and
# a brake that is "firing correctly" look identical from the outside, so this
# test does both halves on REAL processes with REAL /proc/<pid>/environ:
#
#   it MUST kill a tagged runaway          (otherwise the brake is a no-op and
#                                           the 27h check script is back)
#   it MUST NOT kill                       (each of these is a real incident
#     - an untagged process                  class, not a hypothetical)
#     - a process with the WRONG team token
#     - the agent ROOT (the harness itself)
#     - a harness/service binary (a pi or node session)
#     - the manager's own watchdog tooling
#
# The kill cases run for real, against throwaway processes, under a private
# ALERT file and a KILL_CPU of 0 - but ONLY after asserting that no
# pre-existing team-tagged process exists, so a full-threshold scan can never
# reach the live fleet. If one does exist (i.e. the team has been rolled out and
# this very session is named), the destructive half reports SKIPPED rather than
# pretending to have run.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/manager/agent_tag.sh
. "$HERE/agent_tag.sh"

TMP="$(mktemp -d /tmp/pe-tag-test.XXXXXX)"
ALERTF="$TMP/alert.txt"
: >"$ALERTF"
PASS=0; FAIL=0; SKIPPED=0
cleanup() { for p in "${SPAWNED[@]:-}"; do kill -9 "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
SPAWNED=()

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
# A SAFETY SKIP IS NOT A FAILURE. The destructive half refuses to run when a real
# tagged agent is on the box, because a KILL_CPU=0 scan would reach the live
# fleet - and it is right to refuse. The first version of this test called bad()
# for that refusal, so TIER 0 went red every time the fleet was running, which is
# precisely when you least want a red. A gate that cries wolf gets ignored, and
# then it protects nothing. Skips are counted and named separately so the summary
# can never imply coverage it did not have.
skip() { SKIPPED=$((SKIPPED+1)); printf '  SKIP  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
expect() { # $1=label $2=expected $3=actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

env_of()  { pe_environ_var "$1" "$2"; }   # the library's reader, not a copy
verdict() { local v rc=0; v=$(pe_kill_decision "$1" "${2:-}") || rc=1; printf '%s|%s' "$rc" "$v"; }
# spawn a tagged sleeper that is NOT its own agent root (a "work" descendant)
spawn_tagged()  { env PE_TEAM=protocol-emulator PE_AGENT_NAME="$1" PE_ROOT_PID=1 sleep 300 & SPAWNED+=("$!"); disown; }
spawn_untagged(){ env -u PE_TEAM -u PE_AGENT_NAME -u PE_ROOT_PID sleep 300 & SPAWNED+=("$!"); disown; }
spawn_wrong()   { env PE_TEAM=some-other-project PE_AGENT_NAME="$1" PE_ROOT_PID=1 sleep 300 & SPAWNED+=("$!"); disown; }
count_team()    { local n=0 p; for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
                     [ "$(env_of "$p" PE_TEAM)" = "protocol-emulator" ] && n=$((n+1)); done; printf '%s' "$n"; }

echo "agent_tag self-test: $(basename "$0")"
echo "team token: $PE_TEAM_TOKEN   tmp: $TMP"

# ---- 1. the launcher refuses to start an UNNAMED instance --------------------
# An unnamed instance is the exact gap this closes; the launcher must not
# quietly produce one.
"$HERE/launch_agent.sh" >/dev/null 2>&1; expect "launcher refuses to start with no name" "2" "$?"
"$HERE/launch_agent.sh" "bad name" sleep 1 >/dev/null 2>&1; expect "launcher refuses a whitespace name" "2" "$?"

# ---- 2. inheritance: the name lands in /proc/<pid>/environ --------------------
# `bash -c 'sleep 300 & wait'` and NOT `bash -c 'sleep 300'`: bash exec-optimises
# a single simple command, so the "child" case would exec INTO the sleep and
# there would be no child to inspect - the case would pass while testing nothing.
# The first version of this test made exactly that mistake.
"$HERE/launch_agent.sh" selftest-agent bash -c 'sleep 300 & wait' & SPAWNED+=("$!")
ROOT=$!
disown
sleep 0.4
expect "named root carries PE_TEAM"    "protocol-emulator" "$(env_of "$ROOT" PE_TEAM)"
expect "named root carries its name"   "selftest-agent"    "$(env_of "$ROOT" PE_AGENT_NAME)"
expect "PE_ROOT_PID marks the root"    "$ROOT"             "$(env_of "$ROOT" PE_ROOT_PID)"
KID=$(pgrep -P "$ROOT" 2>/dev/null | head -1); SPAWNED+=("$KID")
if [ -z "$KID" ]; then bad "found the spawned child process" "pgrep -P $ROOT found nothing"; else ok "found the spawned child process"; fi
expect "a CHILD process inherits the tag" "protocol-emulator" "$(env_of "$KID" PE_TEAM)"
expect "a CHILD knows the owner"           "selftest-agent"    "$(env_of "$KID" PE_AGENT_NAME)"

# ---- 3. the decision, on real processes with real environments ---------------
spawn_tagged work-agent; TAGGED=$!
spawn_untagged;         UNTAGGED=$!
spawn_wrong   work-agent; WRONG=$!
sleep 0.4
v=$(verdict "$TAGGED");   expect "tagged work process -> KILL"        "0|kill work-agent"       "$v"
v=$(verdict "$UNTAGGED"); expect "untagged process   -> never touch"  "1|skip not-team"          "$v"
v=$(verdict "$WRONG");    expect "wrong team token   -> never touch"  "1|skip not-team [PE_TEAM=some-other-project]" "$v"
v=$(verdict "$ROOT");     expect "the agent ROOT     -> never touch"  "1|skip agent-root selftest-agent" "$v"
cp /bin/sleep "$TMP/pi" 2>/dev/null
env PE_TEAM=protocol-emulator PE_AGENT_NAME=work-agent PE_ROOT_PID=1 "$TMP/pi" 300 & SPAWNED+=("$!")
HARNESS=$!; disown; sleep 0.4
v=$(verdict "$HARNESS");  expect "harness binary     -> never touch"  "1|skip harness work-agent" "$v"
v=$(verdict "$TAGGED" "bash /tmp/runaway_watch.sh")
expect "manager's own tooling -> never touch" "1|skip manager-tool work-agent" "$v"

# ---- 3b. reading an unreadable /proc is SILENT, not noisy --------------------
# A guard that is "fixed" by swallowing the value would pass every case above
# while having stopped reading anything. This asserts BOTH halves: silence on a
# ptrace-gated pid, and a real value on a descendant.
NOISE=$( { pe_environ_var 1 HOME; pe_environ_var "$$" HOME; } 2>&1 >/dev/null )
expect "unreadable /proc raises NO stderr noise" "" "$NOISE"
REALV=$(MARKER=probe-value bash -c 'sleep 20 & c=$!; sleep 0.2; { tr "\0" "\n" < "/proc/$c/environ" 2>/dev/null || true; } 2>/dev/null | sed -n "s/^MARKER=//p" | head -1; kill $c 2>/dev/null')
expect "the silenced reader still READS a real environ" "probe-value" "$REALV"

# ---- 4. THE DESTRUCTIVE HALF: a real scan that must kill ours, spare the rest --
# Reap the throwaway tagged processes from sections 2-3 FIRST. A KILL_CPU=0 scan
# considers every process on the box, and any team-tagged process left over from
# an earlier section would be killed by it - so those helpers are cleared and the
# guard below gets an honest count instead of silently self-skipping the very
# case that proves the brake is not a no-op.
for p in "${SPAWNED[@]}"; do kill -9 "$p" 2>/dev/null; done
SPAWNED=()
sleep 0.3
PRE=$(count_team)
if [ "$PRE" -gt 0 ]; then
  skip "end-to-end kill (refused for safety: $PRE team-tagged process(es) are live - a full-threshold scan would reach the real fleet)" \
       "This half proves the brake is not a no-op. It did NOT run, so this run does not prove that. Run it with the fleet down."
else
  : >"$ALERTF"
  sleep 300 & VICTIM=$!; disown                       # untagged: must survive
  env PE_TEAM=protocol-emulator PE_AGENT_NAME=doomed-runaway PE_ROOT_PID=1 sleep 300 & T=$!; disown
  SPAWNED+=("$VICTIM" "$T")
  ALERT="$ALERTF" ALERT_CPU=0 KILL_CPU=0 PE_WATCH_ONCE=1 "$HERE/runaway_watch.sh" >/dev/null 2>&1
  sleep 0.3
  if kill -0 "$T" 2>/dev/null; then bad "tagged runaway is actually KILLED" "pid $T survived the scan"; else ok "tagged runaway is actually KILLED"; fi
  if kill -0 "$VICTIM" 2>/dev/null; then ok "untagged process survives the same scan"; else bad "untagged process survives the same scan" "pid $VICTIM was killed - the gate is not holding"; fi
  if grep -q "KILL: .*doomed-runaway" "$ALERTF"; then ok "the KILL is attributed to its agent"; else bad "the KILL is attributed to its agent" "$(head -3 "$ALERTF")"; fi
  if grep -q "SKIP (not-team)" "$ALERTF"; then ok "the skip is recorded, not silent"; else bad "the skip is recorded, not silent" "$(head -3 "$ALERTF")"; fi
fi

# ---- verdict -----------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then
  if [ "$SKIPPED" -gt 0 ]; then
    echo "agent_tag self-test: OK ($PASS of $PASS cases proved the ownership gate, $SKIPPED SKIPPED for safety)"
    echo "  NOTE: the skipped half did not run. This run does NOT prove the brake can"
    echo "  actually kill - only that it will not touch what is not ours. Run it with"
    echo "  the fleet down for full coverage."
  else
    echo "agent_tag self-test: OK ($PASS of $PASS cases proved the ownership gate)"
  fi
  exit 0
fi
echo "agent_tag self-test: FAILED ($FAIL of $((PASS+FAIL)) cases failed, $SKIPPED skipped for safety)"
exit 1
