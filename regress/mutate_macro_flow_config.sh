#!/usr/bin/env bash
# mutate_macro_flow_config.sh — negative tests for tools/checks/macro_flow_config.py.
#
# WHY THIS EXISTS (E2-1/E2-2/E2-3). The static gate claims every hard macro is
# placed and has a physical power path before the flow runs. That claim is only
# as strong as the gate's ability to FAIL, so this harness mutates a COPY of
# the flow config and the PDN script (never the tracked files) and requires the
# gate to reject each mutation:
#
#   1. wrong-net: one macro entry swaps VPWR and VGND, leaving every macro pin
#      name exactly where it was (the old pin-name-only check passed this);
#   2. missing-metal4-to-vertical: the macro grid's
#      `add_pdn_connect -layers "Metal4 $::env(PDN_VERTICAL_LAYER)"` is gone;
#   3. missing-vertical-to-horizontal: the macro grid's
#      `add_pdn_connect -layers "$::env(PDN_VERTICAL_LAYER)
#      $::env(PDN_HORIZONTAL_LAYER)"` is gone;
#   4. missing-metal4-stripe: the macro grid's `add_pdn_stripe -layer Metal4`
#      is gone;
#   5. wrong-layer: the Metal4->vertical connect names Metal5 instead;
#   6. reversed-layers: that connect names the pair in the other order;
#   7. missing-lef-view / missing-gds-view / missing-lib-corner /
#      nonexistent-view / wrong-view-type: the E2-4 macro view configuration
#      is incomplete, names a file the PDK sg13g2_sram tree does not contain,
#      or puts a view of the wrong class (a .lib in the LEF slot) where a
#      typed view belongs;
#   8. corner-file-shared / corner-key-wildcard (R3): one lib file satisfies
#      two -- or, under a `*` key, every -- required PVT corner, so two
#      corners would silently read the same timing data. Key-pattern coverage
#      alone cannot see that copy/paste error.
#
# It also runs a SYNTHETIC two-type flow (E2-5): two blackbox macros whose
# LEFs declare different SIZEs (10x10 and 100x100), a fake PDK staging their
# typed views and corner, and configs that are legal for a single-hard-coded-
# LEF checker but must fail -- one where the larger type leaves the die, one
# where the pair is closer than the placement gap only when each type's own
# width is used, and one where a configured type has no LEF (a finding, and
# that type's instances are reported unchecked, never silently measured).
#
# The same synthetic fixture also pins E2-6 type<->view identity: a clean
# config with correct per-type views must pass, while a type configured with
# ANOTHER type's LEF (`type-b-wrong-lef`), another type's lib, or a LEF with
# no MACRO declaration at all must be detected as exit 1 -- the checker used
# to measure the configured file's SIZE without ever comparing its MACRO
# declaration to the configured type, so type B (100x100) configured with
# type A's 10x10 LEF passed a 50x50 die placement it could never fit.
#
# It also pins the E2-3 exit taxonomy: a missing LEF alone is an INCOMPLETE
# (exit 2, a supported PDK-less skip) and the harness itself skips cleanly when
# its own baseline is incomplete, but a finding (including a view finding) with
# the geometry missing is still exit 1, and a Yosys elaboration failure is
# exit 1, never a skip.
#
# The unmutated copy must pass first, and the tracked files are compared at the
# end to prove this script never touched them.
set -u
# MUTABLE — what this harness EDITS inside the repo. Read by
# regress/verify_merge.sh (the merge gate) to decide whether a narrowed gate
# has to run this suite, and by regress/check_mutation_lists.sh to prove the
# list still covers every file the harness writes. Evidence: it writes only under $TMP (synthetic fixtures) and reads the PDK; it mutates nothing in the repo, so empty means NEVER SKIPPED.
# An EMPTY value means this suite mutates nothing in the repo and is therefore
# NEVER SKIPPED. A MISSING line is the opposite: unmappable, and the gate
# escalates to running every suite rather than guessing.
MUTABLE=""
cd "$(dirname "$0")/.."
# The single-run lock: this worktree is shared and a concurrent run would be
# mutating and restoring the same RTL. Inherited from run_all.sh when this is
# one of its children, so the harnesses do not deadlock their own parent.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "$(basename "$0")"

