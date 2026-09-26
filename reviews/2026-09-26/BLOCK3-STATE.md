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

---

## UPDATE: the exact carry LANDS, and the first measurement regresses

Run entirely on a copy in /tmp -- **the tree was never touched**, so a /new
landing mid-run could not inherit a dirty tree or a half-edit.

    CHECK 0  the address counter agrees with the assembler at all four sites
    CHECK 1  all four blocks are byte-for-byte the verified block
    jump check  every jump inside the conversion resolves inside it

**MEASUREMENT 1 IS NOW EXACT: 999 mm**, against the specification's 999
(it was 991). The exact carry is the fix, and it works for the value that
needed it.

**MEASUREMENT 0 REGRESSED: 222 mm**, where it was 199. This is the
interesting half, because it CONTRADICTS a claim I had been making for six
resumes: that the exact add and the flawed guard must AGREE whenever the low
byte does not carry. For r = 8 the chain is 8 -> 16 -> 32 -> 40 -> 80 -> 88,
nothing ever carries, and the two versions of the add should be
indistinguishable. They are not: 222 - 198 = 24, and 24 is a SMALL-TERM
value, so the term came out 24 where it should be 1.

**What that says, and it is the next thing to look at.** The term is
`(11r) >> 6`, and 24 is `1536 >> 6` while 1 is `88 >> 6`. So at the
shift, the small term's accumulator held 1536 rather than 88 -- and 88 is
0x0058, so a HIGH byte of 0x06 appeared in dmem[0..1] between the chain and
the shift. The chain's high byte is the only place that can come from, and
the carry test is what writes it. So the suspicion moves from the arithmetic
(which is now provably right, twice) to **which slot the chain's high byte is
in**: the scratch slots are dmem[6..9], the answer slots, and the second
measurement's bank writes 8,9 -- so a value written to the accumulator's high
byte before the shift, and read back after, would be a slot that the bank has
since overwritten. That is a NAMED HYPOTHESIS with a line to read, not a
conclusion, and the same discipline applies: measure it, do not reason it.

**THE THREE COMMANDS OF THE LAST COMMITTION ARE CORRECT AND THEY WORK.** The
first time the whole procedure has run end to end without a placement error.
What is left is one arithmetic question that the checks have now narrowed to
a single byte, and it is not a placement problem any more.

---

## UPDATE 2: THE TRACE NAMES IT, AND IT IS THE ANSWER SLOTS

The probe printed the term, the accumulator and the scratch at the instant each
bank happens:

    [bank] N=1 | T(term)=1 ACC=199 | slot0=199 slot1=182
    [bank] N=2 | T(term)=9 ACC=231 | slot0=222 slot1=231

**T(term) is CORRECT AT BOTH BANKS: 1 for r=8 and 9 for r=56** (11*8>>6 = 1,
11*56>>6 = 9). **The conversion is right.** And the two answers the
testbench reads are 222 and 999 -- of which 999 is right and 222 is not.

**222 is `sum` -- the second conversion's SCRATCH, sitting in slot 0.**

### The fault, stated exactly

I chose dmem[6..9] as the exact add's four temporaries because they are "unwritten
until the bank". **That is true of the answer for the CURRENT slot and false of
the PREVIOUS one.** The order inside one conversion is: the small term's chain
(scratch 6-9), the shift, the main term's chain (scratch 6-9), the final add,
and the BANK LAST. So the N=0 bank writes measurement 0 into 6,7 -- and the N=1
conversion's temporaries then **overwrite 6,7 with its scratch**. The testbench
reads the slots at the end, by which time slot 0 holds the second conversion's
leftover `sum` and not the first measurement's answer.

**So measurement 1 is exact at 999 mm because its bank is the last write in the
run, and measurement 0 reads 222 because its answer was destroyed by the next
conversion's scratch.** Neither the arithmetic nor the carry is at fault. The
exact add is correct; the ALLOCATION is not, and the allocation was my choice
four resumes ago, made for a reason that was almost right.

### The constraint this exposes, and it is the act's real one

**SIXTEEN BYTES IS NOT ENOUGH FOR TWO BANKED ANSWERS PLUS FOUR ADD TEMPORARIES
DISJOINTLY.** The temporaries need four bytes that nothing else reads; the
answers need four; the accumulators need four (two of 16-bit values); the tick
needs one; PREV and STATE need two; the count, the flag, the width and the two
Q bytes need five more. The arithmetic cannot be blamed for the shortfall and
no arrangement of the existing map fixes it.

