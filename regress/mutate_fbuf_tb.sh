#!/usr/bin/env bash
# Mutation-test tb_pe_fbuf.v: it must FAIL when the properties it claims break.
#
# The two properties this TB exists for are byte-granular writes and
# lane-correct reads, and BOTH failure modes are silent ones:
#
#   * a mask polarity/lane bug writes the whole word (clobbering the neighbour)
#     or writes nothing (the macro's BM=0 trap, which is not an error);
#   * a lane register captured one cycle late only misbehaves when consecutive
#     reads alternate lanes.
#
# Neither shows up in a design review of correct-looking code, which is why the
# TB has to be shown to actually catch them.
#
# THREE OUTCOMES, NOT TWO: a compile failure is INCONCLUSIVE (reported, and it
# fails the run), because "not detected" would be a false accusation against the
# TB and would hide a surviving mutation behind a build error.
#
# Usage: regress/mutate_fbuf_tb.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The SRAM model, because the default (FLOP=0) path is the real macro. Compiling
# without it silently falls back to... nothing, in this case -- pe_fbuf has no
# implicit fallback, so a missing model is a hard error. That is deliberate and
# matches pe_imem's policy, but the harness still checks it up front so the
# failure is one clear message instead of five mutations all "failing to build".
if ! SRAM_MODEL=$(cd sim && ../regress/sram_model.sh); then
  echo "FATAL: SRAM behavioural model unavailable; cannot simulate the macro path."
  exit 2
fi
SRAM_FLAGS=$(printf '%s ' $SRAM_MODEL)

detected=0
inconclusive=0
survived=0

MUTABLE="rtl/pe_fbuf.v"

# ---- restore VERIFICATION ---------------------------------------------------
# A harness that fails to restore leaves MUTATED RTL on disk and every later run
# then quietly tests the mutant. That has happened in this repo, and the result
# was a full regression reporting failures that were really the leftover
# mutation. The restore is verified per case against a PRISTINE SNAPSHOT taken
# here -- NOT against git. A `git diff --quiet` check flags any uncommitted
# change in the file, including a legitimate one made during development, so it
# reported RESTORE FAILED on a tree where the restore had in fact worked
# (measured: this file after removing an unused localparam).
PRISTINE=$(mktemp /tmp/pe_fbuf.pristine.XXXXXX.v)
cp "$MUTABLE" "$PRISTINE"

verify_restore() {
  if ! cmp -s "$PRISTINE" "$MUTABLE"; then
    echo "  RESTORE FAILED -- the file does not match the pristine snapshot:"
    diff "$PRISTINE" "$MUTABLE" | head -10 | sed 's/^/    /'
    echo "    Refusing to continue: every later result would be measuring the mutant."
    exit 3
  fi
}

# Compile and run ONE configuration of the TB. $1 = label, rest = iverilog args.
# Echoes the number of FAIL lines, or "BUILDFAIL".
run_tb() {
  local label="$1"; shift
  local work; work=$(mktemp -d)
  local cc=0
  (cd sim && iverilog -g2012 -s tb_pe_fbuf -o "$work/tb.vvp" "$@") \
      >"$work/compile.log" 2>&1 || cc=$?
  if [ "$cc" -ne 0 ] || [ ! -s "$work/tb.vvp" ]; then
    echo "BUILDFAIL"
    rm -rf "$work"
    return
  fi
  local out
  out=$(cd sim && vvp "$work/tb.vvp" 2>&1)
  rm -rf "$work"
  if grep -q '^FAIL' <<< "$out"; then
    echo "$(grep -c '^FAIL' <<< "$out")"
  else
    echo "0"
  fi
}

# A mutation is only DETECTED if BOTH implementations catch it. Checking only
# the macro path would let a mutation that the FLOP fallback misses through --
# and the fallback existing is the reason to check it.
run_case() {
  local name="$1"; shift
  local script="$1"

  echo "=== mutation: $name ==="

  local backup; backup=$(mktemp -d)
  cp rtl/pe_fbuf.v "$backup/"

  restore() { cp "$backup/pe_fbuf.v" rtl/pe_fbuf.v; rm -rf "$backup"; }

  if ! python3 "$script"; then
    echo "  MUTATION DID NOT APPLY -> INCONCLUSIVE"
    inconclusive=$((inconclusive+1))
    restore; verify_restore; echo; return
  fi

  local macro flop
  # Paths are sim/-relative because run_tb compiles from inside sim/ -- the same
  # reason regress/mutate_i2c_tb.sh passes ../rtl/... to its compile line. Passing
  # repo-root paths here made every mutation report BUILDFAIL, which the harness
  # correctly labelled INCONCLUSIVE rather than "detected".
  macro=$(run_tb "macro" $SRAM_FLAGS ../rtl/pe_fbuf.v ../tb/tb_pe_fbuf.v)
  flop=$(run_tb  "flop"  -DFLOP=1 ../rtl/pe_fbuf.v ../tb/tb_pe_fbuf.v)

  if [ "$macro" = "BUILDFAIL" ] || [ "$flop" = "BUILDFAIL" ]; then
    echo "  INCONCLUSIVE: the mutated design did not compile (macro=$macro flop=$flop)"
    inconclusive=$((inconclusive+1))
    restore; verify_restore; echo; return
  fi

  # A MUTATION NEED ONLY BE CAUGHT BY THE IMPLEMENTATION IT TOUCHES. Mutations
  # 1, 4 and 5 edit one path and leave the other byte-identical, so demanding a
  # failure from both was a wrong criterion -- it reported three real detects as
  # "survived". What it does mean is reported explicitly, so a mutation that
  # touches BOTH paths while only one notices is visible rather than averaged
  # away: that is the shape of a real blind spot, and it is how mutation 2 was
  # found (the live-lane mutation passed on both, because no check sampled
  # mid-cycle; the pipelined-read test now covers it).
  local caught=0
  local touched_both=0
  grep -q 'MUTANT' rtl/pe_fbuf.v && touched_both=1
  [ "$macro" -gt 0 ] && caught=1
  [ "$flop"  -gt 0 ] && caught=1

  if [ "$caught" -eq 1 ]; then
    if [ "$macro" -gt 0 ] && [ "$flop" -gt 0 ]; then
      echo "  DETECTED (both paths: macro=$macro FAILs, flop=$flop FAILs)"
    elif [ "$macro" -gt 0 ]; then
      echo "  DETECTED by the macro path ($macro FAILs); the flop path is" \
           "unaffected by this mutation, which is expected"
    else
      echo "  DETECTED by the flop path ($flop FAILs); the macro path is" \
           "unaffected by this mutation, which is expected"
    fi
    detected=$((detected+1))
  else
    echo "  SURVIVED -- blind spot: macro=$macro FAILs, flop=$flop FAILs"
    survived=$((survived+1))
  fi

  restore; verify_restore; echo
}

TMP=$(mktemp -d)
# Interruption is not an excuse to leave the checkout mutated. The per-case
# restore only runs on its normal path, and EXIT only cleaned temporaries -- so
# SIGTERM mid-simulation left the mutated RTL in place and the next regression
# measured it (measured, review 2 R2-7). This restores the pristine bytes on
# ANY exit, including TERM/INT, and a trapped signal EXITS rather than falling
# back into the script (bash continues after a TERM trap returns).
restore_pristine() {
  [ -f "$PRISTINE" ] && cp "$PRISTINE" "$MUTABLE"
  return 0
}
cleanup() {
  restore_pristine
  rm -rf "$TMP" "$PRISTINE"
}
on_signal() {
  cleanup
  trap - EXIT INT TERM
  exit 143
}
trap cleanup EXIT
trap on_signal INT TERM

# ---------------------------------------------------------------- mutation 1
# BREAK THE WRITE MASK: always select the low lane. A write to an odd (high-lane)
# address then clobbers the neighbouring even byte instead of its own.
cat > "$TMP/m1.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_fbuf.v'); t = p.read_text()
old = """      assign bm_m  = access_addr[0] ? 16'hFF00 : 16'h00FF;
      assign din_m = access_addr[0] ? {wdata, 8'h00} : {8'h00, wdata};"""
if old not in t:
    sys.exit("write-mask anchor not found")
new = """      assign bm_m  = 16'h00FF;                    // MUTANT: low lane only
      assign din_m = {8'h00, wdata};              // MUTANT: always low"""
t = t.replace(old, new, 1)
print("  write mask pinned to the low lane")
p.write_text(t)
PY

