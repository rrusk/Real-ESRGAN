#!/bin/bash
# ==============================================================================
# Script Name: capture_tape.sh v18 - Final Production Archival Ingest
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
    echo "Usage: $0 [-o OUTPUT_DIR] <TAPE_ID> [DESCRIPTION]"
    echo ""
    echo "  -o OUTPUT_DIR  Optional. Override the default capture root."
    echo "                 Default: ${CAPTURE_ROOT}"
    echo "  TAPE_ID        Required. A short unique identifier for the tape."
    echo "                 Spaces are allowed and will be converted to underscores."
    echo "  DESCRIPTION    Optional. Additional context appended to the filename."
    echo ""
    echo "Examples:"
    echo "  $0 TAPE01"
    echo "     -> ${CAPTURE_ROOT}/TAPE01_20250319_1430/TAPE01_20250319_1430001.avi"
    echo ""
    echo "  $0 '1995 Summer Vacation'"
    echo "     -> ${CAPTURE_ROOT}/1995_Summer_Vacation_20250319_1430/1995_Summer_Vacation_20250319_1430001.avi"
    echo ""
    echo "  $0 BOX2_TAPE04 'Christmas 1998'"
    echo "     -> ${CAPTURE_ROOT}/BOX2_TAPE04_Christmas_1998_20250319_1430/BOX2_TAPE04_Christmas_1998_20250319_1430001.avi"
    echo ""
    echo "  $0 -o /tmp/test TAPE01 'Summer 1995'"
    echo "     -> /tmp/test/TAPE01_Summer_1995_20250319_1430/TAPE01_Summer_1995_20250319_1430001.avi"
    echo ""
    echo "Notes:"
    echo "  - Spaces are converted to underscores automatically."
    echo "  - Special characters are stripped for filesystem safety."
    echo "  - Capture date is appended so repeat captures don't overwrite each other."
    echo "  - Output files are placed in CAPTURE_ROOT/<n>/ with a matching log."
    echo "  - For Digital8 tapes, the original filming date is preserved inside"
    echo "    the DV stream and can be extracted later with dvgrab or ffprobe."
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
while getopts ":o:" opt; do
    case $opt in
        o)
            CAPTURE_ROOT="$OPTARG"
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
# Note: --timestamp intentionally omitted. SESSION_DATE in BASE_NAME records
# the capture date instead. For analog Hi8 (1993-2003) there is no internal
# tape date anyway. For Digital8, the original filming date is preserved
# inside the DV stream and can be extracted later with dvgrab or ffprobe.
FLAGS=(
    --format dv2     # Type 2 AVI (Standard for FFmpeg/AI pipeline)
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

# Output file prefix passed to awk for real-time bitrate estimation.
OUTPUT_FILE_PREFIX="$OUTPUT_DIR/${BASE_NAME}"

# Seconds without frame progress before a stall warning is emitted.
STALL_TIMEOUT_SEC=120

# dvgrab --showstatus uses \r to overwrite the terminal line in place,
# producing a stream of \r-separated records with no \n between them.
# RS="\r" in awk BEGIN makes it correctly split on carriage returns
# before any rule runs -- split($0,...,"\r") failed because the entire
# stream arrived as one \n-terminated blob.
#
# Features:
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
      -v stall_sec="$STALL_TIMEOUT_SEC" '
    BEGIN {
        RS = "\r"
        last_printed       = -1
        last_frame_seen    = -1
        last_progress_time = systime()
    }
    {
        # RS="\r" splits on carriage returns before any rule runs, so each
        # dvgrab status update arrives as its own record. Strip whitespace,
        # control characters (including BEL 0x07 that dvgrab prefixes to
        # damage warnings), and skip blank records.
        line = $0
        gsub(/[\x00-\x1F]/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line == "") next

        # Suppress the boilerplate explanation line that dvgrab emits after
        # every damage warning -- it adds no information and breaks dedup.
        if (line == "This means that there were missing or invalid FireWire packets.") next

        # Critical lines: wrap errors and warnings in a visible banner.
        # Lifecycle messages (Capture Start/Stop, Autosplit) pass through
        # without a banner as they are informational, not alerts.
        # Deduplication uses a stable key with timecode/date stripped so
        # that BEL prefix differences and garbage timestamp variations
        # do not cause the same logical warning to appear multiple times.
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
            next
        }

        # Progress lines: extract frame count, apply stall detection
        # and interval sampling, annotate with position and bitrate.
        # Timecode and date fields are stripped -- on Hi8 analog tapes
        # they are always garbage (e.g. 45:85:85.45, 2067.02.15) and
        # add no useful information to the output.
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

            # Sample at interval, always print first line
            if (last_printed < 0 || frame_count - last_printed >= interval) {
                total_sec = int(frame_count * 1001 / 30000)
                h  = int(total_sec / 3600)
                m_ = int((total_sec % 3600) / 60)
                s  = total_sec % 60

                # Strip timecode and date only when they are the Hi8
                # garbage pattern (e.g. 45:85:85.45, date 2067.xx.xx).
                # Valid Digital8 timecodes and dates are preserved.
                clean = line
                if (clean ~ /timecode [0-9]{2}:[8-9][0-9]:[8-9][0-9]/) {
                    gsub(/ timecode [^ ]+/, "", clean)
                    gsub(/ date [0-9]+\.[0-9]+\.[0-9]+ [0-9:]+/, "", clean)
                }

                # Real-time bitrate from cumulative size of ALL segment
                # files -- accurate across autosplits, stable at boundaries.
                bitrate_mbps = "N/A"
                if (total_sec > 5) {
                    filesize = 0
                    cmd = "stat -c%s \"" outfile_prefix "\"*.avi 2>/dev/null"
                    while ((cmd | getline sz) > 0) filesize += sz
                    close(cmd)
                    if (filesize > 0)
                        bitrate_mbps = sprintf("%.2f", (filesize * 8) / total_sec / 1000000)
                }
                printf "[PROGRESS ~%d:%02d:%02d | %s Mbps] %s\n", h, m_, s, bitrate_mbps, clean
                fflush()
                last_printed = frame_count
            }
            next
        }

        # Pass through everything else (device init messages, etc.)
        print line; fflush()
    }