**THE THREE WAYS OUT, and the one I would take:**

1. **BANK ONE POINT PER RUN**, as the frequency meter does with two. The
   temporaries then have the whole map to themselves and nothing to destroy,
   at the cost of a run per measurement.
2. **SAVE THE TERM BEFORE THE MAIN TERM'S CHAIN** -- the term is one byte, it
   is finished before the main chain starts, and one byte outside 6-9 is enough
   to keep it. This is the smallest change and it makes the two banked answers
   safe, because only the CURRENT slot is ever scratch and the previous one is
   not.
3. **REORDER: run the main term FIRST.** It needs Q = us>>6, which is the only
   thing US is used for, and after that US is dead for the whole conversion --
   so dmem[2],dmem[3] become available as temporaries and the answer slots
   stop being the only candidates.

Option 2 is the one to implement: the term is finished before the main term's
chain, it is ONE byte, and the fix is to put it somewhere the chain does not
write. The failing case is a testbench reading an answer that a later
conversion overwrote, and the next session should make the testbench say so
directly -- check each answer AS IT IS BANKED rather than all of them at the
end, which is the same "read it in the wrong place" family as the two earlier
instrument defects in this act.

---

## UPDATE 3: A SECOND INDEPENDENT ATTEMPT CONFIRMS THE CONSTRAINT

The findings file's option "run the main term first, after which US is dead"
was tried, in the three-temporary form: the exact carry needs only THREE slots
if `c2` is written over `sum` (the sum is finished with by then), and the
three candidates were dmem[2], dmem[3] and dmem[11] -- US and the tick's
previous reading.

**The three-slot sequence is EXACT for all 65,536 (src, dst) pairs.** The
arithmetic is not the problem and has not been the problem for three attempts
running.

**The act got WORSE, and that is the finding: dmem[2] and dmem[3] are NOT
dead.** The small term reads `us_lo` to form r, but the MAIN term's `Q = us>>6`
setup reads BOTH bytes of US again -- and that setup runs *after* the small
term's chain has already written its temporaries over 2 and 3. The measured
width came back as **32896 us = 0x8080**, which is scratch, not a width.

So the dead-byte budget during a chain is: **dmem[11] only** (the tick's
previous reading), plus whichever answer slot has not been written yet -- and
"whichever has not been written" depends on the bank count, which the four
add sites cannot know without being parameterised per site.

**That closes the question the last two updates opened.** There is no
arrangement of the existing sixteen-byte map that gives the exact add its
temporaries while two answers stay banked. The act's real constraint is not
the arithmetic and not the scratch choice; it is that **this machine cannot
hold two banked millimetre answers and a four-temporary exact 16-bit add at
the same time**, and every attempt to make it fit has moved the failure rather
than removed it.

**SO THE ACT SHOULD BE BUILT AS ONE MEASUREMENT PER RUN** -- which is what the
frequency meter does, and which makes the whole answer map available to the
conversion so the temporaries can be the answer slots with no previous answer
to destroy. The testbench then runs the firmware twice, once per distance, and
checks each answer AS IT IS BANKED, so a destroyed answer is reported where it
is destroyed rather than as a wrong number at the end.

That is a design change to the act, not a repair, and it should be made
deliberately rather than as a fifth attempt at the current shape. Everything
needed for it is here: the exact carry (exhaustively verified, twice, in two
and three-slot forms), the conversion's structure, the two measurements the
act claims, and the testbench's checks, which are the right checks and need
one change -- reading each answer when it is banked.

---

## UPDATE 4: THE DESIGN CHANGE IS TRIED, AND IT IS THE RIGHT DIRECTION

The shape the last update prescribed -- ONE measurement per run, the answer
slots free for the whole conversion, the three temporaries at {6, 7, 11} so
that US survives to the main term's Q setup -- assembles and runs:

* 385 words;
* the firmware banks ONE answer to dmem[6..7] and **parks**, with DONE = 1;
* the two failing measurement checks are now stale by construction, because
  the testbench still expects two banked answers per run.

**TWO THINGS ARE STILL WRONG, and both are named rather than guessed.**

