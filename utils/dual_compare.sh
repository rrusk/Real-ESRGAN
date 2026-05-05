#!/usr/bin/env bash
# ==============================================================================
# dual_compare.sh
# Integrated three-phase video comparison tool for Hi8 DV vs DVD source files.
#
# Phase 1 — Audio peak detection (find_offset.sh logic)
#   Estimates the time offset between two captures by finding matching audio
#   transients. Shows the result for confirmation before proceeding.
#
# Phase 2 — Frame-accurate alignment (blink_compare.sh)
#   Launches an interactive HTML blink/diff comparator at the audio peak
#   position (or a user-specified time) for single-frame offset fine-tuning.
#   Polls for alignment.json saved by the comparator, then confirms before
#   proceeding to playback.
#
# Phase 3 — Synchronized side-by-side playback (mpv + Lua IPC)
#   Launches both videos in adjacent mpv windows, locked together by the
#   confirmed offset. Transport controls operate both windows simultaneously.
#   Left video audio plays in the left channel, right video in the right
#   channel — with headphones, differences between the two sources are
#   immediately audible as events in one ear only.
#   To swap left/right, reverse the order of input files on the command line.
#   Optional waypoints file enables n/p navigation to pre-defined positions.
#
# Usage:
#   ./dual_compare.sh [OPTIONS] <left_input> <right_input>
#
#   Inputs may be raw video files (.dv, .avi, .mpg, .mkv, .mp4) or DVD ISO
#   images (.iso). ISO inputs are mounted in /tmp, extracted as MPEG-2 to
#   /storage/Videos/compare/, then unmounted — nothing is left in /tmp.
#
# Options:
#   --aligned           Declare that both inputs are already time-aligned
#                       (same start point, zero offset). Creates alignment.json
#                       with offset=0 if one does not yet exist, then jumps
#                       straight to phase 3. Ideal for comparing an original
#                       capture against an upscaled or processed version.
#   --resume DIR        Skip phases 1 & 2, read alignment.json from DIR,
#                       go straight to phase 3.
#   --start TIME        Start playback at TIME in the left file (mm:ss or
#                       hh:mm:ss). Used with --resume to continue a session.
#   --waypoints FILE    File of timecodes to navigate with n/p keys.
#                       Use <session_dir>/waypoints.txt from compare_dv_dvd.sh.
#   --left-label LABEL  Display label for left input (default: filename stem)
#   --right-label LABEL Display label for right input (default: filename stem)
#   --blink PATH        Path to blink_compare.sh (default: same dir as this)
#   --find-offset PATH  Path to find_offset.sh (default: same dir as this)
#   --blink-frames N    Number of frames extracted for the phase-2 blink
#                       comparator (default: 60). Increase when the default
#                       window does not contain a clean alignment point.
#
# Phase 3 controls (mpv):
#   Space       Pause / resume both
#   [ / ]       Seek back / forward 5 seconds in both
#   , / .       Step one frame back / forward in both
#   z / x       Nudge right video back / forward 1 frame (fine alignment)
#   Z / X       Nudge right video back / forward 2 seconds (coarse, crosses GOP)
#   a           Mute / unmute this window only
#   m / M       Mute both / Unmute both
#   n / p       Next / previous waypoint (requires --waypoints)
#   q           Quit both windows
#
# Dependencies: mpv, ffmpeg, ffprobe, python3, xdg-open, socat, sudo (ISO mount)
#
# Session directory: named from input filename stems joined with _vs_
#   e.g. compare_hi8_19960525-19961117_vs_19960525_19961117/
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
ALIGNED=""         # set to 1 with --aligned to skip phases 1 & 2 with offset=0
RESUME_DIR=""
START_TIME="0"
WAYPOINTS_FILE=""
LEFT_LABEL_OVERRIDE=""
RIGHT_LABEL_OVERRIDE=""
BLINK_SCRIPT="${SCRIPT_DIR}/blink_compare.sh"
FIND_OFFSET_SCRIPT="${SCRIPT_DIR}/find_offset.sh"
COMPARE_DIR="${HOME}/video_compare_work"  # symlink to actual storage
PEAK_WINDOW=60
BLINK_FRAMES=60     # frames extracted for phase-2 blink comparator; raise with --blink-frames if
                    # the default window is too narrow to find a clean alignment point
SOFTWARE_RENDER=""  # set to 1 with --software-render to use x11 vo (safe with CUDA pipelines)
REALIGN_THRESHOLD=15  # minutes from last calibration before offering blink realign on resume
DISPLAY_SCREEN=""   # xrandr output name to place mpv windows on (e.g. HDMI-1, DP-1);
                    # default is the primary display.  Use --screen to override.

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
usage() {
    cat << 'EOF'

Usage: ./dual_compare.sh [OPTIONS] <left_input> <right_input>

Options:
  --aligned           Skip phases 1 & 2; treat inputs as time-aligned (offset=0).
                      Writes alignment.json if absent, then jumps to playback.
                      Ideal for original vs upscaled/processed comparisons.
  --resume DIR        Skip phases 1 & 2, read existing alignment.json from DIR
  --start TIME        Start playback at TIME (mm:ss or hh:mm:ss), use with --resume
  --waypoints FILE    Timecode file for n/p waypoint navigation
                      (use <session_dir>/waypoints.txt from compare_dv_dvd.sh)
  --compare-dir DIR   Base directory for session output (default: ~/video_compare_work)
                      ~/video_compare_work should be a symlink to actual storage
  --left-label LABEL  Display label for left input
  --right-label LABEL Display label for right input
  --software-render       Use x11 software rendering (no GPU). Safe to run alongside
                          CUDA pipelines. Default is GPU rendering (--vo=gpu).
  --screen NAME           xrandr output name to place mpv windows on (e.g. HDMI-1,
                          DP-1, DP-2). Default: primary display. Run 'xrandr' to
                          list connected outputs and their names.
  --realign-threshold N   Minutes from last blink calibration before offering to
                          realign on resume. Default: 15. Set 0 to always prompt.
  --blink-frames N        Number of frames extracted for phase-2 blink comparator.
                          Default: 60. Increase when the default window is too
                          narrow to find a clean alignment point.

Phase 3 controls:
  Space   Pause/resume both    [ / ]   Seek ±5s in both
  , / .   Step one frame       z / x   Nudge right ±1 frame (fine)
  Z / X   Nudge right ±2s      a       Mute/unmute this window
  m / M   Mute both / Unmute   n / p   Next/prev waypoint
  q       Quit both

Audio: left video → left ear (mono mix), right video → right ear (mono mix).
       To swap left/right, reverse the order of input files.
       With headphones, differences between sources are audible in one ear.

EOF
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --aligned)      ALIGNED=1;                shift   ;;
        --resume)       RESUME_DIR="$2";          shift 2 ;;
        --start)        START_TIME="$2";           shift 2 ;;
        --waypoints)    WAYPOINTS_FILE="$2";       shift 2 ;;
        --compare-dir)  COMPARE_DIR="$2";          shift 2 ;;
        --left-label)   LEFT_LABEL_OVERRIDE="$2";  shift 2 ;;
        --right-label)  RIGHT_LABEL_OVERRIDE="$2"; shift 2 ;;
        --blink)            BLINK_SCRIPT="$2";         shift 2 ;;
        --find-offset)      FIND_OFFSET_SCRIPT="$2";   shift 2 ;;
        --software-render)      SOFTWARE_RENDER=1;                shift   ;;
        --screen)               DISPLAY_SCREEN="$2";              shift 2 ;;
        --realign-threshold)    REALIGN_THRESHOLD="$2";           shift 2 ;;
        --blink-frames)         BLINK_FRAMES="$2";                shift 2 ;;
        --help|-h)      usage ;;
        --) shift; break ;;
        -*) echo "[ERROR] Unknown option: $1"; usage ;;
        *)  break ;;
    esac
done

if [[ "$#" -lt 2 ]]; then
    echo "[ERROR] Two input files are required."
    usage
fi

LEFT_RAW="$1"
RIGHT_RAW="$2"

# ------------------------------------------------------------------------------
# Dependency checks
# ------------------------------------------------------------------------------
check_dep() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[ERROR] Required tool not found: $1"
        echo "        Install with: sudo apt install $2"
        exit 1
    fi
}

check_dep mpv       mpv
check_dep ffmpeg    ffmpeg
check_dep ffprobe   ffmpeg
check_dep python3   python3
check_dep xdg-open  xdg-utils

