#!/bin/bash
# dvd_encode.sh — Encode a DVD-extracted MPG or upscaled video to a
# distribution-ready MP4 (H.264 + AAC) with embedded chapter markers.
#
# This script is the final step in the DVD preservation pipeline:
#
#   dvd_extract.sh  ->  dvd_encode.sh
#
# It can be used in two ways:
#
#   1. Direct from extraction (default --passthrough mode):
#      Takes the .mpg from dvd_extract.sh, runs the pre-flight probe,
#      deinterlaces with bwdif (field order auto-detected), applies the chosen
#      pre-filter profile, and encodes to MP4.  No upscaling.  Output resolution
#      matches the source (720x480 NTSC).  Useful for testing the full pipeline,
#      or when a smaller file size is preferred over the upscaled version.
#
#   2. From upscaled source (--upscaled):
#      Takes a progressive video file produced by Real-ESRGAN or similar.
#      No deinterlacing applied.  Pre-filter profiles are still available and
#      applied to clean up any encoding artifacts from the upscaler.
#
# Pre-filter profiles (--profile):
#   balanced         Default. Hi8/S-Video -> DVD (~4.6Mbps source).
#                    hqdn3d=2:2:6:6, pp=fd, unsharp=3:3:0.2
#   aggressive       Heavy noise, composite captures, low-bitrate DVD.
#                    hqdn3d=3:3:6:6, pp=ac, unsharp=3:3:0.6
#   halo             White ghost lines / ringing around dark edges.
#                    hqdn3d=4:4:8:8, pp=fd  (no unsharp — avoids reintroducing
#                    edge artifacts; use --sharpen only after verifying halo is gone)
#
#
#   60fps variants (halved temporal hqdn3d) are auto-selected when source FPS
#   exceeds 45fps (i.e. bwdif mode=1 field-rate output from prepare_video.sh).
#
# Usage:
#   ./dvd_encode.sh [OPTIONS] <input_video> <chapter_file>
#
# Arguments:
#   <input_video>    DVD-extracted MPEG-2 video file (.mpg from dvd_extract.sh).
#   <chapter_file>   OGM chapter file from dvd_extract.sh
#                    (<stem>_title_NN_chapters.txt).
#                    Optional when --names is provided: the script searches for
#                    <stem>_title_NN_chapters.txt files in the same directory as
#                    <input_video> and auto-selects the one whose chapter count
#                    matches the line count of the names file.  If more than one
#                    matches, the script lists them and asks which to use.
#
# Options:
#   --scale N        Deterministic Lanczos upscale by integer factor N after all
#                    other filters (default: 2).  Common: 1 (no upscale) or 4.
#                    DAR is preserved.
#   --profile NAME   Pre-filter profile (default: balanced).
#                    Choices: balanced aggressive halo
#   --mode0          Use bwdif mode=0 (frame-rate ~30fps output).
#                    Default is mode=1 (field-rate ~60fps output).
#                    mode=1: each field becomes a progressive frame (~60fps),
#                    preserving full temporal resolution for fast motion.
#                    mode=0: both fields combined into one frame (~30fps),
#                    lower CPU cost and smaller output file.
#   --mask N         Black out the bottom N pixels (must be even).  Masks
#                    head-switching noise at the bottom edge of the frame.
#                    Default: 0 (DVD sources generally do not have this issue).
#   --sharpen        Apply an additional unsharp=3:3:0.3 pass after all other
#                    filters.  Most profiles include unsharp=3:3:0.2 already;
#                    --sharpen adds a second pass bringing effective strength
#                    to ~0.5.  Exception: the halo profile has no built-in
#                    unsharp -- --sharpen adds the only sharpening pass.
#   --dar W:H        Override auto-detected display aspect ratio.  DAR is
#                    normally inferred from SAR metadata or resolution
#                    heuristics (720x480 NTSC -> 4:3).  Use only if a player
#                    displays the wrong aspect ratio.  Example: --dar 16:9
#   --names FILE     Plain-text chapter names file, one title per line, count
#                    matching the chapters in <chapter_file>.
#   --crf N          H.264 CRF quality (default: 18).  16 is near-transparent;
#                    23 is ffmpeg default.  Lower = larger file.
#   --preset NAME    H.264 encoding preset (default: slower).
#                    Choices: ultrafast fast medium slow slower veryslow
#   -o, --output FILE  Output MP4 filename.
#                    Default: <input_stem>_encoded.mp4
#   --test           Process only the first 30 seconds for a quick preview.
#   -h, --help       Show this help and exit.
#
# Output:
#   <output>.mp4  H.264 video + AAC 192k audio, progressive, with chapters.
#
# Filter chain order:
#   bwdif -> format=yuv420p -> hqdn3d -> pp -> [unsharp] -> [drawbox mask]
#   -> [--sharpen] -> [--scale lanczos]
#
# drawbox always runs at source resolution; --scale always runs last.
#
# Dependencies (all available via apt):
#   Required : ffmpeg
#              python3
#   Chapters : mkvtoolnix  (mkvpropedit -- MKV in-place chapter injection)
#              gpac       (MP4Box -- MP4 chapter injection)
#   Optional : xxhash      (xxhsum -- output integrity verification)
#
# NOTE: The entire script is wrapped in main() so bash reads the complete file
# into memory before execution begins. This prevents mid-run file replacement
# from affecting an in-progress encode.
#
set -euo pipefail

main() {

# ==============================================================================
# Usage
# ==============================================================================
usage() {
    sed -n '2,/^set -euo/{ /^set -euo/d; s/^# \{0,1\}//; p }' "$0"
    exit 0
}

# ==============================================================================
# Defaults
# ==============================================================================
SCALE_FACTOR=2      # default: 2x Lanczos upscale; use --scale 1 for source resolution
PROFILE="balanced"
BWDIF_MODE=1
MASK_PIXELS=0
MASK_EXPLICITLY_SET=false
SHARPEN=false
DAR_OVERRIDE=""
NAMES_FILE=""
CRF=18
PRESET="slower"
OUTPUT_STEM=""  # output filename stem (no extension)
OUTPUT_MODE="both"  # both | mp4only | mkvonly
TEST_MODE=false
INPUT_VIDEO=""
CHAPTER_FILE=""

# ==============================================================================
# Argument parsing
# ==============================================================================
_NEXT=""
while [[ $# -gt 0 ]]; do
    if [[ -n "$_NEXT" ]]; then
        case "$_NEXT" in
            profile)  PROFILE="$1"  ;;
            mask)     MASK_PIXELS="$1"; MASK_EXPLICITLY_SET=true ;;
            dar)      DAR_OVERRIDE="$1" ;;
            names)    NAMES_FILE="$1"   ;;
            crf)      CRF="$1"          ;;
            preset)   PRESET="$1"       ;;
            output)   OUTPUT_STEM="$1"  ;;
            scale)    SCALE_FACTOR="$1"  ;;
        esac
        _NEXT=""
        shift
        continue
    fi
    case "$1" in
        --mp4-only)          OUTPUT_MODE="mp4only" ;;
        --mkv-only)          OUTPUT_MODE="mkvonly" ;;
        --scale)             _NEXT="scale"       ;;
        --mode0)             BWDIF_MODE=0        ;;
        --sharpen)           SHARPEN=true        ;;
        --test)              TEST_MODE=true      ;;
        --profile)           _NEXT="profile"     ;;
        --mask)              _NEXT="mask"        ;;
        --dar)               _NEXT="dar"         ;;
        --names)             _NEXT="names"       ;;
        --crf)               _NEXT="crf"         ;;
        --preset)            _NEXT="preset"      ;;
        -o|--output)         _NEXT="output"      ;;
        -h|--help)           usage               ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            echo "Run with --help for usage."
            exit 1 ;;
        *)
            if [[ -z "$INPUT_VIDEO" ]]; then
                INPUT_VIDEO="$1"
            elif [[ -z "$CHAPTER_FILE" ]]; then
                CHAPTER_FILE="$1"
            else
                echo "[ERROR] Unexpected argument: $1"
                echo "Run with --help for usage."
                exit 1
            fi ;;
    esac
    shift
