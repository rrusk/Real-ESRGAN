#!/bin/bash
# ==============================================================================
# Script Name: check_dv_chapters.sh
# Version:     1.4
# Description: Sanity-check that every source DV file for days that have been
#              assembled is represented as a chapter in its output MKV.
#
# Iterates over INPUT_ROOT (the authoritative source) rather than OUTPUT_ROOT,
# so entirely unprocessed days are detected, not just chapter gaps within
# assembled MKVs.
#
# For each source day directory:
#   - If an assembled *_chapters_*.mkv exists: verify every source .avi is
#     present as a chapter title.
#   - If no assembled MKV exists but a later day IS assembled (i.e. the day
#     falls within the processing frontier): report as a GAP — this indicates
#     a day was skipped out of order.
#   - If the day is beyond the processing frontier (latest assembled day):
#     report as PENDING — not yet reached, not a problem.
#
# Chapter names are timestamps embedded in the DV filename:
#   dv.YYYYMMDD[-_]HHMMSS.avi  →  "YYYY-MM-DD HH:MM:SS"
#   dv.YYYYMMDD-HHMM.avi       →  "YYYY-MM-DD HH:MM"   (older short format)
#
# Exit codes:
#   0  — all assembled days have complete chapters; no gaps detected
#   1  — missing chapters or gap days detected
#   2  — usage or configuration error
#
# Usage:
#   check_dv_chapters.sh [--input-root DIR] [--output-root DIR] [--day YYYYMMDD[_Loc]]
#   check_dv_chapters.sh --help
#
# Requirements: ffprobe (ffmpeg package), bash >= 4.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Defaults (match upscale_dv_batch.sh)
# ------------------------------------------------------------------------------
INPUT_ROOT="/mnt_WD8TB_A/Videos/Family/Videos/Hi8/DV/Digital8_Native"
OUTPUT_ROOT="./outputs/dv_upscaled"
# Optional filter: if non-empty, check only these days (frontier logic is
# disabled when a filter is active — all filtered days are checked directly).
DAY_FILTER=()

# ------------------------------------------------------------------------------
# 2. Argument Parsing
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Verify that every source DV .avi file is represented as a chapter in the
assembled MKV for each completed day.  Days within the processing frontier
that have no assembled MKV are reported as gaps.

Options:
  --input-root DIR      Root directory containing per-day DV subdirectories.
                        (default: $INPUT_ROOT)
  --output-root DIR     Root directory for upscaled output (assembled MKVs).
                        (default: $OUTPUT_ROOT)
  --day YYYYMMDD[_Loc]  Check only this day.  May be repeated.  Disables
                        frontier-based gap detection.
  --help, -h            Show this help.

Examples:
  # Check all source days, detect gaps:
  $0

  # Check a single day:
  $0 --day 20040707
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input-root)  INPUT_ROOT="$2";    shift 2 ;;
        --output-root) OUTPUT_ROOT="$2";   shift 2 ;;
        --day)         DAY_FILTER+=("$2"); shift 2 ;;
        --help|-h)     usage; exit 0 ;;
        *) echo "Error: Unknown argument: '$1'" >&2; usage; exit 2 ;;
    esac
done

# ------------------------------------------------------------------------------
# 3. Tool Check
# ------------------------------------------------------------------------------
for tool in ffprobe; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: Required tool not found in PATH: $tool" >&2
        echo "       ffprobe is part of the ffmpeg package" >&2
        exit 2
    fi
done

INPUT_ROOT=$(realpath "$INPUT_ROOT")
OUTPUT_ROOT=$(realpath "$OUTPUT_ROOT")

if [[ ! -d "$INPUT_ROOT" ]]; then
    echo "Error: INPUT_ROOT does not exist: $INPUT_ROOT" >&2
    exit 2
fi
if [[ ! -d "$OUTPUT_ROOT" ]]; then
    echo "Error: OUTPUT_ROOT does not exist: $OUTPUT_ROOT" >&2
    exit 2
fi

# ------------------------------------------------------------------------------
# 4. Helper: extract chapter names from an MKV via ffprobe
# ------------------------------------------------------------------------------
# ffprobe -show_chapters emits one [CHAPTER] block per chapter, each containing
# a TAG:title=<name> line.  This is the same mechanism used by upscale_dv_batch.sh
# for its own post-assembly chapter count verification.
# Output: one chapter title per line, trailing whitespace stripped.
get_chapter_names() {
    local mkv="$1"
    ffprobe -v error -show_chapters "$mkv" 2>/dev/null \
        | grep '^TAG:title=' \
        | sed 's/^TAG:title=//; s/[[:space:]]*$//'
}

