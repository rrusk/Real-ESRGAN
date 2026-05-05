#!/bin/bash
# dvd_extract.sh — Extract MPEG-2 video from a DVD or mounted ISO image,
# and capture chapter timestamps from the IFO metadata for use when
# muxing upscaled output into MKV and MP4 distribution files.
#
# Usage:
#   ./dvd_extract.sh [OPTIONS] <dvd_mount_point_or_iso>
#
# Arguments:
#   <dvd_mount_point_or_iso>
#       Path to an already-mounted DVD directory (must contain VIDEO_TS/),
#       or a path to a .iso file which this script will mount itself.
#
# Options:
#   -o, --output-dir DIR   Directory for all output files (default: current
#                          working directory).  Created if it does not exist.
#   -h, --help             Show this help and exit.
#
# Output files (written to <output-dir>):
#   <name>.mpg
#       Concatenated MPEG-2 stream (stream copy, lossless).
#       Overwrites any previous extraction of the same disc.
#   <name>_title_NN_chapters.txt
#       OGM/Matroska chapter timestamps extracted by dvdxchap.
#       One file per title.  Direct input to mkvmerge and mkvpropedit;
#       converted to MP4Box format automatically by dvd_add_chapters.sh.
#   <name>_lsdvd.py
#       Python dict literal from lsdvd -Oy; useful for disc structure
#       inspection and as a fallback chapter source.
#
# Chapter files are produced before the (slow) VOB extraction so they are
# available immediately, even if the ffmpeg step is interrupted.
#
# Applying chapters to upscaled output (see also dvd_add_chapters.sh):
#
#   MKV — in-place inject, no remux, instant:
#     mkvpropedit upscaled.mkv --chapters <name>_title_01_chapters.txt
#
#   MKV — during initial mux:
#     mkvmerge -o upscaled.mkv --chapters <name>_title_01_chapters.txt input.mkv
#
#   MP4 or MPG — via dvd_add_chapters.sh:
#     dvd_add_chapters.sh upscaled.mp4 <name>_title_01_chapters.txt
#
# Dependencies (all available via apt):
#   Required : ffmpeg
#   Chapter  : ogmtools   (dvdxchap -- OGM/Matroska chapter extraction)
#              lsdvd      (disc structure -- title count and duration)
#              mkvtoolnix (mkvmerge, mkvpropedit -- MKV muxing/chapter inject)
#              gpac       (MP4Box -- MP4 chapter muxing)
#   ISO mount: sudo (for mount -o loop,ro)
#   Optional : xxhash     (xxhsum -- fast integrity verification)
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
# Argument parsing
# Must happen before the dependency check so --help exits cleanly without
# running the probe loop or printing the dependency table.
# ==============================================================================
OUTPUT_DIR="."   # default: current working directory
INPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            echo "Run with --help for usage."
            exit 1 ;;
        *)
            if [[ -z "$INPUT" ]]; then
                INPUT="$1"
            else
                echo "[ERROR] Unexpected argument: $1"
                echo "Run with --help for usage."
                exit 1
            fi
            shift ;;
    esac
done

if [[ -z "$INPUT" ]]; then
    echo "[ERROR] No input specified."
    echo "Run with --help for usage."
    exit 1
fi

# ==============================================================================
# Dependency pre-flight check
#
# All tools are probed first and the full status table is printed before any
# decision is made -- the user sees the complete picture in one pass.
#
# Tool tiers:
#   CRITICAL  -- ffmpeg: hard abort if missing.
#   IMPORTANT -- chapter/muxing tools: extraction still produces a .mpg without
#                them, but chapter files and next-step commands will be absent.
#                User is shown the full missing list and asked once.
#   OPTIONAL  -- xxhsum: silently skipped if absent.
# ==============================================================================
echo ""
echo "========================================="
echo "  dvd_extract.sh -- dependency check"
echo "========================================="
echo ""

HAVE_FFMPEG=0;      command -v ffmpeg      >/dev/null 2>&1 && HAVE_FFMPEG=1
HAVE_DVDXCHAP=0;    command -v dvdxchap   >/dev/null 2>&1 && HAVE_DVDXCHAP=1
HAVE_LSDVD=0;       command -v lsdvd      >/dev/null 2>&1 && HAVE_LSDVD=1
HAVE_MKVTOOLNIX=0
if command -v mkvmerge >/dev/null 2>&1 && command -v mkvpropedit >/dev/null 2>&1; then
    HAVE_MKVTOOLNIX=1
