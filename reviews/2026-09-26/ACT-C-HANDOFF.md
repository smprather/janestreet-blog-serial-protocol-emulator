# Act (c) FM0/FM1 — handoff at the 07:00 CDT wrap

**branch `fw-timing-protocols` · worktree `/tmp/worktrees/fw-timing` · `03d71c1`**
Tree clean apart from `.pi-lens-probe-home/` (a pi-lens log artefact).
176 words. Act is RED; everything below is measured.

Written to the repository on purpose: the `/tmp` copy of this file was deleted
twice during the session by something that cleans `/tmp`, and a handoff that
vanishes is worse than no handoff.

---

## THE ONE OPEN FAULT, AND IT IS ONE BIT

**The payload is emitted one bit late**, so the preamble's first assembled byte
is `0xFF` where the flag test wants `0x80`, and the flag comes out **FM1 for an
FM0 stream** (`dmem[3] = 1` when `enc_fm0 = 1`).

Captured one bit per arrival at `bit_store` (`probe_bits.v`):

```text
    emitted  sixteen 1s, then 0 1 0 0 1 0 1 0 | 0 1 1 1 1 0 0 0 | 1 1 0 1 0 0 1
    frame                  1 0 1 0 0 1 0 1 | 0 0 1 1 1 1 0 0 | 1 0 0 1 0 1 1 0
```

The payload is the frame delayed by exactly one bit, and the preamble came out
as sixteen ones where it should be seven zeros then eight ones.

**The cause, and it is not a bug in the resync:** the first transition of a
transmission is always the start of a bit, so the resync's dropping it discards
the boundary into the preamble's first bit. Under FM0 the preamble's first half
differs from the idle line, so that frame-start boundary exists and is the only
transition carrying bit 0. Under FM1 the first half *equals* the idle line,
there is no frame-start transition, and FM1 loses nothing. **The loss is
asymmetric between the two polarities**, which is why it has to be designed out
rather than compensated for.

**Next, and model both polarities before editing:** make the first transition
after a resync a *boundary* rather than a dropped one. The difficulty is that
FM1's first transition is a *mid*, and `dmem[3]` is not set at that point, so
the receiver cannot yet tell which case it is in. Work out in the model whether
the preamble *shape* can be made polarity-independent — for instance a first bit
followed by something that forces a transition in both polarities — rather than
detecting the case and compensating for it.

After that: the non-vacuous flag and the same frame both ways (the check the act
has wanted since it began), the firmware encoder (the stub is 10 dead words and
its `half_wait` cannot terminate), and wire behind `<<wip>>`.

---

## What is now measured and right, none of which was right this morning

| what | measured |
| :--- | :--- |
| the interval | 32 writes to `dmem[8]`, 18 of value 2 µs, 13 of value 4 µs, **no 6** |
| the boundary decision | 39 mids, 25 boundaries, 1 resync — 39 is exactly 16 preamble + 24 payload, less the resync |
| the byte arithmetic | the bit is **shifted in**, not added at its own index |
| the preamble | on the wire, consumed, `dmem[9]` ends at 3 |

---

## The twelve faults, and the two shapes worth carrying

None of the twelve was found by reading the diff. All were found by a probe
printing. The two that cost the most time are the two to carry forward.

### The bit was added at its own index instead of shifted in

The block computed `dmem[12] + dmem[7]`: it added the bit **index** rather than
the bit **at** that index. Its comment read *"a general add of two bytes, whose
carry is NOT tested: both are 0 or 1"* — and both **were** 0 or 1, which is true
of the index *and* of the bit, and is exactly why it read as correct.

**That is why every byte this act has ever reported has been `1c`.** `0x1c` is
`0001_1100`: a byte whose bits land at the indices they are.

**Three sessions read `1c 1c` out of this program and I read it as a phase
problem**, because the boundary decision was independently known to be exact
and a wrong phase was the obvious suspect. *It was never a phase problem.* A
right answer to the wrong question about the arithmetic, arrived at by
measuring.

### Every structural check passed while the program was broken

Inserting `LDI A, 1 / STM 13, A` into the middle of init's run of zero stores
left **A = 1 for the three stores that follow**, so `dmem[11]` — the **mode
byte** — was seeded to 1 and the program jumped into the encoder stub on the
first poll. The jump check, the reachability pass and the adjacent-label check
all reported clean, because all three are structural and this is a **data fault
inside a block whose stores inherit a register value set earlier in the same
block**.

Fix: every run of stores carries its own `LDI`, and the one store that needs a
non-zero value sits at the end of init. **That deserves to be a fourth permanent
check** — it is the one class the existing three are blind to by construction.

### Also this session

The init comment said *"seeded to 1"* over an instruction that seeded 0. The
preamble ended at bit 7 rather than 15 because the comment stated a
**conjunction** and the code tested one conjunct — twice in one block. And a
probe whose label printed a hard-coded count instead of the real one, which
briefly had me reading 41 bits where there were 39.

---

## The inherited wrap named three things; two were true

1. *delete the dead tail at 52-54* — done, and it was **52-55**, not 52-54
2. *the `JMP bit_edge` at 51 is mis-targeted* — **not a fault**
3. *re-run the write-hook, expect dozens of 2s and 4s* — done, exactly

On (2): `JMP bit_edge` encodes `0x38 = 56` and **56 is `bit_edge`** —
`the_pin=33, half_done=55, bit_edge=56`, counted from the assembler's listing,
not the source. A jump naming a label goes to that label. What made the handler
look re-entered was the **dead tail holding four words open**. "Fix the
mis-targeted jump" would have repaired a fault that was not there, on the
strength of a decimal read without the label map beside it.

**The acceptance probe could not pass before**, because the stimulus was sending
twenty-four ones: `enc_bitval(b)` took a **bit number** and answered "is it bit
zero", the stimulus passed 0..23, so every bit but bit 0 encoded as a `1` — a
run of ones, which under the old rules is a **constant line**. Measured:
`in_line` changed **three times** in a 3.9 ms run of a 24-bit frame.

---

## Run it

```sh
/tmp/run_bmc_probe.sh <probe-file>     # injects a probe, adds the L_ defines,
                                       # builds against sim/'s RTL, runs
python3 /tmp/bmc_checks.py firmware/bmc_frame.pe
                                       # jump check, reachability, adjacent labels
```

`probe_bits.v` is the one to run first now — it prints the emitted stream
grouped into bytes. Then `probe_pre.v` (preamble path and the byte the flag is
compared against), `probe_dec.v` (classification and stores), `probe_gap.v`
(sample gap), `probe_write8.v` (the interval write-hook), `probe_diff.v` (wire
vs firmware change times).

Jump check: **0 of 21 mismatches**. The only unreachable words are the encoder
stub's. Run the checks after **every** edit *and read the whole block in the
listing, not the part that changed* — that rule caught a `data_zero`/`resync`
fall-through in this session's own new code within a minute of writing it.
