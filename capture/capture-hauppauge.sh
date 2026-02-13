#!/bin/bash

# --- 1. Dependency Check ---
MISSING_PKGS=()
type v4l2-ctl >/dev/null 2>&1 || MISSING_PKGS+=("v4l-utils")
type arecord  >/dev/null 2>&1 || MISSING_PKGS+=("alsa-utils")
type ffmpeg   >/dev/null 2>&1 || MISSING_PKGS+=("ffmpeg")
type ffplay   >/dev/null 2>&1 || MISSING_PKGS+=("ffmpeg (ffplay)")

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Error: Missing required tools: ${MISSING_PKGS[*]}"
    echo "Please run: sudo apt update && sudo apt install v4l-utils alsa-utils ffmpeg"
    exit 1
fi

# --- 2. Robust Hardware Detection ---
# Finds the video node specifically for Hauppauge hardware
VIDEO_DEV=$(v4l2-ctl --list-devices 2>/dev/null | grep -iA 5 "Hauppauge" | grep -o "/dev/video[0-9]\+" | head -n 1)

# Detects audio via the manufacturer name or the specific chipset driver
AUDIO_CARD=$(arecord -l 2>/dev/null | grep -iE "Hauppauge|Cx231xx" | head -n 1 | cut -d' ' -f2 | tr -d ':')

if [ -z "$VIDEO_DEV" ] || [ -z "$AUDIO_CARD" ]; then
    echo "Error: Hauppauge hardware not fully detected."
    echo "Video: ${VIDEO_DEV:-NOT FOUND} | Audio Card: ${AUDIO_CARD:-NOT FOUND}"
    exit 1
fi

AUDIO_DEV="hw:${AUDIO_CARD},0"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="vhs_capture_${TIMESTAMP}.mkv"

echo "--------------------------------------------------------"
echo "HAUPPAUGE CAPTURE SYSTEM"
echo "Detected: Video=$VIDEO_DEV | Audio=$AUDIO_DEV"
echo "--------------------------------------------------------"

# --- 3. Duration Prompt ---
echo "Enter duration (e.g., 10s, 5m, 1h) [default 10s]: "
read DUR_INPUT
DUR_VAL=${DUR_INPUT:-10s}

# --- 4. Hardware Initialization ---
v4l2-ctl -d "$VIDEO_DEV" -i 1 >/dev/null 2>&1  # Force S-Video
v4l2-ctl -d "$VIDEO_DEV" -s ntsc >/dev/null 2>&1 # Force NTSC

# --- 5. Action: Starting Combined Capture & Monitor ---
# Using rawvideo for master archive and NUT pipe for live monitoring
# Removed -nodb and -alwaysontop to avoid the ESM parsing errors
echo "ACTION: Starting Lossless FFV1 Capture for $DUR_VAL..."
echo "FILE:   $OUTPUT_FILE"
echo "EXIT:   Press 'q' in the monitor window to stop"
echo "--------------------------------------------------------"

# Using FFV1 version 3 for archival stability
ffmpeg -hide_banner -loglevel error \
       -f v4l2 -thread_queue_size 2048 -video_size 720x480 -i "$VIDEO_DEV" \
       -f alsa -thread_queue_size 2048 -i "$AUDIO_DEV" \
       -t "$DUR_VAL" \
       -c:v ffv1 -level 3 -coder 1 -context 1 -pix_fmt yuyv422 \
       -c:a pcm_s16le \
       -f tee -map 0:v -map 1:a \
       "$OUTPUT_FILE|[f=nut]pipe:1" | ffplay -i - -window_title "RECORDING MONITOR" -autoexit

# --- 6. Terminal Completion Alert ---
if [ -f "$OUTPUT_FILE" ]; then
    SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    
    # Visual and Audible Terminal Alert
    echo -e "\a" 
    echo "********************************************************"
    echo "             CAPTURE FINISHED SUCCESSFULLY             "
    echo "********************************************************"
    echo "FILE: $OUTPUT_FILE ($SIZE)"
    echo "NEXT: Run 'prepare_video.sh $OUTPUT_FILE'"
    echo "********************************************************"
else
    echo -e "\a"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "                ERROR: CAPTURE FAILED                  "
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi
