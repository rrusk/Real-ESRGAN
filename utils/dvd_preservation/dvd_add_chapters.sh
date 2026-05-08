#!/bin/bash
# dvd_add_chapters.sh — Add chapter markers to an upscaled MKV or MP4 file
# using chapter timestamps previously extracted from a DVD or ISO image.
#
# This script is the companion to dvd_extract.sh, which produces the chapter
# files at extraction time.  Keeping the two operations separate means:
#   - chapter injection is independently repeatable without remounting the disc
#   - the extraction and upscaling workflows remain cleanly distinct
#
# Usage:
#   ./dvd_add_chapters.sh [OPTIONS] <video_file> <chapter_source>
#
#   <video_file>      Upscaled .mkv or .mp4 file to receive chapter markers, or
#                     a .mpg file for testing (remuxed to .mkv with chapters).
#
#   <chapter_source>  One of:
#     *.txt           OGM/Matroska chapter file produced by dvdxchap
#                     (e.g. <name>_chapters.txt from dvd_extract.sh).
#     *.json          lsdvd Python output file produced by dvd_extract.sh, used as a
#                     fallback when no OGM file is available.
#     *.iso           ISO image — script mounts it, runs dvdxchap/lsdvd, and
#                     injects chapters in one step.
#     <directory>     Mounted DVD directory containing VIDEO_TS/ — same as ISO.
#
# Options:
#   -t, --title N     DVD title number to extract chapters from when the
#                     chapter source is an ISO or directory (default: 1).
#   -n, --names FILE  Plain-text file of chapter titles, one per line, in
#                     chapter order.  The line count must exactly match the
#                     number of chapters in the OGM file.  Each line replaces
#                     the corresponding CHAPTERnnNAME value.  Lines are used
#                     as-is; leading/trailing whitespace is stripped.
#   -o, --output FILE Output filename for MP4 (which requires a remux and
#                     therefore a new file).  Ignored for MKV (in-place edit).
#                     Default: <stem>_chaptered.mp4
#   -h, --help        Show this help and exit.
#
# Behaviour by container:
#
#   MKV — mkvpropedit injects chapters in-place: no remux, no quality loss,
#         instant regardless of file size.  The input file is modified directly.
#
#   MP4 — mp4box requires a remux pass; a new output file is written.
#         The original file is not modified.  The OGM chapter format from
#         dvdxchap is converted to mp4box simple format automatically.
#
# Dependencies (all available via apt):
#   MKV path : mkvtoolnix  (mkvpropedit)
#   MP4 path : gpac        (mp4box)
#   ISO/dir  : ogmtools    (dvdxchap)   — primary chapter source
#              lsdvd                    — fallback / JSON inspection
#   ISO mount: sudo (for mount -o loop,ro)
#
set -euo pipefail

# ==============================================================================
# Defaults
# ==============================================================================
DVD_TITLE=1          # which DVD title to extract chapters from (--title)
NAMES_FILE=""        # optional chapter names file (--names)
OUTPUT_FILE=""       # MP4 output path (--output); derived from input if empty
CHAPTER_SOURCE=""    # positional arg 2
VIDEO_FILE=""        # positional arg 1

# ==============================================================================
# Usage
# ==============================================================================
usage() {
    sed -n '2,/^set -/{ /^set -/d; s/^# \{0,1\}//; p }' "$0"
    exit "${1:-0}"
}

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--title)
            DVD_TITLE="$2"; shift 2 ;;
        -n|--names)
            NAMES_FILE="$2"; shift 2 ;;
        -o|--output)
            OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)
            usage 0 ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            usage 1 ;;
        *)
            if [[ -z "$VIDEO_FILE" ]]; then
                VIDEO_FILE="$1"
            elif [[ -z "$CHAPTER_SOURCE" ]]; then
                CHAPTER_SOURCE="$1"
            else
                echo "[ERROR] Unexpected argument: $1"
                usage 1
            fi
            shift ;;
    esac
done

if [[ -z "$VIDEO_FILE" || -z "$CHAPTER_SOURCE" ]]; then
    echo "[ERROR] Both <video_file> and <chapter_source> are required."
    echo ""
    usage 1
fi

