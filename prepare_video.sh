#!/bin/bash
# ==============================================================================
# Script Name: prepare_video.sh
# Description: Smart deinterlacing & mastering for AI-upscaling pipeline.
# Handles Raw DV/Hi8 captures, DVD MPEG-2, and progressive digital files
# with dynamic detection.
#
# NOTE: The entire script is wrapped in main() so that bash reads the complete
# file into memory before execution begins. This prevents mid-run file
# replacement from affecting an in-progress encode.
#
# ==============================================================================
# CHANGE HISTORY — CRF VALUES
# ==============================================================================
# 2026-05-04: All source types now use CRF 12 as the pipeline intermediate.
#             ALL previously processed files used CRF 16 regardless of source type.
#
#             Rationale: as a pipeline intermediate fed to Real-ESRGAN,
#             maximum input quality applies regardless of source noise floor.
#             Detail lost at this stage cannot be recovered by upscaling.
#             See inline comments at each source type block for exact locations.
# ==============================================================================
# CHANGE HISTORY — CHROMA SUBSAMPLING
# ==============================================================================
# 2026-05-05: Deinterlaced master now encoded as yuv444p instead of yuv420p.
#
#             Native DV (NTSC) is 4:1:1. libavcodec's DV decoder outputs
#             yuv420p, halving chroma vertically on decode. Previously, encoding
#             the master as yuv420p applied a second lossy chroma subsampling
#             step after bwdif had already processed those decoded frames.
#             Encoding as yuv444p avoids that second round-trip. Real-ESRGAN
#             decodes to float32 RGB internally regardless of pix_fmt, so there
#             is no inference overhead — only a small increase in master file size.
# ==============================================================================
set -euo pipefail

