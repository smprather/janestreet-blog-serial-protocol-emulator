#!/usr/bin/env bash
# mutate_eth_tx_loop_tb.sh — mutation-test the INTEGRATION around the 10BASE-T
# TX frame path: tb/tb_pe_soc_eth_loop.v (the SoC wire loopback) and the
# pad-level case in tb/tb_tt_um_protocol_emulator.v
# (wiki/plans/eth-tx-frame-path.md G8 / Review Focus 6-8).
#
# WHY THIS EXISTS. The unit TB proves the ENGINE. These mutations are the
# failures that live BETWEEN the blocks, where every individual block can be
# correct and the frame still never reaches the wire (or arrives broken):
#
#   1. owner-mux-stuck-serdes — u_tx_codec.tx_bit is the SERDES bit whatever
#                              tx_path says, so a frame is never encoded
#                              (Review Focus 7: the owner mux must be
#                              EXCLUSIVE).
#   2. overlay-not-driven     — eng_ov_en never selects pin 7, so the frame
#                              is generated but the pad keeps the firmware
#                              level: TX looks perfect at the engine and the
#                              receiver sees nothing.
#   3. pad-not-mapped          — the wrapper's G6 mux ignores the matrix, so
#                              uo_out[2] stays dbg_pc[0] and the real pad
#                              carries garbage (Review Focus 8). This one is
#                              only visible at the PAD, so it runs the
#                              wrapper TB, not the loop TB.
#   4. cell-start-doubled     — the engine advances at the half-cell rate as
#                              well as the cell boundary, so the Manchester
#                              halves are not three clean clocks and the DRU
#                              cannot frame them.
#   5. rx-capture-disconnected— the strobe that captures the looped-back frame
#                              into the MAC is tied off, so the receiver
#                              never completes a frame.
#   6. fcs-verdict-wrong-convention
#                            — the MAC's verdict compares the register to
#                              zero (the crc_zero convention) instead of the
#                              residue, so a corrupt frame is ACCEPTED.
#   7. push-wrap-into-ctrl    — the window's push bank no longer wraps at 23,
#                              so the 9th push writes TXLENL (index 24) and
#                              a burst lands in CTRL (Review Focus 5).
#
# RESTORE IS A FILE COPY with a cmp-verified pristine snapshot, restored after
# EVERY mutation, plus EXIT/INT/TERM traps (the 2026-09-24 18:43 OOM killed a
# suite mid-mutation and left the mutant on disk; the snapshot dir below is
# the recovery path). `git checkout` is never used (gotcha 63).
set -u
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"
ROOT="$PWD"
SOC="$ROOT/rtl/pe_soc.v"
MAC="$ROOT/rtl/pe_eth_mac.v"
TOP="$ROOT/rtl/tt_um_protocol_emulator.v"
LOG=/tmp/mutate_eth_tx_loop.log
CCLOG=/tmp/mutate_eth_tx_loop_cc.log
PRISTINE=$(mktemp -d /tmp/pristine_eth_tx_loop.XXXXXX)
BAK=$(mktemp -d /tmp/backup_eth_tx_loop.XXXXXX)

MUTABLE="rtl/pe_soc.v rtl/pe_eth_mac.v rtl/tt_um_protocol_emulator.v"

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
  for f in $MUTABLE; do cp "$BAK/$(basename "$f")" "$ROOT/$f" 2>/dev/null; done
  rm -rf "$BAK"
}
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"
for f in $MUTABLE; do
  cp "$ROOT/$f" "$PRISTINE/$(basename "$f")"
  cp "$ROOT/$f" "$BAK/$(basename "$f")"
  cmp -s "$ROOT/$f" "$PRISTINE/$(basename "$f")" || { echo "FATAL: could not snapshot $f"; exit 2; }
done

# The TBs read these images through $readmemh; a stale one is a silent pass.
missing=
for hex in eth_arp_echo eth_tx_two eth_tx_wrap_probe eth_tx_busy_probe \
           eth_tx_owner_probe eth_tx_arp spi_xfer; do
  [ -f "$ROOT/firmware/$hex.hex" ] || missing="$missing $hex"
