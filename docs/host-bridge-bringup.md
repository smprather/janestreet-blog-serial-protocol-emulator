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
  readback) are both landed** on the shuttle — R2 passes all 15 golden steps
  byte-exact against this repo's `R2-READ-VERIFICATION.json` package. So a
  healthy run should pass the `r2_*` read checks too; if they go red on real
  hardware, that is a board-level problem to triage, not the expected state.

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
| `r2_read_*` / `r2_dump_header` FAIL, others PASS | the read path is chip-confirmed in simulation but the board disagrees | compare against `R2-READ-VERIFICATION.json`; the 18 read-path steps are the same ones `tb_pe_ctrl_r2` passes (22 in the package, 4 held-core steps still unconfirmed) - a board-only failure points at the MISO read path or wiring, not the contract |
| EVERY op FAILs with `bad PE response: length field does not match the frame` or `CRC mismatch` - including `hello` and `ping`, which use no payload | the host clocks a fixed budget of wait words past the end of every reply (the chip may emit up to 15 filler words before a bounded read), so the words after the frame come off a **released** MISO pad: `pe_ctrl` drives MISO only while a response shifts | the reader trims the buffer to the frame's own length field, so idle words are discarded. If you see this, you are on an older host build without that trim, OR the pad is being driven by something else while idle (a wiring or shuttle problem) - check the MISO row first, then confirm your host has `pe_frame.strip_wait_words` trimming to the length field |
| `irq`/`fault` steps FAIL | the fitted shuttle predates R1's `IRQ_N`, or the adapter was built without `irq_enabled` | check the shuttle revision; `irq_n()` returns `None` (SKIP) when IRQ is unavailable |
| `uart` SKIP | no bridge op reports UART bytes (dropped from this phase by ruling) | revisit at hardware bring-up; not a failure |
| Chip is stopped and will NOT restart, and the run strap looks correct | **a debug hold is asserted** (an R3 breakpoint hit, or a single step paused it). While held, `cpu_exec = dbg_step \|\| (run && !dbg_hold)`, so the strap is ignored in BOTH directions | send `DEBUG_BP_CLR` — it is the **only** release. Pulling the run strap low will NOT recover the chip, and neither will `STOP`; the other escape is a hardware reset. See the note below |
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
