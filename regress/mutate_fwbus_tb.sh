#!/usr/bin/env bash
# mutate_fwbus_tb.sh — mutation-test the five advanced-bus protocol TBs
# together: tb_pe_soc_i2c_adv, tb_pe_soc_spi3, tb_pe_soc_uart_flow,
# tb_pe_soc_midi and tb_pe_soc_dmx512.
#
# WHY ONE HARNESS FOR FIVE TBs. Each of these testbenches has the same shape
# -- the DUT is a FIRMWARE program, the RTL underneath is the already-verified
# CPU, pin matrix, pads and tick -- so the mutations are firmware edits and
# every harness would be the same script with a different name and a different
# anchor list. The existing suite keeps one harness per TB (mutate_i2c_tb,
# mutate_spi_tb, mutate_ctrl_tb, ...) because those are separate BLOCKS with
# separate RTL. These five are one deliverable -- the advanced bus protocols --
# and splitting them would quintuple the boilerplate to say the same thing. The
# per-mutation verdicts are still printed one line each, so nothing is lost.
#
# RESTORES BOTH the .pe AND the .hex of every firmware it touches, verified by
# cmp: each TB $readmemh's the hex, so restoring only the source would leave a
# mutant image in place and report a score that means nothing. The .hex is
# RE-ASSEMBLED from the (possibly mutated) .pe before every run, so a mutation
# is never masked by a stale image -- and a mutation that fails to assemble is
# a HARNESS ERROR, reported separately from a detection, because "the mutant did
# not compile" is not evidence that the TB tests anything.
#
# Every mutation below is a defect these TBs were actually written to catch,
# and four of the ten are defects the TBs CAUGHT while the firmware was being
# written. They are named at the mutation site.
#
# WHAT IS NOT HERE, and why. A mutation of a TESTBENCH -- making the slave
# answer a constant, say -- would be checking that the TB can fail, not that it
# tests the firmware, and the existing harnesses do not do it either. The
# response check's non-vacuity rests on the fact that the expected value is
# COMPUTED from the word the slave decoded, and that the three frames carry
# three different words and three different responses: an expectation written
# for one frame fails the other two.
set -u
cd "$(dirname "$0")/.." || exit 1
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same files. Inherited from run_all.sh when this is
# one of its children, so the harness does not deadlock its own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
SRAM_MODEL=$("$ROOT/regress/sram_model.sh")
SRCS="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v $SRAM_MODEL"
# EVERY /tmp PATH IN THIS HARNESS IS WORKTREE-SCOPED, and the reason is not
# tidiness -- it is a measurement that came out wrong.
#
# regress/run_lock.sh takes a PER-WORKTREE lock on purpose ("concurrent runs in
# DIFFERENT worktrees are safe (disjoint files)"), so parallel suites in
# different worktrees are the DESIGNED case, not an accident. But the paths
# below were all bare /tmp names, and /tmp is shared across worktrees. So two
# parallel suites -- mine, and fw-timing's or the main repo's -- each ran this
# harness and each wrote /tmp/mutate_fwbus_case.log, and whichever finished last
# won. Observed directly: after a full green run of MY suite, the log I read
# reported "detected: 12" in the pre-a39caba format, and /tmp carried
# mutate_timing.log, mutate_eth.log and mutate_ctrl_r3.log, none of which are
# gates in my run_all.sh. The twelve was fw-timing's harness, not mine.
#
# That also explains an earlier reading I had dismissed as a stale file and
# then written a WORKLOG correction about: it was never stale, it was another
# worktree's, and the correction was wrong about why.
#
# The lock's claim that different worktrees are safe is therefore false for any
# shared /tmp path, which is a run_all.sh-wide issue raised as a QUESTION. The
# paths THIS harness owns are fixed here, using the same worktree digest the
# lock uses.
_wt=$(git rev-parse --show-toplevel 2>/dev/null | md5sum | cut -c1-8)
[ -n "$_wt" ] || _wt=shared
# run_all.sh captures this script's stdout in ITS own /tmp/mutate_fwbus.log,
# which is not worktree-scoped and is the manager's to change; keep every path
# this harness writes on its own so a parallel run cannot truncate them.
LOG=/tmp/mutate_fwbus_case.${_wt}.log
BAK=$(mktemp -d /tmp/fwbus_mut.${_wt}.XXXXXX)

