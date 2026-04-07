#!/bin/bash
# ==============================================================================
# Script Name: audit_capture.sh v1
# Purpose:     Stand-alone integrity audit and recording date analysis for an
#              existing dvgrab capture directory.
#              Replicates sections 8 and 9 of capture_tape.sh v34 so that
#              captures made with older script versions can be re-audited.
# Usage:       audit_capture.sh <CAPTURE_DIR>
# Example:     audit_capture.sh /mnt/video_capture/avi/captures/dv_20260406_1802
# ==============================================================================

set -uo pipefail

for cmd in ffprobe bc; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[ERROR] Required command not found: $cmd"
        echo "        Install it and retry."
        exit 1
    }
done

usage() {
    echo ""
    echo "Usage: $0 <CAPTURE_DIR>"
    echo ""
    echo "  CAPTURE_DIR  Path to an existing dvgrab capture directory."
    echo "               Must contain one or more .avi files."
    echo ""
    echo "  The directory may optionally contain a .log file from the original"
    echo "  capture session. If present, it is used for recording date analysis."
    echo "  If absent, dates are extracted directly from the AVI filenames"
    echo "  (Digital8 only -- Hi8 filenames do not encode recording dates)."
    echo ""
    echo "Output files written into CAPTURE_DIR:"
    echo "  <dirname>.audit.txt   Per-file and summary bitrate/duration report."
    echo "  <dirname>.dates.txt   Unique recording dates found on the tape."
    echo "                        Overwrites any existing .dates.txt from capture."
    echo ""
}

if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    [ "$#" -lt 1 ] && exit 1 || exit 0
fi

CAPTURE_DIR="${1%/}"   # strip any trailing slash

if [ ! -d "$CAPTURE_DIR" ]; then
    echo "[ERROR] Directory not found: $CAPTURE_DIR"
    exit 1
fi

BASE_NAME=$(basename "$CAPTURE_DIR")
AUDIT_REPORT="${CAPTURE_DIR}/${BASE_NAME}.audit.txt"
DATE_REPORT="${CAPTURE_DIR}/${BASE_NAME}.dates.txt"

# Find the capture log if one exists (capture_tape.sh names it <base>.log)
LOG_FILE="${CAPTURE_DIR}/${BASE_NAME}.log"

