"""The firmware's labels and their addresses, from the ASSEMBLER'S OWN LISTING.

A probe may then be pointed at `L_enc_drive` instead of a decimal, which is how
this act lost six placements to an edit that moved a label under a probe that
had the old number written into it. Nothing here hand-writes an address, and
nothing here survives an edit to the firmware.

Every failure in here is LOUD and says what it was: this is a generator whose
output a probe's correctness depends on, so a partial or empty answer is worse
than no answer at all, and a file that half-parsed would put wrong addresses
into a probe that then reports a fault that is not there.

RUN AS A SCRIPT it prints the Verilog `define lines, which is what the rest of
this block's tooling expects. IMPORTED, it gives the same numbers as a dict,
which is what run.sh substitutes into a probe -- because a macro's usefulness
depends on a backtick surviving the trip, and in this act it never has.
"""

import re
import subprocess
from pathlib import Path

F = Path("firmware/bmc_frame.pe")
OPS = r"^(LDI|OUT|IN|MOV|JMP|JZ|JNZ|ADD|SUB|AND|OR|INCX|DECX|SHR|LDS|STS|LDM|STM|NOP)\b"

if not F.is_file():
    raise SystemExit(f"labels.py: {F} is not there; run this from the repository root")


def addresses(root=None):
    """{label: address} for the firmware, counted against the assembler's own
    listing. This is the whole of what a probe is allowed to know about where
    the firmware's words are, and it is recomputed on every probe build."""
    root = Path(root) if root else Path(__file__).resolve().parents[2]
    f = root / F
    if not f.is_file():
        raise SystemExit(f"labels.py: {f} is not there")

    # The listing is asked for rather than counted here: if the assembler and
    # this script ever disagree about what a word is, the assembler's answer is
    # the one that is right, and check=True below is what says so instead of an
    # empty string flowing onwards into every address below.
    listing = subprocess.run(
        ["python3", "tools/fw/peasm.py", str(f), "--listing"],
        capture_output=True,
        text=True,
        cwd=root,
        check=True,
    ).stdout

    addr, labels = 0, {}
    with f.open() as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith(";"):
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", s)
            if m and not re.match(OPS, s):
                labels[m.group(1)] = addr
                if not m.group(2).strip():
                    continue
            if re.match(OPS, s):
                addr += 1

    words = len(re.findall(r"^\s*\d+\s+[0-9A-Fa-f]{4}\s", listing, re.MULTILINE))
    if words != addr:
        raise SystemExit(
            f"labels.py counted {addr} words and the assembler's listing has "
            f"{words}: the two disagree about the program, and every address "
            f"below would be wrong"
        )
    return labels


def main():
    labels = addresses()
    print(f"// generated from {F} -- do not hand-write these")
    for name, value in labels.items():
        print(f"`define L_{name} 10'd{value}")


if __name__ == "__main__":
    main()