# The five (firmware, testbench) pairs. The firmware is the DUT of each.
#
# dmx512 IS THE SLOW ONE: one DMX512-A frame is 22.6 ms of simulated time, or
# 1.37 million clocks, so each of its four mutations costs about half a minute
# of wall clock and the whole gate is minutes rather than seconds. That is the
# price of proving a protocol whose frame is a quarter of a second long, and it
# is paid knowingly rather than discovered as a mysteriously slow suite.
FWS="i2c_adv spi_mode3 uart_flow midi_xfer dmx512"

cleanup() {
  for f in $FWS; do
    cp "$BAK/$f.pe" "$ROOT/firmware/$f.pe" 2>/dev/null
    cp "$BAK/$f.hex" "$ROOT/firmware/$f.hex" 2>/dev/null
  done
  rm -rf "$BAK"
}
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

for f in $FWS; do
  cp "$ROOT/firmware/$f.pe"  "$BAK/$f.pe"
  cp "$ROOT/firmware/$f.hex" "$BAK/$f.hex"
done

pass=0; fail=0; survived=0; hangs=0

mkdir -p "$ROOT/sim"

restore() {
  for f in $FWS; do
    cp "$BAK/$f.pe" "$ROOT/firmware/$f.pe"
    cp "$BAK/$f.hex" "$ROOT/firmware/$f.hex"
  done
}
verify_restore() {
  for f in $FWS; do
    if ! cmp -s "$BAK/$f.pe" "$ROOT/firmware/$f.pe" ||
       ! cmp -s "$BAK/$f.hex" "$ROOT/firmware/$f.hex"; then
      echo "  FATAL: the $f snapshot was not restored"; exit 3
    fi
  done
}

# run_tb <firmware> <testbench>; 0 = PASS, 1 = the TB failed, 2 = harness error
run_tb() {
  local fw="$1" tb="$2"
  if ! python3 "$ROOT/tools/fw/peasm.py" "$ROOT/firmware/$fw.pe" \
        -o "$ROOT/firmware/$fw.hex" >"/tmp/mut_fwbus_asm.${_wt}.log" 2>&1; then
    return 2
  fi
  if ! (cd "$ROOT/sim" && iverilog -g2012 -s "$tb" \
        -o "/tmp/mut_fwbus_${_wt}_$tb.vvp" $SRCS "$ROOT/tb/$tb.v") \
        >"/tmp/mut_fwbus_cc.${_wt}.log" 2>&1; then
    return 2
  fi
  (cd "$ROOT/sim" && timeout 300 vvp "/tmp/mut_fwbus_${_wt}_$tb.vvp") >"$LOG" 2>&1
  run_tb_verdict "$LOG"
}

# The verdict rule, factored out of run_tb so the self-test below can
# exercise the REAL code rather than a copy of it. A copy is not a test.
#   0 = passed (survived)   1 = an assertion caught it
#   3 = caught only by a hang   2 = harness error   4 = no verdict at all
run_tb_verdict() {
  local LOG="$1" _nfail _nwatch
  _nfail=$(grep -cE "^FAIL" "$LOG")
  _nwatch=$(grep -cE "^FAIL: watchdog" "$LOG")
  if   [ "$(wc -l <"$LOG")" -eq 0 ];                          then return 4
  elif grep -qE "^PASS" "$LOG";                              then return 0
  elif [ "$_nfail" -eq 0 ];                                   then return 3
  elif [ "$_nwatch" -gt 0 ] && [ "$_nfail" -eq "$_nwatch" ];  then return 3
  else return 1
  fi
}

# ---------------------------------------------------------------------------
# THE CLASSIFIER SELF-TEST, and it runs on EVERY invocation, before any score.
#
# A classifier is an assertion, and an assertion nobody has tested is a claim.
# This is the second time in this file that a mechanism of mine produced a
# wrong number nobody could see. The first version of the verdict matched the
# "FAIL: watchdog" PREFIX alone, so it scored a BOUNDED wait that expires
# (tb_pe_soc_i2c_adv.v) exactly as it scored a genuine UNBOUNDED hang
# (tb_pe_soc_dmx512.v), and reported "1 of 21 by hang" when the truth is none.
# It was caught only by reading the wait instead of trusting the number.
#
# The rule is about what ELSE a run printed: a hang prints the watchdog line
# and nothing else; a bounded-wait diagnostic that still trips assertions
# prints it AND other FAIL lines.
#
# TWO OF THE FIVE CASES BELOW EXIST TO PROVE THE CLASSIFIER CAN STILL SAY
# "hang". A rule that classified everything as an assertion would report a
# clean "0 by hang" and look like an improvement -- which is exactly the shape
# of the bug it replaced. The cases are the real shapes observed in this
# session, not invented ones.
# ---------------------------------------------------------------------------
classifier_self_test() {
  local d rc bad=0 n w checked=0
  # THE NUMBER OF CASES EXERCISED IS ITSELF ASSERTED, and that is what makes
  # this self-test non-vacuous. A self-test whose loop iterated zero times
  # would leave bad=0, return success, and let the gate report a score from a
  # classifier it never checked -- the exact shape of the bug that produced the
  # false "1 of 21 by hang", one level up. Demonstrated rather than assumed:
  # with the loop disabled the harness ran straight through to its baselines
  # and reported nothing whatever. So `checked` counts the cases actually run,
  # is required to equal EXPECTED_CASES, and both numbers are printed.
  local EXPECTED_CASES=5
  d=$(mktemp -d /tmp/fwbus_clsfy.${_wt:-shared}.XXXXXX)
  # a GENUINE hang: the watchdog line plus diagnostic lines that are NOT FAILs
  printf '%s\n' "=== dmx ===" "FAIL: watchdog -- the test did not complete" \
    "  slots reached: 0 of 513" "  frame layer finished: 0" "  pc=64" > "$d/hang"
  # a BOUNDED wait that expires and then trips real assertions
  printf '%s\n' "=== i2c ===" "FAIL: watchdog -- the transaction did not complete" \
    "FAIL: one STOP, got 0" "FAIL: two STARTs, got 1" "FAILURES: 2" > "$d/bounded"
  # a plain assertion failure, no watchdog at all
  printf '%s\n' "=== midi ===" "FAIL: exactly 14 bytes on the wire (got 13)" \
    "FAILURES: 1" > "$d/assert"
  printf '%s\n' "=== dmx ===" "PASS: tb_pe_soc_dmx512" > "$d/pass"
  : > "$d/empty"

  for c in hang:3 bounded:1 assert:1 pass:0 empty:4; do
    n=${c%%:*}; w=${c##*:}
    checked=$((checked+1))
    # The RETURN VALUE, not stdout: run_tb_verdict RETURNS its code, and
    # capturing stdout here silently yields the empty string and fails all five
    # cases. Which is what happened the first time, and is the second instance
    # in this file of the same mistake in a different costume -- a hand-written
    # probe that ECHOED the code, then a real function that RETURNS it, and a
    # call site left in the first style.
    run_tb_verdict "$d/$n"; rc=$?
    if [ "$rc" != "$w" ]; then
      echo "  CLASSIFIER SELF-TEST FAILED: '$n' returned '$rc', expected $w"
      bad=1
    fi
  done
  if [ "$checked" -ne "$EXPECTED_CASES" ]; then
    echo "  CLASSIFIER SELF-TEST VACUOUS: exercised $checked case(s), expected $EXPECTED_CASES"
    bad=1
  fi
  rm -rf "$d"
  if [ "$bad" -ne 0 ]; then
    echo "mutate_fwbus_tb.sh: refusing to report a score from a classifier that is itself broken" >&2
    return 1
  fi
  echo "  [classifier self-test] $checked/$EXPECTED_CASES cases, verdict rule verified"
  return 0
}

if ! classifier_self_test; then
  exit 1
fi

mutate() {
  python3 - "$ROOT/firmware/$1.pe" "$2" "$3" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
if sys.argv[2] not in t: sys.exit(4)
p.write_text(t.replace(sys.argv[2], sys.argv[3], 1))
PYEOF
}

# check_mutation <name> <firmware> <testbench> <from> <to>
check_mutation() {
  local name="$1" fw="$2" tb="$3" from="$4" to="$5"
  if ! mutate "$fw" "$from" "$to"; then
    echo "  [$name] HARNESS ERROR: anchor not found in $fw.pe"
    restore; fail=$((fail+1)); return
  fi
  run_tb "$fw" "$tb"
  local rc=$?
  if   [ $rc -eq 0 ]; then
    echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then
    echo "  [$name] detected (assertion)"; pass=$((pass+1))
  elif [ $rc -eq 3 ]; then
    # Caught, but by the testbench refusing to finish rather than by a check
    # failing. Counted as caught, kept visible, and it must be justified above:
    # a hang says the image is unacceptable, not that the assertions work.
    echo "  [$name] detected (HANG/timeout only -- weaker: no assertion fired)"
    pass=$((pass+1)); hangs=$((hangs+1))
  else
    echo "  [$name] HARNESS ERROR (assemble/compile failed, or no verdict in the log; see /tmp/mut_fwbus_*.${_wt}.log)"
    fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing the five advanced-bus protocol TBs ==="
for pair in "i2c_adv tb_pe_soc_i2c_adv" "spi_mode3 tb_pe_soc_spi3" \
            "uart_flow tb_pe_soc_uart_flow" "midi_xfer tb_pe_soc_midi" \
            "dmx512 tb_pe_soc_dmx512"; do
  set -- $pair
  if run_tb "$1" "$2"; then
    echo "  [baseline] $2 passes on the unmutated firmware"
  else
    echo "  FATAL: $2 does not pass on the clean firmware"; sed -n '1,10p' "$LOG"; exit 2
  fi
done

# ---------------------------------------------------------------------------
# (1) I2C ADVANCED -- the read burst, the stretch poll, the STOP.
# ---------------------------------------------------------------------------

# The burst ACK. Releasing SCL and SDA together is the natural-looking
# "release the bus" line and it is wrong twice: the slave samples SDA on the
# rising edge and reads the release instead of the ACK, so the burst stops
# after one byte; and SDA rises under a rising clock, an illegal data move.
# CAUGHT BY THIS TB while i2c_adv.pe was written -- it presented as one
# decoded read byte, two grammar violations, and dmem[5..7] = 00 00 00.
check_mutation "i2c-ack-releases-sda" i2c_adv tb_pe_soc_i2c_adv \
  "rb_ack_rel:
        LDI   A, SCL               ; ACK: release SCL, HOLD SDA low" \
  "rb_ack_rel:
        LDI   A, SDA|SCL           ; MUTANT: releases SDA with SCL"

# The stretch poll in the send path. Without it the master times tHIGH from its
# own write instead of from the line, and the bits of a stretched cell are
# sampled while the slave still owns SCL.
check_mutation "i2c-no-stretch-poll" i2c_adv tb_pe_soc_i2c_adv \
  "sb_hi:  IN    A, PIN
        AND   A, SCL
        JNZ   sb_h1" \
  "sb_hi:  JMP   sb_h1              ; MUTANT: never looks at the SCL level"

# The STOP. Without it the bus is left captured by a master that no longer
# owns it, and the grammar monitor sees no STOP at all.
check_mutation "i2c-no-stop" i2c_adv tb_pe_soc_i2c_adv \
  "s9:     JMP   do_stop" \
  "s9:     JMP   main              ; MUTANT: no STOP, the bus is left held"

# The stretch COUNTER. If this stops being incremented the firmware still waits
# correctly, so nothing about the protocol changes -- but dmem[0] goes to zero
# and the TB's non-vacuity pair ("the firmware polled SCL while the slave held
# it") has nothing left to measure. A check that can be satisfied by removing
# the thing it measures is not a check.
check_mutation "i2c-stretch-uncounted" i2c_adv tb_pe_soc_i2c_adv \
  "sb_hi:  IN    A, PIN
        AND   A, SCL
        JNZ   sb_h1
        LDM   A, 0                 ; SCL still low: the slave is stretching
        ADD   A, 1
        STM   0, A
        JMP   sb_hi" \
  "sb_hi:  IN    A, PIN
        AND   A, SCL
        JNZ   sb_h1
        JMP   sb_hi                ; MUTANT: still waits, but never counts"

# ---------------------------------------------------------------------------
# (2) SPI MODE 3 -- the idle level, the CRC's reduction, its comparison, and
#     the XOR identity the reduction is built from.
# ---------------------------------------------------------------------------

# Mode 3's idle clock. This is the single most important line in the program:
# SCLK idles HIGH. Driving it low is mode 0's idle pattern, and because reset
# already drives the output register's bit 0 high, a program that simply
# omitted the write would be right by accident. The check that catches it is
# the one at the END of the run, since reset's value hides it at the start.
check_mutation "spi3-sclk-idles-low" spi_mode3 tb_pe_soc_spi3 \
  "        LDI   A, 5                 ; CS_N=1, MOSI=0, SCLK=1
        OUT   TXPIN, A" \
  "        LDI   A, 4                 ; MUTANT: mode 0's idle level
        OUT   TXPIN, A"

# The CRC's polynomial. Zeroing it turns the fold into a plain 8-bit shift, so
# every CRC is wrong -- and the TB catches it on BOTH sides of the wire, once
# from the slave recomputing what the firmware sent and once from the reference
# datapath in the testbench.
check_mutation "spi3-crc-no-reduction" spi_mode3 tb_pe_soc_spi3 \
  "        LDI   A, 0x07              ; home before the polynomial goes in X" \
  "        LDI   A, 0x00              ; MUTANT: the polynomial is zero"

# The XOR identity's register pressure. (V|P) - (V&P) is the XOR, and P is a
# subset of V|P, so the version that recomputes the AND from the ALREADY-OR'd
# value computes (V|P)&P -- which is P, every time. CAUGHT BY THIS TB while
# spi_mode3.pe was written: the CRC was right for a few bytes and wrong after,
# which is the worst shape a bug can have.
check_mutation "spi3-crc-xor-without-park" spi_mode3 tb_pe_soc_spi3 \
  "        STM   2, A                 ; the high term, parked: THREE REGISTERS
        MOV   A, Y                 ; ARE NOT ENOUGH WITHOUT IT" \
  "        MOV   Y, A                ; MUTANT: ANDs the ALREADY-OR'd value"

# The CRC comparison. `SUB A, 2` reads like "subtract the received CRC" and
# assembles to `A := dmem[14] - 2`, which is never zero for a real CRC, so the
# counter stays at 0 while the transaction otherwise completes perfectly.
# CAUGHT BY THIS TB while spi_mode3.pe was written.
check_mutation "spi3-crc-compare-vs-constant" spi_mode3 tb_pe_soc_spi3 \
  "        LDM   X, 2
        MOV   A, X                 ; A = the received CRC byte
        LDM   X, 14
        SUB   A, X                 ; A = received - computed" \
  "        LDM   A, 14
        SUB   A, 2                 ; MUTANT: compares against a CONSTANT"

# ---------------------------------------------------------------------------
# (3) UART RTS/CTS -- the wait, the assertion, the dispatch, the hold.
# ---------------------------------------------------------------------------

# The wait itself. CAUGHT BY THIS TB while uart_flow.pe was written, as a
# hang; the reported failures are the invariant ("TX never left idle while CTS
# was low", 7756 clocks) and the ordering ("the first start bit is at or after
# the CTS rise", start 251 us against a CTS rise at 417 us).
check_mutation "uart-cts-ignored" uart_flow tb_pe_soc_uart_flow \
  "        AND   A, CTS
        JNZ   cts_go" \
  "        AND   A, CTS
        JMP   cts_go               ; MUTANT: CTS is read and then ignored"

# RTS is not asserted at all. The bytes still go out and still decode, so
# everything about the UART is right -- the flow control is simply absent, and
# only the handshake-order checks can see it.
check_mutation "uart-rts-never-asserted" uart_flow tb_pe_soc_uart_flow \
  "        LDI   A, RTS|UTX
        OUT   TXPIN, A
        LDI   A, RTS
        STM   4, A" \
  "        LDI   A, UTX             ; MUTANT: RTS is never asserted
        OUT   TXPIN, A
        LDI   A, 0
        STM   4, A"

# RTS dropped during the DATA bits. Every byte still arrives intact and every
# bit is still correctly timed; the receiver has simply been told the line is
# free while this program is mid-byte with the wire pulled low.
#
# NOT "RTS released at the start of the stop bit", which was the first version
# of this mutation and SURVIVED. It survives because it is not a defect: the
# stop bit is HIGH, so the line looks idle for its whole duration and a
# receiver cannot distinguish "released during the stop bit" from "released
# after it". Several real drivers do release RTS there. The TB's
# `rts_low_while_tx_low` monitor is scoped to instants TX is LOW, which is
# exactly the distinction -- and the mutation it catches is the one a receiver
# with a full buffer would actually be hurt by.
check_mutation "uart-rts-dropped-mid-frame" uart_flow tb_pe_soc_uart_flow \
  "        AND   A, 1                 ; isolate the LSB
        OR    A, RTS               ; RTS stays high for the WHOLE frame: it" \
  "        AND   A, 1                 ; isolate the LSB
                                  ; MUTANT: RTS is not held across the frame"

# The payload dispatch. `LDS A, [X]` is X-indexed with NO OFFSET, so a table
# lookup at a variable index needs three compares -- and getting the second
# entry wrong sends the wrong byte with nothing else disturbed. CAUGHT BY THIS
# TB while uart_flow.pe was written.
check_mutation "uart-payload-dispatch" uart_flow tb_pe_soc_uart_flow \
  "pay1:   LDM   A, 9" \
  "pay1:   LDM   A, 10              ; MUTANT: the wrong payload slot"

# ---------------------------------------------------------------------------
# (4) MIDI 31.25 kBAUD -- the counted delay, a cell's padding, the stop bit,
#     the shift, and the running status.
# ---------------------------------------------------------------------------

# THE COUNTED-DELAY CONSTANT, and this is the mutation both BLOCK 3 acts exist
# to be able to catch, so it is the one this gate is really here for.
#
# ONE ITERATION. midi_xfer.pe's cell is 22 + 13*146 = 1920 clocks, so 145
# iterations makes it 1907: 0.68% fast. That is a rate error a forgiving
# receiver repairs by resynchronising on the next start bit, which is exactly
# why it survives review -- and it is 0.68% because the delay loop's body is 13
# clocks long. The quantisation, not a tolerance somebody chose. The TB's
# window is +/-0.3% for that reason and for no other: a window at MIDI's own
# +/-2% would admit 1907, 1920 and 1933 clocks alike, this mutation would
# SURVIVE, and the rate check would be decoration.
check_mutation "midi-cell-count-minus-one" midi_xfer tb_pe_soc_midi \
  "        LDI   A, 146             ; 22 + 13*146 = 1920 clocks, which is" \
  "        LDI   A, 145             ; MUTANT: one iteration fewer = 0.68% fast"

# A CELL'S PADDING, which the window above CANNOT see and the spread check can.
# Three NOPs in sb_start; a fourth makes the start cell 1921 clocks while the
# other nine stay at 1920. The mean barely moves, every measurement that starts
# in that cell moves by a clock, and the frame stops having one rate. One
# clock is 0.05%, so this is a mutation the rate window is blind to by a factor
# of six, and it is why the TB asserts that every cell measures the same.
#
# WHICH ASSERTION CATCHES IT, and note that "detected" does not say. This
# harness prints one verdict per mutation and cannot distinguish which check
# fired, so the attribution was established by running this mutation by hand: it
# produces EXACTLY ONE failure, "every cell is the same length (the
# measurements span 0.0146 us)", and all fourteen per-frame rate-window checks
# PASS. So the spread assertion is load-bearing here rather than decorative --
# and if it were ever removed this mutation would SURVIVE and this harness
# would report that, which is the safety net one level below the explanation.
check_mutation "midi-cell-padding-nop" midi_xfer tb_pe_soc_midi \
  "        NOP                      ; three NOPs, and their number is not a
        NOP                      ; matter of taste. See the header, \"A CELL'S
        NOP                      ;  LENGTH BELONGS TO THE PATH BETWEEN TWO" \
  "        NOP                      ; MUTANT: a fourth NOP in the start cell
        NOP                      ; three NOPs, and their number is not a
        NOP                      ; matter of taste. See the header, \"A CELL'S
        NOP                      ;  LENGTH BELONGS TO THE PATH BETWEEN TWO"

# THE STOP BIT, driven low. This is MIDI defect (3) from the firmware's own
# header reproduced as a mutation, and it is the one mutation in this harness
# whose detection depends on the RECEIVER rather than on a comparison. The
# stop cell is the last cell of a frame and the next frame's start bit supplies
# a high cell immediately after it, so a receiver that does not verify its
# stop bit sees thirteen perfectly good bytes instead of fourteen and never
# notices. Caught here on all fourteen frames.
check_mutation "midi-stop-bit-driven-low" midi_xfer tb_pe_soc_midi \
  "        LDI   A, 1
        OUT   TXPIN, A
        NOP                      ; five more, AFTER the output this time: the" \
  "        LDI   A, 0
        OUT   TXPIN, A
        NOP                      ; MUTANT: the stop bit is driven LOW"

# THE SHIFT, replaced by a NOP rather than deleted, so the cell length is
# unchanged and the mutation tests the payload alone: all eight data cells then
# drive bit 0 of a byte that never moves, and 0x90 goes out as eight zero bits.
# Deleting the instruction would also shorten every cell by a clock, and a
# mutation that trips two checks at once proves less than one that trips the
# check it was written for.
check_mutation "midi-never-shifts-the-byte" midi_xfer tb_pe_soc_midi \
  "        LDM   A, 0
        SHR   A
        STM   0, A
        JMP   sb_hold" \
  "        LDM   A, 0
        NOP                      ; MUTANT: the byte is never shifted
        STM   0, A
        JMP   sb_hold"

# RUNNING STATUS, negated: the mod-3 counter that decides where a status byte
# goes is compared against 1 instead of 3, so it is always zero and all six
# messages carry their status byte. Eighteen bytes and six status bytes on the
# wire -- still perfectly well formed, and a receiver that ignored running
# status would reconstruct the same six messages. The claim this act makes is
# the SAVING, so this is the mutation that tests the claim.
check_mutation "midi-status-byte-every-message" midi_xfer tb_pe_soc_midi \
  "        LDM   A, 2
        ADD   A, 1
        SUB   A, 3
        JZ    mod3_zero" \
  "        LDM   A, 2
        ADD   A, 1
        SUB   A, 1
        JZ    mod3_zero             ; MUTANT: a status byte on every message"

# ---------------------------------------------------------------------------
# (5) DMX512-A 250 kBAUD -- the counted delay, the break floor, the stop bit
#     and the payload ramp.
# ---------------------------------------------------------------------------

# THE COUNTED-DELAY CONSTANT again, and this time the error is larger: the cell
# is 21 + 1 + 109*2 = 240 clocks, so 108 iterations makes it 238 -- 0.83%
# slow. A DMX receiver resynchronises on every slot and would decode the frame
# anyway, and that is exactly the point: the defect both these acts exist to
# prevent is one that a receiver's resynchronisation HIDES.
check_mutation "dmx-cell-count-minus-one" dmx512 tb_pe_soc_dmx512 \
  "        LDI   A, 109             ; 21 + 1 + 109*2 = 240 clocks, pin to pin" \
  "        LDI   A, 108             ; MUTANT: one iteration fewer = 0.83% slow"

# THE BREAK, one cell short: 21 cells is 84.0 us against a floor of 87.5, so
# the result is not a slow frame, it is not a frame. The floor is why the
# firmware uses 22 whole cells and not 21.875, and this is the mutation that
# proves the break check is measuring something rather than passing.
check_mutation "dmx-break-too-short" dmx512 tb_pe_soc_dmx512 \
  "        LDI   A, 22" \
  "        LDI   A, 21              ; MUTANT: 84.0 us, under the 87.5 us floor"

# THE FIRST STOP BIT, driven low. 8N2 is an obligation and not a habit: with
# the first stop low the line is only high for the second, so a receiver that
# checks both rejects all 513 slots and the per-slot comparisons never run.
check_mutation "dmx-first-stop-driven-low" dmx512 tb_pe_soc_dmx512 \
  "        LDI   A, 1
        OUT   TXPIN, A
        NOP                      ; two NOPs, for cell 9 rather than this one:" \
  "        LDI   A, 0
        OUT   TXPIN, A
        NOP                      ; MUTANT: the first stop bit is driven LOW"

# THE PAYLOAD RAMP, stepping by two. 0, 2, 4, ... is still a perfectly good
# universe of values and the frame is still well formed; only the per-slot
# comparison knows that data slot 1 should have been 0x01. Half the slots fail
# and half pass, which is the shape a payload bug always has and the reason
# every slot is compared rather than the first and the last.
check_mutation "dmx-ramp-steps-by-two" dmx512 tb_pe_soc_dmx512 \
  "        ADD   A, 1               ; 8 bits, so this wraps at 255 by itself" \
  "        ADD   A, 2               ; MUTANT: the ramp steps by two"

echo
echo "  detected: $pass  (of which $hangs by hang/timeout only)   survived: $survived   harness errors: $fail"
if [ "$survived" -ne 0 ] || [ "$fail" -ne 0 ]; then
  echo "MUTATION TEST FAILED"
  exit 1
fi
echo "all mutations detected"
