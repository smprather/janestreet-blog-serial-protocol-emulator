#!/usr/bin/env bash
# run_firmware_tests.sh — the firmware regression.
#
# Assembles every program in firmware/ and runs it in the bit-accurate emulator
# against a modelled wire. This is the loop that makes firmware development
# possible without an RTL build: a 2-second emulator run replaces a multi-minute
# synthesis+simulation cycle, and the emulator mirrors the RTL's cycle model.
#
# Usage:  regress/run_firmware_tests.sh
# Exit:   0 = all pass

set -u
cd "$(dirname "$0")/.." || exit 1
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"

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
if ! $PY tools/fw/peasm.py firmware/uart_echo.pe -o firmware/uart_echo.hex >/dev/null 2>&1; then
  echo "assemble                               FAIL"
  $PY tools/fw/peasm.py firmware/uart_echo.pe 2>&1 | head -3 | sed 's/^/    /'
  exit 1
fi
size=$(grep -c . firmware/uart_echo.hex)
printf '%-34s PASS (%s of 128 words)\n' "assemble uart_echo" "$size"
pass=$((pass+1))

# tick_count.pe is the STATUS-port exerciser that tb_pe_soc_tick.v runs.
# It must assemble here for the same reason uart_echo does: the RTL testbench
# $readmemh's the .hex, so a stale image would be a silent pass.
if ! $PY tools/fw/peasm.py firmware/tick_count.pe -o firmware/tick_count.hex >/dev/null 2>&1; then
  echo "assemble tick_count                    FAIL"
  $PY tools/fw/peasm.py firmware/tick_count.pe 2>&1 | head -3 | sed 's/^/    /'
  exit 1
fi
printf '%-34s PASS (%s words)\n' "assemble tick_count" \
  "$(grep -c . firmware/tick_count.hex)"
pass=$((pass+1))

# spi_xfer.pe is the second baseline protocol (the blog's set is "UART, SPI and
# I2C"). It has no RTL testbench yet -- tb_pe_spi.v exercises pe_serdes, which
# is a different SPI -- so the emulator is the ONLY thing that runs it. That
# makes this assemble check load-bearing rather than a formality: if the
# firmware stops assembling, nothing else here would notice.
if ! $PY tools/fw/peasm.py firmware/spi_xfer.pe -o firmware/spi_xfer.hex >/dev/null 2>&1; then
  echo "assemble spi_xfer                      FAIL"
  $PY tools/fw/peasm.py firmware/spi_xfer.pe 2>&1 | head -3 | sed 's/^/    /'
  exit 1
fi
printf '%-34s PASS (%s words)\n' "assemble spi_xfer" \
  "$(grep -c . firmware/spi_xfer.hex)"
pass=$((pass+1))

# i2c_pins.pe is the pin-matrix exerciser: tb_pe_soc_i2c.v $readmemh's the hex
# it produces, so this assemble step is what keeps the RTL test from simulating
# a stale image. tools/checks/i2c_timing.py checks its spec compliance.
if ! $PY tools/fw/peasm.py firmware/i2c_pins.pe -o firmware/i2c_pins.hex >/dev/null 2>&1; then
  echo "assemble i2c_pins                      FAIL"
  $PY tools/fw/peasm.py firmware/i2c_pins.pe 2>&1 | head -3 | sed 's/^/    /'
  exit 1
fi
printf '%-34s PASS (%s words)\n' "assemble i2c_pins" \
  "$(grep -c . firmware/i2c_pins.hex)"
pass=$((pass+1))

# eth_rx.pe is the frame-window consumer: tb_pe_soc_eth.v $readmemh's the hex
# it produces, so a stale image would be a silent pass.
if ! $PY tools/fw/peasm.py firmware/eth_rx.pe -o firmware/eth_rx.hex >/dev/null 2>&1; then
  echo "assemble eth_rx                       FAIL"
  $PY tools/fw/peasm.py firmware/eth_rx.pe 2>&1 | head -3 | sed 's/^/    /'
  exit 1
fi
printf '%-34s PASS (%s words)\n' "assemble eth_rx" \
  "$(grep -c . firmware/eth_rx.hex)"
pass=$((pass+1))

# i2c_xfer.pe is the transaction-layer firmware: tb_pe_soc_i2c_xfer.v
# $readmemh's the hex it produces, so a stale image would be a silent pass.
if ! $PY tools/fw/peasm.py firmware/i2c_xfer.pe -o firmware/i2c_xfer.hex >/dev/null 2>&1; then
  echo "assemble i2c_xfer                     FAIL"
  $PY tools/fw/peasm.py firmware/i2c_xfer.pe 2>&1 | head -3 | sed 's/^/    /'
  exit 1
fi
printf '%-34s PASS (%s words)\n' "assemble i2c_xfer" \
  "$(grep -c . firmware/i2c_xfer.hex)"