main() {

# 1. Argument Check
# Validates input count and provides detailed help documentation.
if [ "$#" -eq 0 ] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "Usage: $0 <source_video> [mask_pixels] [--test] [--aac] [--crf N] [--mode0]"
    echo ""
    echo "Arguments:"
    echo "  source_video    Path to the raw AVI, MPG, or MP4 file."
    echo "  mask_pixels     (Optional) Number of pixels to black out at the bottom."
    echo "                  *** Use EVEN numbers (8, 10, 12) for best results. ***"
    echo "  --test          (Optional) Process only the first 30s for quick mask review."
    echo "  --aac           (Optional) Force AAC encoding (192k lossy) instead of"
    echo "                  preserving PCM audio bit-for-bit. When PCM is detected,"
    echo "                  the default behaviour is to write a .mkv master (which"
    echo "                  supports PCM natively) rather than lossy-encode to AAC."
    echo "                  Use --aac only if you specifically need an MP4 master."
    echo "  --crf N         (Optional) x264 CRF quality level (default: 12)."
    echo "                  12 is the archival default for all SD pipeline intermediates."
    echo "                  Lower = higher quality and larger file. Rarely needs changing."
    echo "  --mode0         (Optional) Use bwdif mode=0 (frame-rate output: ~30fps)."
    echo "                  Default is mode=1 (field-rate output: ~60fps)."
    echo ""
    echo "                  mode=1 (default): each field becomes its own progressive"
    echo "                  frame (~60fps), preserving field-rate temporal resolution."
    echo "                  Best for fast motion where the ~16.7ms between fields matters."
    echo "                  ESRGAN processes 2x as many frames — expect roughly 2x the"
    echo "                  upscaling pipeline runtime."
    echo "                  Always pair mode=1 output with --no-rife in the pipeline."
    echo ""
    echo "                  mode=0 (--mode0): combines both interlaced fields into one"
    echo "                  full-resolution progressive frame (~30fps). All source data"
    echo "                  is preserved. ESRGAN processes the 30fps frame count."
    echo ""
    echo "                  Output filename includes '_30fps' when --mode0 is used,"
    echo "                  and '_60fps' for the default mode=1."
    echo ""
    echo "How to select mask_pixels:"
    echo "  1. Play your video in VLC and look at the bottom edge."
    echo "  2. If you see a flickering/static line (head-switching noise), estimate its height."
    echo "  3. Typical values for Hi8/VHS are 8, 10, or 12 pixels."
    echo "  4. CRITICAL: Always use an EVEN number to maintain correct vertical alignment"
  echo "               for the drawbox mask (applies regardless of chroma subsampling)."
    exit 0
fi

# Strict argument limit check as per previous versions
if [ "$#" -gt 7 ]; then
    echo "Error: Too many arguments."
    echo "Usage: $0 <source_video> [mask_pixels] [--test] [--aac] [--crf N] [--mode0]"
    exit 1
fi

# Variable Initialization
# SOURCE_INPUT is always the first positional argument.
# shift moves past it so the remaining args can be parsed without risk of
# misinterpreting a numeric filename (e.g. 12345.avi) as a mask value.
SOURCE_INPUT="$1"
shift
MASK_PIXELS=0
TEST_MODE=false
FORCE_AAC=false
CRF_VALUE=""       # empty until after prefix detection; --crf sets this explicitly
CRF_EXPLICIT=false # true when --crf was supplied on the command line
BWDIF_MODE=1       # default: field-rate output (~60fps); --mode0 sets this to 0 (~30fps)

# Simple parsing loop to handle optional numeric mask and named flags.
# Because SOURCE_INPUT has been shifted out, only genuine optional args remain.
_NEXT_IS_CRF=false
for arg in "$@"; do
    if [[ "$_NEXT_IS_CRF" == true ]]; then
        CRF_VALUE="$arg"
        CRF_EXPLICIT=true
        _NEXT_IS_CRF=false
    elif [[ "$arg" == "--crf" ]]; then
        _NEXT_IS_CRF=true
    elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        MASK_PIXELS="$arg"
    elif [[ "$arg" == "--test" ]]; then
        TEST_MODE=true
    elif [[ "$arg" == "--aac" ]]; then
        FORCE_AAC=true
    elif [[ "$arg" == "--mode0" ]]; then
        BWDIF_MODE=0
    else
        # Reject unrecognised arguments early rather than silently ignoring them.
        # Common mistake: passing 'test' instead of '--test'.
        echo "Error: Unrecognised argument: '$arg'" >&2
        echo "Usage: $0 <source_video> [mask_pixels] [--test] [--aac] [--crf N] [--mode0]" >&2
        exit 1
    fi
done

# CRF Validation
# --crf overrides the default. Validates that the value is a whole number
# within the x264 range and warns if it seems unreasonable for an SD pipeline
# intermediate. Hard error above 51 (x264 maximum).
# Default is CRF 12 for all source types — maximum quality input for
# Real-ESRGAN regardless of source noise floor (2026-05-04: was CRF 16).
if [[ "$CRF_EXPLICIT" == false ]]; then
    CRF_VALUE=12
fi
if ! [[ "$CRF_VALUE" =~ ^[0-9]+$ ]]; then
    echo "Error: --crf requires a whole number (got: '$CRF_VALUE')." >&2
    exit 1
fi
if (( CRF_VALUE > 51 )); then
    echo "Error: CRF $CRF_VALUE is out of range — x264 maximum is 51." >&2
    exit 1
fi
if (( CRF_VALUE < 10 )); then
    echo -e "⚠️  WARNING: CRF $CRF_VALUE is very low — files will be very large" \
            "with negligible quality benefit over CRF 12."
elif (( CRF_VALUE > 16 )); then
    echo -e "⚠️  WARNING: CRF $CRF_VALUE is lossy for an SD pipeline intermediate." \
            "Detail loss will reduce Real-ESRGAN output quality."
    echo "    Recommended: 12 (default). Use --crf only if you have a specific reason."
fi

# Early Codec Probe
# IS_DV_SOURCE is set here for field order detection later in the script.
# The informational DV messages are emitted after the probe report to keep
# user-visible output in logical order.
#
# DV codec (dvsd, dv25, dvvideo) notes:
#   - Field order is always BFF on NTSC but ffprobe cannot read it from
#     the AVI container headers and returns 'unknown'.
#   - The dvvideo decoder emits 'AC EOB marker is absent' warnings for
#     malformed frames in the tape leader (garbage timecode region).
#     These are cosmetic and stop after the first few seconds.
SOURCE_CODEC=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)
SOURCE_PIX_FMT=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=pix_fmt \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)
# SOURCE_PIX_FMT reflects the container/stream pixel format as ffprobe reports
# it — for DV this is yuv411p (the native DV chroma), not the yuv420p that
# libavcodec outputs on decode. This is intentional: we want to show the user
# what the source actually contains, not what the decoder produces internally.
IS_DV_SOURCE=false
if [[ "$SOURCE_CODEC" == dv* ]]; then
    IS_DV_SOURCE=true
fi

# Hi8 Default Mask
# Hi8 analog captures via DV converter reliably produce 8 pixels of
# head-switching noise at the bottom edge. Apply a default mask of 8 when:
#   - no mask was explicitly supplied on the command line (MASK_PIXELS == 0)
#   - the source codec is dvvideo (IS_DV_SOURCE set below, but filename is
#     available here; codec check is repeated after SOURCE_CODEC is probed)
#   - the filename begins with "hi8" (case-insensitive), matching the capture
#     naming convention: hi8_YYYYMMDD-YYYYMMDD.dv / hi8dv_...
#
# Pure MiniDV sources (no analog conversion) do not have head-switching noise
# and are not named with a "hi8" prefix, so they are unaffected.
#
# Pass mask_pixels=0 explicitly on the command line to suppress this default.
HI8_MASK_APPLIED=false
if [[ "$MASK_PIXELS" -eq 0 ]]; then
    BASE_FOR_MASK=$(basename "$SOURCE_INPUT")
    if [[ "${BASE_FOR_MASK,,}" == hi8* ]]; then
        MASK_PIXELS=8
        HI8_MASK_APPLIED=true
    fi
fi

BASE_NAME=$(basename "$SOURCE_INPUT")
FILE_STEM="${BASE_NAME%.*}"

# Odd Number Sanity Check
# Prevents alignment artifacts at the drawbox mask boundary. Even numbers
# are required for correct macroblock alignment regardless of chroma subsampling.
if (( MASK_PIXELS % 2 != 0 )); then
    echo -e "\n⚠️  WARNING: Mask ($MASK_PIXELS) is an odd number."
    echo "    This can cause alignment artifacts at the mask boundary."
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
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="outputs"
mkdir -p "$OUTPUT_DIR"

# Always embed an fps label so masters are self-documenting regardless of which
# mode was used. Both mode=1 (default, ~60fps) and mode=0 (--mode0, ~30fps)
# get an explicit suffix so files are never ambiguous in the outputs directory.
if [ "$BWDIF_MODE" -eq 0 ]; then
    FPS_LABEL="_30fps"
else
    FPS_LABEL="_60fps"
fi

if [ "$TEST_MODE" = true ]; then
    PROG_OUTPUT="${OUTPUT_DIR}/${FILE_STEM}_mask${MASK_PIXELS}${FPS_LABEL}_TEST.mp4"
    LIMIT_CMD="-t 30"
    TEST_LABEL=" (TEST MODE: 30s)"
else
    PROG_OUTPUT="${OUTPUT_DIR}/${FILE_STEM}_mask${MASK_PIXELS}${FPS_LABEL}_${TIMESTAMP}.mp4"
    LIMIT_CMD=""
    TEST_LABEL=""
fi