' | tee "$LOG_FILE" || true

# ==============================================================================
# 8. Post-Capture Integrity Audit
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

# ls -t sorts by modification time -- correct for autosplit edge cases where
# lexicographic sort would mis-order file9.avi vs file10.avi.
# Using the array as explicit arguments (not a glob) is a safe use of ls.
LATEST_FILE=$(ls -t -- "${AVI_FILES[@]}" | head -1)

if [ -f "$LATEST_FILE" ]; then

    # Extract only duration= and bit_rate= lines, discarding dvvideo decoder
    # warnings (AC EOB marker, Concealing bitstream errors) that appear at the
    # start of analog Hi8 tapes due to garbage timecode in the tape leader.
    STATS=$(ffprobe -v error -show_entries format=duration,bit_rate \
        -of default=noprint_wrappers=1 "$LATEST_FILE" 2>&1 \
        | grep -E '^(duration|bit_rate)')

    BITRATE=$(echo "$STATS" | grep "^bit_rate" | cut -d= -f2 || echo "N/A")
    DURATION=$(echo "$STATS" | grep "^duration" | cut -d= -f2 || echo "0")

    # Normalise empty strings to sentinel values
    BITRATE="${BITRATE:-N/A}"
    DURATION="${DURATION:-0}"

    # Guard: ffprobe often returns N/A for bit_rate on DV/AVI containers.
    # Fall back to manual calculation from file size and duration.
    if [[ "$BITRATE" == "N/A" || "$BITRATE" == "0" ]]; then
        if [[ "$DURATION" == "0" || "$DURATION" == "N/A" ]]; then
            echo "[WARNING] Could not determine duration or bitrate. File may be empty." | tee -a "$LOG_FILE"
            BITRATE_MBPS="0"
        else
            FILE_SIZE=$(stat -c%s "$LATEST_FILE")
            BITRATE=$(echo "scale=0; ($FILE_SIZE * 8) / $DURATION" | bc)
            BITRATE_MBPS=$(echo "scale=2; $BITRATE / 1000000" | bc)
            echo "[INFO] Bitrate calculated from file size (ffprobe returned N/A -- normal for DV/AVI)." | tee -a "$LOG_FILE"
        fi
    else
        BITRATE_MBPS=$(echo "scale=2; $BITRATE / 1000000" | bc)
    fi

    if [[ "$BITRATE_MBPS" != "0" ]]; then
        # Convert duration to h:mm:ss for readability
        DURATION_INT=${DURATION%.*}
        DURATION_HMS=$(printf '%d:%02d:%02d' \
            $((DURATION_INT / 3600)) \
            $(((DURATION_INT % 3600) / 60)) \
            $((DURATION_INT % 60)))

        {
            echo "DATA INTEGRITY AUDIT: $BASE_NAME"
            echo "Generated: $(date)"
            echo "---------------------------------------------------------"
            echo "File:     $(basename "$LATEST_FILE")"
            echo "Duration: ${DURATION_HMS} (${DURATION}s)"
            echo "Bitrate:  ${BITRATE_MBPS} Mbps"
            # DV NTSC standard is ~25 Mbps video + ~1.5 Mbps PCM audio = ~28.5 Mbps total
            # Below 28.0 Mbps suggests dropped frames or a degraded stream
            if (( $(echo "$BITRATE_MBPS < 28.0" | bc -l) )); then
                echo "[!!!] WARNING: Low bitrate. Check $LOG_FILE for dropped frames."
            else
                echo "[SUCCESS] High-integrity capture confirmed."
            fi
            echo "---------------------------------------------------------"
        } | tee -a "$LOG_FILE"
    fi
fi

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
        echo "[INFO] No valid recording dates found in log."
        echo "       This is expected for analog Hi8 tapes -- they have no internal"
        echo "       clock, so dvgrab reports garbage timecodes (e.g. 2067) which"
        echo "       are correctly filtered out. Your capture is not affected."
        echo "[INFO] No valid recording dates found (analog Hi8 -- expected)." >> "$LOG_FILE"
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
