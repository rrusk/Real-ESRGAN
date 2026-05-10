#!/usr/bin/env bash
# ==============================================================================
# Script Name: dv_trim.sh
# Description: Trims the start and/or end of a DV or MKV file using stream
#              copy (no re-encode, no quality loss).
#
#              If the input is a DV1 AVI file it is automatically converted
#              to a raw .dv file first (original .avi is left untouched).
#
#              For dvgrab-style _YYYYMMDD_HHMM001 files the trimmed output is
#              written without the 001 suffix and the original is left untouched.
#              For other files the original is renamed to
#              <stem>_original_TIMESTAMP.<ext> and the trimmed file takes its name.
#
#              At least one of --start or --end must be specified.
#
# Usage:
#   ./dv_trim.sh [--start START_TIME] [--end END_TIME] <input>
#
# Arguments:
#   --start START_TIME  Discard everything before this point.
#                       Accepts HH:MM:SS, MM:SS, or raw seconds (decimals ok).
#   --end   END_TIME    Discard everything after this point, measured from
#                       the START of the original file (not from --start).
#                       Accepts HH:MM:SS, MM:SS, or raw seconds (decimals ok).
#   input               Source DV (.dv), DV-in-AVI (.avi), or FFV1/MKV (.mkv)
#                       file.
#
# Examples:
#   Trim start only:
#     ./dv_trim.sh --start 0:08 capture.dv
#
#   Trim end only:
#     ./dv_trim.sh --end 1:23:45 capture.dv
#
#   Trim both ends:
#     ./dv_trim.sh --start 0:08 --end 1:23:45 capture.dv
#     ./dv_trim.sh --start 8.0 --end 5025.3 capture.mkv
#
# Notes:
#   - --end is always relative to the start of the original file, not to
#     --start.  If both are given, ffmpeg receives -ss START and
#     -t (END - START) so the output duration is END minus START.
#   - Stream copy preserves the original codec and quality exactly.
#   - For AVI input the DV stream is extracted to raw .dv before trimming;
#     the original .avi is left untouched.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Dependency check
# ------------------------------------------------------------------------------
for cmd in ffmpeg ffprobe gawk; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[ERROR] Required tool not found: $cmd"
        exit 1
    }
done

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    echo "Usage: $0 [--start START_TIME] [--end END_TIME] <input>"
    echo "  At least one of --start or --end is required."
    echo "  Times: HH:MM:SS, MM:SS, or seconds (decimals ok)."
    echo ""
    echo "  --end is measured from the start of the original file."
    echo ""
    echo "Examples:"
    echo "  $0 --start 0:08 capture.dv"
    echo "  $0 --end 1:23:45 capture.dv"
    echo "  $0 --start 0:08 --end 1:23:45 capture.mkv"
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
START_TIME=""
END_TIME=""
INPUT=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --start)
            [[ -z "${2:-}" ]] && { echo "[ERROR] --start requires a time value."; exit 1; }
            START_TIME="$2"
            shift 2
            ;;
        --end)
            [[ -z "${2:-}" ]] && { echo "[ERROR] --end requires a time value."; exit 1; }
            END_TIME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -z "$INPUT" ]]; then
                INPUT="$1"
            else
                echo "[ERROR] Unexpected argument: $1"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate: at least one trim point required
if [[ -z "$START_TIME" && -z "$END_TIME" ]]; then
    echo "[ERROR] At least one of --start or --end must be specified."
    usage
    exit 1
fi

# Validate: input file required
if [[ -z "$INPUT" ]]; then
    echo "[ERROR] No input file specified."
    usage
    exit 1
fi

[[ -f "$INPUT" ]] || { echo "[ERROR] File not found: $INPUT"; exit 1; }

# ------------------------------------------------------------------------------
# Helper: convert HH:MM:SS or MM:SS or raw seconds to fractional seconds.
# Used to compute the -t duration when both --start and --end are given.
# ------------------------------------------------------------------------------
to_seconds() {
    local T="$1"
    gawk -v t="$T" 'BEGIN {
        n = split(t, a, ":")
        if (n == 3) print a[1]*3600 + a[2]*60 + a[3]
        else if (n == 2) print a[1]*60 + a[2]
        else print t + 0
    }'
}

# ------------------------------------------------------------------------------
# AVI input handling: extract DV stream to raw .dv before trimming.
# Raw .dv seeks cleanly in VLC; AVI remuxing via ffmpeg rebuilds the index
# and inflates the output.  The original .avi is left untouched.
# ------------------------------------------------------------------------------
ext="${INPUT##*.}"
if [[ "${ext,,}" == "avi" ]]; then
    codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT")
    if [[ "$codec" != "dvvideo" ]]; then
        echo "[ERROR] $INPUT does not contain a DV stream (codec: ${codec:-unknown})."
        echo "        Only DV1/DV2 AVI files are supported."
        exit 1
    fi

    DV_INPUT="${INPUT%.*}.dv"
    if [[ -e "$DV_INPUT" ]]; then
        echo "[ERROR] Converted file already exists: $DV_INPUT"
        echo "        Remove or rename it before running this script."
        exit 1
    fi

    echo "AVI input detected -- converting to raw DV first..."
    echo "  Source : $INPUT"
    echo "  Output : $DV_INPUT"

    stdbuf -eL ffmpeg -hide_banner -loglevel warning -stats \
        -i "$INPUT" -c copy -f dv \
        "$DV_INPUT" 2>&1 | gawk '
        BEGIN { RS = "\r" }
        {
            n = split($0, sublines, "\n")
            for (i = 1; i <= n; i++) {
                line = sublines[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line == "") continue
                if (line ~ /^frame=/) { printf "\r  %s", line; fflush() }
                else                  { printf "\n  %s\n", line; fflush() }
            }
        }'
    echo ""
    echo "  Conversion complete."
    INPUT="$DV_INPUT"
