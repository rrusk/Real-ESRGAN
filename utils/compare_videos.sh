#!/bin/bash
# ==============================================================================
# compare_videos.sh
# Launches original (at 2x zoom) and 2x enhanced video side-by-side for
# visual comparison using your choice of media player.
# Checks for all supported players and reports any that are missing.
#
# Usage:
#   ./compare_videos.sh <original_file> <enhanced_file> [player]
#
# Players: mpv, ffplay, vlc
# If no player is specified, the first available one is used.
#
# Examples:
#   ./compare_videos.sh original.mp4 enhanced.mkv
#   ./compare_videos.sh original.mp4 enhanced.mkv mpv
#   ./compare_videos.sh original.mp4 enhanced.mkv ffplay
# ==============================================================================

set -euo pipefail

# --- Supported players ---
SUPPORTED_PLAYERS=("mpv" "ffplay" "vlc")

# Helper: map player name to apt package (needed before argument check)
apt_package() {
    case "$1" in
        vlc)       echo "vlc" ;;
        mpv)       echo "mpv" ;;
        ffplay)    echo "ffmpeg" ;;
        *)         echo "$1" ;;
    esac
}

# --- Check which players are available (always runs, even with no args) ---
AVAILABLE=()
MISSING=()
for player in "${SUPPORTED_PLAYERS[@]}"; do
    if command -v "$player" >/dev/null 2>&1; then
        AVAILABLE+=("$player")
    else
        MISSING+=("$player")
    fi
done

# --- Argument check ---
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <original_file> <enhanced_file> [player]"
    echo ""
    echo "--- Player Availability ---"
    for player in "${SUPPORTED_PLAYERS[@]}"; do
        if command -v "$player" >/dev/null 2>&1; then
            echo "  ✅ $player"
        else
            echo "  ❌ $player  (sudo apt install $(apt_package $player))"
        fi
    done
    echo ""
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "--- Missing Players (install commands) ---"
        for player in "${MISSING[@]}"; do
            echo "  sudo apt install $(apt_package $player)"
        done
        echo ""
    fi
    echo "Examples:"
    echo "  $0 original.mp4 enhanced.mkv"
    echo "  $0 original.mp4 enhanced.mkv mpv"
    echo "  $0 original.mp4 enhanced.mkv ffplay"
    exit 1
fi

ORIGINAL="$1"
ENHANCED="$2"
REQUESTED_PLAYER="${3:-}"

# --- File checks ---
if [[ ! -f "$ORIGINAL" ]]; then
    echo "Error: Original file not found: $ORIGINAL"
    exit 1
fi

if [[ ! -f "$ENHANCED" ]]; then
    echo "Error: Enhanced file not found: $ENHANCED"
    exit 1
fi

echo "--- Player Availability ---"
for player in "${SUPPORTED_PLAYERS[@]}"; do
    if command -v "$player" >/dev/null 2>&1; then
        echo "  ✅ $player"
    else
        echo "  ❌ $player  (sudo apt install $(apt_package $player))"
    fi
done
echo ""

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "--- Missing Players (install commands) ---"
    for player in "${MISSING[@]}"; do
        echo "  sudo apt install $(apt_package $player)"
    done
    echo ""
fi

if [[ ${#AVAILABLE[@]} -eq 0 ]]; then
    echo "Error: No supported players found. Install at least one:"
    for player in "${SUPPORTED_PLAYERS[@]}"; do
        echo "  sudo apt install $(apt_package $player)"
    done
    exit 1
fi

# --- Select player ---
if [[ -n "$REQUESTED_PLAYER" ]]; then
    if ! command -v "$REQUESTED_PLAYER" >/dev/null 2>&1; then
        echo "Error: Requested player '$REQUESTED_PLAYER' is not installed."
        echo "Install with: sudo apt install $(apt_package $REQUESTED_PLAYER)"
        echo ""
        echo "Available players: ${AVAILABLE[*]}"
        exit 1
    fi
    PLAYER="$REQUESTED_PLAYER"
else
    # Use first available in priority order: mpv > ffplay > vlc
    PLAYER="${AVAILABLE[0]}"
    echo "No player specified. Using: $PLAYER"
    echo "(Override with: $0 $ORIGINAL $ENHANCED <player>)"
    echo ""
fi

# --- Get video dimensions for zoom calculation ---
PIX_WIDTH=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 "$ORIGINAL")
PIX_HEIGHT=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 "$ORIGINAL")
SAR=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=sample_aspect_ratio \
    -of default=noprint_wrappers=1:nokey=1 "$ORIGINAL")