done

if [[ -z "$INPUT_VIDEO" ]]; then
    echo "[ERROR] <input_video> is required."
    echo "Run with --help for usage."
    exit 1
fi
if [[ -z "$CHAPTER_FILE" && -z "$NAMES_FILE" ]]; then
    echo "[ERROR] <chapter_file> is required unless --names is provided."
    echo "        With --names, the chapter file is auto-detected by matching"
    echo "        chapter count to the names file line count."
    echo "Run with --help for usage."
    exit 1
fi

# ==============================================================================
# Chapter file auto-detection
#
# When --names is provided but no explicit <chapter_file> argument was given,
# search for _title_NN_chapters.txt files alongside the input video and pick
# the one whose chapter count matches the names file line count.
# ==============================================================================
if [[ -z "$CHAPTER_FILE" && -n "$NAMES_FILE" ]]; then
    NAMES_COUNT=$(grep -c '[^[:space:]]' "$NAMES_FILE" 2>/dev/null || echo 0)
    INPUT_DIR=$(dirname "$INPUT_VIDEO")
    INPUT_BASE=$(basename "$INPUT_VIDEO")
    INPUT_BASE_STEM="${INPUT_BASE%.*}"

    # Search the input directory for _title_NN_chapters.txt files whose stem
    # matches the input video stem (same disc, same dvd_extract.sh run).
    mapfile -t CANDIDATE_OGMS < <(
        ls "${INPUT_DIR}/${INPUT_BASE_STEM}_title_"*"_chapters.txt" 2>/dev/null || true
    )

    # Also try without the _encoded suffix that dvd_encode.sh appends,
    # in case the input is an already-encoded file being re-processed.
    if [[ ${#CANDIDATE_OGMS[@]} -eq 0 ]]; then
        BARE_STEM="${INPUT_BASE_STEM%_encoded*}"
        mapfile -t CANDIDATE_OGMS < <(
            ls "${INPUT_DIR}/${BARE_STEM}_title_"*"_chapters.txt" 2>/dev/null || true
        )
    fi

    MATCHED_OGMS=()
    for ogm in "${CANDIDATE_OGMS[@]}"; do
        CHAP_COUNT=$(grep -c '^CHAPTER[0-9]*=' "$ogm" 2>/dev/null || echo 0)
        if [[ "$CHAP_COUNT" -eq "$NAMES_COUNT" ]]; then
            MATCHED_OGMS+=("$ogm")
        fi
    done

    if [[ ${#MATCHED_OGMS[@]} -eq 0 ]]; then
        echo "[ERROR] No chapter file found matching $NAMES_COUNT chapter(s) in:"
        echo "        $INPUT_DIR"
        if [[ ${#CANDIDATE_OGMS[@]} -gt 0 ]]; then
            echo "        Candidates found (none matched $NAMES_COUNT chapters):"
            for ogm in "${CANDIDATE_OGMS[@]}"; do
                C=$(grep -c '^CHAPTER[0-9]*=' "$ogm" 2>/dev/null || echo 0)
                echo "          $C chapter(s): $(basename "$ogm")"
            done
        fi
        echo "        Provide the chapter file explicitly as the second argument."
        exit 1

    elif [[ ${#MATCHED_OGMS[@]} -eq 1 ]]; then
        CHAPTER_FILE="${MATCHED_OGMS[0]}"
        echo "  [INFO] Chapter file auto-detected: $(basename "$CHAPTER_FILE")"
        echo "         ($NAMES_COUNT chapter(s) matched names file)"

    else
        echo "[ERROR] Multiple chapter files match $NAMES_COUNT chapter(s):"
        for ogm in "${MATCHED_OGMS[@]}"; do
            echo "          $(basename "$ogm")"
        done
        echo "        Provide the chapter file explicitly as the second argument."
        exit 1
    fi
fi

# ==============================================================================
# Pre-filter profile definitions
#
# Two variants per profile: 30fps (source <= 45fps) and 60fps (source > 45fps).
# The 60fps variants halve temporal hqdn3d values because consecutive field-rate
# frames are closer in time and need less inter-frame smoothing.
#
# Pre-filter profiles for DVD MPEG-2 sources.
#
# Filter parameter reference:
#   hqdn3d=luma_sp:chroma_sp:luma_tmp:chroma_tmp
#     luma_sp / chroma_sp:   spatial (within-frame) denoise strength
#     luma_tmp / chroma_tmp: temporal (between-frame) denoise strength
#   pp=fd   fast deblock (handles MPEG-2/DVD macroblocking)
#   pp=ac   full deblock + dering (suits DV DCT block artifacts)
# ==============================================================================
declare -A PROFILES_30FPS PROFILES_60FPS PROFILE_DESCRIPTIONS

PROFILES_30FPS["balanced"]="hqdn3d=2:2:6:6,pp=fd,unsharp=3:3:0.2"
PROFILES_60FPS["balanced"]="hqdn3d=2:2:3:3,pp=fd,unsharp=3:3:0.2"
PROFILE_DESCRIPTIONS["balanced"]="Standard DVD: moderate denoise, temporal stability, fast MPEG-2 deblock."

PROFILES_30FPS["aggressive"]="hqdn3d=3:3:6:6,pp=ac,unsharp=3:3:0.6"
PROFILES_60FPS["aggressive"]="hqdn3d=3:3:3:3,pp=ac,unsharp=3:3:0.6"
PROFILE_DESCRIPTIONS["aggressive"]="Strong spatial denoise, full deblock+dering. Heavy noise or low-bitrate DVD."

PROFILES_30FPS["halo"]="hqdn3d=4:4:8:8,pp=fd"
PROFILES_60FPS["halo"]="hqdn3d=4:4:4:4,pp=fd"
PROFILE_DESCRIPTIONS["halo"]="Heavy denoise to suppress ringing/ghosting around dark edges. No unsharp."


# Validate profile
VALID_PROFILES=("balanced" "aggressive" "halo")
PROFILE_VALID=false
for p in "${VALID_PROFILES[@]}"; do
    [[ "$PROFILE" == "$p" ]] && PROFILE_VALID=true && break
done
if [[ "$PROFILE_VALID" == false ]]; then
    echo "[ERROR] Unknown profile '$PROFILE'."
    echo "        Valid: ${VALID_PROFILES[*]}"
    exit 1
fi

# Validate CRF
if ! [[ "$CRF" =~ ^[0-9]+$ ]] || (( CRF > 51 )); then
    echo "[ERROR] CRF must be an integer 0-51 (recommended: 16-22)."
    exit 1
fi

# Validate preset
case "$PRESET" in
    ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
    *)
        echo "[ERROR] Unknown preset '$PRESET'."
        echo "        Valid: ultrafast fast medium slow slower veryslow"
        exit 1 ;;
esac

# Validate scale factor
if ! [[ "$SCALE_FACTOR" =~ ^[0-9]+$ ]] || (( SCALE_FACTOR < 1 )); then
    echo "[ERROR] --scale requires a positive integer (e.g. --scale 2)."
    exit 1
fi

# Odd mask sanity check (splits 2x2 YUV420p chroma blocks -> color fringing)
if (( MASK_PIXELS % 2 != 0 )); then
    echo ""
    echo "[WARN] Mask ($MASK_PIXELS) is odd. This can cause green/purple chroma fringing."
    echo "       Recommend using $(( MASK_PIXELS + 1 )) instead."
fi

# ==============================================================================
# Dependency check
# ==============================================================================
echo ""
echo "========================================="
echo "  dvd_encode.sh -- dependency check"
echo "========================================="
echo ""

HAVE_FFMPEG=0;      command -v ffmpeg      >/dev/null 2>&1 && HAVE_FFMPEG=1
HAVE_FFPROBE=0;     command -v ffprobe     >/dev/null 2>&1 && HAVE_FFPROBE=1
HAVE_MKVPROPEDIT=0; command -v mkvpropedit >/dev/null 2>&1 && HAVE_MKVPROPEDIT=1
HAVE_MP4BOX=0;      command -v MP4Box      >/dev/null 2>&1 && HAVE_MP4BOX=1
HAVE_PYTHON3=0;     command -v python3     >/dev/null 2>&1 && HAVE_PYTHON3=1
HAVE_XXHSUM=0;      command -v xxhsum      >/dev/null 2>&1 && HAVE_XXHSUM=1

[[ $HAVE_FFMPEG      -eq 1 ]] && echo "  [OK]   ffmpeg          -- video encoding (required)" \
    || { echo "  [MISS] ffmpeg          -- sudo apt install ffmpeg"; }
[[ $HAVE_FFPROBE     -eq 1 ]] && echo "  [OK]   ffprobe         -- source probing (required)" \
    || { echo "  [MISS] ffprobe         -- sudo apt install ffmpeg"; }
[[ $HAVE_MKVPROPEDIT -eq 1 ]] && echo "  [OK]   mkvpropedit     -- MKV chapter injection (mkvtoolnix)" \
    || { echo "  [MISS] mkvpropedit     -- sudo apt install mkvtoolnix"; }
[[ $HAVE_MP4BOX      -eq 1 ]] && echo "  [OK]   MP4Box          -- MP4 chapter injection (gpac)" \
    || { echo "  [MISS] MP4Box          -- sudo apt install gpac"; }
[[ $HAVE_PYTHON3     -eq 1 ]] && echo "  [OK]   python3         -- OGM/XML conversion" \
    || { echo "  [MISS] python3         -- sudo apt install python3"; }
[[ $HAVE_XXHSUM      -eq 1 ]] && echo "  [OK]   xxhsum          -- integrity verification (xxhash)" \
    || { echo "  [----] xxhsum          -- optional: sudo apt install xxhash"; }

echo ""

MISSING=()
[[ $HAVE_FFMPEG      -eq 0 ]] && MISSING+=(ffmpeg)
[[ $HAVE_FFPROBE     -eq 0 ]] && MISSING+=(ffprobe)
[[ $HAVE_MKVPROPEDIT -eq 0 ]] && MISSING+=(mkvtoolnix)
[[ $HAVE_MP4BOX      -eq 0 ]] && MISSING+=(gpac)
[[ $HAVE_PYTHON3     -eq 0 ]] && MISSING+=(python3)

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "[ERROR] Required packages missing: ${MISSING[*]}"
    echo "        sudo apt install ${MISSING[*]}"
    exit 1
fi

# ==============================================================================
# Validate file inputs
# ==============================================================================
if [[ ! -f "$INPUT_VIDEO" ]]; then
    echo "[ERROR] Input video not found: $INPUT_VIDEO"
    exit 1
fi
if [[ ! -f "$CHAPTER_FILE" ]]; then
    echo "[ERROR] Chapter file not found: $CHAPTER_FILE"
    exit 1
fi
if [[ -n "$NAMES_FILE" && ! -f "$NAMES_FILE" ]]; then
    echo "[ERROR] Names file not found: $NAMES_FILE"
    exit 1
fi

# ==============================================================================
# Step 1 — Probe source
#
# Individual ffprobe calls per field, avoiding a single JSON call with grep
# parsing which silently exits under set -e when fields are absent (e.g.
# stream duration is absent in raw MPEG program streams from VOB concatenation).
# ==============================================================================
echo "--- Step 1: Probing source ---"

SOURCE_CODEC=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null)

if [[ -z "$SOURCE_CODEC" ]]; then
    echo "[ERROR] ffprobe found no video stream in: $INPUT_VIDEO"
    exit 1
fi

SRC_WIDTH=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null)

SRC_HEIGHT=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null)

PIX_FMT=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=pix_fmt \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null)

STREAM_FPS=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null)

STREAM_DUR=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null)

FIELD_ORDER_RAW=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=field_order \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null)

SRC_SAR=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=sample_aspect_ratio \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null)

AUDIO_FORMAT=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null)

if [[ -z "$SRC_WIDTH" || -z "$SRC_HEIGHT" || -z "$STREAM_FPS" ]]; then
    echo "[ERROR] ffprobe returned incomplete metadata."
    echo "        codec=${SOURCE_CODEC}  width=${SRC_WIDTH:-empty}  height=${SRC_HEIGHT:-empty}  fps=${STREAM_FPS:-empty}"
    exit 1
fi

SOURCE_FPS_FLOAT=$(echo "$STREAM_FPS" | awk -F'/' \
    '{ if (NF==2 && $2!=0) printf "%.3f", $1/$2; else printf "%.3f", $1 }')

echo "  Codec:      $SOURCE_CODEC"
echo "  Resolution: ${SRC_WIDTH}x${SRC_HEIGHT}"
echo "  Pixel fmt:  ${PIX_FMT:-unknown}"
echo "  FPS:        $STREAM_FPS ($SOURCE_FPS_FLOAT)"
echo "  Audio:      ${AUDIO_FORMAT:-none}"
echo "  SAR:        ${SRC_SAR:-not set}"

# ==============================================================================
# Step 2 — Broken timestamp detection (4-tier)
#
# VOB-concatenated MPEG program streams frequently have absent or unrealistic
# stream-level durations.  +genpts is enabled whenever the stream-level
# duration is missing or unrealistic, regardless of which later tier resolves
# the actual duration for display purposes.
#
# Tier priority (matches cleanup_video.sh):
#   1. Stream-level duration
#   2. Format/container-level duration
#   3. Packet count (no decoding, reads index only)
#   4. Frame count  (full decode -- slow on large files)
# ==============================================================================
echo ""
echo "--- Step 2: Checking timestamps ---"

FFLAGS=""
BROKEN_DURATION=false
NEEDS_GENPTS=false
DURATION_SEC=""

# Tier 1
if [[ -n "$STREAM_DUR" && "$STREAM_DUR" != "N/A" ]]; then
    IS_UNREALISTIC=$(echo "$STREAM_DUR" | \
        awk '{ print ($1 <= 0 || $1 > 86400) ? "yes" : "no" }')
    if [[ "$IS_UNREALISTIC" == "no" ]]; then
        DURATION_SEC="$STREAM_DUR"
        echo "  Duration:   ${DURATION_SEC}s  (stream-level)"
    else
        BROKEN_DURATION=true; NEEDS_GENPTS=true
        echo "  [WARN] Stream-level duration unrealistic (${STREAM_DUR}s) -- trying format level."
    fi
else
    BROKEN_DURATION=true; NEEDS_GENPTS=true
    echo "  [WARN] Stream-level duration absent -- trying format level."
fi

# Tier 2
if [[ "$BROKEN_DURATION" == true ]]; then
    FMT_DUR=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_VIDEO" 2>/dev/null)
    IS_UNREALISTIC=$(echo "${FMT_DUR:-0}" | \
        awk '{ print ($1 <= 0 || $1 > 86400) ? "yes" : "no" }')
    if [[ -n "$FMT_DUR" && "$FMT_DUR" != "N/A" && "$IS_UNREALISTIC" == "no" ]]; then
        DURATION_SEC="$FMT_DUR"
        BROKEN_DURATION=false
        echo "  Duration:   ${DURATION_SEC}s  (format/container level)"
    else
        echo "  [WARN] Format-level duration also unreliable -- trying packet count."
    fi
fi

# Tier 3
if [[ "$BROKEN_DURATION" == true ]]; then
    PKT_COUNT=$(ffprobe -v error \
        -select_streams v:0 -count_packets \
        -show_entries stream=nb_read_packets \
        -of csv=p=0 \
        "$INPUT_VIDEO" 2>/dev/null || true)
    if [[ "$PKT_COUNT" =~ ^[0-9]+$ ]] && (( PKT_COUNT > 0 )); then
        DURATION_SEC=$(echo "$PKT_COUNT $SOURCE_FPS_FLOAT" | \
            awk '{ printf "%.3f", $1 / $2 }')
        BROKEN_DURATION=false
        echo "  Duration:   ${DURATION_SEC}s  (estimated from $PKT_COUNT packets)"
    else
        echo "  [WARN] Packet count unavailable -- falling back to full frame decode (slow)."
    fi
fi

# Tier 4
if [[ "$BROKEN_DURATION" == true ]]; then
    echo "  [WARN] Counting frames (may take several minutes)..."
    FRAME_COUNT=$(ffprobe -v error \
        -count_frames -select_streams v:0 \
        -show_entries stream=nb_read_frames \
        -of csv=p=0 \
        "$INPUT_VIDEO" 2>/dev/null || true)
    if [[ "$FRAME_COUNT" =~ ^[0-9]+$ ]] && (( FRAME_COUNT > 0 )); then
        DURATION_SEC=$(echo "$FRAME_COUNT $SOURCE_FPS_FLOAT" | \
            awk '{ printf "%.3f", $1 / $2 }')
        BROKEN_DURATION=false
        echo "  Duration:   ${DURATION_SEC}s  (estimated from $FRAME_COUNT frames)"
    fi
fi

if [[ "$BROKEN_DURATION" == true ]]; then
    echo ""
    echo "[ERROR] Could not determine video duration through any available method."
    echo "        The file may be corrupt.  Try:"
    echo "        ffprobe -v error -show_format -show_streams \"$INPUT_VIDEO\""
    exit 1
fi

if [[ "$NEEDS_GENPTS" == true ]]; then
    FFLAGS="-fflags +genpts"
    echo "  [INFO] Broken/missing stream timestamps -- enabling PTS regeneration (+genpts)."
fi

# ==============================================================================
# Step 3 — Scan type and field order detection
#
# Detection priority (matches cleanup_video.sh and prepare_video.sh):
#   1. DV codec shortcut -- always BFF on NTSC; AVI container lacks field order
#   2. ffprobe stream field_order metadata
#   3. ffprobe frame-level interlaced_frame flags (first 50 frames)
#   4. ffmpeg idet pixel-level heuristic (last resort)
#
# Ambiguous idet results (15-20% interlace ratio) abort with instructions
# rather than silently guessing wrong field order.
# ==============================================================================
IS_INTERLACED=false
PARITY="-1"
FIELD_ORDER="Progressive"

echo ""
echo "--- Step 3: Detecting scan type and field order ---"

    FIELD_ORDER_UC="${FIELD_ORDER_RAW^^}"
    IS_DV_SOURCE=false

    if [[ "$SOURCE_CODEC" == dv* ]]; then
        # DV from FireWire is always BFF on NTSC; ffprobe returns 'unknown' for
        # DV AVI containers which do not store field order metadata.
        IS_DV_SOURCE=true
        IS_INTERLACED=true
        PARITY="1"
        FIELD_ORDER="Interlaced BFF (DV/NTSC -- codec-based detection)"
        echo "  [Tier 1] DV codec ($SOURCE_CODEC) -- BFF assumed (NTSC standard)."
        echo "  [INFO]   'AC EOB marker' warnings during encode are normal for DV"
        echo "           tape leader frames and stop after the first few seconds."

    elif [[ "$FIELD_ORDER_UC" == "PROGRESSIVE" ]]; then
        IS_INTERLACED=false
        FIELD_ORDER="Progressive"
        echo "  [Tier 2] ffprobe field_order: Progressive"

    elif [[ "$FIELD_ORDER_UC" == "TT" ]]; then
        IS_INTERLACED=true
        PARITY="0"
        FIELD_ORDER="Interlaced TFF (Top Field First -- ffprobe stream metadata)"
        echo "  [Tier 2] ffprobe field_order: TFF"

    elif [[ "$FIELD_ORDER_UC" == "BB" || "$FIELD_ORDER_UC" == "BT" ]]; then
        IS_INTERLACED=true
        PARITY="1"
        FIELD_ORDER="Interlaced BFF (Bottom Field First -- ffprobe stream metadata)"
        echo "  [Tier 2] ffprobe field_order: BFF"

    else
        echo "  [Tier 2] ffprobe field_order: '${FIELD_ORDER_RAW:-unknown}' -- trying frame flags."
        echo "  [Tier 3] Checking interlaced_frame flags on first 50 frames..."

        FRAME_FLAGS=$(ffprobe -v error \
            -select_streams v:0 -show_frames \
            -read_intervals "%+#50" \
            "$INPUT_VIDEO" 2>/dev/null || true)

        INTERLACED_SUM=$(echo "$FRAME_FLAGS" | \
            grep "interlaced_frame=" | awk -F= '{s+=$2} END {print s+0}')
        INTERLACED_COUNT=$(echo "$FRAME_FLAGS" | \
            grep -c "interlaced_frame=" || true)

        TIER3_RESOLVED=false

        if [[ "$INTERLACED_COUNT" -gt 0 && "$INTERLACED_SUM" -eq 0 ]]; then
            IS_INTERLACED=false
            FIELD_ORDER="Progressive (frame-flag detection)"
            echo "  [Tier 3] Progressive (0/$INTERLACED_COUNT frames flagged interlaced)"
            TIER3_RESOLVED=true

        elif [[ "$INTERLACED_COUNT" -gt 0 && "$INTERLACED_SUM" -gt 0 ]]; then
            TFF_SUM=$(echo "$FRAME_FLAGS" | \
                grep "top_field_first=" | awk -F= '{s+=$2} END {print s+0}')
            TFF_COUNT=$(echo "$FRAME_FLAGS" | grep -c "top_field_first=" || true)

            if [[ "$TFF_COUNT" -gt 0 ]]; then
                BFF_SUM=$(( TFF_COUNT - TFF_SUM ))
                IS_INTERLACED=true
                TIER3_RESOLVED=true
                if (( TFF_SUM > BFF_SUM )); then
                    PARITY="0"
                    FIELD_ORDER="Interlaced TFF (frame-flag detection)"
                    echo "  [Tier 3] TFF ($TFF_SUM TFF / $BFF_SUM BFF of $TFF_COUNT frames)"
                else
                    PARITY="1"
                    FIELD_ORDER="Interlaced BFF (frame-flag detection)"
                    echo "  [Tier 3] BFF ($BFF_SUM BFF / $TFF_SUM TFF of $TFF_COUNT frames)"
                fi
            else
                echo "  [Tier 3] Interlaced frames detected but top_field_first absent -- falling through to idet."
            fi
        else
            echo "  [Tier 3] No interlaced_frame flags -- falling through to idet."
        fi

        # Tier 4: idet pixel-level heuristic
        if [[ "$TIER3_RESOLVED" == false ]]; then
            echo "  [Tier 4] Running idet on first 500 frames..."

            IDET_OUTPUT=$(ffmpeg -i "$INPUT_VIDEO" \
                -filter:v idet -frames:v 500 -an -f null - 2>&1 || true)
            IDET_LINE=$(echo "$IDET_OUTPUT" | \
                grep "Multi frame detection:" | tail -1)

            if [[ -z "$IDET_LINE" ]]; then
                echo "[ERROR] idet produced no output. File may be corrupt."
                exit 1
            fi

            IDET_TFF=$(echo  "$IDET_LINE" | grep -oP 'TFF:\s*\K[0-9]+')
            IDET_BFF=$(echo  "$IDET_LINE" | grep -oP 'BFF:\s*\K[0-9]+')
            IDET_PROG=$(echo "$IDET_LINE" | grep -oP 'Progressive:\s*\K[0-9]+')
            IDET_TOTAL=$(( IDET_TFF + IDET_BFF + IDET_PROG ))

            echo "  [Tier 4] idet: TFF=$IDET_TFF BFF=$IDET_BFF Progressive=$IDET_PROG"

            if (( IDET_TOTAL == 0 )); then
                echo "[ERROR] idet returned all-zero counts. File may have no decodable frames."
                exit 1
            fi

            IDET_RATIO=$(echo "$IDET_TFF $IDET_BFF $IDET_TOTAL" | \
                awk '{ printf "%.4f", ($1 + $2) / $3 }')

            IS_PROG_IDET=$(echo  "$IDET_RATIO" | awk '{ print ($1 < 0.15) ? "yes" : "no" }')
            IS_AMBIG_IDET=$(echo "$IDET_RATIO" | \
                awk '{ print ($1 >= 0.15 && $1 <= 0.20) ? "yes" : "no" }')

            if [[ "$IS_PROG_IDET" == "yes" ]]; then
                IS_INTERLACED=false
                FIELD_ORDER="Progressive (idet: ratio ${IDET_RATIO} < 0.15)"
                echo "  [Tier 4] Progressive (ratio ${IDET_RATIO})"

            elif [[ "$IS_AMBIG_IDET" == "yes" ]]; then
                echo ""
                echo "[ERROR] idet result is ambiguous (ratio ${IDET_RATIO}, in the 15-20% grey zone)."
                echo "        Play the file in VLC and look for comb teeth on fast-moving"
                echo "        edges. Combing = interlaced; smooth edges = progressive."
                exit 1

            else
                IS_INTERLACED=true
                if (( IDET_TFF > IDET_BFF )); then
                    PARITY="0"
                    FIELD_ORDER="Interlaced TFF (idet: ratio ${IDET_RATIO})"
                    echo "  [Tier 4] TFF (ratio ${IDET_RATIO})"
                else
                    PARITY="1"
                    FIELD_ORDER="Interlaced BFF (idet: ratio ${IDET_RATIO})"
                    echo "  [Tier 4] BFF (ratio ${IDET_RATIO})"
                fi
            fi
        fi
    fi

# ==============================================================================
# Step 4 — Select 30fps or 60fps profile variant
#
# Sources > 45fps are bwdif mode=1 field-rate masters from prepare_video.sh.
# Their consecutive frames are closer in time and need less temporal smoothing.
# ==============================================================================
IS_60FPS=false
if (( $(echo "$SOURCE_FPS_FLOAT > 45" | bc -l) )); then
    IS_60FPS=true
fi

if [[ "$IS_60FPS" == true ]]; then
    PREFILTER_VF="${PROFILES_60FPS[$PROFILE]}"
    FPS_VARIANT="60fps variant (halved temporal hqdn3d — source FPS ${SOURCE_FPS_FLOAT})"
else
    PREFILTER_VF="${PROFILES_30FPS[$PROFILE]}"
    FPS_VARIANT="30fps variant (source FPS ${SOURCE_FPS_FLOAT})"
fi

# ==============================================================================
# Step 5 — DAR (Display Aspect Ratio) auto-detection
#
# Priority (matches cleanup_video.sh):
#   1. --dar override
#   2. SAR metadata from container
#   3. Resolution heuristics (720x480 NTSC -> 4:3 default)
# ==============================================================================
echo ""
echo "--- Step 4: Detecting display aspect ratio ---"

DAR=""
DAR_SOURCE=""
DAR_CMD=""

gcd() { local a=$1 b=$2; while (( b )); do local t=$b; b=$(( a%b )); a=$t; done; echo "$a"; }

if [[ -n "$DAR_OVERRIDE" ]]; then
    DAR="$DAR_OVERRIDE"
    DAR_SOURCE="user override (--dar)"

elif [[ -n "$SRC_SAR" && "$SRC_SAR" != "N/A" && \
        "$SRC_SAR" != "0:1" && "$SRC_SAR" != "1:1" ]]; then
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
            DAR_SOURCE="resolution heuristic (NTSC 4:3 default; --dar 16:9 to override)" ;;
        720x576|704x576|352x576)
            DAR="4:3"
            DAR_SOURCE="resolution heuristic (PAL 4:3 default; --dar 16:9 to override)" ;;
        352x240|352x288)
            DAR="4:3"
            DAR_SOURCE="resolution heuristic (VCD/half-D1 4:3)" ;;
        *)
            DAR_SOURCE="square pixels assumed (no SAR metadata, no matching heuristic)" ;;
    esac
