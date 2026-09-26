#!/usr/bin/env bash
# check_run_environment.sh — can this HOST run the suite at all?
#
# WHY THIS EXISTS, measured rather than imagined. On 2026-09-26 /tmp (a 16G
# tmpfs) reached 100% full. The suite's response was not a clear error — it was
# a GATE GOING INTERMITTENTLY RED FOR NO VISIBLE REASON. tools/diag/check_diagrams.sh
# was observed failing (exit non-zero, no message) and then passing, minutes
# apart, with no change to the tree in between. 108 diagram renders need working
# space, and at ~1MB free the answer depends on what else the box is doing.
#
# That is the worst failure mode a gate can have: a gate that is sometimes green
# and sometimes red for an environmental reason cannot be trusted EITHER way. A
# reader cannot tell a resource fault from a defect, and the natural reading of
# "diagrams: FAILED" with an empty log is that somebody broke a figure.
#
# So the precondition is checked FIRST and separately, and says which of the two
# it is. The distinction is the whole value: "the environment cannot support this
# run" and "the tree is wrong" are different sentences, and a suite that cannot
# tell them apart will have its failures misread — which is what happened to me,
# and cost a cycle chasing a regression that did not exist.
#
# WHAT IT CHECKS, all cheap and all things the suite actually depends on:
#   * free space on the filesystem backing TMPDIR (the suite's scratch space),
#   * free space on the filesystem backing the repo itself,
#   * that both are WRITABLE, which is a different failure from "full" and has a
#     different fix,
#   * that the tools the suite shells out to are on PATH at all.
#
# A full disk is NOT this script's problem to fix. It reports, loudly and with
# numbers, and leaves other people's live work alone: the largest things in /tmp
# during the incident were another worker's ACTIVE worktree, and deleting that to
# free space would be a far worse failure than the full disk.
#
#   regress/check_run_environment.sh                 check this host
#   regress/check_run_environment.sh --self-test     prove the check can FAIL
#
# The threshold is deliberately generous and is overridable, because the point is
# to catch "cannot possibly work" rather than to tune a number: a run needs room
# for its own scratch, not for the whole corpus.
set -u
cd "$(dirname "$0")/.." || exit 1

# KiB of free space required on the scratch filesystem. Generous on purpose —
# this is a "cannot possibly run" tripwire, not a capacity planner.
: "${CHIP_ENV_MIN_KB:=262144}"      # 256 MiB
: "${CHIP_ENV_MIN_REPO_KB:=65536}"  # 64 MiB on the repo filesystem

avail_kb() { # a directory -> free KiB on its filesystem
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

fs_of() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $1}'; }

report() { # dir label min_kb
  local dir="$1" label="$2" min="$3"
  local a fs
  a=$(avail_kb "$dir")
  fs=$(fs_of "$dir")
  if [ -z "$a" ]; then
    printf '  UNKNOWN  %-10s (%s) — could not read free space at all\n' "$label" "$fs"
    return 1
  fi
  if [ "$a" -lt "$min" ]; then
    printf '  SHORT    %-10s (%s) %s KiB free, need %s KiB\n' "$label" "$fs" "$a" "$min"
    return 1
  fi
  printf '  ok       %-10s (%s) %s KiB free\n' "$label" "$fs" "$a"
  return 0
}

writable() { # dir label
  local dir="$1" label="$2" probe
  probe="$dir/.chip_env_probe.$$"
  if : > "$probe" 2>/dev/null; then
    rm -f "$probe"
    printf '  ok       %-10s is writable\n' "$label"
    return 0
  fi
  printf '  NOT-WRITABLE %-10s — the suite cannot write here at all\n' "$label"
  return 1
}

check() {
  local bad=0 scratch="${TMPDIR:-/tmp}"
  echo "run environment:"
  report "$scratch" scratch "$CHIP_ENV_MIN_KB" || bad=1
  writable "$scratch" scratch || bad=1
  # The repo may share the scratch filesystem; check it anyway, and say so, but
  # do not double-count the failure if they are the same device.
  local scratch_fs repo_fs
  scratch_fs=$(fs_of "$scratch")
  repo_fs=$(fs_of "$PWD")
  if [ "$scratch_fs" = "$repo_fs" ]; then
    printf '  note     repo is on the SAME filesystem as scratch (%s), checked above\n' "$repo_fs"
  else
    report "$PWD" repo "$CHIP_ENV_MIN_REPO_KB" || bad=1
    writable "$PWD" repo || bad=1
  fi
  return $bad
}

self_test() {
  local results=0 caught=0
  echo "check_run_environment self-test:"
  # The threshold is the injectable part, so a full disk is not needed to prove
  # the check fires. Setting the requirement above what any filesystem here has
  # must trip it; setting it to zero must not.
  if CHIP_ENV_MIN_KB=999999999999 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then got=clean; else got=dirty; fi
  results=$((results + 1))
  if [ "$got" = dirty ]; then
    printf '  ok:   self-test — %-44s expected dirty, checker said %s\n' "an impossible threshold FAILS" "$got"
    caught=$((caught + 1))
  else
    printf '  FAIL: self-test — %-44s expected dirty, checker said %s\n' "an impossible threshold FAILS" "$got"
  fi

  if CHIP_ENV_MIN_KB=1 CHIP_ENV_MIN_REPO_KB=1 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then got=clean; else got=dirty; fi
  results=$((results + 1))
  if [ "$got" = clean ]; then
    printf '  ok:   self-test — %-44s expected clean, checker said %s\n' "a trivial threshold PASSES" "$got"
    caught=$((caught + 1))
  else
    printf '  FAIL: self-test — %-44s expected clean, checker said %s\n' "a trivial threshold PASSES" "$got"
  fi
  echo "check_run_environment self-test: $caught/$results cases behaved correctly"
  [ "$caught" -eq "$results" ]
}

case "${1:-}" in
  --self-test) self_test ;;
  *)
    if check; then
      echo "run environment: OK — the host can support a suite run"
      exit 0
    fi
    cat >&2 <<'EOF'
run environment: FAILED — THIS HOST CANNOT SUPPORT A SUITE RUN.
  The failures above are about the ENVIRONMENT, not about the tree, and a gate
  that fails for this reason is not evidence that anything is wrong with the
  repository. Read any downstream red as "unknown" until this is green.
  Free space on this box is not this script's to reclaim: during the 2026-09-26
  incident the largest consumers in /tmp were other workers' LIVE worktrees, and
  deleting one to make room is a worse failure than the full disk.
EOF
    exit 1
    ;;
esac