# ==============================================================================
# Dependency pre-flight check
#
# Tools are probed first; the full status table is printed before any decision.
# Only tools relevant to the actual operation need to be present, but the table
# shows everything so the user knows the complete picture up front.
# ==============================================================================
echo ""
echo "========================================="
echo "  dvd_add_chapters.sh — dependency check"
echo "========================================="
echo ""

HAVE_FFMPEG=0
command -v ffmpeg      >/dev/null 2>&1 && HAVE_FFMPEG=1

HAVE_MKVPROPEDIT=0
command -v mkvpropedit >/dev/null 2>&1 && HAVE_MKVPROPEDIT=1

HAVE_MKVMERGE=0
command -v mkvmerge    >/dev/null 2>&1 && HAVE_MKVMERGE=1

HAVE_MP4BOX=0
command -v MP4Box      >/dev/null 2>&1 && HAVE_MP4BOX=1

HAVE_DVDXCHAP=0
command -v dvdxchap    >/dev/null 2>&1 && HAVE_DVDXCHAP=1

HAVE_LSDVD=0
command -v lsdvd       >/dev/null 2>&1 && HAVE_LSDVD=1

if [[ $HAVE_FFMPEG -eq 1 ]]; then
    echo "  [OK]   ffmpeg          — MPG remux to MKV (required for .mpg input)"
else
    echo "  [MISS] ffmpeg          — MPG remux to MKV (required for .mpg input)"
    echo "                           sudo apt install ffmpeg"
fi

if [[ $HAVE_MKVPROPEDIT -eq 1 ]]; then
    echo "  [OK]   mkvpropedit     — MKV in-place chapter injection (mkvtoolnix)"
else
    echo "  [MISS] mkvpropedit     — MKV in-place chapter injection"
    echo "                           sudo apt install mkvtoolnix"
fi

if [[ $HAVE_MKVMERGE -eq 1 ]]; then
    echo "  [OK]   mkvmerge        — MPG/MKV chapter muxing (mkvtoolnix)"
else
    echo "  [MISS] mkvmerge        — MPG/MKV chapter muxing"
    echo "                           Required when input is .mpg (remux to MKV)."
    echo "                           sudo apt install mkvtoolnix"
fi

if [[ $HAVE_MP4BOX -eq 1 ]]; then
    echo "  [OK]   MP4Box          — MP4 chapter muxing (gpac)"
else
    echo "  [MISS] MP4Box          — MP4 chapter muxing"
    echo "                           sudo apt install gpac"
fi

if [[ $HAVE_DVDXCHAP -eq 1 ]]; then
    echo "  [OK]   dvdxchap        — DVD chapter extraction from ISO/dir (ogmtools)"
else
    echo "  [MISS] dvdxchap        — DVD chapter extraction from ISO/dir"
    echo "                           Required when <chapter_source> is an ISO or"
    echo "                           directory rather than a pre-extracted .txt file."
    echo "                           sudo apt install ogmtools"
fi

if [[ $HAVE_LSDVD -eq 1 ]]; then
    echo "  [OK]   lsdvd           — DVD structure fallback / JSON (lsdvd)"
else
    echo "  [MISS] lsdvd           — DVD structure fallback / JSON"
    echo "                           sudo apt install lsdvd"
fi

echo ""

# Determine which tools are actually required for this specific invocation,
# then check availability and collect any gaps before prompting once.
EXT="${VIDEO_FILE##*.}"
EXT="${EXT,,}"   # lowercase

SOURCE_EXT="${CHAPTER_SOURCE##*.}"
SOURCE_EXT="${SOURCE_EXT,,}"

MISSING_PKGS=()

# Container-specific requirement
if [[ "$EXT" == "mkv" && $HAVE_MKVPROPEDIT -eq 0 ]]; then
    MISSING_PKGS+=(mkvtoolnix)
fi
if [[ "$EXT" == "mpg" && ($HAVE_FFMPEG -eq 0 || $HAVE_MKVPROPEDIT -eq 0) ]]; then
    [[ $HAVE_FFMPEG      -eq 0 ]] && MISSING_PKGS+=(ffmpeg)
    [[ $HAVE_MKVPROPEDIT -eq 0 ]] && MISSING_PKGS+=(mkvtoolnix)
