#!/usr/bin/env bash
# mutate_ctrl_tb.sh — mutation-test tb_pe_ctrl.v.
#
# The loader is the only way a program reaches silicon, so every claim its TB
# makes must be able to fail. Each mutation is a plausible implementation
# choice in pe_ctrl.v; the TB must notice every one.
#
# RESTORE IS A FILE COPY, verified after every mutation — a failed restore
# stacks mutations and reports a meaningless perfect score (the eth_mac
# harness lesson).
#
# ONE EQUIVALENT MUTATION IS DELIBERATELY ABSENT. Removing the W_PULSE run
# abort is not observable: the `host_we = we_r & ~run` mask stops the write and
# the W_DONE run check discards the word, so the queued-word cases still pass.
# The three run mechanisms are defence in depth; each of the others has its own
# detectable mutation below (idle-abort, host-we-mask, done-run-check).
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
RTL="$ROOT/rtl/pe_ctrl.v"
TB="$ROOT/tb/tb_pe_ctrl.v"
SRCS="../rtl/pe_ctrl.v $TB"
LOG=/tmp/mutate_ctrl.log
BAK=$(mktemp /tmp/pe_ctrl.XXXXXX.v)

cleanup() { cp "$BAK" "$RTL" 2>/dev/null; rm -f "$BAK"; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"
cp "$RTL" "$BAK"
cmp -s "$RTL" "$BAK" || { echo "FATAL: could not snapshot $RTL"; exit 2; }

pass=0; fail=0; survived=0

run_tb() {
  iverilog -g2012 -s tb_pe_ctrl -o /tmp/mut_ctrl.vvp $SRCS >/tmp/mut_ctrl_cc.log 2>&1 || return 2
  timeout 120 vvp /tmp/mut_ctrl.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

restore() { cp "$BAK" "$RTL"; }
verify_restore() {
  cmp -s "$BAK" "$RTL" || { echo "  FATAL: $RTL does not match the snapshot after restore."; exit 3; }
}

mutate() {
  python3 - "$RTL" "$1" "$2" <<'PYEOF'
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

echo "=== mutation-testing tb_pe_ctrl ==="
run_tb
if [ $? -ne 0 ]; then echo "  FATAL: the TB does not pass on the clean design"; exit 2; fi
echo "  [baseline] passes on the unmutated design"

# 1. Bit order: assemble the other way (LSB-first). 0xA55A catches it.
check_mutation "lsb-first" \
  "          word_data  <= {shreg[14:0], mosi_s1};" \
  "          word_data  <= {mosi_s1, shreg[14:0]};   // MUTANT: LSB-first"

# 2. Word boundary: 15 bits per word instead of 16.
check_mutation "short-word" \
  "        if (bit_cnt == 4'd15) begin" \
  "        if (bit_cnt == 4'd14) begin   // MUTANT: 15-bit words"

# 3. The CS reset: a second load continues where the last one stopped.
check_mutation "no-cs-reset" \
  "        addr          <= '0;
        bit_cnt       <= '0;
        shreg         <= '0;
        word_ready    <= 1'b0;
        words_written <= '0;" \
  "        bit_cnt       <= '0;
        shreg         <= '0;
        word_ready    <= 1'b0;
        words_written <= '0;   // MUTANT: no address reset"

# 4. The receive run gate: bits are accepted while the core executes.
check_mutation "run-gate" \
  "      if (sclk_rise && !run && !cs_s1 && !word_ready && !load_error) begin" \
  "      if (sclk_rise && !cs_s1 && !word_ready && !load_error) begin   // MUTANT: no run gate"

# 5. Address increment: every word lands on word 0.
check_mutation "stuck-address" \
  "            addr   <= addr + 1'b1;" \
  "            addr   <= addr;   // MUTANT: address never advances"

# 6. The write pulse: completed words are never handed to the SoC.
check_mutation "no-write-pulse" \
  "            we_r   <= 1'b1;
            wstate <= W_DONE;" \
  "            we_r   <= 1'b0;   // MUTANT: no host write
            wstate <= W_DONE;"

# 7. The partial-word flag: a load ending mid-word is silently discarded.
check_mutation "partial-word-flag" \
  "        if (bit_cnt != 4'd0) load_error <= 1'b1;" \
  "        ;   // MUTANT: partial word not flagged"

# 8. The oversize guard: a long load wraps over word 0.
check_mutation "wraparound" \
  "            if (addr == AW'(WORDS - 1)) begin
              load_error <= 1'b1;      // more words than instruction memory
              wstate     <= W_IDLE;
            end else begin
              addr   <= addr + 1'b1;
              wstate <= W_IDLE;
            end" \
  "            addr   <= addr + 1'b1;
            wstate <= W_IDLE;   // MUTANT: wraps over word 0"

# 9. The W_IDLE run abort: a queued-but-unstarted word waits for run to fall
#    and then writes stale program data.
check_mutation "idle-abort" \
  "          if (word_ready) begin
            if (run) begin
              word_ready <= 1'b0;
              load_error <= 1'b1;      // aborted: the image is incomplete
            end else begin
              wstate <= W_PULSE;
            end
          end" \
  "          if (word_ready && !run) wstate <= W_PULSE;   // MUTANT: no idle abort"

# 10. The host_we run mask: a run that rises inside W_DONE reaches the SoC.
check_mutation "host-we-mask" \
  "  assign host_we       = we_r & ~run;" \
  "  assign host_we       = we_r;   // MUTANT: no run mask"

# 11. The W_DONE run abort: a masked word is still counted and reported clean.
check_mutation "done-run-check" \
  "          if (run) begin
            // run rose at the sampling edge: host_we was masked, so nothing
            // was written and nothing is counted.
            load_error <= 1'b1;
            wstate     <= W_IDLE;
          end else begin" \
  "          if (1'b0) begin   // MUTANT: no run abort in W_DONE
            load_error <= 1'b1;
            wstate     <= W_IDLE;
          end else begin"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
[ $survived -gt 0 ] && { echo "SURVIVORS: the TB does not test what it claims."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every mutation is detected by tb_pe_ctrl."
exit 0
