#!/bin/bash
# ==============================================================================
# Script Name: capture_tape.sh v38
# Optimized for: Sony DCR-TRV330 (Hi8/Digital8) & LSI FireWire Chipsets
# ==============================================================================
# CONFIGURATION:
# CAPTURE_ROOT defaults to ~/dv_captures, which can be a symlink to wherever
# your video storage actually lives. This works on any machine for any user.
#
# To set up on a new machine:
#   ln -s /path/to/actual/storage ~/dv_captures
#
# Examples:
#   Mac Mini:  ln -s /mnt/video_capture/avi/captures ~/dv_captures
#   Desktop:   ln -s /media/rrusk/videodrive/captures ~/dv_captures
#
# Override at runtime with: -o /path/to/output
# Do NOT use relative paths (./captures) as dvgrab will fail to create files.
# ==============================================================================
#
# CHANGE LOG:
#   v38 -- DV mode: progress lines show timecode, filename, and cumulative MiB.
#          Bitrate removed from per-frame progress; reported once at segment
#          close (>>> SEGMENT DONE) using stat on the closed file for exact
#          size. NEW SEGMENT announcements replaced by SEGMENT DONE.
#          Date analysis reads filming dates from AVI filenames instead of
#          log parsing; no year filter needed (DV stream dates are trustworthy).
#          Session header (version, date) written to log after user confirms.
#          awk pipeline uses tee -a to preserve the session header.
#
#   v37 -- CAPTURE_ROOT defaults to ~/dv_captures (symlink-friendly, portable).
#          Validation detects broken symlinks and offers to create the directory
#          on first run. mkdir -p no longer treated as fatal if dir exists.
#   v36 -- DV mode: added --size 0 to prevent 1GB mid-segment splits.
#   v35 -- All modes: --format dv1 (dv2 causes audio sync drift).
#
#   v36 -- Changed --format dv1 to --format raw: raw .dv files seek
#          cleanly in VLC and can be trimmed with dd without AVI
#          container overhead or index rebuilding issues.
#   v34 -- Audit loops all AVI files; per-file [OK]/[!!!] flags; totals.
#   v32 -- Fixed progress stopping after first DV segment (awk subline split).
#          Improved usage/help with concrete filename examples.
#   v18 -- Initial production release.
# ==============================================================================
#
# NOTE: The entire script body is wrapped in main() and called at the bottom.
# This causes bash to read and parse the complete script into memory before
# execution begins, so editing this file mid-run has no effect on the current
# capture session.
# ==============================================================================
set -uo pipefail

# ==============================================================================
# Dependency Preflight
# Fail early with a clear message rather than a cryptic error mid-capture.
# Placed outside main() so it runs before the function body is even entered.
# ==============================================================================
for cmd in dvgrab ffprobe bc gawk; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[ERROR] Required command not found: $cmd"
        echo "        Install it and retry."
        exit 1
    }
done

# ==============================================================================
# Configuration
# Placed outside main() so they are visible to usage() help text at any point.
# ==============================================================================
# Default capture root. Use a symlink to point this at actual storage:
#   ln -s /path/to/actual/storage ~/dv_captures
CAPTURE_ROOT="${HOME}/dv_captures"

# How often to emit a progress line to the console and log during capture.
# This is used to bracket damaged-frame warnings with an approximate tape
# position, since Hi8 timecodes are garbage and cannot be used directly.
# Value is in seconds. At 29.97fps NTSC: 60s = ~1798 frames.
# Increase to reduce log verbosity; decrease for finer position resolution.
PROGRESS_INTERVAL_SEC=60

