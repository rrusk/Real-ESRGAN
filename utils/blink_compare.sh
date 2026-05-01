#!/bin/bash
# ==============================================================================
# Script Name: blink_compare.sh
# Description: Extracts aligned frames from two video files and generates
#              an interactive HTML blink comparator for quality comparison.
#
# The HTML viewer lets you:
#   - Step through frame pairs with arrow keys or buttons
#   - Toggle blink mode (auto-alternates between old/new at adjustable speed)
#   - Manually flip between old and new with spacebar
#   - See both frames side-by-side or overlaid
#   - Zoom into regions of interest
#   - Save the nudge-adjusted offset as alignment.json (when -j is given)
#
# Usage:
#   ./blink_compare.sh [OPTIONS] <file_left> <file_right>
#
# Options:
#   -t TIME      Time in the LEFT video (mm:ss, hh:mm:ss, or raw seconds) [required]
#   -o SECONDS   Offset: left is this many seconds ahead of right [required]
#   -n FRAMES    Number of frame pairs to extract (default: 30)
#   -r EVERY     Extract every Nth frame (default: 15, ~0.5s apart at 29.97fps)
#   -d DIR       Output directory (default: blink_YYYYMMDD_HHMM)
#   -l LABEL     Label for left file  (default: filename stem)
#   -L LABEL     Label for right file (default: filename stem)
#   -j DIR       If given, inject a "Save Offset" button into the HTML that
#                downloads alignment.json into DIR when clicked.  The JSON
#                records the nudge-adjusted offset, file paths, and labels so
#                blink_survey.sh (or any other consumer) can read it directly.
#
# Right start time = LEFT_TIME - OFFSET.  Increase -o to shift the right video
# later; decrease to shift earlier.  One frame adjustment at 29.97fps = 0.033s.
#
# Examples:
#   Extract 30 frame pairs at 24:52 in left video, left 7.958s ahead of right:
#     ./blink_compare.sh -t 24:52 -o 7.958 -n 30 old.mkv new.mkv
#
#   Extract every 30th frame with custom labels:
#     ./blink_compare.sh -t 1:02:15 -o 7.958 -n 20 -r 30 -l "S-Video" -L "DV-FireWire" old.mkv new.mkv
#
#   Align mode (called by blink_survey.sh): inject Save Offset button:
#     ./blink_compare.sh -t 5:00 -o 7.958 -r 1 -n 60 -j /path/to/survey old.mkv new.mkv
# ==============================================================================
set -euo pipefail

TIME_STR=""
OFFSET=""
NUM_FRAMES=30
EVERY_N=15
OUTPUT_DIR=""
LEFT_LABEL_OVERRIDE=""
RIGHT_LABEL_OVERRIDE=""
SAVE_OFFSET_DIR=""      # -j: directory where alignment.json should be downloaded

usage() {
    echo ""
    echo "Usage: $0 [OPTIONS] <file_left> <file_right>"
    echo ""
    echo "Options:"
    echo "  -t TIME      Time in LEFT video, mm:ss / hh:mm:ss / raw seconds [required]"
    echo "  -o SECONDS   Offset: LEFT is this many seconds ahead of RIGHT [required]"
    echo "  -n FRAMES    Number of frame pairs to extract (default: 30)"
    echo "  -r EVERY     Extract every Nth frame (default: 15)"
    echo "  -d DIR       Output directory (default: blink_YYYYMMDD_HHMM)"
    echo "  -l LABEL     Label for left file"
    echo "  -L LABEL     Label for right file"
    echo "  -j DIR       Inject Save Offset button; alignment.json downloaded into DIR"
    echo ""
    echo "  Right start = LEFT_TIME - OFFSET"
    echo "  Increase -o to shift right later; decrease to shift right earlier."
    echo ""
    exit 1
}

if [ "$#" -lt 1 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
fi

while getopts "t:o:n:r:d:l:L:j:" opt; do
    case $opt in
        t) TIME_STR="$OPTARG" ;;
        o) OFFSET="$OPTARG" ;;
        n) NUM_FRAMES="$OPTARG" ;;
        r) EVERY_N="$OPTARG" ;;
        d) OUTPUT_DIR="$OPTARG" ;;
        l) LEFT_LABEL_OVERRIDE="$OPTARG" ;;
        L) RIGHT_LABEL_OVERRIDE="$OPTARG" ;;
        j) SAVE_OFFSET_DIR="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -lt 2 ]; then
    echo "[ERROR] Two input files are required."
    usage
fi

if [ -z "$TIME_STR" ]; then
    echo "[ERROR] -t TIME is required."
    usage
fi

if [ -z "$OFFSET" ]; then
    echo "[ERROR] -o OFFSET is required."
    usage
fi

# Parse time string to seconds (accepts mm:ss, hh:mm:ss, or raw seconds)
parse_time() {
    local T="$1"
    local PARTS
    IFS=':' read -ra PARTS <<< "$T"
    case ${#PARTS[@]} in
        1) python3 -c "print(float('${PARTS[0]}'))" ;;
        2) python3 -c "print(int('${PARTS[0]}') * 60 + float('${PARTS[1]}'))" ;;
        3) python3 -c "print(int('${PARTS[0]}') * 3600 + int('${PARTS[1]}') * 60 + float('${PARTS[2]}'))" ;;
        *)
            echo "[ERROR] Invalid time format: $T (use mm:ss, hh:mm:ss, or raw seconds)"
            exit 1
            ;;
    esac
}

L_START=$(parse_time "$TIME_STR")
R_START=$(python3 -c "print(round(${L_START} - ${OFFSET}, 6))")

# Guard: neither alignment start time may be negative.
#
#   L_START = -t argument (left-file time of the alignment point)
#   R_START = L_START - OFFSET  (right-file time of the same moment)
#
# A negative L_START means -t was given a negative value.
# A negative R_START means OFFSET > L_START, i.e. the right video leads
# left by more than the alignment point is into the left file — the right
# video's alignment point would be before its own frame 0.
#
# Both cases are caught here before any file I/O is attempted.  The silent
# max(0) clamp in L/R_START_EXTRACT further below would otherwise mask the
# problem and produce frames from the wrong position.
#
# The most common cause of a negative R_START is reversed video order; the
# fix is to swap the two input files and negate the offset.
if python3 -c "import sys; sys.exit(0 if float('${L_START}') < 0 else 1)"; then
    echo ""
    echo "[ERROR] Left alignment time is negative: ${L_START}s  (-t ${TIME_STR})"
    echo "        -t must be a non-negative time within the left video."
    echo ""
    exit 1
