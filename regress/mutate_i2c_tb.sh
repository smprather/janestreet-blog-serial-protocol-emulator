#!/usr/bin/env bash
# Mutation-test tb_pe_soc_i2c.v: it must FAIL when the properties it claims
# break. A testbench that passes on broken RTL is worse than no testbench,
# because it manufactures confidence.
#
# THREE OUTCOMES, NOT TWO. A mutation is only meaningful if the mutated design
# actually BUILT. Reporting "not detected" when the compile failed would be a
# false accusation against the TB -- and would hide a genuinely surviving
# mutation behind an unrelated build error. So a compile failure is
# INCONCLUSIVE, reported as such, and fails the run.
#
# Usage: regress/mutate_i2c_tb.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"

# The SRAM behavioural model, via the same helper run_all.sh uses, and BEFORE
# run_case() because the compile line inside it needs the variable. Compiling
# without it silently falls back to pe_imem's FLOP array, which would mean the
# mutation test exercised a different memory than the one that ships.
if ! SRAM_MODEL=$(cd sim && ../regress/sram_model.sh); then
  echo "FATAL: SRAM behavioural model unavailable; cannot simulate the SoC."
  exit 2
fi
SRAM_FLAGS=$(printf '%s ' $SRAM_MODEL)

detected=0
inconclusive=0
survived=0

# Files any mutation may touch, for the snapshot/restore.
MUTABLE="rtl/pe_soc.v rtl/pe_pinmux.v firmware/i2c_pins.pe firmware/i2c_pins.hex firmware/uart_echo.hex"

# The pristine snapshot every restore is verified against. NOT git: a harness
# must work in a `git archive` clone (which has no .git at all) and must not
# call a legitimate uncommitted change a failed restore -- measured both ways
# on the fresh-clone regression the review runs.
PRISTINE=$(mktemp -d)
for f in $MUTABLE; do cp "$f" "$PRISTINE/"; done
# The assembled image is committed too, and a mutation run regenerates it
# from the mutated source. Snapshot it as well so an interrupted run can
# put BOTH back byte-exactly (review 2 R2-7).
IMAGE=firmware/i2c_pins.hex
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
    python3 tools/fw/peasm.py firmware/i2c_pins.pe -o firmware/i2c_pins.hex >/dev/null 2>&1
  }


  # ---- restore VERIFICATION -------------------------------------------------
  # A mutation harness that fails to restore leaves MUTATED RTL on disk, and
  # every subsequent test run then quietly tests the mutant. That happened during
  # development and produced a full regression run reporting failures in the
  # firmware and the SPI testbench -- both of which were really reporting the
  # leftover mutation. The verdict was nonsense and it looked like a real
  # regression, which is the worst kind of wrong answer: loud and misleading.
  #
  # So the restore is VERIFIED, per case, against a PRISTINE SNAPSHOT: are the
  # mutable files byte-identical to the ones this run started from?
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

  python3 tools/fw/peasm.py firmware/i2c_pins.pe -o firmware/i2c_pins.hex >/dev/null 2>&1

  # Compile into a temp dir under a name unique to this case, so a stale vvp
  # from a previous case can never be executed by accident. -s names the REAL
  # top module (the TB), not a wrapper.
  local work; work=$(mktemp -d)
  local top="tb_pe_soc_i2c"
  # iverilog prints "sorry:" notices (unsupported-but-tolerated constructs) to
  # stderr and still exits 0. Gating on the exit code rather than on the
  # chatter is the difference between "the mutation broke the build" and
  # "Icarus grumbled".
  #
  # The vvp file is the second, independent signal: whatever iverilog says,
  # there is nothing to run if it did not produce output. Both are checked
  # explicitly -- the previous shorthand (`if ! compile && [ ! -s vvp ]`)
  # bound the && to the whole negated expression, so a compile that SUCCEEDED
  # with a non-empty vvp still took the "did not compile" branch.
  local cc=0
  (cd sim && iverilog -g2012 -s "$top" -o "$work/$top.vvp" $SRAM_FLAGS \
      ../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v \
      ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v \
      ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v \
      ../tb/tb_pe_soc_i2c.v) >"$work/compile.log" 2>&1 || cc=$?
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

  # RUN FROM sim/. The TB does $readmemh("../firmware/i2c_pins.hex"), which only
  # resolves from sim/ -- running vvp from the repo root silently loads nothing,
  # the program is all NOP fill, no pins ever move, and EVERY mutation then
  # looks "detected" for the same wrong reason. That is what the first version
  # of this script did: five mutations reported DETECTED with byte-identical
  # failures, which is the signature of a broken harness, not a good test.
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
  # THE HARNESS-EDIT PRE-FLIGHT (regress/dep_guard.sh). Stamped when this
  # harness took the run lock; verified HERE, because this is the only place it
  # can be: the harness sets its own `trap cleanup EXIT` after sourcing
  # run_lock.sh, and a second EXIT trap replaces the first, so a check installed
  # over there would be silently discarded. If this script — or the lock helper it
  # sources — changed while we were running, bash's incremental read means our
  # verdict is untrustworthy in EITHER direction, so exit 4 (INCONCLUSIVE) rather
  # than report a possibly-false pass.
  chip_dep_check "run_$(basename "$0")" || exit 4
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
# Break the OD gate in pe_pinmux: make pad_oe ignore the od term, so a pin in
# open-drain mode CAN drive high. tb_pe_soc_i2c asserts this never happens, on
# the RTL's own pin_oe output.
cat > "$TMP/m1.py" <<'PY'
import pathlib, re, sys
p = pathlib.Path('rtl/pe_pinmux.v')
t = p.read_text()
m = re.search(r'assign\s+pad_oe\s*=\s*([^;]+);', t)
if not m:
    sys.exit("no pad_oe assignment found")
