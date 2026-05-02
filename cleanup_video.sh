#!/bin/bash
# ==============================================================================
# Script Name: cleanup_video.sh
# Description: All-in-one analog video cleanup for VHS, Hi8, and DV sources.
#              Handles raw captures directly — no prior preparation step needed.
#
#              Combines the source-handling logic of prepare_video.sh
#              (deinterlacing, field order detection, DV codec quirks, broken
#              timestamp repair, bottom mask) with cleanup profiles tuned for
#              a final watchable output rather than AI upscaler input.
#
#              All source probing is done inline via ffprobe/ffmpeg — there is
#              no dependency on probe_video.py or any other external script.
#
#              Supports raw DV/Hi8 AVI captures, DVD MPEG-2, and progressive
#              digital files with fully automatic scan-type detection.
#
# Pre-filter profiles vs. video_upscale_pipeline.py:
#   The pipeline profiles are conservative — ESRGAN handles sharpening and
#   recovers texture, so they deliberately leave noise for it to work with.
#   Here the filter chain IS the final product, so:
#     - Spatial denoise is stronger (no ESRGAN to hallucinate texture back in)
#     - Sharpening is explicit and stronger (no ESRGAN to add detail)
#     - Temporal values in 60fps variants remain halved (same reasoning as the
#       pipeline: field-rate frames are closer in time and need less smoothing)
#
# Interlace detection priority (mirrors probe_video.py):
#   1. DV codec shortcut — always BFF on NTSC; ffprobe cannot read field order
#      from AVI container headers for DV streams and returns 'unknown'.
#   2. ffprobe stream=field_order — authoritative for MPEG-2/DVD and most
#      MP4/MKV sources where the container stores this metadata.
#   3. ffprobe frame flags — checks first 50 frames for interlaced_frame=1.
#      Reliable structural check independent of container metadata.
#   4. ffmpeg idet filter — pixel-level heuristic, last resort only.
#      Prints a clear message when used; ambiguous results (15-20% interlace
#      ratio) abort with instructions rather than silently defaulting.
#
# Broken timestamp detection:
#   Duration is resolved via a 4-tier chain (stream -> format -> packet count
#   -> frame count). Sources with unrealistic durations (> 24h or missing)
#   have -fflags +genpts enabled to regenerate PTS on decode.
#   If all four tiers fail the script aborts — there is no silent fallback.
#
# NOTE: The entire script is wrapped in main() so that bash reads the complete
#       file into memory before execution begins. This prevents mid-run file
#       replacement from affecting an in-progress encode.
# ==============================================================================
set -euo pipefail

