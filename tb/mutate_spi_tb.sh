#!/usr/bin/env bash
# Mutation-test tb_pe_spi_soc.v: it must FAIL when the properties it claims
# break. A testbench that passes on broken RTL is worse than no testbench,
# because it manufactures confidence.
#
# WHAT THIS HARNESS IS GUARDING, SPECIFICALLY
#
# The SPI TB's load-bearing claim is that the byte the SLAVE decodes from the
# pins is the byte the firmware meant to send, MSB first. That claim is what
# makes SPI a verified protocol rather than a pin-toggling demo. So the
# mutations below attack the bit order, the sample edge, the frame boundaries
# and the response path -- not incidental behaviour.
#
# THREE OUTCOMES, NOT TWO. A mutation is only meaningful if the mutated design
# actually BUILT. Reporting "not detected" when the compile failed would be a
# false accusation against the TB -- and would hide a genuinely surviving
# mutation behind an unrelated build error. So a compile failure is
# INCONCLUSIVE, reported as such, and fails the run.
#
# Usage: tb/mutate_spi_tb.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The SRAM behavioural model, via the same helper run_all.sh uses, and BEFORE
# run_case() because the compile line inside it needs the variable. Compiling
# without it silently falls back to pe_imem's FLOP array, which would mean the
# mutation test exercised a different memory than the one that ships.
if ! SRAM_MODEL=$(cd sim && ../tb/sram_model.sh); then
  echo "FATAL: SRAM behavioural model unavailable; cannot simulate the SoC."
  exit 2
fi
SRAM_FLAGS=$(printf '%s ' $SRAM_MODEL)

detected=0
inconclusive=0
survived=0

# Files any mutation may touch, for the snapshot/restore.
MUTABLE="rtl/pe_uart_soc.v rtl/pe_pinmux.v firmware/spi_xfer.pe"

# The pristine snapshot every restore is verified against. NOT git: a harness
# must work in a `git archive` clone (which has no .git at all) and must not
# call a legitimate uncommitted change a failed restore -- measured both ways
# on the fresh-clone regression the review runs.
PRISTINE=$(mktemp -d)
for f in $MUTABLE; do cp "$f" "$PRISTINE/"; done
# The assembled image is committed too, and a mutation run regenerates it
# from the mutated source. Snapshot it as well so an interrupted run can
# put BOTH back byte-exactly (review 2 R2-7).
IMAGE=firmware/spi_xfer.hex
cp "$IMAGE" "$PRISTINE/"

run_case() {
  local name="$1"; shift
  local script="$1"

  echo "=== mutation: $name ==="

  local backup
  backup=$(mktemp -d)
  for f in $MUTABLE; do cp "$f" "$backup/"; done

  restore() {
    for f in $MUTABLE; do cp "$backup/$(basename "$f")" "$f"; done
    rm -rf "$backup"
    python3 tools/peasm.py firmware/spi_xfer.pe -o firmware/spi_xfer.hex >/dev/null 2>&1
  }


  # ---- restore VERIFICATION -------------------------------------------------
  # A mutation harness that fails to restore leaves MUTATED RTL on disk, and
  # every subsequent test run then quietly tests the mutant. That happened during
  # development (an ad-hoc cross-check loop, not this script) and it produced a
  # full regression run reporting failures in the firmware and the SPI TB -- both
  # of which were really reporting the leftover mutation. The verdict was
  # nonsense and it looked like a real regression.
  #
  # So the restore is now VERIFIED, per case, against a PRISTINE SNAPSHOT:
  # are the mutable files byte-identical to the ones this run started from?
  verify_restore() {
    for f in $MUTABLE; do
      if ! cmp -s "$PRISTINE/$(basename "$f")" "$f"; then
        echo "  RESTORE FAILED -- $f does not match the pristine snapshot:"
        diff "$PRISTINE/$(basename "$f")" "$f" | head -10 | sed 's/^/    /'
        echo "    Refusing to continue: every later result would be measuring the mutant."
        exit 3
      fi
    done
  }

  if ! python3 "$script"; then
    echo "  MUTATION DID NOT APPLY -> INCONCLUSIVE"
    inconclusive=$((inconclusive+1))
    restore
    verify_restore
    echo
    return
  fi

  python3 tools/peasm.py firmware/spi_xfer.pe -o firmware/spi_xfer.hex >/dev/null 2>&1

  # Compile into a temp dir under a name unique to this case, so a stale vvp
  # from a previous case can never be executed by accident. -s names the REAL
  # top module (the TB), not a wrapper.
  local work; work=$(mktemp -d)
  local top="tb_pe_spi_soc"
  # iverilog prints "sorry:" notices (unsupported-but-tolerated constructs) to
  # stderr and still exits 0. Gating on the exit code rather than on the
  # chatter is the difference between "the mutation broke the build" and
  # "Icarus grumbled".
  local cc=0
  (cd sim && iverilog -g2012 -s "$top" -o "$work/$top.vvp" $SRAM_FLAGS \
      ../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_uart_soc.v \
      ../tb/tb_pe_spi_soc.v) >"$work/compile.log" 2>&1 || cc=$?
  if [ "$cc" -ne 0 ] || [ ! -s "$work/$top.vvp" ]; then
    echo "  INCONCLUSIVE: the mutated design did not compile (iverilog exit $cc)"
    grep -E "error:" "$work/compile.log" | head -4 | sed 's/^/    /'
    inconclusive=$((inconclusive+1))
    rm -rf "$work"
    restore
    verify_restore
    echo
    return
  fi

  # RUN FROM sim/. The TB does $readmemh("../firmware/spi_xfer.hex"), which only
  # resolves from sim/ -- running vvp from the repo root silently loads nothing,
  # the program is all NOP fill, no pins ever move, and EVERY mutation then
  # looks "detected" for the same wrong reason. (This exact bug was found the
  # hard way in tb/mutate_i2c_tb.sh.)
  local out
  out=$(cd sim && vvp "$work/$top.vvp" 2>&1)
  rm -rf "$work"

  if grep -q '^FAIL' <<< "$out"; then
    echo "  DETECTED (TB failed on the mutated design)"
    grep -E '^FAIL' <<< "$out" | head -3 | sed 's/^/    /'
    detected=$((detected+1))
  else
    echo "  SURVIVED -- the TB passed on the mutated design (blind spot)"
    grep -E '^PASS|RESULT' <<< "$out" | head -3 | sed 's/^/    /'
    survived=$((survived+1))
    fi

    restore
    verify_restore
    echo
    }