fi
if [[ "$EXT" == "mp4" && $HAVE_MP4BOX -eq 0 ]]; then
    MISSING_PKGS+=(gpac)
fi

# Source-specific requirement (ISO or directory needs a chapter extractor)
if [[ "$SOURCE_EXT" == "iso" || -d "$CHAPTER_SOURCE" ]]; then
    if [[ $HAVE_DVDXCHAP -eq 0 && $HAVE_LSDVD -eq 0 ]]; then
        MISSING_PKGS+=(ogmtools lsdvd)
    elif [[ $HAVE_DVDXCHAP -eq 0 ]]; then
        MISSING_PKGS+=(ogmtools)
    fi
fi

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo "  The following packages are required for this operation but are missing:"
    for pkg in "${MISSING_PKGS[@]}"; do
        echo "    - $pkg"
    done
    echo ""
    echo "  Install:"
    echo "    sudo apt install ${MISSING_PKGS[*]}"
    echo ""
    echo "Exiting. Install the packages above and re-run."
    exit 1
fi

# ==============================================================================
# Validate video file
# ==============================================================================
if [[ ! -f "$VIDEO_FILE" ]]; then
    echo "[ERROR] Video file not found: $VIDEO_FILE"
    exit 1
fi

if [[ "$EXT" != "mkv" && "$EXT" != "mp4" && "$EXT" != "mpg" ]]; then
    echo "[ERROR] Unsupported video format '.$EXT'. Supported: .mkv, .mp4, .mpg"
    exit 1
fi

# ==============================================================================
# Resolve chapter source → OGM chapter file
#
# Four cases:
#   .txt  — already OGM format from dvdxchap; use directly.
#   .py  — lsdvd Python output; convert to OGM format via awk.
#   .iso  — mount, run dvdxchap (or lsdvd fallback), unmount.
#   dir   — run dvdxchap (or lsdvd fallback) directly.
# ==============================================================================
MOUNT_POINT=""
MOUNTED_ISO=0
TEMP_OGM=""      # set if we create a temporary OGM file that should be cleaned up

cleanup() {
    if [[ $MOUNTED_ISO -eq 1 && -n "$MOUNT_POINT" ]]; then
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
    [[ -n "$TEMP_OGM" && -f "$TEMP_OGM" ]] && rm -f "$TEMP_OGM"
}
trap cleanup EXIT

OGM_FILE=""   # the OGM chapter file we will ultimately consume

echo "--- Resolving chapter source ---"

case "$SOURCE_EXT" in

    txt)
        # Pre-extracted OGM file from dvdxchap — use directly.
        if [[ ! -f "$CHAPTER_SOURCE" ]]; then
            echo "[ERROR] Chapter file not found: $CHAPTER_SOURCE"
            exit 1
        fi
        OGM_FILE="$CHAPTER_SOURCE"
        NUM_CHAP=$(grep -c '^CHAPTER[0-9]*=' "$OGM_FILE" 2>/dev/null || echo 0)
        echo "  OGM chapter file: $OGM_FILE ($NUM_CHAP chapters)"
        ;;

    py)
        # lsdvd Python output (.py) from dvd_extract.sh — convert to OGM format.
        # lsdvd -Oy emits a Python dict literal assigned to $lsdvd.
        # We strip the assignment and eval() the dict, then extract chapter timestamps.
        if [[ ! -f "$CHAPTER_SOURCE" ]]; then
            echo "[ERROR] lsdvd Python output file not found: $CHAPTER_SOURCE"
            exit 1
        fi
        echo "  lsdvd Python output: $CHAPTER_SOURCE — converting to OGM format..."
        TEMP_OGM=$(mktemp /tmp/dvd_chapters_XXXXXX.txt)
        python3 - "$CHAPTER_SOURCE" "$DVD_TITLE" "$TEMP_OGM" <<'PYEOF'
import sys, re

src_path  = sys.argv[1]
title_num = int(sys.argv[2])
out_path  = sys.argv[3]

with open(src_path) as f:
    src = f.read()

