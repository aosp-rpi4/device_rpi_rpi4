#!/usr/bin/env bash
#
# build_bootanimation.sh
#
# Converts a video (or GIF) into an Android bootanimation.zip, and
# optionally pushes it straight to a connected device over adb.
#
# Usage:
#   ./build_bootanimation.sh -m loop.mp4 --push
#   ./build_bootanimation.sh -i intro.mp4 -m loop.gif -r 1280x720 -f 24
#
# Run with --help for all options.

set -euo pipefail

# ---------- defaults ----------
MAIN_INPUT=""
INTRO_INPUT=""
OUTPUT="bootanimation.zip"
WIDTH=""
HEIGHT=""
FPS=30
DEVICE_PATH="/system/media/bootanimation.zip"
DO_PUSH=false
DO_REBOOT=false
KEEP_FRAMES=false

usage() {
  cat <<'EOF'
build_bootanimation.sh - build an Android bootanimation.zip from a video/GIF

Required:
  -m, --main FILE        Main clip (video or GIF) - loops until boot completes

Optional:
  -i, --intro FILE       Plays once before the main clip starts looping
  -o, --output FILE      Output zip path (default: bootanimation.zip)
  -r, --resolution WxH   e.g. 1920x1080. If omitted: tries adb (if a device
                         is connected), then falls back to the main clip's
                         own resolution
  -f, --fps N            Frames per second (default: 30)
  --push                 adb root + remount + push to the device
  --device-path PATH     Where to push on-device (default: /system/media/bootanimation.zip)
  --reboot               Reboot the device after pushing (implies --push)
  --keep-frames          Don't delete the extracted PNG frames afterward
  -h, --help             Show this help

Examples:
  ./build_bootanimation.sh -m clip.mp4 --push
  ./build_bootanimation.sh -i intro.mp4 -m loop.gif -r 1280x720 -f 24
EOF
}

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--main) MAIN_INPUT="$2"; shift 2 ;;
    -i|--intro) INTRO_INPUT="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -r|--resolution) WIDTH="${2%x*}"; HEIGHT="${2#*x}"; shift 2 ;;
    -f|--fps) FPS="$2"; shift 2 ;;
    --push) DO_PUSH=true; shift ;;
    --device-path) DEVICE_PATH="$2"; shift 2 ;;
    --reboot) DO_REBOOT=true; DO_PUSH=true; shift ;;
    --keep-frames) KEEP_FRAMES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MAIN_INPUT" ]]; then
  echo "Error: -m/--main FILE is required" >&2
  usage
  exit 1
fi
[[ -f "$MAIN_INPUT" ]] || { echo "Error: main file not found: $MAIN_INPUT" >&2; exit 1; }
if [[ -n "$INTRO_INPUT" ]]; then
  [[ -f "$INTRO_INPUT" ]] || { echo "Error: intro file not found: $INTRO_INPUT" >&2; exit 1; }
fi

# ---------- dependency checks ----------
for bin in ffmpeg ffprobe zip; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Error: '$bin' is required but not installed." >&2; exit 1; }
done
if $DO_PUSH; then
  command -v adb >/dev/null 2>&1 || { echo "Error: adb is required for --push." >&2; exit 1; }
fi

# ---------- resolution detection ----------
detect_device_resolution() {
  command -v adb >/dev/null 2>&1 || return 1
  adb get-state >/dev/null 2>&1 || return 1
  local size
  size=$(adb shell wm size 2>/dev/null | sed -n 's/.*Physical size: *\([0-9]*x[0-9]*\).*/\1/p' | tr -d '\r')
  [[ -n "$size" ]] || return 1
  echo "$size"
}

detect_source_resolution() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=s=x:p=0 "$1" | tr -d '\r'
}

if [[ -z "$WIDTH" || -z "$HEIGHT" ]]; then
  if SIZE=$(detect_device_resolution); then
    echo "Detected connected device resolution: $SIZE"
  else
    SIZE=$(detect_source_resolution "$MAIN_INPUT")
    echo "No device connected -- using source clip resolution: $SIZE"
  fi
  WIDTH="${SIZE%x*}"
  HEIGHT="${SIZE#*x}"
fi
echo "Target resolution: ${WIDTH}x${HEIGHT} @ ${FPS}fps"

# ---------- frame extraction ----------
TMPDIR=$(mktemp -d)
cleanup() { $KEEP_FRAMES || rm -rf "$TMPDIR"; }
trap cleanup EXIT

SCALE_FILTER="fps=${FPS},scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black"

extract_part() {
  local input="$1" partdir="$2"
  mkdir -p "$partdir"
  ffmpeg -y -loglevel error -i "$input" -vf "$SCALE_FILTER" "$partdir/%04d.png"
  local count
  count=$(find "$partdir" -name '*.png' | wc -l | tr -d ' ')
  echo "  -> $count frames in $(basename "$partdir")"
}

echo "Extracting frames..."
if [[ -n "$INTRO_INPUT" ]]; then
  extract_part "$INTRO_INPUT" "$TMPDIR/part0"
  extract_part "$MAIN_INPUT" "$TMPDIR/part1"
  cat > "$TMPDIR/desc.txt" <<EOF
${WIDTH} ${HEIGHT} ${FPS}
p 1 0 part0
p 0 0 part1
EOF
else
  extract_part "$MAIN_INPUT" "$TMPDIR/part0"
  cat > "$TMPDIR/desc.txt" <<EOF
${WIDTH} ${HEIGHT} ${FPS}
p 0 0 part0
EOF
fi

# ---------- pack zip (stored, frames added in sorted filename order) ----------
echo "Packing $OUTPUT..."
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT_ABS="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
rm -f "$OUTPUT_ABS"

PARTS=(desc.txt part0)
[[ -n "$INTRO_INPUT" ]] && PARTS+=(part1)

# zip -r alone doesn't guarantee files are stored in name order (it follows
# readdir() order, which can be arbitrary). Feed an explicitly sorted file
# list instead so frames always land in the zip in sequence.
(
  cd "$TMPDIR"
  for p in "${PARTS[@]}"; do find "$p" -type f; done | LC_ALL=C sort | zip -0 -q -X "$OUTPUT_ABS" -@
)

SIZE_MB=$(du -m "$OUTPUT_ABS" | cut -f1)
echo "Built $OUTPUT_ABS (${SIZE_MB} MB)"
if (( SIZE_MB > 50 )); then
  echo "Warning: ${SIZE_MB}MB is large for a bootanimation -- consider a lower fps/resolution/duration so it doesn't stretch boot time."
fi

# ---------- push to device ----------
if $DO_PUSH; then
  echo "Pushing to device at $DEVICE_PATH..."
  adb root
  adb remount
  adb push "$OUTPUT_ABS" "$DEVICE_PATH"
  if $DO_REBOOT; then
    echo "Rebooting device..."
    adb reboot
  else
    echo "Done. Run 'adb reboot' to see it."
  fi
fi