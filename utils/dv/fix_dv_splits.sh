#!/usr/bin/env bash
# ==============================================================================
# fix_dv_splits.sh
#
# Detect and merge dvgrab 1GB split artifacts for Digital8 captures.
# Uses filename timestamps + file size heuristics to build safe concat groups.
#
# Requirements: bash, ffmpeg, stat, awk, sort
# ==============================================================================

set -euo pipefail

DIR="${1:-.}"

if [[ ! -d "$DIR" ]]; then
    echo "[ERROR] Directory not found: $DIR"
    exit 1
fi

cd "$DIR"

echo "Scanning: $DIR"
echo

# Thresholds
SIZE_THRESHOLD_KB=1000000     # ~1GB (1024088 typical)
MAX_GAP_SEC=360              # 6 minutes max gap (~1GB DV span ≈ 4.7 min)

# Extract timestamp (seconds since epoch)
get_ts() {
    local f="$1"
    # dv_YYYY.MM.DD_HH-MM-SS.avi
    if [[ "$f" =~ dv_([0-9]{4})\.([0-9]{2})\.([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
        date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} \
${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s
    else
        echo 0
    fi
}

# Get sorted file list
mapfile -t FILES < <(ls dv_*.avi 2>/dev/null | sort)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "[ERROR] No dv_*.avi files found."
    exit 1
fi

declare -a GROUP
group_index=0

process_group() {
    local group=("$@")
    if [[ ${#group[@]} -le 1 ]]; then
        return
    fi

    echo "---------------------------------------------------------"
    echo "Merge group detected:"
    for f in "${group[@]}"; do
        echo "  $f"
    done

    out="merged_${group[0]}"
    list="concat_${group_index}.txt"

    # Build concat list
    : > "$list"
    for f in "${group[@]}"; do
        printf "file '%s'\n" "$PWD/$f" >> "$list"
    done

    if [[ -f "$out" ]]; then
        echo "[SKIP] Output already exists: $out"
        return
    fi

    echo "-> Output: $out"
    read -p "Merge this group? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        ffmpeg -loglevel error -f concat -safe 0 -i "$list" -c copy "$out"
        echo "[OK] Created: $out"
    else
        echo "[SKIPPED]"
    fi

    group_index=$((group_index + 1))
}

GROUP=("${FILES[0]}")

for ((i=1; i<${#FILES[@]}; i++)); do
    prev="${FILES[i-1]}"
    curr="${FILES[i]}"

    prev_size=$(stat -c%s "$prev")
    prev_kb=$((prev_size / 1024))

    prev_ts=$(get_ts "$prev")
    curr_ts=$(get_ts "$curr")

    gap=$((curr_ts - prev_ts))

    # Condition for continuation:
    # 1. Previous file ~1GB
    # 2. Time gap small (~<= 6 minutes)
    if (( prev_kb >= SIZE_THRESHOLD_KB && gap >= 0 && gap <= MAX_GAP_SEC )); then
        GROUP+=("$curr")
    else
        process_group "${GROUP[@]}"
        GROUP=("$curr")
    fi
done

# Final group
process_group "${GROUP[@]}"

echo
echo "Done."