main() {

# --- 0. Virtual Environment Guard ---
if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    echo -e "\n[!] WARNING: Virtual environment not detected."
    echo "    Recommended: source venv/bin/activate"
    echo "    Continuing without venv — tool versions are not guaranteed."
fi

# --- 1. Argument Check ---
if [ "$#" -eq 0 ] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "Usage: $0 <source_video> [mask_pixels] [options]"
    echo ""
    echo "Arguments:"
    echo "  source_video         Path to the raw AVI, MKV, MP4, or MPG file."
    echo "  mask_pixels          (Optional) Pixels to black out at the bottom edge."
    echo "                       Use for head-switching noise on VHS/Hi8 tapes."
    echo "                       *** Always use EVEN numbers (8, 10, 12). ***"
    echo "                       Odd values cause YUV420p chroma alignment artifacts."
    echo ""
    echo "Options:"
    echo "  --profile PROFILE    Cleanup profile (default: balanced). See below."
    echo "  --scale N            Lanczos upscale factor (default: 2). Use --scale 1 to"
    echo "                       output at native source resolution (no upscale)."
    echo "                       Common values: 1 (native), 2 (default), 4 (4K displays)."
    echo "                       No AI — purely geometric. DAR is auto-detected and"
    echo "                       preserved regardless of scale factor."
    echo "  --sharpen            Apply a mild unsharp pass (unsharp=3:3:0.3) after all"
    echo "                       other filters. Not needed with the default 2x upscale —"
    echo "                       lanczos already compensates for hqdn3d softening."
    echo "                       Useful with --scale 1 when edge recovery is desired"
    echo "                       without upscaling."
    echo "  --dar W:H            Override the auto-detected display aspect ratio."
    echo "                       DAR is normally inferred automatically from resolution"
    echo "                       and SAR metadata (e.g. 720x480 NTSC -> 4:3 or 16:9)."
    echo "                       Use this only if auto-detection picks the wrong value."
    echo "                       Does not crop or stretch pixels; sets the DAR flag"
    echo "                       that players honour. Example: --dar 16:9"
    echo "  --mode0              Use bwdif mode=0 (frame-rate output: ~30fps)."
    echo "                       Default is mode=1 (field-rate output: ~60fps)."
    echo ""
    echo "                       mode=1 (default): each interlaced field becomes its own"
    echo "                       progressive frame (~60fps), preserving full temporal"
    echo "                       resolution. Best for fast motion."
    echo ""
    echo "                       mode=0 (--mode0): combines both fields into one"
    echo "                       full-resolution progressive frame (~30fps). Lower"
    echo "                       CPU cost and smaller output file."
    echo ""
    echo "  --crf N              x264 quality level (default: 18)."
    echo "                       Lower = higher quality and larger file."
    echo "                       16 is near-transparent; 20 suits casual archival."
    echo "  --aac                Force AAC audio output (192k). Default: lossless copy."
    echo "                       PCM sources automatically use .mkv to avoid re-encoding."
    echo "                       Use --aac only if you need an MP4 container instead."
    echo "  --test               Process only the first 30 seconds for quick preview."
    echo "  --60fps              Force 60fps profile variant selection. Normally"
    echo "                       auto-detected from source FPS (> 45fps threshold)."
    echo ""
    echo "How to select mask_pixels:"
    echo "  1. Play your video in VLC and look at the bottom edge."
    echo "  2. If you see a flickering/static line (head-switching noise), estimate height."
    echo "  3. Typical values for Hi8/VHS are 8, 10, or 12 pixels."
    echo "  4. CRITICAL: Always use an EVEN number to maintain YUV420p color alignment."
    echo ""
    echo "Profiles (--profile):"
    echo "  balanced             Default. Hi8/S-Video -> DVD (~4.6Mbps)."
    echo "                       Moderate denoise, temporal stability, fast deblock."
    echo ""
    echo "  aggressive           Heavy noise, composite-in captures, low-bitrate DVD."
    echo "                       Strong spatial denoise, full deblock+dering."
    echo "                       Use when balanced leaves visible noise."
    echo ""
    echo "  halo                 White ghost lines / ringing around dark edges."
    echo "                       Heavy denoise suppresses ringing. Do not combine"
    echo "                       with --sharpen — it would reintroduce edge artifacts."
    echo ""
    echo "  dv                   MiniDV / Digital8 / DV AVI sources."
    echo "                       Light-moderate denoise, full deblock+dering for DCT"
    echo "                       block artifacts."
    echo ""
    echo "  hi8dv                Hi8 tape via Digital8/FireWire DV capture."
    echo "                       No MPEG-2 artifacts (DVD authoring step bypassed)."
    echo "                       Moderate denoise targeting tape grain, full deblock."
    echo ""
    echo "  vhsdv                VHS via camcorder passthrough (S-Video input)."
    echo "                       Stronger chroma spatial denoise vs hi8dv for VHS"
    echo "                       color-under noise. Same temporal values."
    echo ""
    echo "  vhsdv_composite      VHS via camcorder passthrough (composite input)."
    echo "                       Elevated chroma spatial denoise targets dot crawl and"
    echo "                       cross-colour from comb filter luma/chroma separation."
    echo ""
    echo "Examples:"
    echo "  $0 tape.avi                                 # 2x upscale by default"
    echo "  $0 tape.avi 10                              # mask 10px head-switching noise"
    echo "  $0 tape.avi --profile vhsdv"
    echo "  $0 tape.avi 10 --profile vhsdv"
    echo "  $0 tape.avi --scale 1                       # native resolution (no upscale)"
    echo "  $0 tape.avi --scale 4                       # 4x upscale for 4K displays"
    echo "  $0 tape.mkv --profile dv --crf 16"
    echo "  $0 tape.avi --profile aggressive --test"
    echo "  $0 tape.avi --dar 16:9                      # override widescreen DV if mis-detected"
    echo "  $0 tape.avi --mode0                         # ~30fps output, lower CPU cost"
    exit 0
fi

# --- 2. Argument Parsing ---
# SOURCE_INPUT is always the first positional argument.
# shift moves past it so the remaining args can be parsed without risk of
# misinterpreting a numeric filename (e.g. 12345.avi) as a mask value.
SOURCE_INPUT="$1"
shift

MASK_PIXELS=0
MASK_EXPLICITLY_SET=false
PROFILE="balanced"
SCALE_FACTOR=2  # default: 2x lanczos upscale; override with --scale N (use 1 to disable)
SHARPEN=false   # opt-in; not needed with upscale — lanczos compensates for hqdn3d softening
DAR_OVERRIDE=""
BWDIF_MODE=1    # default: field-rate output (~60fps); --mode0 sets this to 0 (~30fps)
CRF_VALUE=18
FORCE_AAC=false
TEST_MODE=false
FORCE_60FPS=false

_NEXT_IS_PROFILE=false
_NEXT_IS_DAR=false
_NEXT_IS_CRF=false
_NEXT_IS_SCALE=false

for arg in "$@"; do
    if [[ "$_NEXT_IS_PROFILE" == true ]]; then
        PROFILE="$arg"
        _NEXT_IS_PROFILE=false
    elif [[ "$_NEXT_IS_DAR" == true ]]; then
        DAR_OVERRIDE="$arg"
        _NEXT_IS_DAR=false
    elif [[ "$_NEXT_IS_CRF" == true ]]; then
        CRF_VALUE="$arg"
        _NEXT_IS_CRF=false
    elif [[ "$_NEXT_IS_SCALE" == true ]]; then
        if ! [[ "$arg" =~ ^[0-9]+$ ]] || (( arg < 1 )); then
            echo "Error: --scale requires a positive integer (e.g. --scale 2)."
            exit 1
        fi
        SCALE_FACTOR="$arg"
        _NEXT_IS_SCALE=false
    elif [[ "$arg" == "--profile" ]]; then
        _NEXT_IS_PROFILE=true
    elif [[ "$arg" == "--dar" ]]; then
        _NEXT_IS_DAR=true
    elif [[ "$arg" == "--crf" ]]; then
        _NEXT_IS_CRF=true
    elif [[ "$arg" == "--scale" ]]; then
        _NEXT_IS_SCALE=true
    elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        MASK_PIXELS="$arg"
        MASK_EXPLICITLY_SET=true
    elif [[ "$arg" == "--sharpen" ]]; then
        SHARPEN=true
    elif [[ "$arg" == "--aac" ]]; then
        FORCE_AAC=true
    elif [[ "$arg" == "--test" ]]; then
        TEST_MODE=true
    elif [[ "$arg" == "--60fps" ]]; then
        FORCE_60FPS=true
    elif [[ "$arg" == "--mode0" ]]; then
        BWDIF_MODE=0
    else
        echo "Error: Unknown argument: $arg"
        echo "Run '$0 --help' for usage."
        exit 1
    fi
done

# --- 3. Validate Profile ---
# Each profile has two variants: 30fps (default) and 60fps (bwdif mode=1 masters).
#
# Differences from video_upscale_pipeline.py profiles:
#   - unsharp is removed entirely. In the pipeline it compensated for hqdn3d
#     softening ahead of ESRGAN. Here, lanczos upscaling (default 2x) provides
#     perceived sharpness that more than compensates. For --scale 1 output, use
#     --sharpen to add a conservative unsharp=3:3:0.3 pass if needed.
#   - Spatial denoise (hqdn3d luma_sp:chroma_sp) is raised where appropriate —
#     without ESRGAN hallucinating texture back in, we can safely remove more.
#   - Temporal values in 60fps variants remain halved as in the pipeline:
#     consecutive field-rate frames are closer in time and need less smoothing.
#
# Filter parameter reference:
#   hqdn3d=luma_sp:chroma_sp:luma_tmp:chroma_tmp
#     luma_sp / chroma_sp:   spatial (within-frame) denoise strength
#     luma_tmp / chroma_tmp: temporal (between-frame) denoise strength
#   pp=fd   fast deblock (handles MPEG-2/DVD macroblocking)
#   pp=ac   full deblock + dering (stronger; suits DV DCT artifacts)

declare -A PROFILES_30FPS
declare -A PROFILES_60FPS
declare -A PROFILE_DESCRIPTIONS

# balanced: luma_sp raised 2->3 vs pipeline; unsharp removed (lanczos handles sharpness)
PROFILES_30FPS["balanced"]="hqdn3d=3:3:6:6,pp=fd"
PROFILES_60FPS["balanced"]="hqdn3d=3:3:3:3,pp=fd"
PROFILE_DESCRIPTIONS["balanced"]="Moderate denoise, temporal stability, fast deblock. Hi8/S-Video -> DVD."

# aggressive: luma_sp raised 3->4; unsharp removed
PROFILES_30FPS["aggressive"]="hqdn3d=4:4:6:6,pp=ac"
PROFILES_60FPS["aggressive"]="hqdn3d=4:4:3:3,pp=ac"
PROFILE_DESCRIPTIONS["aggressive"]="Strong spatial denoise, full deblock+dering. Heavy noise or composite captures."

# halo: spatial/temporal unchanged (already heavy); unsharp removed
# Removing unsharp is especially important here — sharpening over heavy denoise
# risks re-introducing the edge artifacts this profile exists to suppress.
PROFILES_30FPS["halo"]="hqdn3d=4:4:8:8,pp=fd"
PROFILES_60FPS["halo"]="hqdn3d=4:4:4:4,pp=fd"
PROFILE_DESCRIPTIONS["halo"]="Heavy denoise to suppress ringing/ghosting around dark edges."

# dv: luma_sp raised 1.5->2.5; unsharp removed
# DV sources are genuinely sharp — lanczos at 2x is sufficient to restore
# perceived crispness without risking sharpening-induced ringing.
PROFILES_30FPS["dv"]="hqdn3d=2.5:2.5:4:4,pp=ac"
PROFILES_60FPS["dv"]="hqdn3d=2.5:2.5:2:2,pp=ac"
PROFILE_DESCRIPTIONS["dv"]="Light-moderate denoise, full deblock+dering. MiniDV/Digital8/DV AVI."

# hi8dv: luma_sp raised 2->3; unsharp removed
PROFILES_30FPS["hi8dv"]="hqdn3d=3:3:5:5,pp=ac"
PROFILES_60FPS["hi8dv"]="hqdn3d=3:3:2.5:2.5,pp=ac"
PROFILE_DESCRIPTIONS["hi8dv"]="Moderate denoise targeting tape grain, full deblock. Hi8 via Digital8/FireWire DV capture."

# vhsdv: luma_sp raised 2.5->3; chroma_sp raised 3->3.5; unsharp removed
PROFILES_30FPS["vhsdv"]="hqdn3d=3:3.5:5:5,pp=ac"
PROFILES_60FPS["vhsdv"]="hqdn3d=3:3.5:2.5:2.5,pp=ac"
PROFILE_DESCRIPTIONS["vhsdv"]="Stronger chroma spatial denoise for VHS color-under noise. VHS via camcorder S-Video passthrough."

# vhsdv_composite: luma_sp raised 2.5->3; chroma_sp raised 3.5->4; unsharp removed
PROFILES_30FPS["vhsdv_composite"]="hqdn3d=3:4:5:5,pp=ac"
PROFILES_60FPS["vhsdv_composite"]="hqdn3d=3:4:2.5:2.5,pp=ac"
PROFILE_DESCRIPTIONS["vhsdv_composite"]="Elevated chroma spatial denoise for dot crawl/cross-colour from composite comb filter. VHS via camcorder composite passthrough."

VALID_PROFILES=("balanced" "aggressive" "halo" "dv" "hi8dv" "vhsdv" "vhsdv_composite")
PROFILE_VALID=false
for p in "${VALID_PROFILES[@]}"; do
    [[ "$PROFILE" == "$p" ]] && PROFILE_VALID=true && break
done
if [[ "$PROFILE_VALID" == false ]]; then
    echo "Error: Unknown profile '$PROFILE'."
    echo "Valid profiles: ${VALID_PROFILES[*]}"
    exit 1
fi

# --- 4. Profile-Based Default Mask ---
# Head-switching noise at the bottom edge is an analog tape artifact present on
# VHS, Hi8, and any other analog tape source. It is absent on native digital
# sources (MiniDV/Digital8 footage recorded digitally) because there is no
# analog tape head transition to produce it.
#
# When the user has not explicitly provided a mask value, apply a profile-based
# default. The 'dv' profile is the only one covering a native digital source;
# all others involve an analog tape at some point in the signal chain.
#
# Default mask by profile:
#   dv                -> 0  (native digital recording — no head-switching noise)
#   all other profiles -> 8  (analog tape source — head-switching noise expected)
#
# The user can always override by providing an explicit mask value on the
# command line, including 0 to suppress masking for a dv-adjacent source.

declare -A PROFILE_DEFAULT_MASK
PROFILE_DEFAULT_MASK["balanced"]=8
PROFILE_DEFAULT_MASK["aggressive"]=8
PROFILE_DEFAULT_MASK["halo"]=8
PROFILE_DEFAULT_MASK["dv"]=0
PROFILE_DEFAULT_MASK["hi8dv"]=8
PROFILE_DEFAULT_MASK["vhsdv"]=8
PROFILE_DEFAULT_MASK["vhsdv_composite"]=8

if [[ "$MASK_EXPLICITLY_SET" == false ]]; then
    MASK_PIXELS="${PROFILE_DEFAULT_MASK[$PROFILE]}"
    MASK_SOURCE="profile default (use an explicit value to override)"
else
    MASK_SOURCE="user specified"
fi

# --- 5. Odd Mask Warning ---
# Odd mask values split 2x2 YUV420p chroma blocks, producing green/purple fringing.
if (( MASK_PIXELS % 2 != 0 )); then
    echo -e "\n⚠️  WARNING: Mask ($MASK_PIXELS) is an odd number."
    echo "    This can cause green/purple lines due to YUV420p chroma alignment."
    echo "    Recommend using $((MASK_PIXELS + 1)) instead."
fi

# --- 6. ISO Guard ---
if [[ "${SOURCE_INPUT,,}" == *.iso ]]; then
    echo -e "\n[!] ERROR: Cannot process .ISO files directly."
    echo "    1. Mount the ISO (e.g., open it in your file manager)."
    echo "    2. Combine the VOBs: 'cat VIDEO_TS/VTS_01_*.VOB | ffmpeg -i - -c copy master.mpg'"
    echo "    3. Run this script on the resulting .mpg file."
    exit 1
fi

# --- 7. Early Summary: Confirm Arguments Before Probing ---
# Show what is known from command-line arguments alone and get user confirmation
# before running the slow probing steps (timestamp check, interlace detection,
# and potentially idet pixel analysis). This catches configuration mistakes
# (wrong profile, wrong mask) without waiting minutes for probing to complete.
echo ""
echo "========================================="
echo "         ARGUMENT SUMMARY"
echo "========================================="
echo "Source file:   $SOURCE_INPUT"
echo "Profile:       $PROFILE  —  ${PROFILE_DESCRIPTIONS[$PROFILE]}"
echo "Bottom mask:   ${MASK_PIXELS}px  ($MASK_SOURCE)"
echo "Scale:         $([ "$SCALE_FACTOR" -gt 1 ] && echo "${SCALE_FACTOR}x lanczos" || echo "none (native resolution)")"
echo "Sharpen:       $([ "$SHARPEN" == true ] && echo "yes (unsharp=3:3:0.3)" || echo "no")"
echo "bwdif mode:    $([ "$BWDIF_MODE" -eq 1 ] && echo "1 (field-rate ~60fps, default)" || echo "0 (frame-rate ~30fps, --mode0)")"
echo "CRF:           $CRF_VALUE"
echo "Audio:         $([ "$FORCE_AAC" == true ] && echo "AAC 192k (--aac)" || echo "lossless copy (default)")"
echo "Test mode:     $([ "$TEST_MODE" == true ] && echo "yes (first 30s only)" || echo "no")"
if [[ -n "$DAR_OVERRIDE" ]]; then
    echo "DAR override:  $DAR_OVERRIDE"
fi
echo "========================================="
echo ""
echo "  Probing will now run to detect scan type, field order, timestamps,"
echo "  and display aspect ratio. This is fast unless idet pixel analysis"
echo "  is needed (only if all structural detection tiers fail)."
echo ""
read -p "Arguments look correct? Proceed to probe? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled. Adjust arguments and re-run."
    exit 0
fi

# --- 8. Probe: Codec, Dimensions, FPS, Pixel Format, Field Order, SAR ---
echo ""
echo "--- Step 1: Probing source ---"

# Individual ffprobe calls per field, matching the approach used in
# prepare_video.sh which is proven to work on raw .dv files without
# any special format hints. A single JSON probe with grep/sed parsing
# is avoided because fields like duration are absent in raw DV containers,
# causing set -e to exit silently on empty variables.

SOURCE_CODEC=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

if [[ -z "$SOURCE_CODEC" ]]; then
    echo "[!] ERROR: ffprobe found no video stream in: $SOURCE_INPUT"
    echo "    Try: ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \"$SOURCE_INPUT\""
    exit 1
fi

SRC_WIDTH=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

SRC_HEIGHT=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

PIX_FMT=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=pix_fmt \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

STREAM_FPS=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

# Stream-level duration — absent in raw DV containers; handled gracefully
# in the timestamp detection section via format-level and packet-count fallbacks.
STREAM_DUR=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

FIELD_ORDER_RAW=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=field_order \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

SRC_SAR=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=sample_aspect_ratio \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

AUDIO_FORMAT=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_INPUT" 2>/dev/null)

# Validate minimum required fields before proceeding.
if [[ -z "$SRC_WIDTH" || -z "$SRC_HEIGHT" || -z "$STREAM_FPS" ]]; then
    echo "[!] ERROR: ffprobe returned incomplete metadata for: $SOURCE_INPUT"
    echo "    codec=$SOURCE_CODEC  width=${SRC_WIDTH:-empty}  height=${SRC_HEIGHT:-empty}  fps=${STREAM_FPS:-empty}"
    exit 1
fi

# Evaluate FPS fraction (e.g. "30000/1001" -> 29.970)
SOURCE_FPS_FLOAT=$(echo "$STREAM_FPS" | awk -F'/' \
    '{ if (NF==2 && $2!=0) printf "%.3f", $1/$2; else printf "%.3f", $1 }')

echo "  Codec:      $SOURCE_CODEC"
echo "  Resolution: ${SRC_WIDTH}x${SRC_HEIGHT}"
echo "  Pixel fmt:  ${PIX_FMT:-unknown}"
echo "  FPS:        $STREAM_FPS ($SOURCE_FPS_FLOAT)"
echo "  Audio:      ${AUDIO_FORMAT:-none}"
echo "  SAR:        ${SRC_SAR:-not set}"

# --- 9. Broken Timestamp Detection ---
# Hauppauge and some AVI muxers write absurd DTS values that produce durations
# > 24 hours. MKV stream duration is often simply absent (0). Both require
# falling through to a better duration source and trigger +genpts on encode.
#
# Duration resolution priority (mirrors probe_video.py check_bitrate_health):
#   1. Stream-level duration  — fast; reliable for AVI/MP4 with intact headers
#   2. Format-level duration  — fast; reliable for MKV and most other containers
#   3. Packet count           — fast; no decoding, reads index only
#   4. Frame count            — last resort; decodes every frame, slow on large files
#
# If all four tiers fail the script aborts — there is no silent fallback.
# +genpts is enabled whenever the stream-level duration was absent or unrealistic,
# regardless of which later tier successfully resolved the duration.

echo ""
echo "--- Step 2: Checking timestamps ---"

FFLAGS=""
BROKEN_DURATION=false
NEEDS_GENPTS=false

# Tier 1: stream-level duration
DURATION_SEC=""
if [[ -n "$STREAM_DUR" && "$STREAM_DUR" != "N/A" ]]; then
    IS_UNREALISTIC=$(echo "$STREAM_DUR" | awk '{ print ($1 <= 0 || $1 > 86400) ? "yes" : "no" }')
    if [[ "$IS_UNREALISTIC" == "no" ]]; then
        DURATION_SEC="$STREAM_DUR"
        echo "  Duration:   ${DURATION_SEC}s  (stream-level)"
    else
        BROKEN_DURATION=true
        NEEDS_GENPTS=true
        echo "  [WARN] Stream-level duration is unrealistic ($STREAM_DUR s) — trying format level."
    fi
else
    BROKEN_DURATION=true
    NEEDS_GENPTS=true
    echo "  [WARN] Stream-level duration absent — trying format level."
fi

# Tier 2: format-level duration (MKV stores it here, not in the stream)
if [[ "$BROKEN_DURATION" == true ]]; then
    FMT_DUR=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$SOURCE_INPUT" 2>/dev/null)
    IS_UNREALISTIC=$(echo "${FMT_DUR:-0}" | awk '{ print ($1 <= 0 || $1 > 86400) ? "yes" : "no" }')
    if [[ -n "$FMT_DUR" && "$FMT_DUR" != "N/A" && "$IS_UNREALISTIC" == "no" ]]; then
        DURATION_SEC="$FMT_DUR"
        BROKEN_DURATION=false
        echo "  Duration:   ${DURATION_SEC}s  (format/container level)"
    else
        echo "  [WARN] Format-level duration also unreliable — trying packet count."
    fi
fi

# Tier 3: packet count (reads index, no decoding)
if [[ "$BROKEN_DURATION" == true ]]; then
    PKT_COUNT=$(ffprobe -v error \
        -select_streams v:0 \
        -count_packets \
        -show_entries stream=nb_read_packets \
        -of csv=p=0 \
        "$SOURCE_INPUT" 2>/dev/null || true)
    if [[ "$PKT_COUNT" =~ ^[0-9]+$ ]] && (( PKT_COUNT > 0 )); then
        DURATION_SEC=$(echo "$PKT_COUNT $SOURCE_FPS_FLOAT" | awk '{ printf "%.3f", $1 / $2 }')
        BROKEN_DURATION=false
        echo "  Duration:   ${DURATION_SEC}s  (estimated from $PKT_COUNT packets)"
    else
        echo "  [WARN] Packet count unavailable — falling back to full frame decode (slow)."
    fi
fi

# Tier 4: frame count — decodes every frame; slow on long files
if [[ "$BROKEN_DURATION" == true ]]; then
    echo "  [WARN] Counting frames to determine duration (may take several minutes)..."
    FRAME_COUNT=$(ffprobe -v error \
        -count_frames \
        -select_streams v:0 \
        -show_entries stream=nb_read_frames \
        -of csv=p=0 \
        "$SOURCE_INPUT" 2>/dev/null || true)
    if [[ "$FRAME_COUNT" =~ ^[0-9]+$ ]] && (( FRAME_COUNT > 0 )); then
        DURATION_SEC=$(echo "$FRAME_COUNT $SOURCE_FPS_FLOAT" | awk '{ printf "%.3f", $1 / $2 }')
        BROKEN_DURATION=false
        echo "  Duration:   ${DURATION_SEC}s  (estimated from $FRAME_COUNT frames)"
    fi
fi

if [[ "$BROKEN_DURATION" == true ]]; then
    echo ""
    echo "[!] ERROR: Could not determine video duration through any available method."
    echo "    The file may be corrupt or have a completely broken container."
    echo "    Try: ffprobe -v error -show_format -show_streams \"$SOURCE_INPUT\""
    exit 1
fi

if [[ "$NEEDS_GENPTS" == true ]]; then
    FFLAGS="-fflags +genpts"
    echo "  [INFO] Broken/missing stream timestamps — enabling PTS regeneration (+genpts)."
fi

# --- 10. Interlace and Field Order Detection ---
# Priority mirrors probe_video.py detect_interlace():
#   1. DV codec shortcut
#   2. ffprobe stream field_order metadata
#   3. ffprobe frame-level interlaced_frame flags (first 50 frames)
#   4. ffmpeg idet pixel-level heuristic (last resort — slow)
#
# Ambiguous idet results (15-20% interlace ratio) abort with instructions
# rather than silently defaulting to either progressive or interlaced.

echo ""
echo "--- Step 3: Detecting scan type and field order ---"

IS_INTERLACED=false
PARITY="-1"
FIELD_ORDER="Unknown"
FIELD_ORDER_UC="${FIELD_ORDER_RAW^^}"

IS_DV_SOURCE=false
if [[ "$SOURCE_CODEC" == dv* ]]; then
    # DV from FireWire capture is always BFF on NTSC regardless of what ffprobe
    # reports. The AVI container does not store field order metadata for DV
    # streams, causing ffprobe to return 'unknown'. Shortcut here to avoid
    # misleading fallthrough to later detection tiers.
    IS_DV_SOURCE=true
    IS_INTERLACED=true
    PARITY="1"
    FIELD_ORDER="Interlaced BFF (Bottom Field First — DV/NTSC, codec-based detection)"
    echo "  [Tier 1] DV codec detected ($SOURCE_CODEC) — BFF assumed (NTSC standard)."
    echo "  [INFO]   'AC EOB marker' warnings during encode are normal for DV tape"
    echo "           leader frames and will stop after the first few seconds."

elif [[ "$FIELD_ORDER_UC" == "PROGRESSIVE" ]]; then
    IS_INTERLACED=false
    PARITY="-1"
    FIELD_ORDER="Progressive"
    echo "  [Tier 2] ffprobe field_order: Progressive"

elif [[ "$FIELD_ORDER_UC" == "TT" ]]; then
    IS_INTERLACED=true
    PARITY="0"
    FIELD_ORDER="Interlaced TFF (Top Field First — ffprobe stream metadata)"
    echo "  [Tier 2] ffprobe field_order: TFF (Top Field First)"

elif [[ "$FIELD_ORDER_UC" == "BB" || "$FIELD_ORDER_UC" == "BT" ]]; then
    IS_INTERLACED=true
    PARITY="1"
    FIELD_ORDER="Interlaced BFF (Bottom Field First — ffprobe stream metadata)"
    echo "  [Tier 2] ffprobe field_order: BFF (Bottom Field First)"

else
    # Tier 2 was inconclusive. Proceed through tiers 3 and 4.
    echo "  [Tier 2] ffprobe field_order: '${FIELD_ORDER_RAW:-unknown}' — trying frame flags."
    echo "  [Tier 3] Checking interlaced_frame flags on first 50 frames..."

    FRAME_FLAGS=$(ffprobe -v error \
        -select_streams v:0 \
        -show_frames \
        -read_intervals "%+#50" \
        "$SOURCE_INPUT" 2>/dev/null || true)

    INTERLACED_SUM=$(echo "$FRAME_FLAGS" | grep "interlaced_frame=" | \
        awk -F= '{s+=$2} END {print s+0}')
    INTERLACED_COUNT=$(echo "$FRAME_FLAGS" | grep -c "interlaced_frame=" || true)

    TIER3_RESOLVED=false

    if [[ "$INTERLACED_COUNT" -gt 0 && "$INTERLACED_SUM" -eq 0 ]]; then
        IS_INTERLACED=false
        PARITY="-1"
        FIELD_ORDER="Progressive (frame-flag detection — 0/$INTERLACED_COUNT frames interlaced)"
        echo "  [Tier 3] Result: Progressive (0/$INTERLACED_COUNT frames flagged interlaced)"
        TIER3_RESOLVED=true

    elif [[ "$INTERLACED_COUNT" -gt 0 && "$INTERLACED_SUM" -gt 0 ]]; then
        TFF_SUM=$(echo "$FRAME_FLAGS" | grep "top_field_first=" | \
            awk -F= '{s+=$2} END {print s+0}')
        TFF_COUNT=$(echo "$FRAME_FLAGS" | grep -c "top_field_first=" || true)

        if [[ "$TFF_COUNT" -gt 0 ]]; then
            BFF_SUM=$(( TFF_COUNT - TFF_SUM ))
            IS_INTERLACED=true
            TIER3_RESOLVED=true
            if (( TFF_SUM > BFF_SUM )); then
                PARITY="0"
                FIELD_ORDER="Interlaced TFF (Top Field First — frame-flag detection)"
                echo "  [Tier 3] Result: Interlaced TFF ($TFF_SUM TFF / $BFF_SUM BFF of $TFF_COUNT frames)"
            else
                PARITY="1"
                FIELD_ORDER="Interlaced BFF (Bottom Field First — frame-flag detection)"
                echo "  [Tier 3] Result: Interlaced BFF ($BFF_SUM BFF / $TFF_SUM TFF of $TFF_COUNT frames)"
            fi
        else
            echo "  [Tier 3] Interlaced frames detected but top_field_first absent — falling through to idet."
        fi
    else
        echo "  [Tier 3] No interlaced_frame flags present — falling through to idet."
    fi

    # Tier 4: idet pixel-level heuristic — reached only when tiers 1-3 are inconclusive.
    if [[ "$TIER3_RESOLVED" == false ]]; then
        echo "  [Tier 4] Running idet on first 500 frames (pixel-level analysis — may take a moment)..."

        IDET_OUTPUT=$(ffmpeg -i "$SOURCE_INPUT" \
            -filter:v idet \
            -frames:v 500 \
            -an -f null - 2>&1 || true)

        IDET_LINE=$(echo "$IDET_OUTPUT" | grep "Multi frame detection:" | tail -1)

        if [[ -z "$IDET_LINE" ]]; then
            echo ""
            echo "[!] ERROR: idet filter produced no usable output."
            echo "    The file may be corrupt or unreadable by ffmpeg."
            echo "    Try: ffmpeg -i \"$SOURCE_INPUT\" -filter:v idet -frames:v 50 -an -f null -"
            exit 1
        fi

        IDET_TFF=$(echo  "$IDET_LINE" | grep -oP 'TFF:\s*\K[0-9]+')
        IDET_BFF=$(echo  "$IDET_LINE" | grep -oP 'BFF:\s*\K[0-9]+')
        IDET_PROG=$(echo "$IDET_LINE" | grep -oP 'Progressive:\s*\K[0-9]+')
        IDET_TOTAL=$(( IDET_TFF + IDET_BFF + IDET_PROG ))

        echo "  [Tier 4] idet: TFF=$IDET_TFF  BFF=$IDET_BFF  Progressive=$IDET_PROG  Total=$IDET_TOTAL"

        if (( IDET_TOTAL == 0 )); then
            echo ""
            echo "[!] ERROR: idet returned all-zero counts."
            echo "    The file may have no decodable frames in the first 500."
            echo "    Try playing the file in VLC to confirm it is readable."
            exit 1
        fi

        IDET_INTERLACE_RATIO=$(echo "$IDET_TFF $IDET_BFF $IDET_TOTAL" | \
            awk '{ printf "%.4f", ($1 + $2) / $3 }')

        # Thresholds mirror probe_video.py:
        #   < 15%  -> progressive (field artifacts are codec noise in a clean source)
        #   15-20% -> ambiguous — abort rather than guess wrong
        #   > 20%  -> interlaced
        IS_PROGRESSIVE_IDET=$(echo "$IDET_INTERLACE_RATIO" | \
            awk '{ print ($1 < 0.15) ? "yes" : "no" }')
        IS_AMBIGUOUS_IDET=$(echo "$IDET_INTERLACE_RATIO" | \
            awk '{ print ($1 >= 0.15 && $1 <= 0.20) ? "yes" : "no" }')

        if [[ "$IS_PROGRESSIVE_IDET" == "yes" ]]; then
            IS_INTERLACED=false
            PARITY="-1"
            FIELD_ORDER="Progressive (idet: interlace ratio ${IDET_INTERLACE_RATIO}, below 15% threshold)"
            echo "  [Tier 4] Result: Progressive (ratio ${IDET_INTERLACE_RATIO} < 0.15)"

        elif [[ "$IS_AMBIGUOUS_IDET" == "yes" ]]; then
            echo ""
            echo "[!] ERROR: idet result is ambiguous (interlace ratio ${IDET_INTERLACE_RATIO}, in the 15-20% grey zone)."
            echo "    Cannot safely determine whether this source is interlaced or progressive."
            echo ""
            echo "    To diagnose:"
            echo "      Play the file in VLC and look for comb teeth (alternating horizontal"
            echo "      lines) on fast-moving edges. Combing = interlaced; smooth = progressive."
            echo ""
            echo "    To proceed:"
            echo "      If interlaced: the source is likely NTSC analog (VHS/Hi8/DV)."
            echo "        Re-run with the same arguments — the script will use bwdif with"
            echo "        parity auto-detect if field order cannot be determined upstream."
            echo "        If you know the field order, open an issue with your ffprobe output."
            echo "      If progressive: the idet hits are likely compression artifacts."
            echo "        The source does not need deinterlacing."
            exit 1

        else
            # ratio > 20% -> interlaced
            IS_INTERLACED=true
            if (( IDET_TFF > IDET_BFF )); then
                PARITY="0"
                FIELD_ORDER="Interlaced TFF (Top Field First — idet: TFF=$IDET_TFF BFF=$IDET_BFF)"
                echo "  [Tier 4] Result: Interlaced TFF (ratio ${IDET_INTERLACE_RATIO})"
            else
                PARITY="1"
                FIELD_ORDER="Interlaced BFF (Bottom Field First — idet: BFF=$IDET_BFF TFF=$IDET_TFF)"
                echo "  [Tier 4] Result: Interlaced BFF (ratio ${IDET_INTERLACE_RATIO})"
            fi
        fi
    fi
fi

# --- 11. Source FPS and Profile Variant Selection ---
# Auto-detect 60fps master unless overridden by --60fps.
# The 45fps threshold cleanly separates 29.97/25fps from 59.94/50fps masters.
IS_60FPS=false
if [[ "$FORCE_60FPS" == true ]]; then
    IS_60FPS=true
    echo ""
    echo "  [INFO] --60fps flag: using 60fps profile variant."
elif (( $(echo "$SOURCE_FPS_FLOAT > 45" | bc -l) )); then
    IS_60FPS=true
    echo ""
    echo "  [INFO] Source FPS ($SOURCE_FPS_FLOAT) > 45 — auto-selecting 60fps profile variant."
fi

if [[ "$IS_60FPS" == true ]]; then
    PREFILTER_VF="${PROFILES_60FPS[$PROFILE]}"
    FPS_LABEL="src>45fps hqdn3d variant"
else
    PREFILTER_VF="${PROFILES_30FPS[$PROFILE]}"
    FPS_LABEL="src≤45fps hqdn3d variant"
fi

# --- 12. Audio Strategy ---
# MP4 does not support PCM audio. When PCM is detected the output container
# is switched to MKV, which supports PCM natively, and audio is stream-copied
# bit-for-bit. Use --aac to force AAC and keep an MP4 container instead.
if [[ "$FORCE_AAC" == true ]]; then
    AUDIO_CMD="-c:a aac -b:a 192k"
    AUDIO_PLAN="CONVERT (Forced AAC — 192k lossy)"
    CONTAINER="mp4"
elif [[ "$AUDIO_FORMAT" == pcm* ]]; then
    AUDIO_CMD="-c:a copy"
    AUDIO_PLAN="LOSSLESS (PCM preserved bit-for-bit — output container: .mkv)"
    CONTAINER="mkv"
else
    AUDIO_CMD="-c:a copy"
    AUDIO_PLAN="LOSSLESS (Bitstream copy of ${AUDIO_FORMAT:-unknown})"
    CONTAINER="mp4"
fi

# --- 13. DAR (Display Aspect Ratio) Auto-Detection ---
#
# Priority:
#   1. --dar override (user always wins)
#   2. SAR metadata from container, if set and non-trivial
#      SAR 8:9   -> NTSC 4:3  (720x480 -> display 640x480)
#      SAR 32:27 -> NTSC 16:9 (720x480 -> display 853x480)
#      SAR 16:15 -> PAL 4:3   (720x576 -> display 768x576)
#      SAR 64:45 -> PAL 16:9  (720x576 -> display 1024x576)
#   3. Resolution heuristics for formats where SAR is absent (e.g. raw DV AVI)
#      720x480 / 704x480 / 352x480 -> 4:3 NTSC default
#      720x576 / 704x576 / 352x576 -> 4:3 PAL default
#      352x240 / 352x288            -> 4:3 VCD/half-D1
#      Anything else                -> square pixels assumed
#
# --scale N multiplies pixel dimensions but does not change the display aspect
# ratio — the same DAR value is correct at any scale factor.

echo ""
echo "--- Step 4: Detecting display aspect ratio ---"

DAR=""
DAR_SOURCE=""

gcd() {
    local a=$1 b=$2
    while (( b )); do local t=$b; b=$(( a % b )); a=$t; done
    echo "$a"
}

if [[ -n "$DAR_OVERRIDE" ]]; then
    DAR="$DAR_OVERRIDE"
    DAR_SOURCE="user override (--dar)"

elif [[ -n "$SRC_SAR" && "$SRC_SAR" != "N/A" && "$SRC_SAR" != "0:1" && "$SRC_SAR" != "1:1" ]]; then
    SAR_NUM=$(echo "$SRC_SAR" | cut -d: -f1)
    SAR_DEN=$(echo "$SRC_SAR" | cut -d: -f2)
    DISPLAY_W=$(( SRC_WIDTH * SAR_NUM / SAR_DEN ))
    G=$(gcd "$DISPLAY_W" "$SRC_HEIGHT")
    DAR="$(( DISPLAY_W / G )):$(( SRC_HEIGHT / G ))"
    DAR_SOURCE="SAR metadata (${SRC_SAR} -> display ${DISPLAY_W}x${SRC_HEIGHT})"

else
    case "${SRC_WIDTH}x${SRC_HEIGHT}" in
        720x480|704x480|352x480)
            DAR="4:3"
            DAR_SOURCE="resolution heuristic (NTSC 4:3 default; use --dar 16:9 to override for widescreen DV)"
            ;;
        720x576|704x576|352x576)
            DAR="4:3"
            DAR_SOURCE="resolution heuristic (PAL 4:3 default; use --dar 16:9 to override for widescreen)"
            ;;
        352x240|352x288)
            DAR="4:3"
            DAR_SOURCE="resolution heuristic (VCD/half-D1 4:3)"
            ;;
        *)
            DAR=""
            DAR_SOURCE="square pixels assumed (no SAR metadata, no matching heuristic)"
            ;;
    esac