# Compute display dimensions respecting SAR
if [[ -z "$SAR" || "$SAR" == "N/A" || "$SAR" == "0:1" || "$SAR" == "1:1" ]]; then
    DISPLAY_WIDTH=$PIX_WIDTH
    DISPLAY_HEIGHT=$PIX_HEIGHT
else
    SAR_NUM=$(echo "$SAR" | cut -d: -f1)
    SAR_DEN=$(echo "$SAR" | cut -d: -f2)
    DISPLAY_WIDTH=$(python3 -c "print(round($PIX_WIDTH * $SAR_NUM / $SAR_DEN))")
    DISPLAY_HEIGHT=$PIX_HEIGHT
fi

# 2x zoom display dimensions for original window
ZOOM_WIDTH=$((DISPLAY_WIDTH * 2))
ZOOM_HEIGHT=$((DISPLAY_HEIGHT * 2))

echo "--- Video Info ---"
echo "  Original  : ${PIX_WIDTH}x${PIX_HEIGHT} pixels, SAR ${SAR:-1:1}, display ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}"
echo "  At 2x zoom: ${ZOOM_WIDTH}x${ZOOM_HEIGHT}"
echo "  Enhanced  : playing at natural size (should match 2x zoom of original)"
echo ""
echo "--- Launching with: $PLAYER ---"
echo ""

# --- Launch side by side ---
case "$PLAYER" in

    mpv)
        # mpv: --geometry=WxH+X+Y positions the window
        # Original at 2x zoom on the left, enhanced natural size on the right
        echo "Original  (2x zoom): left side"
        echo "Enhanced (natural) : right side"
        echo ""
        mpv \
            --title="ORIGINAL (2x zoom) - $ORIGINAL" \
            --geometry="${ZOOM_WIDTH}x${ZOOM_HEIGHT}+0+0" \
            --vf="scale=${ZOOM_WIDTH}:${ZOOM_HEIGHT}" \
            --loop-file=inf \
            "$ORIGINAL" &
        sleep 1
        mpv \
            --title="ENHANCED (natural) - $ENHANCED" \
            --geometry="${ZOOM_WIDTH}x${ZOOM_HEIGHT}+$((ZOOM_WIDTH + 10))+0" \
            --loop-file=inf \
            "$ENHANCED" &
        ;;

    ffplay)
        # ffplay: -x/-y set window size, -left sets X position
        echo "Original  (2x zoom): left side"
        echo "Enhanced (natural) : right side"
        echo "Press 'q' in each window to quit."
        echo ""
        ffplay \
            -x "$ZOOM_WIDTH" -y "$ZOOM_HEIGHT" \
            -vf "scale=${ZOOM_WIDTH}:${ZOOM_HEIGHT}" \
            -window_title "ORIGINAL (2x zoom)" \
            -left 0 \
            "$ORIGINAL" &
        sleep 1
        ffplay \
            -x "$ZOOM_WIDTH" -y "$ZOOM_HEIGHT" \
            -window_title "ENHANCED (natural)" \
            -left "$((ZOOM_WIDTH + 10))" \
            "$ENHANCED" &
        ;;

    vlc)
        # VLC: --width/--height set window size, --video-x/--video-y set position
        # Use :zoom=2 for the original to get 2x zoom
        echo "Original  (2x zoom): left side"
        echo "Enhanced (natural) : right side"
        echo ""
        vlc \
            --width="$ZOOM_WIDTH" --height="$ZOOM_HEIGHT" \
            --video-x=0 --video-y=0 \
            --no-video-title-show \
            --input-title-format="ORIGINAL (2x zoom)" \
            --zoom=2 \
            "$ORIGINAL" &
        sleep 1
        vlc \
            --width="$ZOOM_WIDTH" --height="$ZOOM_HEIGHT" \
            --video-x="$((ZOOM_WIDTH + 10))" --video-y=0 \
            --no-video-title-show \
            --input-title-format="ENHANCED (natural)" \
            "$ENHANCED" &
        ;;



esac

echo "Both players launched."
echo ""
echo "What to look for:"
echo "  - Original at 2x zoom and Enhanced at natural size should appear the same physical size"
echo "  - Enhanced should show noticeably more detail and sharpness"
echo "  - Aspect ratio should look identical between both windows (no stretching)"
