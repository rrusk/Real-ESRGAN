#!/usr/bin/env bash
# vhs_quality.sh
# Usage: ./vhs_quality.sh [--sample SECONDS] [--no-histogram] [--histogram-only] [--correction-cmd] <session_dir_a> [session_dir_b]
#
# Each argument is a capture session directory produced by capture_passthrough.sh
# or capture_tape.sh.  The directory must contain exactly one .dv file and
# should contain the dvgrab .log file of the same base name.  The .dv file and
# .log file are resolved automatically; no need to specify file paths directly.
#
# If multiple .dv files are found (should not happen for VCR sessions — the VCR
# is never paused) a warning is emitted and the first file (segment 001) is used.
# If the dvgrab .log is absent the integrity check falls back to frame-count
# arithmetic with a note; all other analysis proceeds normally.
#
# With ONE directory: produces a single-capture report focused on brightness
# calibration metrics (mean_yavg, widespread_clip, highlight_var, YMAX and
# YAVG distributions).  Useful for confirming whether a Hauppauge brightness
# setting is attenuating the signal correctly before committing to a full
# 37-minute capture.
#
# With TWO directories: analyses both captures independently, aligns them by
# audio peak, and produces a side-by-side report plus paired-frame analysis.
#
# Options:
#   --sample SECONDS   Analyse only the first SECONDS seconds of each file.
#                      Useful for a quick indicative result before committing
#                      to a full run (37 min DV ≈ 15-25 min; 120s sample ≈ 1 min).
#                      The report header notes that results are from a sample.
#                      Omit for a full-length analysis.
#
#   --no-histogram     Skip the full pixel-level luma histogram.  The histogram
#                      is run by default as it provides the most complete picture
#                      of clipping behaviour and requires numpy (python3-numpy).
#                      Use --no-histogram for a faster run when you only need
#                      the signalstats metrics and do not need pixel distribution.
#
#   --histogram-only   Run ONLY the integrity check and pixel histogram —
#                      skip all signalstats processing (Steps 1-6).  Use
#                      when you only need to determine whether clipping is
#                      correctable (signal headroom exists) or not (hard ADC
#                      ceiling), without waiting for a full quality analysis.
#                      Runtime is approximately half that of a full run
#                      (one ffmpeg decode pass only).
#
# Dependencies: ffmpeg (with signalstats, astats, ametadata filters), awk,
#               python3 with numpy (for histogram; install: sudo apt install python3-numpy)
#
# Output directory: placed inside session_dir_a (single-session mode)
#   a_stats.log         - per-frame signalstats for capture A
#   a_aligned.log       - a_stats.log (copy; trimmed in two-file mode)
#   dropouts_a.txt      - frames flagged as dropouts in A
#   report.txt          - quality report including luma histogram bright-end summary
#   luma_hist_a.txt     - full luma histogram for A (skipped with --no-histogram)
#   [two-session mode only:]
#   b_stats.log, b_aligned.log, dropouts_b.txt, paired_frames.txt
#   luma_hist_b.txt     - full luma histogram for B (skipped with --no-histogram)

set -euo pipefail

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------
SAMPLE_DURATION=""      # empty = full file; set to seconds string if --sample given
RUN_HISTOGRAM=1         # 1 = run by default; 0 = skip (--no-histogram)
HISTOGRAM_ONLY=0        # 1 = skip Steps 1-6, run only integrity check + histogram
SHOW_CORRECTION_CMD=0   # 1 = emit ffmpeg correction command (--correction-cmd)

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <session_dir_a> [session_dir_b]

Each argument is a capture session directory produced by capture_passthrough.sh
or capture_tape.sh, containing one .dv file and the dvgrab .log of the same
base name.  Files are resolved automatically from the directory.

With ONE directory : single-capture brightness calibration report.
With TWO directories: side-by-side comparison with paired-frame analysis.

Options:
  --sample SECONDS    Analyse only the first SECONDS seconds of each file.
                      Useful for a quick indicative result before a full run.
                      (37 min DV ≈ 15-25 min analysis; 120s sample ≈ 1 min.)

  --no-histogram      Skip the luma pixel histogram (requires python3-numpy).
                      Use when you only need signalstats metrics.

  --histogram-only    Run only the integrity check and pixel histogram,
                      skipping all signalstats processing (Steps 1-6).
                      Approximately half the runtime of a full run.

  --correction-cmd    Print an ffmpeg highlight rolloff command in the report.
                      WARNING: only useful when the luma histogram shows a hard
                      ADC spike at Y=255.  Applying the rolloff to a smooth bright
                      signal compresses real information and may do more harm than
                      good.  Consult the histogram before using the output command.

  -h, --help          Show this help and exit.

Output is written to a timestamped subdirectory inside session_dir_a.

Dependencies:
  ffmpeg (with signalstats, astats, ametadata, extractplanes filters)
  ffprobe, awk, python3, python3-numpy (numpy required for histogram)
  Install numpy with: sudo apt install python3-numpy
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --sample)
            if [[ -z "${2:-}" ]] || [[ ! "${2}" =~ ^[0-9]+$ ]]; then
                echo "[ERROR] --sample requires a positive integer (seconds)."
                exit 1
            fi
            SAMPLE_DURATION="$2"
            shift 2
            ;;
        --no-histogram)
            RUN_HISTOGRAM=0
            shift
            ;;
        --histogram-only)
            RUN_HISTOGRAM=1
            HISTOGRAM_ONLY=1
            shift
            ;;
        --correction-cmd)
            SHOW_CORRECTION_CMD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

# ------------------------------------------------------------------------------
# resolve_session DIR LABEL
# Resolves a capture session directory to its .dv file and dvgrab .log file.
# Sets the caller's DV_FILE and DVGRAB_LOG variables (via echo; caller uses
# read to capture).  Prints warnings for unexpected conditions but only exits
# on hard errors (no .dv file found).
#
# Expected directory contents (from capture_passthrough.sh / capture_tape.sh):
#   SESSION/SESSION001.dv   — raw DV stream (single file for VCR sessions)
#   SESSION/SESSION.log     — dvgrab progress and integrity log
# ------------------------------------------------------------------------------
resolve_session() {
    local DIR="$1"
    local LABEL="$2"

    [[ -d "$DIR" ]] || { echo "[ERROR] Capture $LABEL: not a directory: $DIR" >&2; exit 1; }

    local -a dv_files log_files
    mapfile -t dv_files  < <(find "$DIR" -maxdepth 1 -name "*.dv"  | sort)
    mapfile -t log_files < <(find "$DIR" -maxdepth 1 -name "*.log" | sort)

    case "${#dv_files[@]}" in
        0)
            echo "[ERROR] Capture $LABEL: no .dv file found in $DIR" >&2
            exit 1
            ;;
        1)  ;;
        *)
            echo "[WARN]  Capture $LABEL: ${#dv_files[@]} .dv files found in $DIR" >&2
            echo "        This should not happen for VCR sessions (VCR is never paused)." >&2
            echo "        Proceeding with first file: ${dv_files[0]}" >&2
            ;;
    esac

    case "${#log_files[@]}" in
        0)
            echo "[WARN]  Capture $LABEL: no dvgrab .log found in $DIR" >&2
            echo "        Integrity check will use frame-count arithmetic only." >&2
            ;;
        1)  ;;
        *)
            echo "[WARN]  Capture $LABEL: ${#log_files[@]} .log files found in $DIR — using first: ${log_files[0]}" >&2
            ;;
    esac

    # Return resolved paths via stdout as two tab-separated fields.
    printf '%s\t%s\n' "${dv_files[0]}" "${log_files[0]:-}"
}

# Resolve session directories into .dv paths and dvgrab log paths.
{ read -r A DVGRAB_LOG_A; } < <(resolve_session "$1" "A")
B=""
DVGRAB_LOG_B=""
if [ "$#" -ge 2 ]; then
    { read -r B DVGRAB_LOG_B; } < <(resolve_session "$2" "B")
fi

# SINGLE_MODE=1 when only one capture is provided.  Steps that require two
# files (audio alignment, B signalstats, log trimming, paired analysis) are
# skipped entirely.  The report is a single-column brightness calibration
# summary rather than a side-by-side comparison.
SINGLE_MODE=0
[ -z "$B" ] && SINGLE_MODE=1

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Output directory naming:
#   Single-file: placed inside the video's own directory with a simple
#                timestamp name so it is self-contained alongside the source.
#                e.g. VHS_Jive_.../vhs_quality_20260428_181145/
#   Two-file:    placed in the current working directory, named after
#                both file stems to make the comparison self-documenting.
#                e.g. VHS_Jive_..._vs_VHS_Jive_..._quality_20260428_094641/
if [ "$SINGLE_MODE" -eq 1 ]; then
    W="${1}/vhs_quality_${TIMESTAMP}"
else
    A_STEM=$(basename "${A%.*}")
    B_STEM=$(basename "${B%.*}")
    # Truncate stems to keep the directory name manageable.
    A_SHORT="${A_STEM:0:30}"
    B_SHORT="${B_STEM:0:30}"
    W="${A_SHORT}_vs_${B_SHORT}_quality_${TIMESTAMP}"
fi
mkdir -p "$W"

# ------------------------------------------------------------------------------
# Tuning parameters
# ------------------------------------------------------------------------------

# Search window for audio peak detection (seconds from start of each file).
PEAK_WINDOW=60

# A frame is flagged as a dropout if its YDIF exceeds this threshold.
# YDIF is the mean absolute luma difference from the previous frame.
# On stable footage typical values are 1-4; a dropout typically spikes to
# 20+ depending on severity.  Adjust if your footage has fast motion.
DROPOUT_YDIF_THRESHOLD=20

# A frame is flagged as widespread-clipping if its YHIGH (75th-percentile
# luma) meets or exceeds this threshold.  YHIGH>=230 means at least 25%
# of the frame is at or near broadcast white - genuine pervasive clipping
# rather than an isolated specular highlight (which drives YMAX to 255
# while leaving YHIGH well below this level).  Adjust downward (e.g. 210)
# for footage with less extreme highlights.
CLIP_YHIGH_THRESHOLD=230

# A frame is included in highlight-texture analysis if its YHIGH (75th-
# percentile luma) meets or exceeds this threshold.  Using YHIGH rather than
# YAVG catches frames where highlights occupy only part of the frame (e.g. a
# bright floor visible in the lower half), which is the common VHS dance-
# footage case.  We measure the variance of YAVG across those frames: a VCR
# that clips highlights produces near-constant YAVG on hot frames (variance
# near zero); a VCR with headroom shows genuine texture variation (higher
# variance).  Adjust upward if your content is uniformly very bright.
HIGHLIGHT_YHIGH_THRESHOLD=210

# ------------------------------------------------------------------------------
# Helper: confirm_continue
# Prompts the user after a non-fatal failure.  Reads from /dev/tty so the
# prompt works even when stdin is redirected.  Exits on anything but y/Y.
# ------------------------------------------------------------------------------
confirm_continue() {
    local reason="$1"
    echo ""
    echo "  [WARN] ${reason}"
    printf "  Continue anyway? [y/N] "
    local answer
    read -r answer </dev/tty
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "  Aborting."
        exit 1
    fi
    echo ""
}

