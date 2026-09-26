#!/usr/bin/env bash
# mutate_soc_serdes_tb.sh — mutation-test tb_pe_soc_serdes.v (the word-engine
# integration in pe_soc).
#
# WHY THIS EXISTS. The integration plan (wiki/plans/serdes-integration.md)
# requires the SoC loopback TB to be able to fail on the exact failures the
# SHARED-enable topology would have produced, plus the two alignment defects
# this integration itself must not have. Each mutation below is a plausible
# implementation choice in rtl/pe_soc.v; the TB must notice every one:
#
#   1. tx-hold-removed     — serdes.tx_bit_en = tx_cell_en (no !tx_stuffed):
#                            the serdes consumes a payload bit per WIRE cell,
#                            so the bit after a stuff insertion is shifted or
#                            lost (the plan's mutation (a)).
#   2. rx-skip-removed     — serdes.rx_bit_en = rx_cell_en (no rx_bit_valid):
#                            received stuff cells are captured as payload
#                            (the plan's mutation (b)).
#   3. doubled-cell-enable — the TX codec's bit_en also pulses at the
#                            half-cell boundary, i.e. twice per encoded cell
#                            (the plan's mutation (c)).
#   4. strobe-cross-wire   — the RX codec's bit_en comes from the TX cell
#                            strobe instead of the DRU decode strobe in
#                            Manchester mode (the plan's mutation (d)).
#   5. rx-start-no-anchor  — Manchester rx_start is not anchored to the first
#                            DRU decode after the load, so the stale idle
#                            decode in flight is captured as payload bit 0
#                            and the word shifts by one (the alignment defect
#                            found while bringing this up).
#   6. half-rate-half-phase— half_phase toggles only at the mid-cell
#                            boundary (once per cell instead of twice), so
#                            the Manchester wire runs at cell rate and the
#                            DRU cannot decode it (the second alignment
#                            defect found while bringing this up).
#   7. no-grid-load        — the load is not grid-aligned (applied the
#                            cycle the CTRL strobe lands), so bit0 can be
#                            truncated to a fraction of the first cell.
#
# RESTORE IS A FILE COPY, verified after every mutation (the eth_mac lesson:
# a failed restore stacks mutations and reports a meaningless perfect score).
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
# MUTABLE — what this harness EDITS inside the repo. Read by
# regress/verify_merge.sh (the merge gate) to decide whether a narrowed gate
# has to run this suite, and by regress/check_mutation_lists.sh to prove the
# list still covers every file the harness writes. Evidence: RTL=.
# An EMPTY value means this suite mutates nothing in the repo and is therefore
# NEVER SKIPPED. A MISSING line is the opposite: unmappable, and the gate
# escalates to running every suite rather than guessing.
MUTABLE="rtl/pe_soc.v"
LOG=/tmp/mutate_soc_serdes.log
BAK=$(mktemp /tmp/pe_soc_serdes.XXXXXX.v)