# Validate waypoints file if provided
WAYPOINTS_DATA=""
N_WAYPOINTS=0
if [[ -n "$WAYPOINTS_FILE" ]]; then
    if [[ ! -f "$WAYPOINTS_FILE" ]]; then
        echo "[ERROR] Waypoints file not found: $WAYPOINTS_FILE"
        exit 1
    fi
    # Read non-comment, non-empty lines: TIMECODE [LABEL]
    # Store as JSON array string for embedding in Lua
    WAYPOINTS_DATA=$(python3 -c "
import re, json, sys
waypoints = []
with open('$WAYPOINTS_FILE') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split(None, 1)
        tc = parts[0]
        label = parts[1] if len(parts) > 1 else tc
        # Parse timecode to seconds
        m = re.match(r'(\d+):(\d+):(\d+)[.,](\d+)', tc)
        if m:
            secs = int(m.group(1))*3600 + int(m.group(2))*60 + int(m.group(3)) + int(m.group(4))/1000
        else:
            m2 = re.match(r'(\d+):(\d+)', tc)
            if m2:
                secs = int(m2.group(1))*60 + float(m2.group(2))
            else:
                secs = float(tc)
        waypoints.append({'secs': secs, 'tc': tc, 'label': label})
print(json.dumps(waypoints))
")
    N_WAYPOINTS=$(python3 -c "import json; print(len(json.loads('${WAYPOINTS_DATA//\'/\'\\\'\'}')))" 2>/dev/null || echo 0)
    echo "  Waypoints loaded : $N_WAYPOINTS from $WAYPOINTS_FILE"
fi
if [[ -z "$RESUME_DIR" ]]; then
    # Only needed for phases 1 & 2
    if [[ ! -x "$BLINK_SCRIPT" ]]; then
        echo "[ERROR] blink_compare.sh not found or not executable: $BLINK_SCRIPT"
        echo "        Use --blink PATH to specify its location."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Helper: check_alignment_json
# Checks SESSION_DIR and ~/Downloads/ for alignment.json, moves if found in
# Downloads. Used both in phase 2 polling and after realign on resume.
# ------------------------------------------------------------------------------
check_alignment_json() {
    if [[ -f "$ALIGNMENT_JSON" ]]; then
        return 0
    fi
    if [[ -f "${HOME}/Downloads/alignment.json" ]]; then
        mv "${HOME}/Downloads/alignment.json" "$ALIGNMENT_JSON"
        echo "  Moved alignment.json from ~/Downloads/ to session directory."
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Helper: confirm_continue
# Prompts after important steps. Reads from /dev/tty.
# ------------------------------------------------------------------------------
confirm_continue() {
    local prompt="$1"
    local answer
    printf "\n  %s [y/N] " "$prompt"
    read -r answer </dev/tty
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "  Aborting."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Helper: parse time string to seconds (mm:ss, hh:mm:ss, or raw seconds)
# ------------------------------------------------------------------------------
parse_time() {
    local T="$1"
    local PARTS
    IFS=':' read -ra PARTS <<< "$T"
    case ${#PARTS[@]} in
        1) python3 -c "print(float('${PARTS[0]}'))" ;;
        2) python3 -c "print(int('${PARTS[0]}') * 60 + float('${PARTS[1]}'))" ;;
        3) python3 -c "print(int('${PARTS[0]}') * 3600 + int('${PARTS[1]}') * 60 + float('${PARTS[2]}'))" ;;
        *)
            echo "[ERROR] Invalid time format: $T"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Helper: format seconds to HH:MM:SS.mmm
# ------------------------------------------------------------------------------
format_tc() {
    python3 -c "
s = float('$1')
h = int(s/3600); m = int((s%3600)/60); sec = s%60
print(f'{h:02d}:{m:02d}:{sec:06.3f}')
"
}

# ------------------------------------------------------------------------------
# Helper: get filename stem (no path, no extension)
# ------------------------------------------------------------------------------
stem() {
    basename "$1" | sed 's/\.[^.]*$//'
}

# ------------------------------------------------------------------------------
# Helper: audio peak detection
# Finds the loudest transient within PEAK_WINDOW seconds of START in FILE.
# Prints absolute timestamp in seconds, or NOT_FOUND.
# ------------------------------------------------------------------------------
find_peak() {
    local FILE="$1"
    local START="${2:-0}"
    local TMPFILE
    TMPFILE=$(mktemp /tmp/dual_peak_XXXXXX.txt)

    ffmpeg -ss "$START" -t "$PEAK_WINDOW" -i "$FILE" \
        -map 0:a:0 \
        -af "aresample=44100,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.Peak_level:file=${TMPFILE}" \
        -vn -f null - 2>/dev/null || true

    local PEAK_TIME
    PEAK_TIME=$(awk '
        /pts_time:/ { split($0,a,"pts_time:"); pts=a[2] }
        /lavfi.astats.Overall.Peak_level=/ {
            split($0,a,"="); val=a[2]
            if (val=="-inf") next
            val=val+0
            if (!found || val>max_val) { max_val=val; max_pts=pts; found=1 }
        }
        END { if (found) print max_pts; else print "NOT_FOUND" }
    ' "$TMPFILE")

    rm -f "$TMPFILE"

    if [[ -z "$PEAK_TIME" || "$PEAK_TIME" == "NOT_FOUND" ]]; then
        echo "NOT_FOUND"
        return 0
    fi

    python3 -c "print(round(${START} + ${PEAK_TIME}, 3))"
}

# ==============================================================================
# MAIN
# ==============================================================================

echo ""
echo "============================================="
echo "  dual_compare.sh"
echo "============================================="

# ------------------------------------------------------------------------------
# Resolve inputs — extract ISOs if needed
# ------------------------------------------------------------------------------
echo ""
echo "[Setup] Resolving inputs..."

# Validate COMPARE_DIR — needed for ISO extraction
if [[ ! -d "$COMPARE_DIR" ]]; then
    echo "[ERROR] Compare directory not found: $COMPARE_DIR"
    echo "  Create a symlink to your storage location:"
    echo "  ln -s /storage/Videos/compare ~/video_compare_work"
    echo "  Or use --compare-dir PATH to specify a different location."
    exit 1
fi

resolve_input() {
    # Sets RESOLVED_INPUT global — avoids $() subshell which swallows sudo prompt
    local INPUT="$1"
    local SIDE="$2"
    if [[ "${INPUT,,}" == *.iso ]]; then
        echo "  ${SIDE}: ISO image detected — extracting MPEG-2..."
        local ISO_STEM
        ISO_STEM=$(stem "$INPUT")
        local MPG_OUT="${COMPARE_DIR}/${ISO_STEM}.mpg"

        if [[ -f "$MPG_OUT" ]]; then
            echo ""
            echo "  Existing extraction found: $MPG_OUT"
            echo "  Size: $(du -h "$MPG_OUT" | cut -f1)"
            if [[ -n "$RESUME_DIR" ]]; then
                echo "  Reusing (resume mode)."
                RESOLVED_INPUT="$MPG_OUT"
                return 0
            fi
            printf "  Reuse it? [Y/n] "
            local answer
            read -r answer </dev/tty
            if [[ ! "$answer" =~ ^[Nn]$ ]]; then
                RESOLVED_INPUT="$MPG_OUT"
                return 0
            fi
        fi

        mkdir -p "$COMPARE_DIR"
        local MOUNT_POINT
        MOUNT_POINT=$(mktemp -d /tmp/dvd_mount_XXXXXX)

        echo ""
        echo "  Mounting ISO: $INPUT"
        echo "  Mount point:  $MOUNT_POINT  (will be removed after extraction)"
        echo "  Output:       $MPG_OUT"

        trap "sudo umount '$MOUNT_POINT' 2>/dev/null; rmdir '$MOUNT_POINT' 2>/dev/null" EXIT

        sudo mount -o loop,ro "$INPUT" "$MOUNT_POINT"

        local VOBS
        mapfile -t VOBS < <(ls "$MOUNT_POINT"/VIDEO_TS/VTS_*_[1-9]*.VOB 2>/dev/null || true)

        if [[ ${#VOBS[@]} -eq 0 ]]; then
            sudo umount "$MOUNT_POINT"
            rmdir "$MOUNT_POINT"
            trap - EXIT
            echo "[ERROR] No content VOB files found in $INPUT"
            exit 1
        fi

        echo "  VOB segments: ${#VOBS[@]}"

        cat "${VOBS[@]}" | ffmpeg -y -i - \
            -map 0:v:0 -map 0:a:0 \
            -vcodec copy -acodec copy \
            "$MPG_OUT" 2>/dev/null

        sudo umount "$MOUNT_POINT"
        rmdir "$MOUNT_POINT"
        trap - EXIT

        echo "  Extracted: $(du -h "$MPG_OUT" | cut -f1)"
        RESOLVED_INPUT="$MPG_OUT"
    else
        if [[ ! -f "$INPUT" ]]; then
            echo "[ERROR] File not found: $INPUT"
            exit 1
        fi
        RESOLVED_INPUT="$INPUT"
    fi
}

RESOLVED_INPUT=""
resolve_input "$LEFT_RAW" "Left"
LEFT_FILE="$RESOLVED_INPUT"

resolve_input "$RIGHT_RAW" "Right"
RIGHT_FILE="$RESOLVED_INPUT"

# Labels
get_default_label() { stem "$1"; }
LEFT_LABEL="${LEFT_LABEL_OVERRIDE:-$(get_default_label "$LEFT_FILE")}"
RIGHT_LABEL="${RIGHT_LABEL_OVERRIDE:-$(get_default_label "$RIGHT_FILE")}"

echo ""
echo "  Left  : $LEFT_FILE"
echo "  Right : $RIGHT_FILE"
echo "  Labels: [$LEFT_LABEL] vs [$RIGHT_LABEL]"

# ------------------------------------------------------------------------------
# Session directory — named from input stems, lives under COMPARE_DIR
# ------------------------------------------------------------------------------
LEFT_STEM=$(stem "$LEFT_FILE")
RIGHT_STEM=$(stem "$RIGHT_FILE")
SESSION_DIR="${COMPARE_DIR}/compare_${LEFT_STEM}_vs_${RIGHT_STEM}"

if [[ -n "$RESUME_DIR" ]]; then
    SESSION_DIR="$RESUME_DIR"
fi

mkdir -p "$SESSION_DIR"

ALIGNMENT_JSON="${SESSION_DIR}/alignment.json"

# ==============================================================================
# ALIGNED MODE — both inputs share the same start point (offset = 0).
# Creates alignment.json if absent, then falls into the normal resume path.
# ==============================================================================
if [[ -n "$ALIGNED" ]]; then
    if [[ ! -f "$ALIGNMENT_JSON" ]]; then
        echo ""
        echo "[Aligned] Writing zero-offset alignment.json..."
        python3 -c "
import json
d = {
    'offset':      0,
    'left_label':  '$LEFT_LABEL',
    'right_label': '$RIGHT_LABEL',
    'aligned_at':  '00:00:00.000',
    'note':        'created by --aligned flag (inputs declared pre-aligned)'
}
json.dump(d, open('$ALIGNMENT_JSON', 'w'), indent=2)
print('  Written:', '$ALIGNMENT_JSON')
"
    else
        echo ""
        echo "[Aligned] Existing alignment.json found — using it as-is."
        echo "  $ALIGNMENT_JSON"
    fi
    # Hand off to the resume path
    RESUME_DIR="$SESSION_DIR"
fi

# ==============================================================================
# RESUME MODE — skip phases 1 & 2
# ==============================================================================
# Trigger either via explicit --resume DIR flag, or by auto-detecting both
# alignment.json and resume.json in the session directory (i.e. a previous
# run completed phases 1 & 2 and wrote a saved position).
RESUME_JSON="${SESSION_DIR}/resume.json"

if [[ -z "$RESUME_DIR" && -f "$ALIGNMENT_JSON" && -f "$RESUME_JSON" ]]; then
    AUTO_RESUME_TC=$(python3 -c "
import json
d = json.load(open('$RESUME_JSON'))
print(d.get('position_tc', ''))
" 2>/dev/null || true)
    if [[ -n "$AUTO_RESUME_TC" ]]; then
        echo ""
        echo "  Saved session detected."
        echo "    Alignment : $ALIGNMENT_JSON"
        echo "    Position  : $AUTO_RESUME_TC"
        printf "  Resume from %s? [Y/n] " "$AUTO_RESUME_TC"
        read -r auto_resume_answer </dev/tty
        if [[ ! "$auto_resume_answer" =~ ^[Nn]$ ]]; then
            RESUME_DIR="$SESSION_DIR"
            # Set START_TIME now so the phase-3 resume prompt does not fire again
            START_TIME="$AUTO_RESUME_TC"
        fi
    fi
fi

if [[ -n "$RESUME_DIR" ]]; then
    echo ""
    echo "[Resume] Reading alignment from $ALIGNMENT_JSON..."

    if [[ ! -f "$ALIGNMENT_JSON" ]]; then
        echo "[ERROR] alignment.json not found in $RESUME_DIR"
        echo "        Run without --resume to complete phases 1 and 2 first."
        exit 1
    fi

    CONFIRMED_OFFSET=$(python3 -c "
import json
d = json.load(open('$ALIGNMENT_JSON'))
print(d['offset'])
")
    CONFIRMED_LEFT_LABEL=$(python3 -c "
import json
d = json.load(open('$ALIGNMENT_JSON'))
print(d.get('left_label', ''))
" 2>/dev/null || echo "$LEFT_LABEL")
    CONFIRMED_RIGHT_LABEL=$(python3 -c "
import json
d = json.load(open('$ALIGNMENT_JSON'))
print(d.get('right_label', ''))
" 2>/dev/null || echo "$RIGHT_LABEL")

    [[ -n "$CONFIRMED_LEFT_LABEL"  ]] && LEFT_LABEL="$CONFIRMED_LEFT_LABEL"
    [[ -n "$CONFIRMED_RIGHT_LABEL" ]] && RIGHT_LABEL="$CONFIRMED_RIGHT_LABEL"

    echo "  Confirmed offset : ${CONFIRMED_OFFSET}s"
    echo "  Left label       : $LEFT_LABEL"
    echo "  Right label      : $RIGHT_LABEL"
    echo "  Start time       : $START_TIME"

    # Fall through to phase 3 section at bottom of script
    SKIP_TO_PLAYBACK=true
else
    SKIP_TO_PLAYBACK=false
fi

# ==============================================================================
# PHASE 1 — Audio peak detection
# ==============================================================================
# cleanup() is defined here (before first use) so the EXIT trap covers all
# phases.  Phase-3 variables are guarded with :- so early exits are safe.
cleanup() {
    # Remove any alignment.json left in ~/Downloads by the browser.  If the
    # script exits before check_alignment_json() moves it to the session dir,
    # this prevents it from silently interfering with a later run.
    rm -f "${HOME}/Downloads/alignment.json"
    # Phase-3 temporaries (may be unset if we exit before Phase 3).
    [[ -n "${LUA_SCRIPT:-}"       ]] && rm -f "$LUA_SCRIPT"
    [[ -n "${LEFT_LABEL_FILE:-}"  ]] && rm -f "$LEFT_LABEL_FILE"
    [[ -n "${RIGHT_LABEL_FILE:-}" ]] && rm -f "$RIGHT_LABEL_FILE"
    [[ -n "${LEFT_SOCKET:-}"      ]] && rm -f "$LEFT_SOCKET"  2>/dev/null || true
    [[ -n "${RIGHT_SOCKET:-}"     ]] && rm -f "$RIGHT_SOCKET" 2>/dev/null || true
    [[ -n "${LEFT_PID:-}"         ]] && kill "$LEFT_PID"  2>/dev/null || true
    [[ -n "${RIGHT_PID:-}"        ]] && kill "$RIGHT_PID" 2>/dev/null || true
    stty sane 2>/dev/null || true  # restore terminal if mpv left it in raw mode
}
trap cleanup EXIT

if [[ "$SKIP_TO_PLAYBACK" == false ]]; then

echo ""
echo "============================================="
echo "  Phase 1: Audio peak detection"
echo "============================================="
echo ""

PHASE1_DONE=false
MANUAL_OFFSET=""

while [[ "$PHASE1_DONE" == false ]]; do

    if [[ -n "$MANUAL_OFFSET" ]]; then
        # User entered offset manually — accept immediately, no re-confirmation needed
        RAW_OFFSET="$MANUAL_OFFSET"
        PEAK_LEFT="manual"
        PEAK_RIGHT="manual"
        COARSE_OFFSET="$RAW_OFFSET"
        DEFAULT_ALIGN_TIME="30"  # fallback alignment point when no audio peak available
        echo "  Using manual offset: ${RAW_OFFSET}s"
        break
    else
        echo "  Analysing left file  : $LEFT_FILE"
        PEAK_LEFT=$(find_peak "$LEFT_FILE")
        echo "  Left peak            : ${PEAK_LEFT}s"
        echo ""
        echo "  Analysing right file : $RIGHT_FILE"
        PEAK_RIGHT=$(find_peak "$RIGHT_FILE")
        echo "  Right peak           : ${PEAK_RIGHT}s"

        if [[ "$PEAK_LEFT" == "NOT_FOUND" || "$PEAK_RIGHT" == "NOT_FOUND" ]]; then
            echo ""
            echo "  [WARN] Audio peak detection failed for one or both files."
            echo "  Options:"
            echo "    m  — enter offset manually"
            echo "    v  — launch rough side-by-side in VLC to estimate offset visually"
            echo "    q  — quit"
            printf "  Choice [m/v/q]: "
            read -r choice </dev/tty
            case "$choice" in
                m|M)
                    printf "  Enter offset in seconds (positive = left leads right): "
                    read -r MANUAL_OFFSET </dev/tty
                    ;;
                v|V)
                    echo "  Launching rough side-by-side in VLC..."
                    vlc "$LEFT_FILE" &
                    sleep 1
                    vlc "$RIGHT_FILE" &
                    echo "  Find a matching moment in both VLC windows."
                    printf "  Enter offset when done (left_time - right_time in seconds): "
                    read -r MANUAL_OFFSET </dev/tty
                    ;;
                q|Q) echo "  Quitting."; exit 0 ;;
                *)   echo "  Unknown choice."; continue ;;
            esac
            continue
        fi

        RAW_OFFSET=$(python3 -c "print(round(${PEAK_LEFT} - ${PEAK_RIGHT}, 3))")
    fi

    # Display offset in human-readable form
    ABS_OFFSET=$(python3 -c "print(abs(float('${RAW_OFFSET}')))")
    OFFSET_TC=$(format_tc "$ABS_OFFSET")
    OFFSET_FRAMES=$(python3 -c "print(round(abs(float('${RAW_OFFSET}')) * 29.97))")

    if python3 -c "import sys; sys.exit(0 if float('${RAW_OFFSET}') > 0 else 1)"; then
        LEAD_SIDE="LEFT leads RIGHT"
    elif python3 -c "import sys; sys.exit(0 if float('${RAW_OFFSET}') < 0 else 1)"; then
        LEAD_SIDE="RIGHT leads LEFT"
    else
        LEAD_SIDE="files appear in sync"
    fi

    echo ""
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │  Detected offset: ${RAW_OFFSET}s"
    echo "  │  ${LEAD_SIDE}"
    echo "  │  (~${OFFSET_FRAMES} frames at 29.97fps)"
    echo "  └─────────────────────────────────────────┘"
    echo ""
    echo "  Does this look reasonable?"
    if python3 -c "import sys; sys.exit(0 if float('${RAW_OFFSET}') == 0 else 1)" 2>/dev/null; then
        echo "    y — yes, files are in sync (will offer to skip blink comparator)"
    else
        echo "    y — yes, proceed to frame alignment"
    fi
    echo "    m — enter offset manually instead"
    echo "    v — launch rough VLC side-by-side to estimate visually"
    echo "    q — quit"
    printf "  Choice [y/m/v/q]: "
    read -r choice </dev/tty

    case "$choice" in
        y|Y)
            PHASE1_DONE=true
            COARSE_OFFSET="$RAW_OFFSET"
            DEFAULT_ALIGN_TIME="$PEAK_LEFT"  # audio peak position in left file
            ;;
        m|M)
            printf "  Enter offset (positive = left leads right, in seconds): "
            read -r MANUAL_OFFSET </dev/tty
            ;;
        v|V)
            echo "  Launching rough side-by-side in VLC..."
            vlc "$LEFT_FILE" &
            sleep 1
            vlc "$RIGHT_FILE" &
            echo "  Find a matching moment in both VLC windows."
            printf "  Enter offset when done (left_time - right_time in seconds): "
            read -r MANUAL_OFFSET </dev/tty
            ;;
        q|Q) echo "  Quitting."; exit 0 ;;
        *)   echo "  Unknown choice, please try again." ;;
    esac

