# Act (c) FM0/FM1 — handoff after the 70% wrap

**branch `fw-timing-protocols` · worktree `/tmp/worktrees/fw-timing` · `f649969`**
188 words. **The DECODE direction is GREEN and the ENCODE direction is RED**, and
the split is now a line rather than a mood.

Written to the repository on purpose, as the last one was: /tmp has been cleaned
three times this session with files in it, and the two artefacts that decide
this act -- `firmware/bmc_model.py` and `firmware/bmc_checks.py` -- are now in
the repository for the same reason.

---

## THE MANAGER'S RULING ON THE ENCODER SHAPE: LOOPBACK

**The firmware's encoder sends THE THREE BANKED BYTES back -- dmem[0..2], the
frame it just received -- re-encoded under the encoding it DETECTED, the one in
dmem[3]. The testbench's decoder decodes three bytes and compares them against
the frame that was sent. The same frame must come back byte-identical under
either encoding.** That is the act's name -- bi-phase LOOPBACK -- and it is the
right shape for a reason the ruling did not need to state: **it is the only
shape in which the flag is load-bearing in BOTH directions.**

### Why the ruling is sharp, and it is worth saying out loud

Neither side is told the other's polarity. The testbench's decoder locks its
own from the preamble's LEVELS, and the firmware's decoder locked its from the
same. So a firmware that re-encoded under the WRONG flag would still put three
recognisable bytes on the wire -- and the testbench's decoder would invert them
with ITS OWN flag and hand back the complement. **A wrong encoder polarity is
caught, and only because the receiver inverts with a polarity it measured
itself.** The bytes come out right if and only if the two independent
measurements agree. No other shape of this act tests that.

### What the ruling implies, so the next session does not rederive it

1. **THE RETURN LEG NEEDS A PREAMBLE, and it is the same preamble.** A
   receiver has the same problem on the way back: the first transition of a
   transmission is the one whose class depends on the polarity, and the
   testbench's decoder will resync on it exactly as the firmware's did. So the
   firmware must put eight zeros then eight ones on OUT_PAD, and the testbench's
   decoder must do the SAME three-state phase lock the firmware now does --
   skip one-half gaps while the phase is UNKNOWN, emit only on a two-half gap,
   read the preamble's received byte as the flag, then invert the payload if
   that flag says FM1. The two directions are the same protocol, and the
   firmware is about to be the transmitter of it.
2. **40 bits go out: 16 preamble + 24 payload**, which is 80 half-intervals =
   160 us, and it starts after the 160 us of input frame plus the firmware's
   own margins. The testbench's 1200 us per pass still covers both legs with
   room to spare -- checked, not assumed.
3. **THE BIT ORDER IS THE SAME high bit first**, because the decoder's
   shift-in puts the first arrival in the high position and the return leg has
   to be decoded by the same rule. The encoder must therefore take bit 7 first
   from a byte it is consuming. **See the SHR finding below: it can, cheaply.**
4. **`dmem[6]` IS FREE**, because the byte to send is no longer a "tx byte" --
   it is dmem[0..2], which the decoder just banked. The encoder's half-interval
   counter takes the byte the old tx-byte role used, and **dmem[13] stops being
   shared**: the old stub counted half-intervals in dmem[13], which is the
   DECODER's preamble-still-running byte. Nothing else in the map is safe: main
   writes dmem[10] and dmem[14] on every poll, so neither can hold encoder state
   across a delay loop, and dmem[14] being "written and never read" does not
   make it free, because main writes it.
5. **THE ENTRY POINT IS A DECISION, and the cheap reading is wrong.** Today
   `frame_done` parks, and the encoder is reached from main's
   `LDM A,11 / JNZ encoding` mode dispatch. Under loopback the natural handover
   is at `frame_done`, because that is where the three bytes become available --
   and if the encoder is entered from the poll loop instead, main will re-enter
   it on the next poll and restart the transmission. So: either `frame_done`
   sets dmem[11] = 1 and falls into the encoder, with the dispatch as the one
   entry, or `frame_done` jumps straight in and the dispatch is deleted as a
   second entry with no caller. **Do not leave both.**
6. **`<<wip>>` until it is green.** It is not in the regression and it is not
   claimed, and the two red checks are the honest end state until then.

### THE SHR FINDING, made in the listing, because it changes the design

**THIS ACT'S OWN COMMENTS ARE WRONG ABOUT THE ISA IN THREE PLACES, and the
error is load-bearing for exactly the work that is left.** The firmware header,
the `NO DIVISION` block in the decoder, and the previous handoff all say this
machine has no shift-right. **It does.** Assembled and counted, not read:

