#!/usr/bin/env bash
# Mutation-test tb_pe_eth_mac.v: every check it makes must be able to FAIL.
#
# The TB passed on its first clean run, which by itself proves only that it
# agrees with the RTL. This harness breaks the RTL in six ways that each target
# one claim the TB makes, and requires the TB to notice every one.
#
# The mutations are chosen to be SUBTLE, not obvious: each is a plausible
# implementation choice somebody could genuinely write, so detecting it means
# the TB is testing the property and not the spelling.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
RTL="$ROOT/rtl/pe_eth_mac.v"
TB="$ROOT/tb/tb_pe_eth_mac.v"
SRCS="../rtl/pe_dru.v ../rtl/pe_line_codec.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v $TB"
LOG=/tmp/mutate_eth.log

cleanup() {
  git checkout -- "$RTL" 2>/dev/null
  rmdir "$ROOT/sim" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"

pass=0
fail=0
survived=0

run_tb() {
  local tag="$1"
  iverilog -g2012 -s tb_pe_eth_mac -o /tmp/mut_eth.vvp $SRCS >/tmp/mut_eth_cc.log 2>&1
  if [ $? -ne 0 ]; then
    echo "  [$tag] INCONCLUSIVE: the mutated design does not compile"
    grep -m2 "error" /tmp/mut_eth_cc.log | sed 's/^/      /'
    return 2
  fi
  timeout 300 vvp /tmp/mut_eth.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

restore() {
  git checkout -- "$RTL"
}

verify_restore() {
  if ! git diff --quiet -- "$RTL"; then
    echo "  FATAL: rtl/pe_eth_mac.v is still mutated. Refusing to continue."
    exit 3
  fi
}

mutate() {
  local name="$1" from="$2" to="$3"
  python3 - "$RTL" "$from" "$to" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
frm, to = sys.argv[2], sys.argv[3]
if frm not in t:
    print("  ANCHOR MISSING:", frm[:70]); sys.exit(4)
p.write_text(t.replace(frm, to, 1))
PYEOF
}

check_mutation() {
  local name="$1"; shift
  local from="$1"; shift
  local to="$1"; shift
  if ! mutate "$name" "$from" "$to"; then
    echo "  [$name] HARNESS ERROR: anchor not found"
    restore; fail=$((fail+1)); return
  fi
  run_tb "$name"
  local rc=$?
  if [ $rc -eq 0 ]; then
    echo "  [$name] SURVIVED (the TB did not notice -- it is vacuous here)"
    survived=$((survived+1))
  elif [ $rc -eq 1 ]; then
    echo "  [$name] detected"
    pass=$((pass+1))
  else
    fail=$((fail+1))
  fi
  restore
  verify_restore
}

echo "=== mutation-testing tb_pe_eth_mac ==="

# ---------------------------------------------------------------- baseline
run_tb "baseline"
if [ $? -ne 0 ]; then
  echo "  FATAL: the TB does not pass on the clean design; fix that first."
  exit 2
fi
echo "  [baseline] passes on the unmutated design"

# 1. The FCS convention: fold the field UN-complemented (the other self-
#    consistent reading). The residue check must then reject every good frame.
check_mutation "crc-convention" \
  "  assign crc_field_out = 1'b0;   // a receiver folds the field as ordinary data" \
  "  assign crc_field_out = 1'b1;   // MUTANT: the un-complemented convention"

# 2. The wind-back: skip it, so a type frame's four FCS bytes stay counted as
#    payload. frame_len and the next frame's start both move.
check_mutation "no-wind-back" \
  "                wptr      <= wptr - FCS_BYTES;" \
  "                wptr      <= wptr;             // MUTANT: no wind-back"

# 3. The delayed fold: fold the bit on its OWN strobe instead of one cycle
#    later, which is the bug the whole delayed-latch design exists to prevent.
check_mutation "fold-too-early" \
  "  assign crc_bit_en = ok && (state == S_HEADER || state == S_PAYLOAD ||
                             state == S_FCS);" \
  "  assign crc_bit_en = bit_en && (state == S_HEADER || state == S_PAYLOAD ||
                                state == S_FCS);  // MUTANT: no settling delay"

# 4. The byte assembly: the off-by-one form that returns the SHIFTED byte.
check_mutation "shifted-byte" \
  "  assign shreg_n = {bit_d, shreg[7:1]};" \
  "  assign shreg_n = {bit_d, shreg[6:0]};   // MUTANT: drops a bit"

# 5. The type/length split: treat every field as a length, which rejects every
#    ARP frame while passing every hand-made length test.
check_mutation "no-type-frames" \
  "  localparam logic [15:0] TYPE_MIN    = 16'h0600;   // 802.3 length/EtherType split" \
  "  localparam logic [15:0] TYPE_MIN    = 16'hFFFF;   // MUTANT: no type frames"

# 6. The bounds check: clamp instead of reject, by removing the header check.
check_mutation "no-bounds-check" \
  "                  end else if (({field[15:8], shreg_n} < TYPE_MIN) &&
                               ({field[15:8], shreg_n} > {{4{1'b0}}, room})) begin
                    state <= S_ERR;                 // will not fit
                  end else begin" \
  "                  end else begin"

# 7. The idle gate: hunt without waiting for an inter-frame gap, which lets a
#    payload 0xD5 lock the receiver into a phantom frame.
check_mutation "no-idle-gate" \
  "            if ((sr_n == SFD_BYTE) && may_hunt) begin" \
  "            if (sr_n == SFD_BYTE) begin   // MUTANT: no inter-frame gate"

# 8. The invalid-cell abort: ignore rx_err mid-frame, so a truncated frame is
#    judged on a fold that is missing its last bit.
check_mutation "no-abort-on-error" \
  "      if (ok == 1'b0 && pend == 1'b1 && rx_err == 1'b1 &&
          (state == S_HEADER || state == S_PAYLOAD || state == S_FCS)) begin" \
  "      if (1'b0) begin   // MUTANT: never abort on an invalid cell"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
if [ $survived -gt 0 ]; then
  echo "SURVIVORS: the TB does not test what it claims for the mutations above."
  exit 1
fi
if [ $fail -gt 0 ]; then
  echo "HARNESS ERRORS: fix the harness before trusting these numbers."
  exit 1
fi
echo "OK: every mutation is detected by tb_pe_eth_mac."
exit 0
