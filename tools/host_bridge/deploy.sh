#!/usr/bin/env bash
# deploy.sh — install the Pico bridge onto the board's MicroPython filesystem.
#
# Usage:
#   tools/host_bridge/deploy.sh                       # copy to the default mount
#   tools/host_bridge/deploy.sh /media/$USER/RPI-RP2  # copy to a named mount
#   tools/host_bridge/deploy.sh --dry-run             # print the plan, copy nothing
#   tools/host_bridge/deploy.sh --mpy                 # also precompile to .mpy
#
# Exit: 0 = installed (or dry run clean), 1 = refused or failed.
#
# WHAT IT INSTALLS, AND WHY ONLY THESE THREE
#
# main.py       the USB CDC line-protocol endpoint and the framed SPI sequencing
# pe_frame.py   the MicroPython frame codec (imported flat by main.py)
# tt_adapter.py the Tiny Tapeout SDK adapter (project, clock, reset, run, SPI)
#
# Those are the only three files the bridge needs at runtime, and they import
# each other flat, exactly as they sit in this directory. Nothing else from
# the repo goes on the board: the host-side modules (protocol, image,
# transport, session, server, acceptance) must stay on the Linux host, because
# they use CPython features MicroPython does not have.
#
# The script is deliberately conservative: it only ever writes the three files
# above, prints a size/hash manifest either way, and refuses to run at all if
# the target does not look like a mounted MicroPython drive.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES=(main.py pe_frame.py tt_adapter.py)
DEFAULT_TARGET="/media/${USER}/RPI-RP2"
TARGET="$DEFAULT_TARGET"
DRY_RUN=0
WANT_MPY=0

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --mpy) WANT_MPY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
        *) TARGET="$1"; shift ;;
    esac
done

printf '=== host bridge deploy ===\n'
printf 'source : %s\n' "$HERE"
printf 'target : %s\n' "$TARGET"

# 1. sanity: all three modules must exist and parse before anything is copied.
missing=0
for module in "${MODULES[@]}"; do
    if [ ! -f "$HERE/$module" ]; then
        printf 'missing source module: %s\n' "$HERE/$module" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || { echo "refusing to deploy an incomplete bridge" >&2; exit 1; }
python3 -c "import ast,sys
for name in sys.argv[1:]:
    ast.parse(open(name).read(), name)
print('syntax: all three modules parse')" "$HERE/main.py" "$HERE/pe_frame.py" \
    "$HERE/tt_adapter.py"

# 2. size + hash manifest (printed even for a dry run: it is the evidence a
#    bring-up note needs).
printf '\n--- payload ---\n'
total=0
for module in "${MODULES[@]}"; do
    size=$(stat -c%s "$HERE/$module")
    total=$((total + size))
    hash=$(sha256sum "$HERE/$module" | cut -c1-16)
    printf '%-13s %6d B  sha256:%s\n' "$module" "$size" "$hash"
done
printf '%-13s %6d B  (RP2040 filesystem: ample; the RAM limit is heap, not flash)\n' \
    "total" "$total"

if [ "$WANT_MPY" -eq 1 ]; then
    if command -v mpy-cross >/dev/null 2>&1; then
        for module in "${MODULES[@]}"; do
            mpy-cross -o "$HERE/${module%.py}.mpy" "$HERE/$module"
            printf 'precompiled %-9s %6d B\n' "${module%.py}.mpy" \
                "$(stat -c%s "$HERE/${module%.py}.mpy")"
        done
    else
        echo "mpy-cross not found: install it from a MicroPython checkout" >&2
        exit 1
    fi
fi

# 3. refuse to write to something that is not a board filesystem.
if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n[dry run] nothing written.\n'
    exit 0
fi
if [ ! -d "$TARGET" ]; then
    echo "target $TARGET does not exist." >&2
    echo "Plug the board in with BOOTSEL held, mount it, and re-run." >&2
    exit 1
fi
if [ ! -w "$TARGET" ]; then
    echo "target $TARGET is not writable (is the board mounted read-only?)" >&2
    exit 1
fi
if [ ! -e "$TARGET/boot.py" ] && [ ! -e "$TARGET/main.py" ] \
   && [ ! -e "$TARGET/RPI-RP2.WFINFO" ] && [ ! -e "$TARGET/INFO_UF2.TXT" ]; then
    echo "target $TARGET does not look like a MicroPython board filesystem" >&2
    echo "(expected boot.py/main.py, RPI-RP2.WFINFO or INFO_UF2.TXT)" >&2
    exit 1
fi

printf '\n--- installing ---\n'
for module in "${MODULES[@]}"; do
    cp "$HERE/$module" "$TARGET/$module"
    printf 'wrote %s/%s\n' "$TARGET" "$module"
done
[ "$WANT_MPY" -eq 1 ] && for module in "${MODULES[@]}"; do
    cp "$HERE/${module%.py}.mpy" "$TARGET/${module%.py}.mpy"
    printf 'wrote %s/%s\n' "$TARGET" "${module%.py}.mpy"
done
cat <<'NEXT'

=== next steps ===
1. On the board: run the bridge.   import main; main.run()
   (on a stock Pico, rename main.py to boot.py to start it at power-up)
2. On the host, verify the port:  ls -l /dev/ttyACM*
3. Run the real acceptance:      python3 tools/host_bridge/acceptance.py \
                                   --device /dev/ttyACM0 --board <revision>
Full bring-up and failure triage: docs/host-bridge-bringup.md
NEXT