fi

if python3 -c "import sys; sys.exit(0 if float('${R_START}') < 0 else 1)"; then
    echo ""
    echo "[ERROR] The right video's alignment point is before its beginning."
    echo "        Left alignment time : ${L_START}s  (-t ${TIME_STR})"
    echo "        Offset              : ${OFFSET}s   (-o)"
    echo "        Right start time    : ${R_START}s  (= left_time - offset)"
    echo ""
    echo "        The right video would need to start at ${R_START}s, which is"
    echo "        before frame 0.  Try reversing the video order and negating"
    echo "        the offset, e.g.:"
    echo "          $0 -t ${TIME_STR} -o $(python3 -c "print(-float('${OFFSET}'))") ... right_file left_file"
    echo ""
    exit 1
fi

LEFT_INPUT="$1"
RIGHT_INPUT="$2"

if [ ! -f "$LEFT_INPUT" ]; then echo "[ERROR] File not found: $LEFT_INPUT"; exit 1; fi
if [ ! -f "$RIGHT_INPUT" ]; then echo "[ERROR] File not found: $RIGHT_INPUT"; exit 1; fi

# Resolve absolute paths so alignment.json contains unambiguous references
LEFT_ABS=$(cd "$(dirname "$LEFT_INPUT")" && pwd)/$(basename "$LEFT_INPUT")
RIGHT_ABS=$(cd "$(dirname "$RIGHT_INPUT")" && pwd)/$(basename "$RIGHT_INPUT")

# Labels
get_label() { basename "$1" | sed 's/\.[^.]*$//'; }
LEFT_LABEL="${LEFT_LABEL_OVERRIDE:-$(get_label "$LEFT_INPUT")}"
RIGHT_LABEL="${RIGHT_LABEL_OVERRIDE:-$(get_label "$RIGHT_INPUT")}"

# Output directory
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="blink_$(date +%Y%m%d_%H%M)"
fi
mkdir -p "$OUTPUT_DIR/frames_left"
mkdir -p "$OUTPUT_DIR/frames_right"

# ==============================================================================
# Probe frame rate and dimensions from the actual input files.
# Works with any container ffprobe supports: mp4, mkv, avi, mov, etc.
# Both files must share the same frame rate; we warn clearly if they don't.
# ==============================================================================
probe_video() {
    local FILE="$1"
    local SIDE="$2"

    # Query each field separately to avoid ffprobe output ordering ambiguity
    local FPS_RAW WIDTH HEIGHT
    FPS_RAW=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$FILE" 2>/dev/null)
    WIDTH=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width \
        -of default=noprint_wrappers=1:nokey=1 "$FILE" 2>/dev/null)
    HEIGHT=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=height \
        -of default=noprint_wrappers=1:nokey=1 "$FILE" 2>/dev/null)

    if [ -z "$FPS_RAW" ] || [ -z "$WIDTH" ] || [ -z "$HEIGHT" ]; then
        echo "[ERROR] ffprobe could not read video stream from ${SIDE} file: $FILE" >&2
        echo "        fps='${FPS_RAW}' width='${WIDTH}' height='${HEIGHT}'" >&2
        exit 1
    fi

    echo "${FPS_RAW} ${WIDTH} ${HEIGHT}"
}

echo ""
echo "--- Probing input files ---"

LEFT_INFO=$(probe_video  "$LEFT_INPUT"  "left")
RIGHT_INFO=$(probe_video "$RIGHT_INPUT" "right")

LEFT_FPS_RAW=$(echo  "$LEFT_INFO"  | awk '{print $1}')
LEFT_WIDTH=$(echo    "$LEFT_INFO"  | awk '{print $2}')
LEFT_HEIGHT=$(echo   "$LEFT_INFO"  | awk '{print $3}')

RIGHT_FPS_RAW=$(echo "$RIGHT_INFO" | awk '{print $1}')
RIGHT_WIDTH=$(echo   "$RIGHT_INFO" | awk '{print $2}')
RIGHT_HEIGHT=$(echo  "$RIGHT_INFO" | awk '{print $3}')

# Convert fps fraction to float for duration math
fps_to_float() {
    python3 -c "n,d='${1}'.split('/'); print(f'{int(n)/int(d):.6f}')"
}

LEFT_FPS=$(fps_to_float  "$LEFT_FPS_RAW")
RIGHT_FPS=$(fps_to_float "$RIGHT_FPS_RAW")

echo "  Left:  ${LEFT_WIDTH}x${LEFT_HEIGHT} @ ${LEFT_FPS_RAW} (${LEFT_FPS} fps)"
echo "  Right: ${RIGHT_WIDTH}x${RIGHT_HEIGHT} @ ${RIGHT_FPS_RAW} (${RIGHT_FPS} fps)"

# Warn if frame rates differ (don't abort — offsets may still be meaningful)
FPS_MATCH=$(python3 -c "print('yes' if abs(${LEFT_FPS} - ${RIGHT_FPS}) < 0.01 else 'no')")
if [ "$FPS_MATCH" != "yes" ]; then
    echo ""
    echo "[WARNING] Frame rate mismatch: left=${LEFT_FPS_RAW}, right=${RIGHT_FPS_RAW}"
    echo "          The every-Nth-frame extraction will sample at different real-time"
    echo "          intervals on each side. Results may be misaligned over time."
    echo "          Using left fps (${LEFT_FPS}) for duration calculation."
fi

# Use left fps for duration calculation (the side whose offset -s is specified)
FPS="$LEFT_FPS"

# Frame period in seconds (used in JS for nudge display)
FRAME_PERIOD=$(python3 -c "print(f'{1.0 / ${FPS}:.6f}')")

# Use left file's dimensions as the canonical display size.
# If the files differ in size, ffmpeg will scale both to match during extraction.
VID_WIDTH="$LEFT_WIDTH"
VID_HEIGHT="$LEFT_HEIGHT"
SBS_WIDTH=$(python3 -c "print(${VID_WIDTH} * 2)")

# ==============================================================================
# Frame Extraction
# ==============================================================================
# We extract NUM_FRAMES from each side, but start HALF_FRAMES earlier than the
# requested alignment point so that the point lands in the centre of the strip.
# This gives equal nudge room in both directions before hitting the limit.
HALF_FRAMES=$(python3 -c "print(${NUM_FRAMES} // 2)")

