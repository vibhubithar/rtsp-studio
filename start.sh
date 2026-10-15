#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

VIDEO_EXTS='mp4|mkv|mov|avi|m4v|webm|ts|mts'

usage() {
  cat <<EOF
Usage: $0 <video-folder> [height]
       $0 <video-folder> --res HEIGHT

Starts MediaMTX and one looping RTSP publish per video file in the folder
(non-recursive). RTSP path is the filename without extension.

HEIGHT is the output height in pixels: 480, 720, 1080, etc.
720p and 1280x720 are also accepted. Aspect ratio is preserved.
If omitted, each file is published at its original resolution (stream copy).

--offset seeks every file to the same timestamp so the folder stays in sync.
Accepts seconds (125.5) or a clock time (2:05 / 00:02:05).
--end sets the stop timestamp. With --loop (default) RTSP repeats start→end.
--no-loop plays start→end once.

--only FILE can be repeated to publish only those filenames (basename, in the folder).
If omitted, every video in the folder is published.

--mark FILE=SECONDS sets a shared event in that file (repeat per camera).
--ref FILE is the reference camera (default: first selected). Start/end times
are on the reference timeline; other files are shifted by (mark - ref mark).

--overlay burns dd-mm-yyyy hh:mm:ss.sss on each RTSP feed.
--overlay-pos CORNER is top-left, bottom-left, top-right, or bottom-right.
--overlay-size SIZE is small, medium, large, or xlarge.
--overlay-color COLOR is white, yellow, red, green, or blue.
--origin-unix SECONDS is the wall clock at file 00:00:00 (host local time).
Overlay forces a libx264 encode even when HEIGHT is omitted.

--ir also publishes a simulated IR feed per camera at <path>_ir.
--ir-style STYLE is thermal (heatmap) or night (green night vision).
IR always encodes. If HEIGHT is omitted, IR is 720p so the color feed can stay 4K copy.

  $0 /home/vibhu/Santa-Clara-test-Videos --res 720 --offset 90 --end 180 --only SITE1-channel-2.mp4
  $0 ... --mark SITE1-channel-2.mp4=120.5 --mark SITE1-channel-4.mp4=123.1 --ref SITE1-channel-2.mp4

Environment (optional):
  MEDIAMTX_BIN   path to mediamtx      (default: $MEDIAMTX_BIN)
  RTSP_PORT      listen/publish port   (default: $RTSP_PORT)
  RTSP_BIND      address ffmpeg uses   (default: $RTSP_BIND)
EOF
}

normalize_height() {
  local raw="${1:-}"
  raw="${raw,,}"
  raw="${raw%p}"
  if [[ "$raw" == *x* ]]; then
    raw="${raw##*x}"
  fi
  if ! [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "Invalid resolution '$1'. Use 480, 720, 1080, or 1280x720." >&2
    exit 1
  fi
  if [ "$raw" -lt 144 ] || [ "$raw" -gt 4320 ]; then
    echo "Resolution height must be between 144 and 4320, got $raw." >&2
    exit 1
  fi
  printf '%s' $((raw - raw % 2))
}

is_resolution_token() {
  local raw="${1:-}"
  raw="${raw,,}"
  [[ "$raw" =~ ^[0-9]+p?$ ]] || [[ "$raw" =~ ^[0-9]+x[0-9]+$ ]]
}

parse_offset() {
  local raw="${1:-}"
  if [[ "$raw" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "$raw"
    return
  fi
  if [[ "$raw" =~ ^[0-9]+:[0-9]{1,2}(:[0-9]{1,2}(\.[0-9]+)?)?$ ]]; then
    awk -F: -v t="$raw" 'BEGIN{
      n = split(t, a, ":")
      if (n == 3) s = a[1]*3600 + a[2]*60 + a[3]
      else if (n == 2) s = a[1]*60 + a[2]
      else exit 1
      if (s < 0) exit 1
      printf "%.3f", s
    }'
    return
  fi
  echo "Invalid offset '$raw'. Use seconds (125.5) or HH:MM:SS." >&2
  exit 1
}

VIDEO_DIR_ARG=""
OUT_HEIGHT=""
START_OFFSET="0"
END_OFFSET=""
LOOP_MODE="1"
ONLY_FILES=()
declare -A MARKS=()
REF_NAME=""
OVERLAY=0
OVERLAY_POS="top-left"
OVERLAY_SIZE="small"
OVERLAY_COLOR="white"
ORIGIN_UNIX=""
IR=0
IR_STYLE="thermal"
if [ -z "${OVERLAY_FONT:-}" ]; then
  for _font in \
    /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
    /usr/share/fonts/TTF/DejaVuSansMono.ttf \
    /usr/share/fonts/dejavu/DejaVuSansMono.ttf \
    /usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf \
    /usr/share/fonts/truetype/freefont/FreeMono.ttf
  do
    if [ -f "$_font" ]; then
      OVERLAY_FONT="$_font"
      break
    fi
  done
  unset _font
fi
OVERLAY_FONT="${OVERLAY_FONT:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --res|--resolution)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      OUT_HEIGHT=$(normalize_height "$2")
      shift 2
      ;;
    --res=*|--resolution=*)
      OUT_HEIGHT=$(normalize_height "${1#*=}")
      shift
      ;;
    --offset|--ss)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      START_OFFSET=$(parse_offset "$2")
      shift 2
      ;;
    --offset=*|--ss=*)
      START_OFFSET=$(parse_offset "${1#*=}")
      shift
      ;;
    --end|--to)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      END_OFFSET=$(parse_offset "$2")
      shift 2
      ;;
    --end=*|--to=*)
      END_OFFSET=$(parse_offset "${1#*=}")
      shift
      ;;
    --loop)
      LOOP_MODE="1"
      shift
      ;;
    --no-loop)
      LOOP_MODE="0"
      shift
      ;;
    --only)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      ONLY_FILES+=("$2")
      shift 2
      ;;
    --only=*)
      ONLY_FILES+=("${1#*=}")
      shift
      ;;
    --mark)
      if [ -z "${2:-}" ] || [[ "$2" != *=* ]]; then
        echo "Use --mark FILE=SECONDS" >&2
        exit 1
      fi
      MARKS["$(basename -- "${2%%=*}")"]=$(parse_offset "${2#*=}")
      shift 2
      ;;
    --mark=*)
      spec="${1#*=}"
      if [[ "$spec" != *=* ]]; then
        echo "Use --mark=FILE=SECONDS" >&2
        exit 1
      fi
      MARKS["$(basename -- "${spec%%=*}")"]=$(parse_offset "${spec#*=}")
      shift
      ;;
    --ref)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      REF_NAME=$(basename -- "$2")
      shift 2
      ;;
    --ref=*)
      REF_NAME=$(basename -- "${1#*=}")
      shift
      ;;
    --overlay)
      OVERLAY=1
      shift
      ;;
    --overlay-pos)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      OVERLAY_POS="$2"
      shift 2
      ;;
    --overlay-pos=*)
      OVERLAY_POS="${1#*=}"
      shift
      ;;
    --overlay-size)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      OVERLAY_SIZE="$2"
      shift 2
      ;;
    --overlay-size=*)
      OVERLAY_SIZE="${1#*=}"
      shift
      ;;
    --overlay-color)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      OVERLAY_COLOR="$2"
      shift 2
      ;;
    --overlay-color=*)
      OVERLAY_COLOR="${1#*=}"
      shift
      ;;
    --origin-unix)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      ORIGIN_UNIX="$2"
      shift 2
      ;;
    --origin-unix=*)
      ORIGIN_UNIX="${1#*=}"
      shift
      ;;
    --ir)
      IR=1
      shift
      ;;
    --ir-style)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      IR=1
      IR_STYLE="$2"
      shift 2
      ;;
    --ir-style=*)
      IR=1
      IR_STYLE="${1#*=}"
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -z "$VIDEO_DIR_ARG" ]; then
        VIDEO_DIR_ARG=$1
      elif [ -z "$OUT_HEIGHT" ] && is_resolution_token "$1"; then
        OUT_HEIGHT=$(normalize_height "$1")
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

OVERLAY_POS="${OVERLAY_POS,,}"
OVERLAY_POS="${OVERLAY_POS//_/-}"
case "$OVERLAY_POS" in
  top-left|bottom-left|top-right|bottom-right) ;;
  *) OVERLAY_POS="top-left" ;;
esac
OVERLAY_SIZE="${OVERLAY_SIZE,,}"
case "$OVERLAY_SIZE" in
  small|medium|large|xlarge) ;;
  extra-large|x-large|xl) OVERLAY_SIZE="xlarge" ;;
  *) OVERLAY_SIZE="small" ;;