print(f"  pad_oe: {m.group(1).strip()!r} -> 'reg_oe' (od term removed)")
t = t[:m.start()] + "assign pad_oe  = reg_oe;" + t[m.end():]
p.write_text(t)
PY
run_case "pe_pinmux: OD gate ignores od (a pin could drive high)" "$TMP/m1.py"

# ---------------------------------------------------------------- mutation 2
# Swap the port->register translation so PINOUT writes land in the OE register
# -- the exact identity-map bug that hung the UART during this refactor.
cat > "$TMP/m2.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_soc.v')
t = p.read_text()
old = """      4'h1:    begin pinmux_waddr = A_OUT; pinmux_we = io_we; end
      4'h2:    begin pinmux_waddr = A_OE;  pinmux_we = io_we; end"""
if old not in t:
    sys.exit("port decode anchor not found")
new = """      4'h1:    begin pinmux_waddr = A_OE;  pinmux_we = io_we; end
      4'h2:    begin pinmux_waddr = A_OUT; pinmux_we = io_we; end"""
p.write_text(t.replace(old, new))
print("  ports 1 and 2 swapped")
PY
run_case "pe_soc: PINOUT and PINOE writes swapped" "$TMP/m2.py"

# ---------------------------------------------------------------- mutation 3
# Break the read-back generalisation: use the OE REGISTER instead of the real
# drive enable, so a pin released by the OD gate still reads back our written
# level. That is the bug the generalised pin_rd exists to avoid, and it makes
# arbitration and clock stretching invisible.
cat > "$TMP/m3.py" <<'PY'
import pathlib, re, sys
p = pathlib.Path('rtl/pe_soc.v')
t = p.read_text()
m = re.search(r'assign\s+pin_rd\s*=\s*([^;]+);', t)
if not m:
    sys.exit("no pin_rd assignment found")
# NB: the signal is `pin_out` (the registered output byte), not `pin_driven` --
# the first version of this mutation used a name that does not exist in the RTL,
# so it failed to elaborate and the case reported INCONCLUSIVE instead of
# telling us anything about the TB.
t = t[:m.start()] + ("assign pin_rd   = (pin_out & pinmux_rdata) | "
                     "(pin_in & ~pinmux_rdata);") + t[m.end():]
p.write_text(t)
PY
run_case "pe_soc: pin_rd uses the OE register, not the OD gate (I2C TB; expected to survive, see note)" "$TMP/m3.py"
# ^ EXPECTED SURVIVOR, and it is counted as one: see mutation 3b below for why
#   the I2C test cannot see this one and which test does.

# ---------------------------------------------------------------- mutation 3b
# The same mutation, seen from the UART side. This case exists because mutation 3
# SURVIVES tb_pe_soc_i2c and that needs explaining rather than papering over.
#
# WHY IT SURVIVES THERE: on a port-0 read the matrix's raddr defaults to A_IN,
# so pinmux_rdata IS pin_in. For the I2C firmware -- which releases every pin it
# reads -- the mutated expression therefore evaluates to the same thing as the
# real one, and the mutation is near-equivalent for that test.
#
# WHY IT IS STILL A REAL BUG, and is caught elsewhere: the UART firmware does
# read-modify-write on the port while DRIVING its TX pin push-pull, so reading
# the pad instead of the register breaks its convergence -- tb_pe_soc_uart
# hangs on the mutation ("watchdog -- firmware still running"). That is a worse
# failure mode than an assertion, but it is detection.
cat > "$TMP/m3b.py" <<'PY'
import pathlib, re
p = pathlib.Path('rtl/pe_soc.v')
t = p.read_text()
m = re.search(r'assign\s+pin_rd\s*=\s*([^;]+);', t)
if not m:
    raise SystemExit("no pin_rd assignment found")
t = t[:m.start()] + ("assign pin_rd   = (pin_out & pinmux_rdata) | "
                     "(pin_in & ~pinmux_rdata);") + t[m.end():]
p.write_text(t)
PY

echo "=== mutation: pin_rd (via the UART, which does read-modify-write) ==="
backup=$(mktemp -d)
cp rtl/pe_soc.v firmware/uart_echo.pe "$backup/"
python3 "$TMP/m3b.py" >/dev/null
work=$(mktemp -d)
cc=0
(cd sim && iverilog -g2012 -s tb_pe_soc_uart -o "$work/u.vvp" $SRAM_FLAGS \
    ../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v \
    ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v \
    ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v \
    ../tb/tb_pe_soc_uart.v) >"$work/c.log" 2>&1 || cc=$?
if [ "$cc" -ne 0 ]; then
  echo "  INCONCLUSIVE: did not compile"
  inconclusive=$((inconclusive+1))
else
  if (cd sim && vvp "$work/u.vvp" 2>&1) | grep -qE '^FAIL|watchdog'; then
    echo "  DETECTED (the UART TB fails or hangs on the mutated read-back)"
    detected=$((detected+1))
  else
    echo "  SURVIVED -- neither SoC test catches this mutation (real blind spot)"
    survived=$((survived+1))
  fi
fi
rm -rf "$work"
cp "$backup/pe_soc.v" rtl/; cp "$backup/uart_echo.pe" firmware/
rm -rf "$backup"
python3 tools/fw/peasm.py firmware/uart_echo.pe -o firmware/uart_echo.hex >/dev/null 2>&1
echo

# ---------------------------------------------------------------- mutation 4
# Firmware: drop the OD write. The pins then drive push-pull, so a pin holding 1
# is driven HIGH and the read-back is our own level rather than the pad.
cat > "$TMP/m4.py" <<'PY'
import pathlib, sys
p = pathlib.Path('firmware/i2c_pins.pe')
t = p.read_text()
old = """        LDI   A, SDA|SCL           ; 0x30
        OUT   PINOD, A"""
if old not in t:
    sys.exit("PINOD write anchor not found")
