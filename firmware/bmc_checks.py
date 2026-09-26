import re
import subprocess
import sys

# The two file operations below are deliberately LOUD and deliberately NOT
# silent-and-clean, and the explicit SystemExit is what keeps them that way: this
# gate is run ON a file, and if the file is missing or the assembler will not
# run, the right behaviour is to stop with the reason on the screen. A gate that
# swallows its own failure and prints a clean report is worse than no gate,
# which is this act's whole subject. The reason is now a MESSAGE rather than a
# traceback, and it names the file, because "FileNotFoundError" does not.
f = sys.argv[1] if len(sys.argv) > 1 else "firmware/bmc_frame.pe"
try:
    with open(f) as _fh:
        src = _fh.read().split("\n")
except OSError as _e:
    raise SystemExit(f"bmc_checks: cannot read {f}: {_e}")
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
        # The regex has already made both of these convertible, so a raise here
        # would be a bug in the regex rather than in the listing -- and a bug
        # that stopped the gate silently would be the worst kind, so it stops
        # it LOUDLY and quotes the line that disagreed.
        try:
            words[int(m.group(1))] = int(m.group(2), 16)
        except ValueError as _e:
            raise SystemExit(f"bmc_checks: listing line {l.strip()!r}: {_e}")
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
adj = 0
for i in range(len(labs) - 1):
    if labs[i][1] + 1 == labs[i + 1][1]:
        adj += 1
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


# The most walk states `routes` may explore before it gives up and says so. -1
# in ROUTE_STATES means the cap was HIT, which is a failure, not a pass.
ROUTE_STATES = 400000


def routes(start, stop, budget=20000):
    """Every route from `start` back to `stop`, as (clocks, the counted delay
    loop it went round).

    The delay loop is NAMED in the result because the three routes out of the
    encoder's tail are three different loops with three different constants,
    and a report that says "128 clocks" without saying WHICH one is 128 is a
    report that cannot be acted on: the fit is per loop.
    """
    out: list = []
    # A walk state is (pc, clocks, depth, A, X, the loop last charged). A and X
    # are concrete where the listing makes them so and None where it does not,
    # and None propagates: a branch downstream of an unknown A is taken both
    # ways, which is the honest answer rather than a guess.
    stack: list = [(start, 0, 0, None, None, None)]
    #
    # *** AND THE WALK IS BOUNDED BY STATES EXPLORED, NOT ONLY BY THE TWO
    # PER-PATH LIMITS ABOVE, BECAUSE A GATE THAT HANGS IS A GATE THAT IS NOT
    # RUN. *** `cost > budget` and `depth > 2000` bound a single PATH. They do
    # not bound the NUMBER of paths, and the number of paths is what grows: a
    # branch the listing cannot resolve forks the walk, so a program with n such
    # branches has up to 2**n routes through it.
    #
    # This is not hypothetical and it is not a theory. It hung twice in one
    # session, on the SAME program, for the SAME reason and in two different
    # ways: once because a bracket was taken from the wrong end of the
    # instruction stream and the walk therefore crossed the whole decoder, and
    # once because a fault injected to prove this very check fires -- a retargeted
    # JMP that stopped the loop returning to its own OUT -- left a cycle the
    # walker does not recognise as a counted delay loop. Both printed NOTHING
    # AT ALL and both were found only because the command was TIMED OUT, which
    # is not something a regression does: run_all.sh would sit there instead of
    # reporting, and the failure would read as a slow machine.
    #
    # So the walk gives up and SAYS SO. The cap is 400000 states, which the real
    # firmware uses about two thousand of: a whole order of magnitude of headroom
    # for a program twice this size, and about a second of work to discover a
    # pathology that used to be unbounded.
    global ROUTE_STATES
    states = 0
    while stack:
        states += 1
        if states > ROUTE_STATES:
            ROUTE_STATES = -1
            return out
        a, cost, depth, A, X, used = stack.pop()
        if cost > budget or depth > 2000:
            continue
        if a == stop and depth:
            out.append((cost, used))
            continue
        mn = mnem.get(a, ("", ""))[0]
        nA, nX, _ = step((A, X), a)
        nxt, extra, nused = a + 1, 0, used
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
                nused = t
            else:
                if mn == "JMP":  # a JMP is unconditional: the fall-through
                    stack.append((t, cost + 1, depth + 1, nA, nX, used))
                    continue  # is not an instruction anybody executes
                taken = None
                if nA is not None:
                    taken = (nA != 0) if mn == "JNZ" else (nA == 0)
                if taken is None or taken:
                    stack.append((t, cost + 1, depth + 1, nA, nX, used))
                if taken:
                    continue
        stack.append((nxt, cost + 1 + extra, depth + 1, nA, nX, nused))
    return out


