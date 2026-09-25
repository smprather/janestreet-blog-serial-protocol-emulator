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
- The chip-side RTL phases **R1 and R2 must be on the shuttle** for the read
  and IRQ steps to pass. R1 (the framed host bus, `IRQ_N`, target 1) has
  landed on `main`; R2 (register/memory readback) has not. Before R2, the run
  stops at the load/status steps and the `r2_*` checks report red — that is
  the gate working, not a bug.

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
register dump → IRQ/fault/clear → disconnect → reconnect) and prints
per-step `PASS`/`FAIL`/`SKIP` plus a manifest (clock, SCLK cap, pads, image
digest, word count). It exits non-zero if any step is `FAIL`.

What a healthy pre-R2 run looks like: with R1 on the shuttle, the
load/status/readback/stop/dump steps pass against the framed bus, while the
`r2_*` register/memory-read checks are expected to be red until R2 lands, and
the `uart` step is a standing SKIP. Read the triage table before assuming a
problem.

## 5. Failure triage

| Symptom (what you see) | Cause | Fix |
|---|---|---|
| `FAIL open pyserial is required ...` | host extra not installed | `pip install .[host-gui]` |
| `FAIL open cannot open /dev/ttyACM0: Permission denied` + dialout hint | user not in `dialout`/`plugdev` | `sudo usermod -aG dialout $USER`, re-login; or the udev rule above |
| `FAIL open cannot open ... No such file or directory` | board not enumerated / wrong port | `ls /dev/ttyACM*`; try `--device` with the real path; check the cable and that the bridge is running |
| `FAIL open` with no response, then every step FAIL | bridge not running on the board | REPL: `import main; main.run()`; check for a Python traceback in the board REPL |
| `FAIL hello` / `board error during hello: project ... not found` | shuttle name wrong for this board | pass `--project <name>` matching the fitted shuttle; confirm in the board REPL with the TT SDK |
| `FAIL sclk` / `board error during prepare: host SPI pin map is not configured` | no `pins` map supplied | `tt_adapter.TTAdapter` needs `pins={sck,mosi,miso}` for your board revision (RP2040 vs RP2350 GPIO numbers differ) — plan Open Item 2 |
| `spi.timeout` on load / every SPI step | CS/SCK/MOSI/MISO not wired, or a shuttle without the framed protocol | check the lower PMOD host-SPI row wiring; confirm the fitted shuttle has R1 |
| `r2_read_*` / `r2_dump_header` FAIL, others PASS | R2 read path not on the shuttle yet | expected pre-R2; the checks are the R2 gate (see `R2-READ-VERIFICATION.md`) |
| `irq`/`fault` steps FAIL | the shuttle lacks R1's `IRQ_N`, or `irq_enabled` was not set | expected on a pre-R1 shuttle; the adapter returns `None` for IRQ until then |
| `uart` SKIP | no bridge op reports UART bytes (dropped from this phase by ruling) | revisit at hardware bring-up; not a failure |
| A step hangs then times out | the Pico read loop is blocked and a request never got answered | Ctrl-C the runner; check the board REPL for a traceback; the host never fabricates a success on timeout |

The host runner **never reports a timed-out or unacknowledged operation as
success** — a `FAIL` means the real thing failed, so read the `error` string
in the report before retrying.

## 6. After a green run

- The acceptance output is the bring-up record: keep the board revision, the
  clock/SCLK values, the image digest and word count, and the observed
  statuses. Paste them into the run record alongside this runbook.
- Re-verify the host side any time with `tools/host_gui/run_host_tests.sh`
  (no board needed).