# ------------------------------------------------------------------------------
# Helper: check_integrity INFILE ACTUAL_FRAMES LABEL DVGRAB_LOG
# Primary method: if DVGRAB_LOG is provided, counts "damaged frame" lines
# reported by dvgrab — these are authoritative FireWire transport failures.
# Fallback (no log): for raw .dv files uses file size / 120000 (exact, no
# decoding needed); for other containers uses duration × fps from ffprobe.
# The fallback is unreliable in two-file mode after alignment trimming and
# is labelled as an estimate in that case.
# Tolerance of 5 frames applies to the fallback path only.
# ------------------------------------------------------------------------------
check_integrity() {
    local INFILE="$1"
    local ACTUAL="$2"
    local LABEL="$3"
    local DVGRAB_LOG="${4:-}"

    # --- Primary: dvgrab log ---
    if [[ -n "$DVGRAB_LOG" && -f "$DVGRAB_LOG" ]]; then
        local DROP_COUNT
        # Sum all lines from grep -c (handles multi-segment logs), strip CR.
        DROP_COUNT=$(grep -c "damaged frame" "$DVGRAB_LOG" 2>/dev/null \
            | tr -d '\r' | awk '{s+=$1} END{print s+0}')
        if [ "$DROP_COUNT" -eq 0 ]; then
            echo "  ${LABEL}: OK — no damaged frames in dvgrab log"
        else
            echo "  ${LABEL}: WARNING — ${DROP_COUNT} damaged frame(s) reported by dvgrab (FireWire transport errors)"
        fi
        return 0
    fi

    # --- Fallback: frame-count arithmetic ---
    echo "  ${LABEL}: (no dvgrab log — using frame-count estimate)"
    local TOLERANCE=5
    local ext EXPECTED MISSING
    ext="${INFILE##*.}"

    if [[ "${ext,,}" == "dv" ]]; then
        # Raw DV: fixed frame size of 120,000 bytes per NTSC frame.
        # File size / 120000 gives exact frame count with no decoding needed.
        # Any remainder indicates a partial frame (truncated capture).
        local FILESIZE REMAINDER
        FILESIZE=$(stat -c%s "$INFILE" 2>/dev/null || echo "0")
        REMAINDER=$(( FILESIZE % 120000 ))
        EXPECTED=$(( FILESIZE / 120000 ))

        if [ "$EXPECTED" -eq 0 ]; then
            echo "  ${LABEL}: expected frame count unavailable (could not stat file)"
            return 0
        fi

        if [ "$REMAINDER" -ne 0 ]; then
            echo "  ${LABEL}: WARNING — file size ${FILESIZE} is not a multiple of 120000 bytes"
            echo "  ${LABEL}: Partial frame at end of file — capture may have been truncated."
        fi
    else
        # MKV/AVI: nb_frames from container index, falling back to duration × fps.
        #
        # LIMITATION: Cannot detect duplicate frames (capture device repeating a
        # frame to fill a gap caused by USB buffer overrun).  Duplicated frames
        # leave the container frame count correct while silently degrading the
        # capture.  The signalstats YDIF metric will show anomalously low
        # inter-frame differences on duplicated frame pairs.
        local DURATION FPS
        DURATION=$(ffprobe -v error -select_streams v:0 \
            -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$INFILE" 2>/dev/null || echo "0")
        FPS=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=r_frame_rate \
            -of default=noprint_wrappers=1:nokey=1 "$INFILE" 2>/dev/null || echo "0/1")

        EXPECTED=$(awk -v d="$DURATION" -v f="$FPS" 'BEGIN {
            split(f, a, "/")
            if (a[2]+0 > 0) printf "%d", int(d * a[1] / a[2] + 0.5)
            else print "0"
        }')

        if [ "$EXPECTED" -eq 0 ] 2>/dev/null; then
            echo "  ${LABEL}: expected frame count unavailable (ffprobe could not read duration)"
            return 0
        fi
    fi

    MISSING=$(( EXPECTED - ACTUAL ))

    if [ "$MISSING" -le "$TOLERANCE" ]; then
        echo "  ${LABEL}: OK — ${ACTUAL} frames decoded, ${EXPECTED} expected (diff=${MISSING})"
        return 0
    else
        echo "  ${LABEL}: WARNING — ${ACTUAL} frames decoded, ${EXPECTED} expected — ${MISSING} frames missing"
        echo "  ${LABEL}: Possible dropped frames. Provide the dvgrab log for authoritative drop detection."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Helper: compute_histogram INFILE OUTFILE LABEL
# Decodes raw luma from INFILE, counts pixel values 0-255 with numpy,
# and writes the formatted histogram to OUTFILE.
# Respects SAMPLE_DURATION if set.
# ------------------------------------------------------------------------------
compute_histogram() {
    local INFILE="$1"
    local OUTFILE="$2"
    local LABEL="$3"

    local DURATION_FLAG=""
    [ -n "$SAMPLE_DURATION" ] && DURATION_FLAG="-t ${SAMPLE_DURATION}"

    echo "  $LABEL: $INFILE"

    # Write the Python histogram script to a temp file so the pipe + heredoc
    # interaction inside a function does not silently produce empty output.
    local PYSCRIPT
    PYSCRIPT=$(mktemp /tmp/vhs_hist_XXXXXX.py)
    cat > "$PYSCRIPT" << 'PYEOF'
import sys, numpy as np

outfile  = sys.argv[1]
hist     = np.zeros(256, dtype=np.int64)
buf_size = 4 * 1024 * 1024   # 4 MB chunks — avoids reading entire file into RAM

stdin = sys.stdin.buffer
while True:
    chunk = stdin.read(buf_size)
    if not chunk:
        break
    arr  = np.frombuffer(chunk, dtype=np.uint8)
    hist += np.bincount(arr, minlength=256)

total = int(hist.sum())

with open(outfile, "w") as fh:
    fh.write("Luma pixel histogram (Y=0-255, all pixels all frames)\n")
    fh.write(f"Total pixels counted: {total:,}\n")
    fh.write("\n")
    fh.write("Note: a spike at one value with near-zero neighbours indicates\n")
    fh.write("ADC clipping or quantisation.  A smooth rolloff at the bright\n")
    fh.write("end indicates genuine signal gradation with headroom.\n")
    fh.write("\n")
    fh.write(f"{'Y':>3}  {'Count':>17}  {'Pct':>6}  Bar (each # = 0.5%)\n")
    fh.write(f"{'---':>3}  {'---':>17}  {'---':>6}  --------------------\n")
    for v in range(256):
        count = int(hist[v])
        pct   = 100.0 * count / total if total else 0.0
        bar   = "#" * min(50, int(pct / 0.5))
        fh.write(f"{v:3d}  {count:17,}  {pct:6.2f}%  {bar}\n")

print(f"    Written: {outfile}")
PYEOF

    # extractplanes=y extracts the Y (luma) plane directly without any
    # colour range conversion.  The previous 'format=gray' filter applied
    # a studio-swing→full-range rescale (×255/219 ≈ 1.164) which caused
    # systematic gaps every 7 values in the histogram output — certain luma
    # values were never produced by the integer arithmetic of the rescaling.
    # extractplanes=y passes Y bytes through unchanged, giving a true 1:1
    # histogram of the actual encoded luma values.
    #
    # IMPORTANT: crop=720:472:0:0 removes the bottom 8 lines before histogram
    # accumulation for the same reason as the signalstats crop above — VHS head
    # switching noise in the bottom lines would inflate the histogram at extreme
    # luma values and distort the bright-end distribution.
    # Do NOT remove this crop.
    # shellcheck disable=SC2086
    ffmpeg -i "$INFILE" $DURATION_FLAG \
        -vf "crop=720:472:0:0,extractplanes=y" \
        -f rawvideo -pix_fmt gray - 2>/dev/null \
    | python3 "$PYSCRIPT" "$OUTFILE"

    rm -f "$PYSCRIPT"
}

# ------------------------------------------------------------------------------
# Helper: find_peak FILE [START]
# Finds the timestamp (seconds) of the loudest audio transient within
# PEAK_WINDOW seconds of START in FILE.  Prints the absolute timestamp,
# or "NOT_FOUND" if no non-silent peak exists.
# ------------------------------------------------------------------------------
find_peak() {
    local FILE="$1"
    local START="${2:-0}"

    local TMPFILE
    TMPFILE=$(mktemp /tmp/vhs_peak_XXXXXX.txt)

    # astats/ametadata writes one Peak_level value per frame to TMPFILE.
    # stderr is suppressed; || true prevents set -e from firing on a
    # non-zero ffmpeg exit (e.g. truncated file).
    ffmpeg -ss "$START" -t "$PEAK_WINDOW" -i "$FILE" \
        -af "aresample=44100,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.Peak_level:file=${TMPFILE}" \
        -vn -f null - 2>/dev/null || true

    local PEAK_TIME
    PEAK_TIME=$(awk '
        /pts_time:/ {
            split($0, a, "pts_time:")
            pts = a[2]
        }
        /lavfi.astats.Overall.Peak_level=/ {
            split($0, a, "=")
            val = a[2]
            if (val == "-inf") next
            val = val + 0
            if (!found || val > max_val) {
                max_val = val
                max_pts  = pts
                found    = 1
            }
        }
        END { if (found) print max_pts; else print "NOT_FOUND" }
    ' "$TMPFILE")

    rm -f "$TMPFILE"

    if [ -z "$PEAK_TIME" ] || [ "$PEAK_TIME" = "NOT_FOUND" ]; then
        echo "NOT_FOUND"
        return 0
    fi

    # Absolute timestamp = window start + relative peak time.
    python3 -c "print(round(${START} + ${PEAK_TIME}, 3))"
}

# ------------------------------------------------------------------------------
# Step 1: Audio peak detection → frame offset  (two-file mode only)
# ------------------------------------------------------------------------------

# --histogram-only: skip Steps 1-6, run integrity check and histogram only.
if [ "$HISTOGRAM_ONLY" -eq 1 ]; then
    echo ""
    echo "========================================"
    echo "  HISTOGRAM-ONLY MODE"
    echo "========================================"
    if [ "$SINGLE_MODE" -eq 1 ]; then
        echo "  Capture : $A"
    else
        echo "  Capture A : $A"
        echo "  Capture B : $B"
    fi
    [ -n "$SAMPLE_DURATION" ] && echo "  *** SAMPLE MODE: first ${SAMPLE_DURATION}s only ***"
    echo ""

    # Check numpy before starting the expensive decode.
    if ! python3 -c "import numpy" 2>/dev/null; then
        echo "[ERROR] numpy is required for histogram computation."
        echo "        Install with: sudo apt install python3-numpy"
        exit 1
    fi

    # Integrity check: use ffprobe frame count directly (no signalstats log).
    # get_frame_count INFILE — returns the expected frame count.
    # For raw DV: file size / 120000 (exact, instantaneous, no ffprobe needed).
    # For other formats: nb_frames from container index, falling back to
    # duration * fps if not stored.
    get_frame_count() {
        local INFILE="$1"
        local ext="${INFILE##*.}"
        if [[ "${ext,,}" == "dv" ]]; then
            local FILESIZE
            FILESIZE=$(stat -c%s "$INFILE" 2>/dev/null || echo "0")
            echo $(( FILESIZE / 120000 ))
            return
        fi
        # Non-DV: try stored nb_frames first, fall back to duration*fps.
        local NB
        NB=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=nb_frames \
            -of default=noprint_wrappers=1:nokey=1 \
            "$INFILE" 2>/dev/null || echo "")
        if [[ "$NB" =~ ^[0-9]+$ ]] && [ "$NB" -gt 0 ]; then
            echo "$NB"
            return
        fi
        local DURATION FPS
        DURATION=$(ffprobe -v error -select_streams v:0 \
            -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$INFILE" 2>/dev/null || echo "0")
        FPS=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=r_frame_rate \
            -of default=noprint_wrappers=1:nokey=1 "$INFILE" 2>/dev/null || echo "0/1")
        awk -v d="$DURATION" -v f="$FPS" 'BEGIN {
            split(f, a, "/")
            if (a[2]+0 > 0) printf "%d", int(d * a[1] / a[2] + 0.5)
            else print "0"
        }'
    }

    echo "[1/2] Checking capture integrity..."
    FA=$(get_frame_count "$A")
    check_integrity "$A" "$FA" "Capture A" "$DVGRAB_LOG_A" || true
    if [ "$SINGLE_MODE" -eq 0 ]; then
        FB=$(get_frame_count "$B")
        check_integrity "$B" "$FB" "Capture B" "$DVGRAB_LOG_B" || true
    fi

    echo ""
    echo "[2/2] Computing luma pixel histogram..."
    compute_histogram "$A" "$W/luma_hist_a.txt" "Capture A"
    if [ "$SINGLE_MODE" -eq 0 ]; then
        compute_histogram "$B" "$W/luma_hist_b.txt" "Capture B"
    fi

    echo ""
    echo "Bright-end summary (Y=220-255):"
    echo ""
    echo "--- Capture A ---"
    awk 'NR>6 && $1+0 >= 220 {print}' "$W/luma_hist_a.txt"
    if [ "$SINGLE_MODE" -eq 0 ]; then
        echo ""
        echo "--- Capture B ---"
        awk 'NR>6 && $1+0 >= 220 {print}' "$W/luma_hist_b.txt"
    fi
    echo ""
    echo "Full histogram : $W/luma_hist_a.txt"
    [ "$SINGLE_MODE" -eq 0 ] && echo "               : $W/luma_hist_b.txt"
    echo ""
    echo "Done."
    exit 0
fi
PEAK_A="N/A"
PEAK_B="N/A"
OFFSET_FRAMES=0
SKIP_A=0
SKIP_B=0

if [ "$SINGLE_MODE" -eq 0 ]; then
echo ""
echo "[1/6] Audio peak detection..."

if command -v python3 >/dev/null 2>&1; then
    PEAK_A=$(find_peak "$A")
    PEAK_B=$(find_peak "$B")

    echo "  Peak A: ${PEAK_A}s"
    echo "  Peak B: ${PEAK_B}s"

    if [ "$PEAK_A" != "NOT_FOUND" ] && [ "$PEAK_B" != "NOT_FOUND" ]; then
        OFFSET_SEC=$(python3 -c "print(round(${PEAK_A} - ${PEAK_B}, 3))")
        # Round to nearest whole frame at 29.97 fps.
        OFFSET_FRAMES=$(python3 -c "print(round(abs(${PEAK_A} - ${PEAK_B}) * 29.97))")
        # Whichever file has its peak later in the file has more content before
        # the peak and must be trimmed so both logs start at the same tape position.
        # PEAK_A > PEAK_B → A has more content before the peak → trim A's log.
        # PEAK_A < PEAK_B → B has more content before the peak → trim B's log.
        if python3 -c "import sys; sys.exit(0 if ${PEAK_A} >= ${PEAK_B} else 1)"; then
            SKIP_A=$OFFSET_FRAMES
            SKIP_B=0
            echo "  A has more content before peak (${PEAK_A}s vs ${PEAK_B}s); A log will be trimmed by ${OFFSET_FRAMES} frames."
        else
            SKIP_A=0
            SKIP_B=$OFFSET_FRAMES
            ABS_SEC=$(python3 -c "print(round(abs(${OFFSET_SEC}), 3))")
            echo "  B has more content before peak (${PEAK_B}s vs ${PEAK_A}s); B log will be trimmed by ${OFFSET_FRAMES} frames."
        fi
    else
        confirm_continue "Peak detection failed (silent or unreadable audio in one or both files). Per-frame logs will NOT be time-aligned."
        SKIP_A=0
        SKIP_B=0
    fi
