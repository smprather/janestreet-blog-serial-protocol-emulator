#!/usr/bin/env bash
# check_tmp_isolation.sh -- no script may write a FIXED GLOBAL /tmp artifact name.
#
# WHY THIS EXISTS, in the shape that matters. On 2026-09-26 a full suite run came
# back RED on "eth_tx loopback TB mutations" and the cause was not the RTL, the
# testbench, or the mutation: two WORKTREES were running the same harness, and
# the harness compiled its simulation binaries to a fixed global path
# (/tmp/mut_eth_tx_tt.vvp), so each worktree's run executed whatever the other
# one had most recently written there.
#
# The interesting part is that EVERY safety net behaved correctly while the run
# was still wrong. The per-worktree run lock (c689124) gave each run its own
# lock and refused neither, correctly, because they were different worktrees.
# The dep-guard was clean and PROVABLY so: for the failing harness its stamps
# showed .hit absent (the sampler saw no outside writer on any RTL target),
# .uncovered empty and .sample.done present. The worktree was verifiably not
# the interference path. The collision lived in /tmp, which nothing watched.
#
# run_lock.sh carried the false premise in its own comment: "concurrent runs in
# DIFFERENT worktrees are safe (disjoint files)". The files are disjoint. The
# compiled binaries were not, and neither are the logs a gate reads its verdict
# back out of.
#
# SO THIS GATES THE CLASS, NOT THE INSTANCES. The first fix (a04bc7f) moved 83
# paths in 10 files and STILL missed a whole mutation harness, because the grep
# that listed the files was `grep -ln "/tmp/mut_"` and that pattern cannot match
# "/tmp/mutate_codec.vvp" -- it needs an underscore after "mut" and "mutate_"
# has "a" there. One character of pattern, one entire suite left exposed, and no
# test would have noticed. A per-instance fix cannot be complete; a lint over
# every fixed name can.
#
# WHAT COUNTS AS A FINDING: a non-comment line naming /tmp/<path>.<ext> that
# carries no per-worktree discriminator -- no mktemp XXXXXX template, no
# "chip-" prefix, and no $CHIP_WT_DIR / ${_diag_wt}. A bare literal is shared
# with every other worktree on the box and every other concurrent run, and so is
# a path built from an ordinary variable: see the matcher for why.
#
# Comment lines are skipped deliberately, and that is not a loophole: a comment
# cannot execute. run_lock.sh deliberately quotes the old colliding path as
# evidence, and rewriting history to satisfy a lint would be the wrong trade.
set -uo pipefail
cd "$(dirname "$0")/.."

FINDINGS=0
REPORTED=0
EXEMPTED=0

# The extensions that are a compiled artifact, a captured log, or a golden
# payload -- i.e. anything a run produces and something else may read back.
EXTS='vvp|log|hex|smt2|json|out|bin|txt|elf|vcd|err'

# A /tmp path is SHARED unless it carries a per-worktree or per-run
# discriminator. The exemption is deliberately narrow and based on WHICH
# expansion appears, not on whether one appears: interpolating ${_diag_wt} or
# $CHIP_WT_DIR makes the path unique per worktree, while interpolating anything
# else -- ${TOP}, $tb, $name -- leaves it shared, because two worktrees holding
# the same module name or the same case name write the same file. That
# distinction is not theoretical: /tmp/smt_induct_${TOP}.smt2 looked safe
# because it interpolates, and it is not, and the first version of this matcher
# missed it for exactly that reason. An mktemp XXXXXX template is unique per
# invocation, and "chip-" is this repo's existing per-worktree namespace.
shared_tmp_paths() {
  # Single-quoted so the shell does not eat the literal ${} in the class; the
  # extension alternation is spliced in. Getting this wrong is not theoretical:
  # double-quoting the pattern made the shell expand ${} and the matcher
  # silently matched NOTHING, so the lint reported OK on a tree with 30 known
  # shared paths -- a check that cannot fail is as useless as one that cannot
  # pass, and it failed in the more dangerous direction.
  #
  # The middle class admits '"' and '$' as well, so a path BUILT BY
  # CONCATENATION is still seen: "/tmp/"$name".log" is a shared path written in
  # the most innocent-looking way there is, and a matcher that only understood
  # whole literals would miss every future instance written that way. Probing
  # the matcher against concatenated forms is what found this; there are no such
  # call sites in the tree today, so it is a latent gap closed rather than a
  # live defect fixed, and the self-test below now pins all three shapes so it
  # cannot reopen.
  grep -oE '/tmp/["$A-Za-z0-9_./{}-]*\.('"$EXTS"')' "$1" 2>/dev/null \
    | grep -vE 'XXXXXX' \
    | grep -vE '^/tmp/chip-' \
    | grep -vE 'CHIP_WT_DIR|_diag_wt' \
    | sort -u
}