# ==============================================================================
# main() -- entire script body
# bash reads and parses this function completely before executing it, so any
# edits made to this file after the script starts are safely ignored.
# ==============================================================================
main() {

# ==============================================================================
# Usage / Help
# ==============================================================================
usage() {
    echo ""
    echo "Usage: $0 [-o OUTPUT_DIR] [-t hi8|dv] <TAPE_ID> [DESCRIPTION]"
    echo ""
    echo "  -o OUTPUT_DIR  Optional. Override the default capture root."
    echo "                 Default: ${CAPTURE_ROOT}"
    echo "  -t TAPE_TYPE   Optional. Tape format: hi8 (default) or dv (Digital8)."
    echo "                 hi8:  Single large file, session date in filename."
    echo "                       Warns if valid timecodes are found (suggests -t dv)."
    echo "                 dv:   Files split by recording segment, named using the"
    echo "                       filming date embedded in the DV stream."
    echo "                       e.g. dv_1997.08.03_14.23.11.dv"
    echo "  TAPE_ID        Required. A short unique identifier for the tape."
    echo "                 Spaces are allowed and will be converted to underscores."
    echo "  DESCRIPTION    Optional. Additional context appended to the filename."
    echo ""
    echo "HOW FILES ARE NAMED"
    echo "-------------------"
    echo "A session directory is always created under OUTPUT_DIR."
    echo "Its name is: <TAPE_ID>[_<DESCRIPTION>]_<YYYYMMDD_HHMM>"
    echo "The capture date/time is appended so that repeat captures of the same"
    echo "tape (e.g. after a head clog) do not overwrite each other."
    echo ""
    echo "  Hi8 mode (default, -t hi8):"
    echo "    One large file per capture. The file is named after the session:"
    echo "      <TAPE_ID>[_<DESCRIPTION>]_<YYYYMMDD_HHMM>001.dv"
    echo "    If the signal drops and dvgrab autosplits, a second file appears:"
    echo "      <TAPE_ID>[_<DESCRIPTION>]_<YYYYMMDD_HHMM>002.dv"
    echo "    Hi8 has no internal clock so filenames use the CAPTURE date."
    echo ""
    echo "    Example: $0 hi8_20040107-20040207 'Christmas 2004'"
    echo "      Directory: ${CAPTURE_ROOT}/hi8_20040107-20040207_Christmas_2004_20260406_1347/"
    echo "      File(s):   hi8_20040107-20040207_Christmas_2004_20260406_1347001.dv"
    echo "                 hi8_20040107-20040207_Christmas_2004_20260406_1347002.dv  (if autosplit)"
    echo ""
    echo "    Example: $0 hi8_20040107-20040207"
    echo "      Directory: ${CAPTURE_ROOT}/hi8_20040107-20040207_20260406_1347/"
    echo "      File(s):   hi8_20040107-20040207_20260406_1347001.dv"
    echo ""
    echo "  Digital8 mode (-t dv):"
    echo "    One file per recording segment, named using the FILMING date embedded"
    echo "    in the DV stream so files sort chronologically by content."
    echo "    Files inside the session directory are named by dvgrab as:"
    echo "      <TAPE_ID>_<YYYY.MM.DD_HH-MM-SS>.dv"
    echo "    If the same filming date appears in multiple segments, dvgrab appends"
    echo "    a counter: <TAPE_ID>_<date>-1.dv, <TAPE_ID>_<date>-2.dv, etc."
    echo ""
    echo "    Example: $0 -t dv dv_20040107-20040207"
    echo "      Directory: ${CAPTURE_ROOT}/dv_20040107-20040207_20260406_1347/"
    echo "      File(s):   dv_20040107-20040207_2004.01.07_14-23-11.dv"
    echo "                 dv_20040107-20040207_2004.01.15_09-05-44.dv"
    echo "                 dv_20040107-20040207_2004.02.07_18-30-00.dv"
    echo ""
    echo "    Example: $0 -t dv dv"
    echo "      Directory: ${CAPTURE_ROOT}/dv_20260406_1802/"
    echo "      File(s):   dv_2004.05.02_16-52-12.dv"
    echo "                 dv_2004.05.15_11-04-33.dv"
    echo ""
    echo "NOTES"
    echo "-----"
    echo "  - Spaces are converted to underscores automatically."
    echo "  - Special characters are stripped for filesystem safety."
    echo "  - For Hi8, use a TAPE_ID that encodes the date range on the tape,"
    echo "    e.g. 'hi8_20040107-20040207', so filenames are self-documenting."
    echo "  - For Digital8, the TAPE_ID prefix is prepended to each filename."
    echo "    Keep it short to avoid overly long paths."
    echo "  - After capture, all unique recording dates found on the tape are"
    echo "    reported. Garbage timecodes outside 1980-2010 are filtered out."
    echo ""
    echo "IMPORTANT: Default CAPTURE_ROOT is: ${CAPTURE_ROOT}"
    echo "  This can be a symlink to your actual storage location:"
    echo "    ln -s /path/to/actual/storage ~/dv_captures"
    echo "  Or override at runtime with: -o /path/to/output"
    echo ""
}

if [ "$#" -lt 1 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
    [ "$#" -lt 1 ] && exit 1 || exit 0
fi

# ==============================================================================
# 1. Argument Parsing
# ==============================================================================
TAPE_TYPE="hi8"   # default; override with -t dv

while getopts ":o:t:" opt; do
    case $opt in
        o)
            CAPTURE_ROOT="$OPTARG"
            ;;
        t)
            TAPE_TYPE="$OPTARG"
            if [[ "$TAPE_TYPE" != "hi8" && "$TAPE_TYPE" != "dv" ]]; then
                echo "[ERROR] -t must be 'hi8' or 'dv' (got: $TAPE_TYPE)"
                usage
                exit 1
            fi
            ;;
        \?)
            echo "[ERROR] Unknown option: -$OPTARG"
            usage
            exit 1
            ;;
        :)
            echo "[ERROR] Option -$OPTARG requires an argument."
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -lt 1 ]; then
    echo "[ERROR] TAPE_ID is required."
    usage
    exit 1
fi

TAPE_ID="$1"
EXTRA_DESC="${2:-}"

# ==============================================================================
# 2. Validate CAPTURE_ROOT
# ==============================================================================
if [ ! -e "$CAPTURE_ROOT" ]; then
    # Resolve what ~/dv_captures should point to before prompting, so the
    # message is useful whether it is a plain directory or a broken symlink.
    echo "[WARNING] CAPTURE_ROOT does not exist: $CAPTURE_ROOT"
    if [ -L "$CAPTURE_ROOT" ]; then
        echo "          This is a broken symlink. Fix it with:"
        echo "            ln -sf /path/to/actual/storage $CAPTURE_ROOT"
        exit 1
    fi
    read -p "          Create it now? (y/n): " _CREATE
    if [[ "$_CREATE" =~ ^[Yy]$ ]]; then
        mkdir -p "$CAPTURE_ROOT" || {
            echo "[ERROR] Failed to create: $CAPTURE_ROOT"
            exit 1
        }
        echo "[INFO] Created: $CAPTURE_ROOT"
        echo "       Consider making this a symlink to your actual storage:"
        echo "         rmdir $CAPTURE_ROOT"
        echo "         ln -s /path/to/actual/storage $CAPTURE_ROOT"
    else
        echo "Aborted. Create the directory or symlink and retry."
        exit 1
    fi
fi
if [ ! -d "$CAPTURE_ROOT" ]; then
    echo "[ERROR] CAPTURE_ROOT exists but is not a directory: $CAPTURE_ROOT"
    exit 1
fi
if [ ! -w "$CAPTURE_ROOT" ]; then
    echo "[ERROR] CAPTURE_ROOT is not writable: $CAPTURE_ROOT"
    _parent=$(dirname "$CAPTURE_ROOT")
    echo "        Check permissions with: ls -la \"$_parent\""
    exit 1
fi

# ==============================================================================
# 3. Configuration & Sanitization
# ==============================================================================
# Sanitize: printf avoids the trailing newline that echo appends, which tr
# was converting to a trailing underscore and causing double-underscore filenames.
SAFE_ID=$(printf '%s' "$TAPE_ID" | tr '[:space:]' '_' | tr -cd '[:alnum:]_-')
SAFE_DESC=$(printf '%s' "$EXTRA_DESC" | tr '[:space:]' '_' | tr -cd '[:alnum:]_-')

# Capture date disambiguates repeat captures of the same tape (e.g. after a head clog)
SESSION_DATE=$(date +%Y%m%d_%H%M)

# Build BASE_NAME, only including SAFE_DESC if it is non-empty
if [[ -n "$SAFE_DESC" ]]; then
    BASE_NAME="${SAFE_ID}_${SAFE_DESC}_${SESSION_DATE}"
else
    BASE_NAME="${SAFE_ID}_${SESSION_DATE}"
fi

OUTPUT_DIR="${CAPTURE_ROOT}/${BASE_NAME}"
LOG_FILE="${OUTPUT_DIR}/${BASE_NAME}.log"
DATE_REPORT="${OUTPUT_DIR}/${BASE_NAME}.dates.txt"