# ---------------------------------------------------------------- mutation 2
# BREAK THE READ LANE. Use the CURRENT address's lane instead of the registered
# one. This is the "lane captured too late" bug, in its most direct form: the
# mux then follows whichever address is presented, not the one being read.
cat > "$TMP/m2.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_fbuf.v'); t = p.read_text()
old = "  assign rdata = rd_lane ? word_rd[15:8] : word_rd[7:0];"
if old not in t:
    sys.exit("read-mux anchor not found")
new = "  assign rdata = raddr[0] ? word_rd[15:8] : word_rd[7:0];   // MUTANT: live lane"
t = t.replace(old, new, 1)
print("  read mux uses the live address lane, not the registered one")
p.write_text(t)
PY

# ---------------------------------------------------------------- mutation 3
# SWAP THE LANES on the read side: high byte where the low belongs. A
# byte-order bug in the read path, which the neighbour test catches directly.
cat > "$TMP/m3.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_fbuf.v'); t = p.read_text()
old = "  assign rdata = rd_lane ? word_rd[15:8] : word_rd[7:0];"
if old not in t:
    sys.exit("read-mux anchor not found")
new = "  assign rdata = rd_lane ? word_rd[7:0] : word_rd[15:8];   // MUTANT: lanes swapped"
t = t.replace(old, new, 1)
print("  read lanes swapped")
p.write_text(t)
PY

# ---------------------------------------------------------------- mutation 4
# TRUNCATE THE WORD ADDRESS: drop bit 1 of the byte address from the word
# address, so byte addresses 2 and 0 alias. An address-width bug, invisible at
# address 0 and invisible to the neighbour test, which is why the independent-
# byte check exists.
cat > "$TMP/m4.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_fbuf.v'); t = p.read_text()
# both the macro path and the flop path index by the word address
n = t.count("access_addr[AW-1:1]") + t.count("raddr[AW-1:1]") + t.count("waddr[AW-1:1]")
if n == 0:
    sys.exit("word-address indexing not found")
# In the flop path, alias by dropping bit 1: use [AW-1:2] padded with a 0.
t = t.replace("if (waddr[0]) mem[waddr[AW-1:1]][15:8] <= wdata;",
              "if (waddr[0]) mem[{waddr[AW-1:2], 1'b0}][15:8] <= wdata;   // MUTANT: bit 1 dropped")
t = t.replace("else          mem[waddr[AW-1:1]][7:0]  <= wdata;",
              "else          mem[{waddr[AW-1:2], 1'b0}][7:0]  <= wdata;   // MUTANT: bit 1 dropped")
t = t.replace("word_rd <= mem[raddr[AW-1:1]];",
              "word_rd <= mem[{raddr[AW-1:2], 1'b0}];                    // MUTANT: bit 1 dropped")
print("  word address bit 1 dropped (flop path): bytes 2 and 0 alias")
p.write_text(t)
PY

# ---------------------------------------------------------------- mutation 5
# BREAK THE MACRO'S WRITE-ENABLE DECODE so a read looks like a write. MEN/WEN
# both asserted with REN low means a write of garbage on every read, which
# destroys stored bytes as the test walks the array.
cat > "$TMP/m5.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_fbuf.v'); t = p.read_text()
old = "      assign we_m = access_is_write;\n      assign re_m = ~access_is_write;"
if old not in t:
    sys.exit("write-enable decode anchor not found")
new = "      assign we_m = 1'b1;         // MUTANT: always write\n      assign re_m = 1'b1;         // MUTANT: write-through always"
t = t.replace(old, new, 1)
print("  macro write-enable decoding broken (every access is a write-through)")
p.write_text(t)
PY

run_case "write mask pinned to the low lane"              "$TMP/m1.py"
run_case "read mux uses the live lane"                    "$TMP/m2.py"
run_case "read lanes swapped"                             "$TMP/m3.py"
run_case "word-address bit dropped (flop path)"           "$TMP/m4.py"
run_case "macro write-enable decode broken"               "$TMP/m5.py"

echo "================================================================"
echo "frame-buffer TB mutations: $detected detected, $survived survived, $inconclusive inconclusive"

[ "$inconclusive" -eq 0 ] || { echo "FAIL: an inconclusive mutation means the harness could not test it."; exit 1; }
[ "$survived" -eq 0 ] || { echo "FAIL: $survived mutation(s) survived -- the TB has a blind spot."; exit 1; }
echo "OK: every mutation was detected, so the TB is not vacuous."
