#!/bin/bash
# ==============================================================================
# Script Name: split_dv.sh v1
# Purpose:     Split a raw DV file at a specified timecode or frame number.
#              Works with files captured by capture_tape.sh / capture_passthrough.sh
#              using dvgrab --format raw (produces .dv files, not AVI).
#
# Usage:
#   split_dv.sh [OPTIONS] INPUT.dv SPLIT_POINT
#
# SPLIT_POINT formats (any one of):
#   HH:MM:SS        e.g. 00:12:34          (assumes .00 seconds fraction)
#   HH:MM:SS.ss     e.g. 00:12:34.50       (decimal seconds, rounded to frame)
#   HH:MM:SS:FF     e.g. 00:12:34:15       (timecode with frame field)
#   Ns              e.g. 754s              (raw seconds)
#   Nf              e.g. 22600f            (raw frame number)
#
# Output:
#   Two files alongside the input, named <stem>_part1.dv and <stem>_part2.dv
#   Output directory can be overridden with -o / --output-dir.
#
# Why dd and not ffmpeg?
#   Raw DV (dvgrab --format raw) stores exactly one DV frame per
#   DV_FRAME_BYTES bytes with no container wrapper, index, or keyframe
#   dependency.  A split at a frame boundary is therefore lossless and
#   instant with dd; no re-encoding is required.
#
# Frame size constants (IEC 61834 / SMPTE 314M):
#   NTSC  29.97 fps  120,000 bytes/frame
#   PAL   25    fps  144,000 bytes/frame
#
# The script auto-detects PAL vs NTSC by probing the file with ffprobe.
# ==============================================================================
# CHANGE LOG:
#   v1 -- Initial release.
# ==============================================================================
set -uo pipefail

# ==============================================================================
# Constants
# ==============================================================================
readonly NTSC_FRAME_BYTES=120000
readonly PAL_FRAME_BYTES=144000
readonly NTSC_FPS_NUM=30000   # 30000/1001 = 29.97...
readonly NTSC_FPS_DEN=1001
readonly PAL_FPS_NUM=25
readonly PAL_FPS_DEN=1

# ==============================================================================
# Dependency preflight
# ==============================================================================
for _cmd in ffprobe bc dd; do
    command -v "$_cmd" >/dev/null 2>&1 || {
        echo "[ERROR] Required command not found: $_cmd"
        exit 1
    }
done
unset _cmd

# ==============================================================================
# Usage
# ==============================================================================
usage() {
    cat <<'EOF'
Usage: split_dv.sh [OPTIONS] INPUT.dv SPLIT_POINT

Split a raw DV file (dvgrab --format raw) at the given split point.
The split is lossless — no re-encoding; frames are copied byte-for-byte.

SPLIT_POINT formats:
  HH:MM:SS          e.g. 00:12:34
  HH:MM:SS.ss       e.g. 00:12:34.50  (decimal seconds, rounded to frame)
  Ns                e.g. 754s         (seconds, integer or decimal)
  Nf                e.g. 22600f       (frame number, zero-based)

Options:
  -o, --output-dir DIR   Directory for output files (default: same as input)
  -n, --dry-run          Show what would be done; do not create files
  -h, --help             Show this help

Output files:
  <stem>_part1.dv   frames 0 .. SPLIT_FRAME-1
  <stem>_part2.dv   frames SPLIT_FRAME .. end

Examples:
  split_dv.sh tape_2004.dv 00:12:34
  split_dv.sh tape_2004.dv 00:12:34:15
  split_dv.sh tape_2004.dv 754s
  split_dv.sh -o /tmp tape_2004.dv 22600f
EOF
}

# ==============================================================================
# Argument parsing
# ==============================================================================
OUTPUT_DIR=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-dir)
            [[ $# -lt 2 ]] && { echo "[ERROR] -o requires a directory argument"; exit 1; }
            OUTPUT_DIR="$2"; shift 2 ;;
        -n|--dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        --)
            shift; break ;;
        -*)
            echo "[ERROR] Unknown option: $1"; usage; exit 1 ;;
        *)
            break ;;
    esac