esac
OVERLAY_COLOR="${OVERLAY_COLOR,,}"
case "$OVERLAY_COLOR" in
  white|yellow|red|green|blue) ;;
  *) OVERLAY_COLOR="white" ;;
esac
IR_STYLE="${IR_STYLE,,}"
IR_STYLE="${IR_STYLE//_/-}"
case "$IR_STYLE" in
  thermal|heat|inferno) IR_STYLE="thermal" ;;
  night|nv|green|night-vision|nightvision) IR_STYLE="night" ;;
  *) IR_STYLE="thermal" ;;
esac

if [ -z "$VIDEO_DIR_ARG" ]; then
  usage >&2
  exit 1
fi

VIDEO_DIR=$(readlink -f -- "$VIDEO_DIR_ARG") || {
  echo "Folder not found: $VIDEO_DIR_ARG" >&2
  exit 1
}

if [ ! -d "$VIDEO_DIR" ]; then
  echo "Not a directory: $VIDEO_DIR" >&2
  exit 1
fi

if [ ! -x "$MEDIAMTX_BIN" ]; then
  echo "MediaMTX not found or not executable: $MEDIAMTX_BIN" >&2
  echo "Run $SCRIPT_DIR/install.sh on this machine, or set MEDIAMTX_BIN." >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found on PATH" >&2
  exit 1
fi

mapfile -d '' -t videos < <(
  find "$VIDEO_DIR" -maxdepth 1 -type f -regextype posix-extended \
    -iregex ".*\\.(${VIDEO_EXTS})\$" -print0 | sort -z
)
if [ "${#videos[@]}" -gt 0 ]; then
  kept=()
  for video in "${videos[@]}"; do
    bn=$(basename -- "$video")
    stem=${bn%.*}
    ext=${bn##*.}
    if [[ "$stem" =~ ^(.*)_clip[0-9]+$ ]]; then
      orig="$VIDEO_DIR/${BASH_REMATCH[1]}.$ext"
      if [ -f "$orig" ]; then
        continue
      fi
    fi
    kept+=("$video")
  done
  videos=("${kept[@]}")
fi

if [ "${#videos[@]}" -eq 0 ]; then
  echo "No video files found in $VIDEO_DIR" >&2
  echo "Looked for: ${VIDEO_EXTS//|/, }" >&2
  exit 1
fi

if [ "${#ONLY_FILES[@]}" -gt 0 ]; then
  filtered=()
  for video in "${videos[@]}"; do
    bn=$(basename -- "$video")
    for want in "${ONLY_FILES[@]}"; do
      want_bn=$(basename -- "$want")
      if [ "$bn" = "$want_bn" ]; then
        filtered+=("$video")
        break
      fi
    done
  done
  if [ "${#filtered[@]}" -eq 0 ]; then
    echo "None of the requested files were found in $VIDEO_DIR" >&2
    exit 1
  fi
  videos=("${filtered[@]}")
fi

if [ "${#MARKS[@]}" -gt 0 ]; then
  if [ -z "$REF_NAME" ]; then
    REF_NAME=$(basename -- "${videos[0]}")
  fi
  if [ -z "${MARKS[$REF_NAME]:-}" ]; then
    echo "Reference camera '$REF_NAME' has no --mark." >&2
    exit 1
  fi
  for video in "${videos[@]}"; do
    bn=$(basename -- "$video")
    if [ -z "${MARKS[$bn]:-}" ]; then
      echo "Missing --mark for $bn (needed to align with $REF_NAME)." >&2
      exit 1
    fi
  done
  echo "Sync reference: $REF_NAME at ${MARKS[$REF_NAME]}s"
  for video in "${videos[@]}"; do
    bn=$(basename -- "$video")
    delta=$(awk -v a="${MARKS[$bn]}" -v b="${MARKS[$REF_NAME]}" 'BEGIN{printf "%+.3f", a-b}')
    echo "  $bn mark ${MARKS[$bn]}s  delta ${delta}s"
    file_ss=$(awk -v s="$START_OFFSET" -v d="${MARKS[$bn]}" -v r="${MARKS[$REF_NAME]}" 'BEGIN{printf "%.3f", s+(d-r)}')
    if awk -v x="$file_ss" 'BEGIN{exit !(x+0 < 0)}'; then
      echo "$bn starts at ${file_ss}s after alignment (before the file). Move start later on the reference timeline." >&2
      exit 1
    fi
    if [ -n "$END_OFFSET" ]; then
      file_ee=$(awk -v e="$END_OFFSET" -v d="${MARKS[$bn]}" -v r="${MARKS[$REF_NAME]}" 'BEGIN{printf "%.3f", e+(d-r)}')
      if awk -v s="$file_ss" -v e="$file_ee" 'BEGIN{exit !(e < s + 0.5)}'; then
        echo "$bn: aligned range ${file_ss}s–${file_ee}s is too short. Move start/end on the reference timeline." >&2
        exit 1
      fi
    fi
  done
fi

if [ -n "$END_OFFSET" ]; then
  if ! awk -v s="$START_OFFSET" -v e="$END_OFFSET" 'BEGIN{exit !(e >= s + 0.5)}'; then
    echo "End time must be at least 0.5s after start (start=${START_OFFSET}s end=${END_OFFSET}s)." >&2
    exit 1
  fi
fi

# Restart cleanly if a previous run left processes around.
stop_all_streams quiet
rm -rf "$STATE_DIR/concat" "$STATE_DIR/run"
mkdir -p "$STATE_DIR/concat" "$STATE_DIR/run"

write_loop_concat() {
  local dest="$1" video="$2" ss="$3" ee="$4" loops="${5:-20000}"
  local esc
  esc=$(printf "%s" "$video" | sed "s/'/'\\\\''/g")
  awk -v vid="$esc" -v ss="$ss" -v ee="$ee" -v n="$loops" 'BEGIN {
    print "ffconcat version 1.0"
    for (i = 0; i < n; i++) {
      printf "file '\''%s'\''\ninpoint %s\noutpoint %s\n", vid, ss, ee
    }
  }' > "$dest"
}