else
    confirm_continue "python3 not found; audio peak detection is unavailable. Per-frame logs will NOT be time-aligned."
    SKIP_A=0
    SKIP_B=0
fi
else
    echo ""
    echo "[1/6] Audio peak detection... skipped (single-file mode)"
fi

# ------------------------------------------------------------------------------
# Step 2: Per-frame signalstats extraction
# ------------------------------------------------------------------------------
# signalstats outputs per-frame metadata via the metadata=print filter.
# Each frame produces a block written to stdout (file=-) in the form:
#   frame:N    pts:N    pts_time:T
#   lavfi.signalstats.YMIN=16
#   lavfi.signalstats.YMAX=235
#   lavfi.signalstats.YDIF=2.31
#   ... (one key per line)
#
# Note: YSTDDEV/USTDDEV/VSTDDEV are NOT available in this filter.
# Spatial luma range is approximated from YHIGH-YLOW (inter-quartile spread).
# Chroma noise is measured via UDIF/VDIF (temporal) and UAVG/VAVG variance.
# Additional fields captured:
#   VREP  - vertical repetition: how much each line resembles the one above.
#           High VREP = smeared/repeated lines (head clog, poor tape contact).
#   UMAX/UMIN/VMAX/VMIN - per-frame chroma range; (UMAX-UMIN + VMAX-VMIN)/2
#           measures chroma bandwidth.  S-Video should outperform composite
#           here; a deficit reveals internal processing or cabling problems.
#   Highlight texture variance - variance of YAVG on frames where YHIGH
#           exceeds HIGHLIGHT_YHIGH_THRESHOLD.  Near-zero variance = clipping
#           has compressed all texture out of bright frames.  Higher variance
#           = genuine tonal gradation is preserved in the highlights.
# ------------------------------------------------------------------------------
echo ""
if [ -n "$SAMPLE_DURATION" ]; then
    echo "[2/6] Extracting per-frame signalstats (sample: first ${SAMPLE_DURATION}s)..."
    DURATION_FLAG="-t ${SAMPLE_DURATION}"
else
    echo "[2/6] Extracting per-frame signalstats (full file)..."
    DURATION_FLAG=""
fi

echo "  Capture A: $A"
# shellcheck disable=SC2086
# IMPORTANT: crop=720:472:0:0 removes the bottom 8 lines of each frame before
# analysis.  VHS head switching noise appears in the bottom ~8 lines and causes
# spurious YDIF spikes, elevated YMAX, and inflated dropout counts if not masked.
# Do NOT remove or simplify this crop — without it quality metrics are corrupted
# by head switching artefacts that are not representative of picture content.
ffmpeg -i "$A" $DURATION_FLAG \
    -vf "crop=720:472:0:0,signalstats,metadata=print:file=-" \
    -f null - 2>/dev/null \
    | grep -E "(^frame:|lavfi\.signalstats\.)" > "$W/a_stats.log" || true

if [ ! -s "$W/a_stats.log" ]; then
    echo "[ERROR] No signalstats output for capture A. Check that ffmpeg supports the signalstats filter."
    exit 1
fi

if [ "$SINGLE_MODE" -eq 0 ]; then
echo "  Capture B: $B"
# shellcheck disable=SC2086
# IMPORTANT: crop=720:472:0:0 — see capture A comment above.
ffmpeg -i "$B" $DURATION_FLAG \
    -vf "crop=720:472:0:0,signalstats,metadata=print:file=-" \
    -f null - 2>/dev/null \
    | grep -E "(^frame:|lavfi\.signalstats\.)" > "$W/b_stats.log" || true

if [ ! -s "$W/b_stats.log" ]; then
    echo "[ERROR] No signalstats output for capture B. Check that ffmpeg supports the signalstats filter."
    exit 1
fi
fi

# skip_frames LOG SKIP OUTFILE
# Strips the first SKIP frame blocks from LOG and writes the rest to OUTFILE.
skip_frames() {
    local LOG="$1"
    local SKIP="$2"
    local OUT="$3"
    if [ "$SKIP" -eq 0 ]; then
        cp "$LOG" "$OUT"
        return
    fi
    local START_LINE
    START_LINE=$(grep -n "^frame:" "$LOG" \
        | awk -v skip="$SKIP" -F: 'NR == skip+1 {print $1}')
    if [ -z "$START_LINE" ]; then
        > "$OUT"
    else
        tail -n "+${START_LINE}" "$LOG" > "$OUT"
    fi
}

count_frames() {
    grep -c "^frame:" "$1" 2>/dev/null || echo 0
}

# ------------------------------------------------------------------------------
# Step 3: Align logs  (two-file mode only)
# In single-file mode a_stats.log is used directly as a_aligned.log.
# ------------------------------------------------------------------------------
if [ "$SINGLE_MODE" -eq 0 ]; then
echo ""
echo "[3/6] Aligning logs (SKIP_A=${SKIP_A} frames, SKIP_B=${SKIP_B} frames)..."

skip_frames "$W/a_stats.log" "$SKIP_A" "$W/a_aligned.log"
skip_frames "$W/b_stats.log" "$SKIP_B" "$W/b_aligned.log"

count_frames() {
    grep -c "^frame:" "$1" 2>/dev/null || echo 0
}

FRAMES_A=$(count_frames "$W/a_aligned.log")
FRAMES_B=$(count_frames "$W/b_aligned.log")

if [ "$FRAMES_A" -ne "$FRAMES_B" ]; then
    if [ "$FRAMES_A" -lt "$FRAMES_B" ]; then
        SHORTER="$FRAMES_A"
        LONGER_LOG="$W/b_aligned.log"
        echo "  A is shorter ($FRAMES_A frames); trimming B to match."
    else
        SHORTER="$FRAMES_B"
        LONGER_LOG="$W/a_aligned.log"
        echo "  B is shorter ($FRAMES_B frames); trimming A to match."
    fi
    TRIM_LINE=$(grep -n "^frame:" "$LONGER_LOG" \
        | awk -v n="$SHORTER" -F: 'NR == n+1 {print $1}')
    if [ -n "$TRIM_LINE" ]; then
        TRIM_LINE=$((TRIM_LINE - 1))
        head -n "$TRIM_LINE" "$LONGER_LOG" > "${LONGER_LOG}.tmp" \
            && mv "${LONGER_LOG}.tmp" "$LONGER_LOG"
    fi
fi
else
    echo ""
    echo "[3/6] Aligning logs... skipped (single-file mode)"
    cp "$W/a_stats.log" "$W/a_aligned.log"
fi

# ------------------------------------------------------------------------------
# Step 4: Dropout detection
# A dropout is a frame whose YDIF exceeds DROPOUT_YDIF_THRESHOLD.
# We also capture YMIN/YMAX to distinguish luma crush from genuine dropouts.
# Output format: FRAME  YDIF  YMIN  YMAX
# ------------------------------------------------------------------------------
echo ""
echo "[4/6] Detecting dropouts (YDIF threshold: ${DROPOUT_YDIF_THRESHOLD})..."

extract_dropouts() {
    local LOG="$1"
    local OUT="$2"
    awk -v thresh="$DROPOUT_YDIF_THRESHOLD" '
        /^frame:/ {
            # Flush previous frame if we have data.
            if (framenum != "") {
                if (ydif > thresh)
                    printf "frame=%-6d  YDIF=%-7.2f  YMIN=%-4s  YMAX=%-4s\n",
                        framenum, ydif, ymin, ymax
            }
            # Parse frame number from "frame:N    pts:..."
            split($1, a, ":")
            framenum = a[2]
            ydif = 0; ymin = ""; ymax = ""
        }
        /^lavfi\.signalstats\.YDIF=/ { split($0, a, "="); ydif = a[2] + 0 }
        /^lavfi\.signalstats\.YMIN=/ { split($0, a, "="); ymin = a[2] }
        /^lavfi\.signalstats\.YMAX=/ { split($0, a, "="); ymax = a[2] }
        END {
            if (framenum != "" && ydif > thresh)
                printf "frame=%-6d  YDIF=%-7.2f  YMIN=%-4s  YMAX=%-4s\n",
                    framenum, ydif, ymin, ymax
        }
    ' "$LOG" > "$OUT"
    echo "  $(wc -l < "$OUT") dropout frames found → $OUT"
}

extract_dropouts "$W/a_aligned.log" "$W/dropouts_a.txt"
if [ "$SINGLE_MODE" -eq 0 ]; then
    extract_dropouts "$W/b_aligned.log" "$W/dropouts_b.txt"
fi

# ------------------------------------------------------------------------------
# Step 5: Compute summary metrics and write report
# ------------------------------------------------------------------------------
# For each aligned log compute:
#   - Total frames
#   - Mean and stddev of YDIF        (temporal luma noise)
#   - Mean UDIF, VDIF                (temporal chroma noise)
#   - Mean YHIGH-YLOW                (spatial luma detail proxy)
#   - Chroma bias: sqrt((Uavg-128)²+(Vavg-128)²)  (composite colour bleed)
#   - Dropout count                  (YDIF spikes above threshold)
#   - Luma clip count                (YMIN<=16 or YMAX=255)
# ------------------------------------------------------------------------------
echo ""
echo "[5/6] Computing quality metrics and writing report..."