```text
  0  D00C  LDM A, 12
  1  A000  SHR          <- opcode 0xA, a <= {1'b0, a[7:1]}, NO OPERAND
  2  0080  LDI A, 0x80
  3  7A00  AND A, X
  4  A000  SHR A        <- "SHR A" assembles the same; it is documentation
```

`tools/fw/peasm.py` lists `SHR` in its table and `rtl/pe_cpu.v` line 327 is
`OP_SHR: a <= {1'b0, a[7:1];`. It shifts by exactly one, takes no operand, and
**discards the bit it shifts out**, so the encoder tests the top bit first
(`LDM X,12 / LDI A,0x80 / AND A,X`) and only then peels (`LDM A,12 / SHR`).

What this changes: the "high bit first" wire order, which was adopted last
session as the *only free* option, is free because the encoder could not cheaply
do the other thing -- and now it can do this one too, so the order is chosen by
the protocol and not by the ISA's gaps. **AND THE CLAIM MUST BE CORRECTED IN THE
FIRMWARE'S COMMENTS IN THE SAME STEP**, because the next reader will design the
encoder around a limitation that does not exist, which is the most expensive kind
of stale figure: one that is load-bearing.

**There is still no shift-LEFT**, so the decoder's shift-in stays a doubling
(`A = A + A`, then the bit in at the low end) and everything already measured
about it stands.

### The order, which is the order that just worked here

1. **Model the encoder's wire output in `bmc_model.py`**, half-interval by
   half-interval, from the wire rules -- both polarities, and with the preamble,
   so the model's transition times and interval histogram for the RETURN leg are
   the thing the firmware is written against.
2. **The firmware to the model**, and **count the 120-clock half_wait in the
   listing before simulating it.** The stub's `half_wait` cannot terminate: it
   loads dmem[13], sets it to 0xFF and spins on a byte nothing will ever clear.
   A loop of `LDI A,1 / SUB A,X / JNZ` is 3 instructions per iteration, so 40
   iterations is 120 clocks exactly -- and then count the instructions on the
   path in and out, because the block is only 120 clocks if the whole path is.
   The block's counted-delay-constant discipline, applied to a delay.
3. **The testbench's decoder to the wire rules, NOT to the firmware**, and then
   let the two argue. Its present shape folds two transitions per bit and
   starts at the first change, which is the flaw this act was written to catch;
   it needs the same three-state phase the firmware has.

---

## WHAT IS MEASURED, AND IT IS THE HEADLINE OF THE ACT

    pass 0: sent FM0 -> the firmware banked a5 3c 96, dmem[3] = 00
    pass 1: sent FM1 -> the firmware banked a5 3c 96, dmem[3] = 01

**Two different flags and the same three bytes, from the same frame.** That is
the check the act has wanted since it began, and it is now the check the
testbench runs, per pass, against the polarity that was actually sent.

## THE ONE-BIT-LATE FAULT IS GONE, AND IT WAS NOT A COMPENSATION

`dmem[15]` is a THREE-state phase: 1 = the last transition was a boundary, 0 =
a mid, **2 = UNKNOWN**, which is what the resync leaves behind. While it is 2 a
one-half gap emits nothing, and only a **two-half** gap may emit -- a two-half
gap is mid-then-mid whatever came before it, so it is the one interval in this
encoding that is unambiguous on its own. The preamble's eight-zero run
guarantees exactly one, and the model puts it at **t = 34 us of the frame in
both polarities**. So the receiver never has to tell which case it is in, which
is the difficulty the handoff named: it does not have to, because it refuses to
answer until the clock is unambiguous.

Two things the model settled that the handoff had backwards, both worth keeping:

* **the loss is NOT asymmetric in the way the handoff said.** It said nothing is
  lost under FM1. The model says FM1 loses a bit too -- its first transition is
  the MID of bit 0, the old algorithm read that as a boundary, and 31 payload
  bits come out, exactly as for FM0. The phase error moves, it does not go.
* **both polarities lose the same eight preamble bits**, which is what lets ONE
  preamble-end test serve both. A preamble whose length depends on which
  polarity lost the race is not a preamble, it is a race.

## THE FLAG IS READ OFF THE WIRE, IN THREE ANSWERS

The preamble's received byte is eight ones AS LEVELS: 0xFF is FM0, 0x00 is FM1,
and **anything else means the receiver locked onto something that is not this
preamble, which it now DECLARES (dmem[3] = 0xFF)** rather than calling FM1. The
payload is then inverted whenever the flag is FM1 -- without that step the frame
comes back as its own complement, measured as 5a c3 69, which is the most
plausible-looking failure this act exists to be able to name.

## THREE FAULTS THAT ONLY THE RIGHT PHASE COULD SHOW

