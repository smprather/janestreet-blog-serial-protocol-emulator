import re
import subprocess
import sys

# The two open()/subprocess calls below are deliberately NOT wrapped in
# try/except, and a linter says so: this gate is run ON a file, and if the
# file is missing or the assembler will not run, the right behaviour is to
# stop with the reason on the screen. A gate that swallows its own failure and
# prints a clean report is worse than no gate, which is this act's whole
# subject.
f = sys.argv[1] if len(sys.argv) > 1 else "firmware/bmc_frame.pe"
with open(f) as _fh:
    src = _fh.read().split("\n")
addr = 0
labels = {}
mnem = {}
OPS = r"^(LDI|OUT|IN|MOV|JMP|JZ|JNZ|ADD|SUB|AND|OR|INCX|DECX|SHR|LDS|STS|LDM|STM|NOP)\b"
for ln in src:
    s = ln.strip()
    if not s or s.startswith(";"):
        continue
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", s)
    if m and not re.match(OPS, s):
        labels[m.group(1)] = addr
        if not m.group(2).strip():
            continue
    mo = re.match(OPS + r"(.*)$", s)
    if mo:
        mnem[addr] = (mo.group(1), mo.group(2).split(";")[0].strip())
        addr += 1
N = addr
lst = subprocess.run(
    ["python3", "tools/fw/peasm.py", f, "--listing"],
    capture_output=True,
    text=True,
    check=False,
).stdout
words = {}
for l in lst.split("\n"):
    m = re.match(r"^\s*(\d+)\s+([0-9A-Fa-f]{4})\s", l)
    if m:
        words[int(m.group(1))] = int(m.group(2), 16)
inv = {v: k for k, v in labels.items()}
# *** THE TARGET FIELD IS TEN BITS, NOT EIGHT, AND THIS LINE WAS 0xFF FOR A
# WHOLE SESSION. *** The check compares the label map with the ENCODED OPERAND,
# which is what makes it worth having, and it read the operand as `word & 0xFF`.
# That is right only while the program is SHORTER THAN 256 WORDS: act (c)'s
# encoder took this file to 289, and eleven jumps past 255 came back
# "*** MISMATCH ***" on a firmware that is correct. So the check was measuring
# the wrong field, and it did it silently and in the direction that looks like
# a firmware fault -- thirteen mismatches on an encoder that assembles, links
# and runs. The field is arg[PCW-1:0] and PCW is $clog2(IMEM_WORDS) (rtl/
# pe_cpu.v), so the mask is derived from the depth here rather than written
# down: a depth that is not a power of two would make the two disagree, and
# that is the assembler's own guard in a different place. It is in this check's
# history because a check that only ever agreed with a small program is a
# check that has never been asked a question.
PCW = 10
bad = 0
print(f"ONE-LINE JUMP CHECK (label map vs the ENCODED operand, {PCW}-bit target):")
for a in sorted(mnem):
    mn, ops = mnem[a]
    if mn in ("JMP", "JZ", "JNZ"):
        t = ops.split(",")[-1].strip()
        t = int(t, 16) if re.fullmatch(r"0x[0-9a-fA-F]+", t) else labels.get(t)
        o = words[a] & ((1 << PCW) - 1)
        ok = o == t
        bad += 0 if ok else 1
        print(
            f"  {a:3d} {mn:4s} {ops.split(',')[-1].strip():10s} -> {t:3d} ({inv.get(t, '?'):10s}) enc 0x{o:02X}  {'OK' if ok else '*** MISMATCH ***'}"
        )
print(f"  mismatches: {bad}")
seen = set()
st = [0]
while st:
    a = st.pop()
    if a in seen or not (0 <= a < N):
        continue
    seen.add(a)
    mn, ops = mnem[a]
    if mn == "JMP":
        st.append(labels[ops.split(",")[-1].strip()])
    elif mn in ("JZ", "JNZ"):
        st.append(labels[ops.split(",")[-1].strip()])
        st.append(a + 1)
    else:
        st.append(a + 1)
