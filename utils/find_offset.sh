#!/bin/bash
# ==============================================================================
# Script Name: find_offset.sh
# Description: Automatically estimates the time offset between two video
#              captures of the same tape by locating matching audio peaks.
#
# Method:
#   Extracts a mono audio segment from each file within a search window,
#   then uses ffmpeg's astats filter to find the timestamp of the loudest
#   peak in each. The difference between the two peak timestamps is the
#   estimated alignment offset for use with compare_captures.sh.
#
# Inputs:
#   Pass the video files (mkv, mp4, avi) directly. Audio is extracted
#   internally — no need to provide separate .mka files.
#
# Best results:
#   - Works best with a sharp, distinctive transient: a hand clap, a door
#     slam, a laugh, or any sudden loud sound that appears in both captures.
#   - Avoid sections with continuous noise (music, wind, crowd) — a peak
#     in a noisy section may not correspond to the same event in both files.
#   - Use dual_vlc.sh first to find a rough region and approximate offset,
#     then pass that region as the search window (-s / -S / -d options).
#     The search windows should be positioned so that the same transient
#     event falls inside BOTH windows — offset them by your rough estimate.
#   - If the two captures have very different audio levels, the peaks will
#     still align as long as the same transient is the loudest event in
#     both search windows.
#
# Output:
#   Reports the peak timestamp in each file, the computed offset, and a
#   ready-to-run compare_captures.sh command using the input video files.
#
# Limitations:
#   - Audio peak detection is not frame-accurate. It finds the loudest
#     sample within the search window, which may be off by a few frames.
#   - For final frame-level fine-tuning, use compare_captures.sh with the
#     computed offset as a starting point and nudge by ±0.017s (1 frame).
#   - Requires Python 3 (used for floating point arithmetic).
# ==============================================================================
set -euo pipefail

# ==============================================================================
# Defaults
# ==============================================================================
L_START=0        # Search window start in LEFT file (seconds)
R_START=0        # Search window start in RIGHT file (seconds)
WINDOW=30        # Duration of audio to analyse (seconds)

usage() {
    echo ""
    echo "Usage: $0 [OPTIONS] <file_left> <file_right>"
    echo ""
    echo "  file_left    First video file (left input for compare_captures.sh)."
    echo "  file_right   Second video file (right input for compare_captures.sh)."
    echo ""
    echo "Options:"
    echo "  -s SECONDS   Start of search window in LEFT file  (default: 0)"
    echo "  -S SECONDS   Start of search window in RIGHT file (default: 0)"
    echo "  -d SECONDS   Duration of search window (default: 30)"
    echo ""
    echo "Examples:"
    echo "  Search the first 30 seconds of both files:"
    echo "    $0 old.mkv new.mkv"
    echo ""
    echo "  Known rough offset of ~8s, search around 1:00 in the left file:"
    echo "    $0 -s 55 -S 47 -d 20 old.mkv new.mkv"
    echo ""
    echo "Workflow:"
    echo "  1. Use dual_vlc.sh to find a region with a sharp loud sound"
    echo "     (clap, door slam, laugh) visible in both files."
    echo "  2. Note the approximate timestamp in each file and the rough offset."
    echo "  3. Run this script with -s / -S positioned so the same event falls"
    echo "     inside both search windows, e.g. if the event is at 1:00 in the"
    echo "     left file and 0:52 in the right, use -s 55 -S 47 -d 20."
    echo "  4. The suggested compare_captures.sh command can be run directly"
    echo "     to verify alignment visually with the wipe."
    echo "  5. Fine-tune the offset in compare_captures.sh with ±0.017s nudges."
    echo ""
    exit 1
}

if [ "$#" -lt 1 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
fi

# ==============================================================================
# 1. Argument Parsing
# ==============================================================================
while getopts "s:S:d:" opt; do
    case $opt in
        s) L_START="$OPTARG" ;;
        S) R_START="$OPTARG" ;;
        d) WINDOW="$OPTARG" ;;
        *)
            echo "[ERROR] Unknown option: -$OPTARG"
            usage
            ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -lt 2 ]; then
    echo "[ERROR] Two input files are required."
    usage
fi

LEFT_INPUT="$1"
RIGHT_INPUT="$2"

# ==============================================================================
# 2. Input Validation
# ==============================================================================
if [ ! -f "$LEFT_INPUT" ]; then
    echo "[ERROR] Left input file not found: $LEFT_INPUT"
    exit 1
fi
if [ ! -f "$RIGHT_INPUT" ]; then
    echo "[ERROR] Right input file not found: $RIGHT_INPUT"
    exit 1
fi

