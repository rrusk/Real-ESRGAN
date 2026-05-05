#!/bin/bash
# ==============================================================================
# Script Name: avi_to_dv.sh
# Description: Converts a DV1 AVI file to a raw DV stream using stream copy
#              (no re-encode, no quality loss).  The raw .dv file seeks cleanly
#              in VLC and can be trimmed instantly with dd.
#
#              The original .avi file is left untouched.  Delete it manually
#              once the .dv output has been verified.
#
# Usage:
#   ./avi_to_dv.sh <input.avi> [output.dv]
#
# Arguments:
#   input.avi    Source DV1 AVI file.
#   output.dv    Optional. Defaults to <stem>.dv alongside input.
#
# Examples:
#   ./avi_to_dv.sh capture001.avi
#   ./avi_to_dv.sh capture001.avi /archive/capture001.dv
# ==============================================================================
set -euo pipefail

for cmd in ffmpeg gawk; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] Required: $cmd"; exit 1; }
done

if [[ $# -lt 1 || $# -gt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 <input.avi> [output.dv]"
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0 || exit 1
fi

INPUT="$1"

[[ -f "$INPUT" ]] || { echo "[ERROR] File not found: $INPUT"; exit 1; }

if [[ $# -eq 2 ]]; then
    OUTPUT="$2"
else
    dir=$(dirname "$INPUT")
    base=$(basename "$INPUT")
    OUTPUT="${dir}/${base%.*}.dv"
fi

[[ "$INPUT" -ef "$OUTPUT" ]] && { echo "[ERROR] Output is same file as input."; exit 1; }
[[ -e "$OUTPUT" ]] && { echo "[ERROR] Output already exists: $OUTPUT"; exit 1; }

echo "Input:    $INPUT"
echo "Output:   $OUTPUT"
echo "Started:  $(date)"

# -c copy: stream copy, no decode; preserves DV bitstream exactly.
# -f dv:   write a raw DV stream rather than an AVI container.
# -stats:  emit progress to stderr using \r to overwrite the line in place.
# -loglevel warning: suppress info messages; keep warnings and -stats output.
#
# gawk splits on \r (RS="\r") since ffmpeg's -stats lines are \r-terminated.
# Each \r record may contain \n-embedded sublines (e.g. a warning followed by
# a stats update), so we split on \n and process sublines individually.
stdbuf -eL ffmpeg -hide_banner -loglevel warning -stats \
    -i "$INPUT" \
    -c copy \
    -f dv \
    "$OUTPUT" 2>&1 | gawk '
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
echo "Finished: $(date)"
echo "Output:   $OUTPUT"