# ==============================================================================
# 4. Pre-flight: Directory Collision Check
# SESSION_DATE makes this unlikely, but protects against same-minute re-runs
# ==============================================================================
mkdir -p "$OUTPUT_DIR"
# find is more reliable than ls -A for non-empty check -- handles odd filenames
# and avoids word-splitting on the subshell output.
if [ "$(find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    echo "[WARNING] Output directory is not empty: $OUTPUT_DIR"
    echo "          A previous capture may exist. Continuing will mix files."
    read -p "Continue anyway? (y/n): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        echo "Aborted. Remove or rename $OUTPUT_DIR and retry."
        exit 2
    fi
fi

# ==============================================================================
# 5. Hardware Pre-Check
# ==============================================================================
if ! ls /dev/fw* &>/dev/null && ! ls /dev/raw1394 &>/dev/null; then
    echo "[ERROR] FireWire device node not found. Is the Sony TRV330 in VTR mode?"
    exit 1
fi

echo "========================================================="
echo "ARCHIVAL INGEST: $BASE_NAME  [capture_tape.sh v38]"
echo "Output:  $OUTPUT_DIR"
echo "---------------------------------------------------------"
echo "CHECKLIST:"
echo " - Tape rewound to start point?"
echo " - Destination drive has ~35GB free?"
echo "---------------------------------------------------------"
read -p "Begin automated playback and capture? (y/n): " PROCEED
if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
    echo "Capture aborted by user."
    exit 2
fi

# Write session header to log now that the user has confirmed capture.
# The awk pipeline appends to this file via tee -a.
{
    echo "capture_tape.sh v38"
    echo "Session: $BASE_NAME"
    echo "Started: $(date)"
    echo "Tape type: $TAPE_TYPE"
    echo "---------------------------------------------------------"
} > "$LOG_FILE"

# ==============================================================================
# 6. Flag Configuration (Bash Array)
# ==============================================================================
if [[ "$TAPE_TYPE" == "dv" ]]; then
    # Digital8: --timestamp names each file using the filming date embedded
    # in the DV stream so files sort chronologically by when content was filmed.
    # --autosplit splits on timecode discontinuities, producing one file per
    # recording session. --size 0 is required to suppress dvgrab's default
    # 1GB size limit, which would otherwise split files mid-segment regardless
    # of timecode boundaries.
    FLAGS=(
        --format raw     # Raw DV stream -- seeks cleanly in VLC, trims
                         # instantly with dd, no AVI container overhead.
        --size 0         # Disable 1GB size-based splitting; let --autosplit
                         # handle splits on timecode discontinuities only
        --timestamp      # Name files using embedded DV recording date
        --autosplit      # Split on signal loss or timecode jumps
        --opendml        # Support files >4GB
        --showstatus
        # --noavc        # Uncomment if camera mechanical control hangs
    )
else
    # Hi8 analog: no valid internal timecodes, so use a single large file
    # named with the capture session date.
    FLAGS=(
        --format raw     # Raw DV stream -- seeks cleanly in VLC, trims
                         # instantly with dd, no AVI container overhead
        --size 0         # Single large file; no size-based splitting
        --autosplit      # Split ONLY on signal loss or timecode jumps
        --opendml        # Support files >4GB (essential for 120min tapes)
        --showstatus     # Emit continuous progress lines; filtered below to one
                         # per PROGRESS_INTERVAL_SEC so damaged-frame warnings
                         # can be bracketed by approximate tape position.
                         # Without this, dvgrab only prints a status line at the
                         # very end of capture (when --size 0 closes the file).
        # --noavc        # Uncomment if camera mechanical control hangs
    )
fi

echo "---------------------------------------------------------"
echo ">>> INITIALIZING DVGRAB..."
echo ">>> COMMANDING CAMERA TO PLAY..."
echo ">>> (If tape doesn't move in 5s, press PLAY on camera)."
echo ">>> Press Ctrl+C to stop. Then press STOP on the camera."
echo "---------------------------------------------------------"

# ==============================================================================
# 7. Execution & Logging
# ==============================================================================
# PROGRESS_INTERVAL_SEC converted to a frame count at NTSC 29.97fps.
# Integer arithmetic using exact NTSC ratio 1001/30000.
PROGRESS_FRAMES=$(( PROGRESS_INTERVAL_SEC * 2997 / 100 ))

# Output file prefix passed to dvgrab and awk.
# For Digital8: use only SAFE_ID so dvgrab appends the filming date directly,
# giving files like "dv_1997.08.03_14.23.11.dv" that sort by content date.
# The capture session date is preserved in OUTPUT_DIR for provenance.
# For Hi8: use the full BASE_NAME including session date.
if [[ "$TAPE_TYPE" == "dv" ]]; then
    OUTPUT_FILE_PREFIX="$OUTPUT_DIR/${SAFE_ID}_"
    echo "[MODE] Digital8 -- files named by filming date, split by segment."
else
    OUTPUT_FILE_PREFIX="$OUTPUT_DIR/${BASE_NAME}"
    echo "[MODE] Analog Hi8 -- single file, named by capture session date."
fi

# Seconds without frame progress before a stall warning is emitted.
STALL_TIMEOUT_SEC=120

# dvgrab --showstatus uses \r to overwrite the terminal line in place,
# producing a stream of \r-separated records with no \n between them.
# RS="\r" in awk BEGIN makes it correctly split on carriage returns
# before any rule runs -- split($0,...,"\r") failed because the entire
# stream arrived as one \n-terminated blob.
#
# IMPORTANT -- WHY WE SPLIT ON \n INSIDE EACH RECORD (v31 fix):
#   dvgrab occasionally emits a \n-terminated filename announcement
#   (e.g. when opening a new autosplit segment) mixed into its otherwise
#   \r-delimited status stream. This creates a single \r-record that
#   contains TWO logical lines joined by \n:
#
#     "/path/to/new_segment.dv":\n   123 frames timecode ... date ...
#
#   In v18, the record-level gsub and regex were applied to the whole
#   combined blob. The frame-count regex could fail to match, causing
#   last_printed to never advance past the first segment and progress
#   output to silently stop for the remainder of the tape.
#
#   The fix (from v31): split each \r-record on \n into sublines and
#   process each subline independently. The filename announcement and
#   the frame-count line are now handled as separate events. All other
#   behaviour (stall detection, bitrate, Hi8 timecode warning, damage
#   deduplication) is identical to v18.
#
# Other features:
#   - Progress sampled every PROGRESS_INTERVAL_SEC with tape position
#   - Real-time bitrate summed across all segment files (autosplit-safe)
#   - Stall detection: warns if frame count unchanged for STALL_TIMEOUT_SEC
#   - Damage warnings and lifecycle messages pass through immediately
#
# stdbuf -oL forces line-buffering on dvgrab's stdout so \r-terminated
# records reach awk promptly rather than accumulating in a block buffer.
#
# || true ensures the script continues to the Audit even if dvgrab
# exits non-zero (normal on tape end).
stdbuf -oL dvgrab "${FLAGS[@]}" "$OUTPUT_FILE_PREFIX" 2>&1 \
| awk -v interval="$PROGRESS_FRAMES" \
      -v outfile_prefix="$OUTPUT_FILE_PREFIX" \
      -v output_dir="$OUTPUT_DIR" \
      -v stall_sec="$STALL_TIMEOUT_SEC" \
      -v tape_type="$TAPE_TYPE" '
    BEGIN {
        RS = "\r"
        last_printed        = -1
        last_frame_seen     = -1
        last_progress_time  = systime()
        capture_start_time  = systime()
        hi8_valid_tc_warned = 0
        last_fname          = ""
        prev_segments_mib   = 0
        last_size_mib       = 0
        segment_start_time  = 0   # wall clock when current segment opened
        segment_start_mib   = 0   # prev_segments_mib at start of current segment
    }
    {
        # RS="\r" splits on carriage returns before any rule runs.
        # Each record may still contain \n-embedded sublines (see comment
        # above). Split the record into sublines and handle each one
        # independently so that filename announcements and frame-count
        # lines in the same record are both processed correctly.
        n = split($0, sublines, "\n")
        for (i = 1; i <= n; i++) {
            line = sublines[i]

            # Strip control characters (including BEL 0x07 that dvgrab
            # prefixes to damage warnings) and leading/trailing whitespace.
            gsub(/[\x00-\x1F]/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line == "") continue

            # Suppress the boilerplate explanation line that dvgrab emits
            # after every damage warning -- it adds no information.
            if (line == "This means that there were missing or invalid FireWire packets.") continue

            # ------------------------------------------------------------------
            # Critical lines: wrap errors and warnings in a visible banner.
            # Lifecycle messages (Capture Start/Stop, Autosplit) pass through
            # without a banner as they are informational, not alerts.
            # Deduplication uses a stable key with timecode/date stripped so
            # that BEL prefix differences and garbage timestamp variations
            # do not cause the same logical warning to appear multiple times.
            # ------------------------------------------------------------------
            if (line ~ /(damaged|missing|invalid|[Ee]rror|Warning:|Autosplit|Capture Start|Capture Stop)/) {
                if (line ~ /(damaged|missing|invalid|[Ee]rror|Warning:)/) {
                    key = line
                    gsub(/ timecode [^ ]+/, "", key)
                    gsub(/ date [0-9.]+[[:space:]]+[0-9:]+/, "", key)
                    if (!(key in warned)) {
                        warned[key] = 1
                        print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        print "!!! " line
                        print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        fflush()
                    }
                } else {
                    # Emit closing segment summary before Capture Stop message
                    if (tape_type == "dv" && line ~ /Capture Stop/ && last_fname != "") {
                        seg_elapsed = now - segment_start_time
                        seg_path = output_dir "/" last_fname
                        seg_bytes = 0
                        cmd = "stat -c%s \"" seg_path "\" 2>/dev/null"
                        if ((cmd | getline seg_bytes) > 0 && seg_bytes > 0) {
                            seg_mib = sprintf("%.2f", seg_bytes / 1048576)
                            if (seg_elapsed > 0)
                                seg_mbps = sprintf("%.2f", (seg_bytes * 8) / seg_elapsed / 1000000)
                            else
                                seg_mbps = "N/A"
                        } else {
                            seg_mib = last_size_mib
                            seg_mbps = "N/A"
                        }
                        close(cmd)
                        print ">>> SEGMENT DONE: " last_fname " | " seg_mib " MiB | " seg_mbps " Mbps"
                        fflush()
                    }
                    print line; fflush()
                }
                continue
            }

            # ------------------------------------------------------------------
            # For Digital8: detect when dvgrab opens a new segment file due to
            # autosplit and announce it clearly so the operator knows a new
            # recording session has started on the tape.
            # This check runs before the frame-count check so that a line
            # containing both a filename and a frame count (which dvgrab emits
            # on the very first frame of a new segment) correctly announces the
            # new file AND is then also processed for progress below.
            # ------------------------------------------------------------------
            if (tape_type == "dv" && line ~ /\.dv":/) {
                fname = line
                gsub(/.*\//, "", fname)
                gsub(/".*/, "", fname)
                if (fname != last_fname && fname != "") {
                    if (last_fname != "") {
                        # The previous segment file is now fully closed.
                        # Use stat on the exact filename for accurate final size,
                        # and wall-clock time since that segment opened for duration.
                        seg_elapsed = now - segment_start_time
                        seg_path = output_dir "/" last_fname
                        seg_bytes = 0
                        cmd = "stat -c%s \"" seg_path "\" 2>/dev/null"
                        if ((cmd | getline seg_bytes) > 0 && seg_bytes > 0) {
                            seg_mib = sprintf("%.2f", seg_bytes / 1048576)
                            if (seg_elapsed > 0)
                                seg_mbps = sprintf("%.2f", (seg_bytes * 8) / seg_elapsed / 1000000)
                            else
                                seg_mbps = "N/A"
                        } else {
                            seg_mib = last_size_mib
                            seg_mbps = "N/A"
                        }
                        close(cmd)
                        print ">>> SEGMENT DONE: " last_fname " | " seg_mib " MiB | " seg_mbps " Mbps"
                        prev_segments_mib += last_size_mib
                    }
                    last_printed      = -1
                    segment_start_time = now
                    segment_start_mib  = prev_segments_mib
                    print "---------------------------------------------------------"
                    print ">>> NEW SEGMENT: " fname
                    print "---------------------------------------------------------"
                    fflush()
                    last_fname = fname
                }
                if (line !~ /frames/) continue
            }

            # ------------------------------------------------------------------
            # Progress lines: extract frame count, apply stall detection
            # and interval sampling, annotate with position and bitrate.
            # Timecode and date fields are stripped on Hi8 analog tapes
            # because they are always garbage (e.g. 45:85:85.45, 2067.02.15)
            # and add no useful information to the output.
            # ------------------------------------------------------------------
            if (match(line, /([0-9]+)[[:space:]]+frames/, m)) {
                frame_count = m[1]
                now = systime()

                # Start the wall clock on the very first frame, not at awk
                # BEGIN. BEGIN runs before dvgrab finds the device and waits
                # for DV signal -- including that pre-capture delay in
                # elapsed_sec inflates the denominator and deflates bitrate.
                if (last_frame_seen < 0) {
                    capture_start_time = now
                    segment_start_time = now
                }

                # Stall detection: == avoids false positives when dvgrab
                # briefly repeats a frame count at segment boundaries.
                if (last_frame_seen >= 0 && frame_count == last_frame_seen) {
                    if (now - last_progress_time >= stall_sec) {
                        printf "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"
                        printf "!!! WARNING: Capture stalled -- no frame progress for ~%ds\n", now - last_progress_time
                        printf "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"
                        fflush()
                        last_progress_time = now
                    }
                } else {
                    last_progress_time = now
                }
                last_frame_seen = frame_count

                # If running in Hi8 mode but the tape has valid timecodes,
                # warn once that Digital8 mode (-t dv) would be more appropriate.
                if (tape_type == "hi8" && !hi8_valid_tc_warned) {
                    if (line ~ /timecode ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\./) {
                        print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        print "!!! WARNING: Valid timecodes detected on this tape."
                        print "!!! This may be a Digital8 tape. Re-capture with -t dv"
                        print "!!! to split files by filming date for chronological sorting."
                        print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        fflush()
                        hi8_valid_tc_warned = 1
                    }
                }

                # Sample at interval, always print first line
                if (last_printed < 0 || frame_count - last_printed >= interval) {
                    # total_sec: frame-derived tape position, used for the
                    # DV timecode display and Hi8 elapsed-position display.
                    # It resets at segment boundaries so must NOT be used
                    # as the bitrate denominator in multi-segment captures.
                    total_sec = int(frame_count * 1001 / 30000)
                    h  = int(total_sec / 3600)
                    m_ = int((total_sec % 3600) / 60)
                    s  = total_sec % 60

                    # Wall-clock elapsed time used as the bitrate denominator.
                    # frame_count resets to zero at each autosplit segment
                    # boundary, so total_sec derived from it underestimates
                    # the true elapsed time once a second segment is open,
                    # causing the reported bitrate to collapse. Wall-clock
                    # time is monotonically increasing and correctly reflects
                    # the full capture duration across all segments.
                    elapsed_sec = now - capture_start_time

                    if (tape_type == "dv") {
                        # For Digital8: timecodes are valid so use them directly
                        # as the position reference. Include the current segment
                        # filename so the operator can see which file is being
                        # written without waiting for the next NEW SEGMENT banner.
                        # dvgrab MiB value is cumulative across all segments so
                        # we use it directly for bitrate rather than calling stat,
                        # avoiding all shell glob quoting issues entirely.
                        size_mib = "?"
                        tc = "?"
                        if (match(line, /([0-9.]+) MiB/, a))  size_mib = a[1]
                        if (match(line, /timecode ([0-9:]+\.[0-9]+)/, a)) tc = a[1]
                        if (size_mib != "?") last_size_mib = size_mib + 0
                        printf "[PROGRESS %s | %s | %s MiB]\n", tc, last_fname, size_mib
                    } else {
                        # For Hi8: strip garbage timecode/date. dvgrab MiB
                        # value used directly for bitrate -- no glob needed.
                        hi8_size_mib = "?"
                        if (match(line, /([0-9.]+) MiB/, a)) hi8_size_mib = a[1]
                        bitrate_mbps = "N/A"
                        if (elapsed_sec > 5 && hi8_size_mib != "?")
                            bitrate_mbps = sprintf("%.2f", (hi8_size_mib * 1048576 * 8) / elapsed_sec / 1000000)
                        clean = line
                        if (clean ~ /timecode [0-9]{2}:[8-9][0-9]:[8-9][0-9]/) {
                            gsub(/ timecode [^ ]+/, "", clean)
                            gsub(/ date [0-9]+\.[0-9]+\.[0-9]+ [0-9:]+/, "", clean)
                        }
                        printf "[PROGRESS ~%d:%02d:%02d | %s Mbps] %s\n", h, m_, s, bitrate_mbps, clean
                    }
                    fflush()
                    last_printed = frame_count
                }
                continue
            }

            # Pass through everything else (device init messages, etc.)
            print line; fflush()
        }
    }
' | tee -a "$LOG_FILE" || true

# ==============================================================================
# 8. Post-Capture Integrity Audit
# ==============================================================================
# For Hi8 there is normally one file (two if dvgrab autosplit on signal loss).
# For Digital8 there can be dozens of segment files. We audit every file,
# accumulate total duration and size, flag any individual file whose bitrate
# is suspiciously low, and print a combined summary at the end.
# ==============================================================================
printf '\a'
echo "---------------------------------------------------------"
echo "RUNNING DATA INTEGRITY AUDIT..."

# nullglob prevents the glob literal being passed as a filename if no .dv
# files exist. The array then reliably holds zero or more actual paths.
shopt -s nullglob
DV_FILES=("$OUTPUT_DIR"/*.dv)
shopt -u nullglob

if [ "${#DV_FILES[@]}" -eq 0 ]; then
    echo "[ERROR] No DV file was generated. Check $LOG_FILE" | tee -a "$LOG_FILE"
    exit 1
fi

# Accumulators for the combined summary
TOTAL_DURATION_SEC=0
TOTAL_SIZE_BYTES=0
WARN_COUNT=0
FFPROBE_FALLBACK_NOTED=0

{
    echo "DATA INTEGRITY AUDIT: $BASE_NAME"
    echo "Generated: $(date)"
    echo "Files: ${#DV_FILES[@]}"
    echo "---------------------------------------------------------"

    # Sort files lexicographically -- DV segment filenames embed the filming
    # date (dv_YYYY.MM.DD_HH-MM-SS.dv) so lex order == chronological order.
    # Hi8 files use a session-date prefix and a numeric suffix (001, 002...)
    # which also sorts correctly lexicographically.
    for AVI_FILE in $(printf '%s\n' "${DV_FILES[@]}" | sort); do

        # Extract only duration= and bit_rate= lines, discarding dvvideo
        # decoder warnings (AC EOB marker, Concealing bitstream errors) that
        # appear at the start of analog Hi8 tapes due to garbage timecode in
        # the tape leader.
        STATS=$(ffprobe -v error -show_entries format=duration,bit_rate \
            -of default=noprint_wrappers=1 "$AVI_FILE" 2>&1 \
            | grep -E '^(duration|bit_rate)')

        BITRATE=$(echo "$STATS" | grep "^bit_rate" | cut -d= -f2 || echo "N/A")
        DURATION=$(echo "$STATS" | grep "^duration" | cut -d= -f2 || echo "0")

        BITRATE="${BITRATE:-N/A}"
        DURATION="${DURATION:-0}"

        FILE_SIZE=$(stat -c%s "$AVI_FILE")
        TOTAL_SIZE_BYTES=$(( TOTAL_SIZE_BYTES + FILE_SIZE ))

        # Guard: ffprobe often returns N/A for bit_rate on DV/AVI containers.
        # Fall back to manual calculation from file size and duration.
        if [[ "$BITRATE" == "N/A" || "$BITRATE" == "0" ]]; then
            if [[ "$DURATION" == "0" || "$DURATION" == "N/A" ]]; then
                BITRATE_MBPS="0"
            else
                BITRATE=$(echo "scale=0; ($FILE_SIZE * 8) / $DURATION" | bc)
                BITRATE_MBPS=$(echo "scale=2; $BITRATE / 1000000" | bc)
                if [[ "$FFPROBE_FALLBACK_NOTED" -eq 0 ]]; then
                    echo "[INFO] Bitrate calculated from file size (ffprobe returned N/A -- normal for DV)."
                    FFPROBE_FALLBACK_NOTED=1
                fi
            fi
        else
            BITRATE_MBPS=$(echo "scale=2; $BITRATE / 1000000" | bc)
        fi

        # Accumulate valid durations into total
        if [[ "$DURATION" != "0" && "$DURATION" != "N/A" ]]; then
            DURATION_INT=${DURATION%.*}
            TOTAL_DURATION_SEC=$(( TOTAL_DURATION_SEC + DURATION_INT ))
            DURATION_HMS=$(printf '%d:%02d:%02d' \
                $((DURATION_INT / 3600)) \
                $(((DURATION_INT % 3600) / 60)) \
                $((DURATION_INT % 60)))
        else
            DURATION_HMS="?"
        fi

        # Per-file line: flag low-bitrate files inline with [!!!]
        # DV NTSC standard is ~25 Mbps video + ~1.5 Mbps PCM audio = ~28.5 Mbps total.
        # Below 28.0 Mbps suggests dropped frames or a degraded stream.
        if [[ "$BITRATE_MBPS" == "0" ]]; then
            printf "  [???] %-45s  duration=%-9s  bitrate=unknown\n" \
                "$(basename "$AVI_FILE")" "$DURATION_HMS"
            (( WARN_COUNT++ )) || true
        elif (( $(echo "$BITRATE_MBPS < 28.0" | bc -l) )); then
            printf "  [!!!] %-45s  duration=%-9s  bitrate=%s Mbps  LOW\n" \
                "$(basename "$AVI_FILE")" "$DURATION_HMS" "$BITRATE_MBPS"
            (( WARN_COUNT++ )) || true
        else
            printf "  [OK]  %-45s  duration=%-9s  bitrate=%s Mbps\n" \
                "$(basename "$AVI_FILE")" "$DURATION_HMS" "$BITRATE_MBPS"
        fi
    done

    echo "---------------------------------------------------------"

    # Combined summary
    TOTAL_HMS=$(printf '%d:%02d:%02d' \
        $((TOTAL_DURATION_SEC / 3600)) \
        $(((TOTAL_DURATION_SEC % 3600) / 60)) \
        $((TOTAL_DURATION_SEC % 60)))
    TOTAL_GiB=$(echo "scale=2; $TOTAL_SIZE_BYTES / 1073741824" | bc)
    # Overall bitrate from totals (more stable than averaging per-file rates)
    if [[ "$TOTAL_DURATION_SEC" -gt 0 ]]; then
        OVERALL_MBPS=$(echo "scale=2; ($TOTAL_SIZE_BYTES * 8) / $TOTAL_DURATION_SEC / 1000000" | bc)
    else
        OVERALL_MBPS="N/A"
    fi

    echo "Total duration: ${TOTAL_HMS}  |  Total size: ${TOTAL_GiB} GiB  |  Overall bitrate: ${OVERALL_MBPS} Mbps"
    echo ""
    if [[ "$WARN_COUNT" -eq 0 ]]; then
        echo "[SUCCESS] All ${#DV_FILES[@]} file(s) passed integrity check."
    else
        echo "[!!!] WARNING: ${WARN_COUNT} file(s) flagged above. Check $LOG_FILE for dropped frames."
    fi
    echo "---------------------------------------------------------"

} | tee -a "$LOG_FILE"

# ==============================================================================
# 9. Recording Date Analysis
# ==============================================================================
# For Digital8: filming dates are embedded in the DV filenames by dvgrab
# (e.g. test_2012.12.25_06-58-41.dv) so we extract them directly from the
# filenames -- no log parsing needed and no awk-emitted date lines required.
#
# For Hi8: filenames use the capture session date, not the filming date, so
# we fall back to the log which contains raw dvgrab status lines. On analog
# Hi8 all dates will be garbage (e.g. 2067) and are filtered out -- expected.
# ==============================================================================
echo "---------------------------------------------------------"
echo "ANALYSING RECORDING DATES..."

if [[ "$TAPE_TYPE" == "dv" ]]; then
    # Extract YYYY.MM.DD from DV filenames. DV filenames use the filming
    # date from the DV stream directly so no year filtering is needed --
    # the dates are trustworthy unlike Hi8 timecodes.
    VALID_DATES=$(printf '%s\n' "${DV_FILES[@]}" \
        | grep -oE '[0-9]{4}\.[0-9]{2}\.[0-9]{2}' \
        | sort -u)

    if [[ -n "$VALID_DATES" ]]; then
        DATE_COUNT=$(echo "$VALID_DATES" | wc -l)
        {
            echo "RECORDING DATE REPORT: $BASE_NAME"
            echo "Generated: $(date)"
            echo "---------------------------------------------------------"
            echo "Unique recording dates found on tape:"
            echo "$VALID_DATES" | while read -r d; do echo "  $d"; done
            echo ""
            echo "Total unique dates: $DATE_COUNT"
            echo "---------------------------------------------------------"
        } | tee "$DATE_REPORT"
    else
        echo "[WARNING] Digital8 mode but no valid recording dates found in filenames."
        echo "          The DV stream may have incomplete timecode data."
    fi

else
    # Hi8: extract dates from log (all will likely be garbage and filtered out)
    if [ -f "$LOG_FILE" ]; then
        VALID_DATES=$(grep -oE 'date [0-9]{4}\.[0-9]{2}\.[0-9]{2}' "$LOG_FILE" \
            | cut -d' ' -f2 \
            | awk -F. '$1 >= 1980 && $1 <= 2010' \
            | sort -u)

        if [[ -n "$VALID_DATES" ]]; then
            DATE_COUNT=$(echo "$VALID_DATES" | wc -l)
            FIRST_STAMP=$(grep -oE 'date [0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_FILE" \
                | cut -d' ' -f2-3 \
                | awk -F'[. ]' '$1 >= 1980 && $1 <= 2010' | head -1)
            LAST_STAMP=$(grep -oE 'date [0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_FILE" \
                | cut -d' ' -f2-3 \
                | awk -F'[. ]' '$1 >= 1980 && $1 <= 2010' | tail -1)
            {
                echo "RECORDING DATE REPORT: $BASE_NAME"
                echo "Generated: $(date)"
                echo "---------------------------------------------------------"
                echo "Unique recording dates found on tape:"
                echo "$VALID_DATES" | while read -r d; do echo "  $d"; done
                echo ""
                echo "Total unique dates: $DATE_COUNT"
                echo "First valid timestamp: $FIRST_STAMP"
                echo "Last valid timestamp:  $LAST_STAMP"
                echo "---------------------------------------------------------"
                echo "NOTE: Dates outside 1980-2010 were filtered as garbage timecode."
                echo "      If your tape predates 1980 or postdates 2010, edit the"
                echo "      year range filter in the script."
            } | tee "$DATE_REPORT"
        else
            echo "[INFO] No valid recording dates found in log."
            echo "       This is expected for analog Hi8 tapes -- they have no internal"
            echo "       clock, so dvgrab reports garbage timecodes (e.g. 2067) which"
            echo "       are correctly filtered out. Your capture is not affected."
            echo "[INFO] No valid recording dates found (analog Hi8 -- expected)." >> "$LOG_FILE"
        fi
    else
        echo "[WARNING] Log file not found. Cannot analyse recording dates."
    fi
fi

echo "---------------------------------------------------------"
echo "Done."
echo "Log:         $LOG_FILE"
if [ -f "$DATE_REPORT" ]; then
    echo "Date report: $DATE_REPORT"
fi

} # end main()

main "$@"