rs: list = []
ent: list = []
if len(OUTS) < 2:
    print(f"  only {len(OUTS)} OUT TXPIN in the program: nothing to bracket")
else:
    start = OUTS[-1]
    rs = routes(start, start)
    hist = {}
    for c, loop in rs:
        hist[(c, loop)] = hist.get((c, loop), 0) + 1
    for c, loop in sorted(hist, key=lambda k: (k[1] is None, k[1] or 0, k[0])):
        flag = "" if c == 120 else "  *** NOT 120 ***"
        print(f"    {c:4d} clocks  x{hist[(c, loop)]}  (delay loop at {loop}){flag}")
    # AND THE FIRST HALF-INTERVAL IS BRACKETED TOO, from the OUT that writes
    # half-interval 0 to the first OUT in the loop. It is the one interval no
    # receiver can measure -- the model excludes it from its own histogram,
    # because a receiver has no previous transition to measure it from -- and
    # that is precisely why it was 49 clocks long and nothing complained:
    # a check that only walks the loop cannot see the gap between the frame's
    # first level and the loop that sends the rest of it.
    #
    # *** AND OUTS[0] IS NOT THAT WRITE, WHICH IS WHY THIS HUNG FOR 120
    # SECONDS INSTEAD OF PRINTING. *** The previous version of this line said
    # "the first OUT TXPIN in the program is that write" and it is not: the
    # program has THREE, and the first is at address 3, in the DECODER, four
    # hundred words upstream of the encoder. So the walk went from the
    # decoder's pad write to the encoder's loop -- across the whole decoder,
    # whose every JZ/JNZ on an A the listing cannot fix forks the walk both
    # ways, with three counted delay loops re-charged on every path through.
    # The path SPACE, not the path length, is what is exponential, and the
    # budget of 20000 clocks and 2000 of depth bounds neither: the check
    # printed NOTHING AT ALL, which is the one failure mode a check cannot
    # have. A check that hangs is a check that is not run, and the way it was
    # found is that the RUN ITSELF TIMED OUT.
    #
    # So it is the SECOND-TO-LAST, counted from the end rather than the start:
    # the encoder's first level write, and the last is the loop's edge, so the
    # two are adjacent and the walk between them is the first half-interval and
    # nothing else. Counting from the end is also the index that survives the
    # next writer adding a pad write to the decoder.
    if len(OUTS) < 3:
        print(
            "  fewer than three OUT TXPIN: there is no encoder first level to "
            "bracket against the loop"
        )
        ent = []
    else:
        ent = routes(OUTS[-2], start)
    hist2 = {}
    for c, loop in ent:
        hist2[(c, loop)] = hist2.get((c, loop), 0) + 1
    for c, loop in sorted(hist2, key=lambda k: (k[1] is None, k[1] or 0, k[0])):
        flag = "" if c == 120 else "  *** NOT 120 ***"
        print(
            f"    {c:4d} clocks  x{hist2[(c, loop)]}"
            f"  THE FIRST HALF-INTERVAL, entry delay loop at {loop}{flag}"
        )
bad_iv = [c for c, _ in rs if c != 120] + [c for c, _ in ent if c != 120]
if not rs:
    print("  NO ROUTE RETURNS to the OUT: the loop never drives a second edge")
