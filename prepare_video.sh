#!/bin/bash
# ==============================================================================
# Script Name: prepare_video.sh
# Description: Detects interlacing and saves a progressive master to outputs/.
# ==============================================================================
set -euo pipefail

# 1. Argument Check
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <source_video>"
    exit 1
fi

SOURCE_INPUT="$1"
BASE_NAME=$(basename "$SOURCE_INPUT")
FILE_STEM="${BASE_NAME%.*}"

# Force the output to the standard project outputs directory
OUTPUT_DIR="outputs"
mkdir -p "$OUTPUT_DIR"
PROG_OUTPUT="${OUTPUT_DIR}/${FILE_STEM}_progressive.mp4"

# 2. Run the Probe
echo "--- Step 1: Probing Video ---"
SCAN_RESULT=$(python3 probe_video.py "$SOURCE_INPUT")
echo "$SCAN_RESULT"

# 3. Decision Logic
if echo "$SCAN_RESULT" | grep -q "Interlaced"; then
    echo "--- Step 2: Deinterlacing Found ---"
    echo "Generating progressive master: $PROG_OUTPUT"
    
    # Using bwdif mode 0 to convert 29.97i to 29.97p without losing temporal sync
    ffmpeg -y -i "$SOURCE_INPUT" \
        -vf "bwdif=mode=0:parity=-1:deint=0" \
        -c:v libx264 -crf 17 -preset slow \
        -c:a copy \
        "$PROG_OUTPUT"
    
    echo -e "\n✅ Success! Use this file for your pipeline tests:"
    echo "   $PROG_OUTPUT"
else
    echo "--- Step 2: No Deinterlacing Needed ---"
    echo "Source is progressive. You can use $SOURCE_INPUT directly."
fi