compute_metrics() {
    local LOG="$1"
    awk -v thresh="$DROPOUT_YDIF_THRESHOLD" \
        -v clip_yhigh="$CLIP_YHIGH_THRESHOLD" \
        -v hi_yhigh="$HIGHLIGHT_YHIGH_THRESHOLD" '
        BEGIN {
            # Explicitly initialise all accumulators and counters to zero.
            # awk defaults uninitialised variables to 0/empty, but explicit
            # initialisation guards against any future awk implementation
            # differences and makes the intent clear.
            n = 0
            sum_ydif = 0;  sum_ydif2 = 0
            sum_udif = 0;  sum_vdif  = 0
            sum_yspread = 0
            sum_uavg = 0;  sum_vavg  = 0
            sum_yavg = 0;  sum_ymax  = 0
            dropouts = 0;  clips = 0
            true_clips = 0; widespread_clips = 0
            n_clip = 0;    n_noclip = 0
            sum_ydif_clip = 0;    sum_ydif_noclip = 0
            sum_yhigh_clip = 0;   sum_ylow_clip = 0
            sum_yavg_clip = 0;    sum_yspread_noclip = 0
            ymax_trueclip = 0;    ymax_superwhite = 0
            ymax_high = 0;        ymax_midhigh = 0
            ymax_midlow = 0;      ymax_low = 0
            yavg_bright = 0;      yavg_midhigh = 0
            yavg_midlow = 0;      yavg_dark = 0
            sum_vrep = 0;         sum_chroma_range = 0
            hl_n = 0;  hl_sum = 0;  hl_sum2 = 0
        }
        /^frame:/ {
            # On seeing a new frame header, flush the signalstats that
            # were accumulated for the PREVIOUS frame.  YDIF is a
            # frame-to-frame difference so skip it on the first frame.
            # All other stats use current-frame values and are always valid.
            if (n > 0) {
                ydif_val = ydif + 0
                sum_ydif  += ydif_val;  sum_ydif2 += ydif_val * ydif_val
                if (ydif_val > thresh)  dropouts++

                udif_val  = udif  + 0;  vdif_val  = vdif  + 0
                # Spatial luma spread: inter-quartile range YHIGH-YLOW.
                yspread   = (yhigh + 0) - (ylow + 0)
                uavg_val  = uavg  + 0;  vavg_val  = vavg  + 0
                ymin_val  = ymin  + 0;  ymax_val  = ymax  + 0
                yavg_val  = yavg  + 0;  yhigh_val = yhigh + 0
                ylow_val  = ylow  + 0

                sum_udif    += udif_val;  sum_vdif    += vdif_val
                sum_yspread += yspread;   sum_uavg    += uavg_val
                sum_vavg    += vavg_val;  sum_yavg    += yavg_val
                sum_ymax    += ymax_val

                # DV uses studio-swing YUV: black=16, nominal white=235,
                # super-white=236-254, true clip=255.
                # is_true_clip: at least one pixel is fully clipped (255).
                # is_black_crush: at least one pixel is at/below black (16).
                # is_any_clip: either of the above.
                is_true_clip       = (ymax_val >= 255)
                is_black_crush     = (ymin_val <= 16)
                is_any_clip        = (is_true_clip || is_black_crush)
                # is_widespread_clip: YHIGH>=clip_yhigh means 25%+ of the
                # frame is at or above nominal white.  The ymax_val >= 250
                # guard avoids false positives where YHIGH is elevated by
                # dense midtone content without genuine near-ceiling signal.
                is_widespread_clip = (yhigh_val >= clip_yhigh && ymax_val >= 250)

                if (is_any_clip)        clips++
                if (is_true_clip)       true_clips++
                if (is_widespread_clip) widespread_clips++

                # Clip-conditioned stats split on YHIGH threshold.
                # Accumulate YHIGH histogram (bucket width 5) on clipping frames
                # to derive a data-driven curves knee for post-processing.
                if (is_widespread_clip) {
                    n_clip++
                    sum_ydif_clip   += ydif_val
                    sum_yhigh_clip  += yhigh_val
                    sum_ylow_clip   += ylow_val
                    sum_yavg_clip   += yavg_val
                    bucket = int(yhigh_val / 5) * 5
                    yhigh_hist[bucket]++
                } else {
                    n_noclip++
                    sum_ydif_noclip    += ydif_val
                    sum_yspread_noclip += yspread
                }

                # YMAX distribution buckets reflecting studio-swing reality.
                #   true clip   : YMAX = 255         (information lost)
                #   super-white : 236 <= YMAX < 255  (above nominal white, recoverable)
                #   nominal high: 200 <= YMAX <= 235  (within broadcast range, high)
                #   mid-high    : 175 <= YMAX < 200
                #   mid-low     : 128 <= YMAX < 175
                #   low         : YMAX < 128
                if      (ymax_val >= 255) ymax_trueclip++
                else if (ymax_val >= 236) ymax_superwhite++
                else if (ymax_val >= 200) ymax_high++
                else if (ymax_val >= 175) ymax_midhigh++
                else if (ymax_val >= 128) ymax_midlow++
                else                      ymax_low++

                # YAVG distribution buckets.
                if      (yavg_val >= 160) yavg_bright++
                else if (yavg_val >= 128) yavg_midhigh++
                else if (yavg_val >=  96) yavg_midlow++
                else                      yavg_dark++

                # VREP: vertical line repetition.  High values indicate head
                # clog, tape damage, or signal smearing.  Accumulated for mean.
                # Chroma range: mean half-sum of U and V excursion per frame.
                # (UMAX-UMIN + VMAX-VMIN)/2.  Higher = more chroma bandwidth
                # retained.  S-Video should show a wider range than composite.
                sum_vrep         += vrep + 0
                sum_chroma_range += ((umax+0)-(umin+0)+(vmax+0)-(vmin+0))/2

                # Highlight texture: variance of YAVG on frames whose YHIGH
                # (75th-percentile luma) exceeds hi_yhigh.  Measures whether
                # tonal gradation survives in highlight-dominated frames.
                # A clipping VCR produces near-constant YAVG on these frames
                # (variance → 0); a VCR with headroom shows real variation.
                if (yhigh_val >= hi_yhigh) {
                    hl_n++
                    hl_sum  += yavg_val
                    hl_sum2 += yavg_val * yavg_val
                }
            }
            n++
            ydif=""; udif=""; vdif=""
            yhigh=""; ylow=""; ymin=""; ymax=""
            uavg=""; vavg=""; yavg=""
            vrep=""; umax=""; umin=""; vmax=""; vmin=""
        }
        /^lavfi\.signalstats\.YDIF=/  { split($0,a,"="); ydif  = a[2] }
        /^lavfi\.signalstats\.UDIF=/  { split($0,a,"="); udif  = a[2] }
        /^lavfi\.signalstats\.VDIF=/  { split($0,a,"="); vdif  = a[2] }
        /^lavfi\.signalstats\.YHIGH=/ { split($0,a,"="); yhigh = a[2] }
        /^lavfi\.signalstats\.YLOW=/  { split($0,a,"="); ylow  = a[2] }
        /^lavfi\.signalstats\.YMIN=/  { split($0,a,"="); ymin  = a[2] }
        /^lavfi\.signalstats\.YMAX=/  { split($0,a,"="); ymax  = a[2] }
        /^lavfi\.signalstats\.UAVG=/  { split($0,a,"="); uavg  = a[2] }
        /^lavfi\.signalstats\.VAVG=/  { split($0,a,"="); vavg  = a[2] }
        /^lavfi\.signalstats\.YAVG=/  { split($0,a,"="); yavg  = a[2] }
        /^lavfi\.signalstats\.VREP=/  { split($0,a,"="); vrep  = a[2] }
        /^lavfi\.signalstats\.UMAX=/  { split($0,a,"="); umax  = a[2] }
        /^lavfi\.signalstats\.UMIN=/  { split($0,a,"="); umin  = a[2] }
        /^lavfi\.signalstats\.VMAX=/  { split($0,a,"="); vmax  = a[2] }
        /^lavfi\.signalstats\.VMIN=/  { split($0,a,"="); vmin  = a[2] }
        END {
            # Flush the last frame — its field values were populated but
            # no subsequent frame: header triggered the flush block above.
            if (n > 0) {
                ydif_val = ydif + 0
                sum_ydif  += ydif_val;  sum_ydif2 += ydif_val * ydif_val
                if (ydif_val > thresh)  dropouts++

                udif_val  = udif+0;     vdif_val  = vdif+0
                yspread   = (yhigh+0) - (ylow+0)
                uavg_val  = uavg+0;     vavg_val  = vavg+0
                ymin_val  = ymin+0;     ymax_val  = ymax+0
                yavg_val  = yavg+0;     yhigh_val = yhigh+0
                ylow_val  = ylow+0

                sum_udif+=udif_val; sum_vdif+=vdif_val
                sum_yspread+=yspread; sum_uavg+=uavg_val
                sum_vavg+=vavg_val; sum_yavg+=yavg_val; sum_ymax+=ymax_val

                is_true_clip       = (ymax_val >= 255)
                is_black_crush     = (ymin_val <= 16)
                is_any_clip        = (is_true_clip || is_black_crush)
                is_widespread_clip = (yhigh_val >= clip_yhigh && ymax_val >= 250)

                if (is_any_clip)        clips++
                if (is_true_clip)       true_clips++
                if (is_widespread_clip) widespread_clips++

                if (is_widespread_clip) {
                    n_clip++
                    sum_ydif_clip+=ydif_val; sum_yhigh_clip+=yhigh_val
                    sum_ylow_clip+=ylow_val; sum_yavg_clip+=yavg_val
                    bucket=int(yhigh_val/5)*5; yhigh_hist[bucket]++
                } else {
                    n_noclip++
                    sum_ydif_noclip+=ydif_val; sum_yspread_noclip+=yspread
                }

                if      (ymax_val>=255) ymax_trueclip++
                else if (ymax_val>=236) ymax_superwhite++
                else if (ymax_val>=200) ymax_high++
                else if (ymax_val>=175) ymax_midhigh++
                else if (ymax_val>=128) ymax_midlow++
                else                    ymax_low++

                if      (yavg_val>=160) yavg_bright++
                else if (yavg_val>=128) yavg_midhigh++
                else if (yavg_val>=96)  yavg_midlow++
                else                    yavg_dark++

                sum_vrep+=vrep+0
                sum_chroma_range+=((umax+0)-(umin+0)+(vmax+0)-(vmin+0))/2

                if (yhigh_val>=hi_yhigh) {
                    hl_n++; hl_sum+=yavg_val; hl_sum2+=yavg_val*yavg_val
                }
            }

            if (n == 0) { print "NO_DATA"; exit }

            mean_ydif    = sum_ydif    / n
            mean_udif    = sum_udif    / n
            mean_vdif    = sum_vdif    / n
            mean_yspread = sum_yspread / n
            mean_uavg    = sum_uavg    / n
            mean_vavg    = sum_vavg    / n
            mean_yavg    = sum_yavg    / n
            mean_ymax    = sum_ymax    / n

            chroma_bias = sqrt((mean_uavg - 128)^2 + (mean_vavg - 128)^2)

            var_ydif = (sum_ydif2 / n) - (mean_ydif * mean_ydif)
            sd_ydif  = (var_ydif > 0) ? sqrt(var_ydif) : 0

            mean_ydif_clip      = (n_clip   > 0) ? sum_ydif_clip   / n_clip   : 0
            mean_ydif_noclip    = (n_noclip > 0) ? sum_ydif_noclip / n_noclip : 0
            mean_yhigh_clip     = (n_clip   > 0) ? sum_yhigh_clip  / n_clip   : 0
            mean_ylow_clip      = (n_clip   > 0) ? sum_ylow_clip   / n_clip   : 0
            mean_yavg_clip      = (n_clip   > 0) ? sum_yavg_clip   / n_clip   : 0
            mean_yspread_noclip = (n_noclip > 0) ? sum_yspread_noclip / n_noclip : 0

            # Curves knee: 10th-percentile of YHIGH histogram on clipping frames.
            # This is where tonal gradation starts being compressed toward the
            # ceiling - the natural point to begin highlight rolloff.
            # Clamped to 160-210 so the knee is always below nominal white (235),
            # ensuring a meaningful compression slope above the knee.
            curves_knee = 0
            if (n_clip > 0) {
                target = int(n_clip * 0.10)
                cumulative = 0
                for (b = 0; b <= 255; b += 5) {
                    if (b in yhigh_hist) cumulative += yhigh_hist[b]
                    if (cumulative >= target) { curves_knee = b; break }
                }
                if (curves_knee < 160) curves_knee = 160
                if (curves_knee > 210) curves_knee = 210
            }

            linear_scale = (mean_yavg > 0) ? 128 / mean_yavg : 1

            mean_vrep        = sum_vrep        / n
            mean_chroma_range = sum_chroma_range / n

            # Highlight texture variance: variance of YAVG on hot frames.
            # Uses the Var(X) = E[X²] - E[X]² identity to avoid a second pass.
            if (hl_n > 1) {
                hl_mean = hl_sum / hl_n
                highlight_var = (hl_sum2 / hl_n) - (hl_mean * hl_mean)
            } else {
                highlight_var = 0
            }

            printf "frames=%d\n",               n
            printf "mean_ydif=%.3f\n",           mean_ydif
            printf "sd_ydif=%.3f\n",             sd_ydif
            printf "mean_udif=%.3f\n",           mean_udif
            printf "mean_vdif=%.3f\n",           mean_vdif
            printf "mean_yspread=%.3f\n",        mean_yspread
            printf "mean_yavg=%.3f\n",           mean_yavg
            printf "mean_ymax=%.3f\n",           mean_ymax
            printf "chroma_bias=%.3f\n",         chroma_bias
            printf "dropouts=%d\n",              dropouts+0
            printf "clips=%d\n",                 clips+0
            printf "true_clips=%d\n",            true_clips+0
            printf "widespread_clips=%d\n",      widespread_clips+0
            printf "n_clip=%d\n",                n_clip+0
            printf "n_noclip=%d\n",              n_noclip+0
            printf "mean_ydif_clip=%.3f\n",      mean_ydif_clip
            printf "mean_ydif_noclip=%.3f\n",    mean_ydif_noclip
            printf "mean_yhigh_clip=%.3f\n",     mean_yhigh_clip
            printf "mean_ylow_clip=%.3f\n",      mean_ylow_clip
            printf "mean_yspread_noclip=%.3f\n", mean_yspread_noclip
            printf "linear_scale=%.4f\n",        linear_scale
            printf "curves_knee=%d\n",           curves_knee+0
            printf "ymax_trueclip=%d\n",         ymax_trueclip+0
            printf "ymax_superwhite=%d\n",       ymax_superwhite+0
            printf "ymax_high=%d\n",             ymax_high+0
            printf "ymax_midhigh=%d\n",          ymax_midhigh+0
            printf "ymax_midlow=%d\n",           ymax_midlow+0
            printf "ymax_low=%d\n",              ymax_low+0
            printf "yavg_bright=%d\n",           yavg_bright+0
            printf "yavg_midhigh=%d\n",          yavg_midhigh+0
            printf "yavg_midlow=%d\n",           yavg_midlow+0
            printf "yavg_dark=%d\n",             yavg_dark+0
            printf "mean_vrep=%.3f\n",           mean_vrep
            printf "mean_chroma_range=%.3f\n",   mean_chroma_range
            printf "highlight_var=%.3f\n",       highlight_var
            printf "highlight_n=%d\n",           hl_n+0
        }
    ' "$LOG"
}

MA=$(compute_metrics "$W/a_aligned.log")
if [ "$SINGLE_MODE" -eq 0 ]; then
    MB=$(compute_metrics "$W/b_aligned.log")
fi

# Pull individual values out of the key=value output.
get() { echo "$1" | grep "^$2=" | cut -d= -f2; }

