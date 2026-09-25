#!/usr/bin/env bash
# mutants.sh — NON-VACUITY EVIDENCE for the formal campaign. Every proof must
# kill the mutant that attacks its claim:
#
#     a property that does not kill its mutant is not a proof.
#
# TWO RULES THIS HARNESS LEARNED, both enforced below:
#   1. THE MUTANT MUST BE RUN IN THE SAME PROOF SHAPE AS THE CLAIM. A claim
#      proved by temporal induction constrains the design's TRANSITIONS, so its
#      mutant must be run by induction too: at a gate depth of 16 with no frame
#      delivered, a BMC simply never reaches the state (measured -- the m4a
#      owner-guard mutant SURVIVED a depth-24 BMC and was caught instantly by
#      the inductive target). Cases below therefore declare their shape.
#   2. A SURVIVING MUTANT IS A FAILURE OF THE HARNESS OR OF THE CLAIM, never a
#      footnote. The run exits non-zero if any mutant survives.
#
# RESTORE DISCIPLINE (the repo's mutation-harness rules, regress/mutate_*.sh):
# pristine snapshot, per-case restore, cmp verification against the snapshot
# (never against git), signal traps, and the single-run lock, because this
# worktree is shared.
#
#   bash formal/mutants.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
# shellcheck source=regress/run_lock.sh
. "$REPO/regress/run_lock.sh"
chip_take_run_lock "formal/mutants.sh"

GATE_DEPTH="${FORMAL_DEPTH:-16}"
OUT="$REPO/formal/results"
mkdir -p "$OUT"

MUTABLE="rtl/pe_pinmux.v rtl/pe_eth_tx.v rtl/pe_ctrl.v rtl/pe_soc.v \
         formal/pe_eth_tx/formal_pe_eth_tx.v"

PRISTINE=$(mktemp -d)
for f in $MUTABLE; do cp "$f" "$PRISTINE/$(basename "$f")"; done

restore_pristine() {
  for f in $MUTABLE; do
    [ -f "$PRISTINE/$(basename "$f")" ] && cp "$PRISTINE/$(basename "$f")" "$f"
  done
  return 0
}
cleanup() { restore_pristine; rm -rf "$PRISTINE"; chip_release_run_lock; }
on_signal() { cleanup; trap - EXIT INT TERM; exit 143; }
trap cleanup EXIT
trap on_signal INT TERM

restore_and_verify() {
  restore_pristine
  local bad=0
  for f in $MUTABLE; do
    if ! cmp -s "$PRISTINE/$(basename "$f")" "$f"; then
      echo "  RESTORE FAILED -- $f differs from the pristine snapshot"; bad=1
    fi
  done
  [ "$bad" -eq 0 ] || { echo "  refusing to continue: later results would measure the mutant"; exit 3; }
}

caught=0; survived=0; inconclusive=0
declare -a MUT_SUMMARY

# fv_case <name> <depth> <top> <sources...>   (env: FORMAL_SAT_MODE, ...)
# Expects the mutated design NOT to prove the target. A COUNTEREXAMPLE is a
# witness; an induction failure (NOTPROVED) is also a catch -- the claims no
# longer hold over the transitions.
fv_case() {
  local name="$1" depth="$2" top="$3"; shift 3
  local log="$OUT/mutant_$name.log"
  local shape="${FORMAL_SAT_MODE:-bmc}"
  printf '=== mutant %-24s depth=%-3s shape=%-6s ' "$name" "$depth" "$shape"
  local res
  res=$(bash formal/fv_run.sh "$log" "$top" "$depth" "$@")
  case "$res" in
    PROVED)      echo "SURVIVED -- the mutant is NOT killed: this claim is a blind spot"; survived=$((survived+1))
                 MUT_SUMMARY+=("$name|$shape|SURVIVED") ;;
    NOTPROVED)   echo "CAUGHT (the claim set no longer closes over the transitions)"; caught=$((caught+1))
                 MUT_SUMMARY+=("$name|$shape|CAUGHT-no-closure") ;;
    COUNTEREXAMPLE) echo "CAUGHT (witness in the log)"; caught=$((caught+1))
                 MUT_SUMMARY+=("$name|$shape|CAUGHT-witness") ;;
    *)           echo "INCONCLUSIVE (build/solver error -- see $log)"; inconclusive=$((inconclusive+1))
                 MUT_SUMMARY+=("$name|$shape|INCONCLUSIVE") ;;
  esac
}

