#!/bin/bash
# ==============================================================================
# Script Name: lossless_remux.sh
# Description: Losslessly converts MKV to MP4 by remuxing streams.
#              Fails if the codecs are not supported by the MP4 container.
# ==============================================================================

set -euo pipefail

# 1. Dependency and Argument Check
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    echo "Error: ffmpeg and ffprobe are required."
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <input_file.mkv>"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="${INPUT_FILE%.*}.mp4"

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: File '$INPUT_FILE' not found."
    exit 1
fi

echo "--- Analyzing Codecs for Lossless Conversion ---"

# 2. Extract Codec Names
# We check the first video and first audio stream for standard MP4 compatibility.
V_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE")
A_CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE")

echo "Video: $V_CODEC"
echo "Audio: $A_CODEC"

# 3. Compatibility Logic
# Common MP4-compatible video: h264 (AVC), h265 (HEVC), mpeg4
# Common MP4-compatible audio: aac, mp3, ac3
CAN_REMUX=true
REASON=""

if [[ ! "$V_CODEC" =~ ^(h264|hevc|mpeg4)$ ]]; then
    CAN_REMUX=false
    REASON+="Video codec '$V_CODEC' is not natively supported by standard MP4 containers for lossless copy.\n"
fi

if [[ ! "$A_CODEC" =~ ^(aac|mp3|ac3)$ ]]; then
    CAN_REMUX=false
    REASON+="Audio codec '$A_CODEC' is often problematic or unsupported for lossless remuxing into MP4.\n"
fi

# 4. Action
if [ "$CAN_REMUX" = false ]; then
    echo -e "\n[!] CANNOT CONVERT LOSSLESSLY"
    echo -e "$REASON"
    echo "Exiting to prevent quality loss from re-encoding."
    exit 1
else
    echo -e "\n--- Starting Lossless Remux ---"
    # -map 0 ensures we bring all streams (if compatible)
    # -movflags +faststart optimizes for web streaming
    ffmpeg -i "$INPUT_FILE" -map 0 -c copy -movflags +faststart "$OUTPUT_FILE"
    
    echo -e "\n✅ Success! Remuxed file created: $OUTPUT_FILE"
fi
