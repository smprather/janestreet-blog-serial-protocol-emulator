# MicroPython verification of the deployed bridge (2026-09-25)

**Scope:** manager dispatch — the recorded limit "MicroPython deployment
unverified" is unblocked. The three files that ship to the Pico filesystem
(`tools/host_bridge/main.py`, `pe_frame.py`, `tt_adapter.py`) were verified
against a **real MicroPython**, not by inspection. No chip-side file was
touched; this is host-side.

## How it was verified

A MicroPython unix port was built and the bridge modules were run on it with
the same harness that runs on CPython, so the two interpreters are compared
directly:

```bash
git clone --depth 1 https://github.com/micropython/micropython /tmp/micropython-src
cd /tmp/micropython-src && git submodule update --init --recursive --depth 1
make -C ports/unix -j8                 # exit 0
make -C mpy-cross                      # exit 0
# MicroPython unix port, commit 09f5bb4 (2026-08-20), version 1.30.0-preview

python3 tools/host_bridge/micropython_check.py                          # CPython: PASS
/tmp/micropython-src/ports/unix/build-standard/micropython \
    tools/host_bridge/micropython_check.py                              # MicroPython: PASS
mpy-cross -o /tmp/main.mpy tools/host_bridge/main.py                    # precompile all three
```

`tools/host_bridge/micropython_check.py` is the harness (new, in the repo, so
this is repeatable). It exercises the frame codec against the shared golden
vectors, the full bridge sequence (hello/prepare/1024-word load/start/read/
stop/range/clear/dump), the sticky-fault lifecycle, the board-failure paths,
and the adapter guards — on both interpreters. `run_host_tests.sh` runs it
automatically when a `micropython` binary is on `PATH` (skips with a note
otherwise).

## What FAILED on MicroPython (and was fixed in the host repo)

Five deployment-blocking issues, all found by running the real interpreter:

1. **`from __future__ import annotations` — `ImportError: no module named
   '__future__'`.** MicroPython has no `__future__` module, so *neither
   `main.py` nor `tt_adapter.py` would have imported on a Pico at all.*
   Removed from both. (`acceptance.py` keeps it — it is host-side only, never
   deployed.)
2. **Starred unpacking in a list display — `SyntaxError: *x must be
   assignment target`.** `main.py` had `return [*self.drain_events(),
   response.to_message()]`. MicroPython's parser rejects it. Rebuilt with
   `messages = ...; messages.append(...); return messages`.
3. **Keyword-only parameters — `TypeError: function missing 2 required
   positional arguments`.** `def __init__(self, adapter, *, project=None,
   ...)` (and the same in `tt_adapter.py`, which also used a `dict | None`
   annotation that MicroPython evaluates at def time). The `*,` markers and
   the PEP 604 union were removed; callers still pass by name.
4. **`collections.deque()` — `TypeError: function missing 2 required
   positional arguments`.** MicroPython's `deque` has no zero-argument form
   (it is `deque(iterable, maxlen)`), and it has **no `.clear()`**. Fixed
   with a bounded `deque([], 16)` (which also caps event memory on a 264 KB
   device) and a popleft-until-empty drain.
5. **RAM: `DEFAULT_MAX_LINE=65536` was a 16x over-permission on a 264 KB
   Pico.** The bridge parses each request line whole. Measured: the largest
   legal request (a full 1024-word LOAD) is **4,142 bytes** and its
   `json.loads` costs **~8.4 KB** of MicroPython heap; a full 1024-word LOAD
   through the bridge costs **69,408 bytes** of heap on the unix port. The
   bound is now **8,192** — every legal request fits with ~2x margin, and a
   pathological line is rejected before it is parsed. The harness asserts
   both the fit and the rejection.

## After the fixes

- Both interpreters: `RESULT: PASS` (identical checks).
- `mpy-cross` compiles all three modules; the precompiled `.mpy` files import
  and run under MicroPython (CRC check `0x29B1`).
- Module sizes for the RP2040 filesystem: `main.py` 19,845 B, `pe_frame.py`
  3,871 B, `tt_adapter.py` 5,921 B (29,637 B source; 10,015 B precompiled as
  `.mpy`). All three are one MicroPython module set; `pe_frame.py` needed no
  changes.
- `run_host_tests.sh`: exit 0 with and without a `micropython` on `PATH`.

## What is still unverified (honest limits)

- The heap figures are from the **unix** port's allocator. RP2040's 264 KB
  SRAM also holds the USB stack and the TT SDK, so the real headroom is
  smaller and must be re-measured on hardware (`gc.mem_free()` in the REPL).
- `machine.SPI` pin mapping, the ttboard v3 SDK on-device, and USB CDC
  behavior are not exercised by the unix port — they are the subject of the
  bring-up runbook.
- The IRQ input is still `None` until RTL phase R1 (`irq_n` guard verified).

Related: `HOST-GUI-PHASE2-BRIDGE.md` (this closes its "MicroPython deployment
unverified" limit), the runbook, and the demo walkthrough.
