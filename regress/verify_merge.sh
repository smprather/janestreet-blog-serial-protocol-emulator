#!/usr/bin/env bash
# verify_merge.sh — THE MERGE GATE. A merge is never pushed without the
# testbenches its own diff can break.
#
# WHY (2026-09-25, merge 5b4731f). R3 added two module INPUTS, dbg_hold and
# dbg_step, to pe_cpu. The fw-timing branch was based before that and had never
# seen them, so its six timing acts' testbenches left the ports unconnected ->
# Z -> the core's execute gate evaluated X -> the core never retired an
# instruction -> dmem = xx, zero edges, watchdog, in SIX unrelated programs at
# once, and 5b4731f was pushed. The 13 testbenches that existed on main had all
# been fixed when R3 landed, so every gate the project owns was green before the
# merge and red after it. No gate could have caught it, because until the merge
# those two states did not coexist. This script is the missing gate: given the
# merge, work out which cases the merge can affect, and run them.
#
# THE MAPPING, and why it is not a guess. The affected set is computed from
# run_all.sh's OWN case table — the same array the suite runs, parsed rather
# than restated, so a case added to the suite cannot be invisible to the gate.
# Each entry is `tb file|rtl file list|top`, so a changed rtl/foo.v selects
# exactly the entries that compile foo.v; a changed tb/<case>.v (or any file
# under tb/<case>/) selects that case; a changed firmware/*.pe or tools/fw/*
# selects EVERY case compiling pe_cpu.v or pe_soc.v, because those are the cases
# whose DUT is partly firmware.
#
# WHEN IT REFUSES TO BE CLEVER. Anything it cannot map confidently is a FULL
# suite run, announced, never a quiet subset: a change outside rtl/, tb/ and
# firmware/ (regress/, tools/ outside the assembler, formal/, flow/, docs/,
# wiki/ — the last two because the generated-reference gates read them), an
# EMPTY mapping, or a case table this script failed to parse. Over-selecting
# costs minutes; under-selecting is how a red merge gets pushed, which is the
# one thing this file exists to stop.
#
# IT CHECKS THAT IT RAN WHAT IT CLAIMED. A gate that selects 12 cases and
# silently runs 3 is worse than no gate, because it prints PASS. So the
# selected-entry count is compared against the TOTAL run_all.sh reports and a
# mismatch exits 3 (GATE ERROR) rather than 0. Same reason `--cases` in
# run_all.sh refuses a filter that matches nothing.
#
# AND IT MAPS THE OTHER DIRECTION OF THE SAME MERGE. `git diff M^1 M` is the
# merge's result against the branch it was merged INTO, which does not mention
# what main gained while the other branch was away — for 5b4731f that is the R3
# ports, the actual cause. So the diff from the merge base to M^1 is mapped as
# well and its cases are selected too. Both sets are printed with their
# provenance and the two together are what runs. --no-behind drops the second
# set; it only ever makes the gate run more, never less.
#
# THE DIRTY-TREE RULE. The suite runs against the WORKING TREE, not the commit,
# because that is what a push ships. An uncommitted change is included and
# reported, so "the merge is green" is never claimed for a tree that is not the
# one being pushed.
#
# WHAT IT DOES NOT NARROW. The firmware, param-guard, lint, doc, formal and
# mutation gates inside run_all.sh are unconditional, so a merge that maps to
# one testbench still pays for them. What the mapping narrows is the RTL
# simulation loop, which is where the six acts failed. Mapping the mutation
# suites onto the RTL they mutate is a real improvement and is NOT done here.
#
# Usage:
#   regress/verify_merge.sh [REV] [--fast [-jN]]   gate REV (default HEAD)
#   regress/verify_merge.sh --list [REV]          print the mapping, run nothing
#   regress/verify_merge.sh --full                skip the mapping, full suite
#   regress/verify_merge.sh --base B [REV]        diff REV against B (non-merge)
#   regress/verify_merge.sh --no-behind           drop the behind-while-away set
#   regress/verify_merge.sh --self-test           the mapper's own test (no RTL)
#
# Exit: 0 = the affected set is green, 1 = it is RED with a named failing case,
#        2 = usage/environment, 3 = the gate could not confirm it ran the set
#        it selected, 4 = INCONCLUSIVE — the run produced no verdict at all
#        (killed, out of disk, or the single-run lock refused it). 4 is not a
#        pass and not a red: nothing is claimed either way, and the fix is to
#        make the run finish, not to read the number.

set -u
cd "$(dirname "$0")/.." || exit 1

REV=""; BASE=""; MODE="run"; BEHIND=1; FORCE_FULL=0
EXTRA=()
usage() { sed -n '/^# Usage:/,/^#        3 =/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list)      MODE="list" ;;
    --full)      FORCE_FULL=1 ;;
    --no-behind) BEHIND=0 ;;
    --base)      BASE="${2:-}"; shift ;;
    --self-test) MODE="self-test" ;;
    --fast)      EXTRA+=(--fast) ;;
    -j)          EXTRA+=(-j "${2:-}"); shift ;;
    -j*)         EXTRA+=("$1") ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "verify_merge.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
    *)
      if [ -n "$REV" ]; then
        echo "verify_merge.sh: one revision only (got '$REV' and '$1')" >&2; exit 2
      fi
      REV="$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# The case table: run_all.sh's own CASES array, read rather than restated.
# ---------------------------------------------------------------------------
CASE_TABLE=""
load_case_table() {  # $1 = file containing the array
  CASE_TABLE=$(awk '/^CASES=\(/,/^\)/' "$1" 2>/dev/null \
               | grep -oE '"[^"]*\|[^"]*\|[^"]*"' | tr -d '"')
}

# The rtl files one entry compiles, with the array's ../rtl/... form normalised
# to the repo-relative path git reports.
entry_rtl_files() {
  printf '%s\n' "$1" | cut -d'|' -f2 | tr ' ' '\n' | sed 's|^\.\./||' | grep -v '^$'
}
entry_name() { printf '%s\n' "$1" | cut -d'|' -f1; }

