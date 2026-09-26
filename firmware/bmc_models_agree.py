#!/usr/bin/env python3
"""bmc_models_agree.py -- the two models of the wire RULES must agree with each
other, and neither of them is told what the other says.

    python3 firmware/bmc_models_agree.py

Exit 0 = the eighty levels match in both polarities; 1 = they do not.

WHY THIS EXISTS, AND IT IS THE LAST THING THAT COULD HAVE BEEN WRONG WITHOUT
ANYBODY NOTICING.

Act (c)'s level check compares the firmware's pad against a model, eighty
levels per pass, in both polarities, and it is the check that made the return
leg green. **But the model it compares against lives inside the same
testbench that runs the firmware** -- `enc_wire_lev` in tb_pe_soc_bmc.v -- so
every level this act has ever reported was measured against a function with
no witness but itself. A wrong model does not show up as a red pad: it shows
up as a GREEN pad measured against the wrong thing, which is the most
expensive shape a mistake can take here, because it looks exactly like success.

There is a SECOND implementation of the same wire rules and it is independent
of the first in every way that matters: `firmware/bmc_model.py` is Python,
`enc_wire_lev` is Verilog, they were written from the prose of the encoding
rather than from each other, and the Python one is the artefact the firmware
was transcribed FROM. So the question is not whether either is right -- it is
whether they are the same, because two implementations of one specification
that disagree have already found the specification's ambiguity, and two that
agree have made each other falsifiable.

**MEASURED, and they agree: 80 levels in each of two polarities, identical.**
That is the result this file exists to keep re-earning. The comparison is the
whole check; the models are not modified, not shared, and not imported into
each other, because a model told what the other model says is one model.

WHAT IT IS NOT. This does not replace the level check. It says nothing about
the FIRMWARE -- the pad could be wrong in eighty ways and both models would
still agree with each other, because neither of them is the hardware. It
bounds a different fault: it stops the act's reference from being a function
that only ever confirms itself, which is the one failure this act could not
otherwise have detected and could not afterwards have been shown to detect.
"""

import contextlib
import importlib.util
import io
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRAME_LEVELS = 80


def python_model(said):
    """the eighty levels per polarity, from bmc_model.py -- run, not imported
    for its side effects, because its top level prints a self-check whose
    output is not this file's to reproduce. `said` is supplied by the caller so
    that a model which exits on its own self-check still has its words
    available to the handler, which is the entire point of the argument below.
    """
    path = ROOT / "firmware/bmc_model.py"
    spec = importlib.util.spec_from_file_location("bmc_model", path)
    # spec_from_file_location returns None for a file it cannot make a spec
    # for, and every attribute below is then an AttributeError on None. A
    # missing model file must say WHICH file, not fail three lines later.
    if spec is None or spec.loader is None:
        raise SystemExit(
            f"bmc_models_agree: cannot build an import spec for {path}, so "
            f"there is no Python model to compare against"
        )
    mod = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(said):
        spec.loader.exec_module(mod)
    if not hasattr(mod, "Tx") or not hasattr(mod, "TX_HALF_TOTAL"):
        raise SystemExit(
            "bmc_models_agree: bmc_model.py no longer models the return leg "
            "(no Tx / TX_HALF_TOTAL), so there is nothing to compare and this "
            "check would pass by having no input"
        )
    out = {}
    for flag in (0, 1):
        wire = mod.Tx(flag).run().wire[: mod.TX_HALF_TOTAL]
        if len(wire) != FRAME_LEVELS:
            raise SystemExit(
                f"bmc_models_agree: bmc_model.py produced {len(wire)} levels "
                f"for flag {flag}, not {FRAME_LEVELS}"
            )
        out[flag] = "".join(str(x) for x in wire)
    return out


def python_model_or_report():
    """python_model(), but a model that FAILS ITS OWN SELF-CHECK is reported
    with what it said rather than as a bare exit code.

    `bmc_model.py` ends with a MODEL SELF-CHECK that calls sys.exit(1) when a
    property fails, after printing which ones. The first version of this file
    swallowed its stdout and re-raised, so a broken model made THIS check
    exit 1 having printed ABSOLUTELY NOTHING -- and a gate that fails
    silently is indistinguishable from a gate that hung, which is the same
    blindness twice over. A monitor that reports an absence as nothing is the
    fault this act has now found in nine instruments, and the tenth is the
    one written at the end to catch the other nine.
    """
    said = io.StringIO()
    try:
        return python_model(said), said.getvalue()
    except SystemExit as e:
        text = said.getvalue()
        raise SystemExit(
            f"bmc_models_agree: bmc_model.py stopped with exit {e.code}, so "
            f"the Python side of this comparison is not trustworthy and the "
            f"comparison is NOT run. What it said:"
            + (f"\n{text.rstrip()}" if text.strip() else " (it printed NOTHING)")
        )
    except Exception as e:  # noqa: BLE001 -- the reason must be on the screen
        text = said.getvalue()
        raise SystemExit(
            f"bmc_models_agree: the Python model did not run: {e}"
            + (f"\n{text.rstrip()}" if text.strip() else "")
        )


