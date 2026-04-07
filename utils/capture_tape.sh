#!/bin/bash
# ==============================================================================
# Script Name: capture_tape.sh v33
# Optimized for: Sony DCR-TRV330 (Hi8/Digital8) & LSI FireWire Chipsets
# ==============================================================================
# CONFIGURATION REQUIRED:
# Set CAPTURE_ROOT to the absolute path where captured files will be stored.
# This directory must exist and be writable before running this script.
# Example: /mnt/video_capture/avi/captures
# Do NOT use relative paths (./captures) as dvgrab will fail to create files.
# Override at runtime with: -o /path/to/output
# ==============================================================================
#
# CHANGE LOG:
#   v34 -- Fixed integrity audit examining only the last AVI file. Now loops
#          over all segment files in chronological order, reports per-file
#          duration and bitrate with [OK]/[!!!]/[???] flags, and prints a
#          combined total duration, size, and overall bitrate at the end.
#          The ffprobe N/A fallback note is emitted once rather than per file.
#          Date analysis was already correct -- it reads the log, which is
#          fully populated now that the v32 subline fix is in place.
#
#   v33 -- Fixed awk stat glob quoting. The bitrate calculation used:
#            stat -c%s "prefix"*.avi
#          which breaks when OUTPUT_DIR contains spaces because the quote
#          boundary prevented shell glob expansion. Now wrapped in sh -c:
#            sh -c 'stat -c%s "prefix"*.avi'
#          so the shell handles glob expansion inside a properly quoted string.
#
#   v32 -- Merge of v18 (production) + v31 awk subline fix.
#          The awk record splitter now iterates over \n-delimited sublines
#          within each \r-delimited dvgrab record. This fixes progress output
#          stopping after the first AVI segment closes: dvgrab emits a
#          newline-terminated filename announcement mixed into its \r stream,
#          which in v18 caused the frame-count regex to miss the next record
#          and silently stop updating last_printed. No other behaviour changed.
#          Improved usage/help with concrete filename examples.
#
#   v18 -- Stable production release. RS="\r" awk filter, stall detection,
#          real-time bitrate, Hi8 valid-timecode warning, integrity audit,
#          recording date analysis.
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
CAPTURE_ROOT="/mnt/video_capture/avi/captures"

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
    echo "                       e.g. dv_1997.08.03_14.23.11.avi"
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
    echo "      <TAPE_ID>[_<DESCRIPTION>]_<YYYYMMDD_HHMM>001.avi"
    echo "    If the signal drops and dvgrab autosplits, a second file appears:"
    echo "      <TAPE_ID>[_<DESCRIPTION>]_<YYYYMMDD_HHMM>002.avi"
    echo "    Hi8 has no internal clock so filenames use the CAPTURE date."
    echo ""
    echo "    Example: $0 hi8_20040107-20040207 'Christmas 2004'"
    echo "      Directory: ${CAPTURE_ROOT}/hi8_20040107-20040207_Christmas_2004_20260406_1347/"
    echo "      File(s):   hi8_20040107-20040207_Christmas_2004_20260406_1347001.avi"
    echo "                 hi8_20040107-20040207_Christmas_2004_20260406_1347002.avi  (if autosplit)"
    echo ""
    echo "    Example: $0 hi8_20040107-20040207"
    echo "      Directory: ${CAPTURE_ROOT}/hi8_20040107-20040207_20260406_1347/"
    echo "      File(s):   hi8_20040107-20040207_20260406_1347001.avi"
    echo ""
    echo "  Digital8 mode (-t dv):"
    echo "    One file per recording segment, named using the FILMING date embedded"
    echo "    in the DV stream so files sort chronologically by content."
    echo "    Files inside the session directory are named by dvgrab as:"
    echo "      <TAPE_ID>_<YYYY.MM.DD_HH-MM-SS>.avi"
    echo "    If the same filming date appears in multiple segments, dvgrab appends"
    echo "    a counter: <TAPE_ID>_<date>-1.avi, <TAPE_ID>_<date>-2.avi, etc."
    echo ""
    echo "    Example: $0 -t dv dv_20040107-20040207"
    echo "      Directory: ${CAPTURE_ROOT}/dv_20040107-20040207_20260406_1347/"
    echo "      File(s):   dv_20040107-20040207_2004.01.07_14-23-11.avi"
    echo "                 dv_20040107-20040207_2004.01.15_09-05-44.avi"
    echo "                 dv_20040107-20040207_2004.02.07_18-30-00.avi"
    echo ""
    echo "    Example: $0 -t dv dv"
    echo "      Directory: ${CAPTURE_ROOT}/dv_20260406_1802/"
    echo "      File(s):   dv_2004.05.02_16-52-12.avi"
    echo "                 dv_2004.05.15_11-04-33.avi"
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
    echo "IMPORTANT: Default CAPTURE_ROOT is hardcoded in this script as:"
    echo "  ${CAPTURE_ROOT}"
    echo "  Edit the CAPTURE_ROOT variable at the top of the script to change it."
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
if [ ! -d "$CAPTURE_ROOT" ]; then
    echo "[ERROR] CAPTURE_ROOT does not exist: $CAPTURE_ROOT"
    echo "        Create it with: mkdir -p $CAPTURE_ROOT"
    echo "        Or specify a different path with: -o /path/to/output"
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
echo "ARCHIVAL INGEST: $BASE_NAME"
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

