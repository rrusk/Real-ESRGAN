#!/bin/bash
# ==============================================================================
# Script Name: prepare_video.sh
# Description: Smart deinterlacing & mastering for AI-upscaling pipeline.
# Handles Raw VHS captures and digital files with dynamic detection.
# ==============================================================================
set -euo pipefail

# 0. Virtual Environment Guard ---
# Ensures consistent tool versions (ffmpeg, python)
if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    echo -e "\n[!] ERROR: Virtual environment not detected."
    echo "    This script must be run within the project venv to ensure"
    echo "    consistent tool versions and pathing."
    echo "    Run: source venv/bin/activate"
    exit 1
fi

# 1. Argument Check
if [ "$#" -eq 0 ] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "Usage: $0 <source_video> [mask_pixels] [--test]"
    echo ""
    echo "Arguments:"
    echo "  source_video    Path to the raw AVI, MPG, or MP4 file."
    echo "  mask_pixels     (Optional) Number of pixels to black out at the bottom (Default: 0)."
    echo "                  Use this to hide VHS head-switching noise."
    echo "  --test          (Optional) Process only the first 30s for quick mask review."

    echo ""
    echo "How to select mask_pixels:"
    echo "  1. Play your video in VLC and look at the bottom edge."
    echo "  2. If you see a flickering/static line, estimate its height."
    echo "  3. Typical values for Hi8/VHS are 8, 10, or 12 pixels."
    echo "  4. Leave blank or use 0 if the bottom edge is clean."
    exit 0
fi

if [ "$#" -gt 3 ]; then
    echo "Error: Too many arguments."
    echo "Usage: $0 <source_video> [mask_pixels]"
    exit 1
fi

SOURCE_INPUT="$1"
MASK_PIXELS=0
TEST_MODE=false

# Simple parsing to handle optional numeric mask and --test flag
for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
        MASK_PIXELS="$arg"
    elif [[ "$arg" == "--test" ]]; then
        TEST_MODE=true
    fi
done

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
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="outputs"
mkdir -p "$OUTPUT_DIR"

# Determine Output Name and Duration based on Mode
if [ "$TEST_MODE" = true ]; then
    PROG_OUTPUT="${OUTPUT_DIR}/${FILE_STEM}_mask${MASK_PIXELS}_TEST.mp4"
    LIMIT_CMD="-t 30"
    echo "--- TEST MODE ENABLED (30 Seconds) ---"
else
    PROG_OUTPUT="${OUTPUT_DIR}/${FILE_STEM}_mask${MASK_PIXELS}_${TIMESTAMP}.mp4"
    LIMIT_CMD=""
fi

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

# 4. Decision Logic (DYNAMIC UPDATE)
SCAN_TYPE=$(echo "$PROBE_LOG" | grep "Scan Type:" | awk -F': ' '{print $2}')

# Check for unrealistic duration to enable timestamp repair
FFLAGS=""
if echo "$PROBE_LOG" | grep -q "unrealistic"; then
    echo "Detected broken timestamps. Enabling PTS regeneration..."
    FFLAGS="-fflags +genpts"
fi

# Determine Parity based on Probe results
PARITY="-1" # Default Auto
if echo "$SCAN_TYPE" | grep -q "TFF"; then PARITY="0"; fi
if echo "$SCAN_TYPE" | grep -q "BFF"; then PARITY="1"; fi

if echo "$PROBE_LOG" | grep -q "Interlaced"; then
    echo -e "\n--- Step 2: High-Quality Deinterlacing ($SCAN_TYPE) ---"
    
    # Construct the filter chain based on whether masking is requested
    FILTER_CHAIN="bwdif=mode=0:parity=${PARITY}:deint=0,format=yuv420p"
    if [ "$MASK_PIXELS" -gt 0 ]; then
        echo "Applying mask: Bottom $MASK_PIXELS pixels"
        FILTER_CHAIN="${FILTER_CHAIN},drawbox=y=ih-${MASK_PIXELS}:h=${MASK_PIXELS}:color=black:t=fill"
    fi

    echo "Generating master: $PROG_OUTPUT"
    
    # Using bwdif mode 0 to convert 29.97i to 29.97p
    # -crf 16 and -preset slower for maximum data retention
    # format=yuv420p ensures compatibility for the AI models
    # -fflags +genpts added dynamically to fix broken durations
    # -c:a aac used because MP4 does not support uncompressed PCM
    ffmpeg -y $FFLAGS -i "$SOURCE_INPUT" $LIMIT_CMD \
        -vf "$FILTER_CHAIN" \
        -c:v libx264 -crf 16 -preset slower \
        -movflags +faststart \
        -c:a aac -b:a 192k \
        "$PROG_OUTPUT"
    
    echo -e "\n✅ Success! Deinterlaced Master Created: $PROG_OUTPUT"
else
    echo -e "\n--- Step 2: No Deinterlacing Needed ---"
    echo "Source is progressive. You can use $SOURCE_INPUT directly."
fi