done  # while PHASE1_DONE == false

# When the confirmed offset is exactly zero the files are already in sync and
# there is nothing for the blink comparator to tune.  Offer to write
# alignment.json directly and jump to Phase 3, mirroring --aligned behaviour.
if python3 -c "import sys; sys.exit(0 if float('${COARSE_OFFSET}') == 0 else 1)" 2>/dev/null; then
    echo ""
    echo "  Offset is 0 — files are already in sync."
    echo "  Skip the blink comparator and go straight to playback?"
    echo "    y — yes, write alignment.json and proceed to Phase 3"
    echo "    n — no, run the blink comparator anyway (Phase 2)"
    printf "  Choice [Y/n]: "
    read -r skip_phase2 </dev/tty
    if [[ ! "$skip_phase2" =~ ^[Nn]$ ]]; then
        echo ""
        echo "[Aligned] Writing zero-offset alignment.json..."
        python3 -c "
import json
d = {
    'offset':      0,
    'left_label':  '$LEFT_LABEL',
    'right_label': '$RIGHT_LABEL',
    'aligned_at':  '00:00:00.000',
    'note':        'offset confirmed as 0 in Phase 1; blink comparator skipped'
}
json.dump(d, open('$ALIGNMENT_JSON', 'w'), indent=2)
print('  Written:', '$ALIGNMENT_JSON')
"
        CONFIRMED_OFFSET="0"
        CONFIRMED_LEFT_LABEL="$LEFT_LABEL"
        CONFIRMED_RIGHT_LABEL="$RIGHT_LABEL"
        SKIP_TO_PLAYBACK=true
    fi
fi

# ==============================================================================
# PHASE 2 — Frame-accurate alignment via blink comparator
# ==============================================================================
if [[ "$SKIP_TO_PLAYBACK" == false ]]; then
echo ""
echo "============================================="
echo "  Phase 2: Frame-accurate alignment"
echo "============================================="

ALIGN_TC=$(format_tc "$DEFAULT_ALIGN_TIME")
echo ""
echo "  Default alignment position: ${DEFAULT_ALIGN_TIME}s (${ALIGN_TC})"
if [[ "$PEAK_LEFT" == "manual" ]]; then
    echo "  (Offset was entered manually; using ${DEFAULT_ALIGN_TIME}s as a default.)"
else
    echo "  This is the audio peak position in the left file."
fi
echo ""
echo "  Use this position? A visually distinctive moment (sharp edges,"
echo "  motion, text) gives a cleaner diff than a static wide shot."
echo ""
echo "    y       — use ${ALIGN_TC}"
echo "    TIME    — enter a different time (e.g. 5:30 or 1:02:15)"
echo "    q       — quit"
printf "  Choice [y/TIME/q]: "
read -r choice </dev/tty

case "$choice" in
    y|Y|"")
        ALIGN_TIME="$DEFAULT_ALIGN_TIME"
        ;;
    q|Q)
        echo "  Quitting."
        exit 0
        ;;
    *)
        # Treat as a time string
        ALIGN_TIME=$(parse_time "$choice") || {
            echo "[ERROR] Could not parse time: $choice"
            exit 1
        }
        ;;
esac

ALIGN_TC=$(format_tc "$ALIGN_TIME")
BLINK_DIR="${SESSION_DIR}/align_$(echo "$ALIGN_TC" | tr ':.' '_')"

echo ""
echo "  Alignment time   : ${ALIGN_TC}"
echo "  Coarse offset    : ${COARSE_OFFSET}s"
echo "  Blink output dir : $BLINK_DIR"
echo ""

# Pre-flight: verify that the alignment time is valid for both videos.
#
# blink_compare.sh requires:
#   L_START (= ALIGN_TIME)                 >= 0  — always true here
#   R_START (= ALIGN_TIME - COARSE_OFFSET) >= 0  — fails when right leads left
#                                                    by more than ALIGN_TIME
#
# When R_START would be negative the right video's alignment point falls
# before its beginning.  Rather than letting blink_compare.sh abort with an
# error deep in the run, catch it here where we can offer a retry with a
# later alignment time instead of quitting entirely.
R_START_CHECK=$(python3 -c "print(round(${ALIGN_TIME} - float('${COARSE_OFFSET}'), 6))")
while python3 -c "import sys; sys.exit(0 if float('${R_START_CHECK}') < 0 else 1)"; do
    MIN_ALIGN=$(python3 -c "print(round(float('${COARSE_OFFSET}'), 3))")
    echo "  [WARN] The right video's alignment point would be before its beginning."
    echo "         Alignment time : ${ALIGN_TC}  (${ALIGN_TIME}s)"
    echo "         Coarse offset  : ${COARSE_OFFSET}s  (right leads left)"
    echo "         Right start    : ${R_START_CHECK}s  — negative, invalid"
    echo ""
    echo "         Choose an alignment time >= ${MIN_ALIGN}s so the right video"
    echo "         has content at that position."
    echo ""
    echo "    TIME    — enter a later alignment time"
    echo "    q       — quit"
    printf "  Choice [TIME/q]: "
    read -r retry_choice </dev/tty
    case "$retry_choice" in
        q|Q) echo "  Quitting."; exit 0 ;;
        *)
            ALIGN_TIME=$(parse_time "$retry_choice") || {
                echo "[ERROR] Could not parse time: $retry_choice"
                exit 1
            }
            ALIGN_TC=$(format_tc "$ALIGN_TIME")
            BLINK_DIR="${SESSION_DIR}/align_$(echo "$ALIGN_TC" | tr ':.' '_')"
            R_START_CHECK=$(python3 -c "print(round(${ALIGN_TIME} - float('${COARSE_OFFSET}'), 6))")
            echo "  Updated alignment time: ${ALIGN_TC}  → right start: ${R_START_CHECK}s"
            echo ""
            ;;
    esac
done

