#!/usr/bin/env bash
# check_r2_package.sh — tb/r2-vectors/ is a DERIVED SNAPSHOT of the host's golden
# package, and this proves it still is.
#
# WHY (manager ruling 2026-09-26). One source of truth: the host generator. The
# chip repo keeps a snapshot so its conformance TB can $readmemh the bytes, and
# this gate is what stops the snapshot from quietly becoming a second source.
# The class died TWICE on 2026-09-25/26, in two different shapes, and both are
# checked here:
#   1. the SNAPSHOT DRIFTED — the copy was 18 steps while the host was at 22, so
#      the TB reported 22/22 against a table that never named three of its own
#      steps, and the package's notice claimed "every golden step passes" while
#      its own conformance line said 15/15. Nobody noticed, because every gate
#      compared the .hex BYTES and none of them looked at the FLAGS the manifest
#      carries.
#   2. a NOTICE THAT CONTRADICTS ITS OWN FILE — the F1 class, and a stale
#      hand-written sentence cannot be fixed by regenerating anything.
# So the gate checks bytes AND flags AND derived files AND the notice's
# arithmetic, and it is wired into the full suite.
#
# WHAT IS COMPARED. Unlike the R3 package, manifest.json is NOT excluded here:
# this snapshot is a byte copy of the host's, and the chip's own evidence for
# each confirmation lives in reviews/2026-09-25/R2-HELD-CORE-CHIP-SIDE.md rather
# than in an edited copy of somebody else's file. Editing the snapshot's manifest
# is therefore drift, and that is the point.
set -u
cd "$(dirname "$0")/.." || exit 1

HOST_PKG=reviews/2026-09-25/r2-hex
SNAP=tb/r2-vectors
bad=0

# 1. BYTES: the snapshot must hold the host package's bytes, file for file. The
#    DERIVED files are excluded here and validated against the manifest in step 2
#    instead — they are generated from it, so they belong to neither package.
#    (Excluding them without validating them would be the hole the R2/R3 gates
#    already had: a derived file that drifts from its own source.)
DERIVED=(R2_CONFORMANCE_RUN.vh R2_READ_EXPECT.vh R2_READ_STEPS.vh r2_steps.txt)
EXC=()
for d in "${DERIVED[@]}"; do EXC+=(--exclude="$d"); done
if diff -r "${EXC[@]}" "$HOST_PKG" "$SNAP" > /tmp/r2_pkg_diff.log 2>&1; then
  :
else
  echo "FAIL snapshot drift: $SNAP does not carry $HOST_PKG's bytes"
  head -12 /tmp/r2_pkg_diff.log | sed 's/^/    /'
  bad=$((bad + 1))
fi

# 2. FLAGS + 3. NOTICE ARITHMETIC, and 4. THE DERIVED FILES, all from the
#    manifest, so a package whose bytes are fine but whose CLAIMS are not still
#    fails.
python3 - "$HOST_PKG" "$SNAP" <<'PY' || bad=$((bad + 1))
import json, re, sys, pathlib
host, snap = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
fail = []
hm = json.loads((host / "manifest.json").read_text())
sm = json.loads((snap / "manifest.json").read_text())
steps = [s for v in hm["vectors"] for s in v["steps"]]
conf = [s for s in steps if s.get("chip_confirmed")]

# the snapshot's flags must equal the host's, step for step
if len(sm["vectors"]) != len(hm["vectors"]):
    fail.append(f"vector count {len(sm['vectors'])} != host {len(hm['vectors'])}")
ssteps = [s for v in sm["vectors"] for s in v["steps"]]
if len(ssteps) != len(steps):
    fail.append(f"step count {len(ssteps)} != host {len(steps)}")
for a, b in zip(ssteps, steps):
    if bool(a.get("chip_confirmed")) != bool(b.get("chip_confirmed")):
        fail.append(f"chip_confirmed differs on {a.get('name')}: snapshot={a.get('chip_confirmed')} host={b.get('chip_confirmed')}")

# THE NOTICE, against the flags it lives beside. A notice that says "every" while
# some step is unconfirmed is false in the same file that carries the flag, which
# is the F1 shape; and a count that disagrees with the conformance line is the
# same defect twice. Both are checked here rather than trusted to the generator.
notice = sm.get("notice", "")
ce = (sm.get("chip_evidence") or {}).get("conformance", "")
n_steps, n_conf = len(steps), len(conf)
if re.search(r"\bevery\b", notice, re.I) and n_conf != n_steps:
    fail.append(f"notice says 'every' but only {n_conf} of {n_steps} steps are chip_confirmed")
for label, text in (("notice", notice), ("chip_evidence.conformance", ce)):
    # Only counts that are unambiguously STEP counts. The first version of this
    # check matched a bare "2/3" in prose and failed a perfectly good package -
    # the reviewer being wrong twice in one gate is a warning sign worth taking
    # seriously, so the pattern now has to see the word it is counting.
    for m in re.finditer(r"(\d+)\s*/\s*(\d+)(?=\s*(?:golden\s+)?steps?\b)", text):
        got, tot = int(m.group(1)), int(m.group(2))
        if tot != n_steps:
            fail.append(f"{label} says {got}/{tot} steps but the package has {n_steps}")
        elif got != n_conf and "not" not in text[max(0, m.start() - 30):m.start()].lower():
            fail.append(f"{label} says {got}/{tot} confirmed but {n_conf} steps are chip_confirmed")

# THE DERIVED FILES must follow the manifest, not memory: one table line per step
# in order, and one r2_step per step with the manifest's own byte counts.
tbl = [l.split() for l in (snap / "r2_steps.txt").read_text().strip().split("\n") if l.strip()]
if len(tbl) != n_steps:
    fail.append(f"r2_steps.txt has {len(tbl)} lines for {n_steps} steps")
else:
    for row, s in zip(tbl, steps):
        want = [s["name"], s["request_file"], s["response_file"],
                str(s["request_bytes"]), str(s["response_bytes"]), str(s.get("model_faults", 0))]
        if row != want:
            fail.append(f"r2_steps.txt line for {s['name']} is {row}, manifest says {want}")
vh = (snap / "R2_CONFORMANCE_RUN.vh").read_text()
calls = re.findall(r'r2_step\((\d+),\s*(\d+),\s*"([^"]+)"', vh)
if len(calls) != n_steps:
    fail.append(f"R2_CONFORMANCE_RUN.vh has {len(calls)} r2_step calls for {n_steps} steps")
else:
    for (rq, rs, nm), s in zip(calls, steps):
        if nm != s["name"] or (int(rq), int(rs)) != (s["request_bytes"], s["response_bytes"]):
            fail.append(f".vh step {nm} ({rq},{rs}) != manifest {s['name']} ({s['request_bytes']},{s['response_bytes']})")

if fail:
    for f in fail[:12]:
        print(f"    - {f}")
    print(f"check_r2_package: {len(fail)} problem(s) — {n_conf}/{n_steps} steps chip_confirmed")
    sys.exit(1)
print(f"check_r2_package: snapshot is byte-identical to the host package; "
      f"{n_conf}/{n_steps} steps chip_confirmed; notice, table and include all agree")
PY

if [ "$bad" -ne 0 ]; then
  echo "check_r2_package: FAILED — the snapshot is no longer a faithful copy of the host's golden package"
  exit 1
fi
echo "check_r2_package: OK"