fi

if [[ -n "$DAR" ]]; then
    DAR_CMD="-aspect $DAR"
    echo "  DAR: $DAR  ($DAR_SOURCE)"
else
    echo "  DAR: not set  ($DAR_SOURCE)"
fi

# ==============================================================================
# Step 6 — Audio strategy
#
# AAC 192k for distribution MP4 — universally supported on Android, iOS,
# Windows, macOS without codec installation.  Source audio (AC3, PCM, etc.)
# is always transcoded to AAC for the final MP4 distribution file.
# ==============================================================================
AUDIO_CMD="-c:a aac -b:a 192k"
AUDIO_PLAN="AAC 192k stereo (transcoded from ${AUDIO_FORMAT:-unknown})"

# ==============================================================================
# Step 7 — Build video filter chain
#
# Chain order:
#   [bwdif]  ->  format=yuv420p  ->  profile filters  ->  [drawbox mask]
#   ->  [--sharpen]
#
# bwdif must precede format=yuv420p; it operates on the original interlaced
# field structure and must see the original pixel format.
# format=yuv420p normalises before the denoise/deblock chain.
# drawbox runs at source resolution so mask_pixels always refers to source
# pixels, regardless of any upstream scaling.
# ==============================================================================

# Build sharpening label for the summary
if [[ "$PROFILE" == "halo" ]]; then
    if [[ "$SHARPEN" == true ]]; then
        SHARPEN_LABEL="unsharp=3:3:0.3 (--sharpen only; halo has no built-in unsharp)"
    else
        SHARPEN_LABEL="none (halo profile -- unsharp deliberately omitted)"
    fi