TMP=$(mktemp -d)
# Interruption is not an excuse to leave the checkout mutated. The
# per-case restore only runs on its normal path, and EXIT only cleaned
# temporaries -- so SIGTERM mid-simulation left the mutated sources in
# place and the next regression measured them (measured, review 2 R2-7).
# This trap restores the pristine bytes and the committed image on ANY
# exit, including TERM/INT.
restore_pristine() {
  for f in $MUTABLE; do
    [ -f "$PRISTINE/$(basename "$f")" ] && cp "$PRISTINE/$(basename "$f")" "$f"
  done
  [ -f "$PRISTINE/$(basename "$IMAGE")" ] && cp "$PRISTINE/$(basename "$IMAGE")" "$IMAGE"
  return 0
}
cleanup() {
  restore_pristine
  rm -rf "$TMP" "$PRISTINE"
}
# A trapped signal must NOT fall back into the script: bash continues after a
# TERM trap returns, so the interrupted case was still running its normal path
# and hit the now-deleted snapshot ("RESTORE FAILED", then exit 3). Restore,
# disarm the traps, and exit with the signal status.
on_signal() {
  cleanup
  trap - EXIT INT TERM
  exit 143
}
trap cleanup EXIT
trap on_signal INT TERM

# ---------------------------------------------------------------- mutation 1
# SAMPLE THE WRONG EDGE. Move the master's MISO sample from after the rising
# edge to before it (read the pin one instruction earlier). On a real mode-0
# bus the slave's previous bit is still on MISO at that instant, so the byte
# comes back shifted by one position.
#
# This is the mutation that tests the TB's central claim. If the TB cannot see
# a wrong sample edge, its "MSB-first, correct byte" check is decorative.
cat > "$TMP/m1.py" <<'PY'
import pathlib, re, sys
p = pathlib.Path('firmware/spi_xfer.pe')
t = p.read_text()
# The sample is `IN A, PIN` immediately after the SCLK-rise write. Swapping it
# with the preceding line moves the sample before the rise.
lines = t.split('\n')
for i, l in enumerate(lines):
    if 'IN    A, PIN' in l and i > 0 and 'OR    A, 1' in lines[i-1]:
        sys.exit("sample point is not where the mutation expects it")
# find the rise block and hoist the sample above it
pat = re.compile(r'( *)(; ---- sample MISO \(bit 3\).*?\n)( *)(IN    A, PIN)\n( *)(AND   A, 8)\n',
                 re.S)
m = pat.search(t)
if not m:
    sys.exit("could not locate the MISO sample block")
print("  moved the MISO sample before the SCLK rise")
# Replace the rise+sample with sample+rise
rise = """        IN    A, PIN
        OR    A, 1
        OUT   TXPIN, A

"""
sample = m.group(0)
newblock = "        " + m.group(4) + "\n" + "        " + m.group(6) + "\n" + rise
t = t.replace(rise + sample, newblock)
p.write_text(t)
PY

