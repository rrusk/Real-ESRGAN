#!/bin/bash
# dvd_enhance_ai.sh — Add chapter markers and produce a distribution MP4 from
# the MKV output of video_upscale_pipeline.py (Real-ESRGAN AI upscale).
#
# This script is the final step in the AI upscale path of the DVD preservation
# pipeline:
#
#   dvd_extract.sh  ->  video_upscale_pipeline.py  ->  dvd_enhance_ai.sh
#
# video_upscale_pipeline.py produces a directly playable MKV.  This script:
#   1. Injects chapter markers into that MKV in-place (mkvpropedit, instant,
#      no remux, no quality loss).
#   2. Produces a distribution MP4 by remuxing the MKV via ffmpeg (stream copy,
#      no re-encode) and injecting chapters into it via MP4Box.
#
# No video re-encoding is performed in either step.  The AI upscale from
# video_upscale_pipeline.py is the final video quality; this script only
# handles container and chapter metadata.
#
# Usage:
#   ./dvd_enhance_ai.sh [OPTIONS] <upscaled_mkv> <chapter_file>
#
# Arguments:
#   <upscaled_mkv>    MKV file from video_upscale_pipeline.py.
#                     Typically: outputs/<name>_<profile>_x2_x2plus_60fps.mkv
#   <chapter_file>    OGM chapter file from dvd_extract.sh.
#                     Optional when --names is provided: auto-detected by
#                     matching chapter count to the names file line count,
#                     searching the directory of <upscaled_mkv> and the
#                     current working directory.
#
# Options:
#   --names FILE   Plain-text chapter names file, one title per line.
#                  Line count must match the chapter count in <chapter_file>.
#                  Without --names, timestamp-only chapter markers are embedded
#                  (e.g. "00:02:42").  For MKV these can be updated at any time
#                  via mkvpropedit with no remux.
#   --no-mp4       Skip MP4 production; inject chapters into MKV only.
#   -o, --output   Output MP4 filename stem (no extension).
#                  Default: <upscaled_mkv_stem>.
#   -h, --help     Show this help and exit.
#
# Output:
#   <stem>.mkv     Input MKV with chapters injected in-place.
#   <stem>.mp4     Stream-copy remux of the MKV with chapters embedded.
#                  (H.264/AAC if the MKV contains those codecs, otherwise
#                  whatever codecs video_upscale_pipeline.py produced.)
#
# Chapter names and format:
#   MKV: mkvpropedit edits chapters in-place -- instant, no remux, no quality
#        loss.  Names can be updated at any time with no cost.
#   MP4: MP4Box requires a remux pass (new file written).  Providing --names
#        at this stage avoids a second remux later if names need changing.
#
# Dependencies (all available via apt):
#   Required : mkvtoolnix  (mkvpropedit -- MKV in-place chapter injection)
#              python3     (OGM -> XML conversion, chapter name substitution)
#   MP4 path : ffmpeg      (stream-copy remux MKV -> MP4)
#              gpac        (MP4Box -- MP4 chapter injection)
#   Optional : xxhash      (xxhsum -- integrity verification)
#
set -euo pipefail

# ==============================================================================
# Usage
# ==============================================================================
usage() {
    sed -n '2,/^set -euo/{ /^set -euo/d; s/^# \{0,1\}//; p }' "$0"
    exit 0
}

# ==============================================================================
# Defaults
# ==============================================================================
NAMES_FILE=""
NO_MP4=false
OUTPUT_STEM=""
INPUT_MKV=""
CHAPTER_FILE=""

# ==============================================================================
# Argument parsing
# ==============================================================================
_NEXT=""
while [[ $# -gt 0 ]]; do
    if [[ -n "$_NEXT" ]]; then
        case "$_NEXT" in
            names)   NAMES_FILE="$1"  ;;
            output)  OUTPUT_STEM="$1" ;;
        esac
        _NEXT=""; shift; continue
    fi
    case "$1" in
        --names)       _NEXT="names"   ;;
        --no-mp4)      NO_MP4=true     ;;
        -o|--output)   _NEXT="output"  ;;
        -h|--help)     usage           ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            echo "Run with --help for usage."
            exit 1 ;;
        *)
            if [[ -z "$INPUT_MKV" ]]; then
                INPUT_MKV="$1"
            elif [[ -z "$CHAPTER_FILE" ]]; then
                CHAPTER_FILE="$1"
            else
                echo "[ERROR] Unexpected argument: $1"
                echo "Run with --help for usage."
                exit 1
            fi ;;
    esac
    shift