else
    if [[ "$SHARPEN" == true ]]; then
        SHARPEN_LABEL="profile built-in + unsharp=3:3:0.3 (--sharpen)"
    else
        SHARPEN_LABEL="profile built-in"
    fi
fi

if [[ "$IS_INTERLACED" == true ]]; then
    if [[ "$BWDIF_MODE" -eq 1 ]]; then
        DEINT_DESC="bwdif mode=1 (field-rate ~60fps)"
    else
        DEINT_DESC="bwdif mode=0 (frame-rate ~30fps)"
    fi
    FILTER_CHAIN="bwdif=mode=${BWDIF_MODE}:parity=${PARITY}:deint=0,format=yuv420p,${PREFILTER_VF}"
else
    DEINT_DESC="none (progressive)"
    FILTER_CHAIN="format=yuv420p,${PREFILTER_VF}"
fi

if [[ "$MASK_PIXELS" -gt 0 ]]; then
    FILTER_CHAIN="${FILTER_CHAIN},drawbox=y=ih-${MASK_PIXELS}:h=${MASK_PIXELS}:color=black:t=fill"
fi

if [[ "$SHARPEN" == true ]]; then
    FILTER_CHAIN="${FILTER_CHAIN},unsharp=3:3:0.3"
fi

# Lanczos upscale -- appended last so drawbox mask covers source pixels
# at source resolution before the frame is scaled up.
SCALE_LABEL="none (source resolution)"
if [[ "$SCALE_FACTOR" -gt 1 ]]; then
    FILTER_CHAIN="${FILTER_CHAIN},scale=iw*${SCALE_FACTOR}:ih*${SCALE_FACTOR}:flags=lanczos"
    OUT_W=$(( SRC_WIDTH  * SCALE_FACTOR ))
    OUT_H=$(( SRC_HEIGHT * SCALE_FACTOR ))
    SCALE_LABEL="${SCALE_FACTOR}x Lanczos  (${OUT_W}x${OUT_H} output pixels)"
fi

# ==============================================================================
# Step 8 — Apply chapter name replacements (--names)
# ==============================================================================
OGM_WORK="$CHAPTER_FILE"
OGM_NAMED=""

if [[ -n "$NAMES_FILE" ]]; then
    OGM_CHAP_COUNT=$(grep -c '^CHAPTER[0-9]*NAME=' "$CHAPTER_FILE" 2>/dev/null || echo 0)
    NAMES_COUNT=$(grep -c '[^[:space:]]' "$NAMES_FILE" 2>/dev/null || echo 0)

    if [[ "$OGM_CHAP_COUNT" -ne "$NAMES_COUNT" ]]; then
        echo "[ERROR] Chapter count mismatch: chapter file has $OGM_CHAP_COUNT, names file has $NAMES_COUNT."
        exit 1
    fi

    OGM_NAMED=$(mktemp /tmp/dvd_encode_ogm_XXXXXX.txt)

    python3 - "$CHAPTER_FILE" "$NAMES_FILE" "$OGM_NAMED" << 'PYEOF'
import sys, re
with open(sys.argv[1]) as f: ogm_lines = f.readlines()
with open(sys.argv[2]) as f: names = [ln.strip() for ln in f if ln.strip()]
name_iter = iter(names)
out = []
for line in ogm_lines:
    if re.match(r'CHAPTER\d+NAME=', line):
        num = re.match(r'(CHAPTER\d+NAME)=', line).group(1)
        out.append(f'{num}={next(name_iter)}\n')
    else:
        out.append(line)
