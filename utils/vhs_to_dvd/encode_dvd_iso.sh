#!/bin/bash

set -e

# ==========================================================
# encode_dvd_v8_iso.sh
# One-pass DVD ISO creation with chapters
#
# Optimized for:
# Sony DCR-TRV330 DV passthrough capture
#
# Output:
# - DVD-compliant ISO with working chapters
# ==========================================================

INPUT="$1"

if [[ -z "$INPUT" ]]; then
    echo "Usage: $0 input_video [options]"
    echo ""
    echo "Options:"
    echo "  --chapters N            Target number of chapters (used for time-based fallback)"
    echo "  --head-switch-pixels N  Pixels to mask at bottom for head-switching noise (default: 8, must be even)"
    echo "  --scene-threshold N     Scene cut sensitivity 0.0-1.0 (default: 0.40; lower = more sensitive)"
    echo "  --start-time TIME       Trim: start time (e.g. 00:00:05 or 5)"
    echo "  --end-time TIME         Trim: end time (e.g. 01:02:30 or 3750)"
    echo "  --force                 Overwrite existing output files without prompting"
    exit 1
fi

shift

# ==============================
# PARSE OPTIONAL ARGS
# ==============================
TARGET_CHAPTERS=""
HEAD_SWITCH_PIXELS=8
SCENE_THRESHOLD="0.40"
START_TIME=""
END_TIME=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chapters)
            TARGET_CHAPTERS="$2"; shift 2 ;;
        --head-switch-pixels)
            HEAD_SWITCH_PIXELS="$2"; shift 2 ;;
        --scene-threshold)
            SCENE_THRESHOLD="$2"; shift 2 ;;
        --start-time)
            START_TIME="$2"; shift 2 ;;
        --end-time)
            END_TIME="$2"; shift 2 ;;
        --force)
            FORCE=true; shift ;;
        *)
            echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate head-switch pixel count
if (( HEAD_SWITCH_PIXELS % 2 != 0 )); then
    echo "Error: --head-switch-pixels must be an even number (got: $HEAD_SWITCH_PIXELS)"
    exit 1
fi

# ==============================
# CONFIG
# ==============================
MODE="HQ"
CHAPTER_MODE="HYBRID"     # SCENE | TIME | HYBRID
MIN_CHAPTER_GAP=240       # seconds; used when TARGET_CHAPTERS is not set

OUTPUT="${INPUT%.*}_dvd.vob"
DVD_DIR="${INPUT%.*}_dvd"
ISO_OUT="${INPUT%.*}.iso"

# ==============================
# DEPENDENCY CHECK
# ==============================
check_dep() {
    if ! command -v "$1" &>/dev/null; then
        echo "[ERROR] Required tool not found: $1"
        echo "        Install with: $2"
        exit 1
    fi
}

check_dep ffmpeg   "sudo apt install ffmpeg"
check_dep ffprobe  "sudo apt install ffmpeg"
check_dep bc       "sudo apt install bc"
check_dep dvdauthor "sudo apt install dvdauthor"
check_dep genisoimage "sudo apt install genisoimage"

echo "→ All dependencies found."

# ==============================
# OUTPUT OVERWRITE CHECK
# ==============================
confirm_overwrite() {
    local FILE="$1"
    if [[ -e "$FILE" ]]; then
        if [[ "$FORCE" == true ]]; then
            echo "→ --force: overwriting $FILE"
        else
            read -r -p "Output already exists: $FILE — overwrite? [y/N] " REPLY
            if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
                echo "Aborting. Use --force to overwrite without prompting."
                exit 1
            fi
        fi
    fi
}

confirm_overwrite "$OUTPUT"
confirm_overwrite "$ISO_OUT"

# ==============================
echo "=== PROBE ==="
ffprobe -hide_banner "$INPUT"

# ==============================
# Trim flags
# ==============================
TRIM_INPUT_FLAGS=""
TRIM_OUTPUT_FLAGS=""

if [[ -n "$START_TIME" ]]; then
    TRIM_INPUT_FLAGS="-ss $START_TIME"
fi
if [[ -n "$END_TIME" ]]; then
    TRIM_OUTPUT_FLAGS="-to $END_TIME"
fi

# ==============================
# Effective duration (after trim)
# ==============================
RAW_DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$INPUT")

