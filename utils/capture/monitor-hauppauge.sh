#!/usr/bin/env bash
# monitor-hauppauge.sh
# Usage: monitor-hauppauge.sh [--svideo|--composite]
#
# Opens a live monitor window from the Hauppauge 610 USB device.
# If neither --svideo nor --composite is given, prompts interactively.
#
# Options:
#   --svideo      Use S-Video input    (Hauppauge input 1)
#   --composite   Use Composite input  (Hauppauge input 0)

set -euo pipefail

# --- 1. Argument Parsing ---
INPUT_NUM=""
INPUT_LABEL=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --svideo)
            INPUT_NUM=1
            INPUT_LABEL="S-Video"
            shift
            ;;
        --composite)
            INPUT_NUM=0
            INPUT_LABEL="Composite"
            shift
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Usage: $0 [--svideo|--composite]"
            exit 1
            ;;
    esac
done

# --- 2. Dependency Check ---
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

# --- 3. Robust Hardware Detection ---
# Detect Video: Searches for the Hauppauge block and grabs the /dev/video node
VIDEO_DEV=$(v4l2-ctl --list-devices 2>/dev/null | grep -iA 5 "Hauppauge" | grep -o "/dev/video[0-9]\+" | head -n 1)

# Detect Audio: Searches for the driver name (Cx231xx) or manufacturer (Hauppauge)
AUDIO_CARD=$(arecord -l 2>/dev/null | grep -iE "Hauppauge|Cx231xx" | head -n 1 | cut -d' ' -f2 | tr -d ':')

# --- 4. Strict Exit Logic ---
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

# --- 5. Hardware Initialization ---
AUDIO_DEV="hw:${AUDIO_CARD},0"
echo "Hardware Verified: Video=$VIDEO_DEV | Audio=$AUDIO_DEV"

# If input was not specified on the command line, prompt interactively.
if [[ -z "$INPUT_NUM" ]]; then
    echo "Select video input:"
    echo "  1) S-Video    (use when VCR has a separate S-Video output)"
    echo "  2) Composite  (use when VCR has only composite, or S-Video clips)"
    printf "Choice [1/2]: "
    local_choice=""
    read -r local_choice </dev/tty
    case "$local_choice" in
        1) INPUT_NUM=1; INPUT_LABEL="S-Video"    ;;
        2) INPUT_NUM=0; INPUT_LABEL="Composite"  ;;
        *)
            echo "Error: please enter 1 for S-Video or 2 for Composite."
            exit 1
            ;;
    esac
    echo ""
fi

echo "Input:      ${INPUT_LABEL} (V4L2 input ${INPUT_NUM})"

# Set selected input and enforce NTSC standard.
v4l2-ctl -d "$VIDEO_DEV" -i "$INPUT_NUM" >/dev/null 2>&1
v4l2-ctl -d "$VIDEO_DEV" -s ntsc >/dev/null 2>&1

# --- 6. Launch Live Monitor ---
# Simple pipe to avoid ESM library and argument parsing errors
ffmpeg -hide_banner -loglevel error \
    -f v4l2 -i "$VIDEO_DEV" \
    -f alsa -i "$AUDIO_DEV" \
    -c:v copy -c:a copy -f nut - | ffplay -i -