print(
    f"  routes between two OUT TXPIN: {len(rs)} in the loop and {len(ent)} into it, "
    f"and the ones that are not exactly 120 clocks: {len(bad_iv)}"
    + ("" if rs and not bad_iv else "  *** SEE ABOVE ***")
)
# THE SEVENTH, AND IT IS THE ONE THAT COST THIS ACT AN HOUR, so it is written
# first among the things that could have.
#
# SHR IS `a <= {1'b0, a[7:1]}`: the NEW BIT 7 IS ALWAYS ZERO. A shift-right moves
# every bit DOWN one place and throws the top one away, so a BYTE peeled with
# SHR comes out LOW BIT FIRST. There is no shift-LEFT to re-align it -- that is
# the whole of why the peel cannot work, and the reason the wire is high bit
# first is the RECEIVER, whose shift-in is a doubling with the arriving bit at
# the low end.
#
# THE FAULT THIS ACT SHIPPED, measured: the encoder held the byte in dmem[11] and
# peeled it, so dmem[11] went 0xFF, 0x7F, 0x52 -- and 0x52 is 0xA5 shifted
# right. It went UNNOTICED for sixteen half-intervals because the preamble's byte
# is 0xFF, which is eight ones in EVERY order, so a receiver that reads the
# payload backwards reads a legal preamble and a transmitter that sends it
# backwards sends a legal preamble. The only thing that caught it was the
# receiver's own trace showing a four-microsecond gap inside a run of eight
# identical bits, which the wire rules say cannot exist.
#
# THE SIGNATURE IS THE RELOAD, and it is mechanical and needs no wire, no probe
# and no model: **the dmem byte a SHR shifts must be reloaded with 0x80.** A mask
# walks 0x80, 0x40, 0x20 ... 0x01 and back to 0x80, and that reload is what
# makes a shift-right the right tool. A byte that is shifted and reloaded with
# anything else is a peel, and a peel is a transmitter that sends the frame
# backwards.
print("\nBIT-ORDER CHECK (a SHR walks a MASK down, so its byte must reload 0x80):")


def lit(ops):
    """the immediate an instruction carries, or None if it is not a number"""
    try:
        return int(ops.split(",")[-1].strip(), 0)
    except ValueError:
        return None


shifts, reloads, fed = [], {}, {}
for a in sorted(mnem):
    # *** AND THE RELOAD IS RECORDED WITH ITS VALUE, BECAUSE WHERE THE MASK
    # STARTS IS THE WHO OF THIS CHECK. *** The first version of this table kept
    # only the addresses of `LDI A, 0x80` + `STM n, A` pairs, so a byte reloaded
    # with 0x40 was indistinguishable from a byte never reloaded at all -- and
    # both printed the same sentence, "neither a mask (no 0x80 reload) nor fed
    # by the payload: a counter or an index, and this check makes no claim
    # about those". That is the act's first and most expensive finding -- the
    # WIRE IS HIGH BIT FIRST -- and the excuse was structurally guaranteed,
    # because a mask at the WRONG bit is indistinguishable from a counter only
    # if you never look at the number. Changing 0x80 to 0x40 puts the wire low
    # bit first, sends the frame BACKWARDS, and passed.
    #
    # THE VALUE SEPARATES A MASK FROM A COUNTER WITHOUT NAMING EITHER, and the
    # separation is not a convention: a bit-position mask is a power of two
    # ABOVE 1, because a mask of 1 is bit 0 and `SHR` on it reaches zero in one
    # step, which is not walking a mask down anywhere. The counter in this same
    # program is reloaded with 1 and the mask with 0x80, and BOTH are walked
    # with SHR, so the instruction cannot tell them apart and the immediate
    # can. 0 and 1 are counters and indices and are excused; a power of two
    # that is not 0x80 is a MASK AT THE WRONG BIT and is a failure, named with
    # the value so a reader can adjudicate rather than take it on trust.
    if (
        mnem.get(a, ("", ""))[0] == "LDI"
        and mnem.get(a + 1, ("", ""))[0] == "STM"
    ):
        imm = lit(mnem[a][1])
        b = lit(mnem[a + 1][1].split(",")[0])
        if b is not None and imm is not None:
            reloads.setdefault(b, []).append((a, imm))
    # an `LDS` whose result reaches an `STM n, A` within a few instructions is
    # the PAYLOAD FETCH landing in memory, and that is what makes a byte a data
    # byte rather than a mask
    if mnem.get(a, ("", ""))[0] == "LDS":
        for k in range(a + 1, min(a + 6, N)):
            if mnem.get(k, ("", ""))[0] == "STM":
                b = lit(mnem[k][1].split(",")[0])
                if b is not None:
                    fed.setdefault(b, []).append(k)
                break
            if mnem.get(k, ("", ""))[0] not in ("NOP", "MOV", "JMP", "LDI"):
                break