fi
HAVE_MP4BOX=0;      command -v MP4Box     >/dev/null 2>&1 && HAVE_MP4BOX=1
HAVE_XXHSUM=0;      command -v xxhsum     >/dev/null 2>&1 && HAVE_XXHSUM=1

if [[ $HAVE_FFMPEG     -eq 1 ]]; then echo "  [OK]   ffmpeg          -- video extraction (required)"
else                                   echo "  [MISS] ffmpeg          -- video extraction (required)"
                                       echo "                           sudo apt install ffmpeg"; fi

if [[ $HAVE_DVDXCHAP   -eq 1 ]]; then echo "  [OK]   dvdxchap        -- OGM/Matroska chapter extraction (ogmtools)"
else                                   echo "  [MISS] dvdxchap        -- OGM/Matroska chapter extraction"
                                       echo "                           Produces chapter timestamps consumed directly"
                                       echo "                           by mkvmerge and mkvpropedit; no conversion needed."
                                       echo "                           sudo apt install ogmtools"; fi

if [[ $HAVE_LSDVD      -eq 1 ]]; then echo "  [OK]   lsdvd           -- disc structure / title count (lsdvd)"
else                                   echo "  [MISS] lsdvd           -- disc structure / title count"
                                       echo "                           Reports how many titles are on the disc so"
                                       echo "                           all titles get their own chapter file."
                                       echo "                           sudo apt install lsdvd"; fi

if [[ $HAVE_MKVTOOLNIX -eq 1 ]]; then echo "  [OK]   mkvtoolnix      -- MKV chapter muxing (mkvmerge + mkvpropedit)"
else                                   echo "  [MISS] mkvtoolnix      -- MKV chapter muxing"
                                       echo "                           mkvpropedit: inject chapters in-place, no remux."
                                       echo "                           mkvmerge:    mux chapters during encode."
                                       echo "                           sudo apt install mkvtoolnix"; fi

if [[ $HAVE_MP4BOX     -eq 1 ]]; then echo "  [OK]   MP4Box          -- MP4 chapter muxing (gpac)"
else                                   echo "  [MISS] MP4Box          -- MP4 chapter muxing"
                                       echo "                           Required to add chapters to MP4 output."
                                       echo "                           Note: MP4 chapter insertion always requires"
                                       echo "                           a remux pass (new file); MKV does not."
                                       echo "                           sudo apt install gpac"; fi

if [[ $HAVE_XXHSUM     -eq 1 ]]; then echo "  [OK]   xxhsum          -- XXH64 integrity verification (xxhash)"
else                                   echo "  [----] xxhsum          -- XXH64 integrity verification (optional)"
                                       echo "                           sudo apt install xxhash"; fi

echo ""

# Hard abort if ffmpeg is missing.
if [[ $HAVE_FFMPEG -eq 0 ]]; then
    echo "[ERROR] ffmpeg is required and not installed. Aborting."
    exit 1
fi

# Collect missing important tools and ask once whether to continue.
MISSING_PKGS=()
[[ $HAVE_DVDXCHAP   -eq 0 ]] && MISSING_PKGS+=(ogmtools)
[[ $HAVE_LSDVD      -eq 0 ]] && MISSING_PKGS+=(lsdvd)
[[ $HAVE_MKVTOOLNIX -eq 0 ]] && MISSING_PKGS+=(mkvtoolnix)
[[ $HAVE_MP4BOX     -eq 0 ]] && MISSING_PKGS+=(gpac)

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo "  The following important packages are missing:"
    for pkg in "${MISSING_PKGS[@]}"; do
        echo "    - $pkg"
    done
    echo ""
    echo "  Install all at once:"
    echo "    sudo apt install ${MISSING_PKGS[*]}"
    echo ""
    echo "  Without these tools, no chapter files will be produced."
    echo "  The .mpg extraction will still complete successfully."
    echo ""
    printf "  Continue without the missing tools? [y/N] "
    read -r _answer </dev/tty
    if [[ ! "$_answer" =~ ^[Yy]$ ]]; then
        echo "Exiting. Install the packages above and re-run."
        exit 1
    fi
    echo ""