p.write_text(t.replace(old, """        LDI   A, 0x00              ; MUTATED: stays push-pull
        OUT   PINOD, A""", 1))
print("  firmware no longer enters open-drain mode")
PY
run_case "firmware: never sets OD (stays push-pull)" "$TMP/m4.py"

# ---------------------------------------------------------------- mutation 5
# Firmware: make the STOP drive SDA low while SCL is high (the spurious-START
# bug that the pad monitors exist to catch).
cat > "$TMP/m5.py" <<'PY'
import pathlib, sys
p = pathlib.Path('firmware/i2c_pins.pe')
t = p.read_text()
old = """        LDI   A, SCL               ; SCL released, SDA held low
        OUT   TXPIN, A"""
if old not in t:
    sys.exit("STOP setup anchor not found")
# The spurious START is generated in isolation and then undone, so the mutation
# tests ONE thing: an extra SDA falling edge while SCL is high. Leaving SDA low
# afterwards would ALSO break the STOP, and the mutation would then be caught by
# the STOP check rather than by the stray-condition check.
#
# This is a genuinely undetected defect in the RTL TB as first written: the
# standalone timing checker (tools/checks/i2c_timing.py) catches it, but the
# RTL TB only counts conditions, and the counts stay 1/1 here because the extra
# START is paired with a spurious STOP. The TB now counts CONDITIONS, which is
# what this mutation is for.
new = """        LDI   A, SDA|SCL
        OUT   TXPIN, A
        LDI   A, SCL
        OUT   TXPIN, A
        LDI   A, SDA|SCL
        OUT   TXPIN, A
        LDI   A, SCL
        OUT   TXPIN, A"""
p.write_text(t.replace(old, new, 1))
print("  extra START+STOP pair injected under SCL-high")
PY
run_case "firmware: spurious START before the STOP" "$TMP/m5.py"

# ---------------------------------------------------------------- mutation 6
# Firmware: shorten the bit cell's low period below the tLOW floor. The RTL TB
# does not measure tLOW (tools/checks/i2c_timing.py does), so this checks
# whether that division of labour leaves a real gap in the RTL test.
cat > "$TMP/m6.py" <<'PY'
import pathlib, sys
p = pathlib.Path('firmware/i2c_pins.pe')
t = p.read_text()
old = "        ADD   A, T_LOW             ; 6 ticks"
if old not in t:
    sys.exit("T_LOW anchor not found")
p.write_text(t.replace(old, "        ADD   A, 2                 ; MUTATED: below the floor"))
print("  tLOW shortened to 2 ticks")
PY
run_case "firmware: tLOW shortened below the spec floor" "$TMP/m6.py"

echo "========================================"
echo "MUTATION TEST: $detected detected, $survived survived, $inconclusive inconclusive"
# ONE survivor is EXPECTED and is explained in the comments above mutation 3:
# the I2C test cannot see a read-back mutation because on a port-0 read the
# matrix returns pin_in anyway, so the mutated expression is equivalent for a
# firmware that only reads pins it has released. Mutation 3b shows the UART test
# does catch it. Asserting the exact expected count keeps this honest: an
# unexpected survivor still fails, and so does the covered one silently becoming
# covered (which would mean the I2C path stopped being equivalent, i.e. a real
# behaviour change nobody intended).
EXPECTED_SURVIVED=1
if [ "$survived" -eq "$EXPECTED_SURVIVED" ] && [ "$inconclusive" -eq 0 ]; then
  echo "no unexplained survivors -- all mutations accounted for"
  exit 0
elif [ "$survived" -ne "$EXPECTED_SURVIVED" ]; then
  echo "SURVIVOR COUNT CHANGED (expected $EXPECTED_SURVIVED, got $survived)"
  echo "either the TB lost coverage or the design changed behaviour; investigate"
  exit 1
else
  echo "RUN INCONCLUSIVE -- a mutated design failed to build"
  exit 2
fi