# Back up the extraction start by HALF_FRAMES * EVERY_N source frames, clamped
# to zero so we never seek before the beginning of the file.
L_START_EXTRACT=$(python3 -c "print(max(0.0, round(${L_START} - ${HALF_FRAMES} * ${EVERY_N} / ${FPS}, 6)))")
R_START_EXTRACT=$(python3 -c "print(max(0.0, round(${R_START} - ${HALF_FRAMES} * ${EVERY_N} / ${FPS}, 6)))")

# Duration needed: enough frames to select NUM_FRAMES after skipping EVERY_N
DURATION=$(python3 -c "print(round(${NUM_FRAMES} * ${EVERY_N} / ${FPS} + 2, 1))")

echo ""
echo "=== Blink Comparator Frame Extraction ==="
echo ""
echo "  Left:   $LEFT_INPUT  (from ${L_START_EXTRACT}s, alignment point at ${L_START}s)"
echo "  Right:  $RIGHT_INPUT  (from ${R_START_EXTRACT}s, alignment point at ${R_START}s)"
echo "  Frames: ${NUM_FRAMES} pairs, every ${EVERY_N}th frame (centred on alignment point)"
echo "  Output: $OUTPUT_DIR"
echo ""

echo "--- Extracting LEFT frames ---"
ffmpeg -ss "$L_START_EXTRACT" -t "$DURATION" -i "$LEFT_INPUT" \
    -vf "scale=${VID_WIDTH}:${VID_HEIGHT},setsar=1,fps=${LEFT_FPS_RAW},select=not(mod(n\,${EVERY_N}))" \
    -vsync vfr \
    -frames:v "$NUM_FRAMES" \
    -q:v 2 \
    "$OUTPUT_DIR/frames_left/frame_%04d.jpg" 2>/dev/null
echo "  Done."

echo "--- Extracting RIGHT frames ---"
ffmpeg -ss "$R_START_EXTRACT" -t "$DURATION" -i "$RIGHT_INPUT" \
    -vf "scale=${VID_WIDTH}:${VID_HEIGHT},setsar=1,fps=${RIGHT_FPS_RAW},select=not(mod(n\,${EVERY_N}))" \
    -vsync vfr \
    -frames:v "$NUM_FRAMES" \
    -q:v 2 \
    "$OUTPUT_DIR/frames_right/frame_%04d.jpg" 2>/dev/null
echo "  Done."

# Count actual extracted frames
LEFT_COUNT=$(ls "$OUTPUT_DIR/frames_left/"*.jpg 2>/dev/null | wc -l)
RIGHT_COUNT=$(ls "$OUTPUT_DIR/frames_right/"*.jpg 2>/dev/null | wc -l)
PAIR_COUNT=$(python3 -c "print(min($LEFT_COUNT, $RIGHT_COUNT))")

echo ""
echo "  Extracted: $LEFT_COUNT left frames, $RIGHT_COUNT right frames, $PAIR_COUNT pairs"

if [ "$PAIR_COUNT" -eq 0 ]; then
    echo "[ERROR] No frames extracted. Check offsets and input files."
    exit 1
fi

# ==============================================================================
# HTML Generation
# ==============================================================================
echo ""
echo "--- Generating HTML comparator ---"

# Build JS arrays of frame filenames
LEFT_FRAMES=""
RIGHT_FRAMES=""
for i in $(seq 1 $PAIR_COUNT); do
    FNAME=$(printf "frame_%04d.jpg" $i)
    LEFT_FRAMES="${LEFT_FRAMES}  'frames_left/${FNAME}',\n"
    RIGHT_FRAMES="${RIGHT_FRAMES}  'frames_right/${FNAME}',\n"
done

# ==============================================================================
# Save Offset button — only injected when -j DIR is given.
#
# The button is placed in its own ctrl-group alongside the nudge controls.
# When clicked, it packages the nudge-corrected offset plus file metadata into
# a JSON blob and triggers a browser download.  Because this runs from a
# file:// URL, we use URL.createObjectURL / revokeObjectURL rather than any
# server-side mechanism.
#
# The download filename is always "alignment.json".  The browser will save it
# to the user's Downloads folder by default; the UI note tells the user to
# move it to SAVE_OFFSET_DIR if needed, but blink_survey.sh also accepts
# -f PATH so the user can point it wherever the file lands.
# ==============================================================================
if [ -n "$SAVE_OFFSET_DIR" ]; then
    # Escape paths for embedding in a JS string literal
    LEFT_ABS_JS=$(printf '%s' "$LEFT_ABS"  | sed "s/'/\\\\'/g")
    RIGHT_ABS_JS=$(printf '%s' "$RIGHT_ABS" | sed "s/'/\\\\'/g")
    LEFT_LABEL_JS=$(printf '%s' "$LEFT_LABEL"  | sed "s/'/\\\\'/g")
    RIGHT_LABEL_JS=$(printf '%s' "$RIGHT_LABEL" | sed "s/'/\\\\'/g")
    SAVE_DIR_JS=$(printf '%s' "$SAVE_OFFSET_DIR" | sed "s/'/\\\\'/g")

    # Tape position (left-file seconds) where this alignment was done
    ALIGN_SECS=$(python3 -c "print(round(float('${L_START}'), 3))")

    # Load existing offset_points from alignment.json if present
    EXISTING_JSON="${SAVE_OFFSET_DIR}/alignment.json"
    if [[ -f "$EXISTING_JSON" ]]; then
        EXISTING_POINTS=$(python3 -c "
import json
try:
    d = json.load(open('$EXISTING_JSON'))
    pts = d.get('offset_points', [])
    if not pts and 'offset' in d:
        pts = [{'secs': d.get('aligned_at_secs', 0), 'offset': d['offset']}]
    print(json.dumps(pts))
except Exception:
    print('[]')
" 2>/dev/null || echo "[]")
    else
        EXISTING_POINTS="[]"
    fi

    SAVE_OFFSET_HTML='
  <div class="ctrl-group" style="grid-column:1/-1">
    <h3>Save Alignment</h3>
    <div class="btn-row">
      <button id="btn-save-offset" title="Download alignment.json with current nudge-adjusted offset">
        ⬇ Save Offset
      </button>
      <span id="save-offset-status"
            style="font-family:'\''Share Tech Mono'\'',monospace;font-size:11px;
                   color:var(--dim);margin-left:12px">
        Downloads alignment.json — move to survey directory if needed.
      </span>
    </div>
  </div>'

    SAVE_OFFSET_JS="
// ----------------------------------------------------------------------
// Save Offset button
// Packages the nudge-corrected offset into alignment.json and triggers
// a browser download.  Works from file:// URLs via createObjectURL.
// If alignment.json already exists in survey_dir (injected below as a
// JS variable), the new point is appended to offset_points array so
// dual_compare.sh can interpolate a drift curve across the tape.
// ----------------------------------------------------------------------
document.getElementById('btn-save-offset').addEventListener('click', () => {
  const everyN     = ${EVERY_N};
  const frameSecs  = FRAME_PERIOD;
  const adjustSecs = nudge * everyN * frameSecs;
  const savedOffset = (${OFFSET} - adjustSecs);

  // Parse the aligned_at time into seconds from start of file for the
  // offset_points array.  aligned_at_secs is the left-file time of this
  // alignment point, injected by blink_compare.sh as the -t argument.
  const alignedAtSecs = ${ALIGN_SECS};

  const now = new Date().toISOString();

  // Load existing offset_points if available (injected as JS variable)
  let existingPoints = ${EXISTING_POINTS};
  // Remove any existing point at the same position (within 5 seconds)
  existingPoints = existingPoints.filter(p => Math.abs(p.secs - alignedAtSecs) > 5);
  // Add new point
  existingPoints.push({secs: alignedAtSecs, offset: parseFloat(savedOffset.toFixed(6))});
  // Sort by position
  existingPoints.sort((a, b) => a.secs - b.secs);

  const data = {
    left_file:       '${LEFT_ABS_JS}',
    right_file:      '${RIGHT_ABS_JS}',
    offset:          parseFloat(savedOffset.toFixed(6)),
    aligned_at_secs: alignedAtSecs,
    offset_points:   existingPoints,
    left_label:      '${LEFT_LABEL_JS}',
    right_label:     '${RIGHT_LABEL_JS}',
    aligned_at:      now,
    aligned_by:      'blink_compare.sh',
    survey_dir:      '${SAVE_DIR_JS}'
  };

  const blob = new Blob([JSON.stringify(data, null, 2)], {type: 'application/json'});
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href     = url;
  a.download = 'alignment.json';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);

  const status = document.getElementById('save-offset-status');
  status.textContent = 'Saved: offset=' + savedOffset.toFixed(6) + 's  (' + now + ')';
  status.style.color = 'var(--accent)';
});
"
else
    SAVE_OFFSET_HTML=""
    SAVE_OFFSET_JS=""