scan() {
  local f="$1" hits
  # Only lines that can execute. A comment cannot write a file.
  hits=$(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null | shared_tmp_paths /dev/stdin)
  [ -n "$hits" ] || return 0
  FINDINGS=$((FINDINGS + 1))
  REPORTED=$((REPORTED + 1))
  echo "FAIL: $f writes a FIXED GLOBAL /tmp name -- shared with every concurrent run:"
  echo "$hits" | sed 's/^/    /'
  echo "    use \$CHIP_WT_DIR (regress/run_lock.sh) or a \${_diag_wt}-style name," >&2
  echo "    or mktemp. See regress/check_tmp_isolation.sh for why." >&2
}

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 4

# SELF-TEST FIRST, and it is a real negative control rather than a smoke test:
# a lint that matches nothing reports OK on a broken tree, which is the same
# failure mode as a gate that always passes. One case per path SHAPE, so a
# regression in the matcher is caught by the matcher and not by a human
# noticing that 30 findings became 0.
selftest() {
  local fails=0 probe expect got ran=0 find_n=0 clean_n=0
  probe=$(mktemp) || return 1
  while IFS='|' read -r line expect; do
    [ -n "$line" ] || continue
    ran=$((ran + 1))
    [ "$expect" = FIND ] && find_n=$((find_n + 1)) || clean_n=$((clean_n + 1))
    printf '%s\n' "$line" > "$probe"
    got=$(grep -vE '^[[:space:]]*#' "$probe" | shared_tmp_paths /dev/stdin)
    if [ "$expect" = "FIND" ] && [ -z "$got" ]; then
      echo "  FAIL selftest: expected a finding, got none: $line" >&2; fails=$((fails+1))
    elif [ "$expect" = "CLEAN" ] && [ -n "$got" ]; then
      echo "  FAIL selftest: expected clean, got: $got   <- $line" >&2; fails=$((fails+1))
    fi
  done <<'CASES'
-o /tmp/mut_eth_tx_tt.vvp|FIND
LOG=/tmp/mutate_codec.log|FIND
SMT2="/tmp/smt_induct_${TOP}.smt2"|FIND
  iverilog -o /tmp/check_formal_ifdef.log 2>&1|FIND
>"/tmp/"$name".log"|FIND
>"/tmp/${top}.vvp"|FIND
"/tmp/"$case".err"|FIND
# /tmp/commented_out.vvp|CLEAN
PRISTINE=$(mktemp -d /tmp/pristine_x.XXXXXX)|CLEAN
vvp /tmp/chip-wt.abc123/mut_loop.vvp|CLEAN
"$CHIP_WT_DIR"/mut_loop.vvp|CLEAN
grep -c ok /tmp/check_diagrams.${_diag_wt}.log|CLEAN
CASES
  rm -f "$probe"
  # These counts are now COUNTED, not typed. "7 shared, 5 exempt" was correct
  # when written and could only be kept correct by hand: add a case to the
  # CASES block above and the message keeps asserting the old numbers, printing
  # an authoritative-looking count of the very cases that were not run. Nothing
  # checked it, so it was a claim about evidence rather than evidence -- the
  # failure this file's own header warns about one level up. Counting in the
  # loop makes the message unable to disagree with the loop that ran.
  if [ "$fails" -eq 0 ]; then
    echo "  ok   selftest: every path shape classified correctly ($find_n shared, $clean_n exempt; $ran case(s) run)"
  fi
  return "$fails"
}

if ! selftest; then
  echo "tmp isolation: HARNESS ERROR (the matcher itself is wrong; its silence proves nothing)" >&2
  exit 4
fi

for f in regress/*.sh tools/*.sh tools/*/*.sh formal/*.sh sim/*.sh; do
  [ -f "$f" ] || continue
  # The lint skips ITSELF, and that exemption is self-referential, so it is
  # written down rather than left as a quiet special case: this file's probe
  # corpus must contain the very shapes it forbids, or the self-test above
  # could not test them. The corpus is not unchecked -- every shape in it is a
  # case in selftest, with its expected verdict, and the self-test gates this
  # script before the scan runs. No other file is exempt.
  case "$f" in
    regress/check_tmp_isolation.sh) continue ;;
  esac
  # A DELIBERATE exemption is carried by the file itself, as a marker line
  # naming the reason, rather than by a list here. A second copy of the list is
  # a second thing to forget to update, and an exemption that lives only inside
  # the gate that honours it is invisible to anyone reading the tool it excuses.
  # Grepping `tmp-isolation` shows every exempt file and its justification; if
  # that set grows, the growth is visible in a diff rather than buried in here.
  if grep -q '^#[[:space:]]*tmp-isolation:' "$f" 2>/dev/null; then
    EXEMPTED=$((EXEMPTED + 1))
    printf 'exempt: %-40s %s\n' "$f" \
      "$(grep -m1 '^#[[:space:]]*tmp-isolation:' "$f" | sed 's/^#[[:space:]]*//')"
    continue
  fi
  scan "$f"
done

if [ "$FINDINGS" -eq 0 ]; then
  echo "tmp isolation: OK (no script writes a fixed global /tmp artifact name$([ "$EXEMPTED" -gt 0 ] && printf ', %s deliberate box-global exemption(s)' "$EXEMPTED"))"
  exit 0
fi
echo "tmp isolation: FAILED ($FINDINGS file(s) share a global /tmp name)" >&2
exit 1
