---
title: Host Stack — the Pico bridge, the session, the model, the packages
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [verification, tooling, architecture]
sources: [tools/host_gui/session.py, tools/host_gui/protocol.py, tools/host_gui/fake_pe.py,
          tools/host_gui/r2_vectors.py, tools/host_gui/r3_vectors.py, tools/host_gui/web/app.js,
          tools/host_bridge/main.py, tools/host_bridge/pe_frame.py, tools/host_bridge/acceptance.py,
          docs/host-bridge-bringup.md]
confidence: high
---

# Host Stack

A laptop-side debugger for a chip whose host bus is a register-level SPI
protocol, reached through a **Raspberry Pi Pico running MicroPython**. Nothing
here has run on a board: every claim below is about simulation, and the one
honest sentence about hardware is the last one. The rule the stack is built
around is that **a model is evidence about a model** — a `chip_confirmed` flag
names a citation to the chip's own run, and nothing here claims silicon.

The chip's host port is a **passive slave**
([[decisions/adr-007-pe-ctrl-passive-slave]]), so a host has to exist to drive
it: this stack is a consequence of that decision, not an optional extra. Layers,
outermost first: the Pico bridge (USB CDC → framed SPI), the `ControllerSession`
state machine, the `FakePE` model, the golden packages that make conformance
byte-exact, the GUI, and the harness that drives it against a real board. The
ordering and the definition of done live in [[plans/host-controller-gui]].

## The bridge: framed SPI, and the wait words at the read boundary

`tools/host_bridge/` is six Python modules plus `deploy.sh`. The Pico speaks
JSON lines over USB CDC and implements **18 ops**: `hello`, `prepare`, `ping`,
`load`, `start`, `stop`, `status`, `read_cpu`, `read_imem`, `read_dmem`,
`dump_core`, `clear_fault`, `target`, four `debug_*`, `set_sclk`. The wire
frame is `0xA55A` sync, a header byte packing version (3:0), opcode (7:0) and
target (3:0), the payload, then **CRC-16/CCITT-FALSE**; responses are
big-endian words.

**The wait words are the first thing to understand.** A bounded read (an
`IMEM`/`DMEM` read, `DUMP_CORE`) may answer with up to **15** wait words ahead
of the frame, and the Pico clocks a *fixed* budget of them for every opcode. So
for a ready-immediate op — `PING` and `HELLO` carry no payload — the buffer
holds the real frame followed by words the chip never sent, and those come off a
**released** MISO pad, because `pe_ctrl` drives MISO only while a response
shifts. `protocol.strip_wait_words` handles it in one place: skip leading
`0xFFFF` words only, bounded by `MAX_WAIT_WORDS = 15`, then **trim to the
frame's own length field**. A `0xFFFF` inside a payload stays data, and a
buffer with no frame raises rather than decoding noise.

The codec exists in **two copies** — `tools/host_gui/protocol.py` and the
MicroPython-compatible `tools/host_bridge/pe_frame.py` — because the Pico
cannot import the host package. They are not kept in sync by discipline:
`tools/host_bridge/tests/golden_vectors.json` is checked against *both*, so the
two cannot disagree about a byte. Board failures are values, not crashes:
`handle()` turns `OSError`/`RuntimeError` into a typed
`board error during <op>` so a dead clock cannot kill the serve loop.

## The session: nine states, and the rules the host owns

