#!/usr/bin/env bash
# check_tree_known.sh — is the working tree in a KNOWN state, or does it hold
# orphaned mutation residue?
#
# WHY THIS EXISTS (2026-09-27, the orphan mutant). A mutation harness plants a
# deliberately broken line in an RTL file, runs the testbench, and restores the
# file from a PRISTINE snapshot. That works: all 16 harnesses trap EXIT/INT/TERM,
# so an interrupt or a SIGTERM restores cleanly.
#
# It does not work against SIGKILL, because no process can trap SIGKILL. When
# the graphical session was torn down, systemd-logind SIGKILLed the whole user
# cgroup and a mutation run in flight died holding a planted line in
# rtl/pe_eth_mac.v:
#
#     -  published_used <= published_used + pay_cnt[AW:0] - consume_credit;
#     +  published_used <= published_used - consume_credit;  // MUTANT: drops length bytes
#
# That sat in the tree with nothing running and no owner, and the next thing to
# compile it would have measured a broken MAC. It surfaced only because someone
# read `git status` by hand, which is a coincidence, not a mechanism. This tree
# has been bitten twice: the 2026-09-24 m1 mutant in pe_pinmux.v presented as a
# 3-TB regression failure and cost a forensic afternoon.
#
# WHY NOT A BETTER TRAP. The tempting conclusion is that the harnesses need
# stronger cleanup. They cannot have it: the process that would restore the file
# is the process being killed, and SIGKILL is uncatchable by construction. So
# cleanup-on-exit is the wrong layer, and the answer is to VERIFY rather than
# TRUST.
#
# THE MARKER IS AN EXISTING CONVENTION. The harnesses all mark a planted line
# `// MUTANT: <why>`, and regress/check_staged_mutants.sh already refuses a
# COMMIT whose staged rtl/tb additions contain one. That check sits at the wrong
# end of the lifecycle: it fires when someone commits, and this failure mode is
# precisely that nobody commits - the mutant sits there and a later suite run
# measures it. This asks the same question of the working tree before a run.
#
# SCOPE, narrow on purpose. It flags an UNCOMMITTED change to rtl/ or tb/ that
# ADDS a line carrying a mutation marker. It does NOT flag ordinary uncommitted
# edits: a worker mid-change is legitimate, and a gate that cries wolf at
# in-progress work gets ignored, which is worse than no gate. The signal has to
# be unambiguous to be worth automating.
#
# Exit: 0 = tree known, 1 = residue found (named, with the remedy), 2 = usage.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$(cd "$HERE/.." && pwd)}"
MARKER='MUTANT'

usage() { echo "usage: $(basename "$0") [repo-root]   (0 known, 1 residue, 2 usage)" >&2; }
case "${1:-}" in -h|--help) usage; exit 0;; esac

cd "$ROOT" || { echo "check_tree_known.sh: cannot enter $ROOT" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "check_tree_known.sh: $ROOT is not a git repository" >&2; exit 2; }

REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT
: >"$REPORT"
found=0

# Uncommitted additions to rtl/ or tb/ that carry the marker, in the working tree
# and in the index. -U0 keeps hunks to single lines so the report can name a
# real line; awk tracks the current file from the "+++ b/<path>" header.
for stage in work index; do
  if [ "$stage" = work ]; then out="$(git diff -U0 -- rtl/ tb/ 2>/dev/null)"; tag=""
  else                          out="$(git diff --cached -U0 -- rtl/ tb/ 2>/dev/null)"; tag=" (staged)"; fi
  [ -z "$out" ] && continue
  hits="$(printf '%s\n' "$out" | awk -v M="$MARKER" -v t="$tag" '
    /^\+\+\+ b\//           { f = substr($0, 7) }
    /^\+/ && !/^\+\+\+/    { if (index($0, M)) { n = substr($0, 2); sub(/^[ \t]+/, "", n); printf "  %s%s: %s\n", f, t, n } }
  ' | head -10)"
  if [ -n "$hits" ]; then printf '%s\n' "$hits" >>"$REPORT"; found=1; fi
done

# An untracked file under rtl/ or tb/ carrying a marker is residue too: that is
# what a harness looks like if it died before its first commit.
while read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    rtl/*|tb/*)
      if grep -qE "$MARKER" "$f" 2>/dev/null; then
        printf '  %s (UNTRACKED): %s\n' "$f" "$(grep -m1 -oE ".{0,40}$MARKER.{0,60}" "$f")" >>"$REPORT"
        found=1
      fi
      ;;
  esac
done < <(git ls-files --others --exclude-standard -- rtl/ tb/ 2>/dev/null)

if [ "$found" -eq 0 ]; then
  echo "tree-known: OK (no orphaned mutation residue in rtl/ or tb/)"
  exit 0
fi

echo "tree-known: FAILED - orphaned MUTATION RESIDUE in the working tree."
echo
echo "  An uncommitted change to rtl/ or tb/ carries a '$MARKER' marker, which means a"
echo "  mutation harness died without restoring. SIGKILL cannot be trapped, so its"
echo "  cleanup-on-exit could not have run. The tree does not currently say what it says:"
echo
cat "$REPORT"
echo
echo "  REMEDY. First find out whether anyone still owns it:"
echo "      pgrep -af 'mutate_.*\\.sh'"
echo "  If a harness IS running it owns the mutant and will restore it - do not touch the"
echo "  file, and wait. Removing a live mutant corrupts a run you do not own."
echo "  If NOTHING is running the plant is orphaned and HEAD is authoritative:"
echo "      git checkout -- <file>"
exit 1
