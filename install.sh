#!/usr/bin/env bash
# Install runtime dependencies for rtsp-folder-streamer on a clean machine.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-1.13.1}"
VENDOR_DIR="$SCRIPT_DIR/vendor/mediamtx"
SKIP_PACKAGES=0

usage() {
  cat <<EOF
Usage: $0 [--skip-packages]

Installs what this app needs on a machine that does not already have
MediaMTX, ffmpeg, or the timestamp font:

  - Python 3.10+
  - ffmpeg / ffprobe (with libx264 and drawtext)
  - a monospace TTF (DejaVu Sans Mono)
  - MediaMTX v${MEDIAMTX_VERSION} into ./vendor/mediamtx

Then start the UI:

  python3 $SCRIPT_DIR/ui.py

Open the printed URL (this host, port 8787). Start/Stop in the web UI
runs the RTSP publishers on this machine.

  --skip-packages   only fetch MediaMTX; do not install OS packages
  MEDIAMTX_VERSION  override MediaMTX release (default: ${MEDIAMTX_VERSION})
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --skip-packages)
      SKIP_PACKAGES=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

have() {
  command -v "$1" >/dev/null 2>&1
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    echo "Need root to install packages. Re-run as root, or install the packages listed above and use --skip-packages." >&2
    exit 1
  fi
}

python_ok() {
  have python3 && python3 - <<'PY'
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
}

font_ok() {
  local f
  for f in \
    /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
    /usr/share/fonts/TTF/DejaVuSansMono.ttf \
    /usr/share/fonts/dejavu/DejaVuSansMono.ttf \
    /usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf \
    /usr/share/fonts/truetype/freefont/FreeMono.ttf
  do
    [ -f "$f" ] && return 0
  done
  return 1
}

ffmpeg_ok() {
  have ffmpeg && have ffprobe
}

install_packages() {
  if python_ok && ffmpeg_ok && font_ok; then
    echo "Python, ffmpeg, and overlay font are already installed."
    return 0
  fi
  if [ "$SKIP_PACKAGES" = 1 ]; then
    echo "Skipping OS packages (--skip-packages)."
    return 0
  fi

  echo "Installing OS packages (python3, ffmpeg, fonts)…"
  if have apt-get; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get update -y
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3 ffmpeg fonts-dejavu-core curl ca-certificates iproute2 tar gzip
  elif have dnf; then
    run_root dnf install -y python3 ffmpeg dejavu-sans-mono-fonts curl ca-certificates iproute tar gzip
  elif have yum; then
    run_root yum install -y python3 ffmpeg dejavu-sans-mono-fonts curl ca-certificates iproute tar gzip
  elif have pacman; then
    run_root pacman -Sy --noconfirm python ffmpeg ttf-dejavu curl ca-certificates iproute2 tar gzip
  elif have brew; then
    brew install python ffmpeg
  else
    echo "No supported package manager found (apt, dnf, yum, pacman, brew)." >&2
    echo "Install python3 (>= 3.10), ffmpeg, ffprobe, and DejaVu Sans Mono, then re-run with --skip-packages." >&2
    exit 1
  fi
}

mtx_os_arch() {
  local os arch
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      echo "Unsupported OS: $(uname -s). Install MediaMTX yourself and set MEDIAMTX_BIN." >&2
      exit 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7) arch="armv7" ;;
    armv6l|armv6) arch="armv6" ;;
    *)
      echo "Unsupported CPU: $(uname -m)." >&2
      exit 1
      ;;
  esac
  printf '%s_%s' "$os" "$arch"
}

download() {
  local url="$1"
  local dest="$2"
  if have curl; then
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  elif have wget; then
    wget -O "$dest" "$url"
  else
    echo "Need curl or wget to download MediaMTX." >&2
    exit 1
  fi
}

install_mediamtx() {
  mkdir -p "$VENDOR_DIR"
  if [ -x "$VENDOR_DIR/mediamtx" ]; then
    echo "MediaMTX already installed at $VENDOR_DIR/mediamtx"
    return 0
  fi

  local local_bin="${HOME}/Downloads/mediamtx_v${MEDIAMTX_VERSION}_$(mtx_os_arch)/mediamtx"
  if [ -x "$local_bin" ]; then
    echo "Copying existing MediaMTX from $local_bin"
    cp "$local_bin" "$VENDOR_DIR/mediamtx"
    chmod +x "$VENDOR_DIR/mediamtx"
    return 0
  fi

  local spec archive url checksums tmp
  spec="$(mtx_os_arch)"
  archive="mediamtx_v${MEDIAMTX_VERSION}_${spec}.tar.gz"
  url="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/${archive}"
  checksums="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/checksums.sha256"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  echo "Downloading MediaMTX v${MEDIAMTX_VERSION} ($spec)…"
  download "$url" "$tmp/$archive"
  if download "$checksums" "$tmp/checksums.sha256"; then
    (
      cd "$tmp"
      if grep -F " $archive" checksums.sha256 | sha256sum -c -; then
        :
      else
        echo "MediaMTX checksum mismatch." >&2
        exit 1
      fi
    )
  else
    echo "Warning: could not download checksums.sha256; continuing without verify." >&2
  fi
  tar -xzf "$tmp/$archive" -C "$tmp"
  if [ ! -f "$tmp/mediamtx" ]; then
    echo "MediaMTX archive did not contain a mediamtx binary." >&2
    exit 1
  fi
  cp "$tmp/mediamtx" "$VENDOR_DIR/mediamtx"
  chmod +x "$VENDOR_DIR/mediamtx"
}

check_runtime() {
  local failed=0
  if ! python_ok; then
    echo "Python 3.10+ is required (python3)." >&2
    failed=1
  else
    echo "python3: $(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  fi
  if ! ffmpeg_ok; then
    echo "ffmpeg and ffprobe are required on PATH." >&2
    failed=1
  else
    echo "ffmpeg: $(ffmpeg -hide_banner -version 2>/dev/null | head -n 1)"
  fi
  if have ffmpeg; then
    filters="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
    encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
    case "$filters" in
      *drawtext*) ;;
      *) echo "Warning: ffmpeg is missing the drawtext filter; timestamp overlay will not burn into RTSP." >&2 ;;
    esac
    case "$encoders" in
      *libx264*) ;;
      *) echo "Warning: ffmpeg is missing libx264; scaled output and overlay need it." >&2 ;;
    esac
  fi
  if ! font_ok; then
    echo "Warning: no DejaVu/Liberation/FreeMono TTF found; timestamp overlay needs a font." >&2
  fi
  if [ ! -x "$VENDOR_DIR/mediamtx" ]; then
    echo "MediaMTX binary missing at $VENDOR_DIR/mediamtx" >&2
    failed=1
  else
    echo "MediaMTX: $VENDOR_DIR/mediamtx"
  fi
  chmod +x "$SCRIPT_DIR/start.sh" "$SCRIPT_DIR/stop.sh" "$SCRIPT_DIR/ui.py" "$SCRIPT_DIR/install.sh" 2>/dev/null || true
  return "$failed"
}

install_packages
install_mediamtx
if ! check_runtime; then
  echo "Install did not finish cleanly." >&2
  exit 1
fi

cat <<EOF

Ready. Start the UI on this machine:

  python3 $SCRIPT_DIR/ui.py

The web UI listens on port 8787 (all interfaces). Start/Stop from any
browser still publishes RTSP from this host.
EOF