# 2. Run the Probe and Capture Results
echo "--- Step 1: Probing Video ---"
# Utilizes external probe_video.py for deep metadata analysis.
PROBE_LOG=$(python3 probe_video.py "$SOURCE_INPUT")
echo "$PROBE_LOG"

# 3. Emit DV-Specific Info Messages
# SOURCE_CODEC and IS_DV_SOURCE were set earlier (before prefix detection).
# Messages are deferred until here so they appear after the probe report
# in the user-visible output, keeping the log in logical order.
if [[ "$IS_DV_SOURCE" == true ]]; then
    echo "[INFO] DV codec detected ($SOURCE_CODEC) — BFF field order assumed (NTSC standard)."
    echo "[INFO] Note: 'AC EOB marker' warnings at encode start are normal for DV tape"
    echo "       leader frames and will stop after the first few seconds."
fi

# 4. Audio Strategy Detection
# Detects source codec and determines re-encoding or preservation strategy.
#
# MP4 does not support PCM audio. When PCM is detected the output container
# is switched to MKV, which supports PCM natively, and audio is stream-copied
# bit-for-bit. The upscale pipeline detects the input extension dynamically
# and handles MKV masters correctly.
#
# Use --aac to force AAC and keep an MP4 master (e.g. for device compatibility).
AUDIO_FORMAT=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

if [[ "$FORCE_AAC" == true ]]; then
    # User explicitly requested AAC — output stays .mp4.
    AUDIO_CMD="-c:a aac -b:a 192k"
    AUDIO_PLAN="CONVERT (Forced AAC — 192k lossy, MP4 output)"
elif [[ "$AUDIO_FORMAT" == pcm* ]]; then
    # PCM cannot be muxed into MP4. Switch container to MKV so audio can be
    # stream-copied without re-encoding. The upscale pipeline handles .mkv input.
    AUDIO_CMD="-c:a copy"
    AUDIO_PLAN="LOSSLESS (PCM preserved bit-for-bit — switching output to .mkv)"
    PROG_OUTPUT="${PROG_OUTPUT%.mp4}.mkv"
    echo -e "\n[INFO] PCM audio detected. Output container changed to .mkv to preserve"
    echo "       audio bit-for-bit. Use --aac to force MP4 output with AAC instead."
else
    # Preserves original compressed audio to maintain sync and quality.
    AUDIO_CMD="-c:a copy"
    AUDIO_PLAN="LOSSLESS (Bitstream copy of $AUDIO_FORMAT)"
fi

# 5. Field Order and Scan Type Detection
#
# Detection priority:
#   1. DV codec shortcut — always BFF on NTSC, ffprobe cannot read from AVI headers
#   2. ffprobe stream=field_order — reliable for MPEG-2/DVD and most MP4 sources
#   3. probe_video.py fallback — for sources where ffprobe returns 'unknown'
#
FFPROBE_FIELD_ORDER=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=field_order \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

# Normalise to upper-case for consistent matching
FFPROBE_FIELD_ORDER_UC="${FFPROBE_FIELD_ORDER^^}"

if [[ "$IS_DV_SOURCE" == true ]]; then
    # DV from FireWire capture is always BFF on NTSC regardless of what
    # ffprobe reports. The AVI container does not store field order metadata
    # for DV streams, causing ffprobe to return 'unknown'. We shortcut here
    # to avoid falling through to the auto-detect path.
    IS_INTERLACED=true
    PARITY="1"
    FIELD_ORDER="BFF (Bottom Field First — DV/NTSC, codec-based detection)"

elif [[ "$FFPROBE_FIELD_ORDER_UC" == "PROGRESSIVE" ]]; then
    IS_INTERLACED=false
    PARITY="-1"
    FIELD_ORDER="Progressive"
elif [[ "$FFPROBE_FIELD_ORDER_UC" == "TT" ]]; then
    IS_INTERLACED=true
    PARITY="0"
    FIELD_ORDER="TFF (Top Field First)"
