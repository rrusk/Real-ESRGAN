#!/bin/bash
# ==============================================================================
# Script Name: prepare_video.sh
# Description: Detects interlacing, checks health, and generates a master.
# ==============================================================================
set -euo pipefail

# --- NEW: Virtual Environment Guard ---
if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    echo -e "\n[!] ERROR: Virtual environment not detected."
    echo "    This script must be run within the project venv to ensure"
    echo "    consistent tool versions and pathing."
    echo "    Run: source venv/bin/activate"
    exit 1
fi

# 1. Argument Check
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <source_video>"
    exit 1
fi

SOURCE_INPUT="$1"

# --- NEW: ISO Warning Guard ---
if [[ "${SOURCE_INPUT,,}" == *.iso ]]; then
    echo -e "\n[!] ERROR: Cannot process .ISO files directly."
    echo "    1. Mount the ISO (e.g., open it in your file manager)."
    echo "    2. Combine the VOBs: 'cat VIDEO_TS/VTS_01_*.VOB | ffmpeg -i - -c copy master.mpg'"
    echo "    3. Run this script on the resulting .mpg file."
    exit 1
fi

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
    echo -e "\n--- Step 2: High-Quality Deinterlacing ---"
    echo "Generating master: $PROG_OUTPUT"
    
    # Using bwdif mode 0 to convert 29.97i to 29.97p
    # -crf 16 and -preset slower for maximum data retention
    # format=yuv420p ensures compatibility for the AI models
    ffmpeg -y -i "$SOURCE_INPUT" \
        -vf "bwdif=mode=0:parity=-1:deint=0,format=yuv420p" \
        -c:v libx264 -crf 16 -preset slower \
        -movflags +faststart \
        -c:a copy \
        "$PROG_OUTPUT"
    
    echo -e "\n✅ Success! Use this for your pipeline: $PROG_OUTPUT"
else
    echo -e "\n--- Step 2: No Deinterlacing Needed ---"
    echo "Source is progressive. You can use $SOURCE_INPUT directly."
fi