done

if [[ -z "$INPUT_MKV" ]]; then
    echo "[ERROR] <upscaled_mkv> is required."
    echo "Run with --help for usage."
    exit 1
fi

if [[ -z "$CHAPTER_FILE" && -z "$NAMES_FILE" ]]; then
    echo "[ERROR] <chapter_file> is required unless --names is provided."
    echo "        With --names, the chapter file is auto-detected by matching"
    echo "        chapter count to the names file line count."
    echo "Run with --help for usage."
    exit 1
fi

# ==============================================================================
# Dependency check
# ==============================================================================
echo ""
echo "========================================="
echo "  dvd_enhance_ai.sh -- dependency check"
echo "========================================="
echo ""

HAVE_MKVPROPEDIT=0; command -v mkvpropedit >/dev/null 2>&1 && HAVE_MKVPROPEDIT=1
HAVE_FFMPEG=0;      command -v ffmpeg       >/dev/null 2>&1 && HAVE_FFMPEG=1
HAVE_MP4BOX=0;      command -v MP4Box       >/dev/null 2>&1 && HAVE_MP4BOX=1
HAVE_PYTHON3=0;     command -v python3      >/dev/null 2>&1 && HAVE_PYTHON3=1
HAVE_XXHSUM=0;      command -v xxhsum       >/dev/null 2>&1 && HAVE_XXHSUM=1

[[ $HAVE_MKVPROPEDIT -eq 1 ]] \
    && echo "  [OK]   mkvpropedit     -- MKV in-place chapter injection (mkvtoolnix)" \
    || echo "  [MISS] mkvpropedit     -- sudo apt install mkvtoolnix"
[[ $HAVE_PYTHON3     -eq 1 ]] \
    && echo "  [OK]   python3         -- OGM/XML conversion" \
    || echo "  [MISS] python3         -- sudo apt install python3"
[[ $HAVE_FFMPEG      -eq 1 ]] \
    && echo "  [OK]   ffmpeg          -- MKV -> MP4 remux" \
    || echo "  [MISS] ffmpeg          -- sudo apt install ffmpeg (required for MP4)"
[[ $HAVE_MP4BOX      -eq 1 ]] \
    && echo "  [OK]   MP4Box          -- MP4 chapter injection (gpac)" \
    || echo "  [MISS] MP4Box          -- sudo apt install gpac (required for MP4)"
[[ $HAVE_XXHSUM      -eq 1 ]] \
    && echo "  [OK]   xxhsum          -- integrity verification (xxhash)" \
    || echo "  [----] xxhsum          -- optional: sudo apt install xxhash"
echo ""

MISSING=()
[[ $HAVE_MKVPROPEDIT -eq 0 ]] && MISSING+=(mkvtoolnix)
[[ $HAVE_PYTHON3     -eq 0 ]] && MISSING+=(python3)
if [[ "$NO_MP4" == false ]]; then
    [[ $HAVE_FFMPEG  -eq 0 ]] && MISSING+=(ffmpeg)
    [[ $HAVE_MP4BOX  -eq 0 ]] && MISSING+=(gpac)
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "[ERROR] Required packages missing: ${MISSING[*]}"
    echo "        sudo apt install ${MISSING[*]}"
    exit 1
fi

# ==============================================================================
# Validate inputs
# ==============================================================================
if [[ ! -f "$INPUT_MKV" ]]; then
    echo "[ERROR] MKV file not found: $INPUT_MKV"
    exit 1
fi