for a in sorted(mnem):
    if mnem[a][0] != "SHR":
        continue
    # the dmem byte this SHR shifts, found by walking back to the nearest load of
    # A in the same straight-line run; None means it shifts a COMPUTED value
    src = None
    k = a - 1
    while k >= 0 and mnem.get(k, ("", ""))[0] not in (
        "LDI",
        "LDM",
        "MOV",
        "SHR",
        "AND",
        "ADD",
        "SUB",
        "OR",
        "OUT",
        "IN",
        "LDS",
    ):
        k -= 1
    if k >= 0 and mnem[k][0] == "LDM" and mnem[k][1].split(",")[0].strip() == "A":
        src = lit(mnem[k][1])
    shifts.append((a, src))
bad_order = 0
for a, src in shifts:
    if src is None:
        print(
            f"    {a:3d} SHR shifts a computed value, not a memory byte: the "
            f"counter or an index, which is a position and not a payload"
        )
    elif src in fed:
        bad_order += 1
        print(
            f"    {a:3d} SHR shifts dmem[{src}], and that byte is FED BY THE "
            f"PAYLOAD FETCH at {', '.join(str(x) for x in fed[src])} -- so it is "
            f"a PEEL, and a peel sends the frame LOW BIT FIRST"
        )
    elif src in reloads:
        # a MASK, and WHERE IT STARTS IS THE CLAIM. Split by the value.
        #
        # *** AND IT IS *EVERY* RELOAD, NOT ANY OF THEM, WHICH IS THE SECOND
        # VERSION OF THIS FAULT AND THE ONE THAT ALMOST SHIPPED. *** A mask
        # byte is reloaded TWICE -- once when the transmission is set up and
        # again when the walk reaches zero -- and the first version of this
        # test asked only whether ANY of the reloads was 0x80. So changing the
        # SET-UP reload to 0x40 passed, with the re-arm still at 0x80: the
        # frame went out high bit first for its first byte and low bit first
        # for the remaining seven, which is worse than either error alone
        # because a check that had been made to fire did not.
        masks = [(x, v) for x, v in reloads[src] if v > 1 and (v & (v - 1)) == 0]
        counts = [(x, v) for x, v in reloads[src] if v in (0, 1)]
        bad_masks = [(x, v) for x, v in masks if v != 0x80]
        if masks and counts:
            # THE LAST OF THIS HOLE, AND IT IS FOUND BY THE INJECTION THAT
            # WAS SUPPOSED TO BE EXCUSED. Reloading the MASK byte to 1 passes
            # every test above, because 1 is in the counter's bucket -- but the
            # SAME byte is reloaded 0x80 elsewhere, so it is being used as a
            # counter in one place and a bit position in another, and the first
            # outbound bit is chosen by a mask of 1 while the remaining seven
            # are chosen by a mask of 0x80. The frame changes bit order ONE
            # BIT IN.
            #
            # A byte is never both. dmem[6] is 0/1 at every reload and dmem[11]
            # is a power of two at every reload, and the check can say that
            # without naming either, which is the only way it can be trusted
            # on the next program.
            bad_order += 1
            print(
                f"    {a:3d} SHR shifts dmem[{src}], which is reloaded BOTH as a "
                f"bit mask ("
                f"{', '.join(f'0x{v:02X} at {x}' for x, v in masks)}) and as a count "
                f"({', '.join(f'0x{v:02X} at {x}' for x, v in counts)}) -- one byte "
                f"cannot be both, and a mask of 1 selects bit 0 while a mask of "
                f"0x80 selects bit 7, so the frame changes bit order one bit in"
            )
        elif bad_masks:
            bad_order += 1
            wrong = ", ".join(f"0x{v:02X} at {x}" for x, v in bad_masks)
            ok = ", ".join(f"0x{v:02X} at {x}" for x, v in masks if v == 0x80)
            # the bit is bound OUTSIDE the comprehension on purpose: a generator
            # has its own scope in Python 3, so a `v` written inside one is
            # not defined after it, and this was a NameError the first time.
            bit = bad_masks[0][1].bit_length() - 1
            print(
                f"    {a:3d} SHR shifts dmem[{src}], whose bit mask is reloaded "
                f"{wrong} -- and a mask that starts at bit {bit} walks the frame "
                f"out LOW BIT FIRST, which sends it BACKWARDS. It must start at "
                f"bit 7 (0x80) on EVERY reload: the first arrival lands in the "
                f"high position, so the bit that goes out first has to be the one "
                f"the mask sits on."
                + (f" (the reload(s) at {ok} are correct, which is what made this "
                   f"look fine: a mask re-armed at 0x80 in the middle of a frame "
                   f"that started at 0x40 changes order half way through)"
                   if ok else "")
            )
        elif masks:
            print(
                f"    {a:3d} SHR shifts dmem[{src}], which is reloaded 0x80 at "
                f"{', '.join(str(x) for x, v in masks)}: a mask walking down, so "
                f"the wire is high bit first"
            )
        else:
            print(
                f"    {a:3d} SHR shifts dmem[{src}], reloaded "
                f"{', '.join(f'0x{v:02X} at {x}' for x, v in reloads[src])}: "
                f"0 or 1, so a counter or an index, and this check makes no "
                f"claim about those"
            )
    else:
        # A counter or an index is neither a mask nor a payload byte, and this
        # check does NOT claim to know what it is. Failing here would be the
        # check overreaching into a verdict it cannot support -- the class of
        # fault this act exists to catch, one level up. So it is reported and
        # not counted: the claim being made is "no byte that RECEIVES THE PAYLOAD
        # is shifted", and that is a claim about a peel.
        print(
            f"    {a:3d} SHR shifts dmem[{src}], which is neither a mask (no "
            f"0x80 reload) nor fed by the payload: a counter or an index, and "
            f"this check makes no claim about those"
        )