elif [[ "$FFPROBE_FIELD_ORDER_UC" == "BB" || "$FFPROBE_FIELD_ORDER_UC" == "BT" ]]; then
    IS_INTERLACED=true
    PARITY="1"
    FIELD_ORDER="BFF (Bottom Field First)"
else
    # ffprobe returned 'unknown' or empty for a non-DV source.
    # Fall back to probe_video.py output.
    SCAN_TYPE=$(echo "$PROBE_LOG" | grep "Scan Type:" | awk -F': ' '{print $2}')
    if echo "$PROBE_LOG" | grep -q "Interlaced"; then
        IS_INTERLACED=true
        if echo "$SCAN_TYPE" | grep -q "TFF"; then
            PARITY="0"
            FIELD_ORDER="TFF (Top Field First, from probe fallback)"
        elif echo "$SCAN_TYPE" | grep -q "BFF"; then
            PARITY="1"
            FIELD_ORDER="BFF (Bottom Field First, from probe fallback)"
        else
            PARITY="-1"
            FIELD_ORDER="Unknown — bwdif will auto-detect"
        fi
    else
        IS_INTERLACED=false
        PARITY="-1"
        FIELD_ORDER="Progressive (from probe fallback)"
    fi
fi

# PTS Regeneration if probe_video.py detects broken or unrealistic durations.
FFLAGS=""
if echo "$PROBE_LOG" | grep -q "unrealistic"; then
    echo "Detected broken timestamps. Enabling PTS regeneration..."
    FFLAGS="-fflags +genpts"
fi

# 6. Pre-Flight Summary & Confirmation
# Summarizes both Video and Audio plans before committing to a long encode.
echo -e "\n========================================="
echo "       PRE-FLIGHT SUMMARY$TEST_LABEL"
echo "========================================="
echo "Source File:   $SOURCE_INPUT"
echo "Source Codec:  $SOURCE_CODEC  |  Pixel fmt: $SOURCE_PIX_FMT"
echo "Output File:   $PROG_OUTPUT"
echo "Output Chroma: yuv444p  (upsampled from decoded $SOURCE_PIX_FMT — avoids second chroma subsampling round-trip)"
echo "Audio Plan:    $AUDIO_PLAN"
if [[ "$HI8_MASK_APPLIED" == true ]]; then
    echo "Bottom Mask:   ${MASK_PIXELS} pixels  (auto-applied: hi8 filename prefix detected — pass 0 to suppress)"
else
    echo "Bottom Mask:   ${MASK_PIXELS} pixels"
fi
echo "CRF:           ${CRF_VALUE}"

if [ "$IS_INTERLACED" = true ]; then
    if [ "$BWDIF_MODE" -eq 1 ]; then
        VIDEO_PLAN="HIGH-QUALITY DEINTERLACING (bwdif mode=1, field-rate ~60fps) — Field Order: ${FIELD_ORDER}"
    else
        VIDEO_PLAN="HIGH-QUALITY DEINTERLACING (bwdif mode=0, frame-rate ~30fps) — Field Order: ${FIELD_ORDER}"
    fi
    echo "Video Plan:    $VIDEO_PLAN"
    echo -e "\n⚠️  WARNING: Deinterlacing is a CPU-intensive process."
    echo "    Depending on video length, this will take quite awhile."
    if [ "$BWDIF_MODE" -eq 1 ]; then
        echo "    NOTE: mode=1 output is ~60fps (one frame per field)."
        echo "          ESRGAN will process 2x as many frames — expect ~2x upscaling runtime."
        echo "          Always pair with --no-rife in video_upscale_pipeline.py."
    else
        echo "    NOTE: mode=0 output is ~30fps. Both fields combined into full-resolution"
        echo "          progressive frames. Use the default (mode=1) for field-rate 60fps output."
    fi
else
    VIDEO_PLAN="Progressive Copy (No deinterlacing needed)"
    echo "Video Plan:    $VIDEO_PLAN"
fi
echo "========================================="

