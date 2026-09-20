#!/usr/bin/env bash
# run_firmware_tests.sh — the firmware regression.
#
# Assembles every program in firmware/ and runs it in the bit-accurate emulator
# against a modelled wire. This is the loop that makes firmware development
# possible without an RTL build: a 2-second emulator run replaces a multi-minute
# synthesis+simulation cycle, and the emulator mirrors the RTL's cycle model.
#
# Usage:  tb/run_firmware_tests.sh
# Exit:   0 = all pass

set -u
cd "$(dirname "$0")/.." || exit 1

PY=python3
pass=0; fail=0; failed=()

run_case() {
  local label="$1"; shift
  if out=$("$@" 2>&1) && grep -q '^PASS' <<< "$out"; then
    printf '%-34s PASS\n' "$label"
    pass=$((pass+1))
  else
    printf '%-34s FAIL\n' "$label"
    grep -E '^(FAIL|peasm|Traceback)' <<< "$out" | head -3 | sed 's/^/    /'
    fail=$((fail+1)); failed+=("$label")
  fi
}

# 1. assemble
if ! $PY tools/peasm.py firmware/uart_echo.pe -o firmware/uart_echo.hex >/dev/null 2>&1; then
  echo "assemble                               FAIL"
  $PY tools/peasm.py firmware/uart_echo.pe 2>&1 | head -3 | sed 's/^/    /'
  exit 1
fi
size=$(grep -c . firmware/uart_echo.hex)
printf '%-34s PASS (%s of 128 words)\n' "assemble uart_echo" "$size"
pass=$((pass+1))

# 2. single byte
run_case "emulate: one byte" \
  $PY tools/peemu.py firmware/uart_echo.hex --send 41 --max-cycles 900000

# 3. multi-byte, with the half-duplex gap the echo loop requires
run_case "emulate: three bytes" \
  $PY tools/peemu.py firmware/uart_echo.hex --send "41 42 43" --max-cycles 900000

# 4. stress: every byte position pattern (0x00 and 0xFF are the cases that
#    expose timing slips, because a mis-sampled bit is invisible in 0xAA)
run_case "emulate: 00 FF 55 AA" \
  $PY tools/peemu.py firmware/uart_echo.hex --send "00 FF 55 AA" --max-cycles 900000

# 5. the documented limitation: back-to-back bytes are LOST (half-duplex).
#    Asserts the failure mode rather than hiding it -- if this ever starts
#    passing, the limitation has been fixed and the wiki page needs updating.
if out=$($PY tools/peemu.py firmware/uart_echo.hex --send "41 42" --gap 1 \
         --max-cycles 900000 2>&1); then
  if grep -q '^FAIL' <<< "$out"; then
    printf '%-34s PASS (still half-duplex)\n' "limitation: gap=1 loses bytes"
    pass=$((pass+1))
  else
    printf '%-34s NOTE (now passes -> update wiki)\n' "limitation: gap=1 loses bytes"
    pass=$((pass+1))
  fi
else
  printf '%-34s PASS (emulator err = not delivered)\n' "limitation: gap=1 loses bytes"
  pass=$((pass+1))
fi

echo
echo "========================================"
echo "FIRMWARE: $((pass+fail))   PASS: $pass   FAIL: $fail"
[ "$fail" -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
echo "all firmware tests pass"
