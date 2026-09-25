# Independent review — host-side code as merged into THIS repo (2026-09-25)

Reviewer: the chip-side worker. **I did not write any of this code**; the host
branch was developed and merged by the gui-worker (1cbc0bc, keep-both). Scope,
read-only, exactly as dispatched: `tools/host_gui/**` and `tools/host_bridge/**`
as they exist in this repository after the merge.

Reviewed against the wire contract **I implemented and documented** in
`rtl/pe_ctrl.v` and `reviews/2026-09-25/R2-READ-PATH-REVIEW.md`. Any
disagreement between the host code and that contract is a finding. I fixed
nothing; this is a report.

## Verdict

The host-side **protocol model and its golden vectors agree with the R2
contract in every checkable detail** — opcodes, status codes, the 11-word
STATUS, ISA-native register widths, the sticky `FAULT_RANGE` lifecycle, and
byte order. The vectors are correct and, as `chip_confirmed 15/15` now records,
they genuinely match the chip.

**But the host code has never been exercised against the chip's actual SPI
behaviour**, and there is one blocking defect that would fail on the first real
board. Everything else is smaller. The short version: the model proves the
protocol; it does not prove the transport, and the transport is where R2 changed
the rules.

---

## BLOCKING

### B1. The bridge cannot read a bounded READ: the R2 wait-word rule is not implemented

`tools/host_bridge/tt_adapter.py:118` `host_spi_transfer()` performs a single
fixed-length exchange:

```python
received = bytearray(len(data))
self._spi.write_readinto(data, received)
return bytes(received)
```

The receive buffer is exactly the request length, and `main.py:_pe_request()`
hands it straight to `pe_frame.decode_frame()` with no scanning for wait
words. There is no wait-word handling anywhere in `tools/host_bridge/**`; the
only occurrence of the phrase in the host tree is a docstring in the
*conformance generator* (`r2_vectors.py:77`), not in the path that talks to
hardware.

**Why this fails on hardware.** I implemented the R2 wait-word contract
precisely because a bounded read cannot answer inside the request's own bit
times: the chip drives `0xFFFF` filler while it fetches, and the real frame
starts at the first non-`0xFFFF` word (worst case 15 filler words). The bridge
as written will read filler as if it were the frame header, so **every
`READ_IMEM` / `READ_DMEM` will fail to decode on a real board** — while passing
every host test, because those tests drive the FakePE model, not the SPI path.
`READ_CPU` and `DUMP_CORE` are ready-immediate and would work, so this would
present as "some reads work, the memory ones mysteriously don't".

Two further consequences of the same fixed-length design:
- The response can also be **shorter** than the request for a 1-word reply, so
  the current fixed-size read is already length-wrong for every opcode; the
  model must be masking this by constructing equal-length exchanges.
- There is no timeout/settle policy at all, so the bridge cannot bound the
  fetch it is waiting for.

The fix belongs in the host: read words, skip **leading** `0xFFFF` words, then
validate the frame — exactly as my `tb_pe_ctrl_r2` does, and as the contract
header states. I am not making that change here; it is the host branch's file.

## MAJOR

### M1. The SPI path has no coverage, which is why B1 is invisible
`tools/host_bridge/tests/test_tt_adapter.py` and `fakes.py` drive
`host_spi_transfer` with a **fixed** `state.response`, and
`test_host_spi_transfer_holds_cs_low_and_releases` asserts
`received == b"\xa5\x5a\x00\x00"` — a fixed-length answer. Nothing in the host
suite ever feeds a response with a variable latency, a leading filler, or a
length different from the request. The conformance suite that *does* know about
wait words is the model-side one, which bypasses the adapter entirely. A single
test that returns `0xFFFF 0xFFFF 0xFFFF <frame>` through the adapter would have
caught B1.

### M2. The model is the oracle for its own contract
`chip_confirmed 15/15` is a real result, and I confirmed the chip matches the
vectors byte-for-byte. But the vectors were generated *from* the FakePE, so
"chip agrees with the model" and "the model is right" are separate claims; only
the first is proven. The model is very carefully written (I checked its
opcodes, STATUS shape, widths, RANGE and sticky-fault policy against my RTL and
it is faithful), so I am not asserting a defect — I am recording that the
evidence does not extend to the transport.

## MINOR

### m1. `irq_n` is deliberately unavailable and the comment says so
`tt_adapter.py:130` returns `None` with the comment "no IRQ input until RTL
phase R1". R1 has since landed and the pad is mapped, so the comment is stale
and a reader may conclude IRQ is unimplemented when it is simply not wired yet.
Not a defect; a stale comment.

### m2. Two copies of the frame codec must be kept in step by hand
`pe_frame.py` and `protocol.py` are independent implementations of the same
codec, cross-checked by a test. That is a reasonable isolation choice for a
MicroPython deployment with no host package, but it means a contract change
(such as the wait-word rule) has to be made twice, and the check is a test
rather than a shared source. Worth a comment saying so at the top of both.

## MicroPython correctness: the claims hold up

`micropython_check.py` says compatibility is "measured, not assumed", and on
inspection the claims are honest:
- the module avoids `dataclasses` and `typing` and uses a minimal HAL double,
  which is the right call for CircuitPython/MicroPython;
- annotations are handled defensively for MicroPython's eager evaluation;
- the board-only paths (`machine.SPI`, `machine.Pin`) are imported lazily inside
  functions and guarded, so importing the module off-board does not explode.

I found no claim in that file that the code does not support. One caveat, not a
finding: the check is a **static/structural** check plus a HAL double, so it
demonstrates the bridge avoids constructs MicroPython rejects — it is not
evidence that the code runs on a real Pico. That remains exactly what the
hardware-gated acceptance item is for.

## Test quality

The host suites are well constructed where they reach: good boundary cases
(CS-to-first-clock sweeps, the R1 load-transaction semantics, the R2 range and
fault lifecycle), real fault injection, and a drift gate between image and
streams. The gap is narrow and specific: **every test terminates in the model,
and the model's SPI is synchronous and fixed-length**, so the suite's scope is
"protocol correct" and not "transport correct". That distinction is currently
unstated, which is how B1 survived a green suite.

## What I recommend, in order

1. **B1** — implement the wait-word skip in the host's SPI read path, with the
   15-word bound as an explicit timeout, and add the adapter test that would
   have caught it. Until then, treat chip-side R2 reads as unproven on hardware
   even though they are proven in simulation.
2. **M1** — add a variable-length / leading-filler response to the adapter fake
   so the transport is covered at all.
3. Re-run the host acceptance against real hardware (already item 11 in
   `wiki/STATUS.md`).

## Scope note

I reviewed only what was dispatched. I did not audit the GUI/server behaviour,
the deploy script, or the canvas, and I did not re-run the host's own test
suites — the review is by reading, against the contract.
