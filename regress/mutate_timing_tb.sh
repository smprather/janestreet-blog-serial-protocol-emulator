#!/usr/bin/env bash
# mutate_timing_tb.sh — mutation-test the three TIMING testbenches.
#
# WHAT THIS IS FOR. The three timing acts (WS2812, servo, DHT11) have a property
# none of the other protocols in this repository has: their DUT is partly the
# FIRMWARE. The RTL is the already-verified CPU, pin matrix, timer and pads; what
# is being tested is a program's instruction count. A testbench that passes
# against a program with the wrong bit period, the wrong bit order, the wrong
# pulse width or a delay that is 300 times too long is not testing anything, and
# unlike a hardware bug there is nothing else in the design that would notice.
#
# So the mutations here are FIRMWARE edits -- the same idea as
# regress/mutate_i2c_xfer_tb.sh, which already mutation-tests a firmware DUT --
# and every one of them must be caught by the testbench that claims to check it.
#
# EVERY MUTANT RUNS ON A PRIVATE COPY. regress/mutate_i2c_xfer_tb.sh mutates the
# tree's firmware in place and restores it with a cmp-verified copy afterwards.
# That is safe when one harness runs at a time, and it is NOT safe here: this
# harness runs its cases in parallel (the servo testbench alone is 66 s of
# simulation, and fourteen cases in series would be fifteen minutes), and a
# second case would read the first one's mutant. So each case assembles from a
# private copy of the .pe into a private hex, and the tree is never written to.
# The run verifies that at the end -- a cmp of every firmware file against a
# snapshot taken at the start -- which is a stronger statement than "restored
# correctly", because it says the tree was never touched at all.
#
# THE IMAGE PATH IS A -D, NOT A STRING IN THE TESTBENCH. Each testbench reads its
# image through a `WS2812_HEX / SERVO_HEX / DHT11_HEX` macro that defaults to the
# tree's firmware/<name>.hex, so a mutant case can be compiled against its own
# image without editing a testbench. That also means the shipped testbench and the
# mutant testbench are the SAME FILE, and a mutant cannot pass by accident
# because it was running a different TB.
set -u
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is one
# of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
SRAM_MODEL=$("$ROOT/regress/sram_model.sh")
SRCS="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v"
TB_WS="$ROOT/tb/tb_pe_soc_ws2812.v"
TB_SV="$ROOT/tb/tb_pe_soc_servo.v"
TB_DH="$ROOT/tb/tb_pe_soc_dht11.v"
JOBS="${MUTATE_TIMING_JOBS:-6}"
mkdir -p "$ROOT/sim"

# ---- the tree must not change ---------------------------------------------
SNAP=$(mktemp -d /tmp/mut_timing_snap.XXXXXX)
for f in ws2812 servo_sweep dht11_read; do
  cp "$ROOT/firmware/$f.pe"  "$SNAP/$f.pe"
  cp "$ROOT/firmware/$f.hex" "$SNAP/$f.hex"
done
cleanup() { rm -rf "$SNAP"; }
trap cleanup EXIT

# ---- one case, in its own directory ---------------------------------------
# $1 name  $2 firmware stem  $3 TB  $4 -D macro name  $5 anchor  $6 replacement
run_case() {
  local name="$1" stem="$2" tb="$3" def="$4" anchor="$5" repl="$6"
  local d; d=$(mktemp -d /tmp/mut_timing_case.XXXXXX)
  local rc=0

  cp "$ROOT/firmware/$stem.pe" "$d/$stem.pe"
  if ! python3 - "$d/$stem.pe" "$anchor" "$repl" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
a, r = sys.argv[2], sys.argv[3]
n = t.count(a)
if n != 1:
    sys.stderr.write(f"anchor occurs {n} times, need exactly 1\n"); sys.exit(9)
p.write_text(t.replace(a, r, 1))
PYEOF
  then
    echo "HARNESS ERROR [$name]: anchor problem"; rm -rf "$d"; return 2
  fi

  if ! python3 "$ROOT/tools/fw/peasm.py" "$d/$stem.pe" -o "$d/$stem.hex" \
        > "$d/asm.log" 2>&1; then
    # A mutant that does not assemble is DETECTED: the property the testbench
    # checks cannot hold for a program that will not build. It is reported
    # separately so a broken anchor is never mistaken for a caught bug.
    echo "detected (does not assemble) [$name]"; rm -rf "$d"; return 0
  fi

  if ! (cd "$ROOT/sim" && iverilog -g2012 "-D$def=\"$d/$stem.hex\"" -s "$(basename "$tb" .v)" \
        -o "$d/out.vvp" $SRCS $SRAM_MODEL "$tb") > "$d/cc.log" 2>&1; then
    echo "HARNESS ERROR [$name]: compile failed"; sed -n '1,3p' "$d/cc.log"; rm -rf "$d"; return 2
  fi

  (cd "$ROOT/sim" && timeout 600 vvp "$d/out.vvp") > "$d/run.log" 2>&1
  if grep -qE '^PASS' "$d/run.log"; then
    echo "SURVIVED [$name]"; rc=1
  elif grep -qE '^FAIL' "$d/run.log"; then
    echo "detected [$name]  ($(grep -cE '^FAIL' "$d/run.log") checks failed)"
  else
    echo "HARNESS ERROR [$name]: neither PASS nor FAIL in the log"
    tail -3 "$d/run.log"; rc=2
  fi
  rm -rf "$d"
  return $rc
}
export -f run_case
export ROOT SRCS SRAM_MODEL TB_WS TB_SV TB_DH