fi

cat > "$OUTPUT_DIR/index.html" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Blink Comparator — ${LEFT_LABEL} vs ${RIGHT_LABEL}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Barlow:wght@300;500;700&display=swap');

  :root {
    --bg:        #0a0c0f;
    --panel:     #111418;
    --border:    #1e2530;
    --accent:    #00e5ff;
    --accent2:   #ff6b35;
    --text:      #c8d4e0;
    --dim:       #4a5568;
    --left-col:  #ffd166;
    --right-col: #06d6a0;
  }

  * { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Barlow', sans-serif;
    font-weight: 300;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 24px 16px;
    gap: 20px;
  }

  header {
    width: 100%;
    max-width: 900px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  h1 {
    font-family: 'Share Tech Mono', monospace;
    font-size: 13px;
    letter-spacing: 0.15em;
    text-transform: uppercase;
    color: var(--accent);
  }

  .subtitle {
    font-size: 11px;
    color: var(--dim);
    letter-spacing: 0.08em;
    font-family: 'Share Tech Mono', monospace;
  }

  /* ── Main viewer ── */
  .viewer-wrap {
    width: 100%;
    max-width: 1440px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .label-bar {
    display: flex;
    justify-content: space-between;
    font-family: 'Share Tech Mono', monospace;
    font-size: 11px;
    letter-spacing: 0.1em;
  }

  .label-left  { color: var(--left-col); }
  .label-right { color: var(--right-col); }
  .label-mode  { color: var(--accent); }

  .frame-container {
    position: relative;
    width: 100%;
    /* Aspect ratio is set dynamically by JS once the first frame loads,
       so it always matches the actual video dimensions regardless of source. */
    background: #000;
    border: 1px solid var(--border);
    overflow: hidden;
    cursor: crosshair;
    user-select: none;
  }

  .frame-container.zoomed { cursor: grab; }
  .frame-container.zoomed.dragging { cursor: grabbing; }

  .frame-container img {
    position: absolute;
    top: 0; left: 0;
    width: 100%; height: 100%;
    object-fit: contain;
    transition: opacity 0.05s;
    transform-origin: 0 0;
    will-change: transform;
    pointer-events: none;
  }

  #img-display { opacity: 1; width: 100%; height: 100%; }

  /* Zoom indicator */
  .zoom-badge {
    position: absolute;
    bottom: 10px; right: 10px;
    background: rgba(0,0,0,0.75);
    border: 1px solid var(--dim);
    padding: 3px 8px;
    font-family: 'Share Tech Mono', monospace;
    font-size: 11px;
    color: var(--dim);
    pointer-events: none;
    z-index: 10;
    transition: color 0.2s, border-color 0.2s;
  }
  .zoom-badge.active {
    color: var(--accent);
    border-color: var(--accent);
  }

  /* Side-by-side and diff both use the canvas at double width */
  #sbs-canvas {
    display: none;
    width: 100%; height: 100%;
  }
  .frame-container.wide-mode #sbs-canvas {
    display: block;
  }
  .frame-container.wide-mode #img-display {
    display: none;
  }

  /* Corner badge */
  .badge {
    position: absolute;
    top: 10px; left: 10px;
    background: rgba(0,0,0,0.75);
    border: 1px solid currentColor;
    padding: 3px 8px;
    font-family: 'Share Tech Mono', monospace;
    font-size: 13px;
    letter-spacing: 0.1em;
    pointer-events: none;
    z-index: 10;
    transition: color 0.1s;
  }

  /* ── Controls ── */
  .controls {
    width: 100%;
    max-width: 1440px;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }

  .ctrl-group {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .ctrl-group h3 {
    font-family: 'Share Tech Mono', monospace;
    font-size: 10px;
    letter-spacing: 0.15em;
    text-transform: uppercase;
    color: var(--dim);
    margin-bottom: 2px;
  }

  .btn-row {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }

  button {
    background: transparent;
    border: 1px solid var(--border);
    color: var(--text);
    font-family: 'Share Tech Mono', monospace;
    font-size: 11px;
    letter-spacing: 0.08em;
    padding: 6px 12px;
    cursor: pointer;
    transition: border-color 0.15s, color 0.15s, background 0.15s;
  }

  button:hover {
    border-color: var(--accent);
    color: var(--accent);
  }

  button.active {
    background: var(--accent);
    border-color: var(--accent);
    color: #000;
  }

  button.danger.active {
    background: var(--accent2);
    border-color: var(--accent2);
    color: #000;
  }

  /* Frame strip */
  .strip-wrap {
    width: 100%;
    max-width: 1440px;
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .strip-label {
    font-family: 'Share Tech Mono', monospace;
    font-size: 10px;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--dim);
  }

  .strip-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .strip-side-label {
    font-family: 'Share Tech Mono', monospace;
    font-size: 10px;
    letter-spacing: 0.1em;
    white-space: nowrap;
    min-width: 80px;
    text-align: right;
    flex-shrink: 0;
  }

  .strip {
    display: flex;
    gap: 4px;
    overflow-x: auto;
    padding-bottom: 4px;
    flex: 1;
  }

  .strip-thumb {
    flex-shrink: 0;
    width: 80px;
    height: 54px;
    object-fit: cover;
    border: 2px solid transparent;
    cursor: pointer;
    opacity: 0.5;
    transition: opacity 0.15s, border-color 0.15s;
  }

  .strip-thumb:hover { opacity: 0.8; }
  .strip-thumb.active {
    border-color: var(--accent);
    opacity: 1;
  }

  /* Slider */
  .slider-row {
    display: flex;
    align-items: center;
    gap: 10px;
    font-family: 'Share Tech Mono', monospace;
    font-size: 11px;
    color: var(--dim);
  }

  input[type=range] {
    flex: 1;
    accent-color: var(--accent);
    height: 2px;
  }

  /* Info bar */
  .info-bar {
    width: 100%;
    max-width: 1440px;
    display: flex;
    justify-content: space-between;
    font-family: 'Share Tech Mono', monospace;
    font-size: 11px;
    color: var(--dim);
    padding: 0 2px;
  }

  kbd {
    display: inline-block;
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 1px 5px;
    font-family: 'Share Tech Mono', monospace;
    font-size: 10px;
    color: var(--text);
    border-radius: 2px;
  }

  ::-webkit-scrollbar { height: 4px; background: var(--bg); }
  ::-webkit-scrollbar-thumb { background: var(--border); }
</style>
</head>
<body>

<header>
  <h1>⬡ Blink Comparator</h1>
  <div class="subtitle">
    <span style="color:var(--left-col)">${LEFT_LABEL}</span>
    <span style="color:var(--dim)"> ↔ </span>
    <span style="color:var(--right-col)">${RIGHT_LABEL}</span>
    <span style="color:var(--dim)"> · ${PAIR_COUNT} frame pairs · every ${EVERY_N} frames · left offset ${L_START}s · right offset ${R_START}s</span>
  </div>
</header>

<div class="viewer-wrap">
  <div class="label-bar">
    <span class="label-left" id="lbl-left">${LEFT_LABEL}</span>
    <span class="label-mode" id="lbl-mode">BLINK</span>
    <span class="label-right" id="lbl-right">${RIGHT_LABEL}</span>
  </div>

  <div class="frame-container" id="viewer">
    <img id="img-display" src="" alt="frame">
    <img id="img-preload" src="" alt="" style="display:none">
    <canvas id="sbs-canvas"></canvas>
    <div class="badge" id="badge" style="color:var(--left-col)">${LEFT_LABEL}</div>
    <div class="zoom-badge" id="zoom-badge">1×</div>
  </div>
</div>

<div class="controls">
  <div class="ctrl-group">
    <h3>Navigation</h3>
    <div class="btn-row">
      <button id="btn-prev" title="Previous frame pair (←)">◀ Prev</button>
      <button id="btn-next" title="Next frame pair (→)">Next ▶</button>
    </div>
    <div class="slider-row">
      <span>1</span>
      <input type="range" id="frame-slider" min="1" max="${PAIR_COUNT}" value="1">
      <span>${PAIR_COUNT}</span>
      <span id="frame-counter" style="color:var(--accent);min-width:3em;text-align:right">1/${PAIR_COUNT}</span>
    </div>
  </div>

  <div class="ctrl-group">
    <h3>View Mode</h3>
    <div class="btn-row">
      <button id="btn-blink" class="active" title="Auto-blink (B)">Blink</button>
      <button id="btn-toggle" title="Manual toggle (Space)">Toggle</button>
      <button id="btn-side" title="Side by side (S)">Side/Side</button>
      <button id="btn-diff" class="danger" title="Difference overlay (D)">Diff</button>
    </div>
  </div>

  <div class="ctrl-group">
    <h3>Blink Speed</h3>
    <div class="slider-row">
      <span>Fast</span>
      <input type="range" id="speed-slider" min="100" max="2000" value="500" step="50">
      <span>Slow</span>
      <span id="speed-label" style="color:var(--accent);min-width:4em;text-align:right">0.5s</span>
    </div>
  </div>

  <div class="ctrl-group">
    <h3>Show</h3>
    <div class="btn-row">
      <button id="btn-show-left"  title="Show left only (1)">Left Only</button>
      <button id="btn-show-right" title="Show right only (2)">Right Only</button>
    </div>
  </div>

  <div class="ctrl-group" style="grid-column:1/-1">
    <h3>Right Frame Nudge — shift which right frame pairs with current left frame</h3>
    <div class="btn-row">
      <button id="btn-nudge-m5"  title="Shift right -5 frames">−5</button>
      <button id="btn-nudge-m1"  title="Shift right -1 frame (,)">−1</button>
      <button id="btn-nudge-0"   title="Reset nudge (0)" class="active">Reset</button>
      <button id="btn-nudge-p1"  title="Shift right +1 frame (.)">+1</button>
      <button id="btn-nudge-p5"  title="Shift right +5 frames">+5</button>
      <span id="nudge-label" style="font-family:'Share Tech Mono',monospace;font-size:11px;color:var(--accent);margin-left:12px">nudge: 0 pairs</span>
      <span id="nudge-reextract" style="font-family:'Share Tech Mono',monospace;font-size:11px;color:var(--accent2);margin-left:12px;display:none">
        ⚠ Re-run with <span id="nudge-reextract-val"></span> and reset nudge
      </span>
    </div>
  </div>
${SAVE_OFFSET_HTML}
</div>

<div class="strip-wrap">
  <div class="strip-row">
    <div class="strip-side-label" style="color:var(--left-col)">${LEFT_LABEL}</div>
    <div class="strip" id="strip-left"></div>
  </div>
  <div class="strip-row">
    <div class="strip-side-label" style="color:var(--right-col)">${RIGHT_LABEL}</div>
    <div class="strip" id="strip-right"></div>
  </div>
  <div class="strip-label">Click thumbnails to jump · Left strip tracks left frame · Right strip tracks paired right frame</div>
</div>

<div class="info-bar">
  <span><kbd>←</kbd><kbd>→</kbd> frames &nbsp; <kbd>Space</kbd> toggle &nbsp; <kbd>B</kbd> blink &nbsp; <kbd>S</kbd> side/side &nbsp; <kbd>D</kbd> diff &nbsp; <kbd>1</kbd><kbd>2</kbd> left/right &nbsp; <kbd>,</kbd><kbd>.</kbd> nudge &nbsp; <kbd>scroll</kbd> zoom &nbsp; <kbd>drag</kbd> pan &nbsp; <kbd>Z</kbd> reset zoom</span>
  <span id="info-offset">Left: ${L_START}s · Right: ${R_START}s · Δ $(python3 -c "print(round(${L_START} - ${R_START}, 3))")s</span>
</div>

<script>
const leftFrames = [
$(printf "${LEFT_FRAMES}")
];
const rightFrames = [
$(printf "${RIGHT_FRAMES}")
];

// Frame period in seconds, derived from the actual detected fps of the left file
const FRAME_PERIOD = ${FRAME_PERIOD};

// Video dimensions, used to set correct aspect ratios on the viewer container
const VID_W = ${VID_WIDTH};
const VID_H = ${VID_HEIGHT};

const TOTAL = Math.min(leftFrames.length, rightFrames.length);
// INITIAL_NUDGE is the centre frame index — both strips were extracted starting
// HALF_FRAMES before the alignment point, so frame INITIAL_NUDGE in each strip
// corresponds to the requested alignment time.
const INITIAL_NUDGE = ${HALF_FRAMES};
// Start at the centre of the extracted strip so nudge has equal room in
// both directions before hitting the frame boundary.
let current = INITIAL_NUDGE;
let nudge = 0;   // how many right frames to offset relative to left (0 = aligned)
let blinking = true;
let showingRight = false;
let blinkInterval = null;
let blinkSpeed = 500;
let mode = 'blink'; // blink | side | diff | manual

const viewer    = document.getElementById('viewer');
const imgDisplay = document.getElementById('img-display');
const imgPreload = document.getElementById('img-preload');
const sbsCanvas  = document.getElementById('sbs-canvas');
const badge     = document.getElementById('badge');
const slider    = document.getElementById('frame-slider');
const counter   = document.getElementById('frame-counter');
const speedSlider = document.getElementById('speed-slider');
const speedLabel  = document.getElementById('speed-label');
const lblMode   = document.getElementById('lbl-mode');

// Single-image blink: track which source is currently displayed
let currentSrc = 'left';  // 'left' or 'right'

// Zoom / pan state
let zoomLevel = 1.0;
const ZOOM_MIN = 1.0;
const ZOOM_MAX = 16.0;
const ZOOM_STEP = 0.2;
let panX = 0;
let panY = 0;
let isDragging = false;
let dragStartX = 0;
let dragStartY = 0;
let panStartX = 0;
let panStartY = 0;

const zoomBadge = document.getElementById('zoom-badge');

// Set viewer aspect ratio from actual video dimensions.
// In blink/manual modes: single-frame ratio.
// In side/diff modes: double-width ratio (both frames side by side on canvas).
function setViewerAspect(wide) {
  viewer.style.aspectRatio = wide ? (VID_W * 2) + ' / ' + VID_H
                                  : VID_W + ' / ' + VID_H;
}

// Initialise to single-frame ratio immediately
setViewerAspect(false);

function applyZoom() {
  const img = imgDisplay;
  const canvas = sbsCanvas;
  const el = (mode === 'side' || mode === 'diff') ? canvas : img;

  // Clamp pan so image doesn't drift fully off screen
  const container = viewer.getBoundingClientRect();
  const maxPanX = container.width  * (zoomLevel - 1);
  const maxPanY = container.height * (zoomLevel - 1);
  panX = Math.max(-maxPanX, Math.min(0, panX));
  panY = Math.max(-maxPanY, Math.min(0, panY));

  const transform = zoomLevel === 1
    ? 'none'
    : 'scale(' + zoomLevel + ') translate(' + (panX / zoomLevel) + 'px, ' + (panY / zoomLevel) + 'px)';

  img.style.transform    = transform;
  canvas.style.transform = transform;

  viewer.classList.toggle('zoomed', zoomLevel > 1);
  zoomBadge.textContent = zoomLevel.toFixed(1) + '×';
  zoomBadge.classList.toggle('active', zoomLevel > 1);
}

function zoomTo(level, cx, cy) {
  const container = viewer.getBoundingClientRect();
  cx = (cx !== undefined) ? cx : 0.5;
  cy = (cy !== undefined) ? cy : 0.5;

  const prevZoom = zoomLevel;
  zoomLevel = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, level));

  if (zoomLevel === 1) {
    panX = 0;
    panY = 0;
  } else {
    const scaleChange = zoomLevel / prevZoom;
    panX = cx * container.width  * (1 - zoomLevel) + (panX - cx * container.width  * (1 - prevZoom)) * scaleChange / prevZoom * prevZoom;
    panY = cy * container.height * (1 - zoomLevel) + (panY - cy * container.height * (1 - prevZoom)) * scaleChange / prevZoom * prevZoom;
  }
  applyZoom();
}