dead = [a for a in range(N) if a not in seen]
print(f"\nREACHABILITY: {len(seen)}/{N} reachable, {len(dead)} dead")
for a in dead:
    print(f"    {a:3d}  {mnem[a][0]:5s} {mnem[a][1]:18s} {inv.get(a, '')}")
# ADJACENT LABELS: two labels on consecutive addresses is a fall-through waiting
# to happen, and it is how the data_zero/resync pair was missed.
print("\nADJACENT LABEL CHECK (a label immediately after another can fall through):")
labs = sorted(labels.items(), key=lambda x: x[1])
for i in range(len(labs) - 1):
    if labs[i][1] + 1 == labs[i + 1][1]:
        print(
            f"    {labs[i][0]} at {labs[i][1]} and {labs[i + 1][0]} at {labs[i + 1][1]} are ADJACENT"
        )
# THE FOURTH PERMANENT CHECK, and it is the one the other three are blind to by
# construction. All three above are STRUCTURAL: they read the control flow and
# the label map. This one reads the DATA FLOW inside a block, which is the class
# of fault that passed all three:
#   `LDI A, 1 / STM 13, A` inserted into the middle of init's run of zero
#   stores left A = 1 for the THREE STORES THAT FOLLOW, so dmem[11] -- the mode
#   byte -- was seeded to 1, main's `LDM A,11 / JNZ encoding` fired on the first
#   poll, and the program jumped into the encoder stub. The jump check, the
#   reachability pass and the adjacent-label check all reported clean, because
#   all three are structural and this is a data fault inside a block whose
#   stores inherit a register value set earlier in the same block.
#
# AND THE MECHANICAL SIGNATURE OF THAT FAULT IS NOT "A RUN OF STORES". Every
# single `LDI A, k / STM n, A` in this file is a run of stores with its setter
# beside it, so a check that flags those flags everything and means nothing --
# which is what the first version of this check did, with 33 findings, all of
# them the ordinary idiom. The setter in the middle of a run does not break the
# run apart, it EXTENDS it, so the signature is TWO RUNS OF STORES WITH ONLY A
# SETTER BETWEEN THEM AND THE TWO SETTERS DIFFERING: read as one run with one
# value -- which is how the reader reads it -- they are two runs with two values,
# and nothing in the listing says so. Both runs must be real runs (two stores or
# more), or every `LDI A,k / STM n,A` in the file fires it. The correct init has
# this shape once, with the SAME setter on both sides, which is what makes it
# one run in the reader's head.
print("\nSTORE-RUN CHECK (two store runs split by a setter that CHANGED the value):")
SETTERS = ("LDI", "IN", "LDM", "MOV")


def sets_a(mn, ops):
    return ops.split(",")[0].strip() == "A" and mn in SETTERS


def setter_before(a):
    for k in range(a - 1, -1, -1):
        mn, ops = mnem[k]
        if sets_a(mn, ops):
            return (k, mn, ops)
    return None


runs = []
i = 0
while i < N:
    if mnem.get(i, ("", ""))[0] == "STM":
        j = i
        while j < N and mnem.get(j, ("", ""))[0] == "STM":
            j += 1
        runs.append((i, j - 1))
        i = j
    else:
        i += 1
bad_runs = 0
for r in range(len(runs) - 1):
    lo, hi = runs[r]
    nlo, nhi = runs[r + 1]
    if hi - lo < 1 or nhi - nlo < 1:
        continue  # not two real runs: the ordinary idiom
    between = [mnem[k] for k in range(hi + 1, nlo)]
    if not between or not all(sets_a(mn, ops) for mn, ops in between):
        continue
    a, b = setter_before(lo), setter_before(nlo)
    if a and b and a[2] != b[2]:
        bad_runs += 1
        print(
            f"    stores {lo}..{hi} and {nlo}..{nhi} are split ONLY by "
            f"'{a[1]} {a[2]}' then '{b[1]} {b[2]}' -- read as one run with"
            f" one value they are two, and the listing does not say which"
            f" the reader is meant to believe ({inv.get(lo, '')})"
        )
