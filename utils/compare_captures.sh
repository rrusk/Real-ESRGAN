#!/bin/bash
# ==============================================================================
# Script Name: compare_captures.sh v5 - A/B Capture Comparison Suite
# Optimized for: Hi8/Digital8 DV captures at 720x480 NTSC
# ==============================================================================
# Compares two captures of the same tape side-by-side or with an animated wipe.
# Useful for evaluating re-captures after head cleans, or comparing different
# capture hardware (e.g. Sony DCR-VTR330 FireWire DV vs Philips DVDR3575H
# S-Video), or comparing pre- and post-enhancement pipeline outputs.
#
# Use -s / -S to align clips that started at different tape positions.
#
# ALIGNMENT WORKFLOW
# ==================
# Two independent analog captures of the same tape will almost never be
# frame-aligned. Use this workflow to find the offset before fine-tuning:
#
#   1. Open both enhanced files in VLC and find a scene that is easy to
#      visually identify — a static shot, a title card, or a moment where
#      someone is standing still works best.
#
#   2. Note the timestamp in each file where that scene appears.
#      e.g. LEFT file: 1:03.0  RIGHT file: 0:54.0  ->  offset = 9.0s
#
#   3. Run a short wipe comparison at that scene to verify rough alignment:
#        ./compare_captures.sh -w -t 10 -s 63 -S 54 left.mkv right.mkv out.mp4
#        vlc --loop out.mp4
#
#   4. Fine-tune by adjusting -s and -S in 0.5s steps until object edges
#      align well at the wipe boundary.
#
#   5. For frame-level precision: at 59.94fps one frame = 0.017s.
#      Nudge one offset by multiples of 0.017 to step frame by frame.
#      e.g. 3 frames forward: add 0.050s to the offset that needs advancing.
#
#   6. Once aligned, use the finalised offset for any scene in the video.
#      Keep the difference between -s and -S constant and shift both values
#      to seek to different parts of the tape.
#      e.g. if aligned at -s 62.82 -S 54.40 (offset = 8.42s), then to
#      compare the scene at 2:00 in the right file use -s 128.42 -S 120.0
#
# NOTE: Perfect frame-lock between two independent analog captures is not
# achievable — tape speed variation and capture card clock differences will
# always leave a small residual offset that may drift slightly over time.
#
# WIPE IMPLEMENTATION NOTE (FFmpeg 4.4)
# ======================================
# The animated wipe is implemented using ffmpeg's blend filter with a
# per-pixel expression: if(lte(X, W*N/TOTAL_FRAMES), B, A)
# This evaluates per pixel per frame, correctly showing clip B (right/new)
# on the left of the blade and clip A (left/old) on the right.
#
# overlay, drawbox, and crop were all tried and rejected for this purpose:
#   - overlay x= is evaluated once at config time, not per-frame
#   - drawbox x= similarly has no access to timeline variables (t, W, N)
#   - crop w= does not support per-frame expressions either
#   - blend all_expr is the correct per-pixel-per-frame solution in FFmpeg 4.4
# ==============================================================================
set -euo pipefail

WIPE_MODE=false
L_OFF=0
R_OFF=0
DURATION=10

usage() {
    echo ""
    echo "Usage: $0 [OPTIONS] <file_left> <file_right> [output_name]"
    echo ""
    echo "  file_left    Required. First input file (shown on left / revealed by wipe)."
    echo "  file_right   Required. Second input file (shown on right / starts full-screen)."
    echo "  output_name  Optional. Output filename (default: comparison_YYYYMMDD_HHMM.mp4)"
    echo ""
    echo "Options:"
    echo "  -w           Enable Animated Wipe mode (default is side-by-side)"
    echo "  -s SECONDS   Seek offset for LEFT input  (e.g. -s 62.5)"
    echo "  -S SECONDS   Seek offset for RIGHT input (e.g. -S 54.4)"
    echo "  -t SECONDS   Duration of comparison clip (default: 10)"
    echo ""
    echo "Examples:"
    echo "  Side-by-side, first 10 seconds:"
    echo "    $0 capture_A.mkv capture_B.mkv"
    echo ""
    echo "  Wipe mode, 30 seconds, right clip starts 5s later to align:"
    echo "    $0 -w -t 30 -S 5.0 capture_A.mkv capture_B.mkv result.mp4"
    echo ""
    echo "  Both clips seeked to a known aligned scene for comparison:"
    echo "    $0 -w -s 62.82 -S 54.40 -t 10 capture_A.mkv capture_B.mkv"
    echo ""
    echo "  Loop the result in VLC for easy review:"
    echo "    vlc --loop result.mp4"
    echo ""
    echo "Alignment tips:"
    echo "  - Use VLC to scrub both files and find a matching static scene first."
    echo "  - Note the timestamp in each file and use the difference as your"
    echo "    initial -s / -S offset before running this script."
    echo "  - Adjust offsets in 0.5s steps for coarse alignment."
    echo "  - At 59.94fps, one frame = 0.017s. Use multiples for frame-level nudging:"
    echo "      1 frame = 0.017s   2 frames = 0.033s   3 frames = 0.050s"
    echo "  - Keep the difference between -s and -S constant to seek to other scenes."
    echo ""
    echo "Notes:"
    echo "  - Both inputs are normalized to 29.97fps before merging."
    echo "    This prevents stuttering when comparing a 59.94fps RIFE-interpolated"
    echo "    output against a raw 29.97fps source. Harmless if both match."
    echo "  - Change TARGET_FPS in the script to 60000/1001 to compare two"
    echo "    59.94fps sources directly."
    echo "  - Audio is excluded from the output to avoid sync confusion when"
    echo "    two temporally offset clips are merged."
    echo ""
    exit 1
}

if [ "$#" -lt 1 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
fi

# ==============================================================================
# 1. Argument Parsing
# ==============================================================================
while getopts "ws:S:t:" opt; do
    case $opt in
        w) WIPE_MODE=true ;;
        s) L_OFF="$OPTARG" ;;
        S) R_OFF="$OPTARG" ;;
        t) DURATION="$OPTARG" ;;
        *)
            echo "[ERROR] Unknown option: -$OPTARG"
            usage
            ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -lt 2 ]; then
    echo "[ERROR] Two input files are required."
    usage
fi

LEFT_INPUT="$1"
RIGHT_INPUT="$2"
OUTPUT_FILE="${3:-comparison_$(date +%Y%m%d_%H%M).mp4}"

# ==============================================================================
# 2. Input Validation
# ==============================================================================
if [ ! -f "$LEFT_INPUT" ]; then
    echo "[ERROR] Left input file not found: $LEFT_INPUT"
    exit 1
fi
if [ ! -f "$RIGHT_INPUT" ]; then
    echo "[ERROR] Right input file not found: $RIGHT_INPUT"
    exit 1
fi

# ==============================================================================
# 3. Label Generation
# Strips the path and extension to produce a clean on-screen label.
# e.g. /mnt/captures/TAPE01_20260319_1000-001.mkv -> TAPE01_20260319_1000-001
# ==============================================================================
get_label() {
    basename "$1" | sed 's/\.[^.]*$//'
}

LEFT_LABEL="$(get_label "$LEFT_INPUT")"
RIGHT_LABEL="$(get_label "$RIGHT_INPUT")"

# ==============================================================================
# 4. Filter Construction
# ==============================================================================
# Normalize both inputs to 29.97fps before merging.
# This prevents stuttering when comparing a RIFE-interpolated 59.94fps output
# against a raw 29.97fps capture. Harmless if both sources already match.
# Change TARGET_FPS to 60000/1001 if comparing two 59.94fps sources directly.
TARGET_FPS_NUM=30000
TARGET_FPS_DEN=1001
TARGET_FPS="${TARGET_FPS_NUM}/${TARGET_FPS_DEN}"

# Common scaling and fps normalization applied to both inputs.
# 720x480 is the correct display target for Hi8/NTSC DV captures.
SCALE="scale=720:480,setsar=1,fps=${TARGET_FPS}"

if [ "$WIPE_MODE" = true ]; then
    # Precompute total frame count using awk (integer math).
    # The blend filter's all_expr uses N (current frame number, 0-based) and
    # TOTAL_FRAMES as a literal integer — this avoids floating point and
    # variable-expansion issues inside the ffmpeg expression evaluator.
    TOTAL_FRAMES=$(awk "BEGIN {printf \"%d\", (${TARGET_FPS_NUM}/${TARGET_FPS_DEN}) * ${DURATION}}")

    echo "--- Mode: Animated Wipe (${DURATION}s, ${TOTAL_FRAMES} frames) ---"
    echo "    Left:  $LEFT_LABEL  (offset: ${L_OFF}s)"
    echo "    Right: $RIGHT_LABEL (offset: ${R_OFF}s)"
    echo "    FPS:   ${TARGET_FPS}"

    # Wipe blend expression breakdown:
    #   X            = current pixel's horizontal position (0 = left edge)
    #   W            = frame width
    #   N            = current frame number (0-based)
    #   TOTAL_FRAMES = total frames in clip (precomputed above)
    #
    #   W*N/TOTAL_FRAMES = wipe blade position, sweeping left to right.
    #
    #   if(lte(X, blade_pos), B, A):
    #     Pixels LEFT  of the blade show B (right input / new capture).
    #     Pixels RIGHT of the blade show A (left input  / old capture).
    #
    # At t=0 the blade is at x=0 so the full frame shows the new capture.
    # At t=end the blade is at x=W so the full frame shows the old capture.
    FILTER="
[0:v]${SCALE},drawtext=text='${LEFT_LABEL}':x=20:y=20:fontsize=24:fontcolor=yellow:box=1:boxcolor=black@0.4[old];
[1:v]${SCALE},drawtext=text='${RIGHT_LABEL}':x=w-tw-20:y=20:fontsize=24:fontcolor=cyan:box=1:boxcolor=black@0.4[new];
[old][new]blend=all_expr='if(lte(X\,W*N/${TOTAL_FRAMES})\,B\,A)'[out]
"
    MAP_OPT="-map [out]"

else
    echo "--- Mode: Side-by-Side (${DURATION}s) ---"
    echo "    Left:  $LEFT_LABEL  (offset: ${L_OFF}s)"
    echo "    Right: $RIGHT_LABEL (offset: ${R_OFF}s)"
    echo "    FPS:   ${TARGET_FPS}"

    FILTER="
[0:v]${SCALE},drawtext=text='${LEFT_LABEL}':x=20:y=20:fontsize=24:fontcolor=yellow:box=1:boxcolor=black@0.4[l];
[1:v]${SCALE},drawtext=text='${RIGHT_LABEL}':x=20:y=20:fontsize=24:fontcolor=cyan:box=1:boxcolor=black@0.4[r];
[l][r]hstack[out]
"
    MAP_OPT="-map [out]"
fi

# ==============================================================================
# 5. Execution
# ==============================================================================
echo "--- Output: $OUTPUT_FILE ---"

# ffmpeg argument notes:
#   -ss placed before -i seeks to the offset before decoding (fast, and
#   accurate enough for alignment work at this level of precision).
#   -t limits how much of each input is read.
#   -an omits audio: two temporally offset clips muxed together produces
#   confusing audio and serves no purpose for visual comparison.
ffmpeg -y \
    -ss "$L_OFF" -t "$DURATION" -i "$LEFT_INPUT" \
    -ss "$R_OFF" -t "$DURATION" -i "$RIGHT_INPUT" \
    -filter_complex "$FILTER" \
    $MAP_OPT \
    -c:v libx264 -crf 18 -preset veryfast \
    -an \
    "$OUTPUT_FILE"

# ==============================================================================
# 6. Result
# ==============================================================================
# Check both that the file exists AND has non-zero size.
# ffmpeg creates a zero-byte file on filter failure before exiting, which
# would cause a plain -f test to report false success.
if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    echo ""
    echo "[SUCCESS] Comparison saved: $OUTPUT_FILE ($FILE_SIZE)"
    echo "          Left:  $LEFT_INPUT (offset: ${L_OFF}s)"
    echo "          Right: $RIGHT_INPUT (offset: ${R_OFF}s)"
    echo "          Duration: ${DURATION}s @ ${TARGET_FPS}fps"
    echo ""
    echo "          To review: vlc --loop $OUTPUT_FILE"
else
    echo ""
    echo "[ERROR] Output file was not created or is empty. Check ffmpeg output above."
    rm -f "$OUTPUT_FILE"
    exit 1
fi