fi

# ------------------------------------------------------------------------------
# Build ffmpeg seek/duration arguments.
#
# -ss before -i (input seek) is fast for MKV/FFV1 but can be imprecise for
# raw DV.  For DV we use -ss after -i (output seek) which decodes and discards
# frames — slightly slower for long offsets but frame-accurate.
#
# When both --start and --end are given, --end is relative to the original
# file start, so we pass -t (end_secs - start_secs) as the output duration.
# ------------------------------------------------------------------------------
ext="${INPUT##*.}"

FFMPEG_ARGS=()

if [[ "${ext,,}" == "dv" ]]; then
    # Output seek for raw DV: -ss placed after -i for frame accuracy.
    FFMPEG_ARGS+=( -i "$INPUT" )
    [[ -n "$START_TIME" ]] && FFMPEG_ARGS+=( -ss "$START_TIME" )
else
    # Input seek for MKV/AVI: -ss before -i for speed; containers handle
    # seek points correctly.
    [[ -n "$START_TIME" ]] && FFMPEG_ARGS+=( -ss "$START_TIME" )
    FFMPEG_ARGS+=( -i "$INPUT" )
fi

if [[ -n "$END_TIME" ]]; then
    if [[ -n "$START_TIME" ]]; then
        # Compute duration = end - start so -t is output-relative.
        START_SECS=$(to_seconds "$START_TIME")
        END_SECS=$(to_seconds "$END_TIME")
        DURATION=$(gawk -v s="$START_SECS" -v e="$END_SECS" 'BEGIN {
            d = e - s
            if (d <= 0) { print "ERROR"; exit 1 }
            printf "%.6f", d
        }')
        if [[ "$DURATION" == "ERROR" ]]; then
            echo "[ERROR] --end ($END_TIME) must be after --start ($START_TIME)."
            exit 1
        fi
        FFMPEG_ARGS+=( -t "$DURATION" )
    else
        # End only: -t from beginning of file.
        FFMPEG_ARGS+=( -t "$END_TIME" )
    fi
fi

FFMPEG_ARGS+=( -c copy )

# ------------------------------------------------------------------------------
# Determine output filenames.
#
# dvgrab names files with a _YYYYMMDD_HHMM001 suffix (the trailing "001" is a
# segment counter).  When the input matches that pattern the trimmed file is
# written directly to the name without the "001", and the original is left
# untouched — it already has the unique timestamped name dvgrab gave it.
#
# For any other input the existing behaviour applies: the original is renamed
# to <stem>_original_TIMESTAMP.<ext> and the trimmed file takes the original
# name.
# ------------------------------------------------------------------------------
dir=$(dirname "$INPUT")
base=$(basename "$INPUT")
stem="${base%.*}"
ext="${base##*.}"
TEMP="${dir}/${stem}_trimming.${ext}"

if [[ "$stem" =~ _[0-9]{8}_[0-9]{4}001$ ]]; then
    # dvgrab-style name: write trimmed file without the 001 segment suffix.
    # The original file is left in place with its existing name.
    TARGET="${dir}/${stem%001}.${ext}"
    ORIGINAL=""
else
    # Generic input: rename original and overwrite with trimmed file.
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    ORIGINAL="${dir}/${stem}_original_${TIMESTAMP}.${ext}"
    TARGET="${dir}/${stem}.${ext}"
fi

echo "Input:    $INPUT"
[[ -n "$START_TIME" ]] && echo "Start:    $START_TIME"
[[ -n "$END_TIME"   ]] && echo "End:      $END_TIME"
echo "Started:  $(date)"

stdbuf -eL ffmpeg -hide_banner -loglevel warning -stats \
    "${FFMPEG_ARGS[@]}" \
    "$TEMP" 2>&1 | gawk '
    BEGIN { RS = "\r" }
    {
        n = split($0, sublines, "\n")
        for (i = 1; i <= n; i++) {
            line = sublines[i]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line == "") continue
            if (line ~ /^frame=/) { printf "\r  %s", line; fflush() }
            else                  { printf "\n  %s\n", line; fflush() }
        }
    }'
echo ""

if [[ -n "$ORIGINAL" ]]; then
    mv "$INPUT" "$ORIGINAL"
fi
mv "$TEMP" "$TARGET"

echo "Finished: $(date)"
echo "Trimmed:  $TARGET"
[[ -n "$ORIGINAL" ]] && echo "Original: $ORIGINAL"
