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
# MUTABLE — what this harness EDITS inside the repo. Read by
# regress/verify_merge.sh (the merge gate) to decide whether a narrowed gate
# has to run this suite, and by regress/check_mutation_lists.sh to prove the
# list still covers every file the harness writes. Evidence: the `for f in ...` firmware list it snapshots into $SNAP and restores.
# An EMPTY value means this suite mutates nothing in the repo and is therefore
# NEVER SKIPPED. A MISSING line is the opposite: unmappable, and the gate
# escalates to running every suite rather than guessing.
MUTABLE="firmware/ws2812.pe firmware/ws2812.hex firmware/servo_sweep.pe firmware/servo_sweep.hex firmware/dht11_read.pe firmware/dht11_read.hex firmware/ds18b20.pe firmware/ds18b20.hex firmware/nec_ir.pe firmware/nec_ir.hex firmware/stepper_ramp.pe firmware/stepper_ramp.hex firmware/freqmeter.pe firmware/freqmeter.hex"
SRCS="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v"
TB_WS="$ROOT/tb/tb_pe_soc_ws2812.v"
TB_SV="$ROOT/tb/tb_pe_soc_servo.v"
TB_DH="$ROOT/tb/tb_pe_soc_dht11.v"
TB_DS="$ROOT/tb/tb_pe_soc_ds18b20.v"
TB_NEC="$ROOT/tb/tb_pe_soc_ir_nec.v"
TB_STP="$ROOT/tb/tb_pe_soc_stepper_ramp.v"
TB_FM="$ROOT/tb/tb_pe_soc_freqmeter.v"
JOBS="${MUTATE_TIMING_JOBS:-6}"
mkdir -p "$ROOT/sim"

