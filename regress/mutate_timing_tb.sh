#!/usr/bin/env bash
# mutate_timing_tb.sh — mutation-test the four TIMING testbenches.
#
# WHAT THIS IS FOR. The timing acts (WS2812, servo, DHT11, DS18B20) have a property
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
# TWO KINDS OF MUTATION, and the 1-Wire act needs both. The first is a text edit
# to a .pe, which is how the three original timing acts are mutated. The 1-Wire
# firmware names its delays as SYMBOLS (OW_RST, OW_T40) because the value is a
# fitted instruction count and the number lives in peasm's CONSTS table, not in
# the source -- so a text edit cannot reach it, and a harness that only knows how
# to sed a .pe would silently cover no counted delay at all. Those cases pass
# `--const NAME=VALUE` to the assembler instead. This matters because the
# counted delays are the whole mechanism of three of these four acts: a gate
# that cannot perturb one is not mutation-testing the thing the act claims.
#
# EVERY MUTANT RUNS ON A PRIVATE COPY. regress/mutate_i2c_xfer_tb.sh mutates the
# tree's firmware in place and restores it with a cmp-verified copy afterwards.
# That is safe when one harness runs at a time, and it is NOT safe here: this
# harness runs its cases in parallel (the servo testbench alone is 66 s of
# simulation, and twenty-five cases in series would be twenty-five minutes), and
# a second case would read the first one's mutant. So each case assembles from a
# private copy of the .pe into a private hex, and the tree is never written to.
# The run verifies that at the end -- a cmp of every firmware file against a
# snapshot taken at the start -- which is a stronger statement than "restored
# correctly", because it says the tree was never touched at all.
#
# THE IMAGE PATH IS A -D, NOT A STRING IN THE TESTBENCH. Each testbench reads its
# image through a `WS2812_HEX / SERVO_HEX / DHT11_HEX / DS18B20_HEX` macro that
# defaults to the tree's firmware/<name>.hex, so a mutant case can be compiled
# against its own image without editing a testbench. That also means the shipped
# testbench and the mutant testbench are the SAME FILE, and a mutant cannot pass
# by accident because it was running a different TB.
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
TB_DS="$ROOT/tb/tb_pe_soc_ds18b20.v"
JOBS="${MUTATE_TIMING_JOBS:-6}"
mkdir -p "$ROOT/sim"

# ---- the tree must not change ---------------------------------------------
SNAP=$(mktemp -d /tmp/mut_timing_snap.XXXXXX)
for f in ws2812 servo_sweep dht11_read ds18b20; do
  cp "$ROOT/firmware/$f.pe"  "$SNAP/$f.pe"
  cp "$ROOT/firmware/$f.hex" "$SNAP/$f.hex"
done
cleanup() { rm -rf "$SNAP"; }
trap cleanup EXIT