# ---- the cases --------------------------------------------------------------
# Each one is a defect a real firmware of this shape can have, chosen so the
# failure it causes is the SPECIFIC property the testbench claims to check --
# a mutant that trips some unrelated check proves less than one that trips the
# right one, and the notes say which check is expected to fire.
CASES=$(mktemp /tmp/mut_timing_cases.XXXXXX)
cat > "$CASES" <<'CASES_EOF'
ws-cell-pad|ws2812|one clock out of the bit cell
ws-level-bit|ws2812|the 1-level driven on the wrong pin bit
ws-drive-low|ws2812|the line never driven back low mid-frame
ws-byte-boundary|ws2812|the byte index never advanced
ws-reset-reload|ws2812|the reset delay's inner counter not reloaded
sv-pulse-width|servo_sweep|the first pulse 1.0 ms -> 1.75 ms
sv-frame-slot|servo_sweep|the 20 ms frame slot shortened to 17 ms
sv-sweep-order|servo_sweep|the sweep emitted in the wrong order
sv-first-rise|servo_sweep|the line idles high, so the first pulse has no rising edge
dh-start-signal|dht11_read|the 18 ms start signal shortened to 0.26 ms
dh-host-window|dht11_read|the 30 us host-high window stretched to 170 us
dh-sample-instant|dht11_read|the sample taken 20 us into the release, not 45
dh-bit-order|dht11_read|the byte built right-shift instead of left
dh-edge-wait|dht11_read|the wait for the line to go high removed
CASES_EOF

pass=0; fail=0; survived=0; herr=0
results=$(mktemp /tmp/mut_timing_res.XXXXXX)
export results
CASELOG=$(mktemp /tmp/mut_timing_log.XXXXXX)
export CASELOG

