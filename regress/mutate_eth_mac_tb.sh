#!/usr/bin/env bash
# Mutation-test tb_pe_eth_mac.v: every check it makes must be able to FAIL.
#
# The TB passed on its first clean run, which by itself proves only that it
# agrees with the RTL. This harness breaks the RTL in thirty ways that each
# target one claim the TB makes, and requires the TB to notice every one.
#
# The mutations are chosen to be SUBTLE, not obvious: each is a plausible
# implementation choice somebody could genuinely write, so detecting it means
# the TB is testing the property and not the spelling.
# RESTORE IS A FILE COPY, NOT `git checkout`. The first version of this harness
# used git and DESTROYED the RTL: rtl/pe_eth_mac.v was untracked, so checkout
# failed with "did not match any file(s) known to git", every mutation stacked
# on the last, and the harness reported "8 detected, 0 survived" -- a result
# that looks like success and means nothing. A harness that cannot restore the
# file it mutates cannot report anything.
set -u
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
RTL="$ROOT/rtl/pe_eth_mac.v"
# MUTABLE — what this harness EDITS inside the repo. Read by
# regress/verify_merge.sh (the merge gate) to decide whether a narrowed gate
# has to run this suite, and by regress/check_mutation_lists.sh to prove the
# list still covers every file the harness writes. Evidence: RTL=.
# An EMPTY value means this suite mutates nothing in the repo and is therefore
# NEVER SKIPPED. A MISSING line is the opposite: unmappable, and the gate
# escalates to running every suite rather than guessing.
MUTABLE="rtl/pe_eth_mac.v"
TB="$ROOT/tb/tb_pe_eth_mac.v"
SRCS="../rtl/pe_dru.v ../rtl/pe_nrzi.v ../rtl/pe_manch.v ../rtl/pe_bitstuff.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v $TB"
LOG=/tmp/mutate_eth.log
BAK=$(mktemp /tmp/pe_eth_mac.XXXXXX.v)

cleanup() {
  # THE HARNESS-EDIT PRE-FLIGHT (regress/dep_guard.sh). Stamped when this
  # harness took the run lock; verified HERE, because this is the only place it
  # can be: the harness sets its own `trap cleanup EXIT` after sourcing
  # run_lock.sh, and a second EXIT trap replaces the first, so a check installed
  # over there would be silently discarded. If this script — or the lock helper it
  # sources — changed while we were running, bash's incremental read means our
  # verdict is untrustworthy in EITHER direction, so exit 4 (INCONCLUSIVE) rather
  # than report a possibly-false pass.
  chip_dep_check "run_$(basename "$0")" || exit 4
  cp "$BAK" "$RTL" 2>/dev/null
  rm -f "$BAK"
  rmdir "$ROOT/sim" 2>/dev/null
}
on_signal() {
  cleanup
  trap - EXIT INT TERM
  exit 143
}
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"

# The pristine copy every restore comes from, verified against the file on
# disk so a corrupt starting state cannot slip through as a pass.
cp "$RTL" "$BAK"
if ! cmp -s "$RTL" "$BAK"; then
  echo "FATAL: could not snapshot $RTL"
  exit 2
fi

pass=0
fail=0
survived=0

# A mutation is "detected" only when the TB PRINTS a failure. A timeout, a
# compile error, a simulator crash or unparseable output is a HARNESS error,
# not a detection: without this, a mutation that hangs a directed wait (for
# example one that never reaches the state the wait polls) is silently counted
# as detected. `timeout` returns 124 on expiry.
run_tb() {
  iverilog -g2012 -s tb_pe_eth_mac -o /tmp/mut_eth.vvp $SRCS >/tmp/mut_eth_cc.log 2>&1
  if [ $? -ne 0 ]; then
    return 2
  fi
  timeout 300 vvp /tmp/mut_eth.vvp >"$LOG" 2>&1
  local rc=$?
  if [ $rc -eq 124 ]; then
    echo "    (timeout after 300 s -- harness error, not a detected mutation)"
    return 2
  fi
  if [ $rc -ne 0 ]; then
    echo "    (vvp exited $rc -- harness error)"
    return 2
  fi
  if grep -qE "^PASS" "$LOG"; then
    return 0
  fi
  if grep -qE "^(FAIL|FAILURES:)" "$LOG"; then
    return 1
  fi
  echo "    (no PASS or FAIL line in the output -- harness error)"
  return 2
}