# Warn if a stale alignment.json is sitting in ~/Downloads.  The browser
# always saves there; if one is already present it will be renamed to
# "alignment (1).json" (or similar) and check_alignment_json() will never
# find it.  Prompt the user to remove it before the browser session begins.
DOWNLOADS_JSON="${HOME}/Downloads/alignment.json"
if [[ -f "$DOWNLOADS_JSON" ]]; then
    echo "  [WARN] ~/Downloads/alignment.json already exists."
    echo "         When the browser saves a new file with the same name it may"
    echo "         be renamed (e.g. 'alignment (1).json') and won't be picked"
    echo "         up automatically."
    echo ""
    printf "  Delete ~/Downloads/alignment.json now? [Y/n] "
    read -r dl_answer </dev/tty
    if [[ ! "$dl_answer" =~ ^[Nn]$ ]]; then
        rm -f "$DOWNLOADS_JSON"
        echo "  Deleted."
    else
        echo "  [WARN] Keeping existing file — you may need to move the saved"
        echo "         alignment.json manually if the browser renames it."
    fi
    echo ""
fi

echo "  Running blink_compare.sh..."

"$BLINK_SCRIPT" \
    -t "$ALIGN_TC" \
    -o "$COARSE_OFFSET" \
    -r 1 \
    -n "$BLINK_FRAMES" \
    -d "$BLINK_DIR" \
    -l "$LEFT_LABEL" \
    -L "$RIGHT_LABEL" \
    -j "$SESSION_DIR" \
    "$LEFT_FILE" \
    "$RIGHT_FILE"

echo ""
echo "  Opening blink comparator in browser..."
xdg-open "${BLINK_DIR}/index.html" 2>/dev/null &

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  In the browser:                                    │"
echo "  │  1. Switch to DIFF mode (D key)                     │"
echo "  │  2. Nudge with < and > until the diff is darkest    │"
echo "  │  3. Click 'Save Offset' to write alignment.json     │"
echo "  │     (browser saves to ~/Downloads/alignment.json)   │"
echo "  │  4. Return here and press Enter to continue         │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
printf "  Press Enter when you have saved the offset in the browser..."
read -r </dev/tty

# Poll for alignment.json using check_alignment_json() defined above
POLL_COUNT=0
while ! check_alignment_json && (( POLL_COUNT < 30 )); do
    sleep 1
    POLL_COUNT=$(( POLL_COUNT + 1 ))
done

if [[ ! -f "$ALIGNMENT_JSON" ]]; then
    echo ""
    echo "  [WARN] alignment.json not found after waiting."
    echo "  Options:"
    echo "    r — retry (wait another 30 seconds)"
    echo "    m — enter confirmed offset manually"
    echo "    q — quit"
    printf "  Choice [r/m/q]: "
    read -r choice </dev/tty
    case "$choice" in
        r|R)
            POLL_COUNT=0
            while ! check_alignment_json && (( POLL_COUNT < 30 )); do
                sleep 1
                POLL_COUNT=$(( POLL_COUNT + 1 ))
            done
            ;;
        m|M)
            printf "  Enter confirmed offset (seconds): "
            read -r manual_off </dev/tty
            python3 -c "
import json
d = {'offset': float('$manual_off'), 'left_label': '$LEFT_LABEL',
     'right_label': '$RIGHT_LABEL', 'aligned_at': '$ALIGN_TC'}
json.dump(d, open('$ALIGNMENT_JSON', 'w'), indent=2)
"
            ;;
        q|Q) echo "  Quitting."; exit 0 ;;
    esac
fi

if [[ ! -f "$ALIGNMENT_JSON" ]]; then
    echo "[ERROR] alignment.json still not found. Cannot proceed to playback."
    exit 1
fi

CONFIRMED_OFFSET=$(python3 -c "
import json
d = json.load(open('$ALIGNMENT_JSON'))
print(d['offset'])
")

CONFIRMED_TC=$(format_tc "$(python3 -c "print(abs(float('$CONFIRMED_OFFSET')))")")
CONFIRMED_FRAMES=$(python3 -c "print(round(abs(float('$CONFIRMED_OFFSET')) * 29.97))")

echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │  Confirmed offset : ${CONFIRMED_OFFSET}s"
echo "  │  (~${CONFIRMED_FRAMES} frames at 29.97fps)"
echo "  │  Saved to: $ALIGNMENT_JSON"
echo "  └─────────────────────────────────────────┘"
echo ""
echo "  Proceed to synchronized playback?"
echo "    y       — yes, start from beginning"
echo "    TIME    — yes, start at TIME in left file (e.g. 45:00)"
echo "    q       — quit (alignment saved, resume later with --resume)"
printf "  Choice [y/TIME/q]: "
read -r choice </dev/tty

case "$choice" in
    y|Y)
        START_TIME="0"
        ;;
    q|Q)
        echo ""
        echo "  Alignment saved. Resume later with:"
        echo "  ./dual_compare.sh --resume $SESSION_DIR \\"
        echo "    --start TIME \\"
        echo "    \"$LEFT_FILE\" \"$RIGHT_FILE\""
        exit 0
        ;;
    *)
        START_TIME=$(parse_time "$choice") || {
            echo "[ERROR] Could not parse time: $choice"
            exit 1
        }
        ;;
esac

fi  # SKIP_TO_PLAYBACK == false (Phase 2)

fi  # SKIP_TO_PLAYBACK == false (outer: Phases 1+2)

# ==============================================================================
# PHASE 3 — Synchronized side-by-side playback
# ==============================================================================
echo ""
echo "============================================="
echo "  Phase 3: Synchronized playback"
echo "============================================="