print(f"  store runs split by a setter that changed the value: {bad_runs}")

# THE FIFTH, same family, and it is the one that let the polarity gate invert
# every byte without a single structural check noticing: JZ AND JNZ TEST A, NOT
# A FLAG. A branch whose A was set by a LOAD is testing the load, and the
# measured result of getting that wrong was an inversion taken zero times out of
# thirty-two bits. The instruction before a branch must be the arithmetic that
# produced the value being tested, or a load of that value into A.
print("\nBRANCH-OPERAND CHECK (JZ/JNZ test A, so A must have been set for them):")
bad_br = 0
for a in sorted(mnem):
    mn, ops = mnem[a]
    if mn in ("JZ", "JNZ"):
        pmn, pops = mnem.get(a - 1, ("", ""))
        ok = (pmn == "SUB") or (
            pmn in ("LDM", "IN") and pops.split(",")[0].strip() == "A"
        )
        if not ok:
            bad_br += 1
            print(
                f"    {a:3d} {mn:4s} {ops:14s} preceded by {pmn:5s} {pops:12s}"
                " -- A here is whatever that left behind, not a tested value"
            )
print(
    f"  branches whose A did not come from a SUB or a load of the tested byte: {bad_br}"
)

# THE SIXTH, and it is the first one that is about TIME rather than structure.
# Every check above reads the source's own shape: a label map, a control-flow
# graph, a data-flow fact inside a block. This one READS THE ASSEMBLER'S
# LISTING AND COUNTS CLOCKS, because the encoder's two OUT TXPIN instructions
# bracket a half-interval and every instruction between two of them is timing.
#
# IT SIMULATES THE COUNTED DELAY LOOPS RATHER THAN CHARGING THEM A FLAT
# NUMBER OF CLOCKS A PASS, and that is the whole point of it. The first version
# of this check assumed three clocks a pass, which is what `DECX / SUB A,X /
# JNZ` costs -- and that loop is NOT a countdown: SUB computes A - X and
# nothing puts A back, so A becomes 0 - (n + (n-1) + ...) and the loop leaves
# when the running sum is 0 mod 256. With `LDI A, 25` that is 49 passes and 147
# clocks. MEASURED: 49 loop bodies between two OUT TXPIN, and 192 clocks on
# the wire where the listing said 120. So the check reported 120 for firmware
# that was transmitting 60% slow, and it did so while looking exactly like a
# check that works -- the assumption and the thing under test were the same
# sentence. This version runs the loop: DECX and the ALU are modelled, the
# branch is decided on the value A actually holds, and the cost is what the
# machine does. A loop that is not a counted delay now shows its real length,
# and a half-interval that is one clock out is a FAILURE with a number on it.
print("\nHALF-INTERVAL CHECK (every route between two OUT TXPIN, in clocks):")
OUTS = [a for a in sorted(mnem) if mnem[a][0] == "OUT" and "TXPIN" in mnem[a][1]]
TMASK = (1 << PCW) - 1
ALU = {
    "ADD": lambda a, b: a + b,
    "SUB": lambda a, b: a - b,
    "AND": lambda a, b: a & b,
    "OR": lambda a, b: a | b,
}


def operand(ops):
    """the ALU's second operand: X if the source names it, else an immediate"""
    t = ops.split(",")[-1].strip()
    if t.upper() == "X":
        return "X"
    try:
        return int(t, 0)
    except ValueError:
        return None