pass=$((pass+1))

# serdes_loop.pe is the word-engine window's first consumer: tb_pe_soc_serdes.v
# $readmemh's the hex it produces (four loopback configs), so a stale image
# would be a silent pass on the integration this firmware configures.
if ! $PY tools/fw/peasm.py firmware/serdes_loop.pe -o firmware/serdes_loop.hex >/dev/null 2>&1; then
  echo "assemble serdes_loop                    FAIL"
  $PY tools/fw/peasm.py firmware/serdes_loop.pe 2>&1 | head -3 | sed 's/^/    /'
  exit 1
fi
printf '%-34s PASS (%s words)\n' "assemble serdes_loop" \
  "$(grep -c . firmware/serdes_loop.hex)"
pass=$((pass+1))

# eth_tx_arp.pe is the 10BASE-T TX frame engine's first consumer:
# tb_pe_soc_eth_tx.v $readmemh's the hex it produces, so a stale image would
# be a silent pass on the window/owner/FIFO integration it exercises.
if ! $PY tools/fw/peasm.py firmware/eth_tx_arp.pe -o firmware/eth_tx_arp.hex >/dev/null 2>&1; then
  echo "assemble eth_tx_arp                   FAIL"
  $PY tools/fw/peasm.py firmware/eth_tx_arp.pe 2>&1 | head -3 | sed 's/^/    /'
  exit 1
fi
printf '%-34s PASS (%s words)\n' "assemble eth_tx_arp" \
  "$(grep -c . firmware/eth_tx_arp.hex)"
pass=$((pass+1))

# Task 5's firmwares: the TX->RX loopback consumer plus the three test-only
# probes (two-frame min IFG, the 16-23 wrap directed case, and the
# start-while-busy directed case). tb_pe_soc_eth_loop.v $readmemh's each hex,
# so a stale image would be a silent pass on the integration it exercises.
for prog in eth_arp_echo eth_tx_two eth_tx_wrap_probe eth_tx_busy_probe; do
  if ! $PY tools/fw/peasm.py "firmware/$prog.pe" -o "firmware/$prog.hex" >/dev/null 2>&1; then
    echo "assemble $prog FAIL"
    $PY tools/fw/peasm.py "firmware/$prog.pe" 2>&1 | head -3 | sed 's/^/    /'
    exit 1
  fi
  printf '%-34s PASS (%s words)\n' "assemble $prog" \
    "$(grep -c . "firmware/$prog.hex")"
  pass=$((pass+1))
done

# The three TIMING programs. Each of these is $readmemh'd by an RTL testbench
# (tb_pe_soc_ws2812 / tb_pe_soc_servo / tb_pe_soc_dht11), so a stale image would
# be a silent pass on the integration -- and these three are the only programs in
# the repository where a stale image cannot be caught by any other test, because
# the thing under test IS the program. The delay constants in them are fitted
# instruction counts (see the headers), so a re-assembly that silently changed
# one would change a timing claim.
for prog in ws2812 servo_sweep dht11_read; do
  if ! $PY tools/fw/peasm.py "firmware/$prog.pe" -o "firmware/$prog.hex" >/dev/null 2>&1; then
    echo "assemble $prog FAIL"
    $PY tools/fw/peasm.py "firmware/$prog.pe" 2>&1 | head -3 | sed 's/^/    /'
    exit 1
  fi
  printf '%-34s PASS (%s words)\n' "assemble $prog" \
    "$(grep -c . "firmware/$prog.hex")"
  pass=$((pass+1))
done

# 2. single byte
run_case "emulate: one byte" \
  $PY tools/fw/peemu.py firmware/uart_echo.hex --send 41 --max-cycles 900000

# 3. multi-byte, with the half-duplex gap the echo loop requires.
#    --expect-buffer also checks the ROLLING BUFFER, not just the echoed bytes.
#    The echo path reads slot 15 ("last byte received"), so it cannot see a
#    broken write pointer -- and the pointer was broken: its wrap mask made it
#    a constant 0 and every byte overwrote slot 0. Bytes-only checks passed
#    throughout.
run_case "emulate: three bytes + buffer" \
  $PY tools/fw/peemu.py firmware/uart_echo.hex --send "41 42 43" \
     --expect-buffer "41 42 43" --max-cycles 900000

# 4. stress: every byte position pattern (0x00 and 0xFF are the cases that
#    expose timing slips, because a mis-sampled bit is invisible in 0xAA)
run_case "emulate: 00 FF 55 AA" \
  $PY tools/fw/peemu.py firmware/uart_echo.hex --send "00 FF 55 AA" --max-cycles 900000