# Read confirmed offset if coming via resume path
if [[ -z "${CONFIRMED_OFFSET:-}" ]]; then
    CONFIRMED_OFFSET=$(python3 -c "
import json
d = json.load(open('$ALIGNMENT_JSON'))
print(d['offset'])
")
fi

# ------------------------------------------------------------------------------
# Resume prompt — check for saved position in session directory.
# RESUME_JSON is set before the resume-mode block above; RESUMED_FROM_JSON
# tracks whether resume.json actually provided the start time (for the
# realign offer below).
# ------------------------------------------------------------------------------
RESUMED_FROM_JSON=false

if [[ -f "$RESUME_JSON" && "$START_TIME" == "0" ]]; then
    RESUME_TC=$(python3 -c "
import json
d = json.load(open('$RESUME_JSON'))
print(d.get('position_tc', ''))
" 2>/dev/null || true)
    if [[ -n "$RESUME_TC" ]]; then
        echo ""
        printf "  Resume from %s? [Y/n/hh:mm:ss] " "$RESUME_TC"
        read -r resume_answer </dev/tty
        if [[ "$resume_answer" =~ ^[Nn]$ ]]; then
            printf "  Start time (hh:mm:ss or mm:ss, blank=beginning): "
            read -r manual_time </dev/tty
            if [[ -n "$manual_time" ]]; then
                START_TIME="$manual_time"
            fi
        elif [[ -n "$resume_answer" && ! "$resume_answer" =~ ^[Yy]$ ]]; then
            # User typed a time directly instead of Y/N
            START_TIME="$resume_answer"
            RESUMED_FROM_JSON=true
        else
            START_TIME="$RESUME_TC"
            RESUMED_FROM_JSON=true
        fi
    fi
fi

# Offer blink realign if resume.json provided the start time (either via
# --resume or auto-detected), and the resume position is far enough from the
# last calibration point to warrant re-checking alignment.
if [[ ( -n "$RESUME_DIR" || "$RESUMED_FROM_JSON" == true ) \
      && -n "$BLINK_SCRIPT" && -x "$BLINK_SCRIPT" \
      && "$REALIGN_THRESHOLD" -gt 0 && "$START_TIME" != "0" \
      && -z "$ALIGNED" \
      && "${CONFIRMED_OFFSET:-1}" != "0" ]]; then
    ALIGNED_AT_SECS=$(python3 -c "
import json
d = json.load(open('$ALIGNMENT_JSON'))
print(d.get('aligned_at_secs', 0))
" 2>/dev/null || echo "0")
    RESUME_SECS=$(python3 -c "
import re
t = '${START_TIME}'
parts = [float(x) for x in re.split('[:,]', t)]
if len(parts)==3: print(parts[0]*3600+parts[1]*60+parts[2])
elif len(parts)==2: print(parts[0]*60+parts[1])
else: print(parts[0])
" 2>/dev/null || echo "0")
    DRIFT_MINS=$(python3 -c "
print(abs(float('$RESUME_SECS') - float('$ALIGNED_AT_SECS')) / 60)
" 2>/dev/null || echo "0")
    NEEDS_REALIGN=$(python3 -c "
print('yes' if float('$DRIFT_MINS') >= $REALIGN_THRESHOLD else 'no')
" 2>/dev/null || echo "no")
    if [[ "$NEEDS_REALIGN" == "yes" ]]; then
        echo ""
        printf "  Last alignment was %.1f minutes from resume point. Run blink comparator to realign? [Y/n] " "$DRIFT_MINS"
        read -r realign_answer </dev/tty
        if [[ ! "$realign_answer" =~ ^[Nn]$ ]]; then
            echo ""
            echo "  Running blink comparator at resume position..."
            BLINK_OUT_DIR="${SESSION_DIR}/align_$(echo "$START_TIME" | tr ':.' '_')"
            # Check for stale alignment.json in ~/Downloads/ before launching
            # blink comparator — browser will save as alignment(1).json if one
            # already exists there, which the script won't find.
            if [[ -f "${HOME}/Downloads/alignment.json" ]]; then
                echo ""
                echo "  [WARN] ~/Downloads/alignment.json already exists."
                echo "         If not deleted, the browser will save the new one as alignment(1).json"
                echo "         and the script won't find it."
                printf "  Delete the stale ~/Downloads/alignment.json? [Y/n] "
                read -r stale_answer </dev/tty
                if [[ ! "$stale_answer" =~ ^[Nn]$ ]]; then
                    rm "${HOME}/Downloads/alignment.json"
                    echo "  Deleted stale ~/Downloads/alignment.json"
                else
                    echo "  [WARN] Keeping stale file. After Save Offset, manually move"
                    echo "         ~/Downloads/alignment(1).json to $ALIGNMENT_JSON"
                fi
            fi
            "$BLINK_SCRIPT" \
                -t "$START_TIME" \
                -o "$CONFIRMED_OFFSET" \
                -r 1 -n 60 \
                -d "$BLINK_OUT_DIR" \
                -l "$LEFT_LABEL" -L "$RIGHT_LABEL" \
                -j "$SESSION_DIR" \
                "$LEFT_FILE" "$RIGHT_FILE"
            echo ""
            echo "  Opening blink comparator in browser..."
            xdg-open "${BLINK_OUT_DIR}/index.html" 2>/dev/null &
            echo ""
            echo "  Fine-tune alignment, click Save Offset, then press Enter..."
            read -r </dev/tty
            # Pick up updated alignment.json from ~/Downloads/ only if it is
            # newer than the existing session file — avoids picking up stale
            # files left from previous sessions.
            DOWNLOADS_JSON="${HOME}/Downloads/alignment.json"
            if [[ -f "$DOWNLOADS_JSON" ]]; then
                if [[ "$DOWNLOADS_JSON" -nt "$ALIGNMENT_JSON" ]]; then
                    mv "$DOWNLOADS_JSON" "$ALIGNMENT_JSON"
                    echo "  Moved updated alignment.json from ~/Downloads/"
                else
                    echo "  [WARN] ~/Downloads/alignment.json is older than session file — ignoring."
                    echo "         If you just saved it, click Save Offset again and press Enter."
                    read -r </dev/tty
                    if [[ -f "$DOWNLOADS_JSON" && "$DOWNLOADS_JSON" -nt "$ALIGNMENT_JSON" ]]; then
                        mv "$DOWNLOADS_JSON" "$ALIGNMENT_JSON"
                        echo "  Moved updated alignment.json from ~/Downloads/"
                    fi
                fi
            fi
            # Re-read the updated offset
            CONFIRMED_OFFSET=$(python3 -c "
import json
d = json.load(open('$ALIGNMENT_JSON'))
print(d['offset'])
")
            echo "  Updated offset: ${CONFIRMED_OFFSET}s"
        fi
    fi
fi

START_SECS=$(parse_time "$START_TIME")

# Always start the lagging source at START_SECS and seek the leading source
# forward by the offset so both show the same tape content. Neither video
# misses content from the beginning of the usable tape.
#
# CONFIRMED_OFFSET = left_peak_time - right_peak_time
#   Positive: left leads right → left starts at START_SECS + offset
#                                 right starts at START_SECS
#   Negative: right leads left → left starts at START_SECS
#                                 right starts at START_SECS + |offset|
ABS_OFFSET=$(python3 -c "print(abs(float('$CONFIRMED_OFFSET')))")

if python3 -c "import sys; sys.exit(0 if float('$CONFIRMED_OFFSET') >= 0 else 1)"; then
    # Left leads right
    LEFT_START=$(python3 -c "print(round(float('$START_SECS') + float('$ABS_OFFSET'), 3))")
    RIGHT_START="$START_SECS"
    LEAD_SIDE="left"
else
    # Right leads left
    LEFT_START="$START_SECS"
    RIGHT_START=$(python3 -c "print(round(float('$START_SECS') + float('$ABS_OFFSET'), 3))")
    LEAD_SIDE="right"
fi

LEFT_START_TC=$(format_tc "$LEFT_START")
RIGHT_START_TC=$(format_tc "$RIGHT_START")

echo ""
echo "  Left  [$LEFT_LABEL]  starts at : ${LEFT_START_TC}"
echo "  Right [$RIGHT_LABEL] starts at : ${RIGHT_START_TC}"
if python3 -c "import sys; sys.exit(0 if float('$CONFIRMED_OFFSET') != 0 else 1)" 2>/dev/null; then
    OFFSET_DESC="${LEAD_SIDE} leads — seeked forward to align"
else
    OFFSET_DESC="no offset — both start at same position"
fi
echo "  Offset: ${CONFIRMED_OFFSET}s  (${OFFSET_DESC})"
echo ""
echo "  Controls (click either window for keyboard focus):"
echo ""
echo "  Playback:"
echo "    Space       Pause / resume both"
echo "    [ / ]       Seek back / forward 5 seconds in both"
echo "    , / .       Step one frame back / forward in both"
echo "    z / x       Nudge right (DVD) ±1 frame — fine alignment"
echo "    Z / X       Seek right (DVD) ±2 seconds — coarse alignment (crosses GOP)"
echo "                (none of these modify alignment.json)"
echo ""
echo "  Audio:"
echo "    a           Mute / unmute this window only"
echo "    m           Mute both simultaneously"
echo "    M           Unmute both simultaneously"
echo "    Left video  → left ear (full mono mix of both channels)"
echo "    Right video → right ear (full mono mix of both channels)"
echo "    Tip: to swap left/right, reverse the order of input files"
echo ""
echo "  Navigation:"
if [[ -n "$WAYPOINTS_FILE" ]]; then
echo "    n / p       Next / previous waypoint  ($N_WAYPOINTS loaded)"
fi
echo "    q           Quit both windows"
echo "    Ctrl+C      (in terminal) Kill both windows"
echo ""
echo "  Position saved to ${RESUME_JSON} every 60s — resume prompt on next launch"
echo ""

# Get screen dimensions and top-left origin for window placement.
# If --screen NAME was given, use that xrandr output; otherwise use the primary.
# xrandr output lines look like:
#   DP-2 connected 1920x1080+3840+0 (normal left inverted right x axis y axis)
# We capture WxH and the +X+Y origin so both mpv windows land on the right monitor.
read -r SCREEN_W SCREEN_H SCREEN_X SCREEN_Y < <(python3 - "$DISPLAY_SCREEN" << 'PYEOF'
import subprocess, re, sys

target = sys.argv[1] if len(sys.argv) > 1 else ''  # empty -> use primary

try:
    out = subprocess.check_output(['xrandr'], text=True)
except Exception:
    print('3840 2160 0 0')
    sys.exit()

primary_result = None
target_result  = None

for line in out.split('\n'):
    if ' connected' not in line:
        continue
    # Match geometry: WxH+X+Y (present when a mode is active)
    m = re.search(r'(\d+)x(\d+)\+(\d+)\+(\d+)', line)
    if not m:
        continue
    w, h, x, y = m.group(1), m.group(2), m.group(3), m.group(4)
    name = line.split()[0]
    if target and name == target:
        target_result = (w, h, x, y)
        break                          # exact match — stop searching
    if 'primary' in line and primary_result is None:
        primary_result = (w, h, x, y)
    if primary_result is None:         # first connected output as fallback
        primary_result = (w, h, x, y)

if target and target_result is None:
    print(f'Warning: --screen {target} not found in xrandr output; using primary',
          file=sys.stderr)

result = target_result or primary_result or ('3840', '2160', '0', '0')
print(*result)
PYEOF
)

# Each window gets half the screen width, full height minus taskbar
WIN_W=$(python3 -c "print(int($SCREEN_W) // 2)")
WIN_H=$(python3 -c "print(int($SCREEN_H) - 60)")  # leave room for taskbar
# Absolute X positions on the target screen
LEFT_X="$SCREEN_X"
RIGHT_X=$(python3 -c "print(int('$SCREEN_X') + int('$WIN_W'))")

echo "  Screen: ${SCREEN_W}x${SCREEN_H} at +${SCREEN_X}+${SCREEN_Y}${DISPLAY_SCREEN:+ ($DISPLAY_SCREEN)}"
echo "  Each window: ${WIN_W}x${WIN_H}"
echo ""

# ------------------------------------------------------------------------------
# Lua IPC script — written to a temp file, loaded by both mpv instances.
# Both instances connect to each other's IPC socket and mirror all
# transport commands. The swap toggle exchanges window titles and the
# IPC roles so the user always sees correct labels.
# ------------------------------------------------------------------------------
LUA_SCRIPT=$(mktemp /tmp/dual_sync_XXXXXX.lua)
LEFT_SOCKET=$(mktemp -u /tmp/mpv_left_XXXXXX)
RIGHT_SOCKET=$(mktemp -u /tmp/mpv_right_XXXXXX)

# Write the label files so the Lua script can read them
LEFT_LABEL_FILE=$(mktemp /tmp/mpv_llabel_XXXXXX.txt)
RIGHT_LABEL_FILE=$(mktemp /tmp/mpv_rlabel_XXXXXX.txt)
echo "$LEFT_LABEL"  > "$LEFT_LABEL_FILE"
echo "$RIGHT_LABEL" > "$RIGHT_LABEL_FILE"

cat > "$LUA_SCRIPT" << LUAEOF
-- dual_sync.lua
-- Loaded by both mpv instances. Each instance reads SIDE from an env var
-- to know whether it is "left" or "right", then connects to the peer's
-- IPC socket and mirrors transport commands.
--
-- Audio: left instance pans audio to left ear (mono mix), right to right ear.
-- Waypoints: n/p keys seek both windows to the next/previous waypoint.

local side        = os.getenv("DUAL_SIDE")        or "left"
local peer_sock   = os.getenv("DUAL_PEER_SOCK")   or ""
local left_label  = os.getenv("DUAL_LEFT_LABEL")  or "LEFT"
local right_label = os.getenv("DUAL_RIGHT_LABEL") or "RIGHT"
local wp_json     = os.getenv("DUAL_WAYPOINTS")   or "[]"
local offset_secs = tonumber(os.getenv("DUAL_OFFSET") or "0")

-- Parse waypoints JSON array [{secs=N, tc=S, label=S}, ...]
-- Simple parser — expects well-formed output from python3 json.dumps
local waypoints = {}
for entry in wp_json:gmatch('{[^}]+}') do
    local secs  = tonumber(entry:match('"secs":%s*([%d%.]+)'))
    local tc    = entry:match('"tc":%s*"([^"]+)"')
    local label = entry:match('"label":%s*"([^"]+)"')
    if secs then
        table.insert(waypoints, {secs=secs, tc=tc or '', label=label or ''})
    end
end
local wp_index = 0   -- 0 = not at any waypoint yet

-- Track mute state
local my_muted = false

local function my_label()
    return (side == "left") and left_label or right_label
end

local function peer_label()
    return (side == "left") and right_label or left_label
end

-- Update window title with mute and waypoint state
local function update_title()
    local mute_hint = my_muted and "  [MUTED]" or ""
    local wp_hint   = (#waypoints > 0) and ("  wp:" .. wp_index .. "/" .. #waypoints) or ""
    mp.set_property("title",
        my_label() .. mute_hint .. wp_hint ..
        "  [Space=pause  ,/.=frame  [/]=seek5s  z/x=nudge  Z/X=coarse  a=mute  n/p=wp  q=quit]")
end

-- Send a JSON IPC command to the peer socket via socat
local function send_peer(cmd_json)
    if peer_sock == "" then return end
    local handle = io.popen(string.format(
        "echo '%s' | socat - UNIX-CONNECT:%s 2>/dev/null",
        cmd_json, peer_sock
    ))
    if handle then handle:close() end
end

-- Seek both windows to a position expressed in left-file time.
-- Left window seeks to secs directly.
-- Right window seeks to secs + offset_secs (offset already applied at launch
-- via --start, but absolute seeks must re-apply it explicitly).
local function seek_absolute_both(secs)
    if side == "left" then
        mp.commandv("seek", tostring(secs), "absolute", "exact")
        local right_secs = secs + offset_secs
        send_peer(string.format('{"command":["seek",%.3f,"absolute","exact"]}', right_secs))
    else
        -- Right instance: seek to secs (already offset-adjusted by caller)
        mp.commandv("seek", tostring(secs), "absolute", "exact")
    end
end

-- Seek both by delta seconds
local function seek_both(delta)
    mp.commandv("seek", tostring(delta), "relative", "exact")
    send_peer(string.format('{"command":["seek",%d,"relative","exact"]}', delta))
end

-- Frame step both
local function frame_step_both(dir)
    if dir > 0 then
        mp.commandv("frame-step")
        send_peer('{"command":["frame-step"]}')
    else
        mp.commandv("frame-back-step")
        send_peer('{"command":["frame-back-step"]}')
    end
end

-- Pause/resume both
local function pause_both()
    local paused = mp.get_property_bool("pause")
    mp.set_property_bool("pause", not paused)
    local cmd = string.format('{"command":["set_property","pause",%s]}',
        (not paused) and "true" or "false")
    send_peer(cmd)
end

-- Quit both
local function quit_both()
    send_peer('{"command":["quit"]}')
    mp.commandv("quit")
end

-- Toggle mute on this window only
local function toggle_my_mute()
    my_muted = not my_muted
    mp.set_property_bool("mute", my_muted)
    update_title()
    mp.osd_message(my_label() .. (my_muted and " — MUTED" or " — unmuted"), 2)
end

-- Mute both
local function mute_both()
    my_muted = true
    mp.set_property_bool("mute", true)
    update_title()
    send_peer('{"command":["script-message","dual-set-mute","true"]}')
    mp.osd_message("Both muted", 2)
end

-- Unmute both
local function unmute_both()
    my_muted = false
    mp.set_property_bool("mute", false)
    update_title()
    send_peer('{"command":["script-message","dual-set-mute","false"]}')
    mp.osd_message("Both unmuted", 2)
end

-- Waypoint navigation — only the left instance drives seeks;
-- it sends the absolute seek to the peer as well.
-- The right instance ignores n/p key presses to avoid double-seeking.
local function goto_waypoint(idx)
    if #waypoints == 0 then
        mp.osd_message("No waypoints loaded", 2)
        return
    end
    idx = math.max(1, math.min(#waypoints, idx))
    wp_index = idx
    local wp = waypoints[idx]
    -- Pause both before seeking for clean visual inspection
    mp.set_property_bool("pause", true)
    send_peer('{"command":["set_property","pause",true]}')
    seek_absolute_both(wp.secs)
    update_title()
    mp.osd_message(string.format("Waypoint %d/%d — %s\n%s",
        idx, #waypoints, wp.tc, wp.label), 4)
end

local function next_waypoint()
    if side == "left" then
        goto_waypoint(wp_index + 1)
    else
        -- Forward to left instance which owns waypoint state
        send_peer('{"command":["script-message","dual-wp-next"]}')
    end
end

local function prev_waypoint()
    if side == "left" then
        goto_waypoint(wp_index - 1)
    else
        send_peer('{"command":["script-message","dual-wp-prev"]}')
    end
end

local alignment_json = ""  -- not used: blink comparator offset is authoritative
local frame_period   = 1.0 / 29.97  -- seconds per frame

-- Nudge right video only by one frame, adjusting the running offset.
-- Only the left instance drives this to avoid double-nudging.
-- Pauses both, steps the right video, resumes both.
-- Nudge right video only by one frame to adjust playback sync.
-- Does NOT modify alignment.json — the blink comparator offset is authoritative.
-- Only the left instance drives this to avoid double-nudging.
-- Nudge right (MPEG-2) video only by one frame to compensate for GOP
-- boundary imprecision after seeking. DV is frame-accurate and stays fixed.
-- Does NOT modify alignment.json — the blink comparator offset is authoritative.
local function nudge_right(dir)
    if side == "left" then
        mp.set_property_bool("pause", true)
        send_peer('{"command":["set_property","pause",true]}')
        if dir > 0 then
            send_peer('{"command":["frame-step"]}')
        else
            send_peer('{"command":["frame-back-step"]}')
        end
        -- Re-pause peer since frame-step unpauses momentarily
        mp.add_timeout(0.1, function()
            send_peer('{"command":["set_property","pause",true]}')
        end)
        offset_secs = offset_secs + (dir * frame_period)
        update_title()
        mp.osd_message(string.format(
            "DVD nudge %s 1 frame (z/x=fine  Z/X=coarse 2s)",
            dir > 0 and "▶" or "◀"), 2)
    else
        send_peer(string.format(
            '{"command":["script-message","dual-nudge-right","%d"]}', dir))
    end
end

-- Coarse seek of right (MPEG-2) window only by 2 seconds.
-- Crosses GOP boundaries where frame-by-frame nudge gets stuck.
local function coarse_right(dir)
    if side == "left" then
        mp.set_property_bool("pause", true)
        send_peer('{"command":["set_property","pause",true]}')
        send_peer(string.format(
            '{"command":["seek",%d,"relative","exact"]}', dir * 2))
        mp.add_timeout(0.2, function()
            send_peer('{"command":["set_property","pause",true]}')
        end)
        offset_secs = offset_secs + (dir * 2)
        update_title()
        mp.osd_message(string.format(
            "DVD coarse %s 2s (z/x=fine  Z/X=coarse 2s)",
            dir > 0 and "▶▶" or "◀◀"), 2)
    else
        send_peer(string.format(
            '{"command":["script-message","dual-coarse-right","%d"]}', dir))
    end
end

-- Key bindings
mp.add_key_binding("space", "dual-pause",        pause_both)
mp.add_key_binding("[",     "dual-seek-back",    function() seek_both(-5)  end)
mp.add_key_binding("]",     "dual-seek-fwd",     function() seek_both(5)   end)
mp.add_key_binding(",",     "dual-frame-back",   function() frame_step_both(-1) end)
mp.add_key_binding(".",     "dual-frame-fwd",    function() frame_step_both(1)  end)
mp.add_key_binding("q",     "dual-quit",         quit_both)
mp.add_key_binding("a",     "dual-mute-this",    toggle_my_mute)
mp.add_key_binding("m",     "dual-mute-both",    mute_both)
mp.add_key_binding("M",     "dual-unmute-both",  unmute_both)
mp.add_key_binding("n",     "dual-wp-next",      next_waypoint)
mp.add_key_binding("p",     "dual-wp-prev",      prev_waypoint)
mp.add_forced_key_binding("z", "dual-nudge-back",  function() nudge_right(-1) end)
mp.add_forced_key_binding("x", "dual-nudge-fwd",   function() nudge_right(1)  end)
mp.add_forced_key_binding("Z", "dual-coarse-back", function() coarse_right(-1) end)
mp.add_forced_key_binding("X", "dual-coarse-fwd",  function() coarse_right(1)  end)

-- Peer messages
mp.register_script_message("dual-set-mute", function(val)
    my_muted = (val == "true")
    mp.set_property_bool("mute", my_muted)
    update_title()
end)

-- Waypoint forwarding: right instance sends these, left instance acts on them
mp.register_script_message("dual-wp-next", function()
    if side == "left" then goto_waypoint(wp_index + 1) end
end)

mp.register_script_message("dual-wp-prev", function()
    if side == "left" then goto_waypoint(wp_index - 1) end
end)

-- Nudge forwarding: right instance forwards to left instance
mp.register_script_message("dual-nudge-right", function(dir)
    if side == "left" then nudge_right(tonumber(dir)) end
end)

mp.register_script_message("dual-coarse-right", function(dir)
    if side == "left" then coarse_right(tonumber(dir)) end
end)

-- Init
mp.register_event("file-loaded", function()
    update_title()
    local wp_hint = #waypoints > 0
        and string.format(" — %d waypoints (n/p to navigate)", #waypoints)
        or ""
    mp.osd_message(my_label() .. " — paired with " .. peer_label() .. wp_hint, 3)

    -- Position tracking: left instance writes resume.json every 60 seconds
    -- and again on quit, so short sessions are never lost.
    -- Position is stored in left-file time (lagging source starts at 0,
    -- leading source is offset-adjusted at launch, so left-file time is the
    -- natural seek reference for --start on next resume).
    if side == "left" then
        local resume_file = os.getenv("DUAL_RESUME_FILE") or ""
        if resume_file ~= "" then
            -- last_pos_secs: continuously updated from the time-pos observer so
            -- it is available even after mpv has unloaded the file (at which
            -- point mp.get_property_number("time-pos") returns nil).
            local last_pos_secs = nil

            mp.observe_property("time-pos", "number", function(_, pos)
                if pos and pos > 0 then last_pos_secs = pos end
            end)

            -- write_resume: write resume.json from last_pos_secs.
            -- rollback_secs: subtract this many seconds so the next session
            -- gets a run-up to re-establish alignment (0 = save exact position).
            local function write_resume(rollback_secs)
                local pos = last_pos_secs
                if pos and pos > 0 then
                    -- Convert left-file position to lagging-source time.
                    local lag_pos
                    if offset_secs >= 0 then
                        lag_pos = math.max(0, pos - offset_secs)
                    else
                        lag_pos = pos
                    end
                    lag_pos = math.max(0, lag_pos - (rollback_secs or 0))
                    local h = math.floor(lag_pos / 3600)
                    local m = math.floor((lag_pos % 3600) / 60)
                    local s = lag_pos % 60
                    local tc = string.format("%02d:%02d:%06.3f", h, m, s)
                    local f = io.open(resume_file, "w")
                    if f then
                        f:write(string.format(
                            '{"position_secs":%.3f,"position_tc":"%s"}\n',
                            lag_pos, tc))
                        f:close()
                    end
                end
            end
            -- Periodic save: 60s rollback gives a run-up on next resume.
            mp.add_periodic_timer(60, function() write_resume(60) end)
            -- On quit: save exact position — no rollback needed since we know
            -- precisely where playback stopped.  Uses last_pos_secs rather than
            -- querying time-pos, which is nil once mpv has unloaded the file.
            mp.register_event("shutdown", function() write_resume(0) end)
        end
    end
end)

LUAEOF

# Clean up temp files on exit
LEFT_PID=""
RIGHT_PID=""

echo "  Launching synchronized players..."
echo "  (socat is used for IPC — install with: sudo apt install socat)"
echo ""

# Check socat is available (needed for Lua IPC)
if ! command -v socat >/dev/null 2>&1; then
    echo "[WARN] socat not found — swap and synchronized controls will not work."
    echo "       Install with: sudo apt install socat"
    echo "       Launching without synchronization..."
    mpv \
        ${SOFTWARE_RENDER:+--vo=x11} \
        --title="${LEFT_LABEL}" \
        --geometry="${WIN_W}x${WIN_H}+${LEFT_X}+${SCREEN_Y}" \
        --start="$LEFT_START" \
        "$LEFT_FILE" &
    sleep 0.5
    mpv \
        ${SOFTWARE_RENDER:+--vo=x11} \
        --title="${RIGHT_LABEL}" \
        --geometry="${WIN_W}x${WIN_H}+${RIGHT_X}+${SCREEN_Y}" \
        --start="$RIGHT_START" \
        "$RIGHT_FILE" &
    echo "  Both players launched (unsynchronized)."
    wait
    exit 0
fi

# Launch left mpv — pan audio to left channel only
# mpv 0.34.1 requires lavfi wrapper for pan filter
DUAL_SIDE=left \
DUAL_PEER_SOCK="$RIGHT_SOCKET" \
DUAL_LEFT_LABEL="$LEFT_LABEL" \
DUAL_RIGHT_LABEL="$RIGHT_LABEL" \
DUAL_WAYPOINTS="$WAYPOINTS_DATA" \
DUAL_OFFSET="$CONFIRMED_OFFSET" \
DUAL_RESUME_FILE="$RESUME_JSON" \
mpv \
    ${SOFTWARE_RENDER:+--vo=x11} \
    --input-ipc-server="$LEFT_SOCKET" \
    --script="$LUA_SCRIPT" \
    --title="${LEFT_LABEL}" \
    --geometry="${WIN_W}x${WIN_H}+${LEFT_X}+${SCREEN_Y}" \
    --start="$LEFT_START" \
    --hr-seek=yes \
    --af="lavfi=[pan=stereo|FL=0.5*FL+0.5*FR|FR=0]" \
    --pause \
    "$LEFT_FILE" &
LEFT_PID=$!

sleep 1

# Launch right mpv — pan audio to right channel only
DUAL_SIDE=right \
DUAL_PEER_SOCK="$LEFT_SOCKET" \
DUAL_LEFT_LABEL="$LEFT_LABEL" \
DUAL_RIGHT_LABEL="$RIGHT_LABEL" \
DUAL_WAYPOINTS="$WAYPOINTS_DATA" \
DUAL_OFFSET="$CONFIRMED_OFFSET" \
DUAL_RESUME_FILE="$RESUME_JSON" \
mpv \
    ${SOFTWARE_RENDER:+--vo=x11} \
    --input-ipc-server="$RIGHT_SOCKET" \
    --script="$LUA_SCRIPT" \
    --title="${RIGHT_LABEL}" \
    --geometry="${WIN_W}x${WIN_H}+${RIGHT_X}+${SCREEN_Y}" \
    --start="$RIGHT_START" \
    --hr-seek=yes \
    --af="lavfi=[pan=stereo|FL=0|FR=0.5*FL+0.5*FR]" \
    --pause \
    "$RIGHT_FILE" &
RIGHT_PID=$!

echo "  Both players launched and paused at start position."
echo "  Press Space in either window to begin playback."
echo ""
echo "  To resume this session later:"
echo "  ./dual_compare.sh --resume $SESSION_DIR \\"
echo "    --start TIME \\"
echo "    \"$LEFT_FILE\" \"$RIGHT_FILE\""
echo "  (TIME is in the ${LEAD_SIDE}-leads offset: use the lagging source's timecode)"
echo ""

# Wait for both to exit
wait $LEFT_PID  2>/dev/null || true
wait $RIGHT_PID 2>/dev/null || true

echo ""
echo "  Session ended. Alignment is at:"
echo "  $ALIGNMENT_JSON"