apply_mutation() {
  python3 "$1" || { echo "  MUTATION DID NOT APPLY -- pattern absent (INCONCLUSIVE)"; return 1; }
  return 0
}

TMP=$(mktemp -d)
SRAM_STUB="formal/pe_soc/sram_model_formal.v"
SOC_RTL="rtl/pe_soc.v rtl/pe_eth_tx.v rtl/pe_serdes.v rtl/pe_nrzi.v rtl/pe_bitstuff.v \
         rtl/pe_codec_mux.v rtl/pe_manch.v rtl/pe_dru.v rtl/pe_crc.v rtl/pe_fbuf.v \
         rtl/pe_cpu.v rtl/pe_imem.v rtl/pe_eth_mac.v rtl/pe_pinmux.v"

# ---------------------------------------------------------------- 1. pinmux
# The real 2026-09-24 defect: pad_oe ignores the open-drain term, so a pin in
# open-drain mode CAN drive high. Target 1 must catch it.
cat > "$TMP/m1.py" <<'PY'
import pathlib, re, sys
p = pathlib.Path('rtl/pe_pinmux.v'); t = p.read_text()
m = re.search(r'assign\s+pad_oe\s*=\s*([^;]+);', t)
if not m: sys.exit("no pad_oe assignment found")
print(f"  pad_oe: {m.group(1).strip()!r} -> 'reg_oe' (od term removed)")
p.write_text(t[:m.start()] + "assign pad_oe  = reg_oe;" + t[m.end():])
PY
if apply_mutation "$TMP/m1.py"; then
  fv_case pinmux_od_m1 "$GATE_DEPTH" formal_pe_pinmux \
    formal/pe_pinmux/formal_pe_pinmux.v rtl/pe_pinmux.v
  restore_and_verify
fi

# ---------------------------------------------------------------- 2. runt
cat > "$TMP/runt.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_eth_tx.v'); t = p.read_text()
if "(frame_len >= 12'd14)" not in t: sys.exit("no lower bound found")
print("  len_ok: lower bound 14 -> 0 (runt accepted)")
p.write_text(t.replace("(frame_len >= 12'd14)", "(frame_len >= 12'd0)"))
PY
if apply_mutation "$TMP/runt.py"; then
  fv_case eth_tx_runt "$GATE_DEPTH" formal_pe_eth_tx \
    formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v
  restore_and_verify
fi

# ---------------------------------------------------------------- 3. jabber
cat > "$TMP/jabber.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_eth_tx.v'); t = p.read_text()
if "(frame_len <= 12'(MAX_STORED))" not in t: sys.exit("no upper bound found")
print("  len_ok: upper bound MAX_STORED -> 4095 (jabber accepted)")
p.write_text(t.replace("(frame_len <= 12'(MAX_STORED))", "(frame_len <= 12'd4095)"))
PY
if apply_mutation "$TMP/jabber.py"; then
  fv_case eth_tx_jabber "$GATE_DEPTH" formal_pe_eth_tx \
    formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v
  restore_and_verify
fi

# --------------------------------------------- 4. the F1 atomicity mutant
# The PRE-FIX behaviour, now a mutant: the frame re-reads frame_len at the
# apply boundary instead of consuming the length validated at the start pulse.
# P1b ("the frame consumes exactly what it latched") must FAIL. The manager's
# F1 ruling made the guard and the latch one event; this case is what enforces
# it, and it replaces the old `eth_tx_len_window` case, whose contract
# assumption is DISCHARGED (the RTL no longer has a window to assume away).
cat > "$TMP/unlatch.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_eth_tx.v'); t = p.read_text()
needle = "                stored_bytes   <= pend_len;"
if needle not in t: sys.exit("no validate-and-latch assignment found")
print("  stored_bytes: pend_len -> frame_len (the F1 pre-fix window is back)")
p.write_text(t.replace(needle, "                stored_bytes   <= frame_len;"))
PY
if apply_mutation "$TMP/unlatch.py"; then
  fv_case eth_tx_len_unlatch "$GATE_DEPTH" formal_pe_eth_tx \
    formal/pe_eth_tx/formal_pe_eth_tx.v rtl/pe_eth_tx.v rtl/pe_crc.v
  restore_and_verify