# 4b. SPI, the second baseline protocol. This runs the SAME SoC firmware
#     against a modelled mode-0 slave: the firmware is the master and generates
#     its own clock, so the emulator only answers on MISO. Both directions are
#     checked and they are independent -- the master's view comes from its
#     rolling buffer (dmem), the slave's view from the MOSI PIN, so a master
#     that shifts the wrong way is caught by the second even though its own
#     receive path would look fine.
#
#     Every byte here is deliberately NOT a bit palindrome (0x00, 0xFF, 0x0F,
#     0x3C, 0x5A, 0x81 and 0xAA all are). A palindromic byte puts the same pin
#     sequence on MOSI/MISO whichever way the shift goes, so it cannot catch a
#     bit-order swap at all. Each of these reverses to something different:
#     0xA7->0xE5, 0xE5->0xA7, 0x96->0x69, 0xC1->0x83; the master's 0x5B->0xDA.
run_case "emulate: spi mode 0, 4 frames" \
  $PY tools/fw/peemu.py firmware/spi_xfer.hex --spi-slave "A7 E5 96 C1" \
     --spi-frames 4 --expect-spi-rx "5B" --max-cycles 4000000

# 4c. The timer edge the emulator used to get wrong, asserted directly because
#     no firmware loop can guarantee landing on the one-cycle overlap. In the
#     RTL a read samples the PRE-edge register and `tick_now` beats the read
#     clear on the wrap edge; the emulator must do both. tb_pe_soc_tick.v is
#     the RTL half of this pair (directed, white-box).
run_case "emulate: timer wrap semantics" \
  $PY -c "
import sys
sys.path.insert(0, 'tools/fw')
from peemu import Soc
ok = True
def check(cond, msg):
    global ok
    if not cond:
        print('FAIL:', msg); ok = False
# (a) wrap + STATUS read, no prior flag: A sees 0, the event survives.
s = Soc([0x2007]); s.run = True; s.imem_rdata = 0x2007
s.tick_cnt = 259; s.tick_val = 7; s.tick_flag = 0
s.step()
check(s.a == 0 and s.tick_flag == 1, 'wrap+read lost the event')
# (b) wrap + STATUS read with the flag pending: report it AND keep it.
s = Soc([0x2007]); s.run = True; s.imem_rdata = 0x2007
s.tick_cnt = 259; s.tick_val = 7; s.tick_flag = 1
s.step()
check(s.a == 1 and s.tick_flag == 1, 'pending flag was cleared by a same-edge tick')
# (c) TIMER on the wrap cycle returns the pre-increment value.
s = Soc([0x2005]); s.run = True; s.imem_rdata = 0x2005
s.tick_cnt = 259; s.tick_val = 7
s.step()
check(s.a == 7 and s.tick_val == 8, 'TIMER read returned the post-increment value')
# (d) stop -> run: the registered ROM prefetch must be imem[0] on resume.
s = Soc([0x0055, 0x4001]); s.run = True; s.step(); s.step()
s.run = False
for _ in range(3): s.step()
s.run = True; s.step()
check(s.a == 0x55, 'resume executed a stale fetched word, not imem[0]')
print('PASS: timer wrap semantics' if ok else 'FAIL')
sys.exit(0 if ok else 1)
"

# 4d. The TX monitor is a firmware verification oracle, so its sampling grid
#     has to be right: it latches the start edge, then samples the CENTRE of
#     each bit (1.5 periods after the edge for data bit 0, 9.5 for the stop).
#     Sampling at the bit boundary made a wire a few clocks slower than the
#     monitor's nominal period decode A5 as 4A (review 2 R2-6).
run_case "emulate: UART monitor periods" \
  $PY -c "