1. **The answer is 256 mm where 199 is expected.** The conversion's own terms
   were correct in the previous shape (the trace printed 1 and 9 at the two
   banks), so this is a NEW observation about the new shape rather than a
   known fault reappearing, and it needs the same treatment: trace the term and
   the accumulator at the single bank, on the copy, and read the numbers.
2. **THE TESTBENCH READS A LOCATION WHOSE MEANING THE DESIGN JUST CHANGED.**
   It reports "firmware 0 us" because it reads the width from dmem[2..3], and
   in this shape dmem[2..3] are the conversion's own temporaries -- the same
   "read it in the wrong place" defect as the US read in the FM0/FM1 act and
   as the period check in this act's own earlier state. The testbench has to
   follow the design change: run the firmware once per distance, read the
   answer at dmem[6..7] AS IT IS BANKED, and read the WIDTH from wherever the
   firmware leaves it once the design no longer needs it during the conversion
   (or not at all, if the width is only ever a testbench-side measurement).

**SO THE REMAINING WORK ON THIS ACT IS NOW SHORT AND SPECIFIC**, and it is a
design change plus a testbench that matches it, not a hunt:

* finish the one-answer firmware (the 256 is one number to trace);
* restructure tb_pe_soc_sr04.v to run the firmware TWICE -- once per
  distance, resetting between -- and check each answer as it is banked;
* then the two cheap items already recorded: peasm's `4*149+4` derivation
  against the 601 clocks the hardware measures, and the inter-measureval
  check's `t_trig_in[1]` guard.

---

## UPDATE 5: THE TRACE NAMES BOTH REMAINING DEFECTS, WITH THE EVIDENCE

One probe, the single bank, every value the conversion left behind:

    [bank] DONE=1 | ACC=1 T(term)=1 | slot=0 | Q=0 0 | d2=0 d3=0

### Defect 1: the bank stores its bytes in the WRONG ORDER, and that is the 256

ACC = 1, so dmem[14] = 1 and dmem[15] = 0. The bank I wrote is

    LDM   A, 15
    STM   6, A
    LDM   A, 14
    STM   7, A

-- the **high byte first**. The testbench reads the slot little-endian, so it
computes (7 << 8) | 6 = **256**, which is exactly the number the testbench
reported. The answer was never 256; it was 1, stored backwards. Every other
act in this block writes its 16-bit values low byte first and the testbench
reads them that way, and this act's own earlier bank did it correctly -- so
this is a defect introduced by the design change twenty minutes ago, in the
one line that change added, and it was found by a trace rather than by
reading the diff.

### Defect 2: US is being destroyed, so the main term multiplies zero

`T(term) = 1` is CORRECT (r = 8, 11*8 >> 6 = 1) -- the small term is right.
But `Q = 0 0` and `d2 = 0, d3 = 0`: US is **zero** by the time the main
term's `Q = us>>6` setup runs, so the main term multiplies zero and
`ACC = 0 + 1 = 1`. The temporaries were moved to {6, 7, 11} so that US would
survive, and something is still writing dmem[2] or dmem[3] -- most likely a
survivor of the sed that moved the slots, because the replacements were made
by pattern and **the pattern edits are the thing this act has the most
evidence about being wrong**.

### What this means for the act

**Both defects are in code written in the last hour, both are named, and
neither is a design problem.** The one-answer design is sound: with the
answer slots free for the conversion, the three temporaries at {6,7,11} do
not collide with anything, and the exact carry has been verified twice. The
remaining work is: swap the bank's two bytes, find and remove the last write
to dmem[2..3], then the testbench restructure (two runs, one per distance,
each answer read AS IT IS BANKED).

**AND THE METHOD THAT FOUND ALL OF IT IS THE SAME ONE EVERY TIME:** a probe on
a copy, printing the values, and reading them. Nine of the eleven defects in
this act were found that way and **none of them by reading the diff** -- and
the two above are the first two that the diff would have shown, which is
worth noticing, because it means the method is not a substitute for review so
much as a substitute for *hunting*.

---

## UPDATE 6: THE ONE-ANSWER DESIGN GIVES AN EXACT ANSWER

Rewritten from the tree's file by the procedure that works -- every site
replaced from the assembler's listing, the label line kept -- with the
three temporaries at **{6, 7, 11}** and the bank storing **low byte first**:

    measurement 0: echo 1160 us -> firmware 1160 us, answer 199 mm (expected 199 mm)

