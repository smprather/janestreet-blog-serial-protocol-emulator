#!/usr/bin/env bash
# mutate_i2c_xfer_tb.sh — mutation-test tb_pe_soc_i2c_xfer.v.
#
# The DUT of this TB is the FIRMWARE: the RTL is the already-verified CPU,
# matrix and pads. So the mutations are firmware edits — bit order, the
# repeated START, the timing constant, the STOP, the arbitration branch and the
# tHD;DAT hold — and the TB must catch every one. A survivor means the TB does
# not test what it claims.
#
# RESTORES BOTH firmware/i2c_xfer.pe AND firmware/i2c_xfer.hex, verified by
# cmp: the TB $readmemh's the hex, so restoring only the source would leave a
# mutant image in place and report a perfect score that means nothing.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
PE="$ROOT/firmware/i2c_xfer.pe"
HEX="$ROOT/firmware/i2c_xfer.hex"
TB="$ROOT/tb/tb_pe_soc_i2c_xfer.v"
SRAM_MODEL=$("$ROOT/regress/sram_model.sh")
SRCS="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_soc.v $SRAM_MODEL"
LOG=/tmp/mutate_i2c_xfer.log
BAK=$(mktemp -d /tmp/i2c_xfer_mut.XXXXXX)

cleanup() { cp "$BAK/i2c_xfer.pe" "$PE" 2>/dev/null; cp "$BAK/i2c_xfer.hex" "$HEX" 2>/dev/null; rm -rf "$BAK"; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

cp "$PE" "$BAK/i2c_xfer.pe"
cp "$HEX" "$BAK/i2c_xfer.hex"

pass=0; fail=0; survived=0

mkdir -p "$ROOT/sim"

run_tb() {
  if ! python3 "$ROOT/tools/fw/peasm.py" "$PE" -o "$HEX" >/tmp/mut_i2c_xfer_asm.log 2>&1; then
    return 2
  fi
  if ! (cd "$ROOT/sim" && iverilog -g2012 -s tb_pe_soc_i2c_xfer \
        -o /tmp/mut_i2c_xfer.vvp $SRCS "$TB") >/tmp/mut_i2c_xfer_cc.log 2>&1; then
    return 2
  fi
  (cd "$ROOT/sim" && timeout 300 vvp /tmp/mut_i2c_xfer.vvp) >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

restore() { cp "$BAK/i2c_xfer.pe" "$PE"; cp "$BAK/i2c_xfer.hex" "$HEX"; }
verify_restore() {
  if ! cmp -s "$BAK/i2c_xfer.pe" "$PE" || ! cmp -s "$BAK/i2c_xfer.hex" "$HEX"; then
    echo "  FATAL: the firmware snapshot was not restored"; exit 3
  fi
}

mutate() {
  python3 - "$PE" "$1" "$2" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
if sys.argv[2] not in t: sys.exit(4)
p.write_text(t.replace(sys.argv[2], sys.argv[3], 1))
PYEOF
}

check_mutation() {
  local name="$1"; shift
  if ! mutate "$1" "$2"; then
    echo "  [$name] HARNESS ERROR: anchor not found"; restore; fail=$((fail+1)); return
  fi
  run_tb
  local rc=$?
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected"; pass=$((pass+1))
  else                     fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing tb_pe_soc_i2c_xfer ==="
run_tb
if [ $? -ne 0 ]; then echo "  FATAL: the TB does not pass on the clean firmware"; exit 2; fi
echo "  [baseline] passes on the unmutated firmware"

# 1. The send shift: without it every bit is the same MSB, so 0xA0 goes out as
#    0xFF and the slave never matches its address.
check_mutation "no-shift" \
  "        LDM   A, 8                 ; shift the byte left: A = 2A via X
        MOV   X, A
        ADD   A, X" \
  "        LDM   A, 8
        MOV   X, A
        ADD   A, 0   ; MUTANT: the byte never shifts"

# 2. The repeated START: skip it and the read address follows the write byte
#    with no START, which the wire grammar and the START count see.
check_mutation "no-repeated-start" \
  "s3:     LDI   A, 4
        STM   10, A
        JMP   do_start" \
  "s3:     LDI   A, 4
        STM   10, A
        JMP   main   ; MUTANT: no repeated START"

# 3. The tLOW constant, in the repeated-START wait: one tick instead of seven
#    puts the ACK clock's low phase under the 4.7 us floor.
check_mutation "short-tlow" \
  "        IN    A, I2CTICK
        ADD   A, T_LOW
        MOV   X, A
w_ds:   IN    A, I2CTICK" \
  "        IN    A, I2CTICK
        ADD   A, 1
        MOV   X, A
w_ds:   IN    A, I2CTICK   ; MUTANT: tLOW collapsed"

# 4. The STOP: releasing SDA while SCL is high is the STOP edge. Without it
#    the bus never signals the end of the transaction.
check_mutation "no-stop" \
  "        LDI   A, SDA|SCL           ; release SDA with SCL high: the STOP
        OUT   TXPIN, A" \
  "        LDI   A, SCL               ; MUTANT: no STOP edge
        OUT   TXPIN, A"

# 5. The arbitration check: skipping it leaves the loss count at 0 in the
#    contention run, so dead code would pass the first run alone.
check_mutation "no-arbitration" \
  "        LDM   A, 12
        JZ    sb_noarb
        IN    A, PIN
        AND   A, SDA
        JNZ   sb_noarb" \
  "        LDM   A, 12
        JZ    sb_noarb
        JMP   sb_noarb   ; MUTANT: arbitration never sampled"

# 6. The tHD;DAT hold: releasing SDA together with SCL on a transmitted 0 is
#    the exact bug the emulator check caught -- SDA moves under a rising clock.
check_mutation "no-hold-zero" \
  "sb_rel0:
        LDI   A, SCL               ; bit 0: SDA stays driven low" \
  "sb_rel0:
        LDI   A, SDA|SCL           ; MUTANT: SDA released with SCL"

# 7. The read accumulator shift: without it the eight sampled bits all land in
#    one position and the read byte is wrong.
check_mutation "read-no-shift" \
  "        LDM   A, 11
        MOV   X, A
        ADD   A, X                 ; acc <<= 1
        STM   11, A" \
  "        LDM   A, 11
        MOV   X, A
        ADD   A, 0                 ; MUTANT: accumulator never shifts
        STM   11, A"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
[ $survived -gt 0 ] && { echo "SURVIVORS: the TB does not test what it claims."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every mutation is detected by tb_pe_soc_i2c_xfer."
exit 0