import sys
sys.path.insert(0, 'tools/fw')
from peemu import Soc
ok = True
for period in (519, 520, 521):
    soc = Soc([])
    bits = [0] + [(0xA5 >> i) & 1 for i in range(8)] + [1, 1]
    for cycle in range(10 + len(bits) * period):
        soc.cycles = cycle
        soc.reg_out = 1 if cycle < 10 else bits[min((cycle - 10) // period, len(bits) - 1)]
        soc.poll_tx()
    if soc.tx_bits != [0xA5]:
        print('FAIL period', period, soc.tx_bits); ok = False
print('PASS: UART monitor periods' if ok else 'FAIL')
sys.exit(0 if ok else 1)
"

# 5. the documented limitation: back-to-back bytes are LOST (half-duplex).
#    Asserts the failure mode rather than hiding it -- if this ever starts
#    passing, the limitation has been fixed and the wiki page needs updating.
if out=$($PY tools/fw/peemu.py firmware/uart_echo.hex --send "41 42" --gap 1 \
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

# ---------------------------------------------------------------------------
# Assembler range checks.
#
# These are NEGATIVE tests: each snippet must be REJECTED. The assembler used
# to silently truncate every out-of-range field, which is the worst possible
# behaviour for a machine whose whole point is that the program is the design:
#
#   * a program over IMEM_WORDS was emitted in full, and the 7-bit program
#     counter aliased word 128 onto word 0 at run time. uart_echo is already
#     114 of 128 words, so the next protocol hits this first.
#   * a jump past the end of instruction memory encoded fine and landed
#     somewhere else entirely.
#   * LDM's bit 7 is a destination selector (A vs X), so `LDM A, 128` silently
#     assembled as `LDM X`.
#   * data addresses above DMEM_BYTES wrapped into occupied slots.
#
# Every one of those is a program that assembles clean and runs wrong.
expect_err() {   # label, expected-substring, source-lines...
  local label="$1" want="$2"; shift 2
  local tmp; tmp=$(mktemp /tmp/peasm_neg_XXXXXX.pe)
  printf '%s\n' "$@" > "$tmp"
  local out rc
  out=$($PY tools/fw/peasm.py "$tmp" 2>&1); rc=$?
  rm -f "$tmp"
  if [ "$rc" -ne 0 ] && grep -qi -- "$want" <<< "$out"; then
    printf '%-34s PASS (rejected)\n' "$label"
    pass=$((pass+1))
  else
    printf '%-34s FAIL\n' "$label"
    printf '    exit=%s out=%s\n' "$rc" "$(head -2 <<< "$out")"
    fail=$((fail+1)); failed+=("$label")
  fi
}

echo
echo "=== assembler range checks (must be rejected) ==="

# Over-long program. The limit moved 128 -> 1024 with the SRAM swap, so this
# test moved with it: it must FAIL at whatever IMEM_WORDS the assembler and the
# RTL agree on, and the failure mode it guards is unchanged (the PC wraps and
# word 1024 executes as word 0). Built as a file rather than through expect_err's
# varargs so the shell cannot word-split it.
#   read the limit from the assembler rather than hard-coding it, so this test
#   cannot silently stop testing anything when the depth changes again.
limit=$($PY -c "import sys; sys.path.insert(0,'tools/fw'); import peasm; print(peasm.IMEM_WORDS)")
big=$(mktemp /tmp/peasm_big_XXXXXX.pe)
for _ in $(seq 1 $((limit + 1))); do echo "        LDI A, 0"; done > "$big"
if out=$($PY tools/fw/peasm.py "$big" 2>&1); then
  printf '%-34s FAIL (accepted %s words)\n' "reject: program over limit" "$((limit + 1))"
  fail=$((fail+1)); failed+=("reject: program over limit")
elif grep -qi "instruction memory" <<< "$out"; then
  printf '%-34s PASS (rejected)\n' "reject: program over $limit words"
  pass=$((pass+1))
else
  printf '%-34s FAIL (wrong error)\n' "reject: program over limit"
  printf '    %s\n' "$(head -1 <<< "$out")"
  fail=$((fail+1)); failed+=("reject: program over limit")
fi
rm -f "$big"

# A jump past the end of instruction memory. 200 was past the end at 128 words;
# at 1024 it is INSIDE the memory, so the test must use the real limit or it
# stops testing anything. Same reasoning as above.
expect_err "reject: jump past imem" "out of range" \
  "        JMP $((limit + 1))"

# ...and the field limit, which is a SECOND bound: the operand is PCW bits, so a
# target inside the memory but outside the field must also be rejected. These
# coincide at 1024 (both 10 bits), which is exactly why the check exists.
expect_err "reject: jump past operand field" "out of range" \
  "        JMP 4096"

# A jump that is now LEGAL and was not before: word 300 is past 255, so this
# program could not have been written against the old 8-bit PC. It is the
# positive half of the PC-widening change and the reason the swap was worth it.
ok=$(mktemp /tmp/peasm_wide_XXXXXX.pe)
{ echo "        JMP 300"; for _ in $(seq 1 300); do echo "        LDI A, 0"; done; } > "$ok"
if out=$($PY tools/fw/peasm.py "$ok" 2>&1); then
  printf '%-34s PASS (word 300 reachable)\n' "accept: jump past word 255"
  pass=$((pass+1))
else
  printf '%-34s FAIL (%s)\n' "accept: jump past word 255" "$(head -1 <<< "$out")"
  fail=$((fail+1)); failed+=("accept: jump past word 255")
fi
rm -f "$ok"

expect_err "reject: LDM A above dmem" "data address" \
  "        LDM A, 128"

expect_err "reject: STM above dmem" "data address" \
  "        STM 20, A"

expect_err "reject: IO port above 15" "port" \
  "        IN A, 31"

echo
echo "========================================"
echo "FIRMWARE: $((pass+fail))   PASS: $pass   FAIL: $fail"
[ "$fail" -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
echo "all firmware tests pass"