# Extract A metrics (always needed).
FA=$(get "$MA" frames)
YDA=$(get "$MA" mean_ydif);    SDA=$(get "$MA" sd_ydif)
UDA=$(get "$MA" mean_udif);    VDA=$(get "$MA" mean_vdif)
YSA=$(get "$MA" mean_yspread); YAA=$(get "$MA" mean_yavg)
YMA=$(get "$MA" mean_ymax);    CBA=$(get "$MA" chroma_bias)
DOA=$(get "$MA" dropouts);     CLA=$(get "$MA" clips)
TCLA=$(get "$MA" true_clips);  WCLA=$(get "$MA" widespread_clips)
NCA=$(get "$MA" n_clip);       NNCA=$(get "$MA" n_noclip)
YDCA=$(get "$MA" mean_ydif_clip);     YDNA=$(get "$MA" mean_ydif_noclip)
YHCA=$(get "$MA" mean_yhigh_clip);    YLCA=$(get "$MA" mean_ylow_clip)
YSNA=$(get "$MA" mean_yspread_noclip)
SCLA=$(get "$MA" linear_scale);       KNEA=$(get "$MA" curves_knee)
YVBRA=$(get "$MA" yavg_bright);  YVMHA=$(get "$MA" yavg_midhigh)
YVMLA=$(get "$MA" yavg_midlow);  YVDA=$(get "$MA"  yavg_dark)
YMTCA=$(get "$MA" ymax_trueclip);  YMSWA=$(get "$MA" ymax_superwhite)
YMHA=$(get "$MA"  ymax_high);      YMMHA=$(get "$MA" ymax_midhigh)
YMMLA=$(get "$MA" ymax_midlow);    YMLA=$(get "$MA"  ymax_low)
VREPA=$(get "$MA" mean_vrep);      CRNGA=$(get "$MA" mean_chroma_range)
HLVA=$(get "$MA"  highlight_var);  HLNA=$(get "$MA"  highlight_n)

if [ "$SINGLE_MODE" -eq 0 ]; then
    # Extract B metrics (two-file mode only).
    FB=$(get "$MB" frames)
    YDB=$(get "$MB" mean_ydif);    SDB=$(get "$MB" sd_ydif)
    UDB=$(get "$MB" mean_udif);    VDB=$(get "$MB" mean_vdif)
    YSB=$(get "$MB" mean_yspread); YAB=$(get "$MB" mean_yavg)
    YMB=$(get "$MB" mean_ymax);    CBB=$(get "$MB" chroma_bias)
    DOB=$(get "$MB" dropouts);     CLB=$(get "$MB" clips)
    TCLB=$(get "$MB" true_clips);  WCLB=$(get "$MB" widespread_clips)
    NCB=$(get "$MB" n_clip);       NNCB=$(get "$MB" n_noclip)
    YDCB=$(get "$MB" mean_ydif_clip);     YDNB=$(get "$MB" mean_ydif_noclip)
    YHCB=$(get "$MB" mean_yhigh_clip);    YLCB=$(get "$MB" mean_ylow_clip)
    YSNB=$(get "$MB" mean_yspread_noclip)
    SCLB=$(get "$MB" linear_scale);       KNEB=$(get "$MB" curves_knee)
    YVBRB=$(get "$MB" yavg_bright);  YVMHB=$(get "$MB" yavg_midhigh)
    YVMLB=$(get "$MB" yavg_midlow);  YVDB=$(get "$MB"  yavg_dark)
    YMTCB=$(get "$MB" ymax_trueclip);  YMSWB=$(get "$MB" ymax_superwhite)
    YMHB=$(get "$MB"  ymax_high);      YMMHB=$(get "$MB" ymax_midhigh)
    YMMLB=$(get "$MB" ymax_midlow);    YMLB=$(get "$MB"  ymax_low)
    VREPB=$(get "$MB" mean_vrep);      CRNGB=$(get "$MB" mean_chroma_range)
    HLVB=$(get "$MB"  highlight_var);  HLNB=$(get "$MB"  highlight_n)

    # winner A B lower|higher - prints "A", "B", or "=" indicating which is better.
    winner() {
        awk -v a="$1" -v b="$2" -v prefer="$3" 'BEGIN {
            if (prefer == "lower") {
                if (a < b) print "A"; else if (b < a) print "B"; else print "="
            } else {
                if (a > b) print "A"; else if (b > a) print "B"; else print "="
            }
        }'
    }

    W_YDIF=$(winner "$YDA" "$YDB" lower)
    W_UDIF=$(winner "$UDA" "$UDB" lower)
    W_VDIF=$(winner "$VDA" "$VDB" lower)
    W_YSTD=$(winner "$YSA" "$YSB" higher)
    W_YAVG=$(winner "$YAA" "$YAB" lower)
    W_YMAX=$(winner "$YMA" "$YMB" lower)
    W_CBIAS=$(winner "$CBA" "$CBB" lower)
    W_DROP=$(winner "$DOA" "$DOB" lower)
    W_CLIP=$(winner "$CLA" "$CLB" lower)
    W_TCLIP=$(winner "$TCLA" "$TCLB" lower)
    W_WCLIP=$(winner "$WCLA" "$WCLB" lower)
    W_YMTC=$(winner "$YMTCA"  "$YMTCB"  lower)
    W_YMSW=$(winner "$YMSWA"  "$YMSWB"  lower)
    W_YVBR=$(winner "$YVBRA"  "$YVBRB"  lower)
    W_VREP=$(winner "$VREPA" "$VREPB" lower)
    W_CRNG=$(winner "$CRNGA" "$CRNGB" higher)
    W_HLV=$(winner "$HLVA"  "$HLVB"  higher)
    W_YDCA=$(winner "$YDCA"  "$YDCB"  lower)
    W_YDNA=$(winner "$YDNA"  "$YDNB"  lower)
    W_YHCA=$(winner "$YHCA"  "$YHCB"  higher)
    W_YLCA=$(winner "$YLCA"  "$YLCB"  lower)
    W_YSNA=$(winner "$YSNA"  "$YSNB"  higher)
fi

# ------------------------------------------------------------------------------
# Helper: _emit_cmd LABEL INFILE KNEE SCALE
# Emits a ready-to-run ffmpeg highlight rolloff or linear scale command.
# Defined here so it is available in both single-file and two-file report modes.
# Derives output filename by inserting '_corrected' before the extension.
#
# Output codec and container are chosen based on the input codec:
#   DV (dvvideo)  : -c:v dvvideo, same extension (.dv/.avi)
#   FFV1 in MKV   : -c:v ffv1 -level 3, .mkv extension
#   Other         : -c:v libx264 -crf 16 -preset slower, .mkv extension
#
# The rolloff uses lutyuv=y (ffmpeg 4.x compatible).  Values at or below the
# knee are unchanged.  Above the knee the full knee-255 range is compressed
# into knee-235, preserving all gradation including super-white (236-254).
# slope = (235 - knee) / (255 - knee)
# output = knee + (val - knee) * slope   for val > knee
# Maps: val=knee -> knee, val=255 -> 235.
_emit_cmd() {
    local label="$1" infile="$2" knee="$3" scale="$4"

    local base ext outfile codec video_codec container_ext
    base="${infile%.*}"
    ext="${infile##*.}"

    # Detect input video codec to select appropriate output codec.
    codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$infile" 2>/dev/null || echo "unknown")

    if [[ "$codec" == "dvvideo" ]]; then
        # DV input: re-encode as DV, preserve original container extension.
        video_codec="-c:v dvvideo"
        container_ext="$ext"
    elif [[ "$codec" == "ffv1" ]]; then
        # FFV1/MKV input: re-encode as FFV1 lossless, keep MKV container.
        video_codec="-c:v ffv1 -level 3 -coder 1 -context 1"
        container_ext="mkv"
    else
        # Unknown/other: high-quality x264 in MKV as a safe fallback.
        video_codec="-c:v libx264 -crf 16 -preset slower"
        container_ext="mkv"
    fi
    outfile="${base}_corrected.${container_ext}"

    if [ "$knee" -gt 0 ] 2>/dev/null; then
        local slope
        slope=$(awk "BEGIN{printf \"%.6f\", (235-$knee)/(255-$knee)}")
        printf "  %s highlight rolloff (knee=%d, 255->235):\n" "$label" "$knee"
        printf "  ffmpeg -i '%s' -vf \"lutyuv=y='if(gt(val\\,%d)\\,%d+((val-%d)*%s)\\,val)'\" %s -c:a copy '%s'\n" \
            "$infile" "$knee" "$knee" "$knee" "$slope" "$video_codec" "$outfile"
        printf "\n"
    elif awk -v s="$scale" 'BEGIN{exit !(s < 0.99)}'; then
        printf "  %s linear brightness scale (no widespread clipping):\n" "$label"
        # Scale only the active luma range (16-235), preserving black at 16.
        # Without this, val*scale for values just above 16 would fall below 16
        # and get clipped to 16, crushing shadow detail.
        # Formula: 16 + (val - 16) * scale, clamped to 16-235.
        printf "  ffmpeg -i '%s' -vf \"lutyuv=y='clip(16+((val-16)*%s)\\,16\\,235)'\" %s -c:a copy '%s'\n" \
            "$infile" "$scale" "$video_codec" "$outfile"
        printf "\n"
    fi
}

echo ""
echo "[5b] Checking capture integrity..."
INTEGRITY_A_OK=0
check_integrity "$A" "$FA" "Capture A" "$DVGRAB_LOG_A" || INTEGRITY_A_OK=1
if [ "$SINGLE_MODE" -eq 0 ]; then
    INTEGRITY_B_OK=0
    check_integrity "$B" "$FB" "Capture B" "$DVGRAB_LOG_B" || INTEGRITY_B_OK=1
fi


if [ "$SINGLE_MODE" -eq 1 ]; then

# ------------------------------------------------------------------------------
# Single-file report: brightness calibration focus
# ------------------------------------------------------------------------------
{
printf "========================================\n"
printf "  VHS CAPTURE QUALITY REPORT (SINGLE)\n"
printf "========================================\n"
printf "\n"
printf "  Capture : %s\n" "$A"
printf "\n"
if [ -n "$SAMPLE_DURATION" ]; then
    printf "  *** SAMPLE MODE: first %ss only - results are indicative ***\n" "$SAMPLE_DURATION"
    printf "\n"
fi
printf "  Frames analysed : %s\n" "$FA"
if [ "$INTEGRITY_A_OK" -eq 1 ]; then
    printf "  *** WARNING: dropped frames detected — capture may be incomplete ***\n"
fi
printf "\n"

# --- Brightness calibration summary ---
printf "Brightness Calibration\n"
printf "  Target: mean_yavg ~128-132 for headroom on bright VHS content.\n"
printf "  widespread_clip should be well below the total frame count.\n"
printf "  highlight_var > 0 indicates texture survives in bright frames.\n"
printf "\n"
printf "%-42s %10s\n" "Metric" "Value"
printf "%-42s %10s\n" "------" "-----"
printf "%-42s %10s\n" "Mean brightness        (YAVG)"        "$YAA"
printf "%-42s %10s\n" "Mean peak luma         (YMAX mean)"   "$YMA"
printf "%-42s %10s\n" "Widespread clip frames (YHIGH>=${CLIP_YHIGH_THRESHOLD})" "$WCLA"
printf "%-42s %10s\n" "Hard clip frames       (YMAX=255)"    "$TCLA"
printf "%-42s %10s\n" "Highlight texture var  (YHIGH>=${HIGHLIGHT_YHIGH_THRESHOLD}, n=${HLNA})" "$HLVA"
printf "%-42s %10s\n" "Dropout frames         (YDIF>${DROPOUT_YDIF_THRESHOLD})" "$DOA"
printf "\n"

# --- YMAX distribution ---
printf "YMAX Distribution (frames per luma bucket)\n"
printf "  Hard clip=255 (ADC ceiling, information lost); near-white=236-254\n"
printf "  (valid displayable signal); mid-high and below have full headroom.\n"
printf "  A spike at 255 with near-zero neighbours at 253-254 indicates ADC\n"
printf "  clipping.  A smooth rolloff to 255 is genuine bright signal.\n"
printf "\n"
printf "%-42s %10s\n" "Bucket" "Frames"
printf "%-42s %10s\n" "------" "------"
printf "%-42s %10s\n" "  Hard clip   (YMAX = 255)"          "$YMTCA"
printf "%-42s %10s\n" "  Near-white  (236 <= YMAX < 255)"   "$YMSWA"
printf "%-42s %10s\n" "  High        (200 <= YMAX <= 235)"  "$YMHA"
printf "%-42s %10s\n" "  Mid-high    (175 <= YMAX < 200)"   "$YMMHA"
printf "%-42s %10s\n" "  Mid-low     (128 <= YMAX < 175)"   "$YMMLA"
printf "%-42s %10s\n" "  Low         (YMAX < 128)"          "$YMLA"
printf "\n"

# --- YAVG distribution ---
printf "YAVG Distribution (frames per brightness bucket)\n"
printf "  If the Bright bucket (YAVG>=160) is large the overall signal is\n"
printf "  hot.  A well-attenuated capture should have most frames in the\n"
printf "  Mid-high or Mid-low buckets.\n"
printf "\n"
printf "%-42s %10s\n" "Bucket" "Frames"
printf "%-42s %10s\n" "------" "------"
printf "%-42s %10s\n" "  Bright   (YAVG >= 160)"        "$YVBRA"
printf "%-42s %10s\n" "  Mid-high (128 <= YAVG < 160)"  "$YVMHA"
printf "%-42s %10s\n" "  Mid-low  ( 96 <= YAVG < 128)"  "$YVMLA"
printf "%-42s %10s\n" "  Dark     (YAVG < 96)"           "$YVDA"
printf "\n"

# --- Clip-conditioned ---
printf "Clip-Conditioned Statistics\n"
printf "\n"
printf "%-42s %10s\n" "Metric" "Value"
printf "%-42s %10s\n" "------" "-----"
printf "%-42s %10s\n" "  Clipping frames"                             "$NCA"
printf "%-42s %10s\n" "  Non-clipping frames"                         "$NNCA"
printf "%-42s %10s\n" "  YDIF on clipping frames"                     "$YDCA"
printf "%-42s %10s\n" "  YDIF on non-clipping frames"                 "$YDNA"
printf "%-42s %10s\n" "  YHIGH on clipping frames (sub-ceil detail)"  "$YHCA"
printf "%-42s %10s\n" "  YLOW  on clipping frames (shadow floor)"     "$YLCA"
printf "%-42s %10s\n" "  Spatial detail on non-clipping frames"       "$YSNA"
printf "\n"

# --- Signal metrics ---
printf "Signal Metrics\n"
printf "\n"
printf "%-42s %10s\n" "Metric" "Value"
printf "%-42s %10s\n" "------" "-----"
printf "%-42s %10s\n" "Temporal luma noise    (YDIF mean)"        "$YDA"
printf "%-42s %10s\n" "Temporal luma noise    (YDIF stddev)"      "$SDA"
printf "%-42s %10s\n" "Temporal chroma noise  (UDIF mean)"        "$UDA"
printf "%-42s %10s\n" "Temporal chroma noise  (VDIF mean)"        "$VDA"
printf "%-42s %10s\n" "Spatial luma detail    (YHIGH-YLOW)"       "$YSA"
printf "%-42s %10s\n" "Chroma bias            (UV dist from 128)" "$CBA"
printf "%-42s %10s\n" "Chroma bandwidth       (UV range mean)"    "$CRNGA"
printf "%-42s %10s\n" "Vertical line repeat   (VREP mean)"        "$VREPA"
printf "\n"

# --- Post-processing ---
printf "Post-Processing Guidance\n"
printf "  Widespread clip frames (YHIGH>=${CLIP_YHIGH_THRESHOLD}): %s\n" "$WCLA"
printf "  Hard clip frames (YMAX=255): %s\n" "$TCLA"
printf "\n"
if [ "$SHOW_CORRECTION_CMD" -eq 1 ]; then
    printf "Post-Processing Correction Command\n"
    printf "  WARNING: only useful when the luma histogram shows a hard ADC spike\n"
    printf "  at Y=255 with near-zero neighbours at 253-254.  Applying this to a\n"
    printf "  smooth bright signal compresses real information — verify the\n"
    printf "  histogram before using this command.\n"
    printf "\n"
    printf "  Linear scale to midpoint (fallback): %s\n" "$SCLA"
    printf "\n"
    _emit_cmd "Capture:" "$A" "$KNEA" "$SCLA"
fi

printf "========================================\n"
} > "$W/report.txt"

else

# ------------------------------------------------------------------------------
# Two-file report: side-by-side comparison
# ------------------------------------------------------------------------------
{
printf "========================================\n"
printf "  VHS CAPTURE QUALITY REPORT\n"
printf "========================================\n"
printf "\n"
printf "  Capture A : %s\n" "$A"
printf "  Capture B : %s\n" "$B"
printf "\n"
if [ -n "$SAMPLE_DURATION" ]; then
    printf "  *** SAMPLE MODE: first %ss only - results are indicative ***\n" "$SAMPLE_DURATION"
    printf "\n"
fi
printf "  Audio peak A    : %ss\n"   "$PEAK_A"
printf "  Audio peak B    : %ss\n"   "$PEAK_B"
printf "  Alignment offset: %d frames (%.3fs)\n" \
    "$OFFSET_FRAMES" \
    "$(awk -v f="$OFFSET_FRAMES" 'BEGIN {printf "%.3f", f/29.97}')"
printf "  Aligned frames  : A=%s  B=%s\n" "$FA" "$FB"
if [ "${INTEGRITY_A_OK:-0}" -eq 1 ]; then
    printf "  *** WARNING: Capture A has dropped frames — capture may be incomplete ***\n"
fi
if [ "${INTEGRITY_B_OK:-0}" -eq 1 ]; then
    printf "  *** WARNING: Capture B has dropped frames — capture may be incomplete ***\n"
fi
if [ "$FRAMES_A" -ne "$FRAMES_B" ]; then
    SHORTER_DUR=$(awk -v f="$SHORTER" 'BEGIN {
        m = int(f/29.97/60); s = f/29.97 - m*60
        printf "%dm%04.1fs", m, s
    }')
    printf "  Trimmed to      : %d frames (%s) — shorter capture limits comparison\n" \
        "$SHORTER" "$SHORTER_DUR"
fi
printf "\n"
printf "%-42s %8s %8s %6s\n" "Metric" "A" "B" "Better"
printf "%-42s %8s %8s %6s\n" "------" "-" "-" "------"
printf "%-42s %8s %8s %6s\n" \
    "Temporal luma noise    (YDIF mean)" \
    "$YDA" "$YDB" "$W_YDIF"
printf "%-42s %8s %8s %6s\n" \
    "Temporal luma noise    (YDIF stddev)" \
    "$SDA" "$SDB" "$W_YDIF"
printf "%-42s %8s %8s %6s\n" \
    "Temporal chroma noise  (UDIF mean)" \
    "$UDA" "$UDB" "$W_UDIF"
printf "%-42s %8s %8s %6s\n" \
    "Temporal chroma noise  (VDIF mean)" \
    "$VDA" "$VDB" "$W_VDIF"
printf "%-42s %8s %8s %6s\n" \
    "Spatial luma detail    (YHIGH-YLOW)" \
    "$YSA" "$YSB" "$W_YSTD"
printf "%-42s %8s %8s %6s\n" \
    "Mean brightness        (YAVG)" \
    "$YAA" "$YAB" "$W_YAVG"
printf "%-42s %8s %8s %6s\n" \
    "Mean peak luma         (YMAX mean)" \
    "$YMA" "$YMB" "$W_YMAX"
printf "%-42s %8s %8s %6s\n" \
    "Chroma bias            (UV dist from 128)" \
    "$CBA" "$CBB" "$W_CBIAS"
printf "%-42s %8s %8s %6s\n" \
    "Dropout frames         (YDIF>${DROPOUT_YDIF_THRESHOLD})" \
    "$DOA" "$DOB" "$W_DROP"
printf "%-42s %8s %8s %6s\n" \
    "Hard clip frames       (YMAX=255)" \
    "$TCLA" "$TCLB" "$W_TCLIP"
printf "%-42s %8s %8s %6s\n" \
    "Widespread clip frames (YHIGH>=${CLIP_YHIGH_THRESHOLD})" \
    "$WCLA" "$WCLB" "$W_WCLIP"
printf "%-42s %8s %8s %6s\n" \
    "Vertical line repeat   (VREP mean)" \
    "$VREPA" "$VREPB" "$W_VREP"
printf "%-42s %8s %8s %6s\n" \
    "Chroma bandwidth       (UV range mean)" \
    "$CRNGA" "$CRNGB" "$W_CRNG"
printf "%-42s %8s %8s %6s\n" \
    "Highlight texture var  (YHIGH>=${HIGHLIGHT_YHIGH_THRESHOLD}, n=A:${HLNA}/B:${HLNB})" \
    "$HLVA" "$HLVB" "$W_HLV"
printf "\n"
printf "YMAX Distribution (frames per luma bucket)\n"
printf "  Hard clip=255 (ADC ceiling, information lost); near-white=236-254\n"
printf "  (valid displayable signal); mid-high and below have full headroom.\n"
printf "  A spike at 255 with near-zero neighbours at 253-254 indicates ADC\n"
printf "  clipping.  A smooth rolloff to 255 is genuine bright signal.\n"
printf "\n"
printf "%-42s %8s %8s %6s\n" "Bucket" "A" "B" "Better"
printf "%-42s %8s %8s %6s\n" "------" "-" "-" "------"
printf "%-42s %8s %8s %6s\n" \
    "  Hard clip   (YMAX = 255)" \
    "$YMTCA" "$YMTCB" "$W_YMTC"
printf "%-42s %8s %8s %6s\n" \
    "  Near-white  (236 <= YMAX < 255)" \
    "$YMSWA" "$YMSWB" "$W_YMSW"
printf "%-42s %8s %8s %6s\n" \
    "  High        (200 <= YMAX <= 235)" \
    "$YMHA" "$YMHB" ""
printf "%-42s %8s %8s %6s\n" \
    "  Mid-high    (175 <= YMAX < 200)" \
    "$YMMHA" "$YMMHB" ""
printf "%-42s %8s %8s %6s\n" \
    "  Mid-low     (128 <= YMAX < 175)" \
    "$YMMLA" "$YMMLB" ""
printf "%-42s %8s %8s %6s\n" \
    "  Low         (YMAX < 128)" \
    "$YMLA" "$YMLB" ""
printf "\n"
printf "YAVG Distribution (frames per brightness bucket)\n"
printf "  A whole-frame brightness lift shifts all buckets upward.\n"
printf "  If only the bright bucket differs, the excess is in highlights.\n"
printf "\n"
printf "%-42s %8s %8s %6s\n" "Bucket" "A" "B" "Better"
printf "%-42s %8s %8s %6s\n" "------" "-" "-" "------"
printf "%-42s %8s %8s %6s\n" \
    "  Bright     (YAVG >= 160)" \
    "$YVBRA" "$YVBRB" "$W_YVBR"
printf "%-42s %8s %8s %6s\n" \
    "  Mid-high   (128 <= YAVG < 160)" \
    "$YVMHA" "$YVMHB" ""
printf "%-42s %8s %8s %6s\n" \
    "  Mid-low    ( 96 <= YAVG < 128)" \
    "$YVMLA" "$YVMLB" ""
printf "%-42s %8s %8s %6s\n" \
    "  Dark       (YAVG < 96)" \
    "$YVDA" "$YVDB" ""
printf "\n"
printf "Clip-Conditioned Statistics\n"
printf "  Metrics computed separately for clipping vs non-clipping frames.\n"
printf "  Isolates clipping artefact inflation from genuine signal noise.\n"
printf "\n"
printf "%-42s %8s %8s %6s\n" "Metric" "A" "B" "Better"
printf "%-42s %8s %8s %6s\n" "------" "-" "-" "------"
printf "%-42s %8s %8s %6s\n" \
    "  Clipping frames" \
    "$NCA" "$NCB" ""
printf "%-42s %8s %8s %6s\n" \
    "  Non-clipping frames" \
    "$NNCA" "$NNCB" ""
printf "%-42s %8s %8s %6s\n" \
    "  YDIF on clipping frames" \
    "$YDCA" "$YDCB" "$W_YDCA"
printf "%-42s %8s %8s %6s\n" \
    "  YDIF on non-clipping frames" \
    "$YDNA" "$YDNB" "$W_YDNA"
printf "%-42s %8s %8s %6s\n" \
    "  YHIGH on clipping frames (sub-ceil detail)" \
    "$YHCA" "$YHCB" "$W_YHCA"
printf "%-42s %8s %8s %6s\n" \
    "  YLOW  on clipping frames (shadow floor)" \
    "$YLCA" "$YLCB" "$W_YLCA"
printf "%-42s %8s %8s %6s\n" \
    "  Spatial detail on non-clipping frames" \
    "$YSNA" "$YSNB" "$W_YSNA"
printf "\n"
printf "Post-Processing Guidance\n"
printf "%-42s %8s %8s\n" "Metric" "A" "B"
printf "%-42s %8s %8s\n" "------" "-" "-"
printf "%-42s %8s %8s\n" \
    "  Widespread clip frames (YHIGH>=${CLIP_YHIGH_THRESHOLD})" \
    "$WCLA" "$WCLB"
printf "%-42s %8s %8s\n" \
    "  Hard clip frames (YMAX=255)" \
    "$TCLA" "$TCLB"
printf "\n"
if [ "$SHOW_CORRECTION_CMD" -eq 1 ]; then
    printf "Post-Processing Correction Command\n"
    printf "  WARNING: only useful when the luma histogram shows a hard ADC spike\n"
    printf "  at Y=255 with near-zero neighbours at 253-254.  Applying this to a\n"
    printf "  smooth bright signal compresses real information — verify the\n"
    printf "  histogram before using this command.\n"
    printf "\n"
    printf "%-42s %8s %8s\n" \
        "  Linear scale to midpoint (fallback)" \
        "$SCLA" "$SCLB"
    printf "\n"
    _emit_cmd "Capture A:" "$A" "$KNEA" "$SCLA"
    _emit_cmd "Capture B:" "$B" "$KNEB" "$SCLB"
fi
printf "  Temporal luma noise (YDIF): mean absolute luma change frame-to-\n"
printf "  frame. Lower = less noise and fewer dropouts from the VCR.\n"
printf "\n"
printf "  Temporal chroma noise (UDIF/VDIF): frame-to-frame chroma change.\n"
printf "  S-Video keeps luma/chroma separate so should score lower than\n"
printf "  composite on stable scenes.\n"
printf "\n"
printf "  Spatial luma detail (YHIGH-YLOW): inter-quartile luma range within\n"
printf "  each frame. Higher means more tonal detail retained.\n"
printf "\n"
printf "  Mean brightness (YAVG): average luma level across all frames.\n"
printf "  A significantly higher value in one capture indicates that VCR\n"
printf "  is outputting a boosted signal - consistent with a VCR not in\n"
printf "  Edit mode applying internal processing. This lifts midtones but\n"
printf "  compresses highlight headroom, causing detail loss in bright\n"
printf "  areas such as a reflective dance floor.\n"
printf "\n"
printf "  Mean peak luma (YMAX mean): average of per-frame maximum luma.\n"
printf "  A high value confirms highlights are being pushed toward\n"
printf "  clipping, corroborating what YAVG suggests about brightness.\n"
printf "\n"
printf "  Chroma bias (UV distance from neutral 128): composite dot crawl\n"
printf "  and colour bleed shift U/V averages away from neutral. Lower =\n"
printf "  more accurate colour reproduction.\n"
printf "\n"
printf "  Dropout frames: single-frame YDIF spikes above threshold.\n"
printf "  See dropouts_a.txt / dropouts_b.txt for frame-level detail.\n"
printf "\n"
printf "  Hard clip frames (YMAX=255): frames where at least one pixel has\n"
printf "  hit the ADC ceiling.  Check the luma histogram: a spike at 255\n"
printf "  with near-zero neighbours indicates genuine information loss.\n"
printf "  A smooth rolloff to 255 means the signal is bright but intact.\n"
printf "\n"
printf "  Widespread clip (YHIGH>=%d): frames where the 75th-percentile\n" \
    "$CLIP_YHIGH_THRESHOLD"
printf "  luma exceeds this threshold — at least 25%% of the frame is very\n"
printf "  bright.  Used to compare signal path headroom between two VCRs.\n"
printf "  A large difference between A-only and B-only counts identifies\n"
printf "  the deck with less headroom.  Does NOT indicate the signal needs\n"
printf "  post-processing correction unless the histogram confirms a hard\n"
printf "  ADC spike at 255.\n"
printf "  Adjust CLIP_YHIGH_THRESHOLD in the script if needed.\n"
printf "\n"
printf "  Vertical line repeat (VREP): signalstats measure of how much\n"
printf "  each line resembles the one above it.  A high mean VREP indicates\n"
printf "  head clog, tape damage, or signal smearing causing repeated lines.\n"
printf "  If one VCR has elevated VREP it suggests a tracking or head\n"
printf "  contact problem rather than a signal path quality difference.\n"
printf "\n"
printf "  Chroma bandwidth (UV range): mean of (UMAX-UMIN + VMAX-VMIN)/2\n"
printf "  per frame.  Measures how much colour excursion is retained.\n"
printf "  S-Video separates luma/chroma on the cable and should produce a\n"
printf "  wider range than composite.  A narrower range on the S-Video path\n"
printf "  points to internal chroma processing or an unexpected cabling issue.\n"
printf "\n"
printf "  Highlight texture variance: variance of YAVG on frames where\n"
printf "  YHIGH >= %d (i.e. the 75th-percentile luma is in the bright\n" \
    "$HIGHLIGHT_YHIGH_THRESHOLD"
printf "  zone).  A VCR that clips highlights compresses all detail toward\n"
printf "  a flat ceiling, yielding near-zero variance.  A VCR with headroom\n"
printf "  shows genuine tonal variation even on the brightest frames.  The\n"
printf "  frame count n is shown so you can judge statistical reliability;\n"
printf "  few qualifying frames = treat result as indicative only.\n"
printf "  Adjust HIGHLIGHT_YHIGH_THRESHOLD in the script if needed.\n"
printf "\n"
printf "  Clip-conditioned YDIF: noise measured separately on widespread-\n"
printf "  clipping vs non-clipping frames.  Overall YDIF is inflated when\n"
printf "  clipping frames are common.  YDIF on non-clipping frames is the\n"
printf "  cleaner noise indicator and enables fairer VCR comparison.\n"
printf "\n"
printf "  YHIGH on clipping frames: mean 75th-percentile luma on frames\n"
printf "  that show widespread clipping.  A higher value means more tonal\n"
printf "  gradation survives below the 235 ceiling.  Combined with the\n"
printf "  curves knee this shows whether post-processing will help.\n"
printf "\n"
printf "  YLOW on clipping frames: mean 25th-percentile luma on clipping\n"
printf "  frames.  A lower value means shadows are preserved in the same\n"
printf "  frames where highlights are clipping - wider dynamic range.\n"
printf "\n"
printf "  Spatial detail on non-clipping frames: YHIGH-YLOW on frames\n"
printf "  that did not show widespread clipping.  Gives a cleaner detail\n"
printf "  comparison uncontaminated by clipping artefacts.\n"
printf "\n"
printf "  Post-processing curves: the rolloff uses lutyuv=y (ffmpeg 4.x\n"
printf "  compatible) to compress luma above the knee, leaving everything\n"
printf "  below the knee unchanged.  Only apply when the luma histogram\n"
printf "  confirms a hard ADC spike at Y=255; applying it to a smooth\n"
printf "  bright signal compresses real information unnecessarily.  The\n"
printf "  knee is derived from the 10th-percentile of the YHIGH histogram\n"
printf "  on clipping frames.  If no widespread clipping is detected a\n"
printf "  simpler linear scale is suggested instead.\n"
printf "\n"
printf "  YMAX distribution: frame counts bucketed by per-frame peak luma.\n"
printf "  Hard clip at 255 is the only value representing information loss.\n"
printf "  Values 236-254 and below are valid displayable signal; they do\n"
printf "  not require correction.\n"
printf "\n"
printf "  YAVG distribution: frame counts bucketed by per-frame mean luma.\n"
printf "  Compares where the overall brightness mass sits. If the bright\n"
printf "  bucket (YAVG>=160) differs between captures but the dark and\n"
printf "  mid-low buckets are similar, the brightness difference is\n"
printf "  confined to highlight-dominated frames (e.g. dance floor\n"
printf "  reflections). If all buckets shift together, the VCR is applying\n"
printf "  a whole-signal lift rather than just boosting highlights.\n"
printf "========================================\n"
} > "$W/report.txt"

