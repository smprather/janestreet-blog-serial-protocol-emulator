#!/usr/bin/env bash
# mutate_eth_soc_tb.sh — mutation-test tb_pe_soc_eth.v.
#
# The TB is the only thing that proves a PROGRAM can consume a frame, so every
# check it makes must be able to fail. Each mutation below is a plausible
# implementation choice somebody could write in pe_soc.v; the TB must notice
# every one.
#
# RESTORE IS A FILE COPY, NOT `git checkout`. rtl/pe_soc.v may be mid-edit,
# and a failed restore STACKS mutations -- which is how the first eth_mac
# harness reported "8 detected, 0 survived" and meant nothing.
set -u
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
RTL="$ROOT/rtl/pe_soc.v"
TB="$ROOT/tb/tb_pe_soc_eth.v"
SRAM_MODEL=$("$ROOT/regress/sram_model.sh")
SRCS="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v $SRAM_MODEL $TB"
LOG=/tmp/mutate_eth_soc.log
BAK=$(mktemp /tmp/pe_soc.XXXXXX.v)

# EVERY file this harness can mutate is snapshotted, not just pe_soc.v. The
# I2C suite's m1 survivor (2026-09-24 18:43) and a local rerun interrupted
# mid-case (2026-09-25 06:51) both left a MUTANT on disk because the file they
# touched was not in the backup set: a killed harness cannot restore what it
# never copied, and a stale mutant then makes every later run report nonsense.
# The mutation list below is the contract -- if a mutation is added here, its
# file must be in MUTABLE.
MUTABLE="rtl/pe_soc.v rtl/pe_eth_mac.v"
PRISTINE=$(mktemp -d /tmp/pristine_eth_soc.XXXXXX)

cleanup() {
  for f in $MUTABLE; do cp "$PRISTINE/$(basename "$f")" "$ROOT/$f" 2>/dev/null; done
  rm -f "$BAK"
  rm -rf "$PRISTINE"
  rmdir "$ROOT/sim" 2>/dev/null
}
on_signal() {
  cleanup
  trap - EXIT INT TERM
  exit 143
}
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"

cp "$RTL" "$BAK"
for f in $MUTABLE; do
  cp "$ROOT/$f" "$PRISTINE/$(basename "$f")"
  if ! cmp -s "$ROOT/$f" "$PRISTINE/$(basename "$f")"; then
    echo "FATAL: could not snapshot $f"
    exit 2
  fi
done

pass=0
fail=0
survived=0

run_tb() {
  if ! iverilog -g2012 -s tb_pe_soc_eth -o /tmp/mut_eth_soc.vvp $SRCS \
       >/tmp/mut_eth_soc_cc.log 2>&1; then
    return 2
  fi
  timeout 300 vvp /tmp/mut_eth_soc.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

restore() {
  for f in $MUTABLE; do cp "$PRISTINE/$(basename "$f")" "$ROOT/$f"; done
  cp "$BAK" "$RTL"
}

verify_restore() {
  for f in $MUTABLE; do
    if ! cmp -s "$PRISTINE/$(basename "$f")" "$ROOT/$f"; then
      echo "  FATAL: $f does not match the pristine snapshot after restore."
      exit 3
    fi
  done
}

mutate() {
  local from="$1" to="$2"
  python3 - "$RTL" "$from" "$to" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
frm, to = sys.argv[2], sys.argv[3]
if frm not in t:
    sys.exit(4)
p.write_text(t.replace(frm, to, 1))
PYEOF
}

check_mutation() {
  local name="$1"; shift
  local from="$1"; shift
  local to="$1"; shift
  if ! mutate "$from" "$to"; then
    echo "  [$name] HARNESS ERROR: anchor not found"
    restore; fail=$((fail+1)); return
  fi
  run_tb
  local rc=$?
  if [ $rc -eq 0 ]; then
    echo "  [$name] SURVIVED (the TB did not notice -- it is vacuous here)"
    survived=$((survived+1))
  elif [ $rc -eq 1 ]; then
    echo "  [$name] detected"
    pass=$((pass+1))
  else
    fail=$((fail+1))
  fi
  restore
  verify_restore
}

echo "=== mutation-testing tb_pe_soc_eth ==="

run_tb
if [ $? -ne 0 ]; then
  echo "  FATAL: the TB does not pass on the clean design; fix that first."
  exit 2
fi
echo "  [baseline] passes on the unmutated design"

# 1. The window starts one byte late: the checksum misses the first byte and
#    folds one past the frame.
check_mutation "window-starts-one-late" \
  "        eth_buf_raddr <= eth_frame_start;" \
  "        eth_buf_raddr <= eth_frame_start + 1'b1;   // MUTANT: skips a byte"

# 2. The window never advances: firmware reads the same byte 46 times.
check_mutation "window-never-advances" \
  "      if (bufbyte_rd && !eth_frame_valid)
        eth_buf_raddr <= eth_buf_raddr + 1'b1;" \
  "      if (1'b0)
        eth_buf_raddr <= eth_buf_raddr + 1'b1;   // MUTANT: no advance"

# 3. The length latched from the wrong register.
check_mutation "len-from-field" \
  "        eth_len       <= eth_frame_len;" \
  "        eth_len       <= eth_frame_field;   // MUTANT: wrong register"

# 4. A frame is never announced, so firmware never proceeds (watchdog).
check_mutation "never-valid" \
  "        eth_valid     <= 1'b1;" \
  "        eth_valid     <= 1'b0;   // MUTANT: the frame is never announced"

# 5. The type/length split is lost; the TB checks the EtherType high byte.
check_mutation "is-type-lost" \
  "        eth_is_type   <= eth_frame_is_type;" \
  "        eth_is_type   <= 1'b0;   // MUTANT: every frame reads as a length"

# 6. Rejected frames become invisible; the TB waits on dmem[8].
check_mutation "bad-not-flagged" \
  "      if (eth_frame_bad) eth_bad <= 1'b1;" \
  "      if (1'b0) eth_bad <= 1'b1;   // MUTANT: rejects are invisible"

# 7. valid is a permanent latch: firmware re-walks frame 1 forever and never
#    sees the bad frame (watchdog).
check_mutation "status-never-clears" \
  "        if (!eth_frame_valid) eth_valid <= 1'b0;" \
  "        if (1'b0) eth_valid <= 1'b0;   // MUTANT: valid never clears"

# 8. The reclaim is destructive again (the E1 bug): BUFCTRL pulses the MAC's
#    whole-ring reset. The permanent consecutive-frame case reads xx.
check_mutation "destructive-reclaim" \
  "    .buf_reset(1'b0),              // the SoC never whole-ring-resets in traffic" \
  "    .buf_reset(eth_buf_consume),   // MUTANT: destructive reclaim in traffic"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
if [ $survived -gt 0 ]; then
  echo "SURVIVORS: the TB does not test what it claims for the mutations above."
  exit 1
fi
if [ $fail -gt 0 ]; then
  echo "HARNESS ERRORS: fix the harness before trusting these numbers."
  exit 1
fi
echo "OK: every mutation is detected by tb_pe_soc_eth."
exit 0