cleanup() { cp "$BAK" "$RTL" 2>/dev/null; rm -f "$BAK"; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

mkdir -p "$ROOT/sim"
cd "$ROOT/sim"
cp "$RTL" "$BAK"
cmp -s "$RTL" "$BAK" || { echo "FATAL: could not snapshot $RTL"; exit 2; }

# The pad-level firmware image must be current: a stale hex is a silent pass.
if [ ! -f "$ROOT/firmware/serdes_loop.hex" ]; then
  echo "  firmware image missing: building it first"
  ( cd "$ROOT" && ./regress/run_firmware_tests.sh >/tmp/mut_soc_serdes_fw.log 2>&1 ) \
    || { echo "FATAL: could not build the firmware images"; exit 2; }
fi

# Same source list as run_all.sh's tb_pe_soc_serdes case.
SRCS="../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v"

run_tb() {
  local sram
  sram=$(bash "$ROOT/regress/sram_model.sh" 2>/dev/null) || return 2
  iverilog -g2012 -s tb_pe_soc_serdes -o /tmp/mut_soc_serdes.vvp \
    $SRCS $sram ../tb/tb_pe_soc_serdes.v >/tmp/mut_soc_serdes_cc.log 2>&1 || return 2
  timeout 300 vvp /tmp/mut_soc_serdes.vvp >"$LOG" 2>&1
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

pass=0; fail=0; survived=0

check_mutation() {
  local name="$1"; shift
  if ! mutate "$1" "$2"; then
    echo "  [$name] HARNESS ERROR: anchor not found"; restore; fail=$((fail+1)); return
  fi
  run_tb
  local rc=$?
  if   [ $rc -eq 0 ]; then echo "  [$name] SURVIVED"; survived=$((survived+1))
  elif [ $rc -eq 1 ]; then echo "  [$name] detected"; pass=$((pass+1))
  else                     echo "  [$name] HARNESS ERROR: exit $rc"; tail -5 /tmp/mut_soc_serdes_cc.log "$LOG" 2>/dev/null; fail=$((fail+1))
  fi
  restore; verify_restore
}

echo "=== mutation-testing tb_pe_soc_serdes ==="
run_tb
rc=$?
if [ $rc -ne 0 ]; then
  echo "  FATAL: the TB does not pass on the clean design (exit $rc)"
  [ $rc -eq 2 ] && tail -5 /tmp/mut_soc_serdes_cc.log
  exit 2
fi
echo "  [baseline] passes on the unmutated design"

# 1. TX hold on inserted stuff cells (the plan's (a)).
check_mutation "tx-hold-removed" \
  "  wire serdes_tx_bit_en = tx_cell_en && !tx_stuffed_w;" \
  "  wire serdes_tx_bit_en = tx_cell_en;   // MUTANT: TX-hold removed"

# 2. RX skip of received stuff cells (the plan's (b)).
check_mutation "rx-skip-removed" \
  "  wire serdes_rx_bit_en = rx_cell_en && rx_bit_valid_w;" \
  "  wire serdes_rx_bit_en = rx_cell_en;   // MUTANT: RX-skip removed"

# 3. Codec cell enable doubled to the half-cell rate (the plan's (c)).
check_mutation "doubled-cell-enable" \
  "  wire tx_cell_en  = cell_en;" \
  "  wire tx_cell_en  = cell_en || (cell_cnt == ((cell_div >> 1) - 16'd1));   // MUTANT: half-cell rate"

# 4. RX codec strobe cross-wired to the TX cadence (the plan's (d)).
check_mutation "strobe-cross-wire" \
  "  wire rx_cell_en  = eng_en && (manch_mode ? eth_bit_en : cell_en);" \
  "  wire rx_cell_en  = eng_en && (manch_mode ? tx_cell_en : cell_en);   // MUTANT: cross-wire"

# 5. Manchester rx_start without the first-decode anchor: the stale idle
#    decode in flight is captured as payload bit 0 and the word shifts.
check_mutation "rx-start-no-anchor" \
  "                        && (manch_mode ? (rx_anchor && eth_bit_en) : cell_en);" \
  "                        && (manch_mode ? rx_anchor : cell_en);   // MUTANT: no decode anchor"

# 6. half_phase toggling once per cell instead of twice.
check_mutation "half-rate-half-phase" \
  "        end else if (cell_cnt == ((cell_div >> 1) - 16'd1)
                     || cell_cnt == cell_div - 16'd1) begin" \
  "        end else if (cell_cnt == ((cell_div >> 1) - 16'd1)) begin   // MUTANT: one toggle per cell"

# 7. Load not grid-aligned: bit0 can be truncated to a fraction of a cell.
check_mutation "no-grid-load" \
  "  wire  tx_load_grid  = tx_load_pend  && cell_en;" \
  "  wire  tx_load_grid  = tx_load_pend;   // MUTANT: load not grid-aligned"

echo
echo "=== $pass detected, $survived survived, $fail harness errors ==="
[ $survived -gt 0 ] && { echo "SURVIVORS: the TB does not test what it claims."; exit 1; }
[ $fail -gt 0 ] && { echo "HARNESS ERRORS: fix the harness first."; exit 1; }
echo "OK: every word-engine integration mutation is detected by tb_pe_soc_serdes."
exit 0