function resetZoom() {
  zoomLevel = 1;
  panX = 0;
  panY = 0;
  applyZoom();
}

// Mouse wheel zoom
viewer.addEventListener('wheel', e => {
  e.preventDefault();
  const rect = viewer.getBoundingClientRect();
  const cx = (e.clientX - rect.left) / rect.width;
  const cy = (e.clientY - rect.top)  / rect.height;
  const delta = e.deltaY < 0 ? (1 + ZOOM_STEP) : (1 / (1 + ZOOM_STEP));
  zoomTo(zoomLevel * delta, cx, cy);
}, { passive: false });

// Double-click to reset zoom
viewer.addEventListener('dblclick', () => resetZoom());

// Drag to pan
viewer.addEventListener('mousedown', e => {
  if (zoomLevel <= 1) return;
  isDragging = true;
  dragStartX = e.clientX;
  dragStartY = e.clientY;
  panStartX = panX;
  panStartY = panY;
  viewer.classList.add('dragging');
  e.preventDefault();
});

document.addEventListener('mousemove', e => {
  if (!isDragging) return;
  panX = panStartX + (e.clientX - dragStartX);
  panY = panStartY + (e.clientY - dragStartY);
  applyZoom();
});

document.addEventListener('mouseup', () => {
  if (isDragging) {
    isDragging = false;
    viewer.classList.remove('dragging');
  }
});

