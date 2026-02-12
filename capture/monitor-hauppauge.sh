#!/bin/bash

# --- 1. Dependency Check ---
# Ensures the required Linux media and audio tools are installed
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
# Detect Video: Searches for the Hauppauge block and grabs the /dev/video node
VIDEO_DEV=$(v4l2-ctl --list-devices 2>/dev/null | grep -iA 5 "Hauppauge" | grep -o "/dev/video[0-9]\+" | head -n 1)

# Detect Audio: Searches for the driver name (Cx231xx) or manufacturer (Hauppauge)
AUDIO_CARD=$(arecord -l 2>/dev/null | grep -iE "Hauppauge|Cx231xx" | head -n 1 | cut -d' ' -f2 | tr -d ':')

# --- 3. Strict Exit Logic ---
# Exit if video hardware is missing
if [ -z "$VIDEO_DEV" ]; then
    echo "Error: Hauppauge video device not found. Is it plugged in?"
    exit 1
fi

# Exit if audio hardware is missing
if [ -z "$AUDIO_CARD" ]; then
    echo "Error: Hauppauge/Cx231xx audio hardware not found."
    echo "Run 'arecord -l' to verify the system sees the capture chip."
    exit 1
fi

AUDIO_DEV="hw:${AUDIO_CARD},0"
echo "Hardware Verified: Video=$VIDEO_DEV | Audio=$AUDIO_DEV"

# --- 4. Hardware Initialization ---
# Enforce S-Video (Input 1) and NTSC standard
v4l2-ctl -d "$VIDEO_DEV" -i 1 >/dev/null 2>&1
v4l2-ctl -d "$VIDEO_DEV" -s ntsc >/dev/null 2>&1

# --- 5. Launch Live Monitor ---
# Simple pipe to avoid ESM library and argument parsing errors
ffmpeg -hide_banner -loglevel error \
    -f v4l2 -i "$VIDEO_DEV" \
    -f alsa -i "$AUDIO_DEV" \
    -c:v copy -c:a copy -f nut - | ffplay -i -
