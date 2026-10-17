#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

STREAMS_ONLY=0
UI_ONLY=0

usage() {
  cat <<EOF
Usage: $0 [--streams|--ui-only]

Stops the web UI and every ffmpeg/MediaMTX publisher started by start.sh.

  --streams   leave the web UI running; only stop RTSP publishers
              (this is what Stop in the browser uses)
  --ui-only   leave RTSP streams running; only stop the web UI
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --streams|--publishers)
      STREAMS_ONLY=1
      shift
      ;;
    --ui-only)
      UI_ONLY=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$STREAMS_ONLY" = 1 ] && [ "$UI_ONLY" = 1 ]; then
  echo "Use only one of --streams or --ui-only." >&2
  exit 1
fi

# The web Stop button must never tear down ui.py. Older UI processes called
# this script with no flags; detect that and keep the UI up.
invoked_by_ui() {
  local args=""
  args=$(ps -o args= -p "${PPID:-0}" 2>/dev/null || true)
  case "$args" in
    *ui.py*) return 0 ;;
  esac
  return 1
}

if [ "$UI_ONLY" != 1 ] && invoked_by_ui; then
  STREAMS_ONLY=1
fi

if [ "$UI_ONLY" != 1 ]; then
  stop_all_streams
fi
if [ "$STREAMS_ONLY" != 1 ]; then
  stop_ui_service
fi