function showLeft() {
  currentSrc = 'left';
  imgDisplay.src = leftFrames[current];
  badge.style.color = 'var(--left-col)';
  badge.textContent = '${LEFT_LABEL}';
}

function showRight() {
  const rightIdx = Math.max(0, Math.min(TOTAL - 1, current + nudge));
  currentSrc = 'right';
  imgDisplay.src = rightFrames[rightIdx];
  badge.style.color = 'var(--right-col)';
  badge.textContent = '${RIGHT_LABEL}';
}

function drawSideBySide() {
  const rightIdx = Math.max(0, Math.min(TOTAL - 1, current + nudge));
  const lImg = new Image();
  const rImg = new Image();
  let loaded = 0;
  const onLoad = () => {
    loaded++;
    if (loaded < 2) return;
    sbsCanvas.width  = lImg.naturalWidth * 2;
    sbsCanvas.height = lImg.naturalHeight;
    const ctx = sbsCanvas.getContext('2d');
    ctx.drawImage(lImg, 0, 0);
    ctx.drawImage(rImg, lImg.naturalWidth, 0);
  };
  lImg.onload = onLoad;
  rImg.onload = onLoad;
  lImg.src = leftFrames[current];
  rImg.src = rightFrames[rightIdx];
}

// Build dual thumbnail strips
const stripLeft  = document.getElementById('strip-left');
const stripRight = document.getElementById('strip-right');