def verilog_model():
    """the same eighty levels, printed by the testbench's OWN model, in the
    order the testbench uses them: pass 0 is FM0, pass 1 is FM1"""
    # check=False EXPLICITLY: a non-zero exit is handled below, and turned
    # into a message naming the missing PASS line, which is more use than a
    # CalledProcessError. The default is False anyway, but the act's rule is
    # that a reviewer should not have to know that.
    r = subprocess.run(
        ["tb/probes/run.sh"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    if "PASS" not in r.stdout:
        raise SystemExit(
            "bmc_models_agree: the testbench did not pass, so its model cannot "
            "be read -- fix the simulation first, because a comparison against "
            "a failing run is a comparison against nothing"
        )
    levels = re.findall(r"^\s*the model\s*:\s*([01]+)\s*$", r.stdout, re.MULTILINE)
    if len(levels) != 2:
        raise SystemExit(
            f"bmc_models_agree: found {len(levels)} model lines in the "
            f"testbench output, expected 2 (one per polarity)"
        )
    for s in levels:
        if len(s) != FRAME_LEVELS:
            raise SystemExit(
                f"bmc_models_agree: the testbench's model line is {len(s)} "
                f"levels, not {FRAME_LEVELS}"
            )
    return {0: levels[0], 1: levels[1]}


def compare_one(py_s, v_s, name, emit=True):
    """Compare one polarity's two eighty-level strings. Returns True if they
    agree, and prints the disagreement -- where, how many, and both strings in
    full -- when they do not.

    EXTRACTED FROM main() SO THAT IT CAN BE EXERCISED WITHOUT A SIMULATION,
    which is the whole point of the extraction. The disagreement branch was
    written, printed a count, and had never been seen to fire: the two models
    can only disagree if BOTH are internally consistent and one of them is
    misreading the encoding, because each model's own self-check catches it
    first. So a live disagreement needs a fault in the ENCODING, in a file, and
    injecting one into either model just trips that model's own self-check
    first -- the branch was unreachable by injection, and `self_test()` below
    is how it gets coverage instead.
    """
    if py_s == v_s:
        if emit:
            print(
                f"  {name}: bmc_model.py and tb_pe_soc_bmc.v agree on all "
                f"{FRAME_LEVELS} levels"
            )
        return True
    if len(py_s) != len(v_s):
        raise SystemExit(
            f"bmc_models_agree: the two {name} strings are different LENGTHS "
            f"({len(py_s)} and {len(v_s)}), which is not a disagreement about "
            f"levels but a disagreement about how many there are"
        )
    diff = [i for i, (a, b) in enumerate(zip(py_s, v_s)) if a != b]
    if emit:
        print(
            f"  {name}: THE TWO MODELS DISAGREE at {len(diff)} of "
            f"{FRAME_LEVELS} half-intervals, first at {diff[0]}"
        )
        for i in diff[:8]:
            print(f"      half-interval {i:2d}: python {py_s[i]} verilog {v_s[i]}")
        print(f"      python : {py_s}")
        print(f"      verilog: {v_s}")
    return False


def self_test():
    """Prove the comparison, both ways, with no simulation and no models.

    THIS IS THE PART THAT WAS MISSING. The check existed to catch two
    implementations of one specification disagreeing, and the branch that does
    the catching had never run, because reaching it needs a fault that is
    invisible to both models' own self-checks. **A check that has never been
    shown to fire is a comment**, and this one was the load-bearing one, so it
    is exercised here against strings built to disagree on purpose.
    """
    ok = True
    base = ("01" * 40)[:FRAME_LEVELS]

    def case(what, py_s, v_s, want):
        nonlocal ok
        # emit=True into a buffer, NOT emit=False: the "a disagreement must not
        # be silent" half of this harness is worth nothing if the comparison is
        # called with its printing switched off. The first version did exactly
        # that, so every disagreement case was reported as a defect in the
        # COMPARISON when the fault was in the HARNESS -- which is a reminder
        # that a failing self-test names a location, not a culprit.
        quiet = io.StringIO()
        with contextlib.redirect_stdout(quiet):
            got = compare_one(py_s, v_s, "SELF-TEST", emit=True)
        said = quiet.getvalue()
        good = got is want
        if not want and not said:
            good = False  # a silent disagreement is this act's ninth instrument
        print(
            f"  {'ok  ' if good else 'FAIL'} {what}"
            + ("" if good else f"  (returned {got}, said {said.strip()[:60]!r})")
        )
        ok = ok and good

    # The base string ALTERNATES, so a "flip" has to go to the OTHER value:
    # the first version of this case used "0" + base[1:], and base already
    # starts with "0", so it compared a string with ITSELF and the harness
    # correctly reported that a disagreement had gone unnoticed.
    case("identical strings agree", base, base, True)
    case("one flipped bit is caught", base, "1" + base[1:], False)
    case(
        "the LAST bit flipped is caught",
        base,
        base[:-1] + ("1" if base[-1] == "0" else "0"),
        False,
    )
    case(
        "a whole byte inverted is caught",
        base,
        "".join("1" if c == "0" else "0" for c in base[:8]) + base[8:],
        False,
    )
    try:
        compare_one(base, base[:-1], "SELF-TEST", emit=False)
        print("  FAIL  a length mismatch is refused rather than compared")
        ok = False
    except SystemExit:
        print("  ok    a length mismatch is refused, not compared")

    print("SELF-TEST: %s" % ("all comparison cases hold" if ok else "FAILED"))
    return 0 if ok else 1


def main():
    if "--self-test" in sys.argv:
        return self_test()
    py, _said = python_model_or_report()

    try:
        v = verilog_model()
    except subprocess.TimeoutExpired:
        raise SystemExit("bmc_models_agree: the testbench timed out")

    bad = [
        flag
        for flag, name in ((0, "FM0"), (1, "FM1"))
        if not compare_one(py[flag], v[flag], name)
    ]

    if bad:
        print(
            "FAIL: the two models of the wire rules disagree under "
            f"{', '.join('FM' + str(f) for f in bad)}. Neither is wrong by "
            "being a model; one of them is a MISREADING of the encoding, and "
            "every level this act reports is measured against one of them."
        )
        return 1
    print(
        "PASS: two independent models of the wire rules -- Python "
        "bmc_model.py and Verilog enc_wire_lev -- agree on all "
        f"{FRAME_LEVELS} levels in both polarities"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