fi

# ------------------------------------------- 5/6. the inductive IFG floor
# Induction shape, matching the claim: a shortened gap and a SKIPPED gap must
# both break the floor. (The skip case is why the mandatory-gap obligation T1b
# exists: without it, going straight from the FCS to IDLE survived.)
cat > "$TMP/ifg90.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_eth_tx.v'); t = p.read_text()
if "if (ifg_cnt == 7'd95)" not in t: sys.exit("no ifg terminal count found")
print("  ifg_cnt terminal 95 -> 89 (gap 96 cells -> 90)")
p.write_text(t.replace("if (ifg_cnt == 7'd95)", "if (ifg_cnt == 7'd89)"))
PY
if apply_mutation "$TMP/ifg90.py"; then
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=6 fv_case eth_tx_ifg90 1 formal_pe_eth_tx_ifg \
    formal/pe_eth_tx/formal_pe_eth_tx_ifg.v rtl/pe_eth_tx.v rtl/pe_crc.v
  restore_and_verify
fi
cat > "$TMP/skipgap.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_eth_tx.v'); t = p.read_text()
old = """      if (fcs_left == 6'd1) begin
                state   <= S_IFG;"""
new = """      if (fcs_left == 6'd1) begin
                state   <= S_IDLE;"""
if old not in t: sys.exit("FCS->IFG transition not found")
print("  FCS end -> IDLE (the gap is skipped entirely)")
p.write_text(t.replace(old, new))
PY
if apply_mutation "$TMP/skipgap.py"; then
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=6 fv_case eth_tx_skip_gap 1 formal_pe_eth_tx_ifg \
    formal/pe_eth_tx/formal_pe_eth_tx_ifg.v rtl/pe_eth_tx.v rtl/pe_crc.v
  restore_and_verify
fi

# --------------------------------------------- 7/8/9. pe_ctrl R2 claims
# Induction shape with the inductive subset (-DFV_INDUCT), matching how those
# claims are proved. mut_len kills the response-length bound, mut_bit14 breaks
# the 16-bit word framing, mut_clr clears FAULT_RANGE without a CLEAR_FAULT.
#
# The response-buffer slot-overrun claim is now PROVED UNBOUNDED (reformulated
# 2026-09-25, see formal_pe_ctrl.v and FORMAL-STRENGTHENING.md 7), so per the
# mutant-kill bar it gets mutants of its OWN scope: the two ways r_slot can go
# wrong in a walk are an accept that loads r_slot<=0, and an R_REQ reached
# without passing an accepted R_START. A promoted claim that survived its own
# scope would be blind, so these two are in the gate.
cat > "$TMP/mut_slotload.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_ctrl.v'); t = p.read_text()
if t.count("r_slot      <= 16'd1;") != 2: sys.exit("expected 2 accept r_slot loads")
print("  accepted start loads r_slot<=0 (the walk can overrun the buffer)")
p.write_text(t.replace("r_slot      <= 16'd1;", "r_slot      <= 16'd0;"))
PY
if apply_mutation "$TMP/mut_slotload.py"; then
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=6 fv_case pe_ctrl_slot_load_zero 1 formal_pe_ctrl \
    -DFV_INDUCT formal/pe_ctrl/formal_pe_ctrl.v rtl/pe_ctrl.v
  restore_and_verify
fi
cat > "$TMP/mut_rreqjump.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_ctrl.v'); t = p.read_text()
if "        R_IDLE: begin end" not in t: sys.exit("no R_IDLE arm")
print("  R_IDLE reaches R_REQ without passing an accepted R_START")
p.write_text(t.replace("        R_IDLE: begin end",
  "        R_IDLE: begin rstate <= R_REQ; // MUTANT\n          end", 1))
