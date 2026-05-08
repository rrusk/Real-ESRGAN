#!/bin/bash
# ==============================================================================
# Script Name: trim_dv.sh
# Description: Trims a DV1 file to a specified end time using stream copy
#              (no re-encode, no quality loss).
#
#              Output is written to a new file; the original is never modified.
#
# Usage:
#   ./trim_dv.sh <end_time> <input.dv> [output.dv]
#
# Arguments:
#   end_time     Where to stop, from the beginning of the file.
#                Accepts HH:MM:SS, MM:SS, or raw seconds (decimals ok).
#   input.dv     Source DV1 file.
#   output.dv    Optional. Defaults to <stem>_trimmed.<ext> alongside input.
#
# Examples:
#   ./trim_dv.sh 1:23:45 hi8_20011102.dv
#   ./trim_dv.sh 1:23:45 hi8_20011102.dv hi8_clean.dv
#   ./trim_dv.sh 5025.3  hi8_20011102.dv
# ==============================================================================
set -euo pipefail

command -v ffmpeg >/dev/null 2>&1 || { echo "[ERROR] ffmpeg not found."; exit 1; }

if [[ $# -lt 2 || $# -gt 3 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 <end_time> <input.dv> [output.dv]"
    echo "  end_time: HH:MM:SS, MM:SS, or seconds"
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0 || exit 1
fi

END_TIME="$1"
INPUT="$2"

[[ -f "$INPUT" ]] || { echo "[ERROR] File not found: $INPUT"; exit 1; }

if [[ $# -eq 3 ]]; then
    OUTPUT="$3"
else
    dir=$(dirname "$INPUT")
    base=$(basename "$INPUT")
    OUTPUT="${dir}/${base%.*}_trimmed.${base##*.}"
fi

[[ "$INPUT" -ef "$OUTPUT" ]] && { echo "[ERROR] Output is same file as input."; exit 1; }

echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "End time: $END_TIME"
echo "Started:  $(date)"

# -c copy: stream copy, no decode; preserves DV quality exactly.
# -stats:  emit progress to stderr using \r to overwrite the line in place.
# -loglevel warning: suppress info messages; keep warnings and -stats output.
#
# ffmpeg's -stats output uses \r (not \n) to overwrite the progress line in
# place in the terminal.  awk must use RS="\r" to split on carriage returns,
# otherwise the entire progress stream arrives as one giant record.
# stdbuf -eL ensures stderr is line-buffered so \r-records reach awk promptly.
#
# awk behaviour:
#   - Records starting with "frame=" are the stats line: reprint in place.
#   - Anything else (warnings, errors) is printed on its own line.
stdbuf -eL ffmpeg -hide_banner -loglevel warning -stats \
    -i "$INPUT" \
    -t "$END_TIME" \
    -c copy \
    "$OUTPUT" 2>&1 | awk '
    BEGIN { RS = "\r" }
    /^frame=/ {
        printf "\r  %s", $0
        fflush()
        next
    }
    /^[[:space:]]*$/ { next }
    {
        # Warning or error: move past the progress line first, then print
        printf "\n  %s\n", $0
        fflush()
    }
'

echo ""
echo "Finished: $(date)"
