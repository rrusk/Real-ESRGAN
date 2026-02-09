#!/bin/bash
# ==============================================================================
# Script Name: prepare_video.sh
# Description: Detects interlacing, checks data health, and saves a master.
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

# 2. Run the Probe and Capture Results
echo "--- Step 1: Probing Video ---"
# We capture the full output to display it and search for warnings
PROBE_LOG=$(python3 probe_video.py "$SOURCE_INPUT")
echo "$PROBE_LOG"

# 3. Data Health Warning
if echo "$PROBE_LOG" | grep -q "DATA WARNING"; then
    echo -e "\n[!] ATTENTION: Low bitrate detected."
    echo "    AI upscaling highly compressed video often results in 'blocky' artifacts."
    echo "    Proceeding, but recommend checking the 2x scale results carefully."
fi

# 4. Decision Logic
if echo "$PROBE_LOG" | grep -q "Interlaced"; then
    echo -e "\n--- Step 2: Deinterlacing Found ---"
    echo "Generating progressive master: $PROG_OUTPUT"
    
    # Using bwdif mode 0 to convert 29.97i to 29.97p
    # -crf 17 and -preset slow ensure no further quality loss
    ffmpeg -y -i "$SOURCE_INPUT" \
        -vf "bwdif=mode=0:parity=-1:deint=0" \
        -c:v libx264 -crf 17 -preset slow \
        -c:a copy \
        "$PROG_OUTPUT"
    
    echo -e "\n✅ Success! Use this file for your pipeline tests:"
    echo "   $PROG_OUTPUT"
else
    echo -e "\n--- Step 2: No Deinterlacing Needed ---"
    echo "Source is progressive. You can use $SOURCE_INPUT directly."
fi