done
if [ -n "$missing" ]; then
  echo "  firmware images missing:$missing - building them first"
  ( cd "$ROOT" && ./regress/run_firmware_tests.sh >/tmp/mut_eth_tx_loop_fw.log 2>&1 ) \
    || { echo "FATAL: could not build the firmware images"; exit 2; }
fi

# Same source lists as run_all.sh's cases.
SOC_SRCS="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v"
TOP_SRCS="$SOC_SRCS ../rtl/pe_ctrl.v ../rtl/tt_um_protocol_emulator.v"

run_loop_tb() {
  local sram
  sram=$(bash "$ROOT/regress/sram_model.sh" 2>/dev/null) || return 2
  iverilog -g2012 -s tb_pe_soc_eth_loop -o /tmp/mut_eth_tx_loop.vvp \
    $SOC_SRCS $sram ../tb/tb_pe_soc_eth_loop.v >"$CCLOG" 2>&1 || return 2
  timeout 600 vvp /tmp/mut_eth_tx_loop.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

run_tt_tb() {
  local sram
  sram=$(bash "$ROOT/regress/sram_model.sh" 2>/dev/null) || return 2
  iverilog -g2012 -s tb_tt_um_protocol_emulator -o /tmp/mut_eth_tx_tt.vvp \
    $TOP_SRCS $sram ../tb/tb_tt_um_protocol_emulator.v >"$CCLOG" 2>&1 || return 2
  timeout 600 vvp /tmp/mut_eth_tx_tt.vvp >"$LOG" 2>&1
  grep -qE "^PASS" "$LOG"
}

restore() { for f in $MUTABLE; do cp "$BAK/$(basename "$f")" "$ROOT/$f"; done; }
verify_restore() {
  for f in $MUTABLE; do
    cmp -s "$PRISTINE/$(basename "$f")" "$ROOT/$f" || {
      echo "  FATAL: $f does not match the pristine snapshot after restore."; exit 3; }
  done
}

mutate() {
  python3 - "$ROOT" "$1" "$2" "$3" <<'PYEOF'
import sys, pathlib
root, rel, old, new = sys.argv[1:5]
p = pathlib.Path(root) / rel
t = p.read_text()
if t.count(old) != 1:
    sys.exit(f"anchor count {t.count(old)} != 1 in {rel}")
p.write_text(t.replace(old, new, 1))
PYEOF
}

pass=0; fail=0; survived=0

# check_mutation <name> <file> <old> <new> <tb: loop|tt>
check_mutation() {
  local name="$1" rel="$2" old="$3" new="$4" tb="$5"
  if ! mutate "$rel" "$old" "$new"; then
    echo "  [$name] HARNESS ERROR: anchor not found/unique in $rel"
    restore; fail=$((fail+1)); return
  fi
  if [ "$tb" = loop ]; then run_loop_tb; else run_tt_tb; fi
  local rc=$?
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected (by $tb)"; pass=$((pass+1))
  else                     echo "  [$name] HARNESS ERROR: exit $rc"; tail -3 "$CCLOG" "$LOG" 2>/dev/null; fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing the eth_tx integration (pristine snapshot: $PRISTINE) ==="
run_loop_tb
rc=$?
if [ $rc -ne 0 ]; then
  echo "  FATAL: tb_pe_soc_eth_loop does not pass on the clean design (exit $rc)"
  [ $rc -eq 2 ] && tail -5 "$CCLOG"
  exit 2
fi
run_tt_tb
rc=$?
if [ $rc -ne 0 ]; then
  echo "  FATAL: tb_tt_um_protocol_emulator does not pass on the clean design (exit $rc)"
  [ $rc -eq 2 ] && tail -5 "$CCLOG"
  exit 2
fi
echo "  [baseline] both TBs pass on the unmutated design"

# 1. The owner mux is stuck on the SERDES: a frame never reaches the codec.
check_mutation "owner-mux-stuck-serdes" "rtl/pe_soc.v" \
  "  assign eth_tx_owner = tx_path ? eth_tx_bit : ser_tx;" \
  "  assign eth_tx_owner = ser_tx;   // MUTANT: owner mux stuck on SERDES" loop

# 1b. FINDING F2's guard removed: a TXCTRL tx_path SET during a live SERDES
# transmission steals the codec mid-frame. tb_pe_soc_eth_loop's owner probe
# records `tx_path && ser_tx_busy` and must fail.
check_mutation "owner-set-guard-removed" "rtl/pe_soc.v" \
  "              if (!ser_tx_busy) tx_path <= 1'b1;" \
  "              tx_path <= 1'b1;   // MUTANT: F2 guard removed" loop

# 2. The pad overlay never selects pin 7: the wire stays at the firmware level.
check_mutation "overlay-not-driven" "rtl/pe_soc.v" \
  "  assign eng_ov_en = eng_en ? (eng_txsel ? 8'h01 : 8'h80) : 8'h00;" \
  "  assign eng_ov_en = 8'h00;   // MUTANT: overlay never driven" loop

# 3. The G6 pad mux ignores the matrix: uo_out[2] is stuck on dbg_pc[0].
#    Pad-level only, so the wrapper TB is the judge.
check_mutation "pad-not-mapped" "rtl/tt_um_protocol_emulator.v" \
  "  assign uo_out[2]   = pin_oe_bus[7] ? pin_out_bus[7] : dbg_pc[0];" \
  "  assign uo_out[2]   = dbg_pc[0];   // MUTANT: G6 pad not mapped" tt

# 4. The engine also advances at the half-cell boundary.
check_mutation "cell-start-doubled" "rtl/pe_soc.v" \
  "  wire eth_cell_start = eng_en && !eng_clr_strb && (cell_div >= 16'd2)
                        && (cell_cnt == cell_div - 16'd1);" \
  "  wire eth_cell_start = eng_en && !eng_clr_strb && (cell_div >= 16'd2)
                        && ((cell_cnt == cell_div - 16'd1)
                            || (cell_cnt == ((cell_div >> 1) - 16'd1)));
                        // MUTANT: advances at the half-cell rate too" loop

# 5. The MAC's capture strobe is tied off: the looped-back frame never
#    completes. (The capture into the MAC is the DRU's per-cell strobe, NOT
#    the RX codec's bit_en -- that one feeds the SERDES, so mutating it
#    leaves this frame path untouched. Found by an earlier draft of this
#    harness, whose `rx-capture-disconnected` mutant SURVIVED.)
check_mutation "rx-capture-disconnected" "rtl/pe_soc.v" \
  "    .bit_en(eth_bit_en), .rx_raw(eth_rx_raw), .rx_err(eth_rx_err)," \
  "    .bit_en(1'b0), .rx_raw(eth_rx_raw), .rx_err(eth_rx_err),   // MUTANT: RX capture disconnected" loop

# 6. The MAC's verdict uses the OTHER convention (crc_zero, i.e. the register
#    reads zero) instead of the residue, so a frame with a wrong FCS is
#    ACCEPTED. pe_eth_mac's own header names this exact trap.
check_mutation "fcs-verdict-wrong-convention" "rtl/pe_eth_mac.v" \
  "            if ((crc_state == CRC_RESIDUE) && hdr_done && (bit_cnt == 3'd0) &&" \
  "            if ((crc_state == 32'd0) && hdr_done && (bit_cnt == 3'd0) &&   // MUTANT: crc_zero convention" loop

# 7. The push bank never wraps: the 9th push lands on TXLENL (index 24).
check_mutation "push-wrap-into-ctrl" "rtl/pe_soc.v" \
  "            win_index     <= (win_index == 5'd23) ? 5'd16 : win_index + 5'd1;" \
  "            win_index     <= win_index + 5'd1;   // MUTANT: push escapes the 16-23 bank" loop

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
echo "    pristine snapshot kept for forensics: $PRISTINE"
[ $survived -gt 0 ] && { echo "SURVIVORS: the integration TBs do not test what they claim."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every eth_tx integration mutation is detected."
exit 0
