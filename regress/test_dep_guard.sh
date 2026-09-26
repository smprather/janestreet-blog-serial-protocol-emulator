#!/usr/bin/env bash
# test_dep_guard.sh — the harness-edit pre-flight's own test.
#
# WHY THIS TEST EXISTS IN THIS SHAPE. The pre-flight's whole job is to turn a
# silent race into a visible INCONCLUSIVE, so the only two things that matter are
# that it FIRES on a changed dependency and that it does NOT fire on an unchanged
# one. A guard that never fires looks exactly like a guard that works, and this
# project has now written three rules that reported numbers they had never been
# shown to compute — so the negative control is the point of the file, not an
# extra.
#
# It runs no simulation, takes NO run lock and touches nothing in the repo: every
# case works on a throwaway copy in a temp directory. That matters, because the
# end-to-end demonstration (edit a real harness mid-run and watch the gate go
# INCONCLUSIVE) needs the worktree lock, and this test must be runnable while
# someone else holds it.
set -u
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d /tmp/dep_guard_test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
GUARD="$PWD/regress/dep_guard.sh"
export CHIP_DEP_STAMP_DIR="$TMP/stamps"
mkdir -p "$CHIP_DEP_STAMP_DIR"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# A stand-in "harness": a script that sources the guard, stamps, and then does
# something whose verdict a mid-run edit could decide. Executed as a real child
# process, because the real race is bash reading a file while it runs.
mk_harness() {   # $1 = name, $2 = body
  local n="$1"
  cat > "$TMP/$n" <<EOF
#!/usr/bin/env bash
set -u
. "$GUARD"
chip_dep_stamp "$n"
# --- the work, which the caller can corrupt from outside mid-run ---
$2
rc=\$?
if ! chip_dep_check "$n"; then
  echo "INCONCLUSIVE: dependency changed"
  exit 4
fi
exit \$rc
EOF
  chmod +x "$TMP/$n"
}

echo "dep_guard self-test:"