fi

if [[ -n "$DAR" ]]; then
    DAR_CMD="-aspect $DAR"
    DAR_LABEL="$DAR  ($DAR_SOURCE)"
else
    DAR_CMD=""
    DAR_LABEL="not set — square pixels  ($DAR_SOURCE)"
fi
echo "  DAR: $DAR_LABEL"

# --- 14. Lanczos Upscale and Optional Sharpen ---
# Scale and sharpen are kept separate from PREFILTER_VF so they can be
# appended AFTER the drawbox mask in the filter chain (step 16).
# This ensures drawbox operates at source resolution — matching prepare_video.sh —
# and the mask value refers to source pixels regardless of scale factor.
# If scale were inside PREFILTER_VF it would run before drawbox, causing the
# mask to cover only source-resolution pixels on an already-upscaled frame.
UPSCALE_LABEL=""
POSTFILTER_VF=""
if [[ "$SCALE_FACTOR" -gt 1 ]]; then
    POSTFILTER_VF="scale=iw*${SCALE_FACTOR}:ih*${SCALE_FACTOR}:flags=lanczos"
    UPSCALE_LABEL="_${SCALE_FACTOR}x"
fi
if [[ "$SHARPEN" == true ]]; then
    if [[ -n "$POSTFILTER_VF" ]]; then
        POSTFILTER_VF="${POSTFILTER_VF},unsharp=3:3:0.3"
    else
        POSTFILTER_VF="unsharp=3:3:0.3"
    fi
