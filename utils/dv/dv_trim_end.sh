#!/bin/bash
# ==============================================================================
# Script Name: dv_trim_end.sh
# Description: Trims the end of a DV1 file at a specified time using stream
#              copy (no re-encode, no quality loss).
#
#              If the input is a DV1 AVI file it is automatically converted
#              to a raw .dv file first (original .avi is left untouched).
#
#              The original file is renamed to <stem>_original_TIMESTAMP.<ext>
#              and the
#              trimmed file takes the original filename.
#
# Usage:
#   ./dv_trim_end.sh <end_time> <input.dv>
#
# Arguments:
#   end_time   Where to stop, from the beginning of the file.
#              Accepts HH:MM:SS, MM:SS, or raw seconds (decimals ok).
#   input.dv   Source DV1 file.
#
# Examples:
#   ./dv_trim_end.sh 1:23:45 hi8_20011102.dv
#   ./dv_trim_end.sh 5025.3  hi8_20011102.dv
# ==============================================================================
set -euo pipefail

for cmd in ffmpeg gawk; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] Required: $cmd"; exit 1; }
done

if [[ $# -ne 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 <end_time> <input.dv>"
    echo "  end_time: HH:MM:SS, MM:SS, or seconds"
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0 || exit 1
fi

END_TIME="$1"
INPUT="$2"

[[ -f "$INPUT" ]] || { echo "[ERROR] File not found: $INPUT"; exit 1; }

# ------------------------------------------------------------------------------
# AVI input handling: if the input is an AVI file, verify it contains a DV
# stream and convert to raw .dv before trimming.  Raw .dv seeks cleanly in
# VLC; AVI remuxing via ffmpeg produces a larger file with a rebuilt index
# that VLC struggles to seek through.
#
# The converted .dv file takes the same stem as the AVI (different extension)
# so the original .avi is left untouched.  If a .dv already exists alongside
# the .avi the user must resolve the conflict manually.
# ------------------------------------------------------------------------------
ext="${INPUT##*.}"
if [[ "${ext,,}" == "avi" ]]; then
    # Verify the AVI contains a DV video stream before proceeding
    codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT")
    if [[ "$codec" != "dvvideo" ]]; then
        echo "[ERROR] $INPUT does not contain a DV stream (codec: ${codec:-unknown})."
        echo "        Only DV1/DV2 AVI files are supported."
        exit 1
    fi

    DV_INPUT="${INPUT%.*}.dv"
    if [[ -e "$DV_INPUT" ]]; then
        echo "[ERROR] Converted file already exists: $DV_INPUT"
        echo "        Remove or rename it before running this script."
        exit 1
    fi

    echo "AVI input detected -- converting to raw DV first..."
    echo "  Source: $INPUT"
    echo "  Output: $DV_INPUT"

    stdbuf -eL ffmpeg -hide_banner -loglevel warning -stats \
        -i "$INPUT" -c copy -f dv \
        "$DV_INPUT" 2>&1 | gawk '
        BEGIN { RS = "\r" }
        {
            n = split($0, sublines, "\n")
            for (i = 1; i <= n; i++) {
                line = sublines[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line == "") continue
                if (line ~ /^frame=/) { printf "\r  %s", line; fflush() }
                else { printf "\n  %s\n", line; fflush() }
            }
        }
    '
    echo ""
    echo "  Conversion complete."
    INPUT="$DV_INPUT"
fi

dir=$(dirname "$INPUT")
base=$(basename "$INPUT")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ORIGINAL="${dir}/${base%.*}_original_${TIMESTAMP}.${base##*.}"

# Write trimmed output to a temp name in the same directory, then rename
# atomically so INPUT always refers to a complete valid file.
TEMP="${dir}/${base%.*}_trimming.${base##*.}"

echo "Input:    $INPUT"
echo "End time: $END_TIME"
echo "Started:  $(date)"

# -c copy: stream copy, no decode; preserves DV quality exactly.
# -stats:  emit progress to stderr using \r to overwrite the line in place.
# -loglevel warning: suppress info messages; keep warnings and -stats output.
#
# gawk splits on \r (RS="\r") since ffmpeg's -stats lines are \r-terminated.
# Each \r record may contain \n-embedded sublines (e.g. a warning followed by
# a stats update), so we split on \n and process sublines individually.
stdbuf -eL ffmpeg -hide_banner -loglevel warning -stats \
    -i "$INPUT" \
    -t "$END_TIME" \
    -c copy \
    "$TEMP" 2>&1 | gawk '
    BEGIN { RS = "\r" }
    {
        n = split($0, sublines, "\n")
        for (i = 1; i <= n; i++) {
            line = sublines[i]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line == "") continue

            if (line ~ /^frame=/) {
                printf "\r  %s", line
                fflush()
            } else {
                printf "\n  %s\n", line
                fflush()
            }
        }
    }
'

echo ""

# Rename original, then promote trimmed file to take the original's name
mv "$INPUT" "$ORIGINAL"
mv "$TEMP" "$INPUT"

echo "Finished: $(date)"
echo "Trimmed:  $INPUT"
echo "Original: $ORIGINAL"
