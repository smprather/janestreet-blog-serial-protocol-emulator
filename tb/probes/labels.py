"""Emit Verilog `L_<label>` defines for every label in the firmware, with the
addresses taken from a first pass that mirrors the assembler's own counting.

A probe may then be pointed at `L_enc_drive` instead of a decimal, which is how
this act lost six placements to an edit that moved a label under a probe that
had the old number written into it. Nothing here hand-writes an address, and
nothing here survives an edit to the firmware.

Every failure in here is LOUD and says what it was: this is a generator whose
output a probe's correctness depends on, so a partial or empty answer is worse
than no answer at all, and a file that half-parsed would put wrong addresses
into a probe that then reports a fault that is not there.
"""

import re
import subprocess
from pathlib import Path

F = Path("firmware/bmc_frame.pe")
OPS = r"^(LDI|OUT|IN|MOV|JMP|JZ|JNZ|ADD|SUB|AND|OR|INCX|DECX|SHR|LDS|STS|LDM|STM|NOP)\b"

if not F.is_file():
    raise SystemExit(f"labels.py: {F} is not there; run this from the repository root")

# The listing is asked for rather than counted here: if the assembler and this
# script ever disagree about what a word is, the assembler's answer is the one
# that is right, and check=True below is what says so instead of an empty string
# flowing onwards into every L_ define.
listing = subprocess.run(
    ["python3", "tools/fw/peasm.py", str(F), "--listing"],
    capture_output=True,
    text=True,
    check=True,
).stdout

addr, labels = 0, {}
with F.open() as fh:
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
        f"{words}: the two disagree about the program, and every L_ define "
        f"below would be wrong"
    )

print(f"// generated from {F} -- do not hand-write these")
for name, value in labels.items():
    print(f"`define L_{name} 10'd{value}")