PY
if apply_mutation "$TMP/mut_rreqjump.py"; then
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=6 fv_case pe_ctrl_r_req_bypass 1 formal_pe_ctrl \
    -DFV_INDUCT formal/pe_ctrl/formal_pe_ctrl.v rtl/pe_ctrl.v
  restore_and_verify
fi
cat > "$TMP/mut_len.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_ctrl.v'); t = p.read_text()
if "pay1 > 16'(MAX_READ_WORDS)" not in t: sys.exit("no MAX_READ_WORDS guard")
print("  imem read count guard removed (resp_len may exceed the 16-word buffer)")
p.write_text(t.replace("pay1 > 16'(MAX_READ_WORDS)", "1'b0"))
PY
if apply_mutation "$TMP/mut_len.py"; then
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=6 fv_case pe_ctrl_len_overflow 1 formal_pe_ctrl \
    -DFV_INDUCT formal/pe_ctrl/formal_pe_ctrl.v rtl/pe_ctrl.v
  restore_and_verify
fi
cat > "$TMP/mut_bit14.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_ctrl.v'); t = p.read_text()
if "if (resp_bitpos == 4'd15) begin" not in t: sys.exit("no word-end check")
print("  word end 15 -> 14 (each word is 15 bits)")
p.write_text(t.replace("if (resp_bitpos == 4'd15) begin", "if (resp_bitpos == 4'd14) begin"))
PY
if apply_mutation "$TMP/mut_bit14.py"; then
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=6 fv_case pe_ctrl_bit14 1 formal_pe_ctrl \
    -DFV_INDUCT formal/pe_ctrl/formal_pe_ctrl.v rtl/pe_ctrl.v
  restore_and_verify
fi
cat > "$TMP/mut_clr.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_ctrl.v'); t = p.read_text()
if "faults      <= faults & ~pay0;" not in t: sys.exit("no CLEAR_FAULT mask")
print("  CLEAR_FAULT clears faults unconditionally (the mask is ignored)")
p.write_text(t.replace("faults      <= faults & ~pay0;", "faults      <= 16'd0;"))
PY
if apply_mutation "$TMP/mut_clr.py"; then
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=6 fv_case pe_ctrl_clear_uncond 1 formal_pe_ctrl \
    -DFV_INDUCT formal/pe_ctrl/formal_pe_ctrl.v rtl/pe_ctrl.v
  restore_and_verify
fi

# ------------------------------------------------- 10/11. pe_soc owner guards
# BOTH directions the manager's F2 ruling made symmetric: the clear guard and
# the new set guard. Each removal must be caught by its own claim (C1 / C2),
# run by INDUCTION (see rule 1 above).
cat > "$TMP/mut_owner.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_soc.v'); t = p.read_text()
needle = "end else if (!eth_tx_busy) begin"
if needle not in t: sys.exit("no tx_path clear guard")
print("  tx_path clear guard removed (the owner can be taken from a busy engine)")
p.write_text(t.replace(needle, "end else if (1'b1) begin"))
PY
if apply_mutation "$TMP/mut_owner.py"; then
  # -DFV_INDUCT: the shape C1 is PROVED in. C2 is also in the target now (it is
  # always-on since the 2026-09-25 strengthening), but the set guard is untouched
  # by THIS mutation, so C2 still closes and the NOTPROVED below is C1's catch.
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=3 FORMAL_MEMORY_MAP=1 \
  fv_case pe_soc_owner_clear_guard_removed 1 formal_pe_soc \
    -DFV_INDUCT formal/pe_soc/formal_pe_soc.v $SRAM_STUB $SOC_RTL
  restore_and_verify
