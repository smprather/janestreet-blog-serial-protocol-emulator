# Block 3 state, and the findings that outlive it

**2026-09-26 · branch `fw-timing-protocols` · handoff for a fresh context**

This is the record to continue from. It is written so that the next session does
not rederive anything: what is green, what is blocked and on which three
commands, what is started and on which design, and the findings that are worth
more than the acts they came from.

---

## Where the three acts of Block 3 stand

| act | state | where |
|---|---|---|
| (b) input frequency + duty meter | **GREEN, in the regression**, 58/58 mutations | `d88e316` |
| (a) HC-SR04 ultrasonic ranging | **BLOCKED** on one 26-instruction block; everything else measured | `b0351b3` |
| (c) FM0/FM1 bi-phase | **started**: RED testbench (7 checks) + first-draft firmware; the WIRE RULES were wrong and are now corrected | `3dace8`, `0513b7e`, `cb191ef` |

Also delivered this session: the **merge-repair** of the six acts in main
(`3657847`, proven on three throwaway exports of main: unpatched 6/6 FAIL,
the RTL hunk alone 6/6 PASS, the TB hunks alone 6/6 PASS, both 6/6 PASS).

---

## (a) HC-SR04 — BLOCKED, and the block is the EDIT

### What is measured and correct

* the trigger pulse is **EXACTLY 600 clocks = 10.000 µs** (an equality, not the
  datasheet's ">= 10 µs");
* the echo width is captured to one tick (the model's 1160 µs arrives as 1159);
* **the first conversion is EXACT**: 1160 µs -> 199 mm against the
  specification's 199.375;
* the recovery wait works and the model sees both triggers;
* the state machine's edge handling has been exonerated **three times** by
  direct traces.

### The one outstanding fault

The second measurement reads **991 mm against 999**. The cause is the
**both-zero guard in a general 16-bit add, which is not exact**: "if the stored
low byte is zero, re-read the addend and see whether it was zero too; otherwise
there was no carry" -- and the second half is FALSE. **A carry out of an add
does not require a zero result**: `0xE0 + 0x38 = 0x118` carries and leaves
`0x18`, which is not zero. For r=56 the small term is `11*56 = 616 = 0x0268`
and the answer 991 implies `0x0068`, so one carry is lost at `acc_x5`
(224 + 56 = 280) and the doublings that follow turn that into 104.

**Why the first measurement is exact and cannot find it:** `1160 & 63 = 8`, and
`8 -> 16 -> 32 -> 40` never carries in the low byte, so the same flawed guard
is *correct* for that value. A carry test that is exact for one operand range
and wrong for another is the worst kind: the measurement that looks right is
the one that cannot detect it.

### The fix, verified as arithmetic

The exact carry, **exhaustively verified for all 65,536 (src, dst) pairs** in a
model, and correct in the machine on the first conversion:

```text
dst_lo into Y  (never re-read, so the store over it costs nothing)
sum  = dst_lo + src_lo        -> keep the SUM in a scratch
c1   = src & dst              -> a second scratch
or_  = src | dst              -> a THIRD
~sum = 255 - sum
c2   = or_ & ~sum
carry = BIT 7 of (c1 | c2)    <- a BYTE identity whose carry is a BIT
if set, the high byte is incremented; then add the addend's high byte
```

**Scratch bytes: dmem[6..9]** -- the two ANSWER SLOTS. They are unwritten until
the bank, which overwrites them anyway, so using them touches **no program
state**. NOT dmem[4] (PREV must read 0 for the next pad check, because a
previous level that is not the idle level IS an edge), NOT dmem[5] (STATE, live
to the poll loop's dispatch), NOT dmem[2..3] (US, which the main term's Q setup
still needs).

### The three commands, and the five failures that make them necessary

1. **Replace each site's range FROM THE ASSEMBLER'S LISTING** -- label address
   to the next label, **KEEPING THE LABEL LINE** -- and compare the **whole**
   emitted block against the expected one **index by index**. Keep the
   mnemonic case in the `JZ` target.
2. **The one-line jump check**: every jump inside the conversion must resolve
   inside it (`convert` .. `park`); the only ones that may leave are the
   `JZ park` and the two `JMP main` at the end of the bank path. **This check
   has never once been wrong.**
3. Run the act.

Every previous attempt failed at step 1, in five different ways, and every one
of them produced a simulation result that meant nothing:

| # | the mistake | how it presented |
|---|---|---|
| 1 | assumed the block starts exactly FOUR lines before the `JNZ` | consumed the wrong lines; the original add survived |
| 2 | replaced only from the `JNZ` | the site's own four leading instructions stayed, so the add ran TWICE |
| 3 | invented jump labels `<lab>_hi` when the originals are `<lab>_h` | would not assemble -- the only failure that announced itself |
| 4 | the replacement range started AT the label line | **deleted the label** the doubling above jumps to |
| 5 | the verification check indexed the block off by two | reported a correct block as WRONG, and the tree was restored for nothing |

And the restore must be **unconditional**: a run that restores the tree only on
its success path left the tree BROKEN, and the next attempt started from a file
that no longer assembled.

### Also open, both cheap, neither mine

* **peasm's derivation is wrong**: the comment says `4*149+4 = 600` while the
  hardware measures **601 clocks = 10.017 µs**, which SATISFIES the device's
  10 µs minimum. The fix is to correct the comment to `4*SR_TRIG + 5` and let
  the testbench's equality follow it.
* **the inter-measurement check reports `-6116 µs`** because `t_trig_in[1]` is
  uninitialised when only one trigger was answered; it needs a guard on
  `n_trig == N_MEAS` so it says "the second trigger never arrived" instead of a
  negative interval.

### What I would do differently

**Write the four sites once as a script that EMITS the `.pe`, then assembles
and prints the block** -- instead of editing an existing `.pe` by pattern. The
act has now been edited by pattern six times and an emitter would have made all
six failures impossible.

---

## (c) FM0/FM1 — started, and its WIRE RULES were wrong twice

### The corrected rules, which everything must now be written against

```text
* EVERY BIT CARRIES A TRANSITION IN ITS MIDDLE -- always, both encodings.
  That is what makes the stream self-clocking and is the entire reason the
  encoding exists.
* THE DATA IS THE LEVEL OF THE FIRST HALF-INTERVAL.
* FM1 vs FM0 is WHICH LEVEL MARKS A ONE at the start of the interval:
  FM1 marks a one LOW, FM0 marks a one HIGH.
* therefore a bit boundary carries a transition IFF two ADJACENT BITS DIFFER.
```

Both wrong versions are in the record because both produced wrong code:

1. "a '1' has no transition at the **end** of its interval" -- that describes a
   scheme where the data lives at the bit boundary, not bi-phase coding. An
   encoder written from it made a `1` a CONSTANT LEVEL.
2. correcting that encoder to satisfy the wrong rules rather than the protocol.

### The consequence that reshapes the act

**A bi-phase stream carries NO POLARITY INFORMATION.** Nothing in the waveform
says whether a one is the low first half or the high first half. A receiver
that guesses decodes a well-formed frame into its **complement** -- every byte
wrong by a consistent bit inversion, the most plausible-looking failure in the
act. So **the protocol needs a preamble**: an asymmetric pattern whose first-half
level the other encoding's reading of the same pattern cannot produce. The
receiver locks polarity on the preamble and only then decodes.

**The check that matters most**: the same frame sent as FM0 and as FM1 must
give two different flag values and the same three bytes. That is the only way to
prove the flag is **measured** rather than **assumed**.

### What exists

* `tb/tb_pe_soc_bmc.v` -- 7 named checks, both directions, the encoding flag,
  and the constant-line case (a line held constant has no transitions and
  carries no clock, which is what a dead sensor looks like). RED, and the
  checks are RIGHT as of `3dace8`.
* `firmware/bmc_frame.pe` -- 139 words, assembles, first draft. Two fixes
  landed: the testbench's encoder is now bi-phase, and the firmware no longer
  **claims its input pad** (`0513b7e` -- a pad the firmware drives reads back
  its own register, so claiming the input meant the decoder never saw the wire;
  the sixth level/enable confusion in this block).
* the encoder, the firmware's decoder and the header's copies of the wrong
  rules still need rewriting against the corrected rules. **Nothing else in the
  act changes, and the seven checks are the right checks for the right
  protocol.**

### The ISA constraint, found by asking a question the act needed answered

A bi-phase receiver does not synchronise on a pin **level**: it **timestamps**
the level and compares it with the level at the last **change** -- and that is
what recovers the clock. **This machine cannot express it:** `OP_LDS` (0xB) is
`a <= ram[x]` with **no X destination**, so `X = ram[X]` -- the store-forward
a transition detector wants -- cannot be written, and the encoding that looks
like it (`LDM X, addr`, arg[7]=1) is a **direct** load whose address field is
the top nibble only and cannot even name byte 8. The old level must therefore
live in a **memory byte**, and that byte belongs to the decoder and to nothing
else.

---

## Findings that outlive the acts

1. **A carry out of a general 16-bit add does NOT require a zero result.**
   `0xE0+0x38 = 0x118` carries and leaves `0x18`. The exact carry is
   `((a&b) | ((a|b) & ~sum))` and **the carry is BIT 7 of that byte** -- a byte
   identity whose carry is a bit, and testing the whole byte is the same class
   of mistake as the guard it replaces. On this ISA the exact sequence is
   exhaustively verifiable in a model, and **verifying it is one second of
   arithmetic against two sessions of simulation.**
2. **The zero-result carry test is exact for a 16-bit INCREMENT** (`+1` can only
   wrap to zero) **and for a doubling** (which uses bit 7, not the result), and
   for NOTHING else. A test derived from one operation is not a test of another.
3. **`X = ram[X]` is not in this ISA** (`OP_LDS` has no X destination), and
   `LDM X, addr` is a *direct* load with a four-bit address. A self-synchronising
   decoder must bounce through a data slot.
4. **Five of the failures in the HC-SR04 act were the EDIT, not the design**,
   and all five produced a simulation result that looked like a finding. Every
   fix applied by a script that decides *where to edit* by a pattern must be
   checked against what the assembler produced, and the restore must be
   unconditional.
5. **Six probe-placement errors in one act**, each of which read as a
   conclusion: a window placed by estimate; a `dmem` location whose meaning I
   had changed; a sample taken after the program had left the value; a window
   one instruction wide; a check's own indices off by two; and a rewrite anchor
   that assumed a fixed line offset. **The one mechanical check written FROM the
   assembler's listing -- the one-line jump check -- has never been wrong.**
6. **The instrument was wrong more often than the design**, in both open acts:
   the HC-SR04 testbench compared a per-measurement claim against a number read
   in the wrong place; the FM0/FM1 testbench's encoder was not bi-phase and a
   header claim was false in four places. **Two decoders written from the wire
   rules, not from each other, is what keeps that honest** -- and so is writing
   the firmware's decoder first, since it is the one with no registers.
7. **A check that names its value finds what a check that asserts a property
   cannot.** "the receiver declared WHICH encoding (flag = %0d)" found an enable
   written backwards that "the decoder produced three bytes" would have let the
   firmware invent.
8. **The frequency meter's act is green with 58/58 mutations, the six acts of
   Blocks 1-2 are green, and the merge-repair is proven** -- so nothing in this
   block is waiting on anything except the two open items above.

---

## The branch, and what is on it

\`\`\`text
cb191ef docs(WORKLOG): the bi-phase WIRE RULES were wrong in a second way
0513b7e fix: the FM0/FM1 firmware claimed its INPUT pad
3dace8 fix: the FM0/FM1 testbench's encoder was not bi-phase
3b10217 wip: FM0/FM1 - the RED testbench now has both directions
b2cb76c wip: FM0/FM1 - the first draft of the firmware
b0351b3 docs(WORKLOG): BLOCKED on the HC-SR04 act's last block
f5844b2 docs(WORKLOG): the procedure caught its own failure twice
6a85230 docs(review): this file
\`\`\`

The working tree is clean apart from \`.pi-lens-probe-home/\`, which is a
pi-lens log artefact and has never been committed.