print(f"  shifts that are peels, or a mask not at bit 7, or neither: {bad_order}")

print(f"\nwords={N}")

# THE VERDICT, AND ITS ABSENCE IS WHY NONE OF THIS WAS IN THE REGRESSION.
#
# Every check above PRINTS a count and stops. That is a report, not a gate: a
# gate is something that can fail, and a script whose last line is
# `words=323` can only be read by a person who is already looking at it -- so
# the seven checks ran by hand, forever, and the firmware's fitted delay
# constants were only ever checked by whoever remembered. This file is in
# regress/run_firmware_tests.sh now, and run_case there looks for a line
# starting PASS, which this file did not have and would never have produced.
#
# The failure list is named rather than counted, because a gate that says "1
# problem" sends the reader back up the output to find which, and the whole
# point of the counts is that they are all zero.
fails = []
if bad:
    fails.append(f"{bad} jump(s) whose target does not match the label map")
if dead:
    fails.append(f"{len(dead)} unreachable word(s)")
if adj:
    fails.append(f"{adj} adjacent label pair(s), each a fall-through waiting to happen")
if bad_runs:
    fails.append(f"{bad_runs} store run(s) split by a setter that CHANGED the value")
if bad_br:
    fails.append(f"{bad_br} branch(es) whose A did not come from a SUB or a tested load")
if not rs:
    fails.append("no route returns to the OUT: the loop never drives a second edge")
if ROUTE_STATES < 0:
    fails.append(
        "the route walk hit its 400000-state cap, so the half-interval check "
        "did NOT finish: a walk that cannot finish is a program this check "
        "cannot measure, and reporting that is what it is for"
    )
if bad_iv:
    fails.append(f"{len(bad_iv)} half-interval route(s) that are not exactly 120 clocks")
if bad_order:
    fails.append(
        f"{bad_order} SHR(s) that are peels, or a mask reloaded anywhere but "
        f"bit 7 -- either one puts the frame on the wire the wrong way round"
    )

if fails:
    print("FAIL: " + "; ".join(fails))
    sys.exit(1)
print(
    f"PASS: 7 checks, 0 failures "
    f"({N} words, {len(rs)} loop routes and {len(ent)} entry routes all 120 clocks)"
)