# ==============================================================================
# 3. Peak Detection
# ==============================================================================
# Extracts a mono audio segment and uses ffmpeg's astats filter to find the
# timestamp of the loudest peak within the search window.
#
# ametadata output format (confirmed on FFmpeg 4.4):
#   "frame:N    pts:N       pts_time:1.2345"
#   "lavfi.astats.Overall.Peak_level=-20.5"  (or -inf for silence)
#
# Metadata is written to a temp file to avoid stdout contention with
# ffmpeg's -f null muxer. All echo statements go to stderr so that only
# the final numeric result is captured by the $() command substitution.
# ==============================================================================

find_peak() {
    local FILE="$1"
    local START="$2"

    echo "  Analysing: $FILE" >&2
    echo "  Window: ${START}s to $((${START%.*} + ${WINDOW%.*}))s" >&2

    local TMPFILE
    TMPFILE=$(mktemp /tmp/find_offset_XXXXXX.txt)

    ffmpeg -ss "$START" -t "$WINDOW" -i "$FILE" \
        -af "aresample=44100,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.Peak_level:file=${TMPFILE}" \
        -vn -f null - 2>/dev/null

    local PEAK_TIME
    PEAK_TIME=$(awk '
        /pts_time:/ {
            split($0, a, "pts_time:")
            pts = a[2]
        }
        /lavfi.astats.Overall.Peak_level=/ {
            split($0, a, "=")
            val = a[2]
            if (val == "-inf") next
            val = val + 0
            if (!found || val > max_val) {
                max_val = val
                max_pts = pts
                found = 1
            }
        }
        END { if (found) print max_pts; else print "NOT_FOUND" }
    ' "$TMPFILE")

    rm -f "$TMPFILE"

    if [ -z "$PEAK_TIME" ] || [ "$PEAK_TIME" = "NOT_FOUND" ]; then
        echo "  [ERROR] No non-silent peak found in search window." >&2
        echo "  Try a different -s / -S / -d window containing a loud transient." >&2
        return 1
    fi

    # Peak time is relative to search window start — add start to get
    # absolute timestamp in the file.
    local ABS_TIME
    ABS_TIME=$(python3 -c "print(round(${START} + ${PEAK_TIME}, 3))")

    echo "  Peak at ${PEAK_TIME}s into window = ${ABS_TIME}s absolute" >&2
    echo "$ABS_TIME"
}

echo ""
echo "=== Audio Peak Alignment ==="
echo ""
echo "--- Analysing LEFT file ---"
LEFT_PEAK=$(find_peak "$LEFT_INPUT" "$L_START")
echo ""
echo "--- Analysing RIGHT file ---"
RIGHT_PEAK=$(find_peak "$RIGHT_INPUT" "$R_START")

# ==============================================================================
# 4. Offset Calculation
# ==============================================================================
LEAD_IN=2

LEFT_SEEK=$(python3 -c "v = ${LEFT_PEAK} - ${LEAD_IN}; print(round(max(0, v), 3))")
RIGHT_SEEK=$(python3 -c "v = ${RIGHT_PEAK} - ${LEAD_IN}; print(round(max(0, v), 3))")
OFFSET=$(python3 -c "print(round(${LEFT_PEAK} - ${RIGHT_PEAK}, 3))")
ABS_OFFSET=$(python3 -c "print(abs(round(${LEFT_PEAK} - ${RIGHT_PEAK}, 3)))")

LEFT_MM=$(python3 -c "t=int(${LEFT_PEAK}); print(f'{t//60}:{t%60:02d}')")
RIGHT_MM=$(python3 -c "t=int(${RIGHT_PEAK}); print(f'{t//60}:{t%60:02d}')")

echo ""
echo "=== Results ==="
echo ""
echo "  LEFT  peak at: ${LEFT_PEAK}s  (${LEFT_MM} in file)"
echo "  RIGHT peak at: ${RIGHT_PEAK}s  (${RIGHT_MM} in file)"
echo "  Computed offset (LEFT - RIGHT): ${OFFSET}s"
echo ""
echo "=== Suggested compare_captures.sh command ==="
echo ""
echo "  Seeks both clips to the matching peak with a ${LEAD_IN}s lead-in:"
echo ""
echo "  compare_captures.sh -w -t 10 -s ${LEFT_SEEK} -S ${RIGHT_SEEK} \\"
echo "    \"${LEFT_INPUT}\" \\"
echo "    \"${RIGHT_INPUT}\" \\"
echo "    offset_check.mp4"
echo ""
echo "  Verify alignment visually with the wipe, then fine-tune with"
echo "  ±0.017s nudges (1 frame at 59.94fps) as needed."
echo ""
echo "  To use this offset at any other point in the video, keep the"
echo "  difference between -s and -S fixed at ${ABS_OFFSET}s."
echo ""