fi

# --- 15. Path and Filename Setup ---
BASE_NAME=$(basename "$SOURCE_INPUT")
FILE_STEM="${BASE_NAME%.*}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="outputs"
mkdir -p "$OUTPUT_DIR"

if [[ "$IS_INTERLACED" == true ]]; then
    DEINT_LABEL="_$([ "$BWDIF_MODE" -eq 0 ] && echo "30fps" || echo "60fps")"
else
    DEINT_LABEL=""
fi

if [[ "$TEST_MODE" == true ]]; then
    OUTPUT_FILE="${OUTPUT_DIR}/${FILE_STEM}_${PROFILE}${UPSCALE_LABEL}${DEINT_LABEL}_mask${MASK_PIXELS}_TEST.${CONTAINER}"
    LIMIT_CMD="-t 30"
    TEST_LABEL=" (TEST MODE: 30s)"
else
    OUTPUT_FILE="${OUTPUT_DIR}/${FILE_STEM}_${PROFILE}${UPSCALE_LABEL}${DEINT_LABEL}_mask${MASK_PIXELS}_${TIMESTAMP}.${CONTAINER}"
    LIMIT_CMD=""
    TEST_LABEL=""
fi

# --- 16. Build Filter Chain ---
# Order: deinterlace -> format=yuv420p -> profile filters -> mask -> scale -> sharpen
#
# bwdif must precede format=yuv420p — it operates on the interlaced field
# structure and must see the original pixel format.
# format=yuv420p normalises before the denoise chain.
# drawbox runs at source resolution (before scale) — matching prepare_video.sh.
# This means the mask value always refers to source pixels: 8px on a 480-line
# source stays 8px of black on 480 lines before being upscaled to 16px of black
# on 960 lines, correctly covering the full noise band at output resolution.
# scale and sharpen (POSTFILTER_VF) are appended last.
#
# For progressive sources bwdif is omitted; the chain starts with format=yuv420p.