for (let i = 0; i < TOTAL; i++) {
  // Left strip
  const lImg = document.createElement('img');
  lImg.src = leftFrames[i];
  lImg.className = 'strip-thumb' + (i === INITIAL_NUDGE ? ' active' : '');
  lImg.title = 'Left frame ' + (i+1);
  lImg.addEventListener('click', () => goTo(i));
  stripLeft.appendChild(lImg);

  // Right strip — src set dynamically to reflect nudge; nudge=0 at init so mirrors left
  const rImg = document.createElement('img');
  const rIdx = i;  // nudge is 0 at init: right frame i pairs with left frame i
  rImg.src = rightFrames[rIdx];
  rImg.className = 'strip-thumb' + (i === INITIAL_NUDGE ? ' active' : '');
  rImg.title = 'Right frame paired with left ' + (i+1);
  rImg.addEventListener('click', () => goTo(i));
  stripRight.appendChild(rImg);
}

function updateRightStrip() {
  // Refresh right strip thumbnails to reflect current nudge
  const thumbs = stripRight.children;
  for (let i = 0; i < TOTAL; i++) {
    const rIdx = Math.max(0, Math.min(TOTAL - 1, i + nudge));
    thumbs[i].src = rightFrames[rIdx];
    const clamped = (i + nudge) !== rIdx;
    thumbs[i].style.borderColor = clamped ? 'var(--accent2)' : '';
    thumbs[i].title = 'Right frame ' + (rIdx+1) + (clamped ? ' ⚠ clamped' : '') + ' (paired with left ' + (i+1) + ')';
  }
}

function goTo(idx) {
  current = Math.max(0, Math.min(TOTAL - 1, idx));
  const rightIdx = Math.max(0, Math.min(TOTAL - 1, current + nudge));

  // Preload both frames for this pair
  imgPreload.src = rightFrames[rightIdx];

  // Show whichever side is currently active
  if (mode === 'side') {
    drawSideBySide();
  } else if (mode === 'diff') {
    drawDiff();
  } else if (currentSrc === 'right') {
    showRight();
  } else {
    showLeft();
  }

  slider.value = current + 1;
  const everyN = ${EVERY_N};
  const rightClamped = (current + nudge) !== rightIdx;
  const pairLabel = 'L:' + (current+1) + ' R:' + (rightIdx+1) + (everyN > 1 ? ' (×' + everyN + ')' : '') + (rightClamped ? ' ⚠' : '');
  counter.textContent = (current+1) + '/' + TOTAL + '  ' + pairLabel;

  // Update both strips — highlight active frame in each
  Array.from(stripLeft.children).forEach((el, i) => {
    el.classList.toggle('active', i === current);
  });
  Array.from(stripRight.children).forEach((el, i) => {
    el.classList.toggle('active', i === current);
  });
  const lThumb = stripLeft.children[current];
  if (lThumb) lThumb.scrollIntoView({behavior:'smooth', block:'nearest', inline:'center'});
  const rThumb = stripRight.children[current];
  if (rThumb) rThumb.scrollIntoView({behavior:'smooth', block:'nearest', inline:'center'});
}

function drawDiff() {
  const rightIdx = Math.max(0, Math.min(TOTAL - 1, current + nudge));
  const lImg = new Image();
  const rImg = new Image();
  let loaded = 0;
  const onLoad = () => {
    loaded++;
    if (loaded < 2) return;
    // Diff draws a single frame width (not double), so the aspect ratio
    // must match a single frame — same as blink mode.
    sbsCanvas.width  = lImg.naturalWidth;
    sbsCanvas.height = lImg.naturalHeight;
    const ctx = sbsCanvas.getContext('2d');
    ctx.drawImage(lImg, 0, 0);
    ctx.globalCompositeOperation = 'difference';
    ctx.drawImage(rImg, 0, 0);
    ctx.globalCompositeOperation = 'source-over';
  };
  lImg.onload = onLoad;
  rImg.onload = onLoad;
  lImg.src = leftFrames[current];
  rImg.src = rightFrames[rightIdx];
}