# ==============================================================================
# 6. Flag Configuration (Bash Array)
# ==============================================================================
if [[ "$TAPE_TYPE" == "dv" ]]; then
    # Digital8: --timestamp names each file using the filming date embedded
    # in the DV stream so files sort chronologically by when content was filmed.
    # --size 0 disables 1GB size-based splitting while preserving autosplit
    # on timecode discontinuities and signal loss.
    FLAGS=(
        --format dv1     # Type 1 AVI -- matches existing Digital8 captures
                         # for checksum comparison. dv1 stores a single
                         # integrated DV track (vs dv2 which adds a separate
                         # audio track). Use dv2 if compatibility with other
                         # tools is needed.
        --size 0         # allow files >1GB
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
        --format dv2
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
# giving files like "dv_1997.08.03_14.23.11.avi" that sort by content date.
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
#     "/path/to/new_segment.avi":\n   123 frames timecode ... date ...
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
      -v stall_sec="$STALL_TIMEOUT_SEC" \
      -v tape_type="$TAPE_TYPE" '
    BEGIN {
        RS = "\r"
        last_printed        = -1
        last_frame_seen     = -1
        last_progress_time  = systime()
        hi8_valid_tc_warned = 0
        last_fname          = ""
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
                    print line; fflush()
                }
                continue
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
                    total_sec = int(frame_count * 1001 / 30000)
                    h  = int(total_sec / 3600)
                    m_ = int((total_sec % 3600) / 60)
                    s  = total_sec % 60

                    # Real-time bitrate from cumulative size of ALL segment
                    # files -- accurate across autosplits, stable at boundaries.
                    bitrate_mbps = "N/A"
                    if (total_sec > 5) {
                        filesize = 0
                        cmd = "sh -c 'stat -c%s \"" outfile_prefix "\"*.avi 2>/dev/null'"
                        while ((cmd | getline sz) > 0) filesize += sz
                        close(cmd)
                        if (filesize > 0)
                            bitrate_mbps = sprintf("%.2f", (filesize * 8) / total_sec / 1000000)
                    }

                    if (tape_type == "dv") {
                        # For Digital8: timecodes are valid so use them directly
                        # as the position reference. Extract size and timecode
                        # from the line and format a compact progress line without
                        # the filename (which changes on every autosplit and would
                        # be stale after the first segment).
                        size_mib = "?"
                        tc = "?"
                        if (match(line, /([0-9.]+) MiB/, a))  size_mib = a[1]
                        if (match(line, /timecode ([0-9:]+\.[0-9]+)/, a)) tc = a[1]
                        printf "[PROGRESS %s | %s MiB | %s Mbps]\n", tc, size_mib, bitrate_mbps
                    } else {
                        # For Hi8: strip garbage timecode/date, keep the rest
                        # of the line for context since there is only one file
                        # and no valid timecode.
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

            # ------------------------------------------------------------------
            # For Digital8: detect when dvgrab opens a new segment file due to
            # autosplit and announce it clearly so the operator knows a new
            # recording session has started on the tape.
            # ------------------------------------------------------------------
            if (tape_type == "dv" && line ~ /\.avi":/ && line !~ /frames/) {
                fname = line
                gsub(/.*\//, "", fname)   # strip path, keep filename
                gsub(/".*/, "", fname)    # strip trailing quote and anything after
                if (fname != last_fname && fname != "") {
                    print "---------------------------------------------------------"
                    print ">>> NEW SEGMENT: " fname
                    print "---------------------------------------------------------"
                    fflush()
                    last_fname = fname
                }
                continue
            }

            # Pass through everything else (device init messages, etc.)
            print line; fflush()
        }
    }
' | tee "$LOG_FILE" || true

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

# nullglob prevents the glob literal being passed as a filename if no .avi
# files exist. The array then reliably holds zero or more actual paths.
shopt -s nullglob
AVI_FILES=("$OUTPUT_DIR"/*.avi)
shopt -u nullglob

if [ "${#AVI_FILES[@]}" -eq 0 ]; then
    echo "[ERROR] No AVI file was generated. Check $LOG_FILE" | tee -a "$LOG_FILE"
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
    echo "Files: ${#AVI_FILES[@]}"
    echo "---------------------------------------------------------"

    # Sort files lexicographically -- DV segment filenames embed the filming
    # date (dv_YYYY.MM.DD_HH-MM-SS.avi) so lex order == chronological order.
    # Hi8 files use a session-date prefix and a numeric suffix (001, 002...)
    # which also sorts correctly lexicographically.
    for AVI_FILE in $(printf '%s\n' "${AVI_FILES[@]}" | sort); do

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
                    echo "[INFO] Bitrate calculated from file size (ffprobe returned N/A -- normal for DV/AVI)."
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
        echo "[SUCCESS] All ${#AVI_FILES[@]} file(s) passed integrity check."
    else
        echo "[!!!] WARNING: ${WARN_COUNT} file(s) flagged above. Check $LOG_FILE for dropped frames."
    fi
    echo "---------------------------------------------------------"

} | tee -a "$LOG_FILE"

# ==============================================================================
# 9. Recording Date Analysis
# ==============================================================================
# dvgrab writes lines like:
#   "file001.avi": 30.75 MiB 254 frames timecode 00:00:10.15 date 1995.07.28 14:23:11
# We extract dates, filter to valid years (1980-2010), deduplicate, and report.
# Analog Hi8 tapes have no internal clock so all dates will be garbage (e.g. 2067)
# and will be filtered out -- this is expected and the warning reflects that.
echo "---------------------------------------------------------"
echo "ANALYSING RECORDING DATES..."

if [ -f "$LOG_FILE" ]; then
    # Extract all dates in YYYY.MM.DD format, filter to sane year range.
    # grep -oE is portable (no PCRE required); cut trims the "date " prefix.
    VALID_DATES=$(grep -oE 'date [0-9]{4}\.[0-9]{2}\.[0-9]{2}' "$LOG_FILE" \
        | cut -d' ' -f2 \
        | awk -F. '$1 >= 1980 && $1 <= 2010' \
        | sort -u)

    if [[ -n "$VALID_DATES" ]]; then
        DATE_COUNT=$(echo "$VALID_DATES" | wc -l)

        # First and last valid full timestamps
        FIRST_STAMP=$(grep -oE 'date [0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_FILE" \
            | cut -d' ' -f2-3 \
            | awk -F'[. ]' '$1 >= 1980 && $1 <= 2010' | head -1)
        LAST_STAMP=$(grep -oE 'date [0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_FILE" \
            | cut -d' ' -f2-3 \
            | awk -F'[. ]' '$1 >= 1980 && $1 <= 2010' | tail -1)

        # Build the report -- write to both terminal and date report file
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
        if [[ "$TAPE_TYPE" == "dv" ]]; then
            echo "[WARNING] Digital8 mode but no valid recording dates found in log."
            echo "          The DV stream may have incomplete timecode data."
        else
            echo "[INFO] No valid recording dates found in log."
            echo "       This is expected for analog Hi8 tapes -- they have no internal"
            echo "       clock, so dvgrab reports garbage timecodes (e.g. 2067) which"
            echo "       are correctly filtered out. Your capture is not affected."
            echo "[INFO] No valid recording dates found (analog Hi8 -- expected)." >> "$LOG_FILE"
        fi
    fi
else
    echo "[WARNING] Log file not found. Cannot analyse recording dates."
fi

echo "---------------------------------------------------------"
echo "Done."
echo "Log:         $LOG_FILE"
if [ -f "$DATE_REPORT" ]; then
    echo "Date report: $DATE_REPORT"
fi

} # end main()

main "$@"
