#!/bin/bash
# Shared paths and stop logic for start.sh / stop.sh.

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT/.rtsp-state}"
PID_FILE="${PID_FILE:-$STATE_DIR/pids}"
LOG_DIR="${LOG_DIR:-$STATE_DIR/logs}"

if [ -z "${MEDIAMTX_DIR:-}" ]; then
  if [ -x "$ROOT/vendor/mediamtx/mediamtx" ]; then
    MEDIAMTX_DIR="$ROOT/vendor/mediamtx"
  elif [ -x "${HOME}/Downloads/mediamtx_v1.13.1_linux_amd64/mediamtx" ]; then
    MEDIAMTX_DIR="${HOME}/Downloads/mediamtx_v1.13.1_linux_amd64"
  else
    MEDIAMTX_DIR="$ROOT/vendor/mediamtx"
  fi
fi
MEDIAMTX_BIN="${MEDIAMTX_BIN:-$MEDIAMTX_DIR/mediamtx}"
MEDIAMTX_CONF="${MEDIAMTX_CONF:-$ROOT/mediamtx.yml}"
RTSP_PORT="${RTSP_PORT:-8554}"
RTSP_BIND="${RTSP_BIND:-127.0.0.1}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

pid_alive() {
  local pid="${1:-}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

signal_pid() {
  local sig="$1"
  local pid="$2"
  if pid_alive "$pid"; then
    kill "-$sig" -- "-$pid" 2>/dev/null || kill "-$sig" "$pid" 2>/dev/null || true
  fi
}

wait_for_exit() {
  local pid="$1"
  local attempts="${2:-20}"
  local i=0
  while pid_alive "$pid" && [ "$i" -lt "$attempts" ]; do
    sleep 0.25
    i=$((i + 1))
  done
  ! pid_alive "$pid"
}

# Stop every process recorded in the PID file (ffmpeg first, then MediaMTX).
stop_all_streams() {
  local quiet="${1:-}"
  local kind pid rest
  local ffmpeg_pids=()
  local mediamtx_pids=()

  if [ ! -s "$PID_FILE" ]; then
    [ "$quiet" = quiet ] || echo "No streams running."
    return 0
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    read -r kind pid rest <<<"$line" || true
    case "$kind" in
      ffmpeg) ffmpeg_pids+=("$pid") ;;
      mediamtx) mediamtx_pids+=("$pid") ;;
    esac
  done < "$PID_FILE"

  local pid
  for pid in "${ffmpeg_pids[@]}" "${mediamtx_pids[@]}"; do
    if pid_alive "$pid"; then
      [ "$quiet" = quiet ] || echo "Stopping PID $pid"
      signal_pid TERM "$pid"
    else
      [ "$quiet" = quiet ] || echo "PID $pid already gone"
    fi
  done

  for pid in "${ffmpeg_pids[@]}" "${mediamtx_pids[@]}"; do
    wait_for_exit "$pid" 20 || signal_pid KILL "$pid"
  done

  : > "$PID_FILE"
  [ "$quiet" = quiet ] || echo "All recorded streams stopped."
}