# ------------------------------------------------------------------------------
# 5. Helper: derive expected chapter name from source .avi filename
# ------------------------------------------------------------------------------
# Input:  basename of the .avi, e.g. dv.20040707-094437.avi
# Output: "2004-07-07 09:44:37"  (or "2004-07-07 09:44" for short format)
# Returns 1 if the filename does not match the expected pattern.
avi_to_chapter_name() {
    local base="$1"
    if [[ "$base" =~ ^dv\.([0-9]{8})[-_]([0-9]{6}) ]]; then
        local d="${BASH_REMATCH[1]}"
        local t="${BASH_REMATCH[2]}"
        echo "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}"
    elif [[ "$base" =~ ^dv\.([0-9]{8})-([0-9]{4}) ]]; then
        local d="${BASH_REMATCH[1]}"
        local t="${BASH_REMATCH[2]}"
        echo "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}"
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 6. Helper: report any non-AVI files present in a source day directory
# ------------------------------------------------------------------------------
# Prints a NOTE line for each file that is not a dv.*.avi — these are files the
# batch script will silently skip and that may need manual attention.
report_non_avi_files() {
    local day="$1"
    local dir="$2"
    local -a others=()
    mapfile -t others < <(
        find "$dir" -maxdepth 1 -type f ! -name 'dv.*.avi' | sort
    )
    for f in "${others[@]}"; do
        echo "NOTE  [$day] Non-AVI file (not processed by batch): $(basename "$f")"
    done
}

# ------------------------------------------------------------------------------
# 7. Helper: extract the sortable YYYYMMDD date prefix from a day directory name
# ------------------------------------------------------------------------------
# Day names are YYYYMMDD or YYYYMMDD_Suffix; the date portion is always first.
day_date_key() {
    echo "${1:0:8}"
}

# ------------------------------------------------------------------------------
# 8. Main check loop
# ------------------------------------------------------------------------------
VERSION="1.4"
echo "check_dv_chapters.sh v${VERSION}"

total_days=0
ok_days=0
fail_days=0      # assembled MKV present but some chapters missing
gap_days=0       # no assembled MKV but within the processing frontier
pending_days=0   # beyond the processing frontier — not yet reached
total_files=0
missing_chapters=0
errors=0

# Build the list of source days to examine, sorted chronologically.
# Day directory names sort correctly as strings because they start with YYYYMMDD.
if [[ ${#DAY_FILTER[@]} -gt 0 ]]; then
    day_list=("${DAY_FILTER[@]}")
    use_frontier=false
else
    mapfile -t day_list < <(
        find "$INPUT_ROOT" -mindepth 1 -maxdepth 1 -type d \
            -printf '%f\n' | sort
    )
    use_frontier=true
fi

# Determine the processing frontier: the latest (lexicographically greatest)
# YYYYMMDD for which an assembled chapter MKV exists in OUTPUT_ROOT.
# Days with a date key <= frontier but no assembled MKV are gaps.
# Days with a date key >  frontier are simply pending.
frontier="00000000"
if [[ "$use_frontier" == true ]]; then
    while IFS= read -r out_day; do
        # Only consider output dirs whose names start with a valid YYYYMMDD.
        [[ "$out_day" =~ ^[0-9]{8} ]] || continue
        # Check whether this output dir actually contains an assembled MKV.
        local_out_dir="${OUTPUT_ROOT}/${out_day}"
        mapfile -t mkvs < <(
            find "$local_out_dir" -maxdepth 1 \
                -name "${out_day}_chapters_*.mkv" -type f 2>/dev/null
        )
        if [[ ${#mkvs[@]} -gt 0 ]]; then
            key=$(day_date_key "$out_day")
            [[ "$key" > "$frontier" ]] && frontier="$key"
        fi
    done < <(find "$OUTPUT_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
    echo "Processing frontier: ${frontier} (latest assembled day)"
fi

for day_name in "${day_list[@]}"; do
    (( total_days++ )) || true

    local_in_dir="${INPUT_ROOT}/${day_name}"
    local_out_dir="${OUTPUT_ROOT}/${day_name}"

    # Verify source directory exists (guards against bad --day arguments).
    if [[ ! -d "$local_in_dir" ]]; then
        echo "WARN  [$day_name] Input directory not found: $local_in_dir"
        (( errors++ )) || true
        continue
    fi

    # Find the assembled chapter MKV for this day (exactly one expected).
    mapfile -t chapter_mkvs < <(
        find "$local_out_dir" -maxdepth 1 \
            -name "${day_name}_chapters_*.mkv" -type f 2>/dev/null | sort
    )

    if [[ ${#chapter_mkvs[@]} -eq 0 ]]; then
        # No assembled MKV.  Classify based on the frontier.
        if [[ "$use_frontier" == true ]]; then
            key=$(day_date_key "$day_name")
            if [[ ! "$key" > "$frontier" ]]; then
                echo "GAP   [$day_name] No assembled MKV but later days are done — possible skip."
                report_non_avi_files "$day_name" "$local_in_dir"
                (( gap_days++ )) || true
                (( errors++ )) || true
            else
                echo "PEND  [$day_name] Beyond processing frontier — not yet reached."
                (( pending_days++ )) || true
            fi
        else
            echo "SKIP  [$day_name] No assembled chapter MKV found."
        fi
        continue
    fi

    if [[ ${#chapter_mkvs[@]} -gt 1 ]]; then
        echo "WARN  [$day_name] Multiple chapter MKVs found — manual inspection needed:"
        printf "        %s\n" "${chapter_mkvs[@]}"
        (( errors++ )) || true
        # Continue with the first one so we still check what we can.
    fi

    chapter_mkv="${chapter_mkvs[0]}"

    # Extract chapter names from the MKV.
    mapfile -t mkv_chapters < <(get_chapter_names "$chapter_mkv")

    if [[ ${#mkv_chapters[@]} -eq 0 ]]; then
        echo "WARN  [$day_name] Could not extract any chapter names from:"
        echo "        $chapter_mkv"
        (( errors++ )) || true
        continue
    fi

    # Build a lookup set of chapter names present in the MKV.
    declare -A chapter_set=()
    for ch in "${mkv_chapters[@]}"; do
        chapter_set["$ch"]=1
    done

    # Check each source .avi against the chapter set.
    mapfile -t avi_files < <(
        find "$local_in_dir" -maxdepth 1 -name 'dv.*.avi' -type f \
            -printf '%f\n' | sort
    )

    if [[ ${#avi_files[@]} -eq 0 ]]; then
        echo "WARN  [$day_name] No source .avi files found in: $local_in_dir"
        (( errors++ )) || true
        unset chapter_set
        continue
    fi

    day_missing=0
    for avi in "${avi_files[@]}"; do
        (( total_files++ )) || true
        expected_name=$(avi_to_chapter_name "$avi") || {
            echo "WARN  [$day_name] Cannot parse timestamp from filename: $avi"
            (( errors++ )) || true
            continue
        }
        if [[ -z "${chapter_set[$expected_name]+_}" ]]; then
            echo "MISS  [$day_name] Missing chapter: '$expected_name'  ($avi)"
            (( day_missing++ )) || true
            (( missing_chapters++ )) || true
        fi
    done
    unset chapter_set

    if [[ $day_missing -gt 0 ]]; then
        echo "FAIL  [$day_name] $day_missing / ${#avi_files[@]} source files missing from chapters."
        report_non_avi_files "$day_name" "$local_in_dir"
        (( fail_days++ )) || true
        (( errors++ )) || true
    else
        echo "OK    [$day_name] All ${#avi_files[@]} source files present in chapters."
        report_non_avi_files "$day_name" "$local_in_dir"
        (( ok_days++ )) || true
    fi

done

# ------------------------------------------------------------------------------
# 9. Summary
# ------------------------------------------------------------------------------
echo ""
echo "========================================================"
echo "Chapter check complete."
echo "  Days examined:         $total_days"
echo "  OK (all chapters):     $ok_days"
echo "  Failed (missing chap): $fail_days"
echo "  GAP (skipped day):     $gap_days"
echo "  Pending (not yet):     $pending_days"
echo "  Total source files:    $total_files"
echo "  Missing chapters:      $missing_chapters"
echo "========================================================"

if [[ $errors -gt 0 ]]; then
    exit 1
fi
exit 0