# ---------------------------------------------------------------- mutation 2
# BREAK THE BIT ORDER. Reverse the transmit shift so the master sends LSB
# first. Every byte the slave decodes becomes its bit-reverse (0x5B -> 0xDA),
# which is exactly what the non-palindromic test bytes were chosen to expose.
cat > "$TMP/m2.py" <<'PY'
import pathlib, sys
p = pathlib.Path('firmware/spi_xfer.pe')
t = p.read_text()
old = """        LDM   A, 12
        MOV   X, A
        AND   A, 0x80              ; isolate the MSB"""
if old not in t:
    sys.exit("transmit shift anchor not found")
# AND 0x80 -> AND 0x01: transmit the LSB first instead of the MSB.
t = t.replace(old, old.replace("AND   A, 0x80", "AND   A, 0x01"), 1)
print("  transmit shift: MSB-first -> LSB-first (AND 0x80 -> AND 0x01)")
p.write_text(t)
PY

# ---------------------------------------------------------------- mutation 3
# BREAK THE FRAME BOUNDARY. Hold CS_N low between frames (drop the deassert).
# The slave then sees one long selection instead of N frames, so the frame
# count and the per-frame byte checks both collapse.
cat > "$TMP/m3.py" <<'PY'
import pathlib, sys
p = pathlib.Path('firmware/spi_xfer.pe')
t = p.read_text()
old = """        ; ---- frame complete -------------------------------------------
        ; Deassert CS_N and leave SCLK low, which is the mode 0 idle state.
        IN    A, PIN
        OR    A, 4                 ; CS_N high
        OUT   TXPIN, A"""
if old not in t:
    sys.exit("frame-complete anchor not found")
new = """        ; MUTANT: CS_N is never deasserted, so frames run together.
        IN    A, PIN
        OUT   TXPIN, A"""
t = t.replace(old, new, 1)
print("  CS_N deassert removed: frames run together")
p.write_text(t)
PY

# ---------------------------------------------------------------- mutation 4
# BREAK THE RESPONSE PATH, on the RTL side. Force the SoC's pin read to ignore
# the released-pin (input) half, so MISO comes back 0 forever. The master then
# stores 0x00 in every slot instead of the slave's bytes.
cat > "$TMP/m4.py" <<'PY'
import pathlib, re, sys
p = pathlib.Path('rtl/pe_uart_soc.v')
t = p.read_text()
m = re.search(r'assign pin_rd = [^;]+;', t)
if not m:
    sys.exit("pin_rd assignment not found")
print(f"  pin_rd: {m.group(0)[:40]}... -> all-zero (inputs invisible)")
t = t[:m.start()] + "assign pin_rd = 8'h00;" + t[m.end():]
p.write_text(t)
PY

# ---------------------------------------------------------------- mutation 5
# BREAK THE IDLE-LEVEL CLAIM. Remove the firmware's explicit idle pattern, so
# SCLK inherits the reset value -- which is HIGH (the UART's idle TX level).
# In SPI a high SCLK at rest is an ACTIVE edge level, so the TB's idle-level
# check must fail. This mutation is the reason that check exists: the reset
# value serves the RESIDENT protocol, and every other protocol's firmware has
# to state its own.
cat > "$TMP/m5.py" <<'PY'
import pathlib, sys
p = pathlib.Path('firmware/spi_xfer.pe')
t = p.read_text()
old = """        LDI   A, 4
        OUT   TXPIN, A             ; CS_N = 1, SCLK = 0, MOSI = 0"""
if old not in t:
    sys.exit("idle-pattern anchor not found")
t = t.replace(old, """        ; MUTANT: no idle pattern written; SCLK keeps the reset value (HIGH).
        LDI   A, 0
        OUT   TXPIN, A""", 1)
print("  idle pattern removed: SCLK inherits the reset (UART) level")
p.write_text(t)
PY

run_case "master samples MISO before the SCLK rise"          "$TMP/m1.py"
run_case "transmit shifts LSB-first instead of MSB-first"    "$TMP/m2.py"
run_case "CS_N never deasserted between frames"              "$TMP/m3.py"
run_case "pin read ignores the input half (MISO stuck 0)"    "$TMP/m4.py"
run_case "no explicit SCLK idle pattern (inherits reset)"     "$TMP/m5.py"

echo "================================================================"
echo "SPI TB mutations: $detected detected, $survived survived, $inconclusive inconclusive"

if [ "$inconclusive" -ne 0 ]; then
  echo "FAIL: an inconclusive mutation means the harness could not test it."
  exit 1
fi
if [ "$survived" -ne 0 ]; then
  echo "FAIL: $survived mutation(s) survived -- the TB has a blind spot."
  exit 1
fi
echo "OK: every mutation was detected, so the TB is not vacuous."