# ---- the tree must not change ---------------------------------------------
SNAP=$(mktemp -d /tmp/mut_timing_snap.XXXXXX)
for f in ws2812 servo_sweep dht11_read ds18b20 nec_ir stepper_ramp freqmeter; do
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
export ROOT SRCS SRAM_MODEL TB_WS TB_SV TB_DH TB_DS TB_NEC TB_STP TB_FM

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
ir-carrier-h1|nec_ir|the carrier's HIGH half period one step short, so the carrier alternates
ir-carrier-h2|nec_ir|the carrier's LOW half period one step short, so the carrier alternates
ir-carrier-n1|nec_ir|the carrier's LOW half period re-fitted to the same (2,34) pair as the other half
ir-gap0|nec_ir|a ZERO's gap shortened to a ONE's, so the zero bits read as ones
ir-gap1|nec_ir|a ONE's gap stretched into a ZERO's
ir-leader|nec_ir|the leader's cycle count reduced, so the 9 ms leader is 3 ms
ir-leadgap|nec_ir|the leader's 4.5 ms gap shortened to 136 us
ir-burst-count|nec_ir|a data burst built from 20 carrier cycles instead of 21
ir-no-rotate|nec_ir|the byte never rotated, so the frame is eight ones instead of 0xA5
ir-stop-burst|nec_ir|the stop burst left out, so the frame ends on the eighth gap
ir-no-drive|nec_ir|only the leader drives the pin; the data bursts leave it released
st-ramp-const|stepper_ramp|the first step period's counted constant 196 -> 112, so the ramp runs the driver's minimum step rate out before the twelfth step
st-ramp-decrement|stepper_ramp|the ramp decrement 10 -> 9, so the ramp is no longer 5110 clocks
st-setup-const|stepper_ramp|the direction setup constant 6 -> 3, under the driver's 5 us
st-pulse-const|stepper_ramp|the STEP pulse constant 2 -> 1, so the pulse is 0.4 us and a driver cannot see it
st-no-dir|stepper_ramp|the direction change removed: twelve steps in one direction
st-dir-clobbered|stepper_ramp|the step's level write clears the DIR bit, so the direction never changes
st-step-releases-dir|stepper_ramp|PINOE written with ST_STEP alone, so DIR floats at the step edge
st-release-drops-dir|stepper_ramp|PINOE written with 0x00 to release STEP, which releases DIR too
st-dir-never-on-pin|stepper_ramp|the direction change updates the register but never writes the pin, so the second run is stepped in the OLD direction
st-no-ramp|stepper_ramp|the ramp never shortened, so the twelve steps are at one period
st-shared-slot|stepper_ramp|the ramp counter back in dmem[9], which the delay routine counts to zero
fm-tick-port|freqmeter|the timebase read from TIMER (the 4.33 us UART half-bit counter) instead of the 1 us one
fm-t-high-byte|freqmeter|the period counter's high byte never incremented, so 10 000 us wraps to 16
fm-h-high-byte|freqmeter|the high-time counter's high byte never incremented
fm-wrong-pad|freqmeter|the pad mask moved to bit 5, so the pad never appears to change
fm-no-rearm|freqmeter|the counters not reset at the rising edge, so each period is the sum of all of them
fm-double-count|freqmeter|the period counter advanced twice per elapsed microsecond
fm-idx-stuck|freqmeter|the slot index never advanced, so both points report the first one
fm-finishes-early|freqmeter|the run declared finished after ONE point, leaving the second slot unwritten
fm-high-byte-order|freqmeter|the high time banked high byte first, which reads as a real measurement times 256
fm-per-base|freqmeter|the period slot's base address shifted, so the periods land on the high times
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
    ir-*) stem=nec_ir;       tb="$TB_NEC"; def=NEC_HEX ;;
    st-*) stem=stepper_ramp; tb="$TB_STP"; def=STEPPER_HEX ;;
    fm-*) stem=freqmeter;    tb="$TB_FM"; def=FREQMETER_HEX ;;
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
    # ---- NEC. The carrier cases are the point of this act: each one leaves
    # the carrier inside the 38 kHz tolerance and breaks its CONSTANCY, which
    # is a check a single carrier-frequency window would forgive.
    ir-carrier-h1)
      extra='--const IR_H1=4'    # 4 steps of 193: 13.0 us instead of 13.15
      anchor="        LDI   A, IR_H1
        STM   9, A
        LDI   A, 2
        STM   10, A
        LDI   A, 44"
      repl="        LDI   A, IR_H1
        STM   9, A
        LDI   A, 2
        STM   10, A
        LDI   A, 44
        ; MUTANT: the fitted high half period is overridden (see --const)" ;;
    ir-carrier-h2)
      extra='--const IR_H2=5'
      anchor="        LDI   A, IR_H2
        STM   9, A
        LDI   A, 2
        STM   10, A
        LDI   A, 34"
      repl="        LDI   A, IR_H2
        STM   9, A
        LDI   A, 2
        STM   10, A
        LDI   A, 34
        ; MUTANT: the fitted low half period is overridden (see --const)" ;;
    ir-carrier-n1)
      # the same delay constant for BOTH halves, on the (2,34) pair: the two
      # half periods then differ by the seven clocks the phase ladder costs,
      # and the carrier alternates 38.05/37.88 kHz -- inside every window.
      anchor="        LDI   A, IR_H1
        STM   9, A
        LDI   A, 2
        STM   10, A
        LDI   A, 44"
      repl="        LDI   A, IR_H2
        STM   9, A
        LDI   A, 2
        STM   10, A
        LDI   A, 34" ;;
    ir-gap0)
      extra='--const IR_GAP0=67'   # a ZERO sent with a ONE's gap
      anchor="        LDI   A, IR_GAP0
        STM   9, A"
      repl="        LDI   A, IR_GAP0
        STM   9, A
        ; MUTANT: the fitted zero gap is overridden (see --const)" ;;
    ir-gap1)
      extra='--const IR_GAP1=200'  # a ONE sent with a ZERO's gap
      anchor="        LDI   A, IR_GAP1
        STM   9, A"
      repl="        LDI   A, IR_GAP1
        STM   9, A
        ; MUTANT: the fitted one gap is overridden (see --const)" ;;
    ir-leader)
      extra='--const IR_LEADR=1'   # one run, not two: a 4.5 ms "leader"
      anchor="        LDI   A, IR_LEADR
        STM   1, A"
      repl="        LDI   A, IR_LEADR
        STM   1, A
        ; MUTANT: the leader is one run instead of two (see --const)" ;;
    ir-leadgap)
      extra='--const IR_LEADGAP=17'  # 529 & 0xFF: the eight-bit truncation
      anchor="        LDI   A, IR_LEADGAP
        STM   9, A"
      repl="        LDI   A, IR_LEADGAP
        STM   9, A
        ; MUTANT: the leader gap is the TRUNCATED constant (see --const)" ;;
    ir-burst-count)
      extra='--const IR_BIT=20'
      anchor="        LDI   A, IR_BIT
        STM   7, A              ; 21 carrier cycles = 0.5625 ms"
      repl="        LDI   A, IR_BIT
        STM   7, A
        ; MUTANT: the fitted burst length is overridden (see --const)" ;;
    ir-no-rotate)
      anchor='ph5:    LDM   A, 3              ; the byte being sent
        SHR   A                 ; the next bit of the frame is now bit 0
        STM   3, A'
      repl='ph5:    LDM   A, 3              ; the byte being sent
        NOP                     ; MUTANT: never rotated, so every bit is the same
        STM   3, A' ;;
    ir-stop-burst)
      anchor="        JZ    ir_stop           ; all eight sent: the stop burst next"
      repl="        NOP                     ; MUTANT: the stop burst is never sent
        JMP   ir_start_bit" ;;
    ir-no-drive)
      # only the leader drives the pad: the data bursts leave it released, and
      # the frame that leaves the pin is a leader and nothing else.
      anchor="ir_emit:
        LDI   A, IR_DATA
        OUT   PINOE, A          ; drive: the burst is on the wire from here"
      repl="ir_emit:
        LDI   A, 0x00
        OUT   PINOE, A          ; MUTANT: the pad is left released" ;;
    # ---- STEPPER. The act's claim is an EQUALITY against 5110 clocks, so the
    # cases that matter are the ones that keep every window happy and break the
    # equality: a ramp decrement of 9 is a perfectly good ramp that is not THIS
    # ramp, and only an equality check can tell them apart.
    st-ramp-const)
      # The COUNTED-DELAY-CONSTANT case, and the interesting way to use one: not
      # a shift (shifting a whole ramp is a different valid ramp, not a defect,
      # and a gate that claimed to catch that would be claiming to catch a
      # choice) but a value that RUNS THE RAMP OUT. At 112 the twelfth step's
      # counter is 2 outer steps, 17 us, an order of magnitude under the
      # driver's minimum step rate -- and one step earlier it is 255, the
      # unsigned wrap, which is the defect this block has now found four times.
      extra='--const ST_GAP0=112'
      anchor="        LDI   A, ST_GAP0
        STM   4, A"
      repl="        LDI   A, ST_GAP0
        STM   4, A
        ; MUTANT: the fitted first period is overridden (see --const)" ;;
    st-ramp-decrement)
      anchor='ph2:    LDM   A, 4              ; the next period is ten outer steps shorter --
        SUB   A, 10             ; THE RAMP, in one subtraction, 5110 clocks
        STM   4, A'
      repl='ph2:    LDM   A, 4
        SUB   A, 9              ; MUTANT: nine, so the ramp is 4599 clocks
        STM   4, A' ;;
    st-setup-const)
      extra='--const ST_SETUP=3'    # 3*69+4 = 211 clocks = 3.5 us, under 5
      anchor="        LDI   A, ST_SETUP
        STM   9, A"
      repl="        LDI   A, ST_SETUP
        STM   9, A
        ; MUTANT: the fitted setup time is overridden (see --const)" ;;
    st-pulse-const)
      extra='--const ST_PULSE=1'    # 1*69+4 = 73 clocks = 1.2 us... to 0.4:
      anchor="        LDI   A, ST_PULSE
        STM   9, A"
      repl="        LDI   A, ST_PULSE
        STM   9, A
        ; MUTANT: the fitted pulse width is overridden (see --const)" ;;
    st-no-dir)
      anchor='        LDI   A, 0x00
        STM   0, A              ; the new direction, in the register
        OUT   TXPIN, A'
      repl='        LDI   A, 0x20          ; MUTANT: the direction never changes
        STM   0, A
        OUT   TXPIN, A' ;;
    st-dir-clobbered)
      # THE BUG THIS ACT FOUND: the step's level write went out as 0x00 and
      # cleared the DIR bit, so the first step zeroed the direction and the
      # change half a ramp later wrote a zero to a register already at zero.
      anchor='        LDM   A, 0
        OUT   TXPIN, A          ; STEP LOW (bit 6 clear), DIR at whatever'
      repl='        LDI   A, 0x00           ; MUTANT: clears the DIR bit too
        OUT   TXPIN, A' ;;
    # NOTE ON A CASE THAT WAS WRITTEN AND THEN DELETED, because the reason is
    # the whole discipline. The first version of st-dir-released released the
    # DIR pad at the moment of the direction change. It SURVIVED, and the
    # second time it survived it looked like a gap in the testbench, and it was
    # not: the pad is released for the four instructions between that write and
    # the write that sets the direction, and the direction being set is the
    # pull-down's own value, so the wire is identical either way. It is a
    # benign mutant. A gate that kept it and loosened a check to catch it would
    # be claiming to catch a no-op, which is the same error as a check that
    # cannot fail -- one level down. The replacement is the same defect made
    # real: the change is written AFTER the setup delay, so the driver is
    # given the whole 5.8 us of "setup" with the OLD direction still on the pin
    # and then steps immediately.
    # ONE anchor, and it takes the direction write OUT of the flip. The
    # register in dmem[0] is still updated, so the program BELIEVES the
    # direction changed -- the defect is invisible from dmem and only exists on
    # the wire, which is the whole of what this act measures. The driver then
    # decodes the OLD direction for all six steps of the second run.
    st-dir-never-on-pin)
      anchor='        LDI   A, 0x00
        STM   0, A              ; the new direction, in the register
        OUT   TXPIN, A'
      repl='        LDI   A, 0x00
        STM   0, A              ; MUTANT: the register is updated, so dmem
                                ; says the direction changed, but nothing is
                                ; written to the pin -- the second run is
                                ; stepped in the OLD direction.' ;;
    st-step-releases-dir)
      # The fourth clobbering write: driving STEP with ST_STEP alone clears the
      # DIR pad for the whole step pulse, and a driver samples DIR on the STEP
      # edge. The receiver sees the direction fall at every step.
      anchor='        LDI   A, ST_BOTH
        OUT   PINOE, A          ; drive STEP, and keep DIR DRIVEN: a driver'
      repl='        LDI   A, ST_STEP         ; MUTANT: releases the DIR pad
        OUT   PINOE, A          ; drive STEP' ;;
    st-release-drops-dir)
      # ...and the third: releasing STEP with 0x00 releases DIR as well, so the
      # direction floats for the whole of the low phase.
      anchor='ph1:    LDI   A, ST_DIR
        OUT   PINOE, A          ; release STEP and ONLY STEP: a write of 0x00'
      repl='ph1:    LDI   A, 0x00           ; MUTANT: releases DIR too
        OUT   PINOE, A          ; release STEP' ;;
    st-no-ramp)
      anchor='ph2:    LDM   A, 4              ; the next period is ten outer steps shorter --
        SUB   A, 10             ; THE RAMP, in one subtraction, 5110 clocks
        STM   4, A'
      repl='ph2:    LDM   A, 4              ; MUTANT: the ramp never shortens
        STM   4, A' ;;
    st-shared-slot)
      # THE OTHER BUG THIS ACT FOUND: the ramp counter back in dmem[9], which
      # the delay routine counts itself down to zero.
      anchor="        LDI   A, ST_GAP0
        STM   4, A"
      repl="        LDI   A, ST_GAP0
        STM   9, A              ; MUTANT: dmem[9] is the DELAY's own counter" ;;
    fm-tick-port)
      # THE TRAP THIS ACT FELL INTO ITSELF, kept as a case. The timebase read
      # from TIMER is the UART HALF-BIT tick: 260 clocks, 4.33 us, because it
      # exists to place a serial sample mid-cell. Every period in the sweep is
      # then reported a factor of 4.33 out, and the error is in the WRONG
      # DIRECTION at every point (a longer period reads shorter), which is the
      # shape a systematic timebase mistake always has.
      anchor='        IN    A, I2CTICK       ; the free-running 1 us counter'
      repl='        IN    A, TIMER         ; MUTANT: the 4.33 us UART half-bit tick' ;;
    fm-t-high-byte)
      # THE 16-BIT CLAIM, and the reason the sweep goes down to 100 Hz. The
      # low byte still counts, so the program runs, reports plausible numbers
      # at every fast point, and reports 16 us for a 100 Hz signal. Nothing
      # about that is visible in the log except at the one point where the
      # claim is made.
      anchor="        LDM   A, 1
        ADD   A, 1
        STM   1, A"
      repl="        NOP                      ; MUTANT: the high byte never increments
        NOP
        NOP" ;;
    fm-h-high-byte)
      # The same defect in the OTHER counter. It is a separate case because a
      # gate that only ever perturbs the first counter would not know whether
      # the high-time path is exercised at all: the longest high time in the
      # sweep is 6000 us and the longest period 10 000, so the two counters
      # are not interchangeable and neither check covers the other.
      anchor="        LDM   A, 3
        ADD   A, 1
        STM   3, A"
      repl="        NOP                      ; MUTANT: the high byte never increments
        NOP
        NOP" ;;
    fm-wrong-pad)
      # A counted CONSTANT rather than a text edit, because FM_IN lives in
      # peasm's CONSTS table and the harness reaches those with --const: a
      # harness that only knew how to sed a .pe would silently cover no
      # constant at all, which is the failure mode the 1-Wire act already
      # found once. Bit 5 is held high by the testbench's pad drive, so the
      # level never appears to change and no edge is ever detected -- which is
      # the whole failure mode of a firmware pointed at the wrong pad.
      extra='--const FM_IN=0x20'
      anchor="        LDI   A, FM_IN
        STM   4, A             ; the line idles high (see the header)"
      repl="        LDI   A, FM_IN
        STM   4, A             ; MUTANT: the fitted constant is overridden" ;;
    fm-per-base)
      # The other constant. On a SIXTEEN-BYTE machine a shifted slot base
      # overlaps the working counters rather than running off the end of
      # memory, so this does not read as an addressing bug: the periods land
      # on the high times and vice versa, and both still look like numbers.
      extra='--const FM_PER_BASE=10'
      anchor='        LDI   A, FM_PER_BASE'
      repl='        LDI   A, FM_PER_BASE     ; MUTANT: the fitted constant is overridden' ;;
    fm-no-rearm)
      # The reset that makes the whole design work: without it the counters
      # are absolute times rather than elapsed times, every "period" is the
      # sum of all of them, and the FIRST point still looks right -- so a
      # check that only looked at the first point would pass.
      anchor="rearm:
        LDI   A, 0
        STM   0, A
        STM   1, A
        STM   2, A
        STM   3, A
        JMP   main"
      repl="rearm:
        NOP                      ; MUTANT: the counters are never reset
        NOP
        NOP
        NOP
        NOP
        JMP   main" ;;
    fm-double-count)
      anchor="        LDM   A, 0
        ADD   A, X
        STM   0, A"
      repl="        LDM   A, 0
        ADD   A, X
        ADD   A, X              ; MUTANT: counted twice
        STM   0, A" ;;
    fm-idx-stuck)
      anchor="        LDI   A, 1
        STM   5, A
        JMP   rearm"
      repl="        LDI   A, 1
        NOP                      ; MUTANT: the index never advances
        JMP   rearm" ;;
    fm-finishes-early)
      # The run ends after ONE point, so the second slot is never written. The
      # testbench has an explicit "was it actually written" check for exactly
      # this, because every arithmetic check in it is silently satisfied by an
      # X: a comparison against an unknown is false in Verilog, so an unwritten
      # result passes the period, the high time and the duty checks.
      anchor="        LDM   A, 5
        JNZ   fin               ; IDX was 1, so both slots are now full"
      repl="        LDM   A, 5
        JNZ   rearm             ; MUTANT: finished after one point" ;;
    fm-high-byte-order)
      # The high time banked HIGH BYTE FIRST. The ISA has no 16-bit data path,
      # so every 16-bit quantity in this program is two byte stores and the
      # order is a decision rather than a property -- and getting it wrong
      # produces a number that is a real measurement times 256, which reads as
      # a distance rather than as an addressing fault. The testbench reads the
      # pair little-endian and names that order, so this is caught by the
      # high-time check and by the duty.
      anchor="        LDM   A, 2
        STS   [X], A
        INCX
        LDM   A, 3
        STS   [X], A"
      repl="        LDM   A, 3              ; MUTANT: the bytes are swapped
        STS   [X], A
        INCX
        LDM   A, 2
        STS   [X], A" ;;
    fm-per-base)
      # The other counted constant, and the other half of the map. A shifted
      # slot base on a SIXTEEN-BYTE machine does not run off the end of
      # memory, it overlaps the working counters -- so the mutant reads as
      # plausible numbers rather than as an addressing fault.
      extra='--const FM_PER_BASE=10'
      anchor='        LDI   A, FM_PER_BASE'
      repl='        LDI   A, FM_PER_BASE     ; MUTANT: the fitted constant is overridden' ;;
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
for f in ws2812 servo_sweep dht11_read ds18b20 nec_ir stepper_ramp freqmeter; do
  cmp -s "$SNAP/$f.pe" "$ROOT/firmware/$f.pe"  || { echo "FATAL: firmware/$f.pe was modified"; stale=1; }
  cmp -s "$SNAP/$f.hex" "$ROOT/firmware/$f.hex" || { echo "FATAL: firmware/$f.hex was modified"; stale=1; }
done
[ "$stale" -eq 0 ] && echo "firmware tree byte-identical after the run (cmp-verified, all 14 files: 7 programs, .pe and .hex)"

echo
echo "timing-TB mutations: $n_cases cases, $n_ok detected, $n_surv survived, $n_err harness errors"
if [ "$n_surv" -ne 0 ] || [ "$n_err" -ne 0 ] || [ "$stale" -ne 0 ] \
   || [ "$n_ok" -ne "$n_cases" ]; then
  echo "RESULT: FAILED"
  exit 1
fi
echo "RESULT: PASS"