fi
# ------------------------------------------- 12/13. R3 debug-control claims
# Both run against the pe_ctrl INDUCTIVE subset (the shape the clean claims are
# proved in): H1 (a hit implies the hold) and H3 (an armed address is inside
# instruction memory). The step/hold mutants live in regress/mutate_ctrl_r3_tb.sh,
# where the TB is the authority: the pe_cpu formal target takes dbg_hold/dbg_step
# as FREE inputs, so it proves the core's RESPONSE to them, not that pe_ctrl
# asserts them.
cat > "$TMP/mut_bp_hit_hold.py" <<'PYMUT'
import pathlib, sys
p = pathlib.Path('rtl/pe_ctrl.v'); t = p.read_text()
needle = """        bp_hit     <= 1'b1;
        dbg_hold_r <= 1'b1;
      end"""
if needle not in t: sys.exit("no hit/hold pair")
print("  breakpoint hit no longer asserts the hold (H1)")
p.write_text(t.replace(needle, """        bp_hit     <= 1'b1;
      end""", 1))
PYMUT
if apply_mutation "$TMP/mut_bp_hit_hold.py"; then
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=6 \
  fv_case pe_ctrl_bp_hit_no_hold 1 formal_pe_ctrl \
    -DFV_INDUCT formal/pe_ctrl/formal_pe_ctrl.v rtl/pe_ctrl.v
  restore_and_verify
fi
cat > "$TMP/mut_bp_range.py" <<'PYMUT'
# H3 (the bound) is NOT mutated here: the claim was VACUOUS and was removed (see
# formal_pe_ctrl.v). The bound is enforced by the TB's C2 case and its
# `bp-set-no-range` mutation in regress/mutate_ctrl_r3_tb.sh, where it IS
# differential (clean TB passes, mutant TB fails).
PYMUT

# F2's SET-side guard, now a FIRST-CLASS formal mutant (2026-09-25). When this
# case was written C2 was labelled gate-depth-only, so the set guard had no
# differential formal mutant here -- only the directed TB case. That is no
# longer true: C2 is now UNBOUNDED (it closes by k-induction at k=1 because the
# guard tap and the busy tap clock from the same edge of the same always block),
# so the clean design closes this target and a NOTPROVED below IS a real
# differential. The mutant removes the set guard -- the pre-fix F2 bug, where a
# TXCTRL write during a live SERDES transmission steals the codec mid-frame --
# and C2 must catch it.
cat > "$TMP/mut_owner_set.py" <<'PY'
import pathlib, sys
p = pathlib.Path('rtl/pe_soc.v'); t = p.read_text()
needle = "if (!ser_tx_busy) tx_path <= 1'b1;"
if t.count(needle) != 1: sys.exit(f"expected 1 set guard, found {t.count(needle)}")
print("  tx_path set guard removed (the owner can be stolen from a busy SERDES)")
p.write_text(t.replace(needle, "tx_path <= 1'b1; // MUTANT"))
PY
if apply_mutation "$TMP/mut_owner_set.py"; then
  # C2 is now proved by INDUCTION (unbounded), so run the mutant in the same
  # shape the clean claim is proved in. The claim is always-on, so it is in the
  # target with or without -DFV_INDUCT.
  FORMAL_SAT_MODE=induct FORMAL_INDUCT_MAX=3 FORMAL_MEMORY_MAP=1 \
  fv_case pe_soc_owner_set_guard_removed 1 formal_pe_soc \
    -DFV_INDUCT formal/pe_soc/formal_pe_soc.v $SRAM_STUB $SOC_RTL
  restore_and_verify
fi
# F2's independent enforcement evidence is ALSO the directed TB case
# (tb_pe_soc_eth_loop's run_owner_probe) and the `owner-set-guard-removed`
# mutation in regress/mutate_eth_tx_loop_tb.sh, where the clean TB passes and
# the mutant fails (verified: clean PASS, mutant FAIL on the rose_mid_serdes and
# tx_path checks). The formal mutant above is the wire-level-independent twin.

rm -rf "$TMP"
echo
{
  printf 'mutant|shape|result\n'
  printf '%s\n' "${MUT_SUMMARY[@]:-}"
} > "$OUT/mutants.txt"
echo "=== mutants: $caught caught, $survived SURVIVED (blind spots), $inconclusive inconclusive ==="
[ $((survived + inconclusive)) -eq 0 ] || exit 1
exit 0