**199 mm, exact, and the WIDTH reads 1160 rather than 0**, which is the part
that matters: US now survives the conversion, because nothing writes dmem[2]
or dmem[3] while a chain runs, and the answer is not byte-swapped because the
bank stores the low byte first. 387 words.

Measurement 1 reading X and the width reading 1160 again is **EXPECTED for
this design and not a fault**: the program measures ONE distance per run and
parks, so the testbench's second-measurement expectations are stale by
construction. That is the change the last three updates prescribed, working.

### Two defects remain in the mechanism, both found by the checks I added

1. **CHECK 1 reported 0/4 with "first difference at index 2" -- and CHECK 1 is
   wrong, not the blocks.** The block I emit contains comment-only lines, the
   listing does not, and so every index after the first comment is shifted by
   one. That is the SIXTH placement error in this act, the first one in a
   CHECK rather than in an edit, and it is the reason a check that reports
   "wrong" must be confirmed by reading what it printed before anything is
   changed.
2. **THREE STRAY INSTRUCTIONS survive in the leftover acc_x11_h block** --
   LDM A,2 and LDM A,3 twice -- because a site's replacement range ends at
   the NEXT LABEL, and the old block's <lab>_h label and its high-byte add
   sit AFTER the JZ, so they were never inside the range. The rule that
   catches this is the one the run printed: **no instruction outside the
   latches and the Q setup may touch dmem[2] or dmem[3]**. That should be a
   permanent check on this act, because those two bytes ARE the width, and
   the width is what the whole act measures.

### What is left on this act, and it is now testbench work

* fix the three stray reads (extend the replacement range past the <lab>_h
  block, or delete the old tail);
* **restructure tb_pe_soc_sr04.v to run the firmware TWICE**, resetting
  between, once per distance, and check **each answer as it is banked**
  rather than all of them at the end -- the change this act's own instruments
  have now demanded three times, in three different files;
* add the "no instruction outside the latches touches the width bytes" check
  to the act's own gate;
* the two cheap items: peasm's 4*149+4 against the 601 clocks the hardware
  measures, and the inter-measurement check's t_trig_in[1] guard, which may
  simply delete itself once the testbench runs one distance per firmware run.

**The arithmetic has been settled for four attempts running** -- exact for all
65,536 pairs in two forms, and now an exact 199 mm in the machine. What is
left is allocation, ordering and the instrument, which is where this act has
always been hardest and has never once been about the maths.

---

## FINAL STATE AT THE HARD WRAP (2026-09-27 00:30)

Everything below is COMMITTED and the working tree is clean.

| act | state | last commit |
|---|---|---|
| (b) frequency + duty meter | **GREEN, in the regression**, 58/58 mutations | `d88e316` |
| (a) HC-SR04 | firmware **exact at 199 mm**; testbench restructure outstanding | `7fc3dc8` |
| (c) FM0/FM1 | RED testbench (7 correct checks), first-draft firmware, wire rules corrected | `cb191ef` |

Plus the **merge-repair** of the six acts in main, `3657847`, proven on three
throwaway exports of main: unpatched 6/6 FAIL, the RTL hunk alone 6/6 PASS,
the TB hunks alone 6/6 PASS, both 6/6 PASS.

### What is verified about (a) HC-SR04 right now, on real RTL

* the conversion is **EXACT**: 1160 us -> 199 mm, against (1160*11)/64 = 199;
* the trigger pulse is **601 clocks = 10.017 us**, an equality, and the
  derivation in peasm's CONSTS is `4*SR_TRIG + 5`, counted from the listing;
* the exact carry is verified for **all 65,536 (src, dst) pairs**, in two forms
  (four temporaries and three), and the three-temporary form is what shipped;
* one answer per run, temporaries at {6,7,11}, bank low byte first.

### The three things still open on (a), in the order they should be done