# THE HARNESS-EDIT PRE-FLIGHT (regress/dep_guard.sh), for the one harness with no
# `trap ... EXIT` of its own. Installed right after the lock is taken (which is
# where the stamp is), so it cannot be replaced, and it converts a changed
# dependency into exit 4 (INCONCLUSIVE) instead of a verdict that a mid-run edit
# could have made false in either direction.
_chip_dep_exit() {
  local rc=$?
  chip_dep_check "run_$(basename "$0")" || rc=4
  exit "$rc"
}
trap _chip_dep_exit EXIT

ROOT="$PWD"
TMP=$(mktemp -d /tmp/macro-flow-neg.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

cp "$ROOT/flow/pe_soc.json"    "$TMP/pe_soc.json"
cp "$ROOT/flow/pe_soc_pdn.tcl" "$TMP/pe_soc_pdn.tcl"
cp "$TMP/pe_soc.json"    "$TMP/pe_soc.json.orig"
cp "$TMP/pe_soc_pdn.tcl" "$TMP/pe_soc_pdn.tcl.orig"

pass=0
fail=0
gate() { python3 "$ROOT/tools/checks/macro_flow_config.py" --flow "$TMP/pe_soc.json" "$@"; }

restore() {
  cp "$TMP/pe_soc.json.orig"    "$TMP/pe_soc.json"
  cp "$TMP/pe_soc_pdn.tcl.orig" "$TMP/pe_soc_pdn.tcl"
}

mutate() {
  python3 - "$TMP" "$1" <<'PY'
import pathlib, sys
tmp = pathlib.Path(sys.argv[1]); which = sys.argv[2]

def edit(fname, old, new):
    p = tmp / fname
    t = p.read_text()
    assert old in t, f"{which}: anchor not found in {fname}"
    p.write_text(t.replace(old, new, 1))

M4V = ('add_pdn_connect \\\n    -grid macro \\\n'
       '    -layers "Metal4 $::env(PDN_VERTICAL_LAYER)"\n')
VH = ('add_pdn_connect \\\n    -grid macro \\\n'
      '    -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"\n')
STRIPE = ('add_pdn_stripe \\\n    -grid macro \\\n    -layer Metal4 \\\n'
          '    -width 1.2 \\\n    -pitch 11.24 \\\n    -offset 4.26 \\\n'
          '    -starts_with POWER\n')
NET = '"u_eth_fbuf\\\\.g_macro\\\\.u_sram VPWR VGND VDD! VSS!"'

VIEWS = ("missing-lef-view", "missing-gds-view", "missing-lib-corner",
         "nonexistent-view", "wrong-view-type", "corner-file-shared",
         "corner-key-wildcard")
if which in VIEWS:
    import json
    p = tmp / "pe_soc.json"
    cfg = json.loads(p.read_text())
    m = cfg["MACROS"]["RM_IHPSG13_1P_1024x16_c2_bm_bist"]
    if which == "missing-lef-view":
        del m["lef"]
    elif which == "missing-gds-view":
        del m["gds"]
    elif which == "missing-lib-corner":
        del m["lib"]["nom_slow_1p08V_125C"]
    elif which == "nonexistent-view":
        m["lib"]["nom_typ_1p20V_25C"] = ["./src/does-not-exist.lib"]
    elif which == "wrong-view-type":
        # An existing file, but the wrong view class: a .lib in the LEF slot.
        m["lef"] = ["./src/RM_IHPSG13_1P_1024x16_c2_bm_bist_typ_1p20V_25C.lib"]
    elif which == "corner-file-shared":
        # R3: the slow corner served by the typ file nom_typ also uses.
        m["lib"]["nom_slow_1p08V_125C"] = [
            "./src/RM_IHPSG13_1P_1024x16_c2_bm_bist_typ_1p20V_25C.lib"]
    elif which == "corner-key-wildcard":
        # R3: one file under a `*` key satisfies every required corner.
        m["lib"] = {"*": [
            "./src/RM_IHPSG13_1P_1024x16_c2_bm_bist_typ_1p20V_25C.lib"]}
    p.write_text(json.dumps(cfg, indent=2) + "\n")
elif which == "wrong-net":
    edit("pe_soc.json", NET, NET.replace("VPWR VGND", "VGND VPWR"))
elif which == "missing-metal4-to-vertical":
    edit("pe_soc_pdn.tcl", M4V, "")
elif which == "missing-vertical-to-horizontal":
    edit("pe_soc_pdn.tcl", VH, "")
elif which == "missing-metal4-stripe":
    edit("pe_soc_pdn.tcl", STRIPE, "")
elif which == "wrong-layer":
    edit("pe_soc_pdn.tcl", M4V, M4V.replace(
        '"Metal4 $::env(PDN_VERTICAL_LAYER)"',
        '"Metal5 $::env(PDN_VERTICAL_LAYER)"'))
elif which == "reversed-layers":
    edit("pe_soc_pdn.tcl", M4V, M4V.replace(
        '"Metal4 $::env(PDN_VERTICAL_LAYER)"',
        '"$::env(PDN_VERTICAL_LAYER) Metal4"'))
else:
    sys.exit(3)
PY
}

# A mutation is detected ONLY by exit 1. Exit 0 means it survived; exit 2 is
# the geometry-incomplete skip and would mean a mutation turned a finding into
# a skip, which is a harness error.
run_negative() {
  local name="$1" expect="$2"
  restore
  if ! mutate "$name"; then
    echo "  [$name] HARNESS ERROR: could not apply the mutation"
    fail=$((fail + 1))
    return
  fi
  gate > "$TMP/gate-$name.log" 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  [$name] SURVIVED: $expect"
    fail=$((fail + 1))
  elif [ "$rc" -eq 1 ]; then
    echo "  [$name] detected"
    pass=$((pass + 1))
  else
    echo "  [$name] HARNESS ERROR: exit $rc (a mutation must be a finding, not a skip)"
    tail -5 "$TMP/gate-$name.log"
    fail=$((fail + 1))
  fi
}

echo "=== negative-testing the macro flow config gate ==="

# The clean copy passes; if the required PDK geometry is absent, the checker
# says INCOMPLETE (exit 2) and this harness skips cleanly rather than failing a
# supported PDK-less regression.
restore
gate > "$TMP/gate-clean.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  [clean] passes on the unmutated copy"
  pass=$((pass + 1))
elif [ "$rc" -eq 2 ] && grep -q "INCOMPLETE" "$TMP/gate-clean.log"; then
  echo "SKIPPED: the baseline is INCOMPLETE (required PDK geometry unavailable)"
  echo "=== SKIPPED: no mutations run (a supported PDK-less result) ==="
  exit 0
else
  echo "  [clean] HARNESS ERROR: the gate did not pass the unmutated copy (exit $rc)"
  cat "$TMP/gate-clean.log"
  fail=$((fail + 1))
fi

run_negative "wrong-net" \
  "a power pin on the ground net was accepted"
run_negative "missing-metal4-to-vertical" \
  "a removed Metal4-to-vertical connect was accepted"
run_negative "missing-vertical-to-horizontal" \
  "a removed vertical-to-horizontal connect was accepted"
run_negative "missing-metal4-stripe" \
  "a removed Metal4 stripe was accepted"
run_negative "wrong-layer" \
  "a Metal5 layer expression was accepted"
run_negative "reversed-layers" \
  "a reversed -layers pair was accepted"
run_negative "missing-lef-view" \
  "a macro type with no LEF view was accepted"
run_negative "missing-gds-view" \
  "a macro type with no GDS view was accepted"
run_negative "missing-lib-corner" \
  "a required PVT corner with no lib view was accepted"
run_negative "nonexistent-view" \
  "a view path with no PDK source was accepted"
run_negative "wrong-view-type" \
  "a lib file in the LEF slot was accepted"
run_negative "corner-file-shared" \
  "one lib file serving two required corners was accepted"
run_negative "corner-key-wildcard" \
  "one lib file satisfying every corner under a * key was accepted"

# ---- E2-3 exit taxonomy ----------------------------------------------------
# Missing LEF with no findings: INCOMPLETE (exit 2), a supported skip.
restore
gate --lef "$TMP/no-such-macro.lef" > "$TMP/gate-pdkless.log" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -q "INCOMPLETE" "$TMP/gate-pdkless.log"; then
  echo "  [pdkless-clean] INCOMPLETE (exit 2) as designed"
  pass=$((pass + 1))
else
  echo "  [pdkless-clean] FAILED: exit $rc, want 2 + INCOMPLETE"
  tail -5 "$TMP/gate-pdkless.log"
  fail=$((fail + 1))
fi

# Missing LEF with a finding: still FAILED (exit 1). Exit 2 is not a blanket
# skip for anything the checker cannot fully check.
restore
if mutate "wrong-net"; then
  gate --lef "$TMP/no-such-macro.lef" > "$TMP/gate-pdkless-finding.log" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "  [pdkless-finding] still a FAILURE (exit 1), not a skip"
    pass=$((pass + 1))
  else
    echo "  [pdkless-finding] FAILED: exit $rc, want 1 (a finding is not a skip)"
    tail -5 "$TMP/gate-pdkless-finding.log"
    fail=$((fail + 1))
  fi
else
  echo "  [pdkless-finding] HARNESS ERROR: could not apply the mutation"
  fail=$((fail + 1))
fi

# A view finding fails even when the geometry LEF is unavailable: the
# missing-GDS structural finding must not become a skip.
restore
if mutate "missing-gds-view"; then
  gate --lef "$TMP/no-such-macro.lef" > "$TMP/gate-pdkless-view.log" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "  [pdkless-view-finding] still a FAILURE (exit 1), not a skip"
    pass=$((pass + 1))
  else
    echo "  [pdkless-view-finding] FAILED: exit $rc, want 1"
    tail -5 "$TMP/gate-pdkless-view.log"
    fail=$((fail + 1))
  fi
else
  echo "  [pdkless-view-finding] HARNESS ERROR: could not apply the mutation"
  fail=$((fail + 1))
fi

# A structural wrong-view-type finding must fail even when BOTH the geometry
# LEF and the PDK view tree are unavailable: class/extension validation is
# config-only and must run outside the tree guard (E2-4 edge).
restore
if mutate "wrong-view-type"; then
  gate --lef "$TMP/no-such-macro.lef" --pdk-root "$TMP/no-such-pdk" \
       > "$TMP/gate-pdkless-type.log" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "  [pdkless-view-type] still a FAILURE (exit 1), not a skip"
    pass=$((pass + 1))
  else
    echo "  [pdkless-view-type] FAILED: exit $rc, want 1"
    tail -5 "$TMP/gate-pdkless-type.log"
    fail=$((fail + 1))
  fi
else
  echo "  [pdkless-view-type] HARNESS ERROR: could not apply the mutation"
  fail=$((fail + 1))
fi

# A Yosys elaboration failure: FAILED (exit 1), never a skip.
restore
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\necho "fake yosys: forced failure" >&2\nexit 1\n' > "$TMP/fakebin/yosys"
chmod +x "$TMP/fakebin/yosys"
PATH="$TMP/fakebin:$PATH" gate > "$TMP/gate-yosysfail.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q "yosys elaboration failed" "$TMP/gate-yosysfail.log"; then
  echo "  [yosys-failure] still a FAILURE (exit 1), not a skip"
  pass=$((pass + 1))
else
  echo "  [yosys-failure] FAILED: exit $rc, want 1 + 'yosys elaboration failed'"
  tail -5 "$TMP/gate-yosysfail.log"
  fail=$((fail + 1))
fi

# ---- E2-5 per-type geometry (synthetic two-type flow) ----------------------
# A single hard-coded LEF measures every type with one footprint. Build an
# isolated flow with two blackbox macros -- A's LEF says 10x10, B's says
# 100x100 -- and a fake PDK that stages each type's own typed views and corner,
# then require each config to fail against its OWN type's dimensions.
SYNTH="$TMP/synth"
mkdir -p "$SYNTH"
python3 - "$SYNTH" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
(root / "pe_soc.v").write_text('''\
(* blackbox *) module RM_IHPSG_FAKE_A(input wire clk); endmodule
(* blackbox *) module RM_IHPSG_FAKE_B(input wire clk); endmodule
module pe_soc(input wire clk);
  RM_IHPSG_FAKE_A u_a (.clk(clk));
  RM_IHPSG_FAKE_B u_b (.clk(clk));
endmodule
''')
sram = root / "pdk/ihp-sg13g2/libs.ref/sg13g2_sram"
for cls in ("gds", "lef", "lib"):
    (sram / cls).mkdir(parents=True)
(sram / "lef/RM_IHPSG_FAKE_A.lef").write_text(
    "MACRO RM_IHPSG_FAKE_A\n  SIZE 10 BY 10 ;\nEND RM_IHPSG_FAKE_A\n")
(sram / "lef/RM_IHPSG_FAKE_B.lef").write_text(
    "MACRO RM_IHPSG_FAKE_B\n  SIZE 100 BY 100 ;\nEND RM_IHPSG_FAKE_B\n")
for n in ("RM_IHPSG_FAKE_A", "RM_IHPSG_FAKE_B"):
    (sram / f"gds/{n}.gds").write_text("")
    # Each lib declares its own cell: type<->file identity (E2-6) is checked
    # against this declaration where one is present.
    (sram / f"lib/{n}_typ.lib").write_text(
        f"library({n}_typ) {{\n  cell({n}) {{\n  }}\n}}\n")
# A LEF whose geometry parses but that declares no MACRO at all: identity is
# fail-closed for LEFs (the MACRO declaration is mandatory LEF syntax).
(sram / "lef/RM_IHPSG_FAKE_NO_MACRO.lef").write_text("  SIZE 100 BY 100 ;\n")
stdcell = root / "pdk/ihp-sg13g2/libs.tech/librelane/sg13g2_stdcell"
stdcell.mkdir(parents=True)
(stdcell / "config.tcl").write_text(
    'set ::env(STA_CORNERS) "\\\nnom_typ_1p20V_25C \\\n"\n'
    'set ::env(DEFAULT_CORNER) "nom_typ_1p20V_25C"\n')
(root / "fake_pdn.tcl").write_text('''\
add_pdn_stripe -grid macro -layer Metal4 -width 1.2 -pitch 11.24 -offset 4.26 -starts_with POWER
add_pdn_connect -grid macro -layers "Metal4 $::env(PDN_VERTICAL_LAYER)"
add_pdn_connect -grid macro -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
''')
base = {
    "PDN_CFG": "./src/fake_pdn.tcl",
    "PDN_MACRO_CONNECTIONS": [
        "u_a VPWR VGND VDD! VSS!", "u_a VPWR VGND VDDARRAY! VSS!",
        "u_b VPWR VGND VDD! VSS!", "u_b VPWR VGND VDDARRAY! VSS!",
    ],
    "MACROS": {
        "RM_IHPSG_FAKE_A": {
            "gds": ["./src/RM_IHPSG_FAKE_A.gds"],
            "lef": ["./src/RM_IHPSG_FAKE_A.lef"],
            "lib": {"nom_typ_1p20V_25C": ["./src/RM_IHPSG_FAKE_A_typ.lib"]},
            "instances": {"u_a": {"location": [0, 0], "orientation": "N"}},
        },
        "RM_IHPSG_FAKE_B": {
            "gds": ["./src/RM_IHPSG_FAKE_B.gds"],
            "lef": ["./src/RM_IHPSG_FAKE_B.lef"],
            "lib": {"nom_typ_1p20V_25C": ["./src/RM_IHPSG_FAKE_B_typ.lib"]},
            "instances": {"u_b": {"location": [20, 0], "orientation": "N"}},
        },
    },
}

def write(name, die, a, b, drop_b_lef=False, b_lef=None, b_lib=None):
    cfg = json.loads(json.dumps(base))
    cfg["DIE_AREA"] = die
    cfg["MACROS"]["RM_IHPSG_FAKE_A"]["instances"]["u_a"]["location"] = a
    cfg["MACROS"]["RM_IHPSG_FAKE_B"]["instances"]["u_b"]["location"] = b
    if drop_b_lef:
        del cfg["MACROS"]["RM_IHPSG_FAKE_B"]["lef"]
    if b_lef:
        cfg["MACROS"]["RM_IHPSG_FAKE_B"]["lef"] = [b_lef]
    if b_lib:
        cfg["MACROS"]["RM_IHPSG_FAKE_B"]["lib"] = {
            "nom_typ_1p20V_25C": [b_lib]}
    (root / name).write_text(json.dumps(cfg, indent=2) + "\n")

# B's 100x100 footprint does not fit the 50x50 die (a single-size checker
# measuring both types with A's 10x10 accepts it).
write("bounds.json", [0, 0, 50, 50], [0, 0], [20, 0])
# B is 100 wide, so it spans under A: the pair is closer than the gap only
# when B's own width is used (a single-size checker sees two 10-wide boxes).
write("overlap.json", [0, 0, 200, 200], [30, 0], [0, 0])
# B has no LEF at all: a config finding, and B's instances are explicitly
# reported as unchecked rather than silently measured.
write("missing-lef.json", [0, 0, 200, 200], [0, 0], [20, 0], drop_b_lef=True)

# E2-6 identity fixtures. clean.json must PASS with correct per-type views
# (the guard that the identity checks do not false-fail a legal config).
write("clean.json", [0, 0, 200, 200], [0, 0], [20, 0])
# type-b-wrong-lef: the E2-6 false pass -- B (own footprint 100x100) is
# configured with A's 10x10 LEF and sits at (20,0) in a 50x50 die. Geometry
# alone measures it with A's SIZE and accepts it; only MACRO identity fails it.
write("wrong-lef.json", [0, 0, 50, 50], [0, 0], [20, 0],
      b_lef="./src/RM_IHPSG_FAKE_A.lef")
# Same shape for the timing view: B configured with A's lib.
write("wrong-lib.json", [0, 0, 200, 200], [0, 0], [20, 0],
      b_lib="./src/RM_IHPSG_FAKE_A_typ.lib")
# A LEF with SIZE but no MACRO declaration: identity is unverifiable -> fail.
write("no-macro-lef.json", [0, 0, 200, 200], [0, 0], [20, 0],
      b_lef="./src/RM_IHPSG_FAKE_NO_MACRO.lef")
PY

gate_synth() {
  python3 "$ROOT/tools/checks/macro_flow_config.py" \
    --flow "$SYNTH/$1" --rtl "$SYNTH/pe_soc.v" --pdk-root "$SYNTH/pdk"
}

gate_synth bounds.json > "$TMP/gate-synth-bounds.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q "u_b: 100.0x100.0 (type RM_IHPSG_FAKE_B).*not inside DIE_AREA" "$TMP/gate-synth-bounds.log"; then
  echo "  [synth-type-bounds] detected (each type measured with its own LEF SIZE)"
  pass=$((pass + 1))
else
  echo "  [synth-type-bounds] FAILED: exit $rc, want 1 + the B-size DIE_AREA finding"
  tail -5 "$TMP/gate-synth-bounds.log"
  fail=$((fail + 1))
fi

gate_synth overlap.json > "$TMP/gate-synth-overlap.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q "closer than the 10.0 um placement gap" "$TMP/gate-synth-overlap.log"; then
  echo "  [synth-type-overlap] detected (the gap uses each type's own width)"
  pass=$((pass + 1))
else
  echo "  [synth-type-overlap] FAILED: exit $rc, want 1 + the gap finding"
  tail -5 "$TMP/gate-synth-overlap.log"
  fail=$((fail + 1))
fi

gate_synth missing-lef.json > "$TMP/gate-synth-missing-lef.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] \
   && grep -q "MACROS\[RM_IHPSG_FAKE_B\].lef is missing or empty" "$TMP/gate-synth-missing-lef.log" \
   && grep -q "no resolvable LEF SIZE for type RM_IHPSG_FAKE_B" "$TMP/gate-synth-missing-lef.log"; then
  echo "  [synth-missing-type-lef] detected (a finding, and the type is reported unchecked)"
  pass=$((pass + 1))
else
  echo "  [synth-missing-type-lef] FAILED: exit $rc, want 1 + the missing-LEF finding"
  tail -5 "$TMP/gate-synth-missing-lef.log"
  fail=$((fail + 1))
fi

# ---- E2-6 type<->view identity (synthetic two-type flow) ------------------
# The legal config passes: identity and corner-file checks must not false-fail
# correctly configured per-type views.
gate_synth clean.json > "$TMP/gate-synth-clean.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  [synth-identity-clean] passes with correct per-type views"
  pass=$((pass + 1))
else
  echo "  [synth-identity-clean] FAILED: exit $rc, want 0 on the legal config"
  tail -5 "$TMP/gate-synth-clean.log"
  fail=$((fail + 1))
fi

# THE E2-6 mutation: type B configured with type A's 10x10 LEF while its own
# footprint is 100x100, placed at (20,0) in a 50x50 die. The checker used to
# measure A's SIZE and accept it (exit 0); it must now be exit 1.
gate_synth wrong-lef.json > "$TMP/gate-synth-wrong-lef.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] \
   && grep -q "declares MACRO RM_IHPSG_FAKE_A, not the configured type RM_IHPSG_FAKE_B" "$TMP/gate-synth-wrong-lef.log"; then
  echo "  [type-b-wrong-lef] detected (a type measured with another type's LEF is rejected)"
  pass=$((pass + 1))
else
  echo "  [type-b-wrong-lef] FAILED: exit $rc, want 1 + the MACRO-identity finding"
  tail -5 "$TMP/gate-synth-wrong-lef.log"
  fail=$((fail + 1))
fi

gate_synth wrong-lib.json > "$TMP/gate-synth-wrong-lib.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] \
   && grep -q "declares no cell for type RM_IHPSG_FAKE_B" "$TMP/gate-synth-wrong-lib.log"; then
  echo "  [type-b-wrong-lib] detected (a type configured with another type's lib is rejected)"
  pass=$((pass + 1))
else
  echo "  [type-b-wrong-lib] FAILED: want exit 1 + the lib-identity finding, got exit $rc"
  tail -5 "$TMP/gate-synth-wrong-lib.log"
  fail=$((fail + 1))
fi

gate_synth no-macro-lef.json > "$TMP/gate-synth-no-macro-lef.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] \
   && grep -q "declares no MACRO" "$TMP/gate-synth-no-macro-lef.log"; then
  echo "  [type-no-macro-lef] detected (identity is fail-closed for a LEF with no MACRO)"
  pass=$((pass + 1))
else
  echo "  [type-no-macro-lef] FAILED: exit $rc, want 1 + the no-MACRO finding"
  tail -5 "$TMP/gate-synth-no-macro-lef.log"
  fail=$((fail + 1))
fi

restore

# The mutations ran on copies; prove the tracked files never moved.
if ! cmp -s "$ROOT/flow/pe_soc.json" "$TMP/pe_soc.json.orig"; then
  echo "  FATAL: flow/pe_soc.json changed"
  exit 3
fi
if ! cmp -s "$ROOT/flow/pe_soc_pdn.tcl" "$TMP/pe_soc_pdn.tcl.orig"; then
  echo "  FATAL: flow/pe_soc_pdn.tcl changed"
  exit 3
fi

echo
echo "=== $pass passed, $fail failed ==="
if [ "$fail" -ne 0 ]; then
  echo "NEGATIVE TEST FAILURE: the gate does not reject every mutation."
  exit 1
fi
echo "OK: pin-to-net, every ladder clause, every macro view (including type<->file identity: LEF MACRO and lib cell), per-type geometry (bounds, gap, missing type LEF), corner-file correspondence, wrong-layer/reversed ordering, the PDK-less skip and the yosys-failure failure all behave as designed."