# Convert START_TIME / END_TIME to seconds for arithmetic
to_seconds() {
    local T="$1"
    if [[ "$T" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$T"
    else
        # HH:MM:SS or MM:SS
        echo "$T" | awk -F: '{ if (NF==3) print ($1*3600)+($2*60)+$3; else print ($1*60)+$2 }'
    fi
}

START_SEC=0
END_SEC=$RAW_DURATION

if [[ -n "$START_TIME" ]]; then
    START_SEC=$(to_seconds "$START_TIME")
fi
if [[ -n "$END_TIME" ]]; then
    END_SEC=$(to_seconds "$END_TIME")
fi

DURATION=$(echo "$END_SEC - $START_SEC" | bc -l)

echo "→ Effective duration: ${DURATION}s"

# ==============================
# Aspect ratio (SAR)
# ==============================
# Read sample_aspect_ratio directly — more reliable than display_aspect_ratio
# for DV sources, which often report DAR inconsistently or as N/A.
# Common NTSC DV values:
#   4:3  -> SAR 8:9   (720x480 -> display 640x480)
#   16:9 -> SAR 32:27 (720x480 -> display 853x480)
RAW_SAR=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=sample_aspect_ratio \
  -of default=noprint_wrappers=1:nokey=1 "$INPUT")

# Normalise separator: ffprobe returns "8:9", setsar wants "8/9"
if [[ -z "$RAW_SAR" || "$RAW_SAR" == "N/A" || "$RAW_SAR" == "0:1" || "$RAW_SAR" == "1:1" ]]; then
    # No SAR or square pixels — default to NTSC 4:3 DV
    SAR="8/9"
    echo "→ SAR: not set in source, defaulting to 8/9 (NTSC 4:3 DV)"
else
    SAR="${RAW_SAR/:/\/}"
    echo "→ SAR: $RAW_SAR (from source)"
fi

# ==============================
# Interlace detection
# ==============================
# -ss before -i for fast input seek; -t limits to the trimmed window.
# (-to is output-position relative, -t is duration relative — safer here.)
IDET_DURATION_FLAG=""
if [[ -n "$START_TIME" || -n "$END_TIME" ]]; then
    IDET_DURATION_FLAG="-t $(printf "%.0f" "$DURATION")"
fi

IDET_LOG=$(ffmpeg $TRIM_INPUT_FLAGS -i "$INPUT" $IDET_DURATION_FLAG \
  -vf idet -frames:v 500 -an -f rawvideo -y /dev/null 2>&1)

TFF=$(echo "$IDET_LOG" | grep -oP 'TFF:\s*\K[0-9]+' | head -1)
BFF=$(echo "$IDET_LOG" | grep -oP 'BFF:\s*\K[0-9]+' | head -1)
PROG=$(echo "$IDET_LOG" | grep -oP 'Progressive:\s*\K[0-9]+' | head -1)

# Default to 0 if grep found nothing — prevents silent arithmetic failures.
# If all three are 0 (e.g. idet produced no output), we keep INTERLACED=true
# and FIELD_ORDER=bff — NTSC DV is bottom field first per IEC 61834, so this
# is the correct safe default for any TRV330 capture.
TFF=${TFF:-0}
BFF=${BFF:-0}
PROG=${PROG:-0}

FIELD_ORDER="bff"
INTERLACED=true

if (( PROG > BFF && PROG > TFF )); then
    INTERLACED=false
elif (( TFF > BFF )); then
    FIELD_ORDER="tff"
fi

# ==============================
# Duration guard
# ==============================
if (( $(echo "$DURATION <= 0" | bc -l) )); then
    echo "[ERROR] Effective duration is zero or negative — check --start-time / --end-time values."
    exit 1
fi

# Integer copy for use in shell arithmetic (avoids bc in loops)
DURATION_INT=$(printf "%.0f" "$DURATION")

# ==============================
# Dynamic bitrate ceiling
# ==============================
# Single-sided DVD capacity: 4,700,000,000 bytes = 37,600,000,000 bits
# Reserve audio: 192,000 bps * duration
# Reserve DVD overhead: ~3% of total capacity
# Remaining bits / duration = max video bitrate
# Clamp to [2000k, 8000k] per DVD spec

DVD_CAPACITY_BITS=37600000000
OVERHEAD_FRACTION=0.03
AUDIO_BITRATE_BPS=192000

MAX_VIDEO_BPS=$(echo "
    scale=0;
    available = $DVD_CAPACITY_BITS * (1 - $OVERHEAD_FRACTION) - ($AUDIO_BITRATE_BPS * $DURATION);
    bps = available / $DURATION;
    if (bps > 8000000) bps = 8000000;
    if (bps < 2000000) bps = 2000000;
    bps / 1000
" | bc)

BITRATE="${MAX_VIDEO_BPS}k"
MAXRATE="8000k"

echo "→ Calculated video bitrate: $BITRATE (duration: ${DURATION}s)"

# ==============================
# Filters
# ==============================
# Head-switching noise mask: drawbox covers bottom N pixels in black
# y coordinate = 480 - HEAD_SWITCH_PIXELS (post-scale, so always correct)
HEAD_SWITCH_Y=$((480 - HEAD_SWITCH_PIXELS))
DRAWBOX="drawbox=x=0:y=${HEAD_SWITCH_Y}:w=iw:h=${HEAD_SWITCH_PIXELS}:color=black:t=fill"

BASE_FILTER="scale=720:480:flags=lanczos,setsar=${SAR},format=yuv420p"

case "$MODE" in
    FAST)    FILTER_CHAIN="$BASE_FILTER,$DRAWBOX" ;;
    HQ)      FILTER_CHAIN="hqdn3d=2:1:2:1,unsharp=5:5:0.5:3:3:0.3,$BASE_FILTER,$DRAWBOX" ;;
    ARCHIVE) FILTER_CHAIN="hqdn3d=3:2:3:2,$BASE_FILTER,$DRAWBOX" ;;
esac

echo "→ Head-switch mask: ${HEAD_SWITCH_PIXELS}px from bottom"

# ==============================
# Field flags
# ==============================
FIELD_FLAGS=""
if [[ "$INTERLACED" = true ]]; then
    if [[ "$FIELD_ORDER" == "tff" ]]; then
        FIELD_FLAGS="-flags +ildct+ilme -top 1"
    else
        FIELD_FLAGS="-flags +ildct+ilme -top 0"
    fi
fi

# ==============================
# ENCODE
# ==============================
echo "=== ENCODING ==="

ffmpeg $TRIM_INPUT_FLAGS -i "$INPUT" $TRIM_OUTPUT_FLAGS \
  -vf "$FILTER_CHAIN" \
  -r 30000/1001 \
  -c:v mpeg2video \
  -pix_fmt yuv420p \
  $FIELD_FLAGS \
  -g 15 \
  -bf 2 \
  -b:v "$BITRATE" \
  -maxrate "$MAXRATE" \
  -bufsize 1835k \
  -c:a ac3 \
  -b:a 192k \
  -ar 48000 \
  -ac 2 \
  -af aresample=async=1 \
  -f dvd \
  "$OUTPUT"

# ==============================
# CHAPTER GENERATION
# ==============================
echo "=== CHAPTERS ==="

# Derive time chapter interval from target chapter count if provided
if [[ -n "$TARGET_CHAPTERS" ]] && (( TARGET_CHAPTERS > 1 )); then
    TIME_CHAPTER_INTERVAL=$(( DURATION_INT / TARGET_CHAPTERS ))
    echo "→ Target chapters: $TARGET_CHAPTERS → interval: ${TIME_CHAPTER_INTERVAL}s"
else
    TIME_CHAPTER_INTERVAL=600
fi

generate_scene_times() {
    TMP=$(mktemp)

    ffmpeg $TRIM_INPUT_FLAGS -i "$INPUT" $IDET_DURATION_FLAG \
      -filter:v "select='gt(scene,${SCENE_THRESHOLD})',showinfo" \
      -vsync vfr -f null - 2>&1 | \
      grep pts_time | \
      grep -oP 'pts_time:\K[0-9\.]+' > "$TMP"

    LAST=0
    TIMES="0"

    # Use TARGET_CHAPTERS-derived gap if available, else MIN_CHAPTER_GAP
    if [[ -n "$TARGET_CHAPTERS" ]] && (( TARGET_CHAPTERS > 1 )); then
        EFFECTIVE_GAP=$(( DURATION_INT / TARGET_CHAPTERS ))
    else
        EFFECTIVE_GAP=$MIN_CHAPTER_GAP
    fi

    while read TIME; do
        if (( $(echo "$TIME - $LAST > $EFFECTIVE_GAP" | bc -l) )); then
            SEC=$(printf "%.0f" "$TIME")
            TIMES="$TIMES,$SEC"
            LAST=$TIME
        fi
    done < "$TMP"

    rm "$TMP"
    echo "$TIMES"
}

generate_time_times() {
    TIMES="0"
    i=$TIME_CHAPTER_INTERVAL

    while (( i < DURATION_INT )); do
        TIMES="$TIMES,$i"
        i=$(( i + TIME_CHAPTER_INTERVAL ))
    done

    echo "$TIMES"
}

if [[ "$CHAPTER_MODE" == "SCENE" ]]; then
    CHAPTER_TIMES=$(generate_scene_times)
elif [[ "$CHAPTER_MODE" == "TIME" ]]; then
    CHAPTER_TIMES=$(generate_time_times)
else
    CHAPTER_TIMES=$(generate_scene_times)

    COUNT=$(echo "$CHAPTER_TIMES" | tr -cd ',' | wc -c)

    if (( COUNT < 2 )); then
        echo "→ Fallback to time-based chapters"
        CHAPTER_TIMES=$(generate_time_times)
    fi
fi

echo "→ Chapter times: $CHAPTER_TIMES"

# ==============================
# AUTHOR DVD + ISO
# ==============================
echo "=== AUTHORING DVD ==="

rm -rf "$DVD_DIR"
mkdir -p "$DVD_DIR"

VIDEO_FORMAT=NTSC dvdauthor -o "$DVD_DIR" -t -c "$CHAPTER_TIMES" "$OUTPUT"
VIDEO_FORMAT=NTSC dvdauthor -o "$DVD_DIR" -T

echo "=== CREATING ISO ==="

# Derive a volume label from the input filename stem.
# ISO 9660 labels: max 32 chars, uppercase, no spaces.
VOL_LABEL=$(echo "${INPUT%.*}" | xargs basename | tr '[:lower:]' '[:upper:]' | tr ' ' '_' | cut -c1-32)

genisoimage -dvd-video -V "$VOL_LABEL" -o "$ISO_OUT" "$DVD_DIR"

echo "=== CLEANING UP ==="
rm -f "$OUTPUT"
rm -rf "$DVD_DIR"
echo "→ Removed: $OUTPUT"
echo "→ Removed: $DVD_DIR"

echo
echo "=== DONE ==="
echo "ISO ready: $ISO_OUT"
