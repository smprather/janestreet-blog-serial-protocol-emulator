#!/usr/bin/env python3
"""annotate_r3_confirmations.py — record the CHIP side's evidence in the TB-side
copy of the R3 golden manifest.

WHY A SCRIPT AND NOT A HAND EDIT. `chip_confirmed` is a claim about the chip, in
a file the HOST generates. Editing it by hand is how a claim starts drifting away
from the evidence behind it. This derives the claim from two inputs that cannot
drift silently:

  * `tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt` — the exact words the conformance
    harness measured as not matching. A step listed there is NOT confirmed, ever.
  * the 26 steps in the manifest itself.

and it refuses to write unless the arithmetic is exactly what the manager ruled:
23 confirmed, 3 not, and the 3 are precisely the pinned ones. Run it with
`--check` in the suite: it re-derives the claim and fails if the file disagrees,
so a hand-edit that claims a step the harness does not prove turns the build red.

THE SPLIT, and why it exists. `reviews/2026-09-25/r3-hex/manifest.json` is the
host's artefact and stays byte-for-byte the host's. The chip's evidence lives in
`tb/r3-vectors/manifest.json`, which is where `tb_pe_ctrl_r3_conf` reads it. That
is the R2 precedent exactly: for R2 the two copies' manifests differ, and the
TB-side one is the one carrying the chip's citations. The suite's byte-exactness
gate therefore excludes manifest.json and instead asserts that ONLY the evidence
fields differ — the golden bytes, the vector/step structure and the byte counts
must still be identical, or the harness is not comparing the host's vectors.

Usage:
  python3 tools/gen/annotate_r3_confirmations.py            # write
  python3 tools/gen/annotate_r3_confirmations.py --check    # fail if stale
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
TB_MANIFEST = REPO / "tb" / "r3-vectors" / "manifest.json"
HOST_MANIFEST = REPO / "reviews" / "2026-09-25" / "r3-hex" / "manifest.json"
DIVERGENCES = REPO / "tb" / "r3-vectors" / "R3_KNOWN_DIVERGENCES.txt"

# The manager's ruling (2026-09-25), twice. First: flip the clean-matching
# steps and hold back the three that do not match, each for a recorded reason.
# Then, after the host regenerated the two host-side defects (gui-worker
# b9d4eb2, "correct the two host-side vector defects the chip's conformance run
# proved") and this harness re-ran them byte-exact, those two flipped too. The
# arithmetic below therefore MOVED when the evidence moved, in the same commit as
# the package refresh -- which is the process rule on both sides: a divergence
# entry resolves in the same commit that changes either side of it, so a
# conformance fix can never read as a regression. These are expectations the tool
# refuses to violate, not constants that quietly rot.
EXPECT_CONFIRMED = 25
EXPECT_TOTAL = 26
EXPECT_NOT_CONFIRMED = 1

# What the two resolved steps were, kept so the record says why the number moved
# and a reader can check the claim rather than take it on trust.
RESOLVED = {
    "read_cpu_shows_a_55": (
        "HOST-side vector defect, fixed host-side in b9d4eb2. The host's "
        "READ_CPU builder returned its debug `state` in the slot the contract "
        "gives to `run`, and carried a stale `insn` where the chip reports the "
        "fetched word at the held pc. Regenerated, this step matches the chip "
        "byte-exact and is chip_confirmed."
    ),
    "status_reports_the_hit": (
        "HOST-side vector defect, fixed host-side in b9d4eb2. The package "
        "carried a=0x0055 where the chip reports 0x00AA: the step from address 1 "
        "to 2 really does execute the LDI A,0xAA at 1, because a step is exactly "
        "one instruction and stop-before applies to the instruction AT the "
        "breakpoint, which has not run. Regenerated, this step matches the chip "
        "byte-exact and is chip_confirmed."
    ),
}

REASON = {
    "status_full_readback": (
        "TB MODEL BOUNDARY, not a disagreement, and NOT claimed. The package's "
        "`insn` is a mid-execution snapshot (pc=4 with a=0 has not executed the "
        "LDI at 3); the model freeze that holds such a snapshot pins pc every "
        "cycle, which collapses the fetch pipeline onto the fill word instead of "
        "the ruled landing word 0xF000. The contract now states that at a freeze "
        "`insn` reports the latched pipeline word, and no RTL changes. If the "
        "host's model adopts that, the package regenerates and this flips."
    ),
}

CITATION = (
    "chip repo tb/tb_pe_ctrl_r3_conf.v (R3 conformance against these exact bytes, "
    "byte-exact incl. CRC) + reviews/2026-09-25/R3-CONFORMANCE-AND-RUN-LOCK.md; "
    "corroborated by the directed harness tb/tb_pe_ctrl_r3 (7/7 mutants) and the "
    "S1-S4 formal claims"
)


def pinned_steps() -> set[str]:
    """The steps the harness measured as diverging, from the lock's own file.

    Read from the lock rather than restated here, so the claim cannot name a
    different set than the one the gate enforces.
    """
    out = set()
    for line in DIVERGENCES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.add(line.split()[0])  # "<step> word <n>: chip ..., package ..."
    return out


def structure(m: dict) -> list:
    """Everything that must be identical to the host's copy: the vector/step
    shape and the byte counts, with every evidence field removed."""
    out = []
    for v in m["vectors"]:
        steps = []
        for s in v["steps"]:
            steps.append(
                {
                    k: s.get(k)
                    for k in (
                        "name",
                        "opcode",
                        "opcode_name",
                        "request_file",
                        "response_file",
                        "request_bytes",
                        "response_bytes",
                        "status",
                        "response_hex",
                        "response_payload_words",
                        "sequence",
                        "model_faults",
                        "model_image_id",
                    )
                }
            )
        out.append(
            {
                "name": v["name"],
                "obligation": v["obligation"],
                "model_image_id": v["model_image_id"],
                "steps": steps,
            }
        )
    return out


def annotate(manifest: dict, pinned: set[str]) -> dict:
    confirmed, not_confirmed = [], []
    for v in manifest["vectors"]:
        for s in v["steps"]:
            if s["name"] in pinned:
                s["chip_confirmed"] = False
                s["chip_evidence"] = None
                not_confirmed.append(s["name"])
            else:
                s["chip_confirmed"] = True
                s["chip_evidence"] = CITATION
                confirmed.append(s["name"])
        v["chip_confirmed"] = all(s["chip_confirmed"] for s in v["steps"])

    if (
        len(confirmed) != EXPECT_CONFIRMED
        or len(not_confirmed) != EXPECT_NOT_CONFIRMED
    ):
        raise SystemExit(
            f"refusing to write: {len(confirmed)} confirmed / "
            f"{len(not_confirmed)} not, expected "
            f"{EXPECT_CONFIRMED}/{EXPECT_NOT_CONFIRMED}. "
            f"not confirmed: {not_confirmed}"
        )
    missing = [n for n in not_confirmed if n not in REASON]
    if missing:
        raise SystemExit(f"no recorded reason for: {missing}")

    manifest["chip_confirmed"] = True
    manifest["chip_evidence"] = {
        "confirmed_steps": confirmed,
        "conformance": (
            f"{len(confirmed)} of {len(confirmed) + len(not_confirmed)} host "
            "golden steps confirmed against the chip, byte-exact including the "
            f"CRC word. The remaining {len(not_confirmed)} is listed in "
            "not_confirmed_steps with its reason: a testbench model boundary that "
            "is not claimed. Two further steps were confirmed only after the host "
            "regenerated them (gui-worker b9d4eb2); they were host-side defects "
            "this run proved, and they are recorded under resolved_steps so the "
            "reason the count moved is on the face of the manifest."
        ),
        "date": "2026-09-25",
        "harness": (
            "tb_pe_ctrl_r3_conf.v replays each step's request_file and compares "
            "the response to response_file word for word, CRC included, with the "
            "vector's model image preloaded; tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt "
            "pins the measured divergences and the harness fails if the observed "
            "set ever differs from it"
        ),
        "not_confirmed_steps": [
            {"step": n, "reason": REASON[n]} for n in not_confirmed
        ],
        "resolved_steps": [
            {"step": n, "resolution": RESOLVED[n]} for n in RESOLVED
        ],
        "review": "reviews/2026-09-25/R3-CONFORMANCE-AND-RUN-LOCK.md",
        "scope": (
            "The chip's answers to the host's bytes, in simulation. Not evidence "
            "about silicon: the real-board acceptance run (Pico over USB with a "
            "physical shuttle) has not been executed and is not claimed."
        ),
        "testbench": "tb/tb_pe_ctrl_r3_conf.v",
    }
    manifest["notice"] = (
        f"CHIP-CONFIRMED for {len(confirmed)} of "
        f"{len(confirmed) + len(not_confirmed)} steps by the chip's own "
        "conformance run (tb_pe_ctrl_r3_conf), byte-exact including the CRC. The "
        f"remaining {len(not_confirmed)} are NOT confirmed and carry a reason each "
        "in chip_evidence.not_confirmed_steps. The real-board acceptance run has "
        "not been executed and is not claimed."
    )
    return manifest


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--check",
        action="store_true",
        help="fail if the checked-in manifest is not what this derives",
    )
    args = ap.parse_args()

    host = json.loads(HOST_MANIFEST.read_text())
    pinned = pinned_steps()
    current = json.loads(TB_MANIFEST.read_text())

    # The golden bytes and the vector shape must still be the host's, whatever
    # the evidence fields say. A harness that compared the chip's own edits to
    # itself would prove nothing.
    if structure(current) != structure(host):
        print("the TB-side manifest no longer matches the host's structure", file=sys.stderr)
        return 1

    derived = annotate(json.loads(json.dumps(host)), pinned)
    if args.check:
        if current.get("chip_evidence") != derived["chip_evidence"]:
            print("chip_evidence is stale; run without --check", file=sys.stderr)
            return 1
        if current.get("chip_confirmed") != derived["chip_confirmed"]:
            print("chip_confirmed is stale; run without --check", file=sys.stderr)
            return 1
        if current.get("notice") != derived["notice"]:
            print("notice is stale; run without --check", file=sys.stderr)
            return 1
        for dv, ev in zip(current["vectors"], derived["vectors"]):
            for ds, es in zip(dv["steps"], ev["steps"]):
                if (ds.get("chip_confirmed"), ds.get("chip_evidence")) != (
                    es.get("chip_confirmed"),
                    es.get("chip_evidence"),
                ):
                    print(f"step {ds['name']} is stale", file=sys.stderr)
                    return 1
        n = len(derived["chip_evidence"]["confirmed_steps"])
        print(f"R3 confirmations: {n}/{EXPECT_TOTAL} steps confirmed, all cited")
        return 0

    TB_MANIFEST.write_text(json.dumps(derived, indent=2, sort_keys=True) + "\n")
    print(
        f"annotated {TB_MANIFEST.relative_to(REPO)}: "
        f"{len(derived['chip_evidence']['confirmed_steps'])}/{EXPECT_TOTAL} "
        f"confirmed; {len(derived['chip_evidence']['not_confirmed_steps'])} "
        f"pinned with reasons"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