restore() {
  cp "$BAK" "$RTL"
}

# Prove the restore worked, every single time. Without this a stacked-mutation
# run reports a perfect score.
verify_restore() {
  if ! cmp -s "$BAK" "$RTL"; then
    echo "  FATAL: $RTL does not match the snapshot after restore."
    exit 3
  fi
}

mutate() {
  local from="$1" to="$2"
  python3 - "$RTL" "$from" "$to" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
frm, to = sys.argv[2], sys.argv[3]
if frm not in t:
    sys.exit(4)
p.write_text(t.replace(frm, to, 1))
PYEOF
}

check_mutation() {
  local name="$1"; shift
  local from="$1"; shift
  local to="$1"; shift
  if ! mutate "$from" "$to"; then
    echo "  [$name] HARNESS ERROR: anchor not found"
    restore; fail=$((fail+1)); return
  fi
  run_tb
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
  "                wptr      <= wptr - AW'(FCS_BYTES);" \
  "                wptr      <= wptr;             // MUTANT: no wind-back"

# 3. The delayed fold: fold the bit on its OWN strobe instead of one cycle
#    later, which is the bug the whole delayed-latch design exists to prevent.
check_mutation "fold-too-early" \
  "  assign crc_bit_en = ok && (state == S_HEADER || state == S_PAYLOAD ||
                             state == S_PAD || state == S_FCS);" \
  "  assign crc_bit_en = bit_en && (state == S_HEADER || state == S_PAYLOAD ||
                                state == S_PAD || state == S_FCS);  // MUTANT: no settling delay"

# 4. The byte assembly: the off-by-one form that returns the SHIFTED byte.
#    `shreg` is 7 bits and `{bit_d, shreg}` is the full 8-bit window; the
#    mutant keeps 8 bits but drops the OLDEST one and injects a zero in its
#    place, so the assembled byte walks.
check_mutation "shifted-byte" \
  "  assign shreg_n = {bit_d, shreg};" \
  "  assign shreg_n = {bit_d, shreg[6:1], 1'b0};   // MUTANT: drops a bit"

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
          (state == S_HEADER || state == S_PAYLOAD || state == S_PAD ||
           state == S_FCS)) begin" \
  "      if (1'b0) begin   // MUTANT: never abort on an invalid cell"

# 9. The pad: jump straight from the declared length to the FCS, which rejects
#    every correctly padded short length frame. This is the finding the TB's
#    frame 8 exists for.
check_mutation "no-pad" \
  "                  if (field < MIN_PAY) begin
                    state   <= S_PAD;
                    pad_cnt <= '0;
                  end else begin
                    state   <= S_FCS;
                    fcs_cnt <= '0;
                  end" \
  "                  state   <= S_FCS;
                  fcs_cnt <= '0;   // MUTANT: no pad state"

# 10. The reclaim: truncate pay_cnt to AW bits. A frame that fills all 2,048
#     bytes leaves pay_cnt = 2048 = 11'h000, so the reclaim adds nothing and
#     `room` stays 0 forever. This is the finding the TB's frame 9 exists for.
check_mutation "truncated-reclaim" \
  "          room      <= room + consume_credit + pay_cnt[AW:0];" \
  "          room      <= room + consume_credit + {1'b0, pay_cnt[AW-1:0]};  // MUTANT: truncated reclaim"

# 11. The structural verdict: accept on the CRC residue alone again. Frame 10
#     is a valid-residue 14-byte runt, so this mutant accepts it and winds the
#     pointer back 4 bytes that were never stored.
check_mutation "crc-only-verdict" \
  "            if ((crc_state == CRC_RESIDUE) && hdr_done && (bit_cnt == 3'd0) &&
                (is_type ? (pay_cnt >= MIN_TYPE_PAY) : fcs_done)) begin" \
  "            if (crc_state == CRC_RESIDUE) begin   // MUTANT: CRC alone"