# lsdvd -Oy writes libdvdread diagnostic lines to stdout before the dict.
# Strip them, then remove the bare assignment prefix so we can eval() the dict.
# 'track' holds the title list; 'title' is just the disc title string.
lines = src.splitlines()
dict_lines = []
in_dict = False
for line in lines:
    if re.match(r'^\w+\s*=\s*\{', line):
        in_dict = True
    if in_dict:
        dict_lines.append(line)
src = '\n'.join(dict_lines)
src = re.sub(r'^\s*\w+\s*=\s*', '', src, count=1).strip()
data = eval(src)  # safe: our own lsdvd output on a local file

tracks = data.get("track", [])
if not isinstance(tracks, list):
    tracks = [tracks]

if not tracks:
    print("[ERROR] No tracks found.", file=sys.stderr); sys.exit(1)

if title_num < 1 or title_num > len(tracks):
    print(f"[ERROR] Title {title_num} not found; disc has {len(tracks)} title(s).",
          file=sys.stderr); sys.exit(1)

track    = tracks[title_num - 1]
chapters = track.get("chapter", [])
if not isinstance(chapters, list):
    chapters = [chapters]

if not chapters:
    print("[ERROR] No chapters in title.", file=sys.stderr); sys.exit(1)

lines = []
for i, ch in enumerate(chapters, start=1):
    secs = float(ch.get("startcell", 0))
    h    = int(secs // 3600)
    m    = int((secs % 3600) // 60)
    s    = secs % 60
    ts   = f"{h:02d}:{m:02d}:{s:06.3f}"
    lines.append(f"CHAPTER{i:02d}={ts}")
    lines.append(f"CHAPTER{i:02d}NAME=Chapter {i:02d}")

with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"  Converted {len(chapters)} chapter(s) to OGM format.")
PYEOF
        OGM_FILE="$TEMP_OGM"
        NUM_CHAP=$(grep -c '^CHAPTER[0-9]*=' "$OGM_FILE" 2>/dev/null || echo 0)
        echo "  Converted: $NUM_CHAP chapter(s)"
        ;;

    iso|*)
        # ISO file or mounted directory — run dvdxchap or lsdvd.
        DVD_DIR=""
        if [[ "$SOURCE_EXT" == "iso" ]]; then
            if [[ ! -f "$CHAPTER_SOURCE" ]]; then
                echo "[ERROR] ISO file not found: $CHAPTER_SOURCE"
                exit 1
            fi
            MOUNT_POINT=$(mktemp -d /tmp/dvd_mount_XXXXXX)
            echo "  Mounting ISO: $CHAPTER_SOURCE"
            sudo mount -o loop,ro "$CHAPTER_SOURCE" "$MOUNT_POINT"
            MOUNTED_ISO=1
            DVD_DIR="$MOUNT_POINT"
        elif [[ -d "$CHAPTER_SOURCE" ]]; then
            DVD_DIR="$CHAPTER_SOURCE"
            echo "  Using DVD directory: $DVD_DIR"
        else
            echo "[ERROR] Cannot interpret chapter source: $CHAPTER_SOURCE"
            echo "        Expected: .txt, .json, .iso, or a directory."
            exit 1
        fi

        TEMP_OGM=$(mktemp /tmp/dvd_chapters_XXXXXX.txt)

        if [[ $HAVE_DVDXCHAP -eq 1 ]]; then
            echo "  Running dvdxchap -t $DVD_TITLE ..."
            if dvdxchap -t "$DVD_TITLE" "$DVD_DIR" > "$TEMP_OGM" 2>/dev/null \
                    && [[ -s "$TEMP_OGM" ]]; then
                NUM_CHAP=$(grep -c '^CHAPTER[0-9]*=' "$TEMP_OGM" 2>/dev/null || echo 0)
                echo "  dvdxchap: $NUM_CHAP chapter(s) found."
                OGM_FILE="$TEMP_OGM"
            else
                echo "  [WARN] dvdxchap found no chapters for title $DVD_TITLE."
                echo "         Check the title number with: lsdvd -c $DVD_DIR"
                rm -f "$TEMP_OGM"; TEMP_OGM=""
            fi
        fi

        # lsdvd fallback — only reached if dvdxchap failed or is absent.
        if [[ -z "$OGM_FILE" && $HAVE_LSDVD -eq 1 ]]; then
            echo "  Falling back to lsdvd..."
            PY_TMP=$(mktemp /tmp/dvd_lsdvd_XXXXXX.py)
            if lsdvd -c -Oy "$DVD_DIR" > "$PY_TMP" 2>/dev/null \
                    && [[ -s "$PY_TMP" ]]; then
                TEMP_OGM=$(mktemp /tmp/dvd_chapters_XXXXXX.txt)
                python3 - "$PY_TMP" "$DVD_TITLE" "$TEMP_OGM" <<'PYEOF'