done

if [[ $# -ne 2 ]]; then
    echo "[ERROR] Expected INPUT.dv and SPLIT_POINT; got $# argument(s)."
    usage
    exit 1
fi

INPUT="$1"
SPLIT_ARG="$2"

# ==============================================================================
# Input validation
# ==============================================================================
if [[ ! -f "$INPUT" ]]; then
    echo "[ERROR] Input file not found: $INPUT"
    exit 1
fi

FILESIZE=$(stat -c%s "$INPUT")
if [[ "$FILESIZE" -eq 0 ]]; then
    echo "[ERROR] Input file is empty: $INPUT"
    exit 1
fi

# ==============================================================================
# Auto-detect PAL vs NTSC via ffprobe
# ==============================================================================
echo "[Info] Probing: $INPUT"

PROBE_JSON=$(ffprobe -v error \
    -select_streams v:0 \
    -show_entries stream=r_frame_rate,codec_name \
    -of default=noprint_wrappers=1 \
    "$INPUT" 2>&1)

CODEC=$(echo "$PROBE_JSON" | grep '^codec_name=' | cut -d= -f2)
RFRAME=$(echo "$PROBE_JSON" | grep '^r_frame_rate=' | cut -d= -f2)

# r_frame_rate is reported as a fraction, e.g. "30000/1001" or "25/1".
FPS_NUM=$(echo "$RFRAME" | cut -d/ -f1)
FPS_DEN=$(echo "$RFRAME" | cut -d/ -f2)

# Distinguish PAL (25 fps) from NTSC (30000/1001 ≈ 29.97 fps).
# Use integer arithmetic: PAL if num/den rounds to 25.
FPS_INT=$(( FPS_NUM / FPS_DEN ))

if [[ "$FPS_INT" -eq 25 ]]; then
    FRAME_BYTES=$PAL_FRAME_BYTES
    FPS_LABEL="PAL 25fps"
    FPS_NUM=$PAL_FPS_NUM
    FPS_DEN=$PAL_FPS_DEN
elif [[ "$FPS_INT" -eq 29 || "$FPS_INT" -eq 30 ]]; then
    FRAME_BYTES=$NTSC_FRAME_BYTES
    FPS_LABEL="NTSC 29.97fps"
    FPS_NUM=$NTSC_FPS_NUM
    FPS_DEN=$NTSC_FPS_DEN
else
    echo "[ERROR] Unrecognised frame rate from ffprobe: $RFRAME"
    echo "        Only NTSC (29.97fps) and PAL (25fps) raw DV are supported."
    exit 1
fi

# Verify file is an integer number of frames.
if (( FILESIZE % FRAME_BYTES != 0 )); then
    echo "[WARN] File size $FILESIZE is not a multiple of $FRAME_BYTES ($FPS_LABEL)."
    echo "       The file may be truncated or corrupted. Proceeding anyway."
fi

TOTAL_FRAMES=$(( FILESIZE / FRAME_BYTES ))
echo "[Info] Format : $FPS_LABEL  ($CODEC)"
echo "[Info] Frames : $TOTAL_FRAMES  ($(bc <<< "scale=3; $TOTAL_FRAMES * $FPS_DEN / $FPS_NUM") s)"
echo "[Info] Size   : $FILESIZE bytes"

# ==============================================================================
# Parse SPLIT_POINT into a frame number
# ==============================================================================

# Helper: convert HH:MM:SS[.ss] to total seconds (decimal) using bc.
# Args: $1=HH $2=MM $3=SS_possibly_decimal
hms_to_sec() {
    local h="$1" m="$2" s="$3"
    bc <<< "scale=6; $h * 3600 + $m * 60 + $s"
}

# Helper: convert seconds (decimal) to nearest frame number.
sec_to_frame() {
    local sec="$1"
    # frame = round(sec * FPS_NUM / FPS_DEN)
    # Use bc for floating-point then truncate (bash integer).
    local f
    f=$(bc <<< "scale=0; ($sec * $FPS_NUM / $FPS_DEN + 0.5) / 1")
    echo "$f"
}

SPLIT_FRAME=""

case "$SPLIT_ARG" in
    # Raw frame number: Nf
    *f)
        SPLIT_FRAME="${SPLIT_ARG%f}"
        if ! [[ "$SPLIT_FRAME" =~ ^[0-9]+$ ]]; then
            echo "[ERROR] Invalid frame number: $SPLIT_ARG"
            exit 1
        fi
        ;;

    # Raw seconds: Ns  (integer or decimal)
    *s)
        SEC="${SPLIT_ARG%s}"
        if ! [[ "$SEC" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "[ERROR] Invalid seconds value: $SPLIT_ARG"
            exit 1
        fi
        SPLIT_FRAME=$(sec_to_frame "$SEC")
        ;;

    # HH:MM:SS.ss  (decimal seconds)
    [0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9]*)
        HH="${SPLIT_ARG:0:2}"
        MM="${SPLIT_ARG:3:2}"
        SS="${SPLIT_ARG:6}"       # everything from position 6 onward
        SEC=$(hms_to_sec "$HH" "$MM" "$SS")
        SPLIT_FRAME=$(sec_to_frame "$SEC")
        ;;

    # HH:MM:SS  (integer seconds)
    [0-9][0-9]:[0-9][0-9]:[0-9][0-9])
        HH="${SPLIT_ARG:0:2}"
        MM="${SPLIT_ARG:3:2}"
        SS="${SPLIT_ARG:6:2}"
        SEC=$(hms_to_sec "$HH" "$MM" "$SS")
        SPLIT_FRAME=$(sec_to_frame "$SEC")
        ;;

    *)
        echo "[ERROR] Unrecognised SPLIT_POINT format: $SPLIT_ARG"
        echo "        See --help for supported formats."
        exit 1
        ;;