# 12. The 64-byte minimum for a type frame: drop it and the 18-byte and
#     63-byte valid-residue runts are accepted (boundary cases (a) and (b)).
check_mutation "no-type-min-size" \
  "                (is_type ? (pay_cnt >= MIN_TYPE_PAY) : fcs_done)) begin" \
  "                (is_type ? 1'b1 : fcs_done)) begin   // MUTANT: no min size"

# 13. Byte alignment: drop it and a frame ending 1-7 bits into a byte is
#     accepted (boundary cases (c)/(d)).
check_mutation "no-byte-align" \
  "            if ((crc_state == CRC_RESIDUE) && hdr_done && (bit_cnt == 3'd0) &&" \
  "            if ((crc_state == CRC_RESIDUE) && hdr_done &&   // MUTANT: no byte alignment"

# 14. Consume rebases the write pointer: the E1 bug. The block TB partially
#     releases a prior published frame while frame 2 is mid-payload, with
#     rptr and wptr at distinct addresses; a rebase corrupts the write side.
check_mutation "consume-rebases-wptr" \
  "          rptr <= buf_consume_addr;" \
  "          rptr <= buf_consume_addr;
          wptr <= buf_consume_addr;   // MUTANT: rebases the write pointer"

# 15. Consume is ignored: room never comes back and rptr never moves.
check_mutation "consume-ignored" \
  "      if (buf_consume && !buf_reset) begin" \
  "      if (1'b0) begin   // MUTANT: consume ignored"

# 16. No forward-distance guard: a backward consume over-credits room and
#     hands back memory that still holds an unconsumed frame.
check_mutation "consume-no-guard" \
  "&&
                           (freed <= used) && (freed <= published_used)" \
  "&&
                           1'b1"

# 17. The wrap distance measured modulo 2*BUF_BYTES again (the E1-1 bug): an
#     AW+1-bit subtraction rejects every wrapped release and leaks it. The new
#     wrapped-release case must catch this as a printed rptr/room failure.
check_mutation "consume-wrap-aw1" \
  "  assign freed = {1'b0, (buf_consume_addr - rptr)};" \
  "  assign freed = {1'b0, buf_consume_addr} - {1'b0, rptr};   // MUTANT: AW+1 subtraction"

# 18. The E1-2 bug: a payload byte forgets the consumer's credit, so a
#     coincident consume loses its freed bytes (room ends at room-1 instead of
#     room+freed-1). The simultaneous-event case must catch it.
check_mutation "no-consume-credit-payload" \
  "                room    <= room + consume_credit - 1'b1;" \
  "                room    <= room - 1'b1;   // MUTANT: drops the consume credit"