with open(sys.argv[3], 'w') as f: f.writelines(out)
PYEOF

    OGM_WORK="$OGM_NAMED"
fi

# Convert OGM to Matroska XML (unambiguous chapter format for mkvpropedit)
CHAP_XML=$(mktemp /tmp/dvd_encode_chap_XXXXXX.xml)

python3 - "$OGM_WORK" "$CHAP_XML" << 'PYEOF'
import sys, re
with open(sys.argv[1]) as f: lines = f.read().strip().splitlines()
entries = {}; order = []
for line in lines:
    m = re.match(r'CHAPTER(\d+)(NAME)?=(.*)', line)
    if not m: continue
    num, is_name, val = m.group(1), m.group(2), m.group(3).strip()
    if num not in entries: entries[num] = {}; order.append(num)
    entries[num]['name' if is_name else 'time'] = val
xml = ['<?xml version="1.0" encoding="UTF-8"?>',
       '<!DOCTYPE Chapters SYSTEM "matroskachapters.dtd">',
       '<Chapters><EditionEntry>']
for num in order:
    t = entries[num].get('time', '00:00:00.000')
    n = entries[num].get('name', f'Chapter {int(num):02d}')
    xml += [f'  <ChapterAtom>',
            f'    <ChapterTimeStart>{t}</ChapterTimeStart>',
            f'    <ChapterDisplay><ChapterString>{n}</ChapterString></ChapterDisplay>',
            f'  </ChapterAtom>']
