#!/bin/bash
# ==============================================================================
# Script Name: compare_test_results.sh
# Description: Generic 4-way comparison for test clips with dynamic scaling.
# ==============================================================================
set -euo pipefail

if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    echo "[!] ERROR: Virtual environment not detected. Run: source venv/bin/activate"
    exit 1
fi

# 1. Argument Check
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <original_test_clip_path>"
    exit 1
fi

INPUT_ORIGINAL="$1"
# Get the filename without path and extension
BASENAME=$(basename "$INPUT_ORIGINAL")
FILE_STEM="${BASENAME%.*}"

# 2. Identify Pipeline Outputs
INPUT_X2="outputs/${FILE_STEM}_x2_rife_FINAL.mkv"
INPUT_X4="outputs/${FILE_STEM}_x4_rife_FINAL.mkv"
OUTPUT_FILE="outputs/comparison_${FILE_STEM}_4K_grid.mkv"

# 3. Validation
if [[ ! -f "$INPUT_X2" || ! -f "$INPUT_X4" ]]; then
    echo "Error: Required comparison files not found in outputs/."
    echo "Ensure you ran run_test_comparisons.py on '$INPUT_ORIGINAL' first."
    exit 1
fi

# 4. Dynamic Grid Config
# Probe the X4 master to determine the target panel size for normalization
PANEL_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$INPUT_X4")
PANEL_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$INPUT_X4")

# 5. Run FFmpeg
# Added -shortest to ensure the infinite color filter stops at the end of the video
# Normalized all inputs to match the X4 dimensions to prevent height mismatch errors
ffmpeg -y \
-i "$INPUT_ORIGINAL" \
-i "$INPUT_X4" \
-i "$INPUT_X2" \
-filter_complex " \
    [0:v]scale=${PANEL_W}:${PANEL_H}:flags=neighbor,drawtext=text='Original VHS':x=20:y=20:fontsize=60:fontcolor=white:box=1:boxcolor=black@0.5[tl]; \
    [1:v]drawtext=text='4x (Filtered, No Face)':x=20:y=20:fontsize=60:fontcolor=white:box=1:boxcolor=black@0.5[tr]; \
    [2:v]scale=${PANEL_W}:${PANEL_H}:flags=lanczos,drawtext=text='2x (Filtered, No Face)':x=20:y=20:fontsize=60:fontcolor=white:box=1:boxcolor=black@0.5[br]; \
    color=s=${PANEL_W}x${PANEL_H}:c=black,drawtext=text='Empty Panel':x=20:y=20:fontsize=60:fontcolor=white[bl]; \
    [tl][tr]hstack[top]; \
    [bl][br]hstack[bottom]; \
    [top][bottom]vstack[v] \
" \
-map "[v]" -map "0:a" -c:v libx264 -crf 18 -preset slow -c:a copy -shortest "$OUTPUT_FILE"

echo "Success! Comparison grid created: $OUTPUT_FILE"
