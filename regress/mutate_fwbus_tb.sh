#!/usr/bin/env bash
# mutate_fwbus_tb.sh — mutation-test the three advanced-bus protocol TBs
# together: tb_pe_soc_i2c_adv, tb_pe_soc_spi3 and tb_pe_soc_uart_flow.
#
# WHY ONE HARNESS FOR THREE TBs. Each of these testbenches has the same shape
# -- the DUT is a FIRMWARE program, the RTL underneath is the already-verified
# CPU, pin matrix, pads and tick -- so the mutations are firmware edits and
# every harness would be the same script with a different name and a different
# anchor list. The existing suite keeps one harness per TB (mutate_i2c_tb,
# mutate_spi_tb, mutate_ctrl_tb, ...) because those are separate BLOCKS with
# separate RTL. These three are one deliverable -- the advanced bus protocols --
# and splitting them would triple the boilerplate to say the same thing. The
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
# run_all.sh captures this script's stdout in /tmp/mutate_fwbus.log; keep each
# simulator run on a different path so it cannot truncate the outer log.
LOG=/tmp/mutate_fwbus_case.log
BAK=$(mktemp -d /tmp/fwbus_mut.XXXXXX)

# The three (firmware, testbench) pairs. The firmware is the DUT of each.
FWS="i2c_adv spi_mode3 uart_flow"

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

pass=0; fail=0; survived=0

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
        -o "$ROOT/firmware/$fw.hex" >/tmp/mut_fwbus_asm.log 2>&1; then
    return 2
  fi
  if ! (cd "$ROOT/sim" && iverilog -g2012 -s "$tb" \
        -o "/tmp/mut_fwbus_$tb.vvp" $SRCS "$ROOT/tb/$tb.v") \
        >/tmp/mut_fwbus_cc.log 2>&1; then
    return 2
  fi
  (cd "$ROOT/sim" && timeout 300 vvp "/tmp/mut_fwbus_$tb.vvp") >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

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
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected"; pass=$((pass+1))
  else
    echo "  [$name] HARNESS ERROR (assemble or compile failed; see /tmp/mut_fwbus_*.log)"
    fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing the three advanced-bus protocol TBs ==="
for pair in "i2c_adv tb_pe_soc_i2c_adv" "spi_mode3 tb_pe_soc_spi3" \
            "uart_flow tb_pe_soc_uart_flow"; do
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

echo
echo "  detected: $pass   survived: $survived   harness errors: $fail"
if [ "$survived" -ne 0 ] || [ "$fail" -ne 0 ]; then
  echo "MUTATION TEST FAILED"
  exit 1
fi
echo "all mutations detected"