# ---- one case, in its own directory ---------------------------------------
# $1 name  $2 firmware stem  $3 TB  $4 -D macro name  $5 anchor  $6 replacement
# $7 (optional) extra assembler arguments, e.g. "--const OW_T40=45"
run_case() {
  local name="$1" stem="$2" tb="$3" def="$4" anchor="$5" repl="$6" extra="${7:-}"
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

  # $extra is a deliberate argument list: it is a flag plus a value, and
  # quoting it would pass "--const" and "OW_T40=45" as two file names.
  # shellcheck disable=SC2086
  if ! python3 "$ROOT/tools/fw/peasm.py" "$d/$stem.pe" $extra -o "$d/$stem.hex" \
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
export ROOT SRCS SRAM_MODEL TB_WS TB_SV TB_DH TB_DS

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
ow-reset-count|ds18b20|the counted RESET delay constant 58 -> 40 (485 us -> 332 us)
ow-sample-early|ds18b20|the counted SAMPLE delay constant 23 -> 2 (25.4 us -> 1.2 us, inside the sensor's response)
ow-sample-late|ds18b20|the counted SAMPLE delay constant 23 -> 45 (25.4 us -> 51.2 us, past the hold)
ow-write1-width|ds18b20|a write-1's low pulse stretched to 29.6 us, past the 15 us maximum
ow-write0-width|ds18b20|a write-0's low pulse collapsed to 1.2 us, inside the 1's band
ow-polarity|ds18b20|the read slot sampled with the WRITE slot's polarity (low = zero)
ow-byte-counter|ds18b20|the read byte counter initialised into the delay's dmem[10] again
ow-bit-order|ds18b20|the byte built shift-left (MSB first) instead of shift-right
ow-skip-rom|ds18b20|SKIP ROM sent as 0x44 instead of 0xCC
ow-read-cmd|ds18b20|READ SCRATCHPAD sent as 0xAE instead of 0xBE
ow-presence-edge|ds18b20|the wait for the presence pulse's release removed
ow-read-count|ds18b20|the read slot counter started at 7, so one slot is short
CASES_EOF

# The counts come from the $results file, not from four shell variables set
# here: the cases run in parallel subshells, so a variable set in one of them
# would never be visible here anyway. These four were the original counters and
# nothing read them.
results=$(mktemp /tmp/mut_timing_res.XXXXXX)
export results
CASELOG=$(mktemp /tmp/mut_timing_log.XXXXXX)
export CASELOG

run_one() {
  local id="$1" desc="$2"
  local stem tb def anchor repl extra=""
  case "$id" in
    ws-*) stem=ws2812;       tb="$TB_WS"; def=WS2812_HEX ;;
    sv-*) stem=servo_sweep;  tb="$TB_SV"; def=SERVO_HEX ;;
    dh-*) stem=dht11_read;   tb="$TB_DH"; def=DHT11_HEX ;;
    ow-*) stem=ds18b20;      tb="$TB_DS"; def=DS18B20_HEX ;;
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
    # ---- the four COUNTED-DELAY-CONSTANT cases. The anchor is a comment-only
    # edit on the line that loads the constant, so the .pe still assembles and
    # the ONLY difference is the --const the assembler was handed. A text edit
    # cannot do this at all: the number is in peasm's CONSTS table, not in the
    # source, which is why --const exists.
    ow-reset-count)
      extra='--const OW_RST=40'   # (40-1)*511+4 = 19933 clocks = 332 us
      anchor="        LDI   A, OW_RST         ; 480 us of low. This is a COUNTED delay and it"
      repl="        LDI   A, OW_RST         ; MUTANT: the fitted constant is overridden" ;;
    ow-sample-early)
      # 2 -> (2-1)*(10+59)+4 = 73 clocks = 1.2 us: inside the sensor's 15 us
      # response, so the line is high and every bit reads as a zero.
      extra='--const OW_T40=2'
      anchor="        LDI   A, OW_T40         ; a fixed wait after the release; the sensor's"
      repl="        LDI   A, OW_T40         ; MUTANT: the fitted constant is overridden" ;;
    ow-sample-late)
      # 45 -> (45-1)*69+4 = 3073 clocks = 51.2 us, past a zero's tRDV+tLOW of
      # 45 us. The DECODE still comes out right, which is the point: this is
      # caught by the sample-inside-the-window margin and by nothing else.
      extra='--const OW_T40=45'
      anchor="        LDI   A, OW_T40         ; a fixed wait after the release; the sensor's"
      repl="        LDI   A, OW_T40         ; MUTANT: the fitted constant is overridden" ;;
    ow-write1-width)
      # 30 -> (30-1)*69+4 = 2041 clocks = 34 us, past the 15 us maximum for a
      # write-1's low pulse. The model's own 30 us decoder still calls it a one,
      # so the COMMANDS still decode: only the band check can see this.
      extra='--const OW_T5=30'
      anchor="        LDI   A, OW_T5           ; 5 us of low: the datasheet's 1-15 us"
      repl="        LDI   A, OW_T5           ; MUTANT: the fitted constant is overridden" ;;
    ow-write0-width)
      # 2 -> 1.2 us, which the model's decoder reads as a ONE (anything under
      # 30 us), so the commands come back shifted as well as mis-banded.
      extra='--const OW_T65=2'
      anchor="        LDI   A, OW_T65         ; 65 us: the datasheet's ~60 us low for a 0"
      repl="        LDI   A, OW_T65         ; MUTANT: the fitted constant is overridden" ;;
    ow-presence-edge)
      anchor='ph1b:   IN    A, PIN
        AND   A, OW_DATA
        JZ    ph1b              ; wait for HIGH: the pulse'"'"'s end. Presence found.'
      repl='ph1b:   NOP                     ; the wait for the release is GONE' ;;
    ow-polarity)
      anchor='        AND   A, OW_DATA
        JNZ   rb_was_zero        ; RELEASED (high) is a zero on the wire;'
      repl='        AND   A, OW_DATA
        JZ    rb_was_zero        ; the WRITE slot'"'"'s polarity: low is a zero' ;;
    ow-byte-counter)
      anchor='        LDI   A, 2              ; the byte never banked: the 1-Wire TB saw 16
        STM   8, A'
      repl='        LDI   A, 2
        STM   10, A             ; dmem[10] is the DELAY'"'"'s middle target' ;;
    ow-bit-order)
      # The DHT11's accumulator, verbatim: shift the byte LEFT and put the new
      # bit in at bit 0. 1-Wire is LSB first, so every byte comes back
      # REVERSED (0x2b as 0xd4) with the right bit count and the right number
      # of ones -- the defect this repository keeps finding twice.
      anchor='        LDM   A, 4              ; PULLED DOWN (low) is a one -- the opposite
        SHR   A                 ; of a write slot, and the reason the two
        OR    A, 0x80           ; directions cannot share one sample idiom'
      repl='        LDM   A, 4
        MOV   X, A
        ADD   A, X              ; the DHT11'"'"'s shift: A = A + A = A << 1
        OR    A, 0x01           ; ...a 1 goes in at the BOTTOM
        STM   4, A' ;;
    ow-skip-rom)
      anchor='        LDI   A, 0xCC
        STM   6, A'
      repl='        LDI   A, 0x44
        STM   6, A              ; not SKIP ROM' ;;
    ow-read-cmd)
      anchor='        LDI   A, 0xBE           ; READ SCRATCHPAD, into the SEND register
        STM   6, A'
      repl='        LDI   A, 0xAE           ; not READ SCRATCHPAD
        STM   6, A' ;;
    ow-read-count)
      anchor='        LDI   A, 8              ; EIGHT bits in this byte. This was 0 first,
        STM   3, A'
      repl='        LDI   A, 7              ; SEVEN bits: one slot short of a byte
        STM   3, A' ;;
    *) return 2 ;;
  esac
  run_case "$id ($desc)" "$stem" "$tb" "$def" "$anchor" "$repl" "$extra"
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
for f in ws2812 servo_sweep dht11_read ds18b20; do
  cmp -s "$SNAP/$f.pe" "$ROOT/firmware/$f.pe"  || { echo "FATAL: firmware/$f.pe was modified"; stale=1; }
  cmp -s "$SNAP/$f.hex" "$ROOT/firmware/$f.hex" || { echo "FATAL: firmware/$f.hex was modified"; stale=1; }
done
[ "$stale" -eq 0 ] && echo "firmware tree byte-identical after the run (cmp-verified, all 8 files)"

echo
echo "timing-TB mutations: $n_cases cases, $n_ok detected, $n_surv survived, $n_err harness errors"
if [ "$n_surv" -ne 0 ] || [ "$n_err" -ne 0 ] || [ "$stale" -ne 0 ] \
   || [ "$n_ok" -ne "$n_cases" ]; then
  echo "RESULT: FAILED"
  exit 1
fi
echo "RESULT: PASS"