# 1. An UNCHANGED dependency passes. If this fails, the guard is noise.
mk_harness h_clean 'echo "work done"; exit 0'
out=$("$TMP/h_clean" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "an unchanged dependency reports a verdict (exit 0)"
else
  bad "an unchanged dependency was flagged (exit $rc): $out"
fi

# 2. A CHANGED dependency must be refused, and the marker must be present so the
#    caller can recognise it. This is the case the whole file exists for.
cat > "$TMP/h_racy" <<EOF
#!/usr/bin/env bash
set -u
. "$GUARD"
chip_dep_stamp h_racy
# The harness edits ITSELF while running: exactly the race, from the inside.
printf '\n# edited mid-run\n' >> "\$0"
echo "work done"
if ! chip_dep_check h_racy; then
  echo "INCONCLUSIVE: dependency changed"
  exit 4
fi
exit 0
EOF
chmod +x "$TMP/h_racy"
out=$("$TMP/h_racy" 2>&1); rc=$?
if [ "$rc" -eq 4 ] && grep -q CHIP-DEP-CHANGED <<< "$out" && grep -q INCONCLUSIVE <<< "$out"; then
  ok "a mid-run edit is refused (exit 4) and the marker is printed"
else
  bad "a mid-run edit was NOT refused (exit $rc): $out"
fi

# 3. THE NEGATIVE CONTROL for case 2 in the other direction: a harness that does
#    NOT change must NOT be flagged, even though case 2 exists. Proves the check
#    is discriminating rather than simply always-refusing.
if ! "$TMP/h_clean" >/dev/null 2>&1; then
  bad "the clean harness started failing once the racy one existed — the check is not discriminating"
else
  ok "the negative control: a clean run is still clean"
fi

# 4. A content-PRESERVING touch must NOT be flagged. This is what separates a
#    content hash from an mtime comparison, and an mtime check would fail here.
#    The file is passed as an EXTRA dependency on purpose: inside `bash -c` the
#    harness is not $0, and the first version of this case touched a file the
#    guard had never heard of — so it passed for the wrong reason, which is the
#    failure mode this project's log is full of.
mk_harness h_touch 'echo "work done"; exit 0'
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"; chip_dep_stamp h_touch "$2"; touch "$2"; chip_dep_check h_touch
' _ "$GUARD" "$TMP/h_touch" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a touch that preserves content is not a change (content hash, not mtime)"
else
  bad "an mtime-only touch was reported as a change (exit $rc): $out"
fi

# 4b. ... and the OTHER half of that claim, so "not flagged" cannot be the
#     guard simply ignoring extras: the SAME file, with different content, must
#     be flagged. Without this pair, case 4 is consistent with a guard that never
#     looks at an extra dependency at all.
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"; chip_dep_stamp h_touch2 "$2"; printf "\n# real edit\n" >> "$2"; chip_dep_check h_touch2
' _ "$GUARD" "$TMP/h_touch" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a CONTENT change to that same extra dependency IS flagged (the pair to case 4)"
else
  bad "a content change to an extra dependency went unnoticed (exit $rc): $out"
fi

# 5. A DELETED dependency is a change, not an absence of evidence. The file must
#    EXIST at stamp time, or the test is checking nothing: ABSENT -> ABSENT is
#    correctly not a change, and the first version of this case had exactly that
#    (its setup line was lost in an edit) and reported a guard failure.
mk_harness h_gone 'echo "work done"; exit 0'
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"; chip_dep_stamp h_gone "$2"; rm -f "$2"; chip_dep_check h_gone
' _ "$GUARD" "$TMP/h_gone" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a dependency that VANISHED is reported as a change"
else
  bad "a vanished dependency went unnoticed (exit $rc): $out"
fi

# 6. No stamp at all means no verdict — a check that silently passes when it has
#    no baseline is the "loop ran zero times" bug one level up.
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"; chip_dep_check never_stamped
' _ "$GUARD" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a run with no stamp is refused rather than assumed fine"
else
  bad "a run with no stamp was trusted (exit $rc): $out"
fi

# --- the DUT dependency and the sampler --------------------------------------
# On 2026-09-25 a mutation harness was live on rtl/pe_eth_mac.v and the file was
# restored from OUTSIDE the harness mid-run, which risked a false survivor. The
# guard could not see it: it stamped SCRIPTS only. A harness's MUTABLE list names
# the exact files it mutates, so those are dependencies too.
#
# THE SAMPLER, IN THREE LINES, because the shape of it is the whole point.
#   chip_dep_sample_start <label> <target>...   start watching, in the background
#   chip_dep_expect pristine|mutated <file>...  the HARNESS says what it just did
#   chip_dep_sample_stop <label>                returns non-zero if it saw a lie
# The poller does not look for a PATTERN, it compares what it sees against what
# the harness DECLARED. That asymmetry is the whole design: a declaration is
# valid for an INTERVAL, so a slow poller can only ever MISS a transition, never
# invent one. The rejected design (design file §3, disproved in §6) watched for
# M-O-M-O and fired ~120 times on a CLEAN run, because M-O-M-O is what every
# harness does to itself between cases.
#
# These cases reuse the SAME inline `bash -c` + positional-args shape as the
# touch/vanish/no-stamp cases above, deliberately. A first attempt generated a
# nested script with its own heredoc, and two things went wrong that a shell
# self-test should not: the inner EOF terminated the OUTER heredoc, leaving the
# file unparseable and running a chmod against /; and after that was repaired, the
# body's target path was expanded by the PARENT when the unquoted heredoc was
# written, so the child wrote to the wrong place. The pattern already passing 7/7
# has neither problem, so the fixture was wrong and the guard was not.
#
# The fixtures pass a SCRIPT NAME in the $0 slot (bash -c takes it there, and
# discards it into nothing if you use `_`). chip_dep_expect derives its label
# from $0 exactly as the real harnesses' own chip_dep_check does, so a
# meaningless $0 would still be self-consistent -- but a real name means the case
# exercises the same derivation the sixteen harnesses rely on.

# 1. A CLEAN run: the harness mutates its target and RESTORES it, exactly as all
#    sixteen real ones do. End state equals start state, so the content check
#    passes -- and the SAMPLER must stay quiet through declarations that are
#    true, or the guard is firing on normal behaviour.
printf 'module dut; endmodule\n' > "$TMP/dut_clean.v"
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"
  command -v chip_dep_expect >/dev/null 2>&1 || { echo "NO SAMPLER IMPLEMENTED"; exit 9; }
  lbl="run_$(basename "$0")"
  chip_dep_stamp dut_clean "$2"
  chip_dep_sample_start "$lbl" "$2"
  chip_dep_expect pristine "$2"
  printf "module dut; // MUTANT\nendmodule\n" > "$2"
  chip_dep_expect mutated "$2"
  sleep 0.3
  printf "module dut; endmodule\n" > "$2"
  chip_dep_expect pristine "$2"
  sleep 0.3
  rc=0; chip_dep_sample_stop "$lbl" || rc=4
  chip_dep_check dut_clean || rc=4
  exit $rc
' dut_clean.sh "$GUARD" "$TMP/dut_clean.v" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a CLEAN run with a mutating target still reports its verdict"
else
  bad "a clean run was refused - the sampler contradicts the harness's own declarations (exit $rc): $out"
fi

# 2. An EXTERNAL edit lands on the target mid-run and is not put back: the shape a
#    content check CAN see. Must be INCONCLUSIVE, never a verdict.
printf 'module dut; endmodule\n' > "$TMP/dut_hit.v"
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"
  command -v chip_dep_expect >/dev/null 2>&1 || { echo "NO SAMPLER IMPLEMENTED"; exit 9; }
  lbl="run_$(basename "$0")"
  chip_dep_stamp dut_hit "$2"
  chip_dep_sample_start "$lbl" "$2"
  chip_dep_expect pristine "$2"
  printf "module dut; // MUTANT\nendmodule\n" > "$2"
  chip_dep_expect mutated "$2"
  sleep 0.3
  printf "module dut; // EDITED BY SOMEBODY ELSE\nendmodule\n" > "$2"
  sleep 0.3
  rc=0; chip_dep_sample_stop "$lbl" || rc=4
  chip_dep_check dut_hit || rc=4
  exit $rc
' dut_hit.sh "$GUARD" "$TMP/dut_hit.v" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a mid-run change to a MUTABLE target is INCONCLUSIVE, never a verdict"
else
  bad "a mid-run target change was NOT caught (exit $rc): $out"
fi

# 3. THE INTERFERENCE ITSELF, and the case the whole sampler exists for. An
#    external actor RESTORES the target to its starting content mid-run while the
#    harness believes the mutant is still in place, and the harness carries on.
#    This case WAS the pinned limitation ("a mid-run restore is invisible to a
#    content check") and it FLIPS here. The sequence ends with the file back at
#    its starting content, so chip_dep_check returns 0 and the ONLY thing that
#    can fail this case is the sampler comparing what it sees against the
#    harness's DECLARATION: the harness said "mutated", an external actor made it
#    pristine, and the harness never told the guard it had changed its mind.
printf 'module dut; endmodule\n' > "$TMP/dut_restore.v"
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"
  command -v chip_dep_expect >/dev/null 2>&1 || { echo "NO SAMPLER IMPLEMENTED"; exit 9; }
  lbl="run_$(basename "$0")"
  chip_dep_stamp dut_restore "$2"
  chip_dep_sample_start "$lbl" "$2"
  chip_dep_expect pristine "$2"
  printf "module dut; // MUTANT 1\nendmodule\n" > "$2"
  chip_dep_expect mutated "$2"
  sleep 0.3
  printf "module dut; endmodule\n" > "$2"    # an EXTERNAL restore; the harness is told nothing
  sleep 0.3
  printf "module dut; // MUTANT 2\nendmodule\n" > "$2"
  chip_dep_expect mutated "$2"
  sleep 0.3
  printf "module dut; endmodule\n" > "$2"    # the harness own final restore
  chip_dep_expect pristine "$2"
  sleep 0.3
  rc=0; chip_dep_sample_stop "$lbl" || rc=4
  chip_dep_check dut_restore || rc=4
  exit $rc
' dut_restore.sh "$GUARD" "$TMP/dut_restore.v" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a mid-run RESTORE behind the harness back is INCONCLUSIVE (the 2026-09-25 shape, now caught)"
else
  bad "a mid-run restore went UNNOTICED - the sampler has stopped watching (exit $rc): $out"
fi

# 4. THE NEGATIVE CONTROL, AND IT IS THE ONE THAT MATTERS. A clean per-case run,
#    shaped like mutate_i2c_tb.sh (restore, then immediately mutate again), must
#    produce ZERO hits. This is the case the rejected design FAILED: watching for
#    M-O-M-O by itself fires ~120 times on exactly this sequence, which is the
#    disproof recorded in design file section 6. Here the declarations are honest
#    throughout, so nothing may fire.
#
#    The truncate-then-write pauses are DELIBERATE and adversarial. Every real
#    mutation is applied by python's write_text, which truncates and rewrites, so
#    between the truncate and the write the file is briefly neither the old
#    content nor the new. In practice that window is sub-millisecond; here it is
#    held open for 100ms, roughly twice the persistence the guard requires, so
#    the case proves the guard tolerates a SLOW legitimate writer rather than
#    only a fast one. Without that, a sampler that fires on its own harnesses
#    would still pass a naive version of this case.
printf 'module dut; endmodule\n' > "$TMP/dut_loop.v"
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"
  command -v chip_dep_expect >/dev/null 2>&1 || { echo "NO SAMPLER IMPLEMENTED"; exit 9; }
  lbl="run_$(basename "$0")"
  chip_dep_stamp dut_loop "$2"
  chip_dep_sample_start "$lbl" "$2"
  chip_dep_expect pristine "$2"
  for n in 1 2 3; do
    : > "$2"; sleep 0.1                      # a truncate held open, adversarially
    printf "module dut; // MUTANT %s\nendmodule\n" "$n" > "$2"
    chip_dep_expect mutated "$2"
    sleep 0.2
    : > "$2"; sleep 0.1                      # and again, on the restore
    printf "module dut; endmodule\n" > "$2"
    chip_dep_expect pristine "$2"
    sleep 0.2
  done
  rc=0; chip_dep_sample_stop "$lbl" || rc=4
  chip_dep_check dut_loop || rc=4
  exit $rc
' dut_loop.sh "$GUARD" "$TMP/dut_loop.v" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a CLEAN per-case run with honest declarations produces ZERO false hits (the case the old design failed)"
else
  bad "a clean per-case run was flagged - the sampler still sees M-O-M-O (exit $rc): $out"
fi

# 5. THE INSTRUMENT MUST BE ACCOUNTED FOR, in both ways it can be silent. A
#    sampler that was never started reports nothing, and a target the harness
#    never declared a state for is never checked -- and both look exactly like a
#    clean run. This is the "loop ran zero times" bug the no-stamp case above
#    already exists for, one level down: without this case the sampler could be
#    dead in production while every case above stayed green.
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"
  command -v chip_dep_sample_stop >/dev/null 2>&1 || { echo "NO SAMPLER IMPLEMENTED"; exit 9; }
  chip_dep_sample_stop "run_never_started.sh"
' x.sh "$GUARD" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a sampler that was never started is refused, not reported as clean"
else
  bad "a sampler that never ran was trusted (exit $rc): $out"
fi

# 5b. ... and the same question one level in: a sampler that IS running but whose
#     target the harness never declared is a target nobody checked. Fail closed,
#     because an unchecked target is the 2026-09-25 incident with the detector
#     switched off, and it would otherwise be indistinguishable from coverage.
printf 'module dut; endmodule\n' > "$TMP/dut_undecl.v"
out=$(CHIP_DEP_STAMP_DIR="$TMP/stamps" bash -c '
  set -u; . "$1"
  command -v chip_dep_expect >/dev/null 2>&1 || { echo "NO SAMPLER IMPLEMENTED"; exit 9; }
  lbl="run_$(basename "$0")"
  chip_dep_sample_start "$lbl" "$2"
  sleep 0.3
  chip_dep_sample_stop "$lbl"
' dut_undecl.sh "$GUARD" "$TMP/dut_undecl.v" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q CHIP-DEP-CHANGED <<< "$out"; then
  ok "a target the harness never DECLARED is reported as unchecked, not as clean"
else
  bad "a target with no declaration was reported as covered (exit $rc): $out"
fi

if [ "$fail" -ne 0 ]; then
  echo "dep_guard self-test: $fail of $((pass+fail)) FAILED"
  exit 1
fi
echo "dep_guard self-test: $pass/$((pass+fail)) cases, the pre-flight fires and stays quiet"