if [[ "$IS_INTERLACED" == true ]]; then
    FILTER_CHAIN="bwdif=mode=${BWDIF_MODE}:parity=${PARITY}:deint=0,format=yuv420p,${PREFILTER_VF}"
else
    FILTER_CHAIN="format=yuv420p,${PREFILTER_VF}"
fi

if [[ "$MASK_PIXELS" -gt 0 ]]; then
    FILTER_CHAIN="${FILTER_CHAIN},drawbox=y=ih-${MASK_PIXELS}:h=${MASK_PIXELS}:color=black:t=fill"
fi

if [[ -n "$POSTFILTER_VF" ]]; then
    FILTER_CHAIN="${FILTER_CHAIN},${POSTFILTER_VF}"
fi

# --- 17. Pre-Flight Summary ---
echo ""
echo "========================================="
echo "       PRE-FLIGHT SUMMARY${TEST_LABEL}"
echo "========================================="
echo "Source File:   $SOURCE_INPUT"
echo "  Codec:       $SOURCE_CODEC"
echo "  Dimensions:  ${SRC_WIDTH}x${SRC_HEIGHT}  |  Pixel fmt: $PIX_FMT"
echo "  Duration:    ${DURATION_SEC}s"
echo "Output File:   $OUTPUT_FILE"
echo "-----------------------------------------"
if [[ "$IS_INTERLACED" == true ]]; then
    if [[ "$BWDIF_MODE" -eq 1 ]]; then
        echo "Deinterlace:   bwdif mode=1 (field-rate ~60fps)  |  ${FIELD_ORDER}"
    else
        echo "Deinterlace:   bwdif mode=0 (frame-rate ~30fps)  |  ${FIELD_ORDER}"
    fi
