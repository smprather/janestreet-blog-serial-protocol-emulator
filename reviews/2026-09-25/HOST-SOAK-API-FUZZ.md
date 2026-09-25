# Host server/API fuzz + soak (2026-09-25)

**Actor:** `gui-worker`. **Scope:** the host branch only
(`tools/host_gui/**`, docs). No chip-side file touched.

**Why:** the protocol fuzzer (`tools/host_gui/fuzz_protocol.py`) stops at the
wire — both frame decoders and the chip-side model. Nothing attacked the layer
the GUI actually talks to: the FastAPI routes, the `ControllerSession` state
machine, a hostile/broken bridge, or concurrent requests. And no test watched
the process footprint over time — the demo machine has a history of Python
processes OOM-killing everything around them, so a leak in the bridge/session
path would repeat that failure live.

**Result:** one new fuzzer (`fuzz_server.py`) and one soak runner
(`soak_host.py`), both seeded and bounded, both wired into the one-command host
gate. The fuzzer's first RED run found **two real host defects**, both fixed
and pinned. The soak verdict is recorded at the end of this document.

---

## 1. The server/API fuzzer

`tools/host_gui/fuzz_server.py` — seeded, reproducible, bounded; the seed and
the reproducing case are printed with every finding. Five campaigns:

| Campaign | Attacks | Invariant that must hold |
|---|---|---|
| `state_sequences` | random op sequences (connect/load/start/stop/status/read/dump/read_imem/read_dmem/clear_fault/negotiate/process_events/sources/health/disconnect) on a fresh stack | refusals are typed (`ApiError`/`SessionError`), postconditions hold, the state is never left `LOADING`, request ids are 1..N per connection |
| `hostile_bridge` | garbage lines, dropped replies, wrong ids, `ok=false`, oversize lines, bad protocol version — with FakeClock so a timeout is instant | every fault is a typed failure; after the bridge heals the session completes load/status/dump again |
| `http` | hostile bodies (empty/null/int/list/dict/NUL/traversal/absolute/1 MB name/extra junk/valid), raw garbage/1 MB content, wrong-state and interleaved sequences through the real FastAPI app (`raise_server_exceptions=False`) | every response < 500, health stays alive, a clean connect→load→start→status→stop→dump still succeeds |
| `concurrency` | 8-12 threads released by a barrier, plus a websocket-style `process_events` poller spinning while requests fly; `sys.setswitchinterval(1e-6)` forces the interleave instead of hoping for it | concurrent legal requests on a healthy bridge never fail (no crossed/stolen replies); mixed mutating ops raise only typed errors; the stack recovers |
| `reconnect_storm` | rapid connect/status/disconnect cycles (double-disconnect included) | request ids restart at 1 per connection and stay consecutive, `session_id` counts connections, a full cycle works after the storm |

## 2. RED — what the first run found (seed 20260926)

Reproduce against the parent commit `5b63029`:

```bash
git checkout 5b63029
python3 -m tools.host_gui.fuzz_server -n 60 --rounds 6
# RESULT: FAIL (28 findings)   [saved log: /tmp/fuzz_server_red.txt]
```

| Finding kind | Count | What it means |
|---|---|---|
| `state/stuck-loading` | 10 | a transport failure mid-`load` left the session in `LOADING`; every later load was refused (`load requires a stopped session (state is LOADING)`) until a reconnect |
| `recovery/after-hostile` | 10 | the same brick, seen from the recovery invariant: with the bridge healed, the session still could not load |
| `concurrency/unserialized` | 8 | two requests read each other's replies (`response id 7 does not match request id 10`) or a concurrent poller consumed a just-written reply (status timed out on a healthy bridge) |

Both are real, not fuzzer artifacts:

1. **Stuck LOADING.** Any `SessionError` raised by `_request` during `load`
   (protocol error, bridge `ok=false`, wrong id, closed port) propagated without
   restoring the state, so the state machine was bricked on a live connection.
   A timeout was different: it intentionally latches `FAULTED`.
2. **Unserialized wire.** FastAPI runs sync handlers in a threadpool and the
   page polls STATUS/READ_CPU on timers while user actions run, so the session
   and transport ARE used from several threads. Two requests could interleave
   between `write` and `readline` and consume each other's reply; `poll_events`
   could drop a reply it found with no outstanding request. On a real serial
   port the window is far larger than on the loopback (the port's `readline`
   can block up to 50 ms).

## 3. Fixes

`tools/host_gui/session.py`

- `load()` records the previous state and restores it if the failed request
  left the state at `LOADING`; a timeout keeps its sticky `FAULTED`.
- every public operation is wrapped in `_serialized` (an `RLock`), so state
  transitions are atomic (check-then-act races removed). `RLock` because
  `connect()` re-enters through `process_events()`.
- the transport factory takes a structural `TransportLike` Protocol (the
  scripted test doubles were always valid transports; the annotation now says
  so).

`tools/host_gui/transport.py`

- `request`, `poll_events`, `events` and `close` take a per-transport wire
  lock; one request owns the wire at a time, including its event draining.

`tools/host_gui/tests/test_session.py`, `test_transport.py`

- `test_failed_load_does_not_stick_in_loading` (retry succeeds on the same
  connection) and `test_concurrent_requests_never_read_each_others_replies` +
  `test_concurrent_poll_events_does_not_steal_a_response` (8 threads ×
  60 rounds under a 1 µs switch interval) pin the fixes. The timeout path's
  existing `test_load_timeout_is_not_success` pins the intentional `FAULTED`.

## 4. GREEN evidence

```bash
# heavy campaign, FastAPI installed: the HTTP campaign runs too
/tmp/hostgui-venv/bin/python -m tools.host_gui.fuzz_server -n 400 --rounds 60 --threads 12
# RESULT: PASS   (5.3 s)

python3 -m unittest discover -s tools/host_gui/tests     # Ran 251 tests ... OK
python3 -m unittest discover -s tools/host_bridge/tests  # Ran 85 tests ... OK
./tools/host_gui/run_host_tests.sh                       # exit 0, 12 steps
```

Gate wiring: `run_host_tests.sh` runs `fuzz_server -n 120 --rounds 10` and a
300-cycle soak smoke. The suite count went 234 → 251 (13 new tests: 5 fuzzer,
2 transport, 1 session, 5 soak). Committed at `e5280fd` (pushed).

## 5. Soak — RSS watch

`tools/host_gui/soak_host.py` drives, in-process:

- a long-lived `Api`/`ControllerSession`/`SerialTransport` over a `FakeBridge`:
  status/run/read_cpu/stop/dump/read_imem/read_dmem cycles;
- a full image **assembly** through `Api.load` every 500 cycles (the real
  route, ~36 ms each);
- a reconnect every 2000 cycles (fresh transport/bridge);
- a hostile dropped-reply cycle every 500 cycles (typed timeout → clear_fault
  → reload);
- a protocol-fuzz chunk every 250 cycles (both decoders + FakePE);
- the FastAPI routes (`--http`) every 50 cycles;
- **RSS + live GC-object sampling**, verdict from a pure `summarize()`:
  baseline = min RSS of the first quarter (warmup), final = last sample,
  growth beyond 8 MB (or 50 k live objects) is a finding. A run shorter than
  20 s is explicitly `insufficient`, never a pass.

Full run: 22 minutes, seed 20260926, venv interpreter, `--http`:

```
python3 -m tools.host_gui.soak_host --minutes 22 --http \
    --sample-every 1000 --sample-seconds 2 --json /tmp/soak_result.json
```

### Result — bounded (PASS)

```
soak seed=20260926 cycles=1891812 seconds=1320.0
  verdict: bounded  rss 53.71 -> 57.31 MB (+3.596 MB, 9.81 MB/h), objects +511
RESULT: PASS
```

**The raw `summarize` headline is deliberately conservative and slightly
misleading on a run of this length:** its baseline is the *minimum* of the
first quarter (53.71 MB, taken during the interpreter's first seconds) while
the process settles at ~57.1 MB within a few minutes. The truthful shape is in
the series:

| Window | Mean RSS |
|---|---|
| 0–5 min | 57.13 MB |
| 5–10 min | 57.33 MB |
| 10–15 min | 57.41 MB |
| 15–20 min | 57.49 MB |
| 20–22 min | 57.44 MB |

- **Last half** (after warmup): linear slope **0.40 MB/h**, range
  57.31–57.59 MB; last 5 min 57.44 → 57.31 MB (not rising).
- **Independent samples** (shell `/proc/<pid>/status` every 3 min):
  55.88 → 56.02 → 56.03 → 56.03 → 56.10 → 56.16 MB (+280 KB over 15 min
  ≈ 1.1 MB/h).
- **Live GC objects** (after collect): 59,608–60,119 across the run;
  +511 from the minimum — and that residue is dominated by the sample list
  itself (1,893 tuples). No object-growth leak.

No unbounded growth in any signal: this is allocator/cache warmup settling
into a flat band, not a leak. The run drove 1.89 M cycles (~1,433/s) through
the real host path, including ~3,780 assemblies, ~3,780 hostile timeout
cycles, ~7,400 protocol-fuzz chunks and ~37,800 FastAPI route calls.

## 6. Files added/changed (this task; `e5280fd` + the soak-record commit)

| File | Change |
|---|---|
| `tools/host_gui/fuzz_server.py` | new: the server/API fuzzer |
| `tools/host_gui/soak_host.py` | new: the soak runner + RSS/GC verdict |
| `tools/host_gui/tests/test_fuzz_server.py`, `test_soak_host.py` | new: fuzzer/soak suite tests |
| `tools/host_gui/session.py` | load state restore; `_serialized` RLock; `TransportLike` |
| `tools/host_gui/transport.py` | wire lock on request/poll_events/events/close |
| `tools/host_gui/tests/test_session.py`, `test_transport.py` | regression pins for both fixes |
| `tools/host_gui/run_host_tests.sh` | server-fuzz + soak-smoke gate steps |
| `README.md`, `docs/demo-walkthrough.md`, `docs/submission-readiness.md`, `HANDOFF.md`, `wiki/STATUS.md` | counts and status |

## 7. Limits / not-claims

- Everything here runs against fakes/loopback in-process. It is host-side
  robustness evidence, **not** evidence about silicon or the real Pico/USB
  link; the board-in-the-loop acceptance remains hardware-gated.
- The concurrency campaign forces thread switches to make a race reproducible;
  the pre-fix failure rate was ~2-4%, so it is a stress test, not a realistic
  traffic generator.
- The soak watches this process's footprint; it cannot see a leak in the
  MicroPython bridge (a different interpreter) or in the chip.
- The fuzzer asserts host contracts only. A misdecode that both host and bridge
  share would need the chip-side wait-word cross-check (`run_all` gate) to
  surface.