xml.append('</EditionEntry></Chapters>')
with open(sys.argv[2], 'w') as f: f.write('\n'.join(xml) + '\n')
PYEOF

# Cleanup temp files on exit
_cleanup() {
    [[ -n "$OGM_NAMED" && -f "$OGM_NAMED" ]] && rm -f "$OGM_NAMED"
    [[ -f "$CHAP_XML" ]] && rm -f "$CHAP_XML"
}
trap _cleanup EXIT

# ==============================================================================
# Output filename
# ==============================================================================
INPUT_STEM="${INPUT_VIDEO%.*}"
if [[ -z "$OUTPUT_STEM" ]]; then
    OUTPUT_STEM="${INPUT_STEM}_encoded"
else
    # -o was given: strip any extension the user may have included.
    OUTPUT_STEM="${OUTPUT_STEM%.*}"
fi
MP4_FILE="${OUTPUT_STEM}.mp4"
MKV_FILE="${OUTPUT_STEM}.mkv"
OUTPUT_FILE="$MP4_FILE"

TEST_LABEL=""
LIMIT_CMD=""
if [[ "$TEST_MODE" == true ]]; then
    # -t as an input option limits how much of the source is read,
    # not just the output duration (matching prepare_video.sh behaviour).
    LIMIT_CMD="-t 30"
    TEST_LABEL=" (TEST MODE -- 30s)"
    OUTPUT_STEM="${INPUT_STEM}_encoded_TEST"
    MP4_FILE="${OUTPUT_STEM}.mp4"
    MKV_FILE="${OUTPUT_STEM}.mkv"
    OUTPUT_FILE="$MP4_FILE"  # reset for test mode
fi

# ==============================================================================
# Pre-flight summary and confirmation
# ==============================================================================
echo ""
echo "========================================="
echo "  PRE-FLIGHT SUMMARY${TEST_LABEL}"
echo "========================================="
echo "  Source:      $INPUT_VIDEO"
echo "    Codec:     $SOURCE_CODEC"
echo "    Size:      ${SRC_WIDTH}x${SRC_HEIGHT}  |  Pixel fmt: ${PIX_FMT:-unknown}"
echo "    Duration:  ${DURATION_SEC}s  |  FPS: $STREAM_FPS"
echo "  Output:      $OUTPUT_FILE"
echo "  Producing:   $OUTPUT_MODE"
  if [[ "$OUTPUT_MODE" != "mp4only" ]]; then echo "  MP4: $MP4_FILE"; fi
  if [[ "$OUTPUT_MODE" != "mkvonly" ]]; then echo "  MKV: $MKV_FILE"; fi
echo "-----------------------------------------"
echo "  Deinterlace: $DEINT_DESC  |  $FIELD_ORDER"
echo "  Profile:     $PROFILE  ($FPS_VARIANT)"
echo "               ${PROFILE_DESCRIPTIONS[$PROFILE]}"
echo "  Sharpen:     $SHARPEN_LABEL"
  echo "  Scale:       $SCALE_LABEL"
echo "  Bottom mask: ${MASK_PIXELS}px"
echo "  DAR:         ${DAR:-not set}  ($DAR_SOURCE)"
echo "  Audio:       $AUDIO_PLAN"
echo "  H.264:       CRF $CRF  |  preset $PRESET  |  -threads 0"
[[ -n "$FFLAGS" ]] && echo "  PTS repair:  enabled (+genpts)"
echo "-----------------------------------------"
echo "  Filter chain: $FILTER_CHAIN"
echo "========================================="

if [[ "$IS_INTERLACED" == true && "$BWDIF_MODE" -eq 1 ]]; then
    echo ""
    echo "  [INFO] bwdif mode=1 outputs ~60fps (one frame per field)."
fi
echo ""

# Warn if a chapter file is provided but no names file -- chapters will be
# embedded with auto-generated timestamp names (e.g. "00:02:42") rather than
# descriptive titles.  This is not an error, but is worth flagging before
# committing to a long encode, since adding names later requires re-running
# dvd_add_chapters.sh with an additional MP4Box remux pass for MP4 output.
if [[ -n "$CHAPTER_FILE" && -z "$NAMES_FILE" ]]; then
    NUM_CHAPS=$(grep -c '^CHAPTER[0-9]*NAME=' "$CHAPTER_FILE" 2>/dev/null || echo 0)
    echo "  [WARN] No --names file provided."
    echo "         $NUM_CHAPS chapter marker(s) will be embedded with timestamp"
    echo "         names only (e.g. '00:02:42').  To embed descriptive titles,"
    echo "         cancel and re-run with:"
    echo "           --names <file>   one title per line, $NUM_CHAPS line(s) required"
    echo "         Or add titles later with dvd_add_chapters.sh."
    echo ""
fi

read -p "  Ready to encode? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# ==============================================================================
# Disk space check
#
# Estimates required space from source bitrate x duration, with a scale
# multiplier and 10% buffer.  Both MP4 and MKV are counted; the MP4Box
# chapter remux also needs one temporary full copy of the MP4.
# Aborts rather than silently failing partway through a long encode.
# ==============================================================================
echo ""
echo "--- Checking disk space ---"

