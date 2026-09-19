#!/usr/bin/env bash
# canvas-publish — push a diagram to the live-canvas dashboard pane.
#
#   ./canvas-publish.sh file.svg              # copy in (keeps the name)
#   ./canvas-publish.sh - < file.svg          # read stdin
#   ./canvas-publish.sh -n timing.svg - < in   # stdin under a new name
#
# The pane follows the newest file, so a publish is a write into the watched
# directory. Nothing else is needed — no server call, no credentials.
#
# Set CANVAS_DIR to override the destination; defaults to the first root in the
# plugin's canvas_roots.json, or $REPO/diagrams.
set -euo pipefail

PLUGIN_DIR="${HERMES_HOME:-$HOME/.hermes}/plugins/live-canvas"
ROOTS_FILE="$PLUGIN_DIR/canvas_roots.json"

default_dir() {
  if [ -f "$ROOTS_FILE" ]; then
    python3 - "$ROOTS_FILE" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    roots = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if isinstance(roots, list) and roots and isinstance(roots[0], str):
    print(os.path.expanduser(roots[0]))
PY
  fi
}

DEST_DIR="${CANVAS_DIR:-$(default_dir)}"
if [ -z "$DEST_DIR" ]; then
  echo "canvas-publish: no destination (set CANVAS_DIR)" >&2
  exit 2
fi
mkdir -p "$DEST_DIR"

NAME=""
if [ "${1:-}" = "-n" ]; then
  NAME="$2"
  shift 2
fi

SRC="${1:-}"
if [ -z "$SRC" ]; then
  echo "usage: $0 [-n name.svg] <file|->" >&2
  exit 2
fi

if [ "$SRC" = "-" ]; then
  [ -n "$NAME" ] || { echo "canvas-publish: - needs -n <name>" >&2; exit 2; }
  cat > "$DEST_DIR/$NAME"
  OUT="$DEST_DIR/$NAME"
else
  [ -f "$SRC" ] || { echo "canvas-publish: no such file: $SRC" >&2; exit 2; }
  BASE="${NAME:-$(basename "$SRC")}"
  # Stage then rename: the watcher only ever sees a complete file, so the pane
  # never renders a half-written diagram.
  TMP="$DEST_DIR/.$BASE.part"
  cp "$SRC" "$TMP"
  mv -f "$TMP" "$DEST_DIR/$BASE"
  OUT="$DEST_DIR/$BASE"
fi

echo "published: $OUT"
