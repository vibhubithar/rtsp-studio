#!/usr/bin/env bash
# Start the RTSP Studio web UI as a background service (no terminal logs).
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<EOF
Usage: $0

Starts the web UI in the background as a user service when systemd is
available, otherwise as a detached process. Logs go to the journal and
$UI_LOG, not this terminal.

Does not start RTSP publishers. Use Start in the web UI (or start.sh).

  $0
  $SCRIPT_DIR/stop-ui.sh
EOF
  exit 0
fi

start_ui_service
print_ui_urls
echo "Start/Stop in the web UI still publishes RTSP from this host."
