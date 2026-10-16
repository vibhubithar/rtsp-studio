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

UI_PORT="${UI_PORT:-8787}"
UI_HOST="${UI_HOST:-0.0.0.0}"
UI_PID_FILE="${UI_PID_FILE:-$STATE_DIR/ui.pid}"
UI_LOG="${UI_LOG:-$LOG_DIR/ui.log}"
UI_UNIT="${UI_UNIT:-rtsp-studio.service}"
UI_UNIT_PATH="${UI_UNIT_PATH:-$HOME/.config/systemd/user/$UI_UNIT}"

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ui_python() {
  command -v python3
}

prepare_user_systemd() {
  local uid
  uid="$(id -u)"
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/run/user/$uid"
  fi
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
}

systemd_user_ok() {
  have_cmd systemctl || return 1
  prepare_user_systemd
  [ -d "${XDG_RUNTIME_DIR:-}" ] || return 1
  systemctl --user status >/dev/null 2>&1
}

ui_port_open() {
  python3 - "$UI_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(0.4)
try:
    raise SystemExit(0 if s.connect_ex(("127.0.0.1", port)) == 0 else 1)
finally:
    s.close()
PY
}

ui_pids() {
  pgrep -f '(^|/)python3( -u)? (.*/)?ui\.py$' 2>/dev/null || true
}

ui_service_active() {
  systemd_user_ok && systemctl --user is-active --quiet "$UI_UNIT"
}

write_ui_unit() {
  local python_bin unit_dir
  python_bin="$(ui_python)"
  unit_dir="$(dirname -- "$UI_UNIT_PATH")"
  mkdir -p "$unit_dir" "$LOG_DIR"
  cat > "$UI_UNIT_PATH" <<EOF
[Unit]
Description=RTSP Studio web UI
After=network.target

[Service]
Type=simple
WorkingDirectory=$ROOT
Environment=PYTHONUNBUFFERED=1
Environment=UI_HOST=$UI_HOST
Environment=UI_PORT=$UI_PORT
ExecStart=$python_bin $ROOT/ui.py
Restart=on-failure
RestartSec=2
StandardOutput=append:$UI_LOG
StandardError=append:$UI_LOG

[Install]
WantedBy=default.target
EOF
}

wait_for_ui() {
  local i=0
  while [ "$i" -lt 25 ]; do
    if ui_port_open; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

lan_ip() {
  python3 - <<'PY'
import subprocess
try:
    out = subprocess.run(
        ["ip", "-4", "route", "get", "1.1.1.1"],
        capture_output=True, text=True, timeout=2, check=False,
    ).stdout.split()
    if "src" in out:
        print(out[out.index("src") + 1])
        raise SystemExit(0)
except Exception:
    pass
print("127.0.0.1")
PY
}

print_ui_urls() {
  local ip
  ip="$(lan_ip)"
  echo "RTSP Studio: http://127.0.0.1:$UI_PORT"
  if [ "$ip" != "127.0.0.1" ] && [ "$ip" != "localhost" ]; then
    echo "             http://$ip:$UI_PORT"
  fi
}

start_ui_service() {
  mkdir -p "$LOG_DIR"
  if systemd_user_ok; then
    write_ui_unit
    systemctl --user daemon-reload
    systemctl --user enable "$UI_UNIT" >/dev/null 2>&1
    if have_cmd loginctl; then
      loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
    fi
  fi
  if ui_port_open; then
    echo "UI already listening on port $UI_PORT."
    return 0
  fi

  if systemd_user_ok; then
    systemctl --user start "$UI_UNIT"
    if wait_for_ui; then
      echo "UI service started ($UI_UNIT)."
      echo "Logs: journalctl --user -u $UI_UNIT -n 50"
      echo "      $UI_LOG"
      return 0
    fi
    echo "systemd user service did not open port $UI_PORT; falling back to a background process." >&2
    systemctl --user stop "$UI_UNIT" >/dev/null 2>&1 || true
  fi

  nohup "$(ui_python)" -u "$ROOT/ui.py" >>"$UI_LOG" 2>&1 &
  echo $! > "$UI_PID_FILE"
  disown || true
  if wait_for_ui; then
    echo "UI started in the background (pid $(cat "$UI_PID_FILE"))."
    echo "Logs: $UI_LOG"
    return 0
  fi
  echo "UI did not start. Last log lines:" >&2
  tail -n 40 "$UI_LOG" 2>/dev/null >&2 || true
  return 1
}

stop_ui_service() {
  local pid
  if systemd_user_ok && [ -f "$UI_UNIT_PATH" ]; then
    systemctl --user stop "$UI_UNIT" >/dev/null 2>&1 || true
  fi
  if [ -s "$UI_PID_FILE" ]; then
    read -r pid < "$UI_PID_FILE" || true
    if pid_alive "${pid:-}"; then
      signal_pid TERM "$pid"
      wait_for_exit "$pid" 20 || signal_pid KILL "$pid"
    fi
    : > "$UI_PID_FILE"
  fi
  for pid in $(ui_pids); do
    signal_pid TERM "$pid"
    wait_for_exit "$pid" 20 || signal_pid KILL "$pid"
  done
  if ui_port_open; then
    echo "UI port $UI_PORT is still in use." >&2
    return 1
  fi
  echo "UI stopped."
}