`ControllerSession` has **9** states: `DISCONNECTED`, `PREPARED`, `LOADING`,
`LOADED`, `RUNNING`, `STOPPED`, `FAULTED`, and the two R3 holds `DEBUG_HOLD`
(a step's pause) and `BP_HIT` (a latched hit) — split because the next action
differs.

The subtle part is the mapping from the chip's state word, and the rule is that
**the run strap is never inferred from it**. The chip encodes
`dbg_hold_r ? (bp_hit ? 3 : 2) : (run ? 1 : 0)`, and 2/3 are compatible with
the strap being either high (a live hit stops the core without dropping the
strap) or low (a step landed on the breakpoint). `DEBUG_STATUS` is the one
debug op that reports the strap explicitly, so the session takes the strap from
there and from `start`/`stop` only.

Some refusals are the **chip's** (`DEBUG_STEP` on a free-running core); others
are **host policy**, stated as such — a step needs something loaded and no
latched fault, because the chip would happily execute against whatever words
happen to sit in IMEM. The GUI mirrors those rules rather than keeping its own
list, and a test drives `app.js` in `node` to prove the two agree state by
state.

One trap is now warned about rather than enforced: `DEBUG_BP_SET` clears
`bp_en` and `bp_hit` but **not** `dbg_hold_r`, so an arm made on a held core is
**step-only** — the free-running hit needs `!dbg_hold_r` (`pe_ctrl.v:692`) while
the step path does not (`:1067`). The session raises a `UserWarning` naming
this and the recovery (`resume_with_breakpoint` = step, clear, re-arm). It
warns rather than refuses because the chip supports the operation; a first
attempt refused it and turned two acceptance beats red.

## FakePE: what it models, and where it cannot

`fake_pe.py` models `pe_ctrl` + `pe_cpu` and carries the **7** R2 read and
**20** R3 debug obligations as probes. It is faithful about register semantics
— including the hold asymmetry above — because the alternative is a host that
agrees with a chip that does not behave that way. Two boundaries are recorded
rather than papered over, and they are different kinds of thing:

* **2 spec-vs-RTL discrepancies** (`r3_reads.DISCREPANCIES`), both **ruled
  2026-09-25** with the vectors standing: vector 11's table row says `pc=0`
  where the RTL answers the PC at the request and re-zeroes at the same edge;
  vector 13 expects `insn=imem[4]` while `pe_cpu` fetches at `next_pc`, so a
  free-running readback reports the landing word.
* **1 step the chip has not confirmed** — `status_full_readback`'s `insn` — for a
  TB reason, not a contract one: a freeze-snapshot model pins `pc` every cycle
  and collapses the fetch pipeline onto the fill word. It is left unconfirmed on
  **both** sides rather than bent to match a testbench.

## The golden packages, and how conformance stays byte-exact

Two packages, generated from the model and consumed by the chip's testbenches:
`r2_vectors.py` (**11** vectors, **22** steps, **22** chip-confirmed, 0
unconfirmed) and `r3_vectors.py` (**14** vectors, **26** steps, **25**
confirmed, **1** unconfirmed). Each step stores request and response frames, so
the chip compares bytes — CRC included — not fields.

Prose staleness kept producing notices that disagreed with their own flags, so
two rules are structural rather than editorial: the **notice is generated** from
the flag arithmetic, so it cannot describe a different state than the data; and
a step that is **not** confirmed must be enumerated **by name, with a reason**
or the build fails — in both directions, so a reason cannot outlive the flip
that confirmed the step. The hex export is gated the same way: its manifest
carries the notice and the evidence block and the drift gate compares both
against a fresh build, because that file is what the chip copies, and a claim
drifting there is a claim the chip inherits.

## The GUI: a capability table, and two poll paths

Sixteen routes in `server.py`, four main buttons (load, start, stop, dump) and
four debug buttons (step, set bp, clear & release, continue keeping bp). Two
polls, both verified against the session rather than assumed:

* **1 000 ms** — `READ_CPU`, the one **non-halting** read, which also keeps the
  heartbeat moving while the core runs (registers and liveness in one read);
* **2 000 ms** — a light `STATUS` read whenever connected, because the Pico
  samples `IRQ_N` only when a host request unblocks its read loop, so a session
  that sends nothing would never observe a chip fault.

The capability table is not hand-written: a test asks the session which
operations it accepts in each state and compares that with what the page
enables, driving the page's own functions. `DUMP_CORE` being unavailable under
`BP_HIT` is that gate's most useful result — the chip answers `NOT_READY` there
while the strap is high.

## Fuzzers and soak: the discipline, and their defaults

Three harnesses, all seeded and all with a wall-clock budget so a gate cannot
hang. `fuzz_protocol.py` — seed **20260925**, **4 000** iterations, **20 s** —
covers the frame codec and its wait-word trimming. `fuzz_server.py` — seed
**20260926**, **200** iterations × **20** rounds, **8** threads, **60 s** —
covers the API layer. `soak_host.py` — seed **20260926**, **20 min** default —
samples every **100** operations / **2.0 s**, reconnects every **2 000**, and
asserts **bounded growth** with ceilings of **8.0 MB** RSS and **50 000** objects,
so a leak is a red gate rather than a slow death. The soak is only meaningful
because the polls run everywhere: a liveness check that watches only a running
core passes while an idle board is wedged.

## The board run, and what is not claimed

```bash
python3 tools/host_bridge/acceptance.py --device /dev/ttyACM0 \
    --project tt_um_protocol_emulator     # both are defaults; --board <label> is recorded
python3 tools/host_bridge/acceptance.py --fake   # never opens a serial device
```

`--fake` is a complete honest end-to-end run over the real GUI, session,
transport and bridge with a modelled chip; the tree reports **37 PASS / 0 FAIL
/ 1 SKIP** across 38 beats, and the skip is a documented gap (no bridge op
reports UART bytes). `tools/host_gui/run_host_tests.sh` is the one-command
gate: **413** host-GUI tests, **109** bridge tests, ruff, both package gates,
all three fuzz/soak harnesses, `compileall`, and the MicroPython conformance
step.

**Not hardware-confirmed: no board has been run.** The real Pico/USB run is
unexecuted and is not claimed anywhere in this stack. When it happens, the
triage table in `docs/host-bridge-bringup.md` is the first thing to read: it is
organised by symptom, including the two that can only fail on hardware — the
`IRQ_N` shuttle revision and the MISO read path. The host never reports a
timed-out or unacknowledged operation as success, so a `FAIL` means the real
thing failed.

## Numbers, and where each one comes from

| claim | value | measured by |
| --- | --- | --- |
| host-GUI / bridge tests | 413 / 109 | `unittest discover`, both suites |
| acceptance, fake chip | 37 PASS, 0 FAIL, 1 SKIP (38 beats) | `acceptance.py --fake` |
| R2 package | 11 vectors, 22 steps, 22 confirmed, 0 unconfirmed | `r2_vectors.build_package()` |
| R3 package | 14 vectors, 26 steps, 25 confirmed, 1 unconfirmed | `r3_vectors.build_package()` |
| bridge ops / modules / images | 18 / 6 + `deploy.sh` / 6 `.pe` | `main.py`, `tools/host_bridge/`, `firmware/` |
| session states / server routes | 9 / 16 | `session.SessionState`, `server.py` |
| polls | 1 000 ms CPU, 2 000 ms status | `tools/host_gui/web/app.js` |
| wait words | ≤ 15, leading only, trimmed to length | `protocol.MAX_WAIT_WORDS` |
| fuzzer / soak defaults | 4 000 @ 20 s; 200 × 20 @ 8 threads, 60 s; 20 min | the harnesses' `DEFAULT_*` |

Sited with `docs/host-bridge-bringup.md` (board procedure and triage table),
`reviews/2026-09-25/HOST-GUI-R3-PREP.md`, `HOST-SOAK-API-FUZZ.md` and the
R2/R3 verification records whose counts are quoted above; the contract itself
is the chip repo's `R3-DEBUG-CONTROL-CONTRACT.md`, and
[[concepts/spi-as-firmware]] explains why that bus is a software loop.