fi

# ==============================================================================
# Output directory
# ==============================================================================
if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
fi

# ==============================================================================
# ISO detection and mounting
#
# If the argument is a .iso file, mount it to a temporary directory.
# The mount point is cleaned up on EXIT via trap.
# If the argument is already a directory, use it directly.
# ==============================================================================
MOUNT_POINT=""
MOUNTED_ISO=0

cleanup_mount() {
    if [[ $MOUNTED_ISO -eq 1 && -n "$MOUNT_POINT" ]]; then
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
        rmdir  "$MOUNT_POINT" 2>/dev/null || true
    fi
}
trap cleanup_mount EXIT

if [[ "${INPUT,,}" == *.iso ]]; then
    if [[ ! -f "$INPUT" ]]; then
        echo "[ERROR] ISO file not found: $INPUT"
        exit 1
    fi
    MOUNT_POINT=$(mktemp -d /tmp/dvd_mount_XXXXXX)
    echo "Mounting ISO: $INPUT"
    echo "Mount point:  $MOUNT_POINT"
    sudo mount -o loop,ro "$INPUT" "$MOUNT_POINT"
    MOUNTED_ISO=1
    DVD_MOUNT="$MOUNT_POINT"
    # Strip .iso / .ISO extension (case-insensitive) from the stem.
    ISO_STEM=$(basename "$INPUT"); ISO_STEM="${ISO_STEM%.[Ii][Ss][Oo]}"
elif [[ -d "$INPUT" ]]; then
    DVD_MOUNT="$INPUT"
    ISO_STEM=$(basename "$DVD_MOUNT")
else
    echo "[ERROR] Argument must be a .iso file or a mounted DVD directory: $INPUT"
    exit 1
fi

VIDEO_TS="$DVD_MOUNT/VIDEO_TS"
if [[ ! -d "$VIDEO_TS" ]]; then
    echo "[ERROR] VIDEO_TS directory not found at '$VIDEO_TS'"
    exit 1
fi