import sys, re

src_path  = sys.argv[1]
title_num = int(sys.argv[2])
out_path  = sys.argv[3]

with open(src_path) as f:
    src = f.read()

# lsdvd -Oy writes libdvdread diagnostic lines to stdout before the dict.
# Strip them, then remove the bare assignment prefix so we can eval() the dict.
lines = src.splitlines()
dict_lines = []
in_dict = False
for line in lines:
    if re.match(r'^\w+\s*=\s*\{', line):
        in_dict = True
    if in_dict:
        dict_lines.append(line)
src = '\n'.join(dict_lines)
src  = re.sub(r'^\s*\w+\s*=\s*', '', src, count=1).strip()
data = eval(src)  # safe: our own lsdvd output on a local file

tracks = data.get("track", [])
if not isinstance(tracks, list):
    tracks = [tracks]

if not tracks:
    print("[ERROR] No tracks in lsdvd output.", file=sys.stderr); sys.exit(1)

if title_num < 1 or title_num > len(tracks):
    print(f"[ERROR] Title {title_num} not found; disc has {len(tracks)} title(s).",
          file=sys.stderr); sys.exit(1)

track    = tracks[title_num - 1]
chapters = track.get("chapter", [])
if not isinstance(chapters, list):
    chapters = [chapters]

if not chapters:
    print("[ERROR] No chapters in title.", file=sys.stderr); sys.exit(1)