esac

# ==============================================================================
# Validate split frame
# ==============================================================================
if [[ "$SPLIT_FRAME" -le 0 ]]; then
    echo "[ERROR] Split frame $SPLIT_FRAME is at or before the start of the file."
    exit 1
fi

if [[ "$SPLIT_FRAME" -ge "$TOTAL_FRAMES" ]]; then
    echo "[ERROR] Split frame $SPLIT_FRAME is at or beyond end of file ($TOTAL_FRAMES frames)."
    exit 1
fi

SPLIT_BYTES=$(( SPLIT_FRAME * FRAME_BYTES ))
PART1_FRAMES=$SPLIT_FRAME
PART2_FRAMES=$(( TOTAL_FRAMES - SPLIT_FRAME ))

# Human-readable durations via bc.
PART1_DUR=$(bc <<< "scale=3; $PART1_FRAMES * $FPS_DEN / $FPS_NUM")
PART2_DUR=$(bc <<< "scale=3; $PART2_FRAMES * $FPS_DEN / $FPS_NUM")

echo "[Info] Split at frame $SPLIT_FRAME  (byte offset $SPLIT_BYTES)"
echo "[Info] Part 1: frames 0..$((SPLIT_FRAME - 1))  ($PART1_FRAMES frames, ${PART1_DUR}s)"
echo "[Info] Part 2: frames ${SPLIT_FRAME}..$((TOTAL_FRAMES - 1))  ($PART2_FRAMES frames, ${PART2_DUR}s)"

# ==============================================================================
# Determine output paths
# ==============================================================================
INPUT_DIR=$(dirname "$INPUT")
STEM=$(basename "$INPUT")
STEM="${STEM%.dv}"   # strip .dv extension if present

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$INPUT_DIR"
fi

