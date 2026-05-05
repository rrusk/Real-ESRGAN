#!/usr/bin/env bash
# capture-hauppauge.sh
# Usage: capture-hauppauge.sh [--brightness N] [--output-dir DIR] [--svideo|--composite] <SOURCE_ID> [DESCRIPTION]
#
# Captures from a Hauppauge 610 USB device to a lossless FFV1/MKV file
# with a simultaneous live monitor window.
#
# Output naming follows capture_passthrough.sh conventions:
#   OUTPUT_DIR/SOURCE_ID[_DESCRIPTION]_TIMESTAMP/
#       SOURCE_ID[_DESCRIPTION]_TIMESTAMP_INPUT_bBRIGHTNESS.mkv
#
# Arguments:
#   SOURCE_ID      Required on command line or prompted interactively.
#                  Short identifier for the tape, e.g. "VHS" or "VHS_Jive".
#                  Spaces are converted to underscores.
#   DESCRIPTION    Optional additional context, e.g. tape title.
#                  Spaces are converted to underscores.
#                  If SOURCE_ID is not provided on the command line both
#                  SOURCE_ID and DESCRIPTION are prompted interactively.
#
# Options:
#   --svideo          Use the S-Video input (Hauppauge input 1).
#   --composite       Use the Composite input (Hauppauge input 0).
#                     If neither is specified the script prompts interactively.
#
#   --brightness N    Set the V4L2 brightness control (0-255, default 128).
#                     128 is the hardware neutral point.  Lower values reduce
#                     the luma level going into the ADC, which can recover
#                     highlight headroom when the VCR output is running hot.
#                     Use vhs_quality.sh --sample 120 to compare captures at
#                     different values and choose the one that minimises
#                     widespread_clip without crushing shadows.
#
#   --output-dir DIR  Root directory under which the capture subdirectory is
#                     created.  Defaults to ~/dv_captures (same as
#                     capture_passthrough.sh) so captures land alongside DV
#                     files automatically.  Created if it does not exist.
#
# The input type and brightness value are embedded in the output filename so
# captures at different settings sort and compare without manual renaming.

set -euo pipefail

# ------------------------------------------------------------------------------
# Helper: confirm_continue REASON
# Prints a prominent warning and prompts the user to continue or abort.
# Reads from /dev/tty so the prompt works even when stdin is redirected.
# Exits on anything but y/Y.
# ------------------------------------------------------------------------------
confirm_continue() {
    local reason="$1"
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  WARNING: ${reason}"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    printf "  Continue anyway? [y/N] "
    local answer
    read -r answer </dev/tty
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "  Aborting."
        exit 1
    fi
    echo ""
}

# --- 1. Dependency Check ---
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

# --- 2. Robust Hardware Detection ---
# Finds the video node specifically for Hauppauge hardware
VIDEO_DEV=$(v4l2-ctl --list-devices 2>/dev/null | grep -iA 5 "Hauppauge" | grep -o "/dev/video[0-9]\+" | head -n 1)

# Detects audio via the manufacturer name or the specific chipset driver
AUDIO_CARD=$(arecord -l 2>/dev/null | grep -iE "Hauppauge|Cx231xx" | head -n 1 | cut -d' ' -f2 | tr -d ':')

if [ -z "$VIDEO_DEV" ] || [ -z "$AUDIO_CARD" ]; then
    echo "Error: Hauppauge hardware not fully detected."
    echo "Video: ${VIDEO_DEV:-NOT FOUND} | Audio Card: ${AUDIO_CARD:-NOT FOUND}"
    exit 1
fi

AUDIO_DEV="hw:${AUDIO_CARD},0"

# --- 3. Argument Parsing ---
# Default V4L2 brightness: 128 is the hardware neutral point (no adjustment).
# Valid range is 0-255; values below 128 attenuate the luma signal at the ADC.
BRIGHTNESS=128

# Default output root: matches capture_passthrough.sh convention.
OUTPUT_DIR="${HOME}/dv_captures"

# Input selection: empty means prompt the user interactively.
# INPUT_NUM is the V4L2 input index (0=Composite, 1=S-Video).
INPUT_NUM=""
INPUT_LABEL=""