entry_top()  { printf '%s\n' "$1" | cut -d'|' -f3; }

# A case that compiles the CPU or the SoC is a case whose DUT is partly
# FIRMWARE, so a firmware or assembler change reaches all of them.
is_cpu_case() {
  entry_rtl_files "$1" | grep -Fxq 'rtl/pe_cpu.v' \
    || entry_rtl_files "$1" | grep -Fxq 'rtl/pe_soc.v'
}

# WHICH CASE READS WHICH PACKAGE DIRECTORY, learned from the testbenches
# themselves. A testbench's data is not always named after it: tb_pe_ctrl_r2
# $readmemh's tb/r2-vectors/*.hex and tb_pe_ctrl_r3_conf reads
# tb/r3-vectors/*.hex, so a change to a vector BYTE belongs to that case even
# though the directory is not a case name. Derived by scanning each case's own
# source, so a testbench that starts reading a new directory teaches the gate
# that directory without anyone editing the gate. Without this the gate called
# all ten r2-vectors files of the held-core commit a "same-list violation" —
# ten false alarms, which is how a real one (tb_pe_soc_freqmeter.v) gets
# ignored.
DATA_DIRS=""
load_data_dirs() {
  local e name d
  DATA_DIRS=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    name=$(entry_name "$e")
    [ -f "tb/${name}.v" ] || continue
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      DATA_DIRS="$DATA_DIRS$d	$name
"
    done < <(grep -oE '\.\./tb/[A-Za-z0-9_.-]+/' "tb/${name}.v" 2>/dev/null \
             | sed 's|^\.\./||; s|/$||' | sort -u)
  done <<< "$CASE_TABLE"
}
cases_reading_dir() {  # $1 = repo-relative dir, e.g. tb/r2-vectors
  printf '%s' "$DATA_DIRS" | awk -F'\t' -v d="$1" '$1 == d { print $2 }'
}

# ---------------------------------------------------------------------------
# THE MUTATION SUITES (manager ruling 2026-09-25: MAPPED, NOT SKIPPED).
#
# A suite runs in a narrowed gate IFF one of its MUTABLE targets intersects the
# merge-mapped changed set. The lists are the harnesses' own `MUTABLE="..."`
# declarations, read exactly the way run_all.sh's CASES array is read — the gate
# never restates them — and regress/check_mutation_lists.sh is what proves each
# list still covers every file its harness writes. Without that checker a stale
# list would make this gate SKIP the suite guarding a changed file, which is the
# one failure mode a gate in this project may not have.
#
# THE THREE ESCALATIONS, all to running MORE, never less:
#   * a harness with no MUTABLE line   -> unmappable, run everything
#   * an empty RUN set                 -> run everything (an empty selection is
#                                        indistinguishable from a broken mapper,
#                                        and it is refused the same way an
#                                        empty CASE selection is)
#   * a suite with an EMPTY MUTABLE    -> never narrowed away: it mutates
#                                        nothing in the repo, so no merge can
#                                        affect it and it always runs
# A full unfiltered run_all.sh (the master/nightly gate) is untouched by all of
# this: the narrowing exists only here, and only when a mapping applies.
# ---------------------------------------------------------------------------
MUT_TABLE=""      # newline-separated "suite<TAB>m1 m2 ..."
MUT_UNMAPPABLE=""  # suites with no MUTABLE line

load_mut_table() {
  local f n m
  MUT_TABLE=""; MUT_UNMAPPABLE=""
  for f in regress/mutate_*.sh; do
    n=${f##*/}; n=${n%.sh}
    if ! m=$(grep -m1 '^MUTABLE=' "$f" | cut -d'"' -f2); then m=""; fi
    if grep -q '^MUTABLE=' "$f"; then
      MUT_TABLE="$MUT_TABLE$n	$m
"
    else
      MUT_UNMAPPABLE="$MUT_UNMAPPABLE $n"
    fi
  done
}

# Sets MUT_RUN / MUT_SKIP / MUT_WHY / MUT_FULL_REASON for the given changed set.
map_mutations() {  # stdin = the same changed-path list the cases were mapped from
  local changed suite targets t
  changed=$(cat)
  MUT_RUN=""; MUT_SKIP=""; MUT_WHY=""; MUT_FULL_REASON=""
  if [ -n "$MUT_UNMAPPABLE" ]; then
    MUT_FULL_REASON="these harnesses declare no MUTABLE list, so their scope is unknown:$MUT_UNMAPPABLE"
    return 0
  fi
  while IFS=$'\t' read -r suite targets; do
    [ -n "$suite" ] || continue
    if [ -z "${targets// /}" ]; then
      MUT_RUN="$MUT_RUN $suite"
      MUT_WHY="$MUT_WHY$suite	MUTABLE is empty: mutates nothing in the repo, never narrowed away
"
      continue
    fi
    local hit=""
    for t in $targets; do
      if printf '%s\n' "$changed" | grep -Fxq "$t"; then hit="$t"; break; fi
    done
    if [ -n "$hit" ]; then
      MUT_RUN="$MUT_RUN $suite"
      MUT_WHY="$MUT_WHY$suite	MUTABLE intersects the changed set ($hit)
"
    else
      MUT_SKIP="$MUT_SKIP $suite"
      MUT_WHY="$MUT_WHY$suite	no MUTABLE target among the changed files
"
    fi
  done <<< "$MUT_TABLE"
  # The empty-selection refusal, symmetric with the case mapping's.
  if [ -z "$(printf '%s' "$MUT_RUN" | tr -d ' ')" ]; then
    MUT_FULL_REASON="no suite's MUTABLE list intersects the changed set (empty selection — refused, running every suite rather than claiming a green from zero mutation coverage)"
  fi
  return 0
}

# Does this regex select exactly the suites map_mutations chose to run? The
# hand-off between the two halves is a contract, and the --cases hand-off already
# taught this project what an unasserted hand-off costs.
mut_regex_test() {  # $1 = expected count, $2 = label
  local want="$1" label="$2" re sel n
  re="^($(printf '%s' "$MUT_RUN" | tr ' ' '\n' | grep -v '^$' | sort -u | paste -sd'|' -))$"
  sel=0
  while IFS=$'\t' read -r suite _t; do
    [ -n "$suite" ] || continue
    if printf '%s\n' "$suite" | grep -qE "$re"; then sel=$((sel + 1)); fi
  done <<< "$MUT_TABLE"
  n=$sel
  if [ "$n" -ne "$want" ]; then
    printf '  FAIL  %-46s regex %s selects %s, mapping chose %s\n' "$label" "$re" "$n" "$want"
    return 1
  fi
  printf '  ok    %-46s regex selects the %s suite(s) the mapping chose\n' "$label" "$n"
  return 0
}

SELECTED=""      # newline-separated "name|top" entries
SEL_WHY=""       # the same entries + TAB + why
FULL_REASON=""   # non-empty => run everything
WARNINGS=""      # paths the mapping could not place

add_sel() {  # $1 = entry, $2 = why
  if ! printf '%s\n' "$SELECTED" | grep -Fxq "$1"; then
    SELECTED="$SELECTED$1
"
    SEL_WHY="$SEL_WHY$1	$2
"
  fi
}

# Records that may change what a case CLAIMS but cannot break one. An explicit
# list rather than a default, because the default (anything unknown = full
# suite) is the direction that keeps a merge from being pushed red. Each entry
# is justified by what READS it, and every changed path is printed, so a
# reviewer can check the classification instead of trusting it:
#   WORKLOG/COLD-START/HANDOFF/README  the human record; no gate reads them
#   reviews/ logs/                     evidence and history; no gate reads them
#   docs/                              operator narrative; no gate reads them
# NOT here, deliberately: wiki/ (tools/gen writes wiki/reference/* and
# run_all.sh checks them STALE), regress/ (the gates themselves), formal/,
# flow/, tools/ outside the assembler, and anything unrecognised.
is_record_only() {
  case "$1" in
    WORKLOG.md|HANDOFF.md|README.md|MANAGER-COLD-START.md|COLD-START.md) return 0 ;;
    reviews/*|logs/*|docs/*) return 0 ;;
    *) return 1 ;;
  esac
}

# map_changed: stdin = one changed path per line, blank lines ignored. Sets
# SELECTED / SEL_WHY / FULL_REASON / WARNINGS. $1 = the diff's label.
# CALL IT WITH A HERE-STRING, NEVER A PIPE. `printf ... | map_changed` runs the
# function in a subshell, so every value it sets is discarded on return and the
# gate selects nothing while reporting an empty mapping. The self-test's own
# counter is guarded for exactly this reason.
map_changed() {
  local label="$1" f e hit base fw_seen="" INERT="" fw_n fw_short d readers rn
  SELECTED=""; SEL_WHY=""; FULL_REASON=""; WARNINGS=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      rtl/*.v)
        hit=""
        while IFS= read -r e; do
          [ -n "$e" ] || continue
          if entry_rtl_files "$e" | grep -Fxq "$f"; then
            hit=1
            add_sel "$e" "compiles $f ($label)"
          fi
        done <<< "$CASE_TABLE"
        # An rtl file no case compiles is a coverage gap, not a broken build:
        # nothing selected can be affected by it, so it is reported loudly
        # rather than answered with a full-suite run that would prove nothing
        # about it either.
        [ -n "$hit" ] || WARNINGS="$WARNINGS  $label: $f is compiled by NO case in the suite (coverage gap, not a break)
" ;;
      tb/*)
        # tb/<case>.v is the testbench itself; tb/<case>/anything is that case's
        # OWN data (vector dirs, hex, model images), and the case is the
        # DIRECTORY there, not the file. Getting this wrong selects nothing and
        # the empty-mapping fallback silently runs everything instead.
        base=${f#tb/}
        case "$base" in */*) base=${base%%/*} ;; esac
        base=${base%.v}
        e=$(printf '%s\n' "$CASE_TABLE" | grep "^${base}|" | head -1)
        if [ -n "$e" ]; then
          add_sel "$e" "its own testbench $f ($label)"
        else
          # Not a testbench name: is it a PACKAGE DIRECTORY one of them reads?
          local d="tb/$base" readers
          readers=$(cases_reading_dir "$d")
          if [ -n "$readers" ]; then
            while IFS= read -r rn; do
              [ -n "$rn" ] || continue
              add_sel "$(printf '%s\n' "$CASE_TABLE" | grep "^${rn}|" | head -1)" \
                      "its golden data $f ($label)"
            done <<< "$readers"
          else
            # A testbench that is not in run_all.sh is not in the regression at
            # all (the same-list rule). Loud, because it means the suite's own
            # claim — "every testbench, one command" — is false for this file.
            WARNINGS="$WARNINGS  $label: $f is NOT in run_all.sh's CASES, and no testbench in the suite reads $d/ (same-list violation; not in the regression)
"
          fi
        fi ;;
      firmware/*|tools/fw/*)
        fw_seen="$fw_seen$f " ;;
      *)
        if is_record_only "$f"; then
          INERT="$INERT $f"
          WARNINGS="$WARNINGS  $label: $f is a record, not an input to any gate (inert)
"
        elif [ -z "$FULL_REASON" ]; then
          FULL_REASON="$f (a change outside rtl/, tb/ and firmware/assembler)"
        fi ;;
    esac
  done

  if [ -n "$fw_seen" ]; then
    # Compact reason: a merge that brings twelve firmware files would otherwise
    # print the same twelve-file list against every one of 20 cases.
    fw_n=$(printf '%s' "$fw_seen" | wc -w)
    fw_short=$(printf '%s' "$fw_seen" | tr ' ' '\n' | head -2 | paste -sd' ' -)
    [ "$fw_n" -gt 2 ] && fw_short="$fw_short +$((fw_n - 2)) more"
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      if is_cpu_case "$e"; then
        add_sel "$e" "DUT is partly firmware; $fw_n firmware/assembler file(s): $fw_short ($label)"
      fi
    done <<< "$CASE_TABLE"
  fi

  # THE FAIL-SAFE, announced rather than silent. An empty selection is NOT
  # "nothing to run": it is indistinguishable from a mapper that has stopped
  # understanding the case table, and a gate that reports GREEN for an empty
  # selection is the exact failure this file exists to prevent (a red merge
  # pushed with a gate that ran nothing). So an empty mapping runs everything,
  # including when the only changed paths were inert records -- proving a
  # negative is not worth a silent pass.
  if [ -z "$SELECTED" ] && [ -z "$FULL_REASON" ]; then
    if [ -n "$INERT" ]; then
      FULL_REASON="no gate input changed (only inert records:$INERT) — empty mapping, running everything rather than claiming a negative"
    else
      FULL_REASON="no case maps to the changed files (empty mapping)"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Self-test of the mapper. A classifier is an assertion, and an untested
# assertion is a claim: this project's own log holds three separate entries for
# a rule reporting numbers it had never been shown to compute. Each rule below
# is one where a wrong answer would be invisible, so each is fed a synthetic
# case table and a synthetic diff and the RESULT is checked, not the intent.
# ---------------------------------------------------------------------------
# THE REGEX CONTRACT IS ASSERTED, NOT ASSUMED. The gate selects cases and hands
# run_all.sh a REGEX; the two sides are different code in different files, and
# when they disagreed the filter selected nothing while the gate still had a
# selection to show. So the self-test also builds a regex the way the driver
# does and matches it the way run_all.sh does, and requires the same count.
filter_contract_test() {
  local want="$1" label="$2" names re sel n
  contract_ran=$((contract_ran + 1))
  names=$(printf '%s\n' "$SEL_WHY" | cut -f1 | cut -d'|' -f1 | sort -u)
  re="^($(printf '%s' "$names" | paste -sd'|' -))$"
  sel=0
  # run_all.sh's own matcher, verbatim: name and TOP as separate lines.
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if printf '%s\n' "$(entry_name "$e")" "$(entry_top "$e")" | grep -qE "$re"; then
      sel=$((sel + 1))
    fi
  done <<< "$CASE_TABLE"
  if [ "$sel" -ne "$want" ]; then
    printf '  FAIL  %-46s regex %s selects %s, gate selected %s\n' "$label" "$re" "$sel" "$want"
    return 1
  fi
  printf '  ok    %-46s regex selects %s case(s) as mapped\n' "$label" "$sel"
  return 0
}

selftest() {
  # NOTE the here-strings, not pipes: `printf ... | st` runs the function in a
  # SUBSHELL, so its counters would be lost and this self-test could report
  # success having counted nothing. The guard below is the anti-vacuity check;
  # it must not be the thing that is vacuous.
  local real_table="$CASE_TABLE" real_dirs="$DATA_DIRS" real_mut="$MUT_TABLE" bad=0 ran=0 contract_ran=0 want_rules=23 want_contract=4
  CASE_TABLE="tb_a|../rtl/pe_cpu.v|tb_a
tb_b|../rtl/pe_ctrl.v|tb_b
tb_c|../rtl/pe_cpu.v ../rtl/pe_soc.v|tb_c
tb_line_codec|../rtl/pe_nrzi.v|tb_line_codec"
  st() {  # $1 = label, $2 = SELECT|FULL, $3 = expected case count,
          # $4 = substring the warnings must contain ("" = don't care); stdin = diff
    local label="$1" want_kind="$2" want_n="$3" want_w="$4" kind n
    ran=$((ran + 1))
    map_changed "st"
    if [ -n "$FULL_REASON" ]; then kind=FULL; else kind=SELECT; fi
    n=$(printf '%s' "$SELECTED" | grep -c . || true)
    if [ "$kind" != "$want_kind" ] || [ "$n" != "$want_n" ]; then
      printf '  FAIL  %-46s got %s/%s, expected %s/%s\n' "$label" "$kind" "$n" "$want_kind" "$want_n"
      bad=$((bad + 1)); return
    fi
    if [ -n "$want_w" ] && ! printf '%s' "$WARNINGS" | grep -qF "$want_w"; then
      printf '  FAIL  %-46s selected %s, but no warning said %s\n' "$label" "$n" "$want_w"
      bad=$((bad + 1)); return
    fi
    printf '  ok    %-46s %s, %s case(s)\n' "$label" "$kind" "$n"
  }
  echo "verify_merge.sh self-test ($((want_rules + want_contract)) checks):"
  # The synthetic case table's testbenches do not exist on disk, so the
  # package-directory rule is exercised with an injected association - the same
  # shape load_data_dirs builds from the real sources.
  DATA_DIRS="tb/r2-vectors	tb_b
tb/r3-vectors	tb_b
"
  st "an rtl file selects only its compilers" SELECT 1 ""                            <<< "rtl/pe_ctrl.v"
  st "a testbench selects its own case" SELECT 1 ""                                <<< "tb/tb_b.v"
  st "a case's vector dir selects the case" SELECT 1 ""                            <<< "tb/tb_b/vectors.v"
  st "the CPU file selects both CPU cases" SELECT 2 ""                              <<< "rtl/pe_cpu.v"
  st "firmware selects every CPU case" SELECT 2 ""                                 <<< "firmware/x.pe"
  st "the assembler selects every CPU case" SELECT 2 ""                            <<< "tools/fw/peasm.py"
  st "rtl + its own tb, two cases" SELECT 2 ""                                     <<< "$(printf 'rtl/pe_ctrl.v\ntb/tb_a.v')"
  st "a record alone falls back to full (no silent negative)" FULL 0 "inert"      <<< "WORKLOG.md"
  st "an unexercised rtl file is reported, not selected" FULL 0 "coverage gap"    <<< "rtl/pe_new.v"
  st "a TB outside the suite is reported as a same-list hole" FULL 0 "same-list" <<< "tb/tb_nosuite.v"
  st "a golden-byte change selects the case that reads it" SELECT 1 ""       <<< "tb/r2-vectors/v.req.hex"
  st "an unread directory is still a same-list hole" FULL 0 "same-list"      <<< "tb/tb_nosuite/data.hex"
  st "an unmappable file falls back to full" FULL 0 ""                              <<< "flow/foo.tcl"
  st "wiki/ is global (the reference gates read it)" FULL 0 ""                      <<< "wiki/reference/x.md"
  st "docs alone fall back to full (nothing to narrow)" FULL 0 "inert"            <<< "docs/x.md"
  st "an rtl change plus a doc still selects one case" SELECT 1 ""                 <<< "$(printf 'rtl/pe_ctrl.v\ndocs/x.md')"
  st "a real change plus a record still selects the case" SELECT 1 ""              <<< "$(printf 'rtl/pe_ctrl.v\nWORKLOG.md')"

  # The two halves of the hand-off, asserted against each other.
  map_changed "contract" <<< "rtl/pe_ctrl.v"
  filter_contract_test 1 "one selected case, regex vs run_all's matcher" || bad=$((bad + 1))
  map_changed "contract" <<< "rtl/pe_cpu.v"
  filter_contract_test 2 "two selected cases, regex vs run_all's matcher" || bad=$((bad + 1))
  map_changed "contract" <<< "firmware/x.pe"
  filter_contract_test 2 "a firmware-wide selection, same contract" || bad=$((bad + 1))
  # ---- the mutation-suite mapping (manager ruling: MAPPED, NOT SKIPPED) ------
  # A synthetic MUTABLE table, so the rules are checked against known inputs:
  # suite A mutates a file the merge changes, suite B one it does not, suite C
  # mutates nothing in the repo.
  MUT_TABLE="mut_a	rtl/pe_soc.v
mut_b	rtl/pe_eth_mac.v
mut_c	
"
  MUT_UNMAPPABLE=""
  mut_st() {  # $1 = label, $2 = expected "runs/skips" e.g. "a,c/b", stdin = changed set
    local label="$1" want="$2" got runs skips
    ran=$((ran + 1))
    map_mutations
    runs=$(printf '%s' "$MUT_RUN" | tr -s ' ' '\n' | grep -v '^$' | sort | paste -sd, -)
    skips=$(printf '%s' "$MUT_SKIP" | tr -s ' ' '\n' | grep -v '^$' | sort | paste -sd, -)
    got="$runs/$skips"
    if [ "$got" = "$want" ]; then
      printf '  ok    %-46s run=[%s] skip=[%s]\n' "$label" "$runs" "$skips"
    else
      printf '  FAIL  %-46s got %s, expected %s\n' "$label" "$got" "$want"
      bad=$((bad + 1))
    fi
  }
  mut_st "a MUTABLE hit runs, a miss skips" "mut_a,mut_c/mut_b" <<< "rtl/pe_soc.v"
  mut_st "an unrelated change skips the hit too" "mut_c/mut_a,mut_b" <<< "rtl/pe_dru.v"
  mut_st "every suite runs when all three match" "mut_a,mut_b,mut_c/" <<< "$(printf 'rtl/pe_soc.v\nrtl/pe_eth_mac.v')"
  # The hand-off between the mapper and the MUTATE_ONLY it hands to run_all.sh.
  # Self-contained on purpose: the first version of this check read whatever
  # MUT_RUN the previous rule happened to leave behind, so it was asserting an
  # order rather than a mapping. A test that passes for the wrong reason is
  # worse than no test, because it looks like coverage.
  map_mutations <<< "rtl/pe_soc.v"
  mut_regex_test 2 "MUTATE_ONLY selects exactly the RUN set" || bad=$((bad + 1))
  contract_ran=$((contract_ran + 1))
  # THE REFUSAL, which is the ruling's explicit requirement: an empty mutation
  # selection must be refused exactly as an empty CASE selection is, because both
  # are indistinguishable from a mapper that has stopped working.
  MUT_TABLE="mut_d	rtl/pe_fbuf.v
"
  map_mutations <<< "rtl/pe_soc.v"
  if [ -n "$MUT_FULL_REASON" ] && [ -z "$(printf '%s' "$MUT_RUN" | tr -d ' ')" ]; then
    printf '  ok    %-46s refused: %s\n' "an empty mutation selection escalates" \
           "$(printf '%s' "$MUT_FULL_REASON" | cut -c1-60)..."
    ran=$((ran + 1))
  else
    printf '  FAIL  %-46s an empty selection was NOT refused\n' "an empty mutation selection escalates"
    bad=$((bad + 1))
  fi
  # ... and the skip must never be silent: every suite needs a printed reason.
  MUT_TABLE="mut_a	rtl/pe_soc.v
mut_b	rtl/pe_eth_mac.v
mut_c	
"
  map_mutations <<< "rtl/pe_soc.v"
  if printf '%s' "$MUT_WHY" | grep -q "mut_b.*no MUTABLE target" \
     && printf '%s' "$MUT_WHY" | grep -q "mut_a.*intersects the changed set (rtl/pe_soc.v)" \
     && printf '%s' "$MUT_WHY" | grep -q "mut_c.*never narrowed away"; then
    printf '  ok    %-46s every suite carries a printed reason\n' "the skip print is never silent"
    ran=$((ran + 1))
  else
    printf '  FAIL  %-46s a suite has no reason line\n' "the skip print is never silent"
    bad=$((bad + 1))
  fi
  # An unmappable harness (no MUTABLE line) must escalate, never be assumed.
  MUT_TABLE=""; MUT_UNMAPPABLE="mut_new_tb"
  map_mutations <<< "rtl/pe_soc.v"
  if [ -n "$MUT_FULL_REASON" ]; then
    printf '  ok    %-46s unmappable harness escalates to all suites\n' "a missing MUTABLE line"
    ran=$((ran + 1))
  else
    printf '  FAIL  %-46s an unmappable harness did NOT escalate\n' "a missing MUTABLE line"
    bad=$((bad + 1))
  fi
  MUT_TABLE=""; MUT_UNMAPPABLE=""

  CASE_TABLE="$real_table"; DATA_DIRS="$real_dirs"; MUT_TABLE="$real_mut"
  if [ "$ran" -ne "$want_rules" ] || [ "$contract_ran" -ne "$want_contract" ]; then
    echo "  FAIL  exercised $ran rule(s) and $contract_ran contract check(s), expected $want_rules and $want_contract — the self-test would pass while checking less than it claims"
    exit 1
  fi
  TOTAL_CHECKS=$((want_rules + want_contract))
  if [ "$bad" -ne 0 ]; then
    echo "verify_merge.sh self-test: $bad check(s) of $TOTAL_CHECKS FAILED"; exit 1
  fi
  echo "verify_merge.sh self-test: $TOTAL_CHECKS/$TOTAL_CHECKS checks ($want_rules mapper rules + $want_contract regex-contract), mapper and hand-off verified"
}

if [ "$MODE" = "self-test" ]; then selftest; exit $?; fi

# ---------------------------------------------------------------------------
# Resolve the revision, and the two diffs.
# ---------------------------------------------------------------------------
REV=${REV:-HEAD}
if ! git rev-parse --verify -q "${REV}^{commit}" >/dev/null; then
  echo "verify_merge.sh: '$REV' is not a commit" >&2; exit 2
fi
MERGE=no
if [ "$(git rev-list --parents -n1 "$REV" | wc -w)" -gt 2 ]; then MERGE=yes; fi

load_case_table regress/run_all.sh
load_data_dirs
if [ -z "$CASE_TABLE" ]; then
  # Loud, and to the SAFE side: with no readable table there is no mapping, and
  # a full suite is the only honest answer to "what does this merge break".
  echo "verify_merge.sh: WARNING could not parse run_all.sh's CASES array -- running the FULL suite" >&2
  FORCE_FULL=1
fi

MERGE_CHANGED=""; BEHIND_CHANGED=""
if [ "$MERGE" = yes ]; then
  if [ -n "$BASE" ]; then
    MERGE_CHANGED=$(git diff --name-only "$BASE" "$REV")
  else
    MERGE_CHANGED=$(git diff --name-only "$REV^1" "$REV")
  fi
  if [ "$BEHIND" -eq 1 ]; then
    MB=$(git merge-base "$REV^1" "$REV^2" 2>/dev/null)
    if [ -n "$MB" ]; then
      BEHIND_CHANGED=$(git diff --name-only "$MB" "$REV^1")
    else
      echo "verify_merge.sh: WARNING no merge base for $REV^1/$REV^2 — the behind-while-away set is MISSING" >&2
    fi
  fi
else
  B=${BASE:-$REV^}
  if ! git rev-parse --verify -q "${B}^{commit}" >/dev/null; then
    echo "verify_merge.sh: '$B' is not a commit (a root commit has no parent to diff)" >&2; exit 2
  fi
  MERGE_CHANGED=$(git diff --name-only "$B" "$REV")
fi

DIRTY=$(git status --porcelain 2>/dev/null | grep -c . || true)

# ---------------------------------------------------------------------------
# Map both diffs and union the two selections.
# ---------------------------------------------------------------------------
map_changed "merged" <<< "$MERGE_CHANGED"
MERGE_WHY="$SEL_WHY"; MERGE_FULL="$FULL_REASON"
MERGE_WARN="$WARNINGS"; MERGE_N=$(printf '%s' "$SELECTED" | grep -c . || true)
BEHIND_N=0; BEHIND_WHY=""; BEHIND_WARN=""; BEHIND_FULL=""
if [ -n "$BEHIND_CHANGED" ]; then
  map_changed "behind" <<< "$BEHIND_CHANGED"
  BEHIND_WHY="$SEL_WHY"
  BEHIND_WARN="$WARNINGS"; BEHIND_FULL="$FULL_REASON"
  BEHIND_N=$(printf '%s' "$SELECTED" | grep -c . || true)
  while IFS=$'\t' read -r e why; do
    [ -n "$e" ] || continue
    add_sel "$e" "$why"
  done <<< "$BEHIND_WHY"
  if [ -n "$BEHIND_FULL" ] && [ -z "$MERGE_FULL" ]; then
    FULL_REASON="behind-while-away: $BEHIND_FULL"
  fi
fi

EXPECTED=$(printf '%s' "$SELECTED" | grep -c . || true)
NAMES=$(printf '%s' "$SEL_WHY" | cut -f1 | cut -d'|' -f1 | sort -u)
ALLCASES=$(printf '%s\n' "$CASE_TABLE" | grep -c . || true)

echo "========================================"
echo "MERGE GATE — $REV ($(git log -1 --format=%s "$REV" | cut -c1-60))"
if [ "$MERGE" = yes ]; then
  if [ -n "$BASE" ]; then
    echo "  base:     $BASE (explicitly given)"
  else
    echo "  base:     ${REV}^1 (first parent);  merge base $(git merge-base "$REV^1" "$REV^2" 2>/dev/null | cut -c1-8)"
  fi
else
  echo "  base:     ${BASE:-$REV^} (not a merge commit)"
fi
echo "  changed:  $(printf '%s' "$MERGE_CHANGED" | grep -c . || true) path(s) merged in" \
     "$( [ "$MERGE" = yes ] && echo "| behind: $(printf '%s' "$BEHIND_CHANGED" | grep -c . || true) path(s) main gained while it was away" )"
if [ "${DIRTY:-0}" -gt 0 ]; then
  echo "  NOTE: working tree is DIRTY ($DIRTY path(s)); the run is against the TREE, not the commit."
fi
echo
echo "--- merged-in set ($MERGE_N case(s)) ---"
printf '%s' "$MERGE_WHY" | while IFS=$'\t' read -r e why; do
  [ -n "$e" ] || continue; printf '  %-26s %s\n' "$(entry_name "$e")" "$why"
done
if [ "${BEHIND_N:-0}" -gt 0 ]; then
  echo "--- behind-while-away set ($BEHIND_N case(s)) ---"
  printf '%s' "$BEHIND_WHY" | while IFS=$'\t' read -r e why; do
    [ -n "$e" ] || continue; printf '  %-26s %s\n' "$(entry_name "$e")" "$why"
  done
fi
[ -n "$MERGE_WARN" ] && printf '%s' "$MERGE_WARN" | sed 's/^  /  ! /'
[ -n "$BEHIND_WARN" ] && printf '%s' "$BEHIND_WARN" | sed 's/^  /  ! /'

# ---- the mutation suites, mapped (manager ruling 2026-09-25: MAPPED, NOT SKIPPED)
CHANGED_ALL=$(printf '%s\n%s' "$MERGE_CHANGED" "$BEHIND_CHANGED" | grep -v '^$')
load_mut_table
map_mutations <<< "$CHANGED_ALL"
MUT_RUN_N=$(printf '%s' "$MUT_RUN" | tr -s ' ' '\n' | grep -c . || true)
MUT_SKIP_N=$(printf '%s' "$MUT_SKIP" | tr -s ' ' '\n' | grep -c . || true)
MUT_TOTAL_N=$(printf '%s\n' "$MUT_TABLE" | grep -c . || true)
MUT_REGEX=""; MUT_ALL_REASON=""
if [ -n "$MUT_FULL_REASON" ]; then
  MUT_ALL_REASON="ALL $MUT_TOTAL_N suites: $MUT_FULL_REASON"
else
  MUT_REGEX="^($(printf '%s' "$MUT_RUN" | tr ' ' '\n' | grep -v '^$' | sort -u | paste -sd'|' -))$"
fi
echo "--- mutation suites ($MUT_RUN_N run, $MUT_SKIP_N skipped by mapping, $MUT_TOTAL_N total) ---"
printf '%s' "$MUT_WHY" | while IFS=$'\t' read -r suite why; do
  [ -n "$suite" ] || continue
  case " $MUT_RUN " in *" $suite "*) v="RUN  " ;; *) v="SKIP " ;; esac
  printf '  %s %-26s %s\n' "$v" "$suite" "$why"
done
[ -n "$MUT_ALL_REASON" ] && echo "  -> $MUT_ALL_REASON"

REGEX=""
if [ "$FORCE_FULL" -eq 1 ] || [ -n "$FULL_REASON" ]; then
  [ "$FORCE_FULL" -eq 1 ] && [ -z "$FULL_REASON" ] && FULL_REASON="--full requested"
  echo "  -> FULL SUITE: $FULL_REASON"
  # A full run is the MASTER gate, not merge triage: it runs EVERY mutation
  # suite. The narrowing lives only here, and only when a mapping applies.
  MUT_REGEX=""
else
  REGEX="^($(printf '%s' "$NAMES" | paste -sd'|' -))$"
  echo "  -> $EXPECTED of $ALLCASES cases selected; run_all.sh runs the rest of the gate unfiltered"
  if [ -n "$MUT_REGEX" ]; then
    echo "  -> mutation suites narrowed to $MUT_RUN_N of $MUT_TOTAL_N by mapping (MUTATE_ONLY)"
  else
    echo "  -> mutation suites: all $MUT_TOTAL_N ($MUT_ALL_REASON)"
  fi
fi
echo

if [ "$MODE" = "list" ]; then
  echo "(--list: nothing was run)"
  [ -n "$REGEX" ] && echo "--cases $REGEX"
  [ -n "$MUT_REGEX" ] && echo "MUTATE_ONLY=$MUT_REGEX"
  exit 0
fi

# ---------------------------------------------------------------------------
# Drive run_all.sh: the entry point the project already trusts, with --cases
# narrowing the RTL loop. Its firmware, param-guard, lint, doc, formal and
# mutation gates run exactly as they always do.
# ---------------------------------------------------------------------------
CMD=(./regress/run_all.sh)
[ -n "$REGEX" ] && CMD+=(--cases "$REGEX")
[ "${#EXTRA[@]}" -gt 0 ] && CMD+=("${EXTRA[@]}")
# The mutation narrowing travels as an environment variable, not an argument, so
# that an ordinary `./regress/run_all.sh` — the master gate, and every human
# habit in this repository — is untouched by any of this.
[ -n "$MUT_REGEX" ] && export MUTATE_ONLY="$MUT_REGEX"
LOG=$(mktemp /tmp/verify_merge.XXXXXX.log)
echo "+ ${CMD[*]}"
echo "(full log: $LOG)"
"${CMD[@]}" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

TOTAL=$(grep -E '^TOTAL: [0-9]+' "$LOG" | tail -1 | awk '{print $2}')
SELECTED_BY_RUN=$(grep -oE '[-][-]cases [^:]*: [0-9]+ selected' "$LOG" | tail -1 | grep -oE '[0-9]+ selected' | grep -oE '[0-9]+')
# The same discipline for the mutation narrowing. The ruling's own words: GREEN
# must never claim more than it ran. So the number of suites run_all.sh reports
# is compared against the number the mapping chose, and a mismatch is a GATE
# ERROR, not a pass — otherwise a MUTATE_ONLY that silently matched nothing
# would report a green with zero mutation coverage, which is the most expensive
# possible way to be wrong.
MUT_RAN_BY_RUN=$(grep -E '^mutation suites: [0-9]+ ran' "$LOG" | tail -1 | grep -oE '[0-9]+' | head -1)
MUT_SKIPPED_BY_RUN=$(grep -E '^mutation suites: [0-9]+ ran' "$LOG" | tail -1 | grep -oE '[0-9]+ SKIPPED' | grep -oE '[0-9]+')
# The evidence for a red: a NAMED failing case or gate. A non-zero exit with
# nothing named is a run that produced NO verdict (OOM-killed mid-loop, out of
# disk, the lock refusing), and reporting that as "RED, the affected set
# failed" is a claim the log does not support — demonstrated on this gate's
# own first run, which exited 137 with an empty failure list.
FAILS=$(grep -E '^(failed:|firmware regression: FAILED|lint gate FAILED|.*mutations: FAILED|STALE:|FATAL)' "$LOG" | sort -u)
# The one non-zero exit that is neither red nor inconclusive: the gate computed
# a selection and run_all.sh's own filter REJECTED it. Those are two pieces of
# this same gate disagreeing about the case table, which is a gate defect, and
# it is a defect rather than a test result — so it gets its own code.
REJECTED=$(grep -c 'matched NO case' "$LOG")
# THE HARNESS-EDIT PRE-FLIGHT, as the gate sees it. A dependency guard that fired
# means the run's own scripts moved underneath it, so it verified nothing — and
# an exit 0 is precisely what a FALSE PASS looks like from out here. So this is
# checked BEFORE the exit code, and it wins over a green: the marker in the log
# forces INCONCLUSIVE whatever the run said about itself.
DEP_CHANGED=$(grep -c 'CHIP-DEP-CHANGED' "$LOG")

echo
echo "========================================"
if [ "${DEP_CHANGED:-0}" -gt 0 ]; then
  {
    echo "MERGE GATE: INCONCLUSIVE — a script this run depends on CHANGED while it was running."
    echo "  Do not read this as a test failure, and do not read it as a pass either."
    echo "  Bash executes a script incrementally, so a harness edited mid-run can report"
    echo "  a FALSE PASS as easily as a false failure, and this run's verdict cannot be"
    echo "  trusted in either direction. The run that reported it:"
    grep -E 'CHIP-DEP-CHANGED|INCONCLUSIVE — ' "$LOG" | head -6 | sed 's/^/    /'
    echo "  Re-run the gate with nothing editing regress/ concurrently."
  } >&2
  exit 4
fi
if [ "${REJECTED:-0}" -gt 0 ]; then
  echo "MERGE GATE: GATE ERROR — run_all.sh rejected the filter this gate built." >&2
  echo "  The gate selected $EXPECTED case(s) and the suite found none of them." >&2
  echo "  That is a disagreement between two halves of one gate about the case" >&2
  echo "  table, not a property of the RTL. Do not push, and do not 'fix' it by" >&2
  echo "  widening the filter: run --self-test, which asserts the regex contract." >&2
  exit 3
fi
if [ "$RC" -ne 0 ]; then
  if [ -n "$FAILS" ]; then
    echo "MERGE GATE: RED — DO NOT PUSH $REV"
    echo "  the affected set failed (run_all.sh exit $RC). Named failures:"
    printf '%s\n' "$FAILS" | sed 's/^/    /'
    exit 1
  fi
  {
    echo "MERGE GATE: INCONCLUSIVE — DO NOT PUSH $REV, and do NOT read this as a test failure"
    echo "  run_all.sh exited $RC and named NO failing case, so nothing in the log says"
    echo "  the RTL is broken. It says the RUN did not finish. Causes, in the order"
    echo "  this has actually happened on this box:"
    echo "    137/143  killed — the OOM killer, or the run lock reaping its process group"
    echo "    75       another run holds /tmp/chip-run-all.lock; wait for it, do not retry in a loop"
    echo "    FATAL    a precondition (the SRAM behavioural model) is missing"
    echo "  Make the run finish and run the gate again. Pushing on an inconclusive gate"
    echo "  is exactly the failure this file exists to stop."
  } >&2
  [ -n "$TOTAL" ] || echo "  (no TOTAL line: the case loop never completed)" >&2
  exit 4
fi
# Anti-vacuity: a green run that did not run the set we selected is a GATE
# ERROR, not a pass. Without this the gate could report PASS for a filter that
# matched nothing — the exact failure it exists to prevent.
if [ -z "$TOTAL" ]; then
  echo "MERGE GATE: GATE ERROR — run_all.sh exited 0 without reporting a TOTAL." >&2
  echo "  A gate that cannot say how much it ran has verified nothing." >&2
  rm -f "$LOG"; exit 3
fi
WANT=$EXPECTED
[ -z "$REGEX" ] && WANT=$ALLCASES
if [ -n "$SELECTED_BY_RUN" ] && [ "$SELECTED_BY_RUN" != "$WANT" ]; then
  echo "MERGE GATE: GATE ERROR — selected $WANT case(s), run_all.sh selected $SELECTED_BY_RUN." >&2
  rm -f "$LOG"; exit 3
fi
if [ "$TOTAL" != "$WANT" ]; then
  echo "MERGE GATE: GATE ERROR — expected $WANT case(s) to run, TOTAL says $TOTAL." >&2
  echo "  The mapping and the suite disagree; treating that as a failure, not a pass." >&2
  rm -f "$LOG"; exit 3
fi
# ... and the same for the mutation suites. MUT_WANT is the number the mapping
# chose when it narrowed, or the full table when it escalated to running all.
MUT_WANT=$MUT_RUN_N
[ -z "$MUT_REGEX" ] && MUT_WANT=$MUT_TOTAL_N
if [ -z "$MUT_RAN_BY_RUN" ]; then
  echo "MERGE GATE: GATE ERROR — run_all.sh reported no mutation-suite count." >&2
  echo "  It must always say how many suites ran, narrowed or not." >&2
  rm -f "$LOG"; exit 3
fi
if [ "$MUT_RAN_BY_RUN" != "$MUT_WANT" ]; then
  echo "MERGE GATE: GATE ERROR — the mapping chose $MUT_WANT mutation suite(s), run_all.sh ran $MUT_RAN_BY_RUN." >&2
  echo "  GREEN would be claiming mutation coverage this run does not have." >&2
  rm -f "$LOG"; exit 3
fi
if [ -n "$MUT_SKIPPED_BY_RUN" ] && [ "$((MUT_RAN_BY_RUN + MUT_SKIPPED_BY_RUN))" != "$MUT_TOTAL_N" ]; then
  echo "MERGE GATE: GATE ERROR — $MUT_RAN_BY_RUN ran + $MUT_SKIPPED_BY_RUN skipped != $MUT_TOTAL_N suites." >&2
  rm -f "$LOG"; exit 3
fi
rm -f "$LOG"
echo "MERGE GATE: GREEN — $REV ($TOTAL case(s) run, $MUT_RAN_BY_RUN/$MUT_TOTAL_N mutation suites run$([ -n "$MUT_SKIPPED_BY_RUN" ] && echo ", $MUT_SKIPPED_BY_RUN skipped by mapping"))"
exit 0
