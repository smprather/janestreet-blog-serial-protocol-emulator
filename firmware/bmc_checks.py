import re
import subprocess
import sys

f=sys.argv[1] if len(sys.argv)>1 else 'firmware/bmc_frame.pe'
with open(f) as _fh: src=_fh.read().split('\n')
addr=0; labels={}; mnem={}
OPS=r'^(LDI|OUT|IN|MOV|JMP|JZ|JNZ|ADD|SUB|AND|OR|INCX|DECX|SHR|LDS|STS|LDM|STM|NOP)\b'
for ln in src:
    s=ln.strip()
    if not s or s.startswith(';'): continue
    m=re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$',s)
    if m and not re.match(OPS,s):
        labels[m.group(1)]=addr
        if not m.group(2).strip(): continue
    mo=re.match(OPS+r'(.*)$',s)
    if mo: mnem[addr]=(mo.group(1),mo.group(2).split(';')[0].strip()); addr+=1
N=addr
lst=subprocess.run(['python3','tools/fw/peasm.py',f,'--listing'],capture_output=True,text=True,check=False).stdout
words={}
for l in lst.split('\n'):
    m=re.match(r'^\s*(\d+)\s+([0-9A-Fa-f]{4})\s',l)
    if m: words[int(m.group(1))]=int(m.group(2),16)
inv={v:k for k,v in labels.items()}
bad=0
print("ONE-LINE JUMP CHECK (label map vs the ENCODED operand):")
for a in sorted(mnem):
    mn,ops=mnem[a]
    if mn in ('JMP','JZ','JNZ'):
        t=ops.split(',')[-1].strip()
        t=int(t,16) if re.fullmatch(r'0x[0-9a-fA-F]+',t) else labels.get(t)
        o=words[a]&0xFF; ok=(o==t); bad+=0 if ok else 1
        print(f"  {a:3d} {mn:4s} {ops.split(',')[-1].strip():10s} -> {t:3d} ({inv.get(t,'?'):10s}) enc 0x{o:02X}  {'OK' if ok else '*** MISMATCH ***'}")
print(f"  mismatches: {bad}")
seen=set(); st=[0]
while st:
    a=st.pop()
    if a in seen or not (0<=a<N): continue
    seen.add(a); mn,ops=mnem[a]
    if mn=='JMP': st.append(labels[ops.split(',')[-1].strip()])
    elif mn in ('JZ','JNZ'):
        st.append(labels[ops.split(',')[-1].strip()]); st.append(a+1)
    else: st.append(a+1)
dead=[a for a in range(N) if a not in seen]
print(f"\nREACHABILITY: {len(seen)}/{N} reachable, {len(dead)} dead")
for a in dead: print(f"    {a:3d}  {mnem[a][0]:5s} {mnem[a][1]:18s} {inv.get(a,'')}")
# ADJACENT LABELS: two labels on consecutive addresses is a fall-through waiting
# to happen, and it is how the data_zero/resync pair was missed.
print("\nADJACENT LABEL CHECK (a label immediately after another can fall through):")
labs=sorted(labels.items(), key=lambda x:x[1])
for i in range(len(labs)-1):
    if labs[i][1]+1==labs[i+1][1]:
        print(f"    {labs[i][0]} at {labs[i][1]} and {labs[i+1][0]} at {labs[i+1][1]} are ADJACENT")
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
SETTERS = ('LDI', 'IN', 'LDM', 'MOV')
def sets_a(mn, ops):
    return ops.split(',')[0].strip() == 'A' and mn in SETTERS
def setter_before(a):
    for k in range(a - 1, -1, -1):
        mn, ops = mnem[k]
        if sets_a(mn, ops):
            return (k, mn, ops)
    return None
runs = []
i = 0
while i < N:
    if mnem.get(i, ('', ''))[0] == 'STM':
        j = i
        while j < N and mnem.get(j, ('', ''))[0] == 'STM':
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
        continue                       # not two real runs: the ordinary idiom
    between = [mnem[k] for k in range(hi + 1, nlo)]
    if not between or not all(sets_a(mn, ops) for mn, ops in between):
        continue
    a, b = setter_before(lo), setter_before(nlo)
    if a and b and a[2] != b[2]:
        bad_runs += 1
        print(f"    stores {lo}..{hi} and {nlo}..{nhi} are split ONLY by "
              f"'{a[1]} {a[2]}' then '{b[1]} {b[2]}' -- read as one run with"
              f" one value they are two, and the listing does not say which"
              f" the reader is meant to believe ({inv.get(lo,'')})")
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
    if mn in ('JZ', 'JNZ'):
        pmn, pops = mnem.get(a - 1, ('', ''))
        ok = (pmn == 'SUB') or (pmn in ('LDM', 'IN') and pops.split(',')[0].strip() == 'A')
        if not ok:
            bad_br += 1
            print(f"    {a:3d} {mn:4s} {ops:14s} preceded by {pmn:5s} {pops:12s}"
                  " -- A here is whatever that left behind, not a tested value")
print(f"  branches whose A did not come from a SUB or a load of the tested byte: {bad_br}")
print(f"\nwords={N}")
