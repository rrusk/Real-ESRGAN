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

    echo -e "\n✅ Remux complete: $OUTPUT_FILE"

    # --- SAR / Display Aspect Ratio Fix ---
    # Read SAR from the source MKV. Non-square pixels are common in legacy video:
    #   NTSC 4:3  (VHS/Hi8/DV):      SAR 8:9   (720x480 -> display 640x480)
    #   NTSC 16:9 (widescreen DV):   SAR 32:27 (720x480 -> display 853x480)
    #   PAL 4:3   (PAL DV/Hi8):      SAR 16:15 (720x576 -> display 768x576)
    #   PAL 16:9  (PAL widescreen):  SAR 64:45 (720x576 -> display 1024x576)
    SAR=$(ffprobe -v error -select_streams v:0         -show_entries stream=sample_aspect_ratio         -of default=noprint_wrappers=1:nokey=1 "$OUTPUT_FILE")

    if [[ -z "$SAR" || "$SAR" == "N/A" || "$SAR" == "0:1" || "$SAR" == "1:1" ]]; then
        echo "SAR is square (1:1) or not set — no display correction needed."
    else
        SAR_NUM=$(echo "$SAR" | cut -d: -f1)
        SAR_DEN=$(echo "$SAR" | cut -d: -f2)
        PIX_WIDTH=$(ffprobe -v error -select_streams v:0             -show_entries stream=width             -of default=noprint_wrappers=1:nokey=1 "$OUTPUT_FILE")
        PIX_HEIGHT=$(ffprobe -v error -select_streams v:0             -show_entries stream=height             -of default=noprint_wrappers=1:nokey=1 "$OUTPUT_FILE")
        DISPLAY_WIDTH=$(python3 -c "print(round($PIX_WIDTH * $SAR_NUM / $SAR_DEN))")

        echo "Source SAR: $SAR — applying PAR $SAR_NUM:$SAR_DEN to MP4 container..."
        echo "  Pixel: ${PIX_WIDTH}x${PIX_HEIGHT} -> Display: ${DISPLAY_WIDTH}x${PIX_HEIGHT}"

        if ! command -v MP4Box >/dev/null 2>&1; then
            echo "⚠️  WARNING: MP4Box not found. Install with: sudo apt install gpac"
            echo "⚠️  Display aspect ratio not corrected in $OUTPUT_FILE"
        else
            MP4Box -par "1=${SAR_NUM}:${SAR_DEN}" "$OUTPUT_FILE"
            echo "✅ Display aspect ratio corrected via MP4Box."
        fi
    fi

    echo -e "\n✅ Done! Final file: $OUTPUT_FILE"
fi