fi  # end SINGLE_MODE branch

# Report is printed once at the end of Step 7 (after histogram is appended
# if --histogram was requested).  Do not cat here.

# ------------------------------------------------------------------------------
# Step 6: Paired-frame analysis  (two-file mode only)
# ------------------------------------------------------------------------------
if [ "$SINGLE_MODE" -eq 1 ]; then
    echo ""
    echo "[6/6] Paired-frame analysis... skipped (single-file mode)"
else
# Reads both aligned logs simultaneously in Python, processing frames in
# lockstep (frame N in A corresponds to frame N in B — same tape content).
# Produces:
#   - A summary section appended to report.txt with aggregate paired metrics:
#       * YAVG difference distribution (fixed offset vs content-correlated)
#       * Clipping coincidence breakdown (both / A-only / B-only / neither)
#       * Differential YDIF (noise isolated from shared scene motion)
#       * VREP coincidence (tape damage vs single-VCR head/tracking problem)
#   - paired_frames.txt: one row per frame where |YAVG_A - YAVG_B| exceeds
#     PAIRED_YAVG_DIFF_THRESHOLD, with per-frame values for targeted visual QC.
#
# Thresholds used (all tunable at the top of this script):
#   CLIP_YHIGH_THRESHOLD      — widespread-clip gate (shared with Steps 4-5)
#   PAIRED_YAVG_DIFF_THRESHOLD — minimum |YAVG_A - YAVG_B| to log a frame
#   PAIRED_VREP_THRESHOLD      — VREP spike level for coincidence analysis
# ------------------------------------------------------------------------------

# Minimum |YAVG_A - YAVG_B| (luma units, 0-255 scale) for a frame to be
# written to paired_frames.txt.  Frames below this threshold are considered
# well-matched and are not individually logged.  Raise to reduce log volume
# on footage with a bright overall signal; lower to catch subtle divergence.
PAIRED_YAVG_DIFF_THRESHOLD=5

# VREP level above which a frame is considered a VREP spike for the purpose
# of coincidence analysis.  signalstats VREP is a percentage (0-100).
# Values above ~10 typically indicate visible line repetition artefacts.
PAIRED_VREP_THRESHOLD=10

echo ""
echo "[6/6] Paired-frame analysis..."

python3 - <<PYEOF
import sys, math

LOG_A       = "$W/a_aligned.log"
LOG_B       = "$W/b_aligned.log"
REPORT      = "$W/report.txt"
PAIRED_OUT  = "$W/paired_frames.txt"
CLIP_YHIGH  = $CLIP_YHIGH_THRESHOLD
YAVG_DIFF_T = $PAIRED_YAVG_DIFF_THRESHOLD
VREP_T      = $PAIRED_VREP_THRESHOLD

# ------------------------------------------------------------------
# parse_frames(path) -> generator of dict per frame
# Each dict contains the numeric values of every signalstats key
# present in the log for that frame, plus 'framenum'.
# ------------------------------------------------------------------
def parse_frames(path):
    frame = {}
    with open(path) as fh:
        for line in fh:
            line = line.rstrip()
            if line.startswith("frame:"):
                if frame:
                    yield frame
                # "frame:N    pts:..."  — extract N from first token
                frame = {"framenum": int(line.split()[0].split(":")[1])}
            elif line.startswith("lavfi.signalstats."):
                # "lavfi.signalstats.KEY=VALUE"
                key, _, val = line.partition("=")
                short = key.split(".")[-1]   # e.g. "YAVG"
                try:
                    frame[short] = float(val)
                except ValueError:
                    pass
    if frame:
        yield frame

# ------------------------------------------------------------------
# Accumulators for paired statistics
# ------------------------------------------------------------------
n_paired = 0          # total paired frames processed

# YAVG difference: A - B per frame
yavg_diff_sum  = 0.0
yavg_diff_sum2 = 0.0
yavg_diff_pos  = 0    # frames where A > B (A brighter)
yavg_diff_neg  = 0    # frames where B > A (B brighter)
yavg_diff_eq   = 0    # frames within 1 luma unit (matched)

# Clipping coincidence (widespread clip gate = CLIP_YHIGH)
clip_both  = 0    # both captures clip on this frame
clip_a_only = 0   # only A clips  → A's signal path has less headroom
clip_b_only = 0   # only B clips  → B's signal path has less headroom
clip_none  = 0    # neither clips → content below clip threshold

# Differential YDIF: (YDIF_A - YDIF_B) isolates path noise from scene motion.
# Computed only on non-clipping frames (matched content, no clip inflation).
ydif_diff_sum  = 0.0
ydif_diff_sum2 = 0.0
n_ydif_noclip  = 0

# VREP coincidence: spike in both = tape damage; spike in one = VCR problem.
vrep_both   = 0
vrep_a_only = 0
vrep_b_only = 0

# Divergent-frame log lines (written to paired_frames.txt)
divergent = []

# ------------------------------------------------------------------
# Main lockstep loop
# ------------------------------------------------------------------
gen_a = parse_frames(LOG_A)
gen_b = parse_frames(LOG_B)

for fa, fb in zip(gen_a, gen_b):
    n_paired += 1

    yavg_a = fa.get("YAVG", 0.0)
    yavg_b = fb.get("YAVG", 0.0)
    diff   = yavg_a - yavg_b

    yavg_diff_sum  += diff
    yavg_diff_sum2 += diff * diff

    if   diff >  1.0: yavg_diff_pos += 1
    elif diff < -1.0: yavg_diff_neg += 1
    else:             yavg_diff_eq  += 1

    # Clipping coincidence
    clip_a = fa.get("YHIGH", 0.0) >= CLIP_YHIGH
    clip_b = fb.get("YHIGH", 0.0) >= CLIP_YHIGH
    if   clip_a and clip_b:  clip_both   += 1
    elif clip_a:             clip_a_only += 1
    elif clip_b:             clip_b_only += 1
    else:                    clip_none   += 1

    # Differential YDIF on non-clipping frames only
    if not clip_a and not clip_b:
        dd = fa.get("YDIF", 0.0) - fb.get("YDIF", 0.0)
        ydif_diff_sum  += dd
        ydif_diff_sum2 += dd * dd
        n_ydif_noclip  += 1

    # VREP coincidence
    vrep_a = fa.get("VREP", 0.0) >= VREP_T
    vrep_b = fb.get("VREP", 0.0) >= VREP_T
    if   vrep_a and vrep_b: vrep_both   += 1
    elif vrep_a:            vrep_a_only += 1
    elif vrep_b:            vrep_b_only += 1

    # Log frames where the captures diverge meaningfully
    if abs(diff) >= YAVG_DIFF_T:
        divergent.append(
            "frame=%-6d  YAVG_A=%-6.1f  YAVG_B=%-6.1f  diff=%-+6.1f"
            "  YHIGH_A=%-5.1f  YHIGH_B=%-5.1f  clip_A=%-3s  clip_B=%-3s"
            "  VREP_A=%-5.1f  VREP_B=%-5.1f" % (
                fa["framenum"],
                yavg_a, yavg_b, diff,
                fa.get("YHIGH", 0), fb.get("YHIGH", 0),
                "YES" if clip_a else "no", "YES" if clip_b else "no",
                fa.get("VREP", 0),  fb.get("VREP", 0),
            )
        )

