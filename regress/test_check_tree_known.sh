#!/usr/bin/env bash
# test_check_tree_known.sh — prove the residue gate on a REAL git repo, with
# REAL commits, REAL diffs and a REAL orphan, before anything depends on it.
#
# WHY A THROWAWAY REPO. This gate's whole job is to read git state, and the only
# honest way to test that is against a real repository with real history. Every
# case below builds one, plants something, asks the question, and tears the repo
# down. Nothing touches the protocol emulator's own tree, which matters: a test
# for "detect an orphaned mutant in rtl/" that plants a mutant in the real rtl/
# would be the very bug it is looking for.
#
# The negative controls matter more than the positive. A gate that always says
# FAILED is not a gate, and a gate that flags a worker's ordinary in-progress
# edit is worse than no gate at all, because people switch it off. Both are
# tested here.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check_tree_known.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; return 0; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }

# Build a throwaway repo with the shape the gate cares about: rtl/ and tb/.
new_repo() {
  local d; d="$(mktemp -d /tmp/pe-tree-known.XXXXXX)"
  mkdir -p "$d/rtl" "$d/tb"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'module pe;\n  assign a = 1; // original\nendmodule\n' >"$d/rtl/pe.v"
  printf 'module tb;\nendmodule\n'                       >"$d/tb/tb.v"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  printf '%s' "$d"
}
run_check() { "$CHECK" "$1" 2>&1; }

echo "check_tree_known self-test: $(basename "$0")"

if [ -x "$CHECK" ]; then ok "check_tree_known.sh exists and is executable"; else
  bad "check_tree_known.sh exists and is executable" "$CHECK missing or not +x"
  echo "check_tree_known self-test: FAILED ($FAIL of $((PASS+FAIL)) cases failed)"; exit 1
fi

# ---- 1. a clean tree is clean ----------------------------------------------
R=$(new_repo)
out=$(run_check "$R"); rc=$?
[ "$rc" -eq 0 ] && ok "a pristine tree passes" || bad "a pristine tree passes" "exit $rc: $out"
case "$out" in *OK*) ok "  ...and says so in words";; *) bad "  ...and says so in words" "$out";; esac

# ---- 2. THE CASE THAT MATTERS: an orphaned mutant, uncommitted -------------
# This is tonight, reproduced: a harness died holding a planted line, and
# nothing is running to restore it.
printf 'module pe;\n  assign a = 0; // MUTANT: drops the increment\nendmodule\n' >"$R/rtl/pe.v"
out=$(run_check "$R"); rc=$?
[ "$rc" -eq 1 ] && ok "an uncommitted MUTANT line in rtl/ is caught" || bad "an uncommitted MUTANT line in rtl/ is caught" "exit $rc: $out"
case "$out" in *rtl/pe.v*) ok "  ...and NAMES the file";; *) bad "  ...and names the file" "$out";; esac
case "$out" in *"drops the increment"*) ok "  ...and quotes the marker's own words";; *) bad "  ...and quotes the marker" "$out";; esac
case "$out" in *pgrep*|*git\ checkout*) ok "  ...and gives a remedy, not just a red";; *) bad "  ...and gives a remedy" "$out";; esac

# ---- 3. NEGATIVE CONTROL: a worker's ordinary WIP is NOT residue -----------
# A gate that flags in-progress work gets ignored, which is worse than no gate.
git -C "$R" checkout -- rtl/pe.v
printf 'module pe;\n  assign a = 2; // legitimate in-progress edit, no marker\nendmodule\n' >"$R/rtl/pe.v"
out=$(run_check "$R"); rc=$?
[ "$rc" -eq 0 ] && ok "an ordinary uncommitted edit is NOT flagged (no false alarm)" \
                || bad "an ordinary uncommitted edit is NOT flagged" "exit $rc: $out"

# ---- 4. NEGATIVE CONTROL: a COMMITTED marker is not residue ----------------
# Once committed, the line is history, not an orphan. Only UNCOMMITTED is a
# signal, or the gate would fire on the project's own mutation suites forever.
git -C "$R" commit -qam "commit a line that contains the word MUTANT"
out=$(run_check "$R"); rc=$?
[ "$rc" -eq 0 ] && ok "a COMMITTED marker is history, not residue" \
                || bad "a committed marker is history, not residue" "exit $rc: $out"

# ---- 5. a STAGED mutant is still uncommitted, and still caught ------------
printf 'module pe;\n  assign a = 3; // MUTANT: staged plant\nendmodule\n' >"$R/rtl/pe.v"
git -C "$R" add rtl/pe.v
out=$(run_check "$R"); rc=$?
[ "$rc" -eq 1 ] && ok "a STAGED mutant is caught too" || bad "a staged mutant is caught too" "exit $rc: $out"
case "$out" in *staged*) ok "  ...and is labelled staged";; *) bad "  ...and is labelled staged" "$out";; esac
git -C "$R" reset -q; git -C "$R" checkout -- rtl/pe.v

# ---- 6. an UNTRACKED file carrying a marker is residue --------------------
printf 'module pe2;\n  assign b = 0; // MUTANT: from a harness that never committed\nendmodule\n' >"$R/rtl/stray.v"
out=$(run_check "$R"); rc=$?
[ "$rc" -eq 1 ] && ok "an UNTRACKED file with a marker is caught" || bad "an untracked file with a marker is caught" "exit $rc: $out"
case "$out" in *stray.v*) ok "  ...and names the stray file";; *) bad "  ...and names the stray file" "$out";; esac
rm -f "$R/rtl/stray.v"

# ---- 7. tb/ is covered too, not just rtl/ ---------------------------------
printf 'module tb2;\n  // MUTANT: tb-side plant\nendmodule\n' >"$R/tb/tb2.v"
out=$(run_check "$R"); rc=$?
[ "$rc" -eq 1 ] && ok "a mutant in tb/ is caught as well" || bad "a mutant in tb/ is caught as well" "exit $rc: $out"
rm -f "$R/tb/tb2.v"

# ---- 8. usage: a non-repo is refused, not silently passed -----------------
out=$(run_check /tmp); rc=$?
[ "$rc" -eq 2 ] && ok "a non-repository is refused (exit 2), not silently OK" \
                || bad "a non-repository is refused" "exit $rc: $out"

# ---- 9. after restoring, the gate goes quiet again ------------------------
out=$(run_check "$R"); rc=$?
[ "$rc" -eq 0 ] && ok "once the residue is gone the gate is quiet again (no sticky red)" \
                || bad "once the residue is gone the gate is quiet" "exit $rc: $out"
rm -rf "$R"

# ---- verdict ----------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then
  echo "check_tree_known self-test: OK ($PASS of $PASS cases proved the residue gate)"
  exit 0
fi
echo "check_tree_known self-test: FAILED ($FAIL of $((PASS+FAIL)) cases failed)"
exit 1
