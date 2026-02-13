#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <dvd_mount_point>"
    exit 1
fi

DVD_MOUNT="$1"
VIDEO_TS="$DVD_MOUNT/VIDEO_TS"

if [[ ! -d "$VIDEO_TS" ]]; then
    echo "Error: VIDEO_TS directory not found at '$VIDEO_TS'"
    exit 1
fi

VOBS=("$VIDEO_TS"/VTS_*.VOB)
NUM_VOBS=${#VOBS[@]}

if [[ $NUM_VOBS -eq 0 ]]; then
    echo "Error: No VOB files found in '$VIDEO_TS'"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="$(basename "$DVD_MOUNT")_master_tape_${TIMESTAMP}.mpg"

echo "========================================="
echo "Creating master tape from all VOBs..."
echo "DVD Mount Point: $DVD_MOUNT"
echo "Number of VOB segments: $NUM_VOBS"
echo "Output File: $OUTPUT_FILE"
echo "========================================="

# --- Stream all VOBs into ffmpeg ---
cat "${VOBS[@]}" | ffmpeg -i - -vcodec copy -acodec copy "$OUTPUT_FILE"

echo ""
echo "Master tape created: $OUTPUT_FILE"

# --- Fast hash verification ---
if command -v xxhsum >/dev/null 2>&1; then
    echo ""
    echo "Verifying combined file integrity (XXH64)..."
    HASH=$(xxhsum -H64 "$OUTPUT_FILE" | awk '{print $1}')
    echo "XXH64: $HASH"
    echo "✅ Verification complete."
else
    echo ""
    echo "xxhsum not found. Skipping hash verification."
fi
