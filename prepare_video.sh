#!/bin/bash
# ==============================================================================
# Script Name: prepare_video.sh
# Description: Smart deinterlacing & mastering for AI-upscaling pipeline.
# Handles Raw VHS captures and digital files with dynamic detection.
# ==============================================================================
set -euo pipefail

# 0. Virtual Environment Guard ---
# Ensures consistent tool versions (ffmpeg, python) across the pipeline.
if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    echo -e "\n[!] ERROR: Virtual environment not detected."
    echo "    This script must be run within the project venv to ensure"
    echo "    consistent tool versions and pathing."
    echo "    Run: source venv/bin/activate"
#    exit 1
fi

# 1. Argument Check
# Validates input count and provides detailed help documentation.
if [ "$#" -eq 0 ] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "Usage: $0 <source_video> [mask_pixels] [--test] [--aac]"
    echo ""
    echo "Arguments:"
    echo "  source_video    Path to the raw AVI, MPG, or MP4 file."
    echo "  mask_pixels     (Optional) Number of pixels to black out at the bottom."
    echo "                  *** Use EVEN numbers (8, 10, 12) for best results. ***"
    echo "  --test          (Optional) Process only the first 30s for quick mask review."
    echo "  --aac           (Optional) Force AAC audio encoding even for compressed sources."

    echo ""
    echo "How to select mask_pixels:"
    echo "  1. Play your video in VLC and look at the bottom edge."
    echo "  2. If you see a flickering/static line (head-switching noise), estimate its height."
    echo "  3. Typical values for Hi8/VHS are 8, 10, or 12 pixels."
    echo "  4. CRITICAL: Always use an EVEN number to maintain YUV420p color alignment."
    exit 0
fi

# Strict argument limit check as per previous versions
if [ "$#" -gt 4 ]; then
    echo "Error: Too many arguments."
    echo "Usage: $0 <source_video> [mask_pixels] [--test] [--aac]"
    exit 1
fi

# Variable Initialization
SOURCE_INPUT="$1"
MASK_PIXELS=0
TEST_MODE=false
FORCE_AAC=false

# Simple parsing loop to handle optional numeric mask and named flags
for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
        MASK_PIXELS="$arg"
    elif [[ "$arg" == "--test" ]]; then
        TEST_MODE=true
    elif [[ "$arg" == "--aac" ]]; then
        FORCE_AAC=true
    fi
done

# Odd Number Sanity Check
# Prevents chroma artifacts caused by splitting 2x2 color blocks in YUV420p.
if (( MASK_PIXELS % 2 != 0 )); then
    echo -e "\n⚠️  WARNING: Mask ($MASK_PIXELS) is an odd number."
    echo "    This can cause green/purple lines due to YUV420p chroma alignment."
    echo "    Recommend using $((MASK_PIXELS + 1)) instead."
fi

# ISO Warning Guard
# Prevents ffmpeg from attempting to read raw disk images.
if [[ "${SOURCE_INPUT,,}" == *.iso ]]; then
    echo -e "\n[!] ERROR: Cannot process .ISO files directly."
    echo "    1. Mount the ISO (e.g., open it in your file manager)."
    echo "    2. Combine the VOBs: 'cat VIDEO_TS/VTS_01_*.VOB | ffmpeg -i - -c copy master.mpg'"
    echo "    3. Run this script on the resulting .mpg file."
    exit 1
fi

# Path and Filename Setup
BASE_NAME=$(basename "$SOURCE_INPUT")
FILE_STEM="${BASE_NAME%.*}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="outputs"
mkdir -p "$OUTPUT_DIR"

if [ "$TEST_MODE" = true ]; then
    PROG_OUTPUT="${OUTPUT_DIR}/${FILE_STEM}_mask${MASK_PIXELS}_TEST.mp4"
    LIMIT_CMD="-t 30"
    TEST_LABEL=" (TEST MODE: 30s)"
else
    PROG_OUTPUT="${OUTPUT_DIR}/${FILE_STEM}_mask${MASK_PIXELS}_${TIMESTAMP}.mp4"
    LIMIT_CMD=""
    TEST_LABEL=""
fi

# 2. Run the Probe and Capture Results
echo "--- Step 1: Probing Video ---"
# Utilizes external probe_video.py for deep metadata analysis.
PROBE_LOG=$(python3 probe_video.py "$SOURCE_INPUT")
echo "$PROBE_LOG"