# ------------------------------------------------------------------
# Derived statistics
# ------------------------------------------------------------------
if n_paired == 0:
    print("  [WARN] No paired frames found — logs may be empty or mismatched.")
    sys.exit(0)

yavg_mean_diff = yavg_diff_sum / n_paired
yavg_var_diff  = (yavg_diff_sum2 / n_paired) - (yavg_mean_diff ** 2)
yavg_sd_diff   = math.sqrt(max(yavg_var_diff, 0.0))

if n_ydif_noclip > 0:
    ydif_mean_diff = ydif_diff_sum / n_ydif_noclip
    ydif_var_diff  = (ydif_diff_sum2 / n_ydif_noclip) - (ydif_mean_diff ** 2)
    ydif_sd_diff   = math.sqrt(max(ydif_var_diff, 0.0))
else:
    ydif_mean_diff = ydif_sd_diff = 0.0

# A near-zero mean with low SD = paths are matched in brightness.
# A non-zero mean = one path is consistently brighter (AGC/level difference).
# A near-zero mean with high SD = paths diverge content-dependently (clipping).
if abs(yavg_mean_diff) < 1.0 and yavg_sd_diff < 2.0:
    brightness_interp = "paths well-matched; no systematic level difference"
elif abs(yavg_mean_diff) >= 2.0 and yavg_sd_diff < abs(yavg_mean_diff):
    which = "A" if yavg_mean_diff > 0 else "B"
    brightness_interp = ("capture %s is consistently brighter — "
                         "possible AGC or level difference") % which
else:
    which = "A" if yavg_mean_diff > 0 else "B"
    brightness_interp = ("divergence is content-correlated — "
                         "capture %s clips more on bright frames") % which

# ------------------------------------------------------------------
# Write paired_frames.txt
# ------------------------------------------------------------------
with open(PAIRED_OUT, "w") as fh:
    fh.write("Paired-frame divergence log\n")
    fh.write("Frames where |YAVG_A - YAVG_B| >= %d\n" % YAVG_DIFF_T)
    fh.write("Use these frame numbers with ffmpeg -vf select or a NLE to\n")
    fh.write("jump directly to the divergent content for visual QC.\n")
    fh.write("  ffmpeg -i FILE -vf \"select='eq(n\\,FRAMENUM)'\" -vsync 0 frame.png\n")
    fh.write("\n")
    fh.write("%-6s  %-8s  %-8s  %-7s  %-7s  %-7s  %-7s  %-7s  %-7s  %-7s\n" % (
        "frame", "YAVG_A", "YAVG_B", "diff",
        "YHIGH_A", "YHIGH_B", "clip_A", "clip_B", "VREP_A", "VREP_B"))
    fh.write("-" * 85 + "\n")
    for line in divergent:
        fh.write(line + "\n")
    fh.write("\n%d divergent frames out of %d paired frames (%.1f%%)\n" % (
        len(divergent), n_paired, 100.0 * len(divergent) / n_paired))

print("  %d divergent frames logged → %s" % (len(divergent), PAIRED_OUT))

# ------------------------------------------------------------------
# Append paired analysis section to report.txt
# ------------------------------------------------------------------
W42 = "%-42s"
def row(label, va, vb, better=""):
    print((W42 + " %8s %8s %6s") % (label, va, vb, better))

def pct(n, total):
    return ("%.1f%%" % (100.0 * n / total)) if total else "0.0%"

with open(REPORT, "a") as fh:
    import sys as _sys
    _sys.stdout = fh

    print("")
    print("========================================")
    print("  PAIRED-FRAME ANALYSIS")
    print("  (frame N in A matched to frame N in B)")
    print("========================================")
    print("")
    print("  Paired frames analysed : %d" % n_paired)
    print("  Divergence threshold   : |YAVG_A - YAVG_B| >= %d" % YAVG_DIFF_T)
    print("  Divergent frames logged: %d (%.1f%%)" % (
        len(divergent), 100.0 * len(divergent) / n_paired))
    print("")

    # --- YAVG difference ---
    print("YAVG Difference (A minus B, per paired frame)")
    print("  Mean ~0 + low SD  = paths match in brightness.")
    print("  Mean offset       = one VCR runs consistently brighter (AGC/level).")
    print("  Mean ~0 + high SD = content-correlated divergence (clipping on")
    print("  bright frames pulls one capture up while the other holds detail).")
    print("")
    print((W42 + " %8s") % ("Metric", "Value"))
    print((W42 + " %8s") % ("------", "-----"))
    print((W42 + " %8.3f") % ("  Mean YAVG diff (A-B)", yavg_mean_diff))
    print((W42 + " %8.3f") % ("  StdDev YAVG diff",     yavg_sd_diff))
    print((W42 + " %8d")   % ("  Frames A brighter (diff > +1)", yavg_diff_pos))
    print((W42 + " %8d")   % ("  Frames B brighter (diff < -1)", yavg_diff_neg))
    print((W42 + " %8d")   % ("  Frames matched   (|diff| <= 1)", yavg_diff_eq))
    print((W42 + " %8s")   % ("  Interpretation", ""))
    print("    %s" % brightness_interp)
    print("")

    # --- Clipping coincidence ---
    better_aonly = "B" if clip_a_only > clip_b_only else ("A" if clip_b_only > clip_a_only else "=")
    print("Clipping Coincidence (YHIGH >= %d)" % CLIP_YHIGH)
    print("  'Both clip'   = content is too bright for either VCR; unavoidable.")
    print("  'A-only clip' = A's signal path has less headroom than B.")
    print("  'B-only clip' = B's signal path has less headroom than A.")
    print("  Fewer A-only or B-only frames = that path handles highlights better.")
    print("")
    print((W42 + " %8s %8s") % ("Metric", "Frames", "Pct"))
    print((W42 + " %8s %8s") % ("------", "------", "---"))
    print((W42 + " %8d %8s") % ("  Both clip",   clip_both,   pct(clip_both,   n_paired)))
    print((W42 + " %8d %8s") % ("  A-only clip", clip_a_only, pct(clip_a_only, n_paired)))
    print((W42 + " %8d %8s") % ("  B-only clip", clip_b_only, pct(clip_b_only, n_paired)))
    print((W42 + " %8d %8s") % ("  Neither clip",clip_none,   pct(clip_none,   n_paired)))
    if clip_a_only != clip_b_only:
        worse  = "A" if clip_a_only > clip_b_only else "B"
        excess = abs(clip_a_only - clip_b_only)
        print("  → Capture %s clips alone on %d more frames — signal path headroom deficit." % (worse, excess))
    else:
        print("  → A-only and B-only counts equal — no clear headroom winner.")
    print("")

    # --- Differential YDIF ---
    print("Differential YDIF on non-clipping frames (A minus B)")
    print("  Both captures see the same scene motion so YDIF_A - YDIF_B")
    print("  cancels the motion component, leaving only the path noise")
    print("  difference.  Computed on %d non-clipping frames." % n_ydif_noclip)
    print("  Mean > 0 = A noisier; Mean < 0 = B noisier.")
    print("  SD measures consistency; high SD = noise is intermittent.")
    print("")
    print((W42 + " %8s") % ("Metric", "Value"))
    print((W42 + " %8s") % ("------", "-----"))
    print((W42 + " %8.3f") % ("  Mean diff-YDIF (A-B)", ydif_mean_diff))
    print((W42 + " %8.3f") % ("  StdDev diff-YDIF",     ydif_sd_diff))
    if n_ydif_noclip > 0:
        if abs(ydif_mean_diff) < 0.3:
            print("  → Noise floors are comparable on non-clipping frames.")
        else:
            noisier = "A" if ydif_mean_diff > 0 else "B"
            print("  → Capture %s has a higher noise floor on clean frames." % noisier)
    print("")

    # --- VREP coincidence ---
    print("VREP Coincidence (VREP >= %.0f%%)" % VREP_T)
    print("  VREP spikes in both captures on the same frame = tape damage")
    print("  at that point (both VCRs see the same problem).")
    print("  Spikes in only one capture = head clog or tracking problem")
    print("  on that specific VCR, not a tape quality issue.")
    print("")
    print((W42 + " %8s %8s") % ("Metric", "Frames", "Pct"))
    print((W42 + " %8s %8s") % ("------", "------", "---"))
    print((W42 + " %8d %8s") % ("  Both spike",   vrep_both,   pct(vrep_both,   n_paired)))
    print((W42 + " %8d %8s") % ("  A-only spike", vrep_a_only, pct(vrep_a_only, n_paired)))
    print((W42 + " %8d %8s") % ("  B-only spike", vrep_b_only, pct(vrep_b_only, n_paired)))
    if vrep_a_only > 5 or vrep_b_only > 5:
        worse = "A" if vrep_a_only > vrep_b_only else "B"
        print("  → Capture %s has more solo VREP spikes — check head/tracking." % worse)
    else:
        print("  → VREP spikes are shared or negligible — tape quality rather than VCR.")
    print("")
    print("  Divergent frame detail: %s" % PAIRED_OUT)
    print("========================================")

    _sys.stdout = _sys.__stdout__

PYEOF

# Report is printed once at the end of Step 7.  Do not cat here.
echo ""
echo "Full per-frame logs : $W/a_stats.log  $W/b_stats.log"
echo "Aligned logs        : $W/a_aligned.log  $W/b_aligned.log"
echo "Dropout detail      : $W/dropouts_a.txt  $W/dropouts_b.txt"
echo "Divergent frames    : $W/paired_frames.txt"
echo "Report              : $W/report.txt"

fi  # end two-file mode Step 6

# ------------------------------------------------------------------------------
# Step 7: Full pixel luma histogram  (--histogram only)
# ------------------------------------------------------------------------------
# Requires a second ffmpeg decode pass — see compute_histogram() helper above.
# Written to luma_hist_a.txt (and luma_hist_b.txt in two-file mode).
# ------------------------------------------------------------------------------

if [ "$RUN_HISTOGRAM" -eq 1 ]; then
    echo ""
    echo "[7/7] Computing luma pixel histogram..."

    # Check numpy is available before starting the expensive decode.
    if ! python3 -c "import numpy" 2>/dev/null; then
        confirm_continue "numpy not found — luma histogram requires it. Install with: sudo apt install python3-numpy. Use --no-histogram to skip the histogram and avoid this dependency."
        RUN_HISTOGRAM=0
    fi
fi

if [ "$RUN_HISTOGRAM" -eq 1 ]; then
    compute_histogram "$A" "$W/luma_hist_a.txt" "Capture A"
    if [ "$SINGLE_MODE" -eq 0 ]; then
        compute_histogram "$B" "$W/luma_hist_b.txt" "Capture B"
    fi

    # Append histogram to report for reference.
    {
        echo ""
        echo "========================================"
        echo "  LUMA PIXEL HISTOGRAM"
        echo "  (see luma_hist_a.txt / luma_hist_b.txt for full 0-255 range)"
        echo "========================================"
        echo ""
        echo "Bright-end distribution (Y=220-255):"
        echo ""
        printf "%-4s  %-17s  %-6s\n" "Y" "Count (A)" "Pct (A)"
        printf "%-4s  %-17s  %-6s\n" "---" "---------" "-------"
        awk 'NR>6 && $1+0 >= 220 {printf "%-4s  %-17s  %-6s\n", $1, $2, $3}' \
            "$W/luma_hist_a.txt"
        if [ "$SINGLE_MODE" -eq 0 ] && [ -f "$W/luma_hist_b.txt" ]; then
            echo ""
            printf "%-4s  %-17s  %-6s\n" "Y" "Count (B)" "Pct (B)"
            printf "%-4s  %-17s  %-6s\n" "---" "---------" "-------"
            awk 'NR>6 && $1+0 >= 220 {printf "%-4s  %-17s  %-6s\n", $1, $2, $3}' \
                "$W/luma_hist_b.txt"
        fi
    } >> "$W/report.txt"
else
    echo ""
    echo "Tip: re-run with --no-histogram to skip the pixel luma distribution"
    echo "     if you only need the signalstats metrics."
fi

# Print the complete report (with histogram appended if requested) exactly once.
cat "$W/report.txt"

echo ""
if [ "$SINGLE_MODE" -eq 1 ]; then
    echo "Per-frame log : $W/a_stats.log"
    echo "Dropout detail: $W/dropouts_a.txt"
    echo "Report        : $W/report.txt"
    [ "$RUN_HISTOGRAM" -eq 1 ] && echo "Luma histogram: $W/luma_hist_a.txt"
else
    echo "Full per-frame logs : $W/a_stats.log  $W/b_stats.log"
    echo "Aligned logs        : $W/a_aligned.log  $W/b_aligned.log"
    echo "Dropout detail      : $W/dropouts_a.txt  $W/dropouts_b.txt"
    echo "Divergent frames    : $W/paired_frames.txt"
    echo "Report              : $W/report.txt"
    if [ "$RUN_HISTOGRAM" -eq 1 ]; then
        echo "Luma histograms     : $W/luma_hist_a.txt  $W/luma_hist_b.txt"
    fi
fi
echo ""
echo "Done."