1. **THE WIRE IS HIGH BIT FIRST, and the ISA decided it.** The receiver's
   shift-in is a doubling with the arriving bit in at the low end, so the first
   bit to arrive lands in the high position; a low-bit-first frame assembled as
   `79 4A FF`. Placing a bit at weight 2**count is a variable shift this machine
   does not have. Every derived number moved with the change (18/14 intervals
   became 16/15; 9 equal-adjacent pairs became 8) and the encoder self-check
   now prints the values it derived rather than a remembered string.
2. **`JZ`/`JNZ` TEST A, NOT A FLAG.** The first polarity gate tested dmem[3]
   with a `LDM` followed by a bare `JZ`, so the branch saw the level. Measured:
   the inversion was taken **zero times out of thirty-two bits**, in both
   polarities, with the jump check, the reachability pass and the adjacent-label
   check all clean. The rule: the instruction before a JZ/JNZ is a SUB.
3. **`dmem[4] IS A MASKED LEVEL, NOT A 0/1.** `the_pin` does
   `IN A, PIN / AND A, BMC_IN`, so the level stored is 0x20 or 0x00. Every use
   of it had been a comparison against BMC_IN, which is blind to the mask, and
   the first thing that arithmetic'd on it produced `1 - 0x20` and banked
   `bf 9f df` for a frame of `a5 3c 96`. A level stored masked has to be
   compared masked, everywhere.

## THE TWO CHECKS THAT ARE STILL RED, AND THEY ARE ONE ITEM

**The encode direction.** Two red checks, both naming it: the testbench's
decoder recovered no frame from the firmware's pad, and its flag is -1.

* the firmware's encoder is still the ten-word stub whose `half_wait` cannot
  terminate -- `LDI A,BMC_HALF / STM 13,A` then `half_wait` reads 13, sets it to
  0xFF and spins on a byte nothing will ever clear;
* the testbench's decoder folds **two transitions per bit**, which is the flaw
  this act was written to catch, and it starts at the first change, which
  assumes a frame-start transition that only one polarity has;
* and the shapes do not match: the firmware has ONE byte to send (dmem[6]) and
  the testbench expects three (it compares `dec_byte[0..2]` against the frame).
  That is a design decision nobody has made, not a bug.

**The order to do it in, and it is the same order that just worked here:** model
the ENCODER's wire output in `bmc_model.py` first (half-interval by half-
interval, from the wire rules), then write the firmware to the model, then write
the testbench's decoder to the wire rules and not to the firmware, then let the
two argue. A `half_wait` that must be exactly 120 clocks is countable in the
listing before it is simulated -- count the instructions on the path.

**Wire it behind `<<wip>>`.** It is not in the regression, it is not claimed,
and the two red checks are the honest end state until it is.

## RUN IT

```sh
python3 firmware/bmc_checks.py firmware/bmc_frame.pe    # the five checks
python3 firmware/bmc_model.py                           # the model, both polarities
python3 tools/fw/peasm.py firmware/bmc_frame.pe > firmware/bmc_frame.hex
/tmp/run_bmc_probe.sh /tmp/probe_cls.v                  # classifications by name
```

`probe_cls.v` counts mids, boundaries, resyncs, unknown-skips and byte_done by
NAME, with the addresses injected from the assembler's listing. It is the probe
that answers "how many of each" without a hand-counted address, and it is the
first one to run. `probe_bits.v` prints the emitted stream grouped into bytes
and `probe_inv.v` prints dmem[3], dmem[4] and dmem[13] at every bit_store.

**Run the checks after every edit and read the WHOLE block in the listing.** That
rule caught three faults this session, and one of them -- a cleared preamble
flag that left the preamble running for the whole frame -- was invisible to
every check and visible in one probe line.

## THE FIVE CHECKS, AND WHY THE LAST TWO EXIST

1. the one-line jump check (label map vs the encoded operand) -- has never been
   wrong;
2. reachability -- the only unreachable words are the encoder stub's;
3. adjacent labels -- a label immediately after another is a fall-through
   waiting to happen, and it is how `data_zero`/`resync` was missed once;
4. **a store run split by a setter that CHANGED the value** -- the fourth
   permanent check the handoff asked for, and the class all three above are
   blind to by construction. Proven against a copy with `LDI A, 1 / STM 13, A`
   put back into init, which is the fault that made dmem[11] = 1;
5. **a JZ/JNZ whose A did not come from a SUB or a load of the tested byte.**

Both of the last two took three tries to get a signature that is not the
ordinary idiom, and both are proven by putting the fault BACK into a copy and
watching the count go non-zero. A check that has never been shown to fire is a
comment.


---

# THE PREVIOUS HANDOFF, KEPT WHOLE BELOW

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