shopt -s nullglob
AVI_FILES=("$CAPTURE_DIR"/*.avi)
shopt -u nullglob

if [ "${#AVI_FILES[@]}" -eq 0 ]; then
    echo "[ERROR] No .avi files found in: $CAPTURE_DIR"
    exit 1
fi

echo "========================================================="
echo "AUDIT: $BASE_NAME"
echo "Directory: $CAPTURE_DIR"
echo "Files found: ${#AVI_FILES[@]}"
echo "========================================================="

# ==============================================================================
# Integrity Audit
# ==============================================================================
TOTAL_DURATION_SEC=0
TOTAL_SIZE_BYTES=0
WARN_COUNT=0
FFPROBE_FALLBACK_NOTED=0

{
    echo "DATA INTEGRITY AUDIT: $BASE_NAME"
    echo "Generated: $(date)"
    echo "Files: ${#AVI_FILES[@]}"
    echo "---------------------------------------------------------"

    # Sort lexicographically -- DV segment filenames embed the filming date
    # (dv_YYYY.MM.DD_HH-MM-SS.avi) so lex order == chronological order.
    # Hi8 files use a session-date prefix with a numeric suffix (001, 002...)
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

        # Accumulate valid durations
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

        # Per-file line: flag low-bitrate files with [!!!]
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

    TOTAL_HMS=$(printf '%d:%02d:%02d' \
        $((TOTAL_DURATION_SEC / 3600)) \
        $(((TOTAL_DURATION_SEC % 3600) / 60)) \
        $((TOTAL_DURATION_SEC % 60)))
    TOTAL_GiB=$(echo "scale=2; $TOTAL_SIZE_BYTES / 1073741824" | bc)
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
        echo "[!!!] WARNING: ${WARN_COUNT} file(s) flagged above. Check for dropped frames."
    fi
    echo "---------------------------------------------------------"

} | tee "$AUDIT_REPORT"

echo ""

# ==============================================================================
# Recording Date Analysis
# ==============================================================================
# For DV captures, AVI filenames are always the authoritative source of unique
# recording dates because dvgrab encodes the filming date in each filename
# directly. This is reliable even when the capture log is absent or incomplete
# (e.g. captures made with older script versions).
#
# The capture log, if present, is used only to enrich the report with full
# HH:MM:SS timestamps for the first and last recording -- information that the
# filenames alone do not carry. The log is never used as the sole date source
# because an incomplete log (missing segments) would produce a misleadingly
# short date list, exactly the bug this replaces.
#
# For Hi8 captures, filenames encode the capture session date (not the filming
# date) so filename-based date extraction yields nothing useful. The log is the
# only source, and on Hi8 all dates will be garbage timecode anyway.
# ==============================================================================
echo "---------------------------------------------------------"
echo "ANALYSING RECORDING DATES..."

# Dates from AVI filenames: DV files are named prefix_YYYY.MM.DD_HH-MM-SS.avi
DATES_FROM_FILES=$(printf '%s\n' "${AVI_FILES[@]}" \
    | grep -oE '[0-9]{4}\.[0-9]{2}\.[0-9]{2}' \
    | awk -F. '$1 >= 1980 && $1 <= 2010' \
    | sort -u)

# Dates from capture log (may be incomplete for older captures)
DATES_FROM_LOG=""
if [ -f "$LOG_FILE" ]; then
    DATES_FROM_LOG=$(grep -oE 'date [0-9]{4}\.[0-9]{2}\.[0-9]{2}' "$LOG_FILE" \
        | cut -d' ' -f2 \
        | awk -F. '$1 >= 1980 && $1 <= 2010' \
        | sort -u)
fi

# Merge both sources: filenames are authoritative for the date list;
# log dates are unioned in case a Hi8 log has dates filenames cannot provide.
if [[ -n "$DATES_FROM_FILES" && -n "$DATES_FROM_LOG" ]]; then
    VALID_DATES=$(printf '%s\n%s\n' "$DATES_FROM_FILES" "$DATES_FROM_LOG" | sort -u)
    DATE_SOURCE="AVI filenames + capture log"
elif [[ -n "$DATES_FROM_FILES" ]]; then
    VALID_DATES="$DATES_FROM_FILES"
    DATE_SOURCE="AVI filenames"
elif [[ -n "$DATES_FROM_LOG" ]]; then
    VALID_DATES="$DATES_FROM_LOG"
    DATE_SOURCE="capture log only"
else
    VALID_DATES=""
    DATE_SOURCE=""
fi

# Note if the log was present but had fewer dates than the filenames -- this
# indicates an incomplete log from an older capture and is worth flagging.
LOG_INCOMPLETE_NOTE=""
if [[ -n "$DATES_FROM_FILES" && -n "$DATES_FROM_LOG" ]]; then
    FILE_DATE_COUNT=$(echo "$DATES_FROM_FILES" | wc -l)
    LOG_DATE_COUNT=$(echo "$DATES_FROM_LOG"  | wc -l)
    if [[ "$LOG_DATE_COUNT" -lt "$FILE_DATE_COUNT" ]]; then
        LOG_INCOMPLETE_NOTE="[NOTE] Capture log is incomplete (${LOG_DATE_COUNT} date(s) vs ${FILE_DATE_COUNT} in filenames). AVI filenames used as primary source."
    fi
fi

if [[ -n "$VALID_DATES" ]]; then
    DATE_COUNT=$(echo "$VALID_DATES" | wc -l)

    # Full HH:MM:SS timestamps from the log (filenames only have date, not time)
    FIRST_STAMP=""
    LAST_STAMP=""
    if [ -f "$LOG_FILE" ]; then
        FIRST_STAMP=$(grep -oE 'date [0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_FILE" \
            | cut -d' ' -f2-3 \
            | awk -F'[. ]' '$1 >= 1980 && $1 <= 2010' | head -1)
        LAST_STAMP=$(grep -oE 'date [0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_FILE" \
            | cut -d' ' -f2-3 \
            | awk -F'[. ]' '$1 >= 1980 && $1 <= 2010' | tail -1)
    fi
    # If log timestamps are missing or incomplete, derive first/last from filenames
    if [[ -z "$FIRST_STAMP" && -n "$DATES_FROM_FILES" ]]; then
        FIRST_STAMP=$(echo "$DATES_FROM_FILES" | head -1)
        LAST_STAMP=$(echo "$DATES_FROM_FILES"  | tail -1)
    fi

    {
        echo "RECORDING DATE REPORT: $BASE_NAME"
        echo "Generated: $(date)"
        echo "Source: $DATE_SOURCE"
        [[ -n "$LOG_INCOMPLETE_NOTE" ]] && echo "$LOG_INCOMPLETE_NOTE"
        echo "---------------------------------------------------------"
        echo "Unique recording dates found on tape:"
        echo "$VALID_DATES" | while read -r d; do echo "  $d"; done
        echo ""
        echo "Total unique dates: $DATE_COUNT"
        if [[ -n "$FIRST_STAMP" ]]; then
            echo "First valid timestamp: $FIRST_STAMP"
            echo "Last valid timestamp:  $LAST_STAMP"
        fi
        echo "---------------------------------------------------------"
        echo "NOTE: Dates outside 1980-2010 were filtered as garbage timecode."
        echo "      If your tape predates 1980 or postdates 2010, edit the"
        echo "      year range filter in the script."
    } | tee "$DATE_REPORT"

else
    echo "[INFO] No valid recording dates found (1980-2010)."
    echo "       This is expected for analog Hi8 tapes -- they have no internal"
    echo "       clock so dvgrab reports garbage timecodes which are filtered out."
    if [ ! -f "$LOG_FILE" ]; then
        echo "       No capture log was found in this directory."
    fi
fi

echo "---------------------------------------------------------"
echo "Done."
echo "Audit report: $AUDIT_REPORT"
if [ -f "$DATE_REPORT" ]; then
    echo "Date report:  $DATE_REPORT"
fi