else
    echo "Deinterlace:   not needed (source is progressive)"
fi
echo "Bottom Mask:   ${MASK_PIXELS}px  ($MASK_SOURCE)"
echo "Profile:       $PROFILE ($FPS_LABEL variant)  —  ${PROFILE_DESCRIPTIONS[$PROFILE]}"
echo "Upscale:       $([ "$SCALE_FACTOR" -gt 1 ] && echo "${SCALE_FACTOR}x lanczos" || echo "none (--scale 1)")"
echo "Sharpen:       $([ "$SHARPEN" == true ] && echo "yes (unsharp=3:3:0.3)" || echo "no")"
echo "DAR:           $DAR_LABEL"
echo "CRF:           $CRF_VALUE"
echo "Audio:         $AUDIO_PLAN"
if [[ -n "$FFLAGS" ]]; then
    echo "PTS repair:    enabled (+genpts — broken/missing stream timestamps)"
fi
echo "-----------------------------------------"
echo "Filter chain:  $FILTER_CHAIN"
echo "========================================="
if [[ "$IS_INTERLACED" == true ]]; then
    echo ""
    echo "  ⚠️  WARNING: Deinterlacing is CPU-intensive. This will take a while."
fi
echo ""
read -p "Ready to encode? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# --- 18. Encode ---
echo ""
echo "--- Step 5: Encoding ---"
echo "Output: $OUTPUT_FILE"
echo ""

# ffmpeg argument order notes:
#   $FFLAGS (+genpts) and $LIMIT_CMD (-t 30) are placed BEFORE -i so they
#   act as input options.
#     +genpts: regenerates PTS on decode for sources with broken timestamps.
#     -t N:    limits how much of the source is read (not just output duration).
#   -threads 0 lets libx264 auto-detect the optimal thread count for the host.
#   -preset slower prioritises quality and compression efficiency over speed.
#   -movflags +faststart is MP4-specific but harmless on MKV (ignored silently).

ffmpeg -y $FFLAGS $LIMIT_CMD -i "$SOURCE_INPUT" \
    -vf "$FILTER_CHAIN" \
    $DAR_CMD \
    -c:v libx264 -threads 0 -crf "$CRF_VALUE" -preset slower \
    -pix_fmt yuv420p \
    -movflags +faststart \
    $AUDIO_CMD \
    "$OUTPUT_FILE"

echo ""
echo "✅ Done! Output: $OUTPUT_FILE"

} # end main
main "$@"