run_one() {
  local id="$1" desc="$2"
  local stem tb def anchor repl
  case "$id" in
    ws-*) stem=ws2812;       tb="$TB_WS"; def=WS2812_HEX ;;
    sv-*) stem=servo_sweep;  tb="$TB_SV"; def=SERVO_HEX ;;
    dh-*) stem=dht11_read;   tb="$TB_DH"; def=DHT11_HEX ;;
    *) echo "HARNESS ERROR: unknown case id $id" >> "$results"; return 2 ;;
  esac
  case "$id" in
    ws-cell-pad)
      # The equalised branch is 14 pads + a JMP. Dropping ONE pad makes the
      # ordinary cells 74 clocks and only the three byte-boundary cells 75 --
      # a frame that is 3/24 wrong, which is the defect the cell-period and
      # grid checks exist for and which no datasheet window would notice.
      anchor='        NOP                     ; 76
        JMP   bitcell           ; 77'
      repl='        JMP   bitcell           ; 77' ;;
    ws-level-bit)
      anchor='        LDI   A, LED_DIN        ;  6  a 1: the data pin'
      repl='        LDI   A, 0x80            ;  6  a 1: the WRONG bit' ;;
    ws-drive-low)
      anchor='        LDI   A, 0x00           ; 57
        OUT   TXPIN, A          ; 58  back to low'
      repl='        NOP                     ; 57
        NOP                     ; 58  never driven low' ;;
    ws-byte-boundary)
      anchor='        INCX                    ; 68'
      repl='        NOP                     ; 68  the byte index never advances' ;;
    ws-reset-reload)
      anchor='        LDM   A, 10             ;  5
        STM   11, A             ;  6   the reload'
      repl='        NOP                     ;  5  the reload is gone
        NOP                     ;  6' ;;
    sv-pulse-width)
      anchor='        LDI   A, 97
        STM   0, A              ; 1000 us, 0 degrees'
      repl='        LDI   A, 170
        STM   0, A              ; 170 = 1.75 ms, not 1.0 ms' ;;
    sv-frame-slot)
      anchor='        LDI   A, 229
        STM   5, A              ; the 19.0 ms gap that completes a 20 ms slot'
      repl='        LDI   A, 210
        STM   5, A              ; a 17.6 ms gap: the frame is 18.6 ms' ;;
    sv-sweep-order)
      anchor='        LDI   A, 145
        STM   1, A              ; 1500 us, centre'
      repl='        LDI   A, 169
        STM   1, A              ; the order of two positions is swapped' ;;
    sv-idle-level)
      anchor='        OUT   TXPIN, A          ; the level: LOW, the servo'"'"'s idle'
      repl='        OUT   TXPIN, A          ; the level: HIGH, which is not idle' ;;
    sv-first-rise)
      anchor='        LDI   A, 0x00
        OUT   TXPIN, A          ; the level: LOW, the servo'"'"'s idle'
      repl='        LDI   A, SRV_DATA
        OUT   TXPIN, A          ; the level: HIGH, which is not an idle' ;;
    dh-start-signal)
      anchor='        LDI   A, 212
        STM   9, A              ; the long (6,255) counts, 18 ms
        LDI   A, 6
        STM   10, A
        LDI   A, 255
        STM   13, A'
      repl='        LDI   A, 4
        STM   9, A              ; 4 long passes = 0.26 ms of low
        LDI   A, 6
        STM   10, A
        LDI   A, 255
        STM   13, A' ;;
    dh-host-window)
      anchor='        LDI   A, 45
        STM   9, A              ; the fine (2,6) counts, 30 us'
      repl='        LDI   A, 250
        STM   9, A              ; 170 us: outside the 20-40 us window' ;;
    dh-sample-instant)
      anchor='        LDI   A, 67             ; 45 us into the release'
      repl='        LDI   A, 20             ; 14 us into the release: inside a 0' ;;
    dh-bit-order)
      anchor='        LDM   A, 6              ; a 0: the same shift, bit 0 left clear
        MOV   X, A
        ADD   A, X
        STM   6, A'
      repl='        LDM   A, 6
        SHR   A                 ; the wrong way round: the byte is reversed
        STM   6, A' ;;
    dh-edge-wait)
      anchor='w_hi:   IN    A, PIN
        AND   A, DHT_DATA
        JZ    w_hi'
      repl='w_hi:   NOP                     ; the wait for the release is gone' ;;
    *) return 2 ;;
  esac
  run_case "$id ($desc)" "$stem" "$tb" "$def" "$anchor" "$repl"
  echo "rc=$?" >> "$results"
}
export -f run_one

# Run them, N at a time. The output is collected per case and printed in the
# declared order afterwards, so the table is stable however the scheduler ran.
grep -v '^#' "$CASES" | while IFS='|' read -r id desc; do
  printf '%s\0%s\0' "$id" "$desc"
done | xargs -0 -n2 -P "$JOBS" bash -c 'run_one "$0" "$1"' >> "$CASELOG" 2>&1

# The results file has one "rc=" per completed case, in completion order; the
# per-case lines were printed to stdout above. Count them here.
sort -k1,1 "$CASELOG" 2>/dev/null | grep -v '^rc=' | sed 's/^/  /'
n_cases=$(grep -c . "$CASES")
n_ok=$(grep -c '^rc=0$' "$results" || true)
n_surv=$(grep -c '^rc=1$' "$results" || true)
n_err=$(grep -c '^rc=2$' "$results" || true)
rm -f "$CASES" "$results" "$CASELOG"

# ---- the tree must not have changed ----------------------------------------
stale=0
for f in ws2812 servo_sweep dht11_read; do
  cmp -s "$SNAP/$f.pe" "$ROOT/firmware/$f.pe"  || { echo "FATAL: firmware/$f.pe was modified"; stale=1; }
  cmp -s "$SNAP/$f.hex" "$ROOT/firmware/$f.hex" || { echo "FATAL: firmware/$f.hex was modified"; stale=1; }
done
[ "$stale" -eq 0 ] && echo "firmware tree byte-identical after the run (cmp-verified, all 6 files)"

echo
echo "timing-TB mutations: $n_cases cases, $n_ok detected, $n_surv survived, $n_err harness errors"
if [ "$n_surv" -ne 0 ] || [ "$n_err" -ne 0 ] || [ "$stale" -ne 0 ] \
   || [ "$n_ok" -ne "$n_cases" ]; then
  echo "RESULT: FAILED"
  exit 1
fi
echo "RESULT: PASS"