SRC_BITRATE_BPS=$(ffprobe -v error \
    -show_entries format=bit_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_VIDEO" 2>/dev/null || echo 0)

# x264 at CRF 18 typically produces 40-60% of source DVD bitrate.
# Scale factor increases output resolution (and bitrate) roughly linearly;
# use a conservative 1.5x multiplier per scale doubling.
SCALE_MULT=1
if   [[ "$SCALE_FACTOR" -eq 2 ]]; then SCALE_MULT=2
elif [[ "$SCALE_FACTOR" -ge 4 ]]; then SCALE_MULT=4
fi

# Estimate MP4 size: source_bytes * scale_mult * 1.1 safety margin
EST_MP4_BYTES=$(awk "BEGIN { printf \"%.0f\", \
    ($SRC_BITRATE_BPS / 8) * $DURATION_SEC * $SCALE_MULT * 1.1 }")

# MKV: same streams, negligible container overhead
# MP4Box remux: needs one temporary full MP4 copy
if [[ "$OUTPUT_MODE" == "mp4only" ]]; then
    EST_TOTAL_BYTES=$(awk "BEGIN { printf \"%.0f\", $EST_MP4_BYTES * 2 }")
elif [[ "$OUTPUT_MODE" == "mkvonly" ]]; then
    EST_TOTAL_BYTES="$EST_MP4_BYTES"
else
    # both: MP4 + MKV + MP4Box temp copy
    EST_TOTAL_BYTES=$(awk "BEGIN { printf \"%.0f\", $EST_MP4_BYTES * 3 }")
fi

AVAIL_BYTES=$(df --output=avail -B1 "$(dirname "$MP4_FILE")" 2>/dev/null \
    | tail -1 | tr -d ' ' || echo 0)

EST_GB=$(awk  "BEGIN { printf \"%.1f\", $EST_TOTAL_BYTES / 1073741824 }")
AVAIL_GB=$(awk "BEGIN { printf \"%.1f\", $AVAIL_BYTES    / 1073741824 }")

echo "  Estimated needed: ~${EST_GB}GB  |  Available: ${AVAIL_GB}GB"

if (( AVAIL_BYTES > 0 )) && \
   awk "BEGIN { exit ($EST_TOTAL_BYTES <= $AVAIL_BYTES) ? 1 : 0 }"; then
    echo ""
    echo "[ERROR] Insufficient disk space."
    echo "        Estimated: ~${EST_GB}GB  |  Available: ${AVAIL_GB}GB"
    echo "        Use -o to write to a different filesystem, or free up space."
    exit 1
fi

# ==============================================================================
# Encode
#
# ffmpeg argument notes:
#   $FFLAGS (+genpts) and $LIMIT_CMD (-t 30) placed BEFORE -i so they act
#   as input options (limits how much source is read, not just output duration).
#   -threads 0 lets libx264 auto-detect optimal thread count for the host CPU.
#   -pix_fmt yuv420p ensures consistent output pixel format.
#   -movflags +faststart moves the MP4 index to the front of the file,
#   enabling playback before the full file is available (streaming, USB copy).
# ==============================================================================
echo ""
echo "--- Encoding ---"
echo "  Output: $OUTPUT_FILE"
echo ""

# shellcheck disable=SC2086
ffmpeg -y $FFLAGS $LIMIT_CMD -i "$INPUT_VIDEO" \
    -map 0:v:0 -map 0:a:0 \
    -vf "$FILTER_CHAIN" \
    $DAR_CMD \
    -c:v libx264 -threads 0 -crf "$CRF" -preset "$PRESET" \
    -pix_fmt yuv420p \
    -movflags +faststart \
    $AUDIO_CMD \
    "$OUTPUT_FILE"

echo ""
echo "  Encoded: $MP4_FILE  ($(du -h "$MP4_FILE" | cut -f1))"

# ==============================================================================
# Duration validation
#
# Compares output duration to source.  A delta > 2s indicates a mux problem
# (broken timestamps, truncated output).  Skipped in test mode (30s clip).
# ==============================================================================
if [[ "$TEST_MODE" != true ]]; then
    echo ""
    echo "--- Duration check ---"
    OUT_DUR=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$MP4_FILE" 2>/dev/null || echo 0)
    DUR_DIFF=$(awk "BEGIN { d=$DURATION_SEC - $OUT_DUR; \
        if (d<0) d=-d; printf \"%.1f\", d }")
    DUR_OK=$(awk  "BEGIN { print ($DUR_DIFF <= 2.0) ? \"yes\" : \"no\" }")
    printf "  Source:  %8.2fs\n" "$DURATION_SEC"
    printf "  Output:  %8.2fs\n" "$OUT_DUR"
    printf "  Delta:   %8.2fs\n" "$DUR_DIFF"
    if [[ "$DUR_OK" == "yes" ]]; then
        echo "  [OK] Duration matches source within tolerance."
    else
        echo ""
        echo "  [WARN] Output duration differs from source by ${DUR_DIFF}s."
        echo "         Verify playback before distributing."
        echo "         The source .mpg may have corruption or broken timestamps."
    fi
fi

# ==============================================================================
# Chapter injection into MP4
#
# MP4Box is used because mkvpropedit v65 does not reliably support MP4.
# MP4Box requires a remux -- a temp file is written then replaces the original.
# ==============================================================================
if [[ "$OUTPUT_MODE" != "mkvonly" ]]; then
    echo ""
    echo "--- Injecting chapters into MP4 ---"
    if [[ $HAVE_MP4BOX -eq 0 ]]; then
        echo "  [WARN] MP4Box not installed -- chapters not injected into MP4."
        echo "         Install: sudo apt install gpac"
    else
        MP4_CHAP_TMP=$(mktemp /tmp/dvd_encode_mp4chap_XXXXXX.txt)
        awk '
            /^CHAPTER[0-9]+=/ && !/NAME/ {
                sub(/^CHAPTER[0-9]+=/, ""); ts = $0
            }
            /^CHAPTER[0-9]+NAME=/ {
                sub(/^CHAPTER[0-9]+NAME=/, ""); print ts " " $0
            }
        ' "$OGM_WORK" > "$MP4_CHAP_TMP"
        CHAPTERED_TMP=$(mktemp /tmp/dvd_encode_chaptered_XXXXXX.mp4)
        MP4Box -add "$MP4_FILE" -chap "$MP4_CHAP_TMP" -new "$CHAPTERED_TMP"
        mv "$CHAPTERED_TMP" "$MP4_FILE"
        rm -f "$MP4_CHAP_TMP"
        echo "  Chapters written to: $MP4_FILE"
    fi
fi

# ==============================================================================
# MKV production
#
# mkvmerge remuxes the finished MP4 -- no re-encode, near-instant.
# mkvpropedit injects chapters in-place immediately after.
# Future chapter name corrections on the MKV are always instant (no remux).
# ==============================================================================
if [[ "$OUTPUT_MODE" != "mp4only" ]]; then
    echo ""
    echo "--- Producing MKV (mkvmerge remux, no re-encode) ---"
    echo "  Output: $MKV_FILE"
    mkvmerge -o "$MKV_FILE" "$MP4_FILE"
    mkvpropedit "$MKV_FILE" --chapters "$CHAP_XML"
    echo "  Chapters written to: $MKV_FILE"
    echo "  Size: $(du -h "$MKV_FILE" | cut -f1)"
fi

# ==============================================================================
# Integrity verification (optional)
# ==============================================================================
if [[ $HAVE_XXHSUM -eq 1 ]]; then
    echo ""
    echo "--- Integrity verification (XXH64) ---"
    if [[ "$OUTPUT_MODE" != "mkvonly" && -f "$MP4_FILE" ]]; then
        HASH=$(xxhsum -H64 "$MP4_FILE" | awk '{print $1}')
        echo "  XXH64: $HASH  $(basename "$MP4_FILE")"
    fi
    if [[ "$OUTPUT_MODE" != "mp4only" && -f "$MKV_FILE" ]]; then
        HASH=$(xxhsum -H64 "$MKV_FILE" | awk '{print $1}')
        echo "  XXH64: $HASH  $(basename "$MKV_FILE")"
    fi
fi

echo ""
echo "========================================="
echo "  Encode complete"
echo "========================================="
if [[ "$OUTPUT_MODE" != "mkvonly" && -f "$MP4_FILE" ]]; then
    echo "  MP4: $MP4_FILE  ($(du -h "$MP4_FILE" | cut -f1))"
fi
if [[ "$OUTPUT_MODE" != "mp4only" && -f "$MKV_FILE" ]]; then
    echo "  MKV: $MKV_FILE  ($(du -h "$MKV_FILE" | cut -f1))"
fi
echo ""

} # end main
main "$@"