rtsp_path_from_file() {
  local stem path
  stem=$(basename -- "$1")
  stem=${stem%.*}
  path=$(printf '%s' "$stem" | sed 's/[^A-Za-z0-9_-]/_/g; s/__*/_/g; s/^_\|_$//g')
  [ -n "$path" ] || path="stream"
  printf '%s' "$path"
}

claim_rtsp_path() {
  local path="$1"
  local base="$path"
  local n=2
  while [ -n "${used_paths[$path]:-}" ]; do
    path="${base}_${n}"
    n=$((n + 1))
  done
  used_paths[$path]=1
  printf '%s' "$path"
}

wait_for_port() {
  local port="$1"
  local attempts="${2:-40}"
  local i=0
  while [ "$i" -lt "$attempts" ]; do
    if bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

echo "Starting MediaMTX..."
(
  cd "$MEDIAMTX_DIR"
  exec "$MEDIAMTX_BIN" "$MEDIAMTX_CONF"
) </dev/null >"$LOG_DIR/mediamtx.log" 2>&1 &
mediamtx_pid=$!
echo "mediamtx $mediamtx_pid" > "$PID_FILE"

if ! pid_alive "$mediamtx_pid"; then
  echo "MediaMTX exited immediately. See $LOG_DIR/mediamtx.log" >&2
  exit 1
fi

if ! wait_for_port "$RTSP_PORT"; then
  echo "MediaMTX did not listen on port $RTSP_PORT. See $LOG_DIR/mediamtx.log" >&2
  stop_all_streams quiet
  exit 1
fi

declare -A used_paths=()
started=()
failed=()

if [ -n "$OUT_HEIGHT" ]; then
  echo "Publishing ${#videos[@]} video(s) from $VIDEO_DIR at ${OUT_HEIGHT}p"
else
  echo "Publishing ${#videos[@]} video(s) from $VIDEO_DIR at original resolution"
fi
if awk -v o="$START_OFFSET" 'BEGIN{exit !(o+0 > 0)}'; then
  echo "Synced start offset: ${START_OFFSET}s"
fi
if [ -n "$END_OFFSET" ]; then
  if [ "$LOOP_MODE" = 1 ]; then
    echo "Looping ${START_OFFSET}s → ${END_OFFSET}s"
  else
    echo "Playing ${START_OFFSET}s → ${END_OFFSET}s once"
  fi
fi
if [ "$IR" = 1 ]; then
  echo "Also publishing ${IR_STYLE} IR at <path>_ir"
fi
echo

video_codec() {
  ffprobe -v error -select_streams v:0 -analyzeduration 2000000 -probesize 2000000 \
    -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | head -n 1
}

bitrate_for_height() {
  case "$1" in
    480) printf '%s' "800k" ;;
    720) printf '%s' "1500k" ;;
    1080) printf '%s' "2500k" ;;
    *) printf '%sk' $(($1 * 2)) ;;
  esac
}