1. **Restructure tb_pe_soc_sr04.v into two runs** -- loop over the two
   distances, reset between (rst_n low, reload, four stopped clocks then #1),
   and **read the answer at the moment dmem[10] goes to 1**, not at the end of
   the run. The end-reading is what reported a correct conversion as 222 mm.
   The full recipe is in the WORKLOG at 23:45.
2. **Three stray reads in the leftover acc_x11_h tail** (`LDM A,2` and
   `LDM A,3` twice) -- a site's replacement range ends at the NEXT LABEL, and
   the old block's `<lab>_h` label and high-byte add sit after the JZ. They are
   reads, which is why the answer is still exact, but they are reachable.
   **The rule that catches this, and it should become a permanent gate on this
   act: no instruction outside init / echo_down / convert may touch dmem[2] or
   dmem[3]** -- those two bytes ARE the width, and the width is the measurement.
3. The width check reads dmem[2..3] AFTER the bank, which is legal only
   because the conversion no longer writes those bytes. Say so in the file.

### The finding that outlives all of it

**EVERY HARD FAILURE IN THIS BLOCK WAS FOUND BY MAKING SOMETHING PROVE ITSELF,
AND NOT ONE BY REASONING AHEAD.** A primitive verified exhaustively over 65,536
operand pairs; a check run on a single known value; a one-line jump check
written from the assembler's listing; a trace of the values a program actually
left behind. The one mechanical check written from the listing has never been
wrong. The SIX written by pattern have been wrong six times, and three of those
were checks rather than edits -- a window placed by estimate, a window one
instruction wide, a block reader that stopped at the first label when the
trigger spans two. **The eye loses track of where a block starts and ends, and
every one of those failures looked like a finding until it was read.**

Also worth carrying: a carry out of a general 16-bit add does **not** require a
zero result (0xE0+0x38 = 0x118 carries and leaves 0x18); this ISA has **no
store-forward** (OP_LDS has no X destination); and **sixteen bytes cannot hold
two banked answers and a four-temporary exact add at once**, which is why (a)
measures one distance per run.

---

## THE MERGE-ORDER DEPENDENCY THE NEXT CONTEXT MUST NOT MISS

**fw-bus-protocols commit `1798abf` already corrects `firmware/dmx512.pe` AND
`firmware/spi_mode3.pe`** ("docs(firmware): correct two header figures the wire
contradicts"). The routed comment batch was already actioned by the worker who
owns those files; neither needs doing again.

Two things to know before that branch is merged:

1. **My `spi_mode3.pe` word-list fix is a different line and does not conflict.**
   Line 224 adds the word index (0, 17, 34) to BOTH bytes as independent 8-bit
   adds, so the words are `0x1134, 0x2245, 0x3356` -- the comment said
   `0x1134, 0x1245, 0x1356`, wrong for two of the three. I reverted my own
   edit of the response line precisely BECAUSE `1798abf` edits that same line
   better (it derives the wire byte as the high byte XOR 0x7E), so my branch
   still carries the stale response list and theirs replaces it cleanly.

2. **THE TWO FIXES INTERACT, AND `1798abf` FIGURES BECOME WRONG WITH MINE.**

   | | high bytes | wire bytes |
   |---|---|---|
   | corrected words `0x1134, 0x2245, 0x3356` | `0x11, 0x22, 0x33` | **`0x6F, 0x5C, 0x4D`** |
   | old list `0x1134, 0x1245, 0x1356` | `0x11, 0x12, 0x13` | `0x6D, 0x6C, 0x6F` <- what 1798abf states |

   So `1798abf` is right for the words the comment used to claim and wrong for
   the words the code builds. **Whichever commit lands second has to recompute
   the response bytes from the corrected words.** That is the one thing in this
   block that two workers have to agree on, and it is arithmetic rather than
   judgement.

## AND THE PATTERN ACROSS ALL FIVE

Five wrong figures in this block, every one a derivation or a duplicate of a
derivation that nobody recomputed when an input moved: the servo `4*152+11`,
the trigger `4*149+4`, the `(2,13)` pair at 1.22 us, the SPI word list, and a
response list that was correct only for a word list that was itself wrong.
Three reached me as routed corrections and two I found by reading the code.

**And the two I could check mechanically I did:** the trigger from the
assembler listing (after three failures by eye) and the word list from the code
that builds it. The three I could not check -- a comment claiming a value whose
derivation lives in a testbench model, a comment naming bytes the model
derives, and a comment belonging to a file that is not on my branch -- are the
three that were wrong, and all three are wrong in the way a duplicate is wrong:
they assert a number in a second place, and the second place is what goes stale.