def step(state, a):
    """one instruction: returns (A, X, taken) with None for anything the
    listing cannot tell us. dmem is NOT modelled -- a load is unknown, which
    makes every branch downstream of one a both-ways branch, and that is the
    honest answer rather than a guess."""
    A, X = state
    mn, ops = mnem.get(a, ("", ""))
    if mn == "LDI":
        v = operand(ops)
        return (v if v is not None else None, X, None)
    if mn == "MOV":
        d, s = [t.strip().upper() for t in ops.split(",")]
        src = {"X": X, "Y": None, "A": A}[s]
        if d == "X":
            return (A, src, None)
        return (src, X, None)
    if mn == "DECX":
        return (A, (X - 1) & 0xFF if X is not None else None, None)
    if mn == "INCX":
        return (A, (X + 1) & 0xFF if X is not None else None, None)
    if mn == "SHR":
        return ((A >> 1) & 0xFF if A is not None else None, X, None)
    if mn in ALU:
        b = operand(ops)
        if b == "X":
            if A is None or X is None:
                return (None, X, None)
            return (ALU[mn](A, X) & 0xFF, X, None)
        if b is None or A is None:
            return (None, X, None)
        return (ALU[mn](A, b) & 0xFF, X, None)
    if mn == "LDM":
        d = ops.split(",")[0].strip().upper()
        return (None, None, None) if d == "A" else (A, None, None)
    if mn in ("LDS", "IN", "STM", "STS", "OUT", "NOP"):
        return (None, X, None) if mn in ("LDS", "IN") else (A, X, None)
    return (A, X, None)


def routes(start, stop, budget=20000):
    """every route from `start` back to `stop`, as a cost in clocks, with the
    counted delay loops RUN rather than assumed"""
    out: list = []
    stack: list = [(start, 0, 0, None, None)]
    while stack:
        a, cost, depth, A, X = stack.pop()
        if cost > budget or depth > 2000:
            continue
        if a == stop and depth:
            out.append(cost)
            continue
        mn = mnem.get(a, ("", ""))[0]
        nA, nX, _ = step((A, X), a)
        nxt, extra = a + 1, 0
        if mn in ("JMP", "JZ", "JNZ"):
            t = words[a] & TMASK
            if t >= N:
                continue
            if t == a:
                continue  # a jump to ITSELF has no exit: park, spin, wait
            if t <= a and mnem.get(t, ("", ""))[0] == "DECX":
                # A COUNTED DELAY LOOP, AND IT IS RUN RATHER THAN CHARGED A
                # FLAT RATE. The body is t..a inclusive and the branch at a
                # decides whether to go round again, which is the only thing
                # that makes a loop a loop.
                rA, rX, n, p = nA, nX, 0, t
                while n < 400:
                    pA, pX, _ = step((rA, rX), p)
                    n += 1
                    if p == a:
                        if pA is None or (pA != 0) != (mn == "JNZ"):
                            break  # the branch leaves, or the listing cannot say
                        p = t
                        continue
                    rA, rX = pA, pX
                    p += 1
                extra = n - 1  # the branch itself is already charged
            else:
                if mn == "JMP":  # a JMP is unconditional: the fall-through
                    stack.append((t, cost + 1, depth + 1, nA, nX))
                    continue  # is not an instruction anybody executes
                taken = None
                if nA is not None:
                    taken = (nA != 0) if mn == "JNZ" else (nA == 0)
                if taken is None or taken:
                    stack.append((t, cost + 1, depth + 1, nA, nX))
                if taken:
                    continue
        stack.append((nxt, cost + 1 + extra, depth + 1, nA, nX))
    return out


if len(OUTS) < 2:
    print(f"  only {len(OUTS)} OUT TXPIN in the program: nothing to bracket")
else:
    start = OUTS[-1]
    rs = routes(start, start)
    hist = {}
    for c in rs:
        hist[c] = hist.get(c, 0) + 1
    for c in sorted(hist):
        flag = "" if c == 120 else "  *** NOT 120 ***"
        print(f"    {c:4d} clocks  x{hist[c]}{flag}")
    bad_iv = [c for c in rs if c != 120]
    if not rs:
        print("  NO ROUTE RETURNS to the OUT: the loop never drives a second edge")
    print(
        f"  routes between two OUT TXPIN: {len(rs)}, and the ones that are "
        f"not exactly 120 clocks: {len(bad_iv)}"
        + ("" if not bad_iv and rs else "  *** SEE ABOVE ***")
    )
print(f"\nwords={N}")
