# Host bridge bring-up and the real acceptance run

Operator runbook for putting the Pico bridge on a Tiny Tapeout demo board and
running the first real acceptance. Everything here is host-side setup; the
bridge source is `tools/host_bridge/{main,pe_frame,tt_adapter}.py` and the
runner is `tools/host_bridge/acceptance.py`.

Read this with `reviews/2026-09-25/HOST-BRIDGE-MICROPYTHON.md` (what was
verified on a real MicroPython) and the triage table at the bottom.

## 0. What you need

- Tiny Tapeout demo board with the PE shuttle fitted, USB cable.
- A Linux host with Python 3.12+ and the host extra:
  `pip install .[host-gui]` (adds `pyserial`, plus the GUI's fastapi/uvicorn).
- Chip R1 (framed host bus, `IRQ_N`, target 1) and **R2 (register/memory
  readback) are both landed** on the shuttle. R2's golden package has **22
  steps, all 22 chip-confirmed byte-exact** against this repo's
  `R2-READ-VERIFICATION.json` — including the four that read back while the
  core is HELD at a breakpoint (`R2-HELD-STATUS-BYTES.md`; the chip's re-run
  that confirmed them is `R2-HELD-CORE-CHIP-SIDE.md` §7 in the chip repo). So a
  healthy run should pass the `r2_*` read
  checks; if they go red on real hardware, that is a board-level problem to
  triage, not the expected state.

### RESOLVED — the bridge's missing wait-word skip (B1): history, not a warning

R2 reads answer **late by design**: a bounded read cannot return inside the
request's own bit times, so the chip drives `0xFFFF` filler words on MISO while
it fetches and the real frame starts at the first non-`0xFFFF` word (worst
case 15 filler words; contract in `rtl/pe_ctrl.v`'s header).

The bridge originally did a single fixed-length `write_readinto` with no skip,
which would have made every `READ_IMEM`/`READ_DMEM` fail on silicon while
`--fake` stayed green. **That defect is FIXED** (gui-worker 059d6c3, merged
def51ea): `pe_frame.strip_wait_words()` (leading-only, bounded at 15, raises on
an all-filler stream), `tt_adapter.host_spi_transfer(data, read_words)` for a
variable-length read that keeps clocking, and per-opcode read sizing in
`main._pe_request`. The regression covers a response longer than the request,
2- and 15-wait-word reads end to end, a `0xFFFF` **payload** surviving
(leading-only), and an all-filler stream as a typed timeout. Full record:
`reviews/2026-09-25/HOST-CODE-REVIEW.md` finding B1.

Consequence for you: **an `r2_read_*` failure is a genuine finding again** —
wiring, MISO, or SPI timing. Do not pre-empt it with the old explanation.

## 1. Flash and mount the board

1. Hold **BOOTSEL**, plug the board in, release. It mounts as
   `/media/$USER/RPI-RP2` (Linux) with `boot.py` (or `INFO_UF2.TXT`).
2. Install the Tiny Tapeout MicroPython firmware (the RP2040/RP2350 build
   matching your board revision) if the board is not already on it. The
   bridge imports `ttboard` and `machine`; both come from that firmware.
3. Optional: set the board to run the bridge at power-up by renaming
   `main.py` to `boot.py` after deploying (see step 2).

## 2. Deploy the bridge

```bash
tools/host_bridge/deploy.sh --dry-run          # manifest: sizes + sha256, no writes
tools/host_bridge/deploy.sh                    # copies the three modules
# or precompile first (smaller/faster to load):
tools/host_bridge/deploy.sh --mpy
```

It installs exactly three files — `main.py`, `pe_frame.py`, `tt_adapter.py` —
and refuses to write to anything that does not look like a MicroPython board
filesystem. The host-side modules (protocol, transport, session, server,
acceptance) stay on the Linux host; they use CPython features MicroPython
lacks. Current payload: ~29.6 KB source, ~10 KB precompiled.

Start it on the board (REPL or `boot.py`):

```python
import main
main.run(project="tt_um_protocol_emulator")
```

The bridge then selects the shuttle, starts the 60 MHz project clock (and
never stops it while connected), and waits for USB CDC lines.

## 3. Host permissions

The CDC device is typically `root:dialout`:

```bash
ls -l /dev/ttyACM*          # expect crw-rw---- 1 root dialout ... /dev/ttyACM0
sudo usermod -aG dialout $USER   # then log out and back in
```

If your distribution uses `plugdev` instead, use that group. A udev rule is
the alternative if you do not want group membership:

```bash
# /etc/udev/rules.d/99-tinyusb-cdc.rules  (adjust ATTRS{idVendor} if needed)
SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", MODE="0660", GROUP="dialout"
sudo udevadm control --reload-rules && sudo udevadm trigger
```

## 4. Run the real acceptance

```bash
python3 tools/host_bridge/acceptance.py --device /dev/ttyACM0 --board <revision>
```

The runner opens the port, sends the same scripted sequence the `--fake` dry
run performs (hello → project select → 60 MHz → reset → host SPI → assemble
`firmware/uart_echo.pe` → load → readback → start → status/heartbeat → stop →
register dump → **debug act** → IRQ/fault/clear → disconnect → reconnect) and
prints per-step `PASS`/`FAIL`/`SKIP` plus a manifest (clock, SCLK cap, pads,
image digest, word count). It exits non-zero if any step is `FAIL`.

The **debug act** is the R3 group — arm a breakpoint over the host bus, run
into it, read the core back while it is held, step across, clear, resume. It
runs on the board like every other step: the act waits for the core to reach
the armed address (a real core advances on its own — only the `--fake` model
has to be clocked), so expect roughly a dozen `r3_demo_*` and `r3_*` lines
here. It needs **R3** (the debug opcodes `0x21`–`0x24`) on the shuttle; on an
earlier one those lines report `UNSUPPORTED` and the panel says so.

What a healthy run looks like: with R1 and R2 on the shuttle every step
passes, plus the standing `uart` SKIP (no bridge op reports UART bytes -
dropped from this phase by ruling). Add R3 and the debug-act lines pass too;
without R3 they are the one group that will not. Read the triage table before
assuming a problem.

## 5. Failure triage

| Symptom (what you see) | Cause | Fix |
| --- | --- | --- |
| `FAIL open pyserial is required ...` | host extra not installed | `pip install .[host-gui]` |
| `FAIL open cannot open /dev/ttyACM0: Permission denied` + dialout hint | user not in `dialout`/`plugdev` | `sudo usermod -aG dialout $USER`, re-login; or the udev rule above |
| `FAIL open cannot open ... No such file or directory` | board not enumerated / wrong port | `ls /dev/ttyACM*`; try `--device` with the real path; check the cable and that the bridge is running |
| `FAIL open` with no response, then every step FAIL | bridge not running on the board | REPL: `import main; main.run()`; check for a Python traceback in the board REPL |
| `FAIL hello` / `board error during hello: project ... not found` | shuttle name wrong for this board | pass `--project <name>` matching the fitted shuttle; confirm in the board REPL with the TT SDK |
| `FAIL sclk` / `board error during prepare: host SPI pin map is not configured` | no `pins` map supplied | `tt_adapter.TTAdapter` needs `pins={sck,mosi,miso}` for your board revision (RP2040 vs RP2350 GPIO numbers differ) — plan Open Item 2 |
| `spi.timeout` on load / every SPI step | CS/SCK/MOSI/MISO not wired, or a shuttle without the framed protocol | check the lower PMOD host-SPI row wiring; confirm the fitted shuttle has R1 |
| `r2_read_*` / `r2_dump_header` FAIL, others PASS | the read path is chip-confirmed in simulation but the board disagrees | compare against `R2-READ-VERIFICATION.json`; all 22 steps in the package are the same ones `tb_pe_ctrl_r2` passes byte-exact (18 read-path + 4 held-core, all confirmed) - a board-only failure points at the MISO read path or wiring, not the contract |
| EVERY op FAILs with `bad PE response: length field does not match the frame` or `CRC mismatch` - including `hello` and `ping`, which use no payload | the host clocks a fixed budget of wait words past the end of every reply (the chip may emit up to 15 filler words before a bounded read), so the words after the frame come off a **released** MISO pad: `pe_ctrl` drives MISO only while a response shifts | the reader trims the buffer to the frame's own length field, so idle words are discarded. If you see this, you are on an older host build without that trim, OR the pad is being driven by something else while idle (a wiring or shuttle problem) - check the MISO row first, then confirm your host has `pe_frame.strip_wait_words` trimming to the length field |
| `irq`/`fault` steps FAIL | the fitted shuttle predates R1's `IRQ_N`, or the adapter was built without `irq_enabled` | check the shuttle revision; `irq_n()` returns `None` (SKIP) when IRQ is unavailable |
| `heartbeat` FAIL / `timer stuck at N` | the chip's `dbg_timer` did not move within the beat's window (3 tries x 0.25 s, so about **0.75 s**) | the one beat the `--fake` dry run cannot rehearse: there the model scripts the increment, so it can only fail on hardware. In order of likelihood: the core is not actually running (the `start` beat passed, so check the strap reached the shuttle), the SoC tick never reaches `dbg_timer` on this shuttle, or the readback path is returning a stale header. Re-run with `--fake` to confirm the host side is sound, then read `status` twice by hand in the board REPL |
| `readback` FAIL (image does not match the manifest) | the words in the chip's instruction memory are not the words that were assembled — a load-path problem, even though the `load` beat itself passed | compare the `sha256` in the run's manifest with `python3 -m tools.host_gui.image` over the same source, and check the lower PMOD SPI row for the shuttle fitted |
| `clear_fault` FAIL (faults still set) | `CLEAR_FAULT` did not clear the sticky register — the fault is STILL latched on the chip | a chip-level symptom, not a host one: the host sent the frame and read the register back. Note it before resetting, because a reset clears the register and the evidence with it |
| `uart` SKIP | no bridge op reports UART bytes (dropped from this phase by ruling) | revisit at hardware bring-up; not a failure |
| Chip is stopped and will NOT restart, and the run strap looks correct | **a debug hold is asserted** (an R3 breakpoint hit, or a single step paused it). While held, `cpu_exec = dbg_step \|\| (run && !dbg_hold)`, so the strap is ignored in BOTH directions | send `DEBUG_BP_CLR` — it is the **only** release. Pulling the run strap low will NOT recover the chip, and neither will `STOP`; the other escape is a hardware reset. See the note below |
| A breakpoint reads ARMED and the core then never stops at it | the arm was made while the core was **already held**, and you then **ran** instead of stepping: the free-running hit is gated on the hold being clear (`pe_ctrl.v:692`) while the step path is not (`:1067`), so a held core can never run into an armed address — and the chip answered `OK` to the arm, so nothing on the wire says otherwise | **step** onto the armed address (that is what latches the hit — state 2 becomes 3), and remember `DEBUG_BP_CLR` disarms as it releases, so an arm does not survive a clear. To continue *with* the breakpoint armed, use the GUI's **Continue (keep bp)**; the session warns on this exact case |
| A step hangs then times out | the Pico read loop is blocked and a request never got answered | Ctrl-C the runner; check the board REPL for a traceback; the host never fabricates a success on timeout |

### If the chip will not restart: the run strap is not the answer

Once R3 debug control is in play, a core can be sitting in a **debug hold** —
latched by a breakpoint hit, or paused by a single step. While held, the
execute gate is `cpu_exec = dbg_step || (run && !dbg_hold)`, which masks the
run strap in **both** directions. So the two reflexes that work for every other
stalled state do **not** work here:

- pulling `run` low will not stop it, because it is already stopped;
- and it will not start it either, because a held core ignores the strap.

**The only release is `DEBUG_BP_CLR`**, which disarms the breakpoint, clears the
hit and drops the hold — with the strap high the core resumes, and with the
strap low it falls to the normal boot stop and the PC re-zeroes. A hardware
reset is the other escape, since reset clears the hold.

This is not a corner case for us: the host's own acceptance demo
(`r3_demo_6_clear_releases`) depends on exactly this release, and an operator
whose GUI died mid-debug will come back to a chip that looks powered and
configured but will not run until they clear the breakpoint.

### The other half of the same trap: an arm made on a held core is step-only

Clearing is the only *release*, and `DEBUG_BP_SET` is not one — it clears the
armed and hit bits and leaves the hold asserted (`pe_ctrl.v:1086-1087`). The two
hit paths then differ in a way that decides whether your breakpoint works:

- **free-running** — `bp_en && !dbg_hold_r && (run || dbg_step_r) && dbg_next_pc
  == bp_addr` (`pe_ctrl.v:692`). Gated on the hold being **clear**, so a core
  that is already held can never run into an armed address.
- **step** — `bp_hit <= bp_en && (dbg_next_pc == bp_addr)` (`pe_ctrl.v:1067`).
  **Not** gated on the hold, so stepping onto an armed address from a held core
  does latch the hit, taking state 2 to 3. This is the stop-before flow the R2
  held-core steps 21/22 exist to pin, and the acceptance act uses it.

So arming a held core is legal — but it is **step-only**. Arm it, then start or
continue, and you get a breakpoint that reports ARMED and can never fire, with
no error anywhere: the chip answered `OK` to the arm. Step onto the address
instead. And an arm does not survive a release at all, because `DEBUG_BP_CLR`
disarms as it releases, so the order that ends armed is always **step → clear →
re-arm** — the GUI's **Continue (keep bp)** button and the session's
`resume_with_breakpoint()` do exactly that.

The host does not leave the trap silent: `session.bp_set()` raises a
`UserWarning` naming the step-only rule and the recovery whenever the core is
held, and the acceptance run's own arm-then-step beats are what proved the rule
is a warning and not a refusal — a first attempt refused the arm outright and
turned two PASSing acceptance beats red.

The host runner **never reports a timed-out or unacknowledged operation as
success** — a `FAIL` means the real thing failed, so read the `error` string
in the report before retrying.

## 7. Running the host gate (and the optional MicroPython step)

`tools/host_gui/run_host_tests.sh` is the one-command host gate and needs
nothing but `python3` (it skips cleanly when `ruff` or `micropython` are
absent). Its MicroPython-conformance step runs the deployed bridge modules on a
real interpreter, which is worth doing before you trust the Pico firmware. To
enable it, build the unix port from a MicroPython checkout (`git clone
https://github.com/micropython/micropython && make -C ports/unix`) and then
either put the binary on `PATH` or point the gate at it:

```bash
MICROPYTHON=/path/to/ports/unix/build-standard/micropython \
    tools/host_gui/run_host_tests.sh
```

**The API-layer tests need the extra.** The server's route, error-mapping and
event-stream tests are driven through starlette's `TestClient`, so they only run
when `.[host-gui]` is installed — including `httpx2`, which that client imports
and which the extra did not declare until 2026-09-25. Without the extra the
suite still reports `OK`, with those tests **skipped**: a green run that never
executed the API layer reads exactly like one that did, so check the skip count
(2 with the extra, 3 without) rather than the word PASS. Run under
`PATH="$PWD/.venv/bin:$PATH"` if you keep the extra in a repo-local venv.

A build is a local artifact at an arbitrary path, so the variable is opt-in and
the default is unchanged. Worth doing explicitly rather than relying on `PATH`:
a step that only runs when someone happens to have the interpreter installed is
a step that mostly does not run, and "skipped" reads the same as "passed" in a
scroll-back.

## 8. After a green run

- The acceptance output is the bring-up record: keep the board revision, the
  clock/SCLK values, the image digest and word count, and the observed
  statuses. Paste them into the run record alongside this runbook.
- Re-verify the host side any time with `tools/host_gui/run_host_tests.sh`
  (no board needed).