read -p "Do you wish to begin? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled by user."
    exit 0
fi

# 7. Processing
if [ "$IS_INTERLACED" = true ]; then
    echo -e "\n--- Step 2: High-Quality Deinterlacing (${FIELD_ORDER}) ---"

    # Filter Chain: bwdif mode=$BWDIF_MODE, yuv444p format, and optional drawbox.
    #   mode=1 (default): field-rate output — one progressive frame per field (~60fps).
    #                     Preserves full temporal resolution; pair with --no-rife in the
    #                     upscale pipeline to avoid accidental 120fps output.
    #   mode=0 (--mode0): frame-rate output — one progressive frame per interlaced frame (~30fps).
    #
    #   format=yuv444p: avoids a second lossy chroma subsampling round-trip after bwdif
    #   shifts chroma values. The native DV bitstream is already 4:1:1 (NTSC); libavcodec
    #   converts that to 4:2:0 during decode. Upsampling to yuv444p here preserves the best
    #   available chroma through the full pipeline rather than halving it again at encode time.
    #   Real-ESRGAN decodes intermediates to float32 RGB regardless of pix_fmt, so feeding
    #   it a yuv444p master costs only slightly more disk space with no processing overhead.
    #
    # 2026-05-05: format=yuv420p -> format=yuv444p. Native DV is 4:1:1 (NTSC); libavcodec
    #             decodes to 4:2:0. Encoding as yuv444p avoids a second lossy chroma
    #             subsampling step after bwdif processes the decoded frames.
    FILTER_CHAIN="bwdif=mode=${BWDIF_MODE}:parity=${PARITY}:deint=0,format=yuv444p"
    if [ "$MASK_PIXELS" -gt 0 ]; then
        echo "Applying mask: Bottom $MASK_PIXELS pixels"
        FILTER_CHAIN="${FILTER_CHAIN},drawbox=y=ih-${MASK_PIXELS}:h=${MASK_PIXELS}:color=black:t=fill"
    fi

    echo "Generating master: $PROG_OUTPUT"

    # ffmpeg argument order notes:
    #   $LIMIT_CMD (-t 30 in test mode) is placed BEFORE -i so it applies as
    #   an input option, strictly limiting how much of the source is read.
    #   Placing it after -i would limit output duration instead, which works
    #   in practice but is semantically incorrect for --test mode.
    #
    #   -threads 0 lets libx264 auto-detect the optimal thread count for the
    #   host CPU rather than hardcoding a value that may under or over-utilize
    #   available cores.
    #
    #   -crf defaults to 12 for all SD source types — maximum quality input
    #   for Real-ESRGAN regardless of source noise floor.
    #   -preset fast: this is a temporary intermediate consumed frame-by-frame
    #   by Real-ESRGAN, which does not benefit from inter-frame compression
    #   efficiency. fast encodes significantly quicker than slower/medium with
    #   no perceptible quality difference for an intermediate at any CRF.
    #
    #   -pix_fmt yuv444p: must be stated explicitly; libx264 does not infer
    #   pix_fmt from the filter chain. Ensures the encoded master matches the
    #   yuv444p frames produced by the filter chain above.
    #
    #   -movflags +faststart is MP4-specific but harmless on MKV (ignored silently).
    ffmpeg -y $FFLAGS $LIMIT_CMD -i "$SOURCE_INPUT" \
        -vf "$FILTER_CHAIN" \
        -c:v libx264 -threads 0 -crf "$CRF_VALUE" -preset fast \
        -pix_fmt yuv444p \
        -movflags +faststart \
        $AUDIO_CMD \
        "$PROG_OUTPUT"

    echo -e "\n✅ Success! Deinterlaced Master Created: $PROG_OUTPUT"
else
    echo -e "\n--- Step 2: No Deinterlacing Needed ---"
    echo "Source is progressive. You can use $SOURCE_INPUT directly."
fi

} # end main
main "$@"