# Tape identification: SOURCE_ID required, DESCRIPTION optional.
SOURCE_ID=""
EXTRA_DESC=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --brightness)
            if [[ -z "${2:-}" ]] || [[ ! "${2}" =~ ^[0-9]+$ ]] \
               || (( ${2} < 0 || ${2} > 255 )); then
                echo "Error: --brightness requires an integer in the range 0-255."
                exit 1
            fi
            BRIGHTNESS="$2"
            shift 2
            ;;
        --output-dir)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --output-dir requires a directory path."
                exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --svideo)
            INPUT_NUM=1
            INPUT_LABEL="svideo"
            shift
            ;;
        --composite)
            INPUT_NUM=0
            INPUT_LABEL="composite"
            shift
            ;;
        -*)
            echo "Error: Unknown option: $1"
            echo "Usage: $0 [--brightness N] [--output-dir DIR] [--svideo|--composite] <SOURCE_ID> [DESCRIPTION]"
            exit 1
            ;;
        *)
            if [[ -z "$SOURCE_ID" ]]; then
                SOURCE_ID="$1"
            elif [[ -z "$EXTRA_DESC" ]]; then
                EXTRA_DESC="$1"
            else
                echo "Error: unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Sanitise: convert spaces to underscores, strip non-alphanumeric characters.
# Matches capture_passthrough.sh sanitisation logic.
SAFE_ID=$(printf '%s' "$SOURCE_ID" | tr '[:space:]' '_' | tr -cd '[:alnum:]_-')
SAFE_DESC=$(printf '%s' "$EXTRA_DESC" | tr '[:space:]' '_' | tr -cd '[:alnum:]_-')

# Create output root if needed and verify it is writable.
if [[ ! -d "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR" || {
        echo "Error: could not create output root: $OUTPUT_DIR"
        exit 1
    }
    echo "Created output root: $OUTPUT_DIR"
fi
if [[ ! -w "$OUTPUT_DIR" ]]; then
    echo "Error: output root is not writable: $OUTPUT_DIR"
    exit 1
fi

echo "--------------------------------------------------------"
echo "HAUPPAUGE CAPTURE SYSTEM"
echo "Detected:   Video=$VIDEO_DEV | Audio=$AUDIO_DEV"
echo "Brightness: $BRIGHTNESS (128=neutral, lower=attenuate)"
echo "Output root: $(realpath "$OUTPUT_DIR")"
echo "--------------------------------------------------------"

# --- 4. Tape Identification ---
# If SOURCE_ID was not supplied on the command line, prompt interactively.
# This mirrors capture_passthrough.sh which requires SOURCE_ID as a positional
# argument; here we accept it on the command line or via prompt for flexibility.
if [[ -z "$SAFE_ID" ]]; then
    printf "Tape SOURCE_ID (e.g. VHS or VHS_Jive_Popular_Variations): "
    read -r _raw_id </dev/tty
    SAFE_ID=$(printf '%s' "$_raw_id" | tr '[:space:]' '_' | tr -cd '[:alnum:]_-')
    if [[ -z "$SAFE_ID" ]]; then
        echo "Error: SOURCE_ID is required."
        exit 1
    fi
    printf "Description (optional, e.g. Corky_Shirley_Ballas — press Enter to skip): "
    read -r _raw_desc </dev/tty
    SAFE_DESC=$(printf '%s' "$_raw_desc" | tr '[:space:]' '_' | tr -cd '[:alnum:]_-')
    echo ""
fi

# --- 5. Input Selection ---
# If not specified on the command line, prompt the user now before the
# duration prompt so all configuration is confirmed before any hardware
# initialisation happens.
if [[ -z "$INPUT_NUM" ]]; then
    echo "Select video input:"
    echo "  1) S-Video    (use when VCR has a separate S-Video output)"
    echo "  2) Composite  (use when VCR has only composite, or S-Video clips)"
    printf "Choice [1/2]: "
    local_choice=""
    read -r local_choice </dev/tty
    case "$local_choice" in
        1)
            INPUT_NUM=1
            INPUT_LABEL="svideo"
            ;;
        2)
            INPUT_NUM=0
            INPUT_LABEL="composite"
            ;;
        *)
            echo "Error: please enter 1 for S-Video or 2 for Composite."
            exit 1
            ;;
    esac
    echo ""
fi
echo "Input:      ${INPUT_LABEL} (V4L2 input ${INPUT_NUM})"
echo "--------------------------------------------------------"

# --- 6. Duration Prompt ---
# Accepts friendly formats: bare seconds (120), or h/m/s combinations
# (10s, 39m, 1h, 1h30m, 1h30m45s).  Converts to integer seconds for ffmpeg -t.
echo "Enter duration (e.g., 10s, 39m, 1h30m, 2h) [default 10s]: "
read -r DUR_INPUT </dev/tty
DUR_INPUT=${DUR_INPUT:-10s}

# Parse into total seconds by matching each h/m/s component independently.
# Sequential =~ matches each reuse BASH_REMATCH cleanly without nested group
# index confusion.
DUR_SECS=0
if [[ "$DUR_INPUT" =~ ^[0-9]+$ ]]; then
    # Bare integer — treat as seconds.
    DUR_SECS="$DUR_INPUT"