publish_feed() {
  local video="$1"
  local path="$2"
  local file_ss="$3"
  local file_ee="$4"
  local kind="${5:-color}"
  local url publish logfile
  local cfile seg_dur runfile ffmpeg_pid
  local bitrate codec ir_h fs_h fs bw wall_base wall_int frac ox oy encode
  local label="$video"
  [ "$kind" = ir ] && label="$video (IR)"

  url="rtsp://localhost:${RTSP_PORT}/${path}"
  publish="rtsp://${RTSP_BIND}:${RTSP_PORT}/${path}"
  logfile="$LOG_DIR/${path}.ffmpeg.log"

  local -a ffmpeg_args vf_filters
  ffmpeg_args=(
    ffmpeg -nostdin -hide_banner -loglevel warning
    -fflags +genpts+discardcorrupt
    -re
  )
  if [ -n "$file_ee" ] && [ "$LOOP_MODE" = 1 ]; then
    cfile="$STATE_DIR/concat/${path}.ffconcat"
    write_loop_concat "$cfile" "$video" "$file_ss" "$file_ee"
    ffmpeg_args+=(-f concat -safe 0 -i "$cfile")
  elif [ -n "$file_ee" ]; then
    seg_dur=$(awk -v s="$file_ss" -v e="$file_ee" 'BEGIN{printf "%.3f", e-s}')
    if awk -v o="$file_ss" 'BEGIN{exit !(o+0 > 0)}'; then
      ffmpeg_args+=(-ss "$file_ss")
    fi
    ffmpeg_args+=(-t "$seg_dur" -i "$video")
  else
    if awk -v o="$file_ss" 'BEGIN{exit !(o+0 > 0)}'; then
      ffmpeg_args+=(-ss "$file_ss")
    fi
    ffmpeg_args+=(-stream_loop -1 -i "$video")
  fi
  ffmpeg_args+=(-map 0:v:0 -an)

  vf_filters=()
  encode=0
  ir_h=""
  if [ "$kind" = ir ]; then
    ir_h="${OUT_HEIGHT:-720}"
    vf_filters+=("scale=-2:${ir_h}")
    case "$IR_STYLE" in
      night)
        vf_filters+=(
          "hue=s=0"
          "eq=contrast=1.2:brightness=0.04"
          "colorchannelmixer=rr=0.05:rg=0:rb=0:gr=0.15:gg=0.8:gb=0.05:br=0:bg=0.2:bb=0.05"
        )
        ;;
      *)
        vf_filters+=(
          "format=gray"
          "eq=contrast=1.2:gamma=0.85"
          "pseudocolor=preset=inferno"
        )
        ;;
    esac
    encode=1
  elif [ -n "$OUT_HEIGHT" ]; then
    vf_filters+=("scale=-2:${OUT_HEIGHT}")
    encode=1
  fi

  if [ "$OVERLAY" = 1 ]; then
    if [ ! -f "$OVERLAY_FONT" ]; then
      echo "Timestamp overlay font not found: $OVERLAY_FONT" >&2
      failed+=("$label")
      return
    fi
    local base_unix="$ORIGIN_UNIX"
    [ -z "$base_unix" ] && base_unix="0"
    # pts 0 of this encode is file_ss; show wall clock origin + file time.
    wall_base=$(awk -v o="$base_unix" -v s="$file_ss" 'BEGIN{printf "%.3f", o+s}')
    fs=22
    fs_h="$OUT_HEIGHT"
    [ "$kind" = ir ] && [ -z "$fs_h" ] && fs_h="720"
    if [ -n "$fs_h" ]; then
      fs=$((fs_h / 30))
      [ "$fs" -lt 16 ] && fs=16
      [ "$fs" -gt 36 ] && fs=36
    fi
    case "$OVERLAY_SIZE" in
      medium) fs=$((fs * 3 / 2)) ;;
      large) fs=$((fs * 2)) ;;
      xlarge) fs=$((fs * 11 / 4)) ;;
    esac
    bw=2
    case "$OVERLAY_SIZE" in
      large) bw=3 ;;
      xlarge) bw=4 ;;
    esac
    wall_int=$(awk -v x="$wall_base" 'BEGIN{printf "%d", int(x)}')
    frac=$(awk -v x="$wall_base" 'BEGIN{printf "%.6f", x-int(x)}')
    case "$OVERLAY_POS" in
      top-right)
        ox="w-tw-12"
        oy="10"
        ;;
      bottom-left)
        ox="12"
        oy="h-th-10"
        ;;
      bottom-right)
        ox="w-tw-12"
        oy="h-th-10"
        ;;
      *)
        ox="12"
        oy="10"
        ;;
    esac
    vf_filters+=("drawtext=fontfile=${OVERLAY_FONT}:fontsize=${fs}:fontcolor=${OVERLAY_COLOR}:borderw=${bw}:bordercolor=black:x=${ox}:y=${oy}:text='%{pts\\:localtime\\:${wall_int}\\:%d-%m-%Y %T}.%{eif\\:mod((t+${frac})*1000\\,1000)\\:d\\:3}'")
    encode=1
  fi

  if [ "$encode" = 1 ]; then
    bitrate="2500k"
    if [ "$kind" = ir ]; then
      bitrate=$(bitrate_for_height "$ir_h")
    elif [ -n "$OUT_HEIGHT" ]; then
      bitrate=$(bitrate_for_height "$OUT_HEIGHT")
    fi
    local vf_joined saved_ifs="$IFS"
    IFS=,
    vf_joined="${vf_filters[*]}"
    IFS="$saved_ifs"
    ffmpeg_args+=(
      -vf "$vf_joined"
      -r 15 -pix_fmt yuv420p
      -c:v libx264 -preset veryfast -tune zerolatency
      -profile:v baseline -bf 0 -g 30 -keyint_min 30
      -b:v "$bitrate"
    )
  else
    codec=$(video_codec "$video")
    ffmpeg_args+=(-c:v copy)
    case "$codec" in
      h264) ffmpeg_args+=(-bsf:v h264_mp4toannexb) ;;
      hevc|h265) ffmpeg_args+=(-bsf:v hevc_mp4toannexb) ;;
      *)
        echo "Unsupported video codec '${codec:-unknown}' in $(basename -- "$video"); skipping." >&2
        failed+=("$label")
        return
        ;;
    esac
  fi

  ffmpeg_args+=(-f rtsp -rtsp_transport tcp "$publish")

  runfile="$STATE_DIR/run/${path}.sh"
  {
    printf '%s\n' '#!/bin/bash' 'trap "kill 0" EXIT TERM INT' 'while true; do'
    printf '  '
    printf '%q ' "${ffmpeg_args[@]}"
    printf '%s\n' '</dev/null' \
      '  echo "$(date -Iseconds) ffmpeg exited $?, restarting" >&2' \
      '  sleep 0.5' \
      'done'
  } > "$runfile"
  chmod +x "$runfile"
  setsid "$runfile" >>"$logfile" 2>&1 &
  ffmpeg_pid=$!
  echo "ffmpeg $ffmpeg_pid $url $video" >> "$PID_FILE"
  started+=("$ffmpeg_pid|$url|$video|$logfile")
}

for video in "${videos[@]}"; do
  path=$(claim_rtsp_path "$(rtsp_path_from_file "$video")")
  bn=$(basename -- "$video")
  file_ss="$START_OFFSET"
  file_ee="$END_OFFSET"
  if [ "${#MARKS[@]}" -gt 0 ]; then
    delta=$(awk -v a="${MARKS[$bn]}" -v b="${MARKS[$REF_NAME]}" 'BEGIN{printf "%.3f", a-b}')
    file_ss=$(awk -v s="$START_OFFSET" -v d="$delta" 'BEGIN{printf "%.3f", s+d}')
    if [ -n "$END_OFFSET" ]; then
      file_ee=$(awk -v e="$END_OFFSET" -v d="$delta" 'BEGIN{printf "%.3f", e+d}')
    fi
    file_ss=$(awk -v x="$file_ss" 'BEGIN{printf "%.3f", (x<0)?0:x}')
    if [ -n "$file_ee" ]; then
      file_ee=$(awk -v x="$file_ee" 'BEGIN{printf "%.3f", (x<0)?0:x}')
    fi
  fi
  publish_feed "$video" "$path" "$file_ss" "$file_ee" color
  if [ "$IR" = 1 ]; then
    ir_path=$(claim_rtsp_path "${path}_ir")
    publish_feed "$video" "$ir_path" "$file_ss" "$file_ee" ir
  fi
