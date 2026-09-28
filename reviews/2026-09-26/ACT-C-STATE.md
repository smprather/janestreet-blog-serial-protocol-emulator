# act (c) — state at the wrap

**branch `fw-timing-protocols` · worktree `/tmp/worktrees/fw-timing` · see `git log` for the head**
**The DECODE direction is green. The ENCODE direction is one bit from green, and
its remaining cause is measured and named.**

**THIS FILE IS IN THE REPOSITORY BECAUSE /tmp HAS NOW BEEN CLEANED FOUR TIMES
THIS BLOCK, and the fourth one deleted the interrupt file minutes after it was
written.** The WORKLOG has said three times that the instruments belong here; it
now applies the same sentence to the state file, which is the instrument a
context switch actually reads.

## Run it

```sh
python3 firmware/bmc_model.py                            # the model, a GATE (exits 1)
python3 firmware/bmc_checks.py firmware/bmc_frame.pe     # six checks, the sixth is the timing one
tb/probes/run.sh                                         # the testbench
tb/probes/run.sh tb/probes/probe_tb_classify.v           # the receiver's own classification trace
tb/probes/run.sh tb/probes/probe_pad_intervals.v         # the pad's interval histogram
tb/probes/run.sh tb/probes/probe_out_seq.v               # every OUT, with A, dmem[6], dmem[11]
python3 tools/fw/peasm.py firmware/bmc_frame.pe > firmware/bmc_frame.hex
```

## THE WIRE IS RIGHT, AND THE HISTOGRAM IS THE PROOF

| | model | measured, per pass |
| :--- | :--- | :--- |
| changes on the return leg | 63 | 63 |
| one-half-interval gaps | 46 | **46** |
| two-half-interval gaps | 16 | **16** |

And **all 24 routes between two `OUT TXPIN` are exactly 120 clocks** — the
sixth check, which SIMULATES its delay loops rather than charging them a flat
rate, because the version that assumed three clocks a pass reported 120 for
firmware transmitting 60% slow.

## RED: THREE CHECKS, AND THE CAUSE IS ONE EXTRA BIT

`dec_have` and the flag check pass. The three byte comparisons fail, and
`tb/probes/probe_bitstring.v` names the fault at bit resolution — the receiver's
24 payload bits in ARRIVAL order, beside the sent 24:

    sent     10100101 00111100 10010110     a5 3c 96, high bit first
    arrived  1|10100101 00111100 1001011|0

**ONE extra bit at the front, and then twenty-two bits line up exactly.** The
receiver's payload starts one mid EARLY and then reads the frame perfectly.

**The extra bit is a 1 because `a5`'s bit 7 is one AND the preamble's last bit
is one**, so the two are indistinguishable in the levels: the seam is a boundary
between two EQUAL bits, which carries no transition, and nine one-bits run
together across it. Only the phase can tell them apart.

**The wire is right** — 63 changes, 46 one-half and 16 two-half gaps per pass,
which is the model's histogram exactly — so this is the receiver's mid count at
the seam. `probe_tb_classify.v` rows #25 to #28 are the last mid of the preamble,
the boundary after it, the mid that completes the byte, and the first mid of
the payload.

**The boundary between the preamble and the payload is a boundary like any
other, and the phase already knows it:** after the preamble's last mid the phase
says "the last change was a mid", so a two-half gap there is a MID and a
one-half gap is a boundary. **The missing bit is the payload's first, and the
fault is in whichever term of that sentence is wrong** — the histogram proves
the wire, so it is the receiver. `probe_tb_classify.v` shows the classification
at the payload's first mid in one line.

## THE ORDER CHECK, WHICH WOULD HAVE SAVED THE FIRST HOUR

*In the encoder, the byte must not be peeled with `SHR`.* `SHR` is
`a <= {1'b0, a[7:1]}`: the new bit 7 is always zero and a shift-right moves bits
DOWN, so a byte peeled with SHR goes out **low bit first** and there is no
shift-LEFT to re-align it. The handoff's recipe ("test the top bit, then peel")
was inside a correction of a claim about the ISA and repeated it.

**MEASURED when it was there:** `dmem[11]` went `0xFF`, `0x7F`, `0x52`, and
`0x52` is `0xA5` shifted right. **It hid behind the preamble for sixteen
half-intervals because its byte is `0xFF` — eight ones in EVERY order** — so the
only thing that caught it was the receiver's own trace: a four-microsecond gap
inside a run of eight identical bits, which the wire rules say cannot exist.

It is a one-line mechanical signature, provable by putting the peel back, and it
belongs beside the branch-operand and store-run checks.

## WHAT IS NOT DONE, DELIBERATELY

* **Not wired into `regress/run_all.sh`.** A `<<wip>>` case that PASSES is itself
  reported as a failure so it can be un-marked, and this one does not pass yet.
* **No commit is left half applied.** An earlier mask rework that did not
  converge inside its session was reverted rather than left in the tree with a
  red timing check; its shape is in the WORKLOG, not in the firmware.

## THE FAULTS OF THIS ACT, and the instrument that found each

| fault | found by | why nothing else could see it |
| :--- | :--- | :--- |
| `frame_done` never reached (3 compared against a pre-increment register) | counting executions of the encoder's own `OUT`: zero in a pass | five green checks over a branch that never fires |
| a masked value tested against 1 | the round trip failing | arithmetic on a value in the wrong domain |
| a parity test asking "is it zero" for "is it odd" | the mid delay loop entered 0 times | a correct comparison of the wrong question |
| the byte-spent test asking where the byte STARTS | 1330 reloads for five bytes | a correct comparison of the wrong question |
| the keep-branch leaving A holding the test's own result | 144 gaps of 121 clocks, none of 241 | a taken branch, a right label, a fitted route |
| the byte dispatch off by one byte | the pad's histogram | three labels that agreed with each other |
| the jump check reading 8 bits of a 10-bit field | it answered "13 mismatches" on firmware that runs | a check that had only agreed with a small program |
| the delay loop a running sum, not a countdown | 49 passes where 25 were counted | the check shared the assumption it tested |
| the encoder peeling with SHR (bit order) | a 4 us gap inside eight identical bits | a preamble made of `0xFF`, which is order-free |
| the TB's data bit on the wrong side of the mid | the preamble read 0xFF and the payload read its complement | the flag is read off the preamble |

**Nine of those ten are invisible to a structural check, and the tenth was in
the check itself.** That is the act's whole subject, and it is why the
instruments here print: every number in this file came from one of them.