elif [[ "$DUR_INPUT" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s?)?$ ]] \
     && [[ "$DUR_INPUT" =~ [hms] ]]; then
    [[ "$DUR_INPUT" =~ ([0-9]+)h ]] && DUR_SECS=$(( DUR_SECS + BASH_REMATCH[1] * 3600 ))
    [[ "$DUR_INPUT" =~ ([0-9]+)m ]] && DUR_SECS=$(( DUR_SECS + BASH_REMATCH[1] * 60  ))
    [[ "$DUR_INPUT" =~ ([0-9]+)s ]] && DUR_SECS=$(( DUR_SECS + BASH_REMATCH[1]       ))
else
    echo "Error: unrecognised duration '${DUR_INPUT}'."
    echo "Use seconds (120), or combine h/m/s (39m, 1h30m, 2h, 90s)."
    exit 1
fi

if (( DUR_SECS <= 0 )); then
    echo "Error: duration must be greater than zero."
    exit 1
fi

# Human-readable label for the banner.
DUR_LABEL="${DUR_INPUT}"

# --- 7. Hardware Initialization ---
v4l2-ctl -d "$VIDEO_DEV" -i "$INPUT_NUM" >/dev/null 2>&1   # Set selected input
v4l2-ctl -d "$VIDEO_DEV" -s ntsc >/dev/null 2>&1            # Force NTSC standard
# Set luma brightness/attenuation.  128 is the cx231xx neutral point; values
# below 128 reduce the ADC input level, recovering headroom on hot VCR outputs.
# The current value is reported in the banner and embedded in the filename.
v4l2-ctl -d "$VIDEO_DEV" --set-ctrl=brightness="$BRIGHTNESS" 2>/dev/null || \
    confirm_continue "brightness control not supported by this driver/device. Capture will proceed at the hardware default level; the requested attenuation will NOT be applied."

echo "Hardware initialised."
echo ""
echo "--------------------------------------------------------"
echo "  Start VCR playback now."
echo "  Wait for the JVC video calibration to complete (~7s)."
echo "  Then press Enter to begin recording."
echo "--------------------------------------------------------"
read -r < /dev/tty

# Timestamp is taken here so the filename reflects when recording actually
# starts, not when the script was launched.
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Build BASE_NAME matching capture_passthrough.sh convention:
#   SOURCE_ID[_DESCRIPTION]_TIMESTAMP
# Then append the Hauppauge-specific suffix: _INPUT_bBRIGHTNESS
if [[ -n "$SAFE_DESC" ]]; then
    BASE_NAME="${SAFE_ID}_${SAFE_DESC}_${TIMESTAMP}"
else
    BASE_NAME="${SAFE_ID}_${TIMESTAMP}"
fi

CAPTURE_DIR="${OUTPUT_DIR}/${BASE_NAME}"
mkdir -p "$CAPTURE_DIR" || {
    echo "Error: could not create capture directory: $CAPTURE_DIR"
    exit 1
}
OUTPUT_FILE="${CAPTURE_DIR}/${BASE_NAME}_${INPUT_LABEL}_b${BRIGHTNESS}.mkv"

# --- 8. Action: Starting Combined Capture & Monitor ---
# Using rawvideo for master archive and NUT pipe for live monitoring
# Removed -nodb and -alwaysontop to avoid the ESM parsing errors
echo "ACTION: Starting Lossless FFV1 Capture for ${DUR_LABEL} (${DUR_SECS}s)..."
echo "FILE:   $OUTPUT_FILE"
echo "EXIT:   Press 'q' in the monitor window to stop"
echo "--------------------------------------------------------"

# Using FFV1 version 3 for archival stability.
# Archive is written as FFV1 lossless to the MKV file.
# The NUT pipe to ffplay provides the live monitor with audio.
ffmpeg -hide_banner -loglevel error \
       -f v4l2 -thread_queue_size 2048 -video_size 720x480 -i "$VIDEO_DEV" \
       -f alsa -thread_queue_size 2048 -i "$AUDIO_DEV" \
       -t "$DUR_SECS" \
       -c:v ffv1 -level 3 -coder 1 -context 1 -pix_fmt yuyv422 \
       -c:a pcm_s16le \
       -f tee -map 0:v -map 1:a \
       "$OUTPUT_FILE|[f=nut]pipe:1" | ffplay -i - -window_title "RECORDING MONITOR" -autoexit

# --- 9. Terminal Completion Alert ---
if [ -f "$OUTPUT_FILE" ]; then
    SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    echo -e "\a"
    echo "********************************************************"
    echo "             CAPTURE FINISHED SUCCESSFULLY             "
    echo "********************************************************"
    echo "FILE: $OUTPUT_FILE ($SIZE)"
    echo "NEXT: Run 'vhs_quality.sh $OUTPUT_FILE'"
    echo "********************************************************"
else
    echo -e "\a"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "                ERROR: CAPTURE FAILED                  "
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi
