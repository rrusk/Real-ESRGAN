#!/bin/bash
# ==============================================================================
# Script Name: mux_pipeline.sh
# Description: Automates parsing raw chapters and muxing them into an MKV.
# Usage: ./mux_pipeline.sh <video_file> <raw_chapters_file>
# ==============================================================================

# 1. Strict Mode (Best Practice)
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error.
# -o pipefail: Return value of a pipeline is the value of the last (failed) command.
set -euo pipefail

# 2. Configuration
readonly CONVERTER_SCRIPT="convert_chapters.py"
readonly TEMP_CHAPTERS="temp_ogm_chapters.txt"

# 3. Helper Functions
log() {
    echo "[$(date +'%H:%M:%S')] $1"
}

usage() {
    echo "Usage: $(basename "$0") <video_file> <raw_chapters_file>"
    echo ""
    echo "The <raw_chapters_file> must be a plain text file with one chapter"
    echo "per line in the format: 'Chapter Name MM:SS'"
    echo ""
    echo "Example File Content:"
    echo "  Introduction 0:00"
    echo "  The Big Race 12:45"
    echo ""
    echo "Example Command: ./add_chapters.sh my_video.mkv timestamps.txt"
    exit 1
}

cleanup() {
    # Best Practice: Ensure temporary files are removed even if the script fails
    if [[ -f "$TEMP_CHAPTERS" ]]; then
        rm "$TEMP_CHAPTERS"
    fi
}

# Register the cleanup function to run on EXIT (success or failure)
trap cleanup EXIT

# 4. Argument Parsing & Validation
if [[ $# -ne 2 ]]; then
    usage
fi

INPUT_VIDEO="$1"
RAW_CHAPTERS="$2"

# Check if files exist
if [[ ! -f "$INPUT_VIDEO" ]]; then
    log "Error: Video file '$INPUT_VIDEO' not found."
    exit 1
fi

if [[ ! -f "$RAW_CHAPTERS" ]]; then
    log "Error: Chapters file '$RAW_CHAPTERS' not found."
    exit 1
fi

# Check dependencies
if ! command -v mkvmerge &> /dev/null; then
    log "Error: mkvmerge is not installed."
    exit 1
fi

# 5. Dynamic Output Naming
# Extracts filename without extension (e.g., "video.mkv" -> "video")
BASENAME=$(basename "$INPUT_VIDEO" .mkv)
FINAL_OUTPUT="${BASENAME}_chaptered.mkv"

main() {
    log "Processing: $INPUT_VIDEO"
    log "Chapters:   $RAW_CHAPTERS"

    # Step A: Convert raw text to OGM format using the Python script
    # We pass the python script the input and tell it where to save the temp file
    log "Step 1: Converting chapter format..."
    python3 "$CONVERTER_SCRIPT" "$RAW_CHAPTERS" -o "$TEMP_CHAPTERS"

    # Step B: Mux into new MKV
    log "Step 2: Muxing into '$FINAL_OUTPUT'..."
    mkvmerge -o "$FINAL_OUTPUT" --chapters "$TEMP_CHAPTERS" "$INPUT_VIDEO"

    log "Success! Output saved to: $FINAL_OUTPUT"
}

main