EXT="${INPUT_MKV##*.}"; EXT="${EXT,,}"
if [[ "$EXT" != "mkv" ]]; then
    echo "[ERROR] Input must be a .mkv file (got .$EXT)."
    exit 1
fi

if [[ -n "$NAMES_FILE" && ! -f "$NAMES_FILE" ]]; then
    echo "[ERROR] Names file not found: $NAMES_FILE"
    exit 1
fi

# ==============================================================================
# Chapter file auto-detection (when --names given but no explicit chapter file)
#
# Searches the directory of the MKV and the current working directory for
# _title_NN_chapters.txt files whose chapter count matches the names file.
# ==============================================================================
if [[ -z "$CHAPTER_FILE" && -n "$NAMES_FILE" ]]; then
    NAMES_COUNT=$(grep -c '[^[:space:]]' "$NAMES_FILE" 2>/dev/null || echo 0)
    MKV_DIR=$(dirname "$INPUT_MKV")

    # Collect candidates from MKV directory and current directory (deduplicated)
    mapfile -t CANDIDATE_OGMS < <(
        { ls "${MKV_DIR}/"*"_title_"*"_chapters.txt" 2>/dev/null || true
          ls ./*"_title_"*"_chapters.txt" 2>/dev/null || true; } | sort -u
    )

    MATCHED_OGMS=()
    for ogm in "${CANDIDATE_OGMS[@]}"; do
        CHAP_COUNT=$(grep -c '^CHAPTER[0-9]*=' "$ogm" 2>/dev/null || echo 0)
        [[ "$CHAP_COUNT" -eq "$NAMES_COUNT" ]] && MATCHED_OGMS+=("$ogm")
    done

    if [[ ${#MATCHED_OGMS[@]} -eq 0 ]]; then
        echo "[ERROR] No chapter file found matching $NAMES_COUNT chapter(s)."
        echo "        Searched: $MKV_DIR and current directory."
        if [[ ${#CANDIDATE_OGMS[@]} -gt 0 ]]; then
            echo "        Candidates found (none matched $NAMES_COUNT chapters):"
            for ogm in "${CANDIDATE_OGMS[@]}"; do
                C=$(grep -c '^CHAPTER[0-9]*=' "$ogm" 2>/dev/null || echo 0)
                echo "          $C chapter(s): $(basename "$ogm")"
            done
        fi
        echo "        Provide the chapter file explicitly as the second argument."
        exit 1
    elif [[ ${#MATCHED_OGMS[@]} -eq 1 ]]; then
        CHAPTER_FILE="${MATCHED_OGMS[0]}"
        echo "  [INFO] Chapter file auto-detected: $(basename "$CHAPTER_FILE")"
        echo "         ($NAMES_COUNT chapter(s) matched names file)"
    else
        echo "[ERROR] Multiple chapter files match $NAMES_COUNT chapter(s):"
        for ogm in "${MATCHED_OGMS[@]}"; do
            echo "          $(basename "$ogm")"
        done
        echo "        Provide the chapter file explicitly as the second argument."
        exit 1
    fi
fi

if [[ ! -f "$CHAPTER_FILE" ]]; then
    echo "[ERROR] Chapter file not found: $CHAPTER_FILE"
    exit 1
fi

# ==============================================================================
# Output filenames
# ==============================================================================
MKV_STEM="${INPUT_MKV%.*}"
if [[ -n "$OUTPUT_STEM" ]]; then
    OUTPUT_STEM="${OUTPUT_STEM%.*}"   # strip any extension the user included
else
    OUTPUT_STEM="$MKV_STEM"
fi
MP4_FILE="${OUTPUT_STEM}.mp4"

# ==============================================================================
# Apply chapter name replacements (--names FILE)
# ==============================================================================
OGM_WORK="$CHAPTER_FILE"
OGM_NAMED=""

if [[ -n "$NAMES_FILE" ]]; then
    OGM_CHAP_COUNT=$(grep -c '^CHAPTER[0-9]*NAME=' "$CHAPTER_FILE" 2>/dev/null || echo 0)
    NAMES_COUNT=$(grep -c '[^[:space:]]' "$NAMES_FILE" 2>/dev/null || echo 0)

    if [[ "$OGM_CHAP_COUNT" -ne "$NAMES_COUNT" ]]; then
        echo "[ERROR] Chapter count mismatch:"
        echo "        Chapter file has $OGM_CHAP_COUNT chapter(s)."
        echo "        Names file has   $NAMES_COUNT line(s)."
        exit 1
    fi

    echo "--- Applying chapter names ---"
    echo "  Names: $NAMES_FILE  ($NAMES_COUNT name(s))"

    OGM_NAMED=$(mktemp /tmp/dvd_finish_ogm_XXXXXX.txt)

    python3 - "$CHAPTER_FILE" "$NAMES_FILE" "$OGM_NAMED" << 'PYEOF'
import sys, re
with open(sys.argv[1]) as f: ogm_lines = f.readlines()
with open(sys.argv[2]) as f: names = [ln.strip() for ln in f if ln.strip()]
name_iter = iter(names)
out = []
for line in ogm_lines:
    if re.match(r'CHAPTER\d+NAME=', line):
        num = re.match(r'(CHAPTER\d+NAME)=', line).group(1)
        out.append(f'{num}={next(name_iter)}\n')
    else:
        out.append(line)
with open(sys.argv[3], 'w') as f: f.writelines(out)
PYEOF

    OGM_WORK="$OGM_NAMED"

    echo "  Chapter list:"
    grep '^CHAPTER[0-9]*' "$OGM_WORK" | paste - - \
        | while IFS=$'\t' read -r ts name; do
            printf "    %s  |  %s\n" "$ts" "$name"
        done
    echo ""
fi

# ==============================================================================
# Convert OGM to Matroska XML
#
# mkvpropedit accepts Matroska XML unambiguously regardless of version.
# MP4Box uses its own simple text format (converted separately below).
# ==============================================================================
CHAP_XML=$(mktemp /tmp/dvd_finish_chap_XXXXXX.xml)
_cleanup() {
    [[ -n "$OGM_NAMED" && -f "$OGM_NAMED" ]] && rm -f "$OGM_NAMED"
    [[ -f "$CHAP_XML" ]] && rm -f "$CHAP_XML"
}
trap _cleanup EXIT

python3 - "$OGM_WORK" "$CHAP_XML" << 'PYEOF'
import sys, re
with open(sys.argv[1]) as f: lines = f.read().strip().splitlines()
entries = {}; order = []
for line in lines:
    m = re.match(r'CHAPTER(\d+)(NAME)?=(.*)', line)
    if not m: continue
    num, is_name, val = m.group(1), m.group(2), m.group(3).strip()
    if num not in entries: entries[num] = {}; order.append(num)
    entries[num]['name' if is_name else 'time'] = val
xml = ['<?xml version="1.0" encoding="UTF-8"?>',
       '<!DOCTYPE Chapters SYSTEM "matroskachapters.dtd">',
       '<Chapters><EditionEntry>']
for num in order:
    t = entries[num].get('time', '00:00:00.000')
    n = entries[num].get('name', f'Chapter {int(num):02d}')
    xml += [f'  <ChapterAtom>',
            f'    <ChapterTimeStart>{t}</ChapterTimeStart>',
            f'    <ChapterDisplay><ChapterString>{n}</ChapterString></ChapterDisplay>',
            f'  </ChapterAtom>']
xml.append('</EditionEntry></Chapters>')
with open(sys.argv[2], 'w') as f: f.write('\n'.join(xml) + '\n')
PYEOF

# ==============================================================================
# Chapter names warning
#
# For MKV: names can be added or changed at any time via mkvpropedit (instant).
# For MP4: adding names later requires a full MP4Box remux pass.
# Prompt for confirmation only when producing MP4 without names.
# ==============================================================================
if [[ -z "$NAMES_FILE" && "$NO_MP4" == false ]]; then
    NUM_CHAPS=$(grep -c '^CHAPTER[0-9]*NAME=' "$CHAPTER_FILE" 2>/dev/null || echo 0)
    echo ""
    echo "  [WARN] No --names file provided for MP4 output."
    echo "         $NUM_CHAPS chapter marker(s) will use timestamp names (e.g. '00:02:42')."
    echo ""
    echo "         Chapter titles are on the DVD menu and straightforward to transcribe."
    echo "         Adding names after this step requires a full MP4Box remux pass."
    echo "         To embed titles now, cancel and re-run with:"
    echo "           --names <file>   one title per line, $NUM_CHAPS line(s) required"
    echo "         MKV chapter names can be updated at any time with no remux:"
    echo "           mkvpropedit <file>.mkv --chapters <named_chapters.txt>"
    echo ""
    read -p "  Continue without chapter titles? (y/n): " -n 1 -r </dev/tty
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled. Re-run with --names <chapter_titles_file>."
        exit 0
    fi
    echo ""
fi

# ==============================================================================
# Step 1 — Inject chapters into MKV (in-place, no remux, instant)
# ==============================================================================
echo "--- Injecting chapters into MKV ---"
echo "  File: $INPUT_MKV"
mkvpropedit "$INPUT_MKV" --chapters "$CHAP_XML"
echo "  Done."

# ==============================================================================
# Step 2 — Produce distribution MP4 (stream-copy remux + MP4Box chapters)
#
# ffmpeg stream-copies all streams from the MKV into an MP4 container.
# No re-encoding: the AI-upscaled video and audio are preserved exactly.
# -movflags +faststart places the MP4 index at the front for streaming.
#
# MP4Box then injects chapters via a remux pass (required by the MP4 format).
# ==============================================================================
if [[ "$NO_MP4" == false ]]; then
    echo ""
    echo "--- Producing distribution MP4 (stream copy, no re-encode) ---"
    echo "  Output: $MP4_FILE"

    ffmpeg -y -i "$INPUT_MKV" \
        -map 0:v:0 -map 0:a:0 \
        -vcodec copy -acodec copy \
        -movflags +faststart \
        "$MP4_FILE"

    echo ""
    echo "  Injecting chapters into MP4..."
    MP4_CHAP_TMP=$(mktemp /tmp/dvd_finish_mp4chap_XXXXXX.txt)
    awk '
        /^CHAPTER[0-9]+=/ && !/NAME/ {
            sub(/^CHAPTER[0-9]+=/, ""); ts = $0
        }
        /^CHAPTER[0-9]+NAME=/ {
            sub(/^CHAPTER[0-9]+NAME=/, ""); print ts " " $0
        }
    ' "$OGM_WORK" > "$MP4_CHAP_TMP"

    CHAPTERED_TMP=$(mktemp /tmp/dvd_finish_chaptered_XXXXXX.mp4)
    MP4Box -add "$MP4_FILE" -chap "$MP4_CHAP_TMP" -new "$CHAPTERED_TMP"
    mv "$CHAPTERED_TMP" "$MP4_FILE"
    rm -f "$MP4_CHAP_TMP"
    echo "  Done. $(du -h "$MP4_FILE" | cut -f1)"
fi

# ==============================================================================
# Integrity verification (optional)
# ==============================================================================
if [[ $HAVE_XXHSUM -eq 1 ]]; then
    echo ""
    echo "--- Integrity verification (XXH64) ---"
    HASH=$(xxhsum -H64 "$INPUT_MKV" | awk '{print $1}')
    echo "  XXH64: $HASH  $(basename "$INPUT_MKV")"
    if [[ "$NO_MP4" == false && -f "$MP4_FILE" ]]; then
        HASH=$(xxhsum -H64 "$MP4_FILE" | awk '{print $1}')
        echo "  XXH64: $HASH  $(basename "$MP4_FILE")"
    fi
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "========================================="
echo "  Complete"
echo "========================================="
echo "  MKV: $INPUT_MKV  ($(du -h "$INPUT_MKV" | cut -f1))"
[[ "$NO_MP4" == false && -f "$MP4_FILE" ]] \
    && echo "  MP4: $MP4_FILE  ($(du -h "$MP4_FILE" | cut -f1))"
echo ""