# 3. Audio Strategy Detection
# Detects source codec and determines if re-encoding or bitstream copying is required.
AUDIO_FORMAT=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$SOURCE_INPUT")

if [[ "$FORCE_AAC" == true ]]; then
    AUDIO_CMD="-c:a aac -b:a 192k"
    AUDIO_PLAN="CONVERT (Forced AAC)"
elif [[ "$AUDIO_FORMAT" == pcm* ]]; then
    # MP4 containers require compressed audio; PCM must be transcoded.
    AUDIO_CMD="-c:a aac -b:a 192k"
    AUDIO_PLAN="CONVERT (PCM to AAC for MP4 compatibility)"
else
    # Preserves original compressed audio to maintain sync and quality.
    AUDIO_CMD="-c:a copy"
    AUDIO_PLAN="LOSSLESS (Bitstream copy of $AUDIO_FORMAT)"
fi

# 4. Decision Logic (Dynamic Handling of Field Order and Timestamps)
SCAN_TYPE=$(echo "$PROBE_LOG" | grep "Scan Type:" | awk -F': ' '{print $2}')

# PTS Regeneration if probe_video.py detects broken or unrealistic durations.
FFLAGS=""
if echo "$PROBE_LOG" | grep -q "unrealistic"; then
    echo "Detected broken timestamps. Enabling PTS regeneration..."
    FFLAGS="-fflags +genpts"
fi

# Determine Field Parity based on Probe results for bwdif filter.
PARITY="-1" # Default Auto
if echo "$SCAN_TYPE" | grep -q "TFF"; then PARITY="0"; fi
if echo "$SCAN_TYPE" | grep -q "BFF"; then PARITY="1"; fi

# 5. Pre-Flight Summary & Confirmation
# Summarizes both Video and Audio plans before committing to a long encode.
echo -e "\n========================================="
echo "       PRE-FLIGHT SUMMARY$TEST_LABEL"
echo "========================================="
echo "Source File:   $SOURCE_INPUT"
echo "Output File:   $PROG_OUTPUT"
echo "Audio Plan:    $AUDIO_PLAN"
echo "Bottom Mask:   ${MASK_PIXELS} pixels"

if echo "$PROBE_LOG" | grep -q "Interlaced"; then
    VIDEO_PLAN="HIGH-QUALITY DEINTERLACING (bwdif)"
    echo "Video Plan:    $VIDEO_PLAN"
    echo -e "\n⚠️  WARNING: Deinterlacing is a CPU-intensive process."
    echo "    Depending on video length, this will take quite awhile."
else
    VIDEO_PLAN="Progressive Copy (No deinterlacing needed)"
    echo "Video Plan:    $VIDEO_PLAN"
fi
echo "========================================="

read -p "Do you wish to begin? (y/n): " -n 1 -r
echo # Move to a new line
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled by user."
    exit 0
fi

# 6. Processing
if echo "$PROBE_LOG" | grep -q "Interlaced"; then
    echo -e "\n--- Step 2: High-Quality Deinterlacing ($SCAN_TYPE) ---"
    
    # Filter Chain: bwdif mode=0 (29.97i -> 29.97p), yuv420p format, and optional drawbox.
    FILTER_CHAIN="bwdif=mode=0:parity=${PARITY}:deint=0,format=yuv420p"
    if [ "$MASK_PIXELS" -gt 0 ]; then
        echo "Applying mask: Bottom $MASK_PIXELS pixels"
        FILTER_CHAIN="${FILTER_CHAIN},drawbox=y=ih-${MASK_PIXELS}:h=${MASK_PIXELS}:color=black:t=fill"
    fi

    echo "Generating master: $PROG_OUTPUT"
    
    # -crf 16 and -preset slower prioritize data retention for the subsequent AI upscale.
    # -field_order progressive prevents subsequent probe hits for interlaced metadata.
    ffmpeg -y $FFLAGS -i "$SOURCE_INPUT" $LIMIT_CMD \
        -vf "$FILTER_CHAIN" \
        -c:v libx264 -threads 8 -crf 16 -preset slower \
        -field_order progressive \
        -movflags +faststart \
        $AUDIO_CMD \
        "$PROG_OUTPUT"
    
    echo -e "\n✅ Success! Deinterlaced Master Created: $PROG_OUTPUT"
else
    echo -e "\n--- Step 2: No Deinterlacing Needed ---"
    echo "Source is progressive. You can use $SOURCE_INPUT directly."
fi