OUT1="${OUTPUT_DIR}/${STEM}_part1.dv"
OUT2="${OUTPUT_DIR}/${STEM}_part2.dv"

echo "[Info] Output 1: $OUT1"
echo "[Info] Output 2: $OUT2"

# Refuse to clobber existing outputs.
for _out in "$OUT1" "$OUT2"; do
    if [[ -e "$_out" ]]; then
        echo "[ERROR] Output already exists: $_out"
        echo "        Remove it or choose a different --output-dir."
        exit 1
    fi
done
unset _out

# ==============================================================================
# Dry-run exit
# ==============================================================================
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[Dry-run] No files written."
    exit 0
fi

# ==============================================================================
# Pre-flight: verify the output filesystem has enough free space.
# df -k reports available blocks in 1024-byte units; convert to bytes.
# We need FILESIZE bytes total (part1 + part2 = original file size).
# ==============================================================================
AVAIL_KB=$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $4}')
AVAIL_BYTES=$(( AVAIL_KB * 1024 ))
if [[ "$AVAIL_BYTES" -lt "$FILESIZE" ]]; then
    echo "[ERROR] Not enough space in $OUTPUT_DIR"
    echo "        Need : $FILESIZE bytes"
    echo "        Available: $AVAIL_BYTES bytes"
    exit 1
fi

# ==============================================================================
# Split with dd
#
# Part 1: bytes 0 .. SPLIT_BYTES-1
#   dd reads SPLIT_BYTES bytes from the start of INPUT.
#   bs=FRAME_BYTES so the kernel does PART1_FRAMES single-frame reads — no
#   partial-frame buffering, no seek.
#
# Part 2: bytes SPLIT_BYTES .. end
#   dd skips SPLIT_FRAME blocks of FRAME_BYTES each (skip=), then copies
#   the remainder.  conv=notrunc is omitted because OUT2 is a new file.
#
# dd exit status is checked explicitly; 2>&1 alone does not propagate it
# through the pipeline when status=progress is in use.
# After each dd, the output file size is verified against the expected byte
# count so that a silent partial write (e.g. filesystem full mid-copy) is
# caught immediately rather than leaving a truncated file behind.
# ==============================================================================

# Helper: run dd and verify the output file reached the expected size.
# Args: $1=expected_bytes  $2=label  -- remaining args are passed to dd.
dd_verified() {
    local expected_bytes="$1"
    local label="$2"
    shift 2

    echo ""
    echo "[Split] Writing ${label}..."
    if ! dd "$@" status=progress 2>&1; then
        echo "[ERROR] dd failed writing ${label}."
        exit 1
    fi

    # Extract the output file path from the dd arguments (of=...).
    local outfile=""
    for arg in "$@"; do
        case "$arg" in of=*) outfile="${arg#of=}" ;; esac
    done

    local actual_bytes
    actual_bytes=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
    if [[ "$actual_bytes" -ne "$expected_bytes" ]]; then
        echo "[ERROR] ${label} is incomplete: expected $expected_bytes bytes, got $actual_bytes bytes."
        echo "        The output filesystem may have run out of space."
        echo "        Partial file left at: $outfile"
        exit 1
    fi
}

PART1_BYTES=$(( PART1_FRAMES * FRAME_BYTES ))
PART2_BYTES=$(( PART2_FRAMES * FRAME_BYTES ))

dd_verified "$PART1_BYTES" "part 1" \
    if="$INPUT" of="$OUT1" \
    bs="$FRAME_BYTES" \
    count="$PART1_FRAMES"

dd_verified "$PART2_BYTES" "part 2" \
    if="$INPUT" of="$OUT2" \
    bs="$FRAME_BYTES" \
    skip="$SPLIT_FRAME"

echo ""
echo "[Done]"
echo "  Part 1: $(stat -c%s "$OUT1") bytes  →  $OUT1"
echo "  Part 2: $(stat -c%s "$OUT2") bytes  →  $OUT2"