done

# Transcode needs a bit longer to fail fast than stream copy.
if [ "$IR" = 1 ]; then
  sleep 4
elif [ -n "$OUT_HEIGHT" ] || [ "$OVERLAY" = 1 ]; then
  sleep 3
else
  sleep 1.5
fi

detect_lan_ip() {
  local ip=""
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }
  }')
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "${ip:-localhost}"
}

lan_ip=$(detect_lan_ip)
ok=0
ok_urls=()

for entry in "${started[@]}"; do
  IFS='|' read -r ffmpeg_pid url video logfile <<<"$entry"
  ip_url="${url/localhost/$lan_ip}"
  if pid_alive "$ffmpeg_pid"; then
    ok=$((ok + 1))
    ok_urls+=("$ip_url")
  else
    failed+=("$video")
    printf 'FAILED  %s\n' "$ip_url" >&2
    if [ -s "$logfile" ]; then
      printf '        %s\n' "$(tail -n 3 "$logfile")" >&2
    fi
  fi
done

if [ "$ok" -eq 0 ]; then
  echo "No feeds stayed up. Stopping MediaMTX." >&2
  stop_all_streams quiet
  exit 1
fi

printf '%s\n' "$VIDEO_DIR" > "$STATE_DIR/folder"
printf '%s\n' "${OUT_HEIGHT}" > "$STATE_DIR/height"
printf '%s\n' "$START_OFFSET" > "$STATE_DIR/offset"
printf '%s\n' "${END_OFFSET}" > "$STATE_DIR/end"
printf '%s\n' "$LOOP_MODE" > "$STATE_DIR/loop"
printf '%s\n' "$REF_NAME" > "$STATE_DIR/ref"
printf '%s\n' "$OVERLAY" > "$STATE_DIR/overlay"
printf '%s\n' "$OVERLAY_POS" > "$STATE_DIR/overlay-pos"
printf '%s\n' "$OVERLAY_SIZE" > "$STATE_DIR/overlay-size"
printf '%s\n' "$OVERLAY_COLOR" > "$STATE_DIR/overlay-color"
printf '%s\n' "$ORIGIN_UNIX" > "$STATE_DIR/origin"
printf '%s\n' "$IR" > "$STATE_DIR/ir"
printf '%s\n' "$IR_STYLE" > "$STATE_DIR/ir-style"
: > "$STATE_DIR/marks"
for mk in "${!MARKS[@]}"; do
  printf '%s %s\n' "$mk" "${MARKS[$mk]}" >> "$STATE_DIR/marks"
done
: > "$STATE_DIR/selected"
for video in "${videos[@]}"; do
  basename -- "$video" >> "$STATE_DIR/selected"
done
printf '%s\n' "${ok_urls[@]}" > "$STATE_DIR/urls"

msg="All $ok feeds started"
[ -n "$OUT_HEIGHT" ] && msg="${msg} at ${OUT_HEIGHT}p"
[ "$OVERLAY" = 1 ] && msg="${msg}, timestamp overlay"
[ "$IR" = 1 ] && msg="${msg}, ${IR_STYLE} IR channels"
if [ -n "$END_OFFSET" ]; then
  if [ "$LOOP_MODE" = 1 ]; then
    msg="${msg}, looping ${START_OFFSET}s–${END_OFFSET}s"
  else
    msg="${msg}, ${START_OFFSET}s–${END_OFFSET}s once"
  fi
elif awk -v o="$START_OFFSET" 'BEGIN{exit !(o+0 > 0)}'; then
  msg="${msg} from ${START_OFFSET}s"
fi
echo "${msg}."
echo "RTSP URLs:"
printf '%s\n' "${ok_urls[@]}"
echo "Use RTSP over TCP in the player (VLC: extra option :rtsp-tcp)."

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Started $ok/${#videos[@]} feeds. ${#failed[@]} failed (logs in $LOG_DIR)." >&2
  exit 1
fi