lines = []
for i, ch in enumerate(chapters, start=1):
    secs = float(ch.get("startcell", 0))
    h    = int(secs // 3600)
    m    = int((secs % 3600) // 60)
    s    = secs % 60
    ts   = f"{h:02d}:{m:02d}:{s:06.3f}"
    lines.append(f"CHAPTER{i:02d}={ts}")
    lines.append(f"CHAPTER{i:02d}NAME=Chapter {i:02d}")

with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"  Converted {len(chapters)} chapter(s) to OGM format.")
PYEOF
                OGM_FILE="$TEMP_OGM"
                NUM_CHAP=$(grep -c '^CHAPTER[0-9]*=' "$OGM_FILE" 2>/dev/null || echo 0)
                echo "  lsdvd fallback: $NUM_CHAP chapter(s)."
            fi
            rm -f "$PY_TMP"
        fi

        if [[ -z "$OGM_FILE" ]]; then
            echo "[ERROR] Could not extract any chapter information from: $CHAPTER_SOURCE"
            exit 1
        fi
        ;;
esac

if [[ ! -s "$OGM_FILE" ]]; then
    echo "[ERROR] OGM chapter file is empty: $OGM_FILE"
    exit 1
fi

# ==============================================================================
# Apply chapter name replacements (--names FILE)
#
# If a names file was supplied, read it line by line and replace the
# CHAPTERnnNAME= values in the OGM file in order.  The names file must
# contain exactly as many non-empty lines as there are chapters.
#
# The substitution writes to a temporary copy of the OGM so the original
# file (which the caller may want to keep unmodified) is never changed.
# ==============================================================================
if [[ -n "$NAMES_FILE" ]]; then
    if [[ ! -f "$NAMES_FILE" ]]; then
        echo "[ERROR] Names file not found: $NAMES_FILE"
        exit 1
    fi

    # Count chapters in OGM and names in file (ignoring blank lines).
    OGM_CHAP_COUNT=$(grep -c '^CHAPTER[0-9]*NAME=' "$OGM_FILE" 2>/dev/null || echo 0)
    NAMES_COUNT=$(grep -c '[^[:space:]]' "$NAMES_FILE" 2>/dev/null || echo 0)

    if [[ "$OGM_CHAP_COUNT" -ne "$NAMES_COUNT" ]]; then
        echo "[ERROR] Chapter count mismatch:"
        echo "        OGM file has $OGM_CHAP_COUNT chapter(s)."
        echo "        Names file has $NAMES_COUNT line(s)."
        echo "        They must match exactly."
        exit 1
    fi

    echo "--- Applying chapter names ---"
    echo "  Names file:    $NAMES_FILE  ($NAMES_COUNT name(s))"
    echo "  OGM (source):  $OGM_FILE"

    NAMED_OGM=$(mktemp /tmp/dvd_named_ogm_XXXXXX.txt)
    # Register for cleanup alongside any other temp files.
    # (The cleanup trap already handles TEMP_OGM; add this one explicitly.)
    trap 'rm -f "$NAMED_OGM" 2>/dev/null; '"$(trap -p EXIT | sed "s/trap -- '//;s/' EXIT//")" EXIT

    python3 - "$OGM_FILE" "$NAMES_FILE" "$NAMED_OGM" << 'INNERPY'
import sys, re

ogm_path   = sys.argv[1]
names_path = sys.argv[2]
out_path   = sys.argv[3]

with open(ogm_path) as f:
    ogm_lines = f.readlines()

with open(names_path) as f:
    # Strip whitespace; skip blank lines.
    names = [ln.strip() for ln in f if ln.strip()]

name_iter = iter(names)
out = []
for line in ogm_lines:
    if re.match(r'CHAPTER\d+NAME=', line):
        num   = re.match(r'(CHAPTER\d+NAME)=', line).group(1)
        title = next(name_iter)
        out.append(f'{num}={title}\n')
    else:
        out.append(line)

with open(out_path, 'w') as f:
    f.writelines(out)

print(f'  Applied {len(names)} chapter name(s).')
INNERPY

    # Show the resulting chapter list for confirmation.
    echo ""
    echo "  Chapter list after applying names:"
    grep '^CHAPTER[0-9]*' "$NAMED_OGM" | paste - - | while IFS=$'\t' read -r ts name; do
        printf "    %s  |  %s\n" "$ts" "$name"
    done
    echo ""

    # Use the named copy for injection; leave original OGM untouched.
    OGM_FILE="$NAMED_OGM"
fi

echo ""

# ==============================================================================
# Convert OGM chapter file to Matroska XML
#
# mkvmerge and mkvpropedit identify chapter format by file extension and
# content.  Passing a .txt file can fail on older mkvmerge versions (e.g.
# v65) even when the content is valid OGM.  Matroska XML (.xml) is
# unambiguous and accepted by all mkvtoolnix versions.
# MP4Box uses its own format and is handled separately below.
# ==============================================================================
CHAP_XML=$(mktemp /tmp/dvd_chapters_XXXXXX.xml)
python3 - "$OGM_FILE" "$CHAP_XML" << 'XMLPY'
import sys, re

with open(sys.argv[1]) as f:
    lines = f.read().strip().splitlines()

entries = {}
order   = []
for line in lines:
    m = re.match(r'CHAPTER(\d+)(NAME)?=(.*)', line)
    if not m:
        continue
    num, is_name, val = m.group(1), m.group(2), m.group(3).strip()
    if num not in entries:
        entries[num] = {}
        order.append(num)
    if is_name:
        entries[num]['name'] = val
    else:
        entries[num]['time'] = val

xml = ['<?xml version="1.0" encoding="UTF-8"?>',
       '<!DOCTYPE Chapters SYSTEM "matroskachapters.dtd">',
       '<Chapters><EditionEntry>']
for num in order:
    t = entries[num].get('time', '00:00:00.000')
    n = entries[num].get('name', f'Chapter {int(num):02d}')
    xml.append(f'  <ChapterAtom>')
    xml.append(f'    <ChapterTimeStart>{t}</ChapterTimeStart>')
    xml.append(f'    <ChapterDisplay><ChapterString>{n}</ChapterString></ChapterDisplay>')
    xml.append(f'  </ChapterAtom>')
xml.append('</EditionEntry></Chapters>')

with open(sys.argv[2], 'w') as f:
    f.write('\n'.join(xml) + '\n')
XMLPY

# ==============================================================================
# Inject chapters into the video file
# ==============================================================================
echo "--- Adding chapters ---"
echo "  Video:    $VIDEO_FILE"
echo "  Chapters: $OGM_FILE"
echo ""

case "$EXT" in

    mkv)
        # mkvpropedit modifies the MKV container in-place.
        # No remux: the video/audio streams are not touched.
        # Uses Matroska XML for unambiguous format detection.
        echo "  MKV: injecting chapters in-place with mkvpropedit..."
        mkvpropedit "$VIDEO_FILE" --chapters "$CHAP_XML"
        rm -f "$CHAP_XML"
        echo ""
        echo "  Done. Chapters written to: $VIDEO_FILE"
        ;;

    mp4)
        # MP4Box requires a remux; a new output file must be written.
        # Uses its own simple text format (HH:MM:SS.mmm Chapter Name),
        # converted from the OGM file via awk.
        VIDEO_STEM="${VIDEO_FILE%.*}"
        if [[ -z "$OUTPUT_FILE" ]]; then
            OUTPUT_FILE="${VIDEO_STEM}_chaptered.mp4"
        fi

        MP4_CHAP_TMP=$(mktemp /tmp/dvd_chapters_mp4_XXXXXX.txt)
        awk '
            /^CHAPTER[0-9]+=/ && !/NAME/ {
                sub(/^CHAPTER[0-9]+=/, ""); ts = $0
            }
            /^CHAPTER[0-9]+NAME=/ {
                sub(/^CHAPTER[0-9]+NAME=/, ""); print ts " " $0
            }
        ' "$OGM_FILE" > "$MP4_CHAP_TMP"

        echo "  MP4: muxing chapters with MP4Box (remux required — new file)..."
        echo "  Output: $OUTPUT_FILE"
        MP4Box -add "$VIDEO_FILE" -chap "$MP4_CHAP_TMP" -new "$OUTPUT_FILE"
        rm -f "$MP4_CHAP_TMP" "$CHAP_XML"
        echo ""
        echo "  Done. Chapters written to: $OUTPUT_FILE"
        echo "  Original file unchanged:   $VIDEO_FILE"
        ;;

    mpg)
        # MPEG-2 program stream: transcode to MKV via ffmpeg, then inject
        # chapters in-place with mkvpropedit.
        #
        # Why not stream copy throughout:
        #   VOB concatenation produces non-monotonous DTS and no reliable
        #   container duration.  Stream-copying into MKV inherits these broken
        #   timestamps, resulting in a near-zero reported duration and a file
        #   that exits immediately on playback.
        #
        # Fixes applied:
        #   -fflags +genpts  -- regenerate PTS from scratch, discarding the
        #                       broken VOB timestamps entirely.
        #   -vcodec copy     -- video bitstream unchanged; only timestamps fixed.
        #   -acodec aac      -- transcode AC3 to AAC 192k.  AAC is universally
        #                       supported (VLC, mpv, browsers, TVs) and avoids
        #                       the AC3 S/PDIF passthrough issues with VLC.
        #                       Original AC3 is preserved in the source .mpg.
        #
        # Output filename replaces .mpg with .mkv.
        VIDEO_STEM="${VIDEO_FILE%.*}"
        if [[ -z "$OUTPUT_FILE" ]]; then
            OUTPUT_FILE="${VIDEO_STEM}.mkv"
        fi
        echo "  MPG: transcoding to MKV with timestamp repair (ffmpeg)..."
        echo "       Video: stream copy  |  Audio: AC3 -> AAC 192k"
        echo "  Output: $OUTPUT_FILE"
        ffmpeg -y -fflags +genpts -i "$VIDEO_FILE" \
            -map 0:v:0 -map 0:a:0 \
            -vcodec copy -acodec aac -b:a 192k \
            "$OUTPUT_FILE"
        # Inject chapters into the finished MKV in-place (no second remux).
        mkvpropedit "$OUTPUT_FILE" --chapters "$CHAP_XML"
        rm -f "$CHAP_XML"
        echo ""
        echo "  Done. MKV with chapters: $OUTPUT_FILE"
        echo "  Original MPG unchanged:  $VIDEO_FILE"
        ;;
esac

echo ""
