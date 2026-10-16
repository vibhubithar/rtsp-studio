#!/usr/bin/env bash
# Stop the RTSP Studio web UI and any RTSP publishers it started.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

UI_ONLY=0

usage() {
  cat <<EOF
Usage: $0 [--ui-only]

Stops the web UI service (or background process) started by start-ui.sh
/ install.sh. Also stops MediaMTX and ffmpeg publishers, so one command
tears down the studio.

  --ui-only   leave RTSP streams running; only stop the web UI
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
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

if [ "$UI_ONLY" != 1 ]; then
  stop_all_streams
fi
stop_ui_service