# ==============================================================================
# VOB discovery -- content segments only
#
# VTS_xx_0.VOB files are menu/navigation VOBs.  They often carry a different
# audio stream layout which causes the "multiple audio stream" issue.
# The glob VTS_*_[1-9]*.VOB selects only content segments (_1, _2, ...).
# ==============================================================================
mapfile -t VOBS < <(ls "$VIDEO_TS"/VTS_*_[1-9]*.VOB 2>/dev/null || true)
NUM_VOBS=${#VOBS[@]}

if [[ $NUM_VOBS -eq 0 ]]; then
    echo "[ERROR] No content VOB files found in '$VIDEO_TS'"
    echo "        (menu-only _0.VOB files are excluded by design)"
    exit 1
fi

# ==============================================================================
# Output filenames (all rooted under OUTPUT_DIR)
# ==============================================================================
OUTPUT_FILE="${OUTPUT_DIR}/${ISO_STEM}.mpg"
CHAPTER_PY="${OUTPUT_DIR}/${ISO_STEM}_lsdvd.py"
# OGM chapter files use this stem; title number and suffix appended in the loop.
CHAPTER_STEM="${OUTPUT_DIR}/${ISO_STEM}"

echo "========================================="
echo "  DVD Extraction"
echo "========================================="
echo "  Source:       $DVD_MOUNT"
echo "  VOB segments: $NUM_VOBS (content only; menu VOBs excluded)"
echo "  Output dir:   $OUTPUT_DIR"
echo "  Output MPG:   $(basename "$OUTPUT_FILE")"
echo "========================================="
echo ""

# ==============================================================================
# Chapter extraction from IFO metadata
#
# Strategy:
#   1. lsdvd determines how many titles the disc has (fast -- IFO reads only).
#      This runs before dvdxchap so we know how many OGM files to produce.
#   2. dvdxchap is run for every title, producing one OGM file per title.
#      OGM (plain text HH:MM:SS.mmm) is the most flexible interchange format:
#      direct input to mkvmerge/mkvpropedit, and converted to MP4Box format
#      automatically by dvd_add_chapters.sh.
#   3. If the disc has more than one title the user is warned and a title
#      table (number, duration, chapter count) is printed.
#
# Both tools run before the slow VOB extraction so chapter files are available
# immediately even if the ffmpeg step is interrupted.
#
# lsdvd 0.17 -Oy output format (current Ubuntu/Debian package):
#   lsdvd = { 'track': [...], 'title': 'disc title string', ... }
#   - Variable name has NO $ prefix (unlike Perl -Op output).
#   - Top-level key for the title list is 'track' (confusingly, 'title' holds
#     the disc title string, not the track list).
#   - lsdvd also writes libdvdread noise lines to stdout before the dict;
#     these are stripped before eval().
#   - Single-title disc may emit 'track' as a dict rather than a one-item list.
# ==============================================================================
echo "--- Chapter extraction ---"
echo ""

NUM_TITLES=0
CHAPTERS_OK=0

# --------------------------------------------------------------------------
# Step 1 -- lsdvd: count titles and collect per-title metadata
# --------------------------------------------------------------------------
if [[ $HAVE_LSDVD -eq 1 ]]; then
    if lsdvd -c -Oy "$DVD_MOUNT" > "$CHAPTER_PY" 2>/dev/null \
            && [[ -s "$CHAPTER_PY" ]]; then

        TITLE_INFO=$(python3 - "$CHAPTER_PY" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    src = f.read()

# lsdvd -Oy writes libdvdread diagnostic lines to stdout before the dict.
# Strip every line that does not start with the assignment or whitespace
# belonging to the dict, then strip the bare "lsdvd = " assignment prefix
# so Python can eval() the dict literal directly.
# The key for the title list is 'track'; 'title' holds the disc title string.
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

try:
    data = eval(src)    # safe: our own lsdvd output on a local file
except Exception as e:
    print("0")          # signal parse failure; caller checks for 0
    sys.exit(0)

# 'track' holds the list of titles; 'title' is the disc title string.
tracks = data.get("track", [])
if not isinstance(tracks, list):
    tracks = [tracks]   # single-title disc: lsdvd emits a dict, not a list

print(len(tracks))      # line 1: total title count
for i, t in enumerate(tracks, 1):
    chapters = t.get("chapter", [])
    if not isinstance(chapters, list):
        chapters = [chapters]
    chaps  = len(chapters)
    length = float(t.get("length", 0.0))
    h      = int(length // 3600)
    m      = int((length % 3600) // 60)
    s      = length % 60
    print(f"{i}\t{h:02d}:{m:02d}:{s:05.2f}\t{chaps}")
PYEOF
        )

        NUM_TITLES=$(echo "$TITLE_INFO" | head -1)

        if [[ "$NUM_TITLES" -eq 0 ]]; then
            echo "  [WARN] lsdvd ran but output could not be parsed; title count unknown."
            echo "         Raw output saved for inspection: $(basename "$CHAPTER_PY")"
        else
            echo "  lsdvd: $NUM_TITLES title(s) found on disc."

            if [[ $NUM_TITLES -gt 1 ]]; then
                echo ""
                echo "  +-------------------------------------------------------------------+"
                echo "  |  WARNING: This disc contains multiple titles.                     |"
                echo "  |  A separate OGM chapter file will be produced for each title.     |"
                echo "  |  Verify which title(s) correspond to the content you extracted.   |"
                echo "  |  Use dvd_add_chapters.sh --title N to select the correct one.     |"
                echo "  +-------------------------------------------------------------------+"
                echo ""

                # Identify the longest title -- almost always the main content.
                LONGEST_TITLE=$(echo "$TITLE_INFO" | tail -n +2 \
                    | awk -F'\t' 'BEGIN{max=0; lt=0}
                        { split($2,a,":"); secs=a[1]*3600+a[2]*60+a[3];
                          if(secs>max){max=secs; lt=$1} }
                        END{print lt}')

                echo "  Title   Duration     Chapters  Note"
                echo "  ------  -----------  --------  ----"
                echo "$TITLE_INFO" | tail -n +2 \
                    | while IFS=$'\t' read -r tnum dur chaps; do
                        note=""
                        [[ "$tnum" == "$LONGEST_TITLE" ]] && note="<-- longest (likely main content)"
                        printf "  %-6s  %-11s  %-8s  %s\n" "$tnum" "$dur" "$chaps" "$note"
                    done
                echo ""
            fi

            # Warn when title 1 is very short (< 2 min) -- a common DVD layout
            # puts a brief intro or menu as title 1 with the main content later.
            if [[ $NUM_TITLES -gt 1 ]]; then
                TITLE1_DUR=$(echo "$TITLE_INFO" | awk -F'\t' 'NR==2{print $2}')
                TITLE1_SECS=$(echo "$TITLE1_DUR" | awk -F':' '{printf "%d", $1*3600+$2*60+$3}')
                if [[ "$TITLE1_SECS" -lt 120 ]]; then
                    echo "  [WARN] Title 1 is only ${TITLE1_DUR} -- likely a short intro or menu."
                    echo "         The main content is probably a higher-numbered title."
                    echo "         Use the chapter file for that title when adding chapters"
                    echo "         to your upscaled video."
                    echo ""
                fi
            fi
        fi

    else
        echo "  [WARN] lsdvd could not read disc structure; title count unknown."
        rm -f "$CHAPTER_PY"
    fi
else
    echo "  [--] lsdvd not available; title count unknown."
fi

# --------------------------------------------------------------------------
# Step 2 -- dvdxchap: extract one OGM file per title
#
# If lsdvd did not determine a title count, attempt title 1 only.
# dvdxchap exits non-zero for invalid title numbers, so the loop is safe.
# --------------------------------------------------------------------------
if [[ $HAVE_DVDXCHAP -eq 1 ]]; then
    if [[ $NUM_TITLES -gt 0 ]]; then
        TITLE_RANGE=$(seq 1 "$NUM_TITLES")
    else
        # lsdvd unavailable or failed -- try title 1 only.
        TITLE_RANGE="1"
    fi

    for T in $TITLE_RANGE; do
        OGM_FILE="${CHAPTER_STEM}_title_$(printf '%02d' "$T")_chapters.txt"
        if dvdxchap -t "$T" "$DVD_MOUNT" > "$OGM_FILE" 2>/dev/null \
                && [[ -s "$OGM_FILE" ]]; then
            NUM_CHAP=$(grep -c '^CHAPTER[0-9]*=' "$OGM_FILE" 2>/dev/null || echo 0)

            # Replace generic "Chapter NN" names with human-readable cumulative
            # timestamps (e.g. "00:02:43") so the chapter list is useful when
            # scrubbing in a media player.  The timestamp IS the chapter marker
            # position, making it the most informative name available since DVDs
            # do not store chapter title strings.
            python3 - "$OGM_FILE" << 'INNERPY'
import sys, re

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

out = []
for line in lines:
    # Timestamp lines: CHAPTER01=HH:MM:SS.mmm  -- keep as-is
    if re.match(r'CHAPTER\d+=', line):
        out.append(line)
    # Name lines: replace "Chapter NN" with the timestamp from the preceding line
    elif re.match(r'CHAPTER\d+NAME=', line):
        # Find the timestamp from the most recent timestamp line
        ts_line = next((l for l in reversed(out) if re.match(r'CHAPTER\d+=', l)), None)
        if ts_line:
            ts = ts_line.split('=', 1)[1].strip()
            # Trim to HH:MM:SS (drop sub-second fraction for readability)
            ts_short = ts[:8]
            num = re.match(r'CHAPTER(\d+)NAME=', line).group(1)
            out.append(f'CHAPTER{num}NAME={ts_short}\n')
        else:
            out.append(line)
    else:
        out.append(line)

with open(path, 'w') as f:
    f.writelines(out)
INNERPY

            echo "  [OK] Title $T: $NUM_CHAP chapter(s) -> $(basename "$OGM_FILE")"
            CHAPTERS_OK=1
        else
            echo "  [--] Title $T: no chapters found (skipped)."
            rm -f "$OGM_FILE"
        fi
    done

    if [[ $CHAPTERS_OK -eq 0 ]]; then
        echo ""
        echo "  [WARN] dvdxchap produced no chapter files."
        echo "         The disc may have no chapter marks, or the title number differs."
        if [[ -f "$CHAPTER_PY" ]]; then
            echo "         Inspect disc structure: cat $(basename "$CHAPTER_PY")"
        fi
    fi
else
    echo "  [--] dvdxchap not available; no OGM chapter files produced."
fi

echo ""

# ==============================================================================
# VOB concatenation and stream copy
#
# -map 0:v:0  -- explicitly select the first video stream, bypassing ffmpeg's
#               stream selection heuristics (avoids wrong-stream issues on
#               multi-stream DVDs).
# -map 0:a:0  -- explicitly select the first audio stream (same reason).
# -vcodec copy / -acodec copy -- stream copy: no re-encode, lossless, fast.
# -y          -- overwrite output without prompting (timestamp ensures uniqueness).
# ==============================================================================
echo "--- Extracting video ---"
echo "  Input VOBs:"
for vob in "${VOBS[@]}"; do
    echo "    $(basename "$vob")"
done
echo ""

cat "${VOBS[@]}" | ffmpeg -y -i - \
    -map 0:v:0 -map 0:a:0 \
    -vcodec copy -acodec copy \
    "$OUTPUT_FILE"

echo ""
echo "  Extracted: $(basename "$OUTPUT_FILE") ($(du -h "$OUTPUT_FILE" | cut -f1))"

# ==============================================================================
# Integrity verification (optional -- requires xxhash)
# ==============================================================================
if [[ $HAVE_XXHSUM -eq 1 ]]; then
    echo ""
    echo "--- Integrity verification (XXH64) ---"
    HASH=$(xxhsum -H64 "$OUTPUT_FILE" | awk '{print $1}')
    echo "  XXH64: $HASH"
    echo "  File:  $(basename "$OUTPUT_FILE")"
fi

# ==============================================================================
# Post-extraction summary and next-step guidance
# ==============================================================================

# Collect OGM files actually produced (glob under OUTPUT_DIR).
mapfile -t OGM_FILES < <(
    ls "${CHAPTER_STEM}_title_"*"_chapters.txt" 2>/dev/null || true
)

echo ""
echo "========================================="
echo "  Extraction complete"
echo "========================================="
echo "  Output dir: $OUTPUT_DIR"
echo "  MPG:   $(basename "$OUTPUT_FILE")"
for ogm in "${OGM_FILES[@]}"; do
    echo "  OGM:   $(basename "$ogm")"
done
[[ -f "$CHAPTER_PY" ]] && echo "  lsdvd: $(basename "$CHAPTER_PY")"

if [[ ${#OGM_FILES[@]} -gt 0 ]]; then
    echo ""
    echo "  Next steps -- add chapters to upscaled output:"
    echo "  (Pass the OGM file for the title that matches your upscaled video.)"
    for ogm in "${OGM_FILES[@]}"; do
        TNUM=$(basename "$ogm" | grep -oP 'title_\K[0-9]+')
        NCHAP=$(grep -c '^CHAPTER[0-9]*=' "$ogm" 2>/dev/null || echo 0)
        echo ""
        echo "  Title $TNUM ($NCHAP chapter(s)) -- $(basename "$ogm")"
        if [[ $HAVE_MKVTOOLNIX -eq 1 ]]; then
            echo "    MKV in-place : mkvpropedit upscaled.mkv --chapters $(basename "$ogm")"
            echo "    MKV at mux   : mkvmerge -o out.mkv --chapters $(basename "$ogm") input.mkv"
        fi
        echo "    via script   : dvd_add_chapters.sh upscaled.mkv $(basename "$ogm")"
        echo "    via script   : dvd_add_chapters.sh upscaled.mp4 $(basename "$ogm")"
    done
else
    echo ""
    echo "  No OGM chapter files were produced."
    echo "  Chapters must be added manually to upscaled output."
    [[ -f "$CHAPTER_PY" ]] && echo "  Inspect disc structure: cat $(basename "$CHAPTER_PY")"
    [[ $HAVE_MKVTOOLNIX -eq 0 ]] && echo "  Install mkvtoolnix : sudo apt install mkvtoolnix"
    [[ $HAVE_MP4BOX     -eq 0 ]] && echo "  Install MP4Box     : sudo apt install gpac"
fi

echo ""