# 19. A valid type-frame verdict winds back four FCS bytes in the same room
#    assignment. It must preserve a simultaneous release as well as reclaiming
#    those four bytes.
check_mutation "no-consume-credit-type-settle" \
  "                room      <= room + consume_credit
                             + {{(AW-2){1'b0}}, FCS_BYTES};" \
  "                room      <= room
                             + {{(AW-2){1'b0}}, FCS_BYTES};  // MUTANT: drops consume credit"

# 20. A bad-CRC verdict rolls back all bytes allocated by the frame. A release
#    on that verdict edge must survive the rollback assignment.
check_mutation "no-consume-credit-bad-settle" \
  "              room  <= room + consume_credit + pay_cnt[AW:0];
            end
            state <= S_SEARCH;" \
  "              room  <= room + pay_cnt[AW:0];
            end
            state <= S_SEARCH;   // MUTANT: drops consume credit"

# 21. A type overflow enters S_ERR after partially allocating the frame. A simultaneous
#    consume must be added to the same room update.
check_mutation "no-consume-credit-error" \
  "          room      <= room + consume_credit + pay_cnt[AW:0];
          state     <= S_SEARCH;" \
  "          room      <= room + pay_cnt[AW:0];
          state     <= S_SEARCH;   // MUTANT: drops consume credit"

# 22. A bad type frame can fill the ring before its CRC verdict. The settle
#    rollback must keep the full-width pay_cnt bit that represents 2,048 bytes.
check_mutation "truncated-reclaim-bad-settle" \
  "              room  <= room + consume_credit + pay_cnt[AW:0];" \
  "              room  <= room + consume_credit + {1'b0, pay_cnt[AW-1:0]};  // MUTANT: truncated bad-settle reclaim"

# 23. Allocated bytes are not necessarily published: the current frame's
#     bad-frame reclaim or TYPE FCS windback will credit them later. The new
#     in-flight over-read tests must reject a consume based on `used` alone.
check_mutation "consume-unpublished-bytes" \
  "&& (freed <= published_used)" \
  "&& (freed <= used) /* MUTANT: no published-byte bound */"

# 24. A successful TYPE frame publishes pay_cnt minus its four stored FCS
#     bytes. The post-commit release test must catch a missing publication.
check_mutation "type-publication-omitted" \
  "                published_used <= published_used + pay_cnt[AW:0]
                                   - {{(AW-2){1'b0}}, FCS_BYTES}
                                   - consume_credit;" \
  "                published_used <= published_used - consume_credit;  // MUTANT: drops TYPE bytes"

# 25. A successful length frame publishes the declared payload; its FCS and
#     any pad bytes are not in the ring. Existing in-flight collision cases
#     release this committed length-frame storage.
check_mutation "length-publication-omitted" \
  "                published_used <= published_used + pay_cnt[AW:0]
                                   - consume_credit;" \
  "                published_used <= published_used - consume_credit;  // MUTANT: drops length bytes"

# 26. TYPE publication excludes the four transient FCS bytes that are wound
#     back from the producer pointer and room count.
check_mutation "type-fcs-published" \
  "                published_used <= published_used + pay_cnt[AW:0]
                                   - {{(AW-2){1'b0}}, FCS_BYTES}
                                   - consume_credit;" \
  "                published_used <= published_used + pay_cnt[AW:0]
                                   - consume_credit;  // MUTANT: publishes TYPE FCS"

# 27. A consume coincident with TYPE publication must be subtracted once from
#     the old committed count plus the newly published TYPE data.
check_mutation "type-credit-dropped-from-publication" \
  "                published_used <= published_used + pay_cnt[AW:0]
                                   - {{(AW-2){1'b0}}, FCS_BYTES}
                                   - consume_credit;" \
  "                published_used <= published_used + pay_cnt[AW:0]
                                   - {{(AW-2){1'b0}}, FCS_BYTES};  // MUTANT: drops consume"

# 28. A consume coincident with length-frame publication must likewise be
#     subtracted from the next committed-byte count.
check_mutation "length-credit-dropped-from-publication" \
  "                published_used <= published_used + pay_cnt[AW:0]
                                   - consume_credit;" \
  "                published_used <= published_used + pay_cnt[AW:0];  // MUTANT: drops consume"

# 29. A bad frame rolls back only its own unpublished allocation; it must not
#     discard the publication count of an older frame still owned by firmware.
check_mutation "bad-settle-clears-published" \
  "              room  <= room + consume_credit + pay_cnt[AW:0];" \
  "              published_used <= '0;  // MUTANT: loses older committed bytes
              room  <= room + consume_credit + pay_cnt[AW:0];"

# 30. S_ERR has the same ownership rule as bad-FCS settlement: reclaim the
#     failing frame, preserving any older committed bytes not yet consumed.
check_mutation "s-err-clears-published" \
  "          room      <= room + consume_credit + pay_cnt[AW:0];" \
  "          published_used <= '0;  // MUTANT: loses older committed bytes
          room      <= room + consume_credit + pay_cnt[AW:0];"

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
