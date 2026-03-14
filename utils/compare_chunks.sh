#!/bin/bash
# ==============================================================================
# Script Name: compare_chunks.sh
# Description: Side-by-side A/B comparison of processed video chunks.
# Usage: ./compare_chunks.sh <chunk_a> <chunk_b> [output_name]
#
# Label resolution (per input file):
#   If the file lives inside a 2_rife_chunks subdirectory, the script looks for
#   metadata.json in the parent processing directory and reads the "profile"
#   field from it.  Falls back to the raw file path if the file isn't in a
#   recognised location, metadata.json is missing, or the profile key is absent.
# ==============================================================================

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <chunk_a.mp4> <chunk_b.mp4> [comparison_output.mp4]"
    exit 1
fi

LEFT_INPUT="$1"
RIGHT_INPUT="$2"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_FILE="${3:-comparison_side_by_side_${TIMESTAMP}.mp4}"

# Check if inputs exist
for file in "$LEFT_INPUT" "$RIGHT_INPUT"; do
    if [ ! -f "$file" ]; then
        echo "Error: File '$file' not found."
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# get_label <file_path>
#   Tries to resolve a human-readable label for the given chunk file.
#   Resolution order:
#     1. Parent directory is 2_rife_chunks  →  read "profile" from
#        ../../metadata.json (i.e. the processing root beside 2_rife_chunks).
#     2. metadata.json not found / profile key absent  →  use the file path.
# ------------------------------------------------------------------------------
get_label() {
    local filepath="$1"
    local dir
    dir="$(cd "$(dirname "$filepath")" && pwd)"
    local dirname_only
    dirname_only="$(basename "$dir")"

    if [ "$dirname_only" = "2_rife_chunks" ]; then
        local metadata_file
        metadata_file="$(dirname "$dir")/metadata.json"

        if [ -f "$metadata_file" ]; then
            local profile=""

            # Prefer jq if available (robust JSON parsing)
            if command -v jq &>/dev/null; then
                profile="$(jq -r '.profile // empty' "$metadata_file" 2>/dev/null)"
            fi

            # Fallback 1: python3
            if [ -z "$profile" ] && command -v python3 &>/dev/null; then
                profile="$(python3 -c \
                    "import json,sys; d=json.load(open('$metadata_file')); print(d.get('profile',''))" \
                    2>/dev/null)"
            fi

            # Fallback 2: grep + sed (last resort, handles simple single-line JSON)
            if [ -z "$profile" ]; then
                profile="$(grep -o '"profile"[[:space:]]*:[[:space:]]*"[^"]*"' \
                    "$metadata_file" 2>/dev/null \
                    | sed 's/.*"profile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
            fi

            if [ -n "$profile" ]; then
                echo "$profile"
                return
            else
                echo "Warning: 'profile' key not found in $metadata_file" >&2
            fi
        else
            echo "Warning: metadata.json not found at $metadata_file" >&2
        fi
    fi

    # Default: use the path as supplied on the command line
    echo "$filepath"
}

LEFT_LABEL="$(get_label "$LEFT_INPUT")"
RIGHT_LABEL="$(get_label "$RIGHT_INPUT")"

echo "--- Generating Side-by-Side Comparison ---"
echo "Left:  $LEFT_INPUT  (Labeled: $LEFT_LABEL)"
echo "Right: $RIGHT_INPUT (Labeled: $RIGHT_LABEL)"

# Filter Complex Breakdown:
# 1. drawtext: Adds labels to the top-left of each stream for identification.
# 2. hstack: Places the two streams side-by-side.
# 3. -c:v libx264 -crf 17: High-quality encode to ensure comparison artifacts
#    aren't masked by new compression.

ffmpeg -y -i "$LEFT_INPUT" -i "$RIGHT_INPUT" \
    -filter_complex "[0:v]drawtext=text='${LEFT_LABEL}':x=20:y=20:fontsize=32:fontcolor=white:box=1:boxcolor=black@0.6[l]; \
                     [1:v]drawtext=text='${RIGHT_LABEL}':x=20:y=20:fontsize=32:fontcolor=white:box=1:boxcolor=black@0.6[r]; \
                     [l][r]hstack=inputs=2[v]" \
    -map "[v]" \
    -c:v libx264 -crf 17 -preset slow -pix_fmt yuv420p \
    "$OUTPUT_FILE"

if [ $? -eq 0 ]; then
    echo -e "\n✅ Success! Comparison created: $OUTPUT_FILE"
else
    echo -e "\n❌ Error: FFmpeg failed to generate comparison."
fi