function setNudge(n) {
  // Clamp nudge so the right index stays within [0, TOTAL-1] at the current
  // position.  This is the tightest meaningful bound: going further would only
  // show the same clamped frame again.
  const minNudge = -current;
  const maxNudge = (TOTAL - 1) - current;
  const clamped_n = Math.max(minNudge, Math.min(maxNudge, n));

  // If already at the frame-level limit and the request would push further,
  // do nothing — prevents the display from updating when nothing can change.
  if (clamped_n === nudge && n !== nudge) return;

  nudge = clamped_n;

  const everyN = ${EVERY_N};
  const frameSecs = FRAME_PERIOD;
  const sourceFrames = nudge * everyN;
  let label = 'nudge: ' + (nudge >= 0 ? '+' : '') + nudge + ' pair' + (Math.abs(nudge) !== 1 ? 's' : '');
  if (everyN > 1) label += ' (' + sourceFrames + ' src frames, ~' + (Math.abs(sourceFrames) * frameSecs).toFixed(2) + 's)';
  else label += ' (~' + (Math.abs(nudge) * frameSecs).toFixed(3) + 's)';

  const reextractEl = document.getElementById('nudge-reextract');
  const reextractVal = document.getElementById('nudge-reextract-val');
  if (nudge !== 0) {
    // nudge and offset adjustment are opposite:
    //   positive nudge = right is late  → increase -o (left further ahead)
    //   negative nudge = right is early → decrease -o (left less far ahead)
    const currentOffset = ${OFFSET};
    const adjustSecs = nudge * everyN * frameSecs;
    const newOffset = (currentOffset - adjustSecs).toFixed(6).replace(/\.?0+$/, '');
    const direction = adjustSecs > 0 ? 'decrease' : 'increase';
    reextractVal.textContent = '-o ' + newOffset + '  (' + direction + ' from ${OFFSET})';
    reextractEl.style.display = '';
  } else {
    reextractEl.style.display = 'none';
  }

  document.getElementById('nudge-label').textContent = label;
  document.getElementById('nudge-label').style.color = 'var(--accent)';
  document.getElementById('btn-nudge-0').classList.toggle('active', nudge === 0);
  updateRightStrip();
  goTo(current);
}

function setMode(m) {
  mode = m;
  stopBlink();
  viewer.classList.remove('wide-mode');
  imgDisplay.style.display = '';
  badge.style.display = '';

  ['btn-blink','btn-side','btn-diff'].forEach(id => {
    document.getElementById(id).classList.remove('active');
  });

  if (m === 'blink') {
    lblMode.textContent = 'BLINK';
    document.getElementById('btn-blink').classList.add('active');
    setViewerAspect(false);
    startBlink();
  } else if (m === 'side') {
    lblMode.textContent = 'SIDE/SIDE';
    document.getElementById('btn-side').classList.add('active');
    setViewerAspect(true);
    viewer.classList.add('wide-mode');
    badge.style.display = 'none';
    drawSideBySide();
  } else if (m === 'diff') {
    lblMode.textContent = 'DIFF';
    document.getElementById('btn-diff').classList.add('active');
    // Diff overlays one frame on top of the other — single-frame aspect ratio
    setViewerAspect(false);
    viewer.classList.add('wide-mode');
    badge.style.display = 'none';
    drawDiff();
  } else if (m === 'manual') {
    lblMode.textContent = currentSrc === 'right' ? 'RIGHT' : 'LEFT';
    setViewerAspect(false);
  }
}

function startBlink() {
  stopBlink();
  // Start on left
  showLeft();
  blinkInterval = setInterval(() => {
    if (currentSrc === 'left') {
      showRight();
    } else {
      showLeft();
    }
  }, blinkSpeed);
}

function stopBlink() {
  if (blinkInterval) { clearInterval(blinkInterval); blinkInterval = null; }
}

function manualToggle() {
  if (mode !== 'manual') { stopBlink(); mode = 'manual'; setViewerAspect(false); }
  if (currentSrc === 'left') {
    showRight();
    lblMode.textContent = 'RIGHT';
  } else {
    showLeft();
    lblMode.textContent = 'LEFT';
  }
}

// Controls
document.getElementById('btn-prev').addEventListener('click', () => goTo(current - 1));
document.getElementById('btn-next').addEventListener('click', () => goTo(current + 1));
document.getElementById('btn-blink').addEventListener('click', () => setMode('blink'));
document.getElementById('btn-toggle').addEventListener('click', manualToggle);
document.getElementById('btn-side').addEventListener('click', () => setMode('side'));
document.getElementById('btn-diff').addEventListener('click', () => setMode('diff'));
document.getElementById('btn-show-left').addEventListener('click', () => {
  stopBlink(); mode = 'manual';
  setViewerAspect(false);
  viewer.classList.remove('wide-mode');
  showLeft();
  lblMode.textContent = 'LEFT';
});
document.getElementById('btn-show-right').addEventListener('click', () => {
  stopBlink(); mode = 'manual';
  setViewerAspect(false);
  viewer.classList.remove('wide-mode');
  showRight();
  lblMode.textContent = 'RIGHT';
});

slider.addEventListener('input', () => goTo(parseInt(slider.value) - 1));

speedSlider.addEventListener('input', () => {
  blinkSpeed = parseInt(speedSlider.value);
  speedLabel.textContent = (blinkSpeed/1000).toFixed(1) + 's';
  if (mode === 'blink') startBlink();
});

document.addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT') return;
  switch(e.key) {
    case 'ArrowLeft':  e.preventDefault(); goTo(current - 1); break;
    case 'ArrowRight': e.preventDefault(); goTo(current + 1); break;
    case ' ':          e.preventDefault(); manualToggle(); break;
    case 'b': case 'B': setMode('blink'); break;
    case 's': case 'S': setMode('side'); break;
    case 'd': case 'D': setMode('diff'); break;
    case '1': document.getElementById('btn-show-left').click(); break;
    case '2': document.getElementById('btn-show-right').click(); break;
    case ',': setNudge(nudge - 1); break;
    case '.': setNudge(nudge + 1); break;
    case 'z': case 'Z': resetZoom(); break;
  }
});

// Nudge controls
document.getElementById('btn-nudge-m5').addEventListener('click', () => setNudge(nudge - 5));
document.getElementById('btn-nudge-m1').addEventListener('click', () => setNudge(nudge - 1));
document.getElementById('btn-nudge-0').addEventListener('click',  () => setNudge(0));
document.getElementById('btn-nudge-p1').addEventListener('click', () => setNudge(nudge + 1));
document.getElementById('btn-nudge-p5').addEventListener('click', () => setNudge(nudge + 5));

${SAVE_OFFSET_JS}

// Init — start at the centred alignment frame so both strips open on the
// alignment point with equal nudge room in both directions.
goTo(INITIAL_NUDGE);
setMode('blink');
</script>
</body>
</html>
HTMLEOF

echo "  Done."
echo ""
echo "=== Complete ==="
echo ""
echo "  Output directory: $OUTPUT_DIR/"
echo "  Open in browser:  open $OUTPUT_DIR/index.html"
echo ""
echo "  Controls:"
echo "    ←/→       Step through frame pairs"
echo "    Space     Manual toggle left/right"
echo "    B         Blink mode (auto-alternates)"
echo "    S         Side-by-side mode"
echo "    D         Difference overlay mode"
echo "    1 / 2     Show left or right only"
if [ -n "$SAVE_OFFSET_DIR" ]; then
echo "    Save Offset button → downloads alignment.json"
fi
echo ""
