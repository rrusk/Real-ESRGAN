#!/usr/bin/env python3
"""
detect_dropouts.py - Detect dropout events in DV and MKV video files using
                     per-frame signalstats metrics (YAVG and YDIF).

Supports both raw DV captures (.dv) and upscaled MKV files from the
Real-ESRGAN pipeline (enhanced/ subdirectory).  Frame rate is probed
automatically via ffprobe, so 29.97 fps DV and 60 fps MKV files are both
handled correctly.  ESRGAN upscaling tends to amplify glitches, making
them easier to spot in the enhanced files.

Enhanced MKV files are de-interlaced to ~59.94 fps by field separation
(each interlaced field becomes one progressive frame).  Consecutive frames
are therefore field-pairs from the same original interlaced frame and are
nearly identical, so natural-motion YDIF values are roughly half those seen
at 29.97 fps.  Scale the YDIF threshold accordingly:

    DV source (29.97 fps):          --ydif-threshold 40  (default)
    Enhanced MKV (59.94 fps):       --ydif-threshold 20

YAVG blank/flash thresholds are unaffected by frame rate or ESRGAN
processing and need no adjustment.  RIFE-interpolated MKV files (a small
subset, each superseded by a non-RIFE re-encode) have synthesised
inter-frame motion and are not the intended target for this script.

Two complementary detection modes run in a single ffmpeg pass:

  YAVG mode — detects multi-frame signal loss events:
    Flash frames:  YAVG > flash_threshold  (FM carrier overload)
    Blank frames:  YAVG < blank_threshold  (TRV330 blue mute / signal loss)
    Event types:
      flash+blank — flash followed by sub-threshold blank (classic dropout)
      blank       — sub-threshold blank without a preceding flash
    Flash-only events (no blank) are suppressed as scene content.
    Sustained bright content (sky, beach) is suppressed via max_flash_frames.

  YDIF mode — detects single-frame glitches and multi-frame corruption:
    YDIF measures mean absolute luma difference between adjacent frames.

    Spike (single corrupt frame): produces exactly TWO consecutive high-YDIF
      frames. A scene cut produces only ONE, suppressing false positives.

    Corrupt (multi-frame DV error concealment): a run of 4+ consecutive
      high-YDIF frames. DV codec error concealment produces visually obvious
      corruption (pixel blocks, colour streaking, noise) whose mean luma
      (YAVG) stays in the normal scene range, making it invisible to the
      YAVG detector. The sustained YDIF run identifies these events. A run is
      only reported if it passes a peak-YDIF (>=60) or YAVG-stdev (>=10)
      guard, which suppresses moderate sustained motion (e.g. a pan) that
      clears the threshold but is not corruption.

  Row-band mode (opt-in via --rows N; OFF by default) — spatially-local
    defects: frame-mean metrics average away a horizontal dropout streak
    occupying part of the frame height (classic Hi8 head-clog/oxide defect).
    This mode slices each frame into N bands and flags a frame where one
    band's YDIF greatly exceeds the others (global motion suppressed; local
    dropout detected). Adds a separate decode pass. NOTE: row-band thresholds
    are not yet calibrated against a confirmed subtle defect; use --row-dump
    to inspect raw per-band values when calibrating.

Threshold rationale (calibrated against TRV330 Hi8 captures at 29.97 fps):
    Flash threshold (140): FM carrier overload — analog signal briefly
        exceeds normal luma range before collapsing. Normal content < 130.
    Blank threshold (50):  TRV330 blue mute frames have YAVG~81. Genuine
        signal loss dips well below 81. Dark scenes stay 60-70 and are
        excluded. 50 cleanly separates signal loss from dark content.
    YDIF spike threshold (40): Normal motion produces YDIF 5-15. Single-
        frame glitches produce YDIF 40-50 on both the arrival and return
        frames. 40 gives good margin above normal content while staying
        below typical glitch values of 46+.
    YDIF run min frames (4): A sustained run of this many or more consecutive
        high-YDIF frames is reported as a "corrupt" event (DV error
        concealment).  Must be > 2 to avoid overlap with spike detection.
        At 29.97fps, 4 frames = ~0.13s.  Adjustable via --ydif-run-min-frames.
    YDIF at 59.94 fps (20): De-interlaced field-pairs are nearly identical,
        so natural-motion YDIF is ~half the 29.97 fps value.  Glitch YDIF
        scales proportionally: 40 × (29.97 / 59.94) ≈ 20.  Use
        --ydif-threshold 20 when scanning enhanced MKV files.

Cluster-aware view script generation:
    When many events fall close together (e.g. a section of badly degraded
    tape producing dozens of short blank events), generating one 20-second
    clip per event results in heavily overlapping, redundant playback.
    Instead, events within --cluster-window seconds of each other are
    grouped into a single viewing clip that spans all of them, with
    --view-lead-in seconds of context before the first event and
    --view-lead-out seconds after the last.  Isolated events get their
    own clip as before (centred on the mid-point of the event).

Usage:
    detect_dropouts.py [options] <input.dv|input.mkv>

    DV source:      detect_dropouts.py input.dv
    Enhanced MKV:   detect_dropouts.py --ydif-threshold 20 input.mkv

Options:
    -f, --flash-threshold FLOAT   YAVG flash threshold (default: 140)
    -b, --blank-threshold FLOAT   YAVG blank threshold (default: 50)
    -m, --min-event-frames INT    Min consecutive anomalous frames for
                                  YAVG events (default: 3)
    -g, --merge-gap INT           Merge YAVG events separated by <= this
                                  many frames (default: 5)
    --max-flash-frames INT        Max frames above flash_threshold in a YAVG
                                  event before the flash component is ignored
                                  and the event is reclassified as blank.
                                  Prevents sustained bright content (sunny
                                  beach, sky) from being labelled flash+blank.
                                  (default: 10, ~0.33s at 29.97fps)
    --flash-drop-margin FLOAT     For flash events without a sub-threshold
                                  blank, the post-flash mean YAVG must be at
                                  least this many units below the pre-flash
                                  mean YAVG to be reported as a dropout.
                                  Suppresses scene lighting flashes that
                                  return to the pre-flash level. (default: 10)
    -y, --ydif-threshold FLOAT    YDIF spike threshold (default: 40)
    --ydif-run-peak-min FLOAT     Corrupt-run guard: min peak YDIF in the run
                                  (suppresses motion FPs) (default: 60)
    --ydif-run-yavg-stdev-min FLOAT
                                  Corrupt-run guard: min YAVG stdev in the run
                                  (default: 10)
    --rows INT                    Enable row-band spatial detector with this
                                  many bands (0 = off; OFF by default). Adds a
                                  decode pass. Thresholds uncalibrated. (default: 0)
    --row-crop-bottom INT         Lines excluded from frame bottom before
                                  banding (head-switch noise) (default: 8)
    --row-ratio FLOAT             Hot band YDIF >= this x median of others (default: 3.0)
    --row-floor FLOAT             Hot band YDIF must be at least this (default: 30)
    --row-min-frames INT          Min consecutive flagged frames (default: 1)
    --row-dump                    Diagnostic: print per-frame per-band YDIF
                                  table and exit (for calibration)
    --no-ydif                     Disable YDIF spike detection
    --no-yavg                     Disable YAVG blank/flash detection
    -s, --start-time STR          Seek to timestamp (e.g. 00:00:00)
    -d, --duration STR            Duration to scan (e.g. 00:45:00)
    -e, --end-time STR            Scan until timestamp (e.g. 00:45:00);
                                  mutually exclusive with --duration
    -v, --verbose                 Print per-frame values for each event
    --no-view-script              Suppress view script generation
    --view-script-dir DIR         Directory for view script (default: input file dir)
    --view-dropout-script PATH    Path to view_dropout.sh (default: same dir as script)
    --cluster-window FLOAT        Cluster events within this many seconds into
                                  a single viewing clip (default: 30.0)
    --view-lead-in FLOAT          Seconds of context before first event in a clip
                                  (default: 10.0)
    --view-lead-out FLOAT         Seconds of context after last event in a clip
                                  (default: 10.0)

Output files (written alongside input file by default):
    <stem>_view_events.sh  — executable shell script with one view_dropout.sh
                             call per event or cluster, each annotated with
                             event type and what to look for.  Run it to step
                             through all events sequentially; quit each clip
                             with q to advance.
"""

import argparse
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import re


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
FLASH_THRESHOLD_DEFAULT = 140.0
BLANK_THRESHOLD_DEFAULT = 50.0
MIN_EVENT_FRAMES_DEFAULT = 3
MERGE_GAP_DEFAULT = 5
YDIF_THRESHOLD_DEFAULT = 40.0
YAVG_DEV_MIN_DEFAULT = 20.0  # min YAVG deviation from neighbours for a spike

# A genuine FM carrier flash lasts at most a few frames before signal
# collapse.  More than this many consecutive above-threshold frames means
# sustained bright content (sky, beach), not a flash.  At 29.97fps, 10
# frames = ~0.33s; at 59.94fps scale proportionally if needed.
MAX_FLASH_FRAMES_DEFAULT = 10

# Sustained-YDIF corruption detector: a run of consecutive frames all with
# YDIF >= ydif_threshold, longer than the single-frame spike (which requires
# exactly 2 high-YDIF frames).  DV codec error concealment produces multi-
# frame corruption visible as pixel blocks/noise that the YAVG detector
# misses because the mean luma stays in the normal range.
# Minimum run length to distinguish from spike events and camera motion bursts.
YDIF_RUN_MIN_FRAMES_DEFAULT = 4
# A camera pan or fast motion can sustain YDIF just above the threshold with
# stable YAVG. Two guards distinguish genuine corruption from motion; either
# passing is sufficient to report the event:
#   Peak YDIF: genuine corruption drives YDIF well above threshold; camera
#              motion at 29.97fps rarely exceeds 60 (observed motion FP peaked
#              at 49.5; real corruption peaked at 87.7).
#   YAVG stdev: corruption causes erratic luma swings (e.g. alternating
#              interlaced fields, stdev ~29); smooth motion keeps YAVG stable
#              (stdev ~1.5).
YDIF_RUN_PEAK_MIN_DEFAULT = 60.0        # min peak YDIF within the run
YDIF_RUN_YAVG_STDEV_MIN_DEFAULT = 10.0  # min YAVG stdev within the run

# Row-band spatial detector (opt-in via --rows; OFF by default).  Every
# signalstats metric is a whole-frame reduction, so a spatially-local defect
# -- the classic Hi8 horizontal dropout streak occupying a fraction of the
# frame height -- is averaged away and invisible to the frame-mean detectors.
# The row-band detector slices each frame into N horizontal bands, measures
# YDIF per band, and flags a frame where ONE band's YDIF greatly exceeds the
# others in the same frame.  The discriminator keys on the RATIO of the
# hottest band to the median of the others (spatial locality) plus an absolute
# floor: camera motion raises all bands together (hot band not an outlier),
# whereas a horizontal dropout raises one band alone.
#
# NOTE: as of this version the row-band thresholds are NOT calibrated against
# a confirmed subtle horizontal-band defect; the defaults below are physics-
# based estimates.  The detector is parked (off by default) until a confirmed
# defect is available to calibrate against.  Use --row-dump to inspect raw
# per-band values when calibrating.
ROW_BANDS_DEFAULT = 0           # 0 = row-band detector disabled
ROW_CROP_BOTTOM_DEFAULT = 8     # exclude bottom N lines (head-switching noise)
ROW_RATIO_DEFAULT = 3.0         # hot band YDIF >= this x median of other bands
ROW_FLOOR_DEFAULT = 30.0        # and hot band YDIF must be at least this
ROW_MIN_FRAMES_DEFAULT = 1      # min consecutive flagged frames to report

# Fallback FPS used only if ffprobe fails; overridden per-file by probe_fps().
FPS_FALLBACK = 29.97

# View-script clustering / clip defaults
CLUSTER_WINDOW_DEFAULT = 30.0   # seconds: events closer than this are grouped
VIEW_LEAD_IN_DEFAULT = 10.0     # seconds of context before first event in clip
VIEW_LEAD_OUT_DEFAULT = 10.0    # seconds of context after last event in clip


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def parse_seek_seconds(s: str) -> float:
    """Parse HH:MM:SS, MM:SS, or plain seconds string to float seconds."""
    parts = s.split(":")
    if len(parts) == 3:
        return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
    elif len(parts) == 2:
        return int(parts[0]) * 60 + float(parts[1])
    return float(s)


def probe_fps(input_file: str) -> float:
    """
    Probe the frame rate of input_file via ffprobe.

    Parses the avg_frame_rate fraction (e.g. "60000/1001" → 59.94,
    "30000/1001" → 29.97) from the first video stream.  Falls back to
    FPS_FALLBACK if ffprobe is unavailable or the stream has no fps.
    """
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=avg_frame_rate",
        "-of", "default=noprint_wrappers=1:nokey=1",
        input_file,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        raw = result.stdout.strip()
        if "/" in raw:
            num, den = raw.split("/")
            if int(den) != 0:
                return float(num) / float(den)
        elif raw:
            return float(raw)
    except Exception:
        pass
    print(f"WARNING: could not probe FPS from {input_file}; "
          f"using fallback {FPS_FALLBACK}", file=sys.stderr)
    return FPS_FALLBACK


def abs_timestamp(seek_offset: float, frame_index: int, fps: float) -> str:
    """Return HH:MM:SS.mmm absolute timestamp for a frame at the given fps."""
    total_seconds = seek_offset + frame_index / fps
    h = int(total_seconds // 3600)
    m = int((total_seconds % 3600) // 60)
    s = total_seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------
def run_signalstats(input_file: str,
                    start_time: str | None,
                    duration: str | None,
                    fps: float,
                    seek_offset: float = 0.0,
                    progress_interval: int = 1800) -> tuple[list[float], list[float]]:
    """
    Run ffmpeg signalstats on input_file in a single pass.

    Returns (yavg_values, ydif_values) as parallel lists indexed by frame.

    signalstats emits YAVG and YDIF (and others) for each frame via
    metadata=print:file=-.  Both metrics are collected from the same stream
    so there is no extra decode cost for the dual-mode detection.

    YDIF for the first frame is always 0 (no previous frame to compare).

    Progress is printed to stderr every progress_interval frames.
    """
    cmd = ["ffmpeg"]
    if start_time:
        cmd += ["-ss", start_time]
    cmd += ["-i", input_file]
    if duration:
        cmd += ["-t", duration]
    cmd += [
        "-vf", "signalstats,metadata=print:file=-",
        "-f", "null", "-"
    ]

    yavg_values: list[float] = []
    ydif_values: list[float] = []
    # Per-frame accumulator: signalstats emits multiple metadata lines per
    # frame; we collect YAVG and YDIF then append when we see the next frame
    # boundary (a new "frame:" line in stderr, or end of stream).
    # Since metadata goes to stdout and ffmpeg progress to stderr, and we
    # discard stderr, we detect frame boundaries by tracking when YAVG
    # appears (one per frame) and using it as the synchronisation point.
    # YDIF appears on a separate line within the same frame block.
    pending_yavg: float | None = None
    pending_ydif: float | None = None
    last_progress = 0

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True)
    try:
        for line in proc.stdout:
            m_yavg = re.search(r"lavfi\.signalstats\.YAVG=([0-9.]+)", line)
            m_ydif = re.search(r"lavfi\.signalstats\.YDIF=([0-9.]+)", line)

            if m_yavg:
                # Flush any previously accumulated frame
                if pending_yavg is not None:
                    yavg_values.append(pending_yavg)
                    # YDIF may be missing for the very first frame
                    ydif_values.append(pending_ydif if pending_ydif is not None else 0.0)
                pending_yavg = float(m_yavg.group(1))
                pending_ydif = None  # reset; YDIF line follows

            elif m_ydif:
                pending_ydif = float(m_ydif.group(1))

            # Progress reporting keyed on frame count
            frame_count = len(yavg_values)
            if frame_count - last_progress >= progress_interval:
                abs_sec = seek_offset + frame_count / fps
                h = int(abs_sec // 3600)
                mn = int((abs_sec % 3600) // 60)
                s = abs_sec % 60
                print(f"  [{frame_count:6d} frames]  position ~{h:02d}:{mn:02d}:{s:04.1f}",
                      file=sys.stderr)
                last_progress = frame_count

        # Flush final frame
        if pending_yavg is not None:
            yavg_values.append(pending_yavg)
            ydif_values.append(pending_ydif if pending_ydif is not None else 0.0)

    finally:
        proc.stdout.close()
        proc.wait()

    return yavg_values, ydif_values


# ---------------------------------------------------------------------------
# YAVG event detection
# ---------------------------------------------------------------------------
def detect_yavg_events(yavg: list[float],
                       flash_threshold: float,
                       blank_threshold: float,
                       min_event_frames: int,
                       merge_gap: int,
                       max_flash_frames: int) -> list[dict]:
    """
    Detect multi-frame blank/flash dropout events from YAVG data.

    Two event types are reported:
      flash+blank — flash (within max_flash_frames) accompanied by at least
                    one frame below blank_threshold; classic TRV330 dropout.
      blank       — sub-threshold blank with no flash component.

    Suppressed (not reported):
      - Flash-only events (no blank): sustained bright content (sky, beach)
        or scene lighting flashes that produce no signal collapse.
      Note: events with a genuine blank (YAVG < blank_threshold) are always
      reported regardless of flash_frame_count.
    """
    n = len(yavg)

    # Mark anomalous frames
    anomalous = [
        1 if (y > flash_threshold or y < blank_threshold) else 0
        for y in yavg
    ]

    # Merge short gaps between anomalous runs
    i = 0
    while i < n:
        if anomalous[i] == 1:
            j = i
            while j < n and anomalous[j] == 1:
                j += 1
            gap_start = j
            gap_end = j
            while gap_end < n and anomalous[gap_end] == 0:
                gap_end += 1
            if gap_end < n and (gap_end - gap_start) <= merge_gap:
                for k in range(gap_start, gap_end):
                    anomalous[k] = 1
            i = j
        else:
            i += 1

    # Collect runs into events
    events = []
    i = 0
    while i < n:
        if anomalous[i] == 1:
            start = i
            while i < n and anomalous[i] == 1:
                i += 1
            end = i - 1
            frame_count = end - start + 1
            if frame_count >= min_event_frames:
                window = yavg[start:end + 1]
                flash_frame_count = sum(1 for y in window if y > flash_threshold)
                has_blank = any(y < blank_threshold for y in window)

                if has_blank:
                    # Classic dropout: sub-threshold blank is present.
                    # Always report regardless of flash_frame_count — a genuine
                    # blank (MinY < blank_threshold) confirms signal loss even
                    # when the flash component is long.
                    etype = "flash+blank" if flash_frame_count > 0 else "blank"
                    events.append({
                        "start_frame": start,
                        "end_frame": end,
                        "frame_count": frame_count,
                        "peak_value": max(window),
                        "min_value": min(window),
                        "type": etype,
                        "metric": "YAVG",
                    })
                elif flash_frame_count > max_flash_frames:
                    # No blank and sustained bright content (sky, beach,
                    # tape-end signal): suppress.
                    pass

        else:
            i += 1

    return events


# ---------------------------------------------------------------------------
# YDIF spike detection
# ---------------------------------------------------------------------------
def detect_ydif_spikes(ydif: list[float],
                       yavg: list[float],
                       ydif_threshold: float,
                       yavg_dev_min: float) -> list[dict]:
    """
    Detect single-frame glitches from YDIF data.

    A single-frame glitch produces two consecutive high-YDIF frames:
      frame N:   high YDIF — bad frame differs from the previous good frame
      frame N+1: high YDIF — return to normal differs from the bad frame

    A scene cut produces only one high-YDIF frame, so requiring two
    consecutive spikes suppresses cuts without requiring YMIN/YMAX checks.

    The reported frame is N (the bad frame itself), between the two spikes.
    """
    n = len(ydif)
    events = []

    i = 1  # YDIF[0] is always 0 (no previous frame)
    while i < n - 1:
        if ydif[i] >= ydif_threshold and ydif[i + 1] >= ydif_threshold:
            # Frame i is the bad frame: ydif[i] = diff(frame[i-1], frame[i])
            # ydif[i+1] = diff(frame[i], frame[i+1]) — return to normal
            # Require frame i+2 is below threshold -- exactly two consecutive
            # high-YDIF frames means a single-frame glitch; three or more means
            # camera motion or a scene transition, which we suppress.
            if i + 2 < n and ydif[i + 2] < ydif_threshold:
                # Also require a significant YAVG deviation from neighbours.
                # Camera motion has high YDIF but YAVG stays within the
                # normal scene range. A genuine glitch causes an abrupt
                # luma excursion visible as a large deviation from neighbours.
                prev_yavg = yavg[i - 1] if i > 0 else yavg[i + 1]
                next_yavg = yavg[i + 1]
                neighbour_avg = (prev_yavg + next_yavg) / 2.0
                yavg_deviation = abs(yavg[i] - neighbour_avg)
                if yavg_deviation >= yavg_dev_min:
                    events.append({
                        "start_frame": i,
                        "end_frame": i,
                        "frame_count": 1,
                        "peak_value": yavg[i],
                        "min_value": yavg[i],
                        "peak_ydif": max(ydif[i], ydif[i + 1]),
                        "yavg_dev": yavg_deviation,
                        "type": "spike",
                        "metric": "YDIF",
                    })
            i += 2  # skip past the return frame regardless
        else:
            i += 1

    return events




# ---------------------------------------------------------------------------
# Sustained-YDIF corruption detection
# ---------------------------------------------------------------------------
def detect_ydif_runs(ydif: list[float],
                     yavg: list[float],
                     ydif_threshold: float,
                     min_run_frames: int,
                     peak_ydif_min: float,
                     yavg_stdev_min: float) -> list[dict]:
    """
    Detect multi-frame corruption events from sustained high-YDIF runs.

    DV codec error concealment can produce several consecutive corrupt frames
    that are visually obvious (pixel blocks, colour streaking, noise) but
    whose mean luma (YAVG) stays in the normal scene range, making them
    invisible to the YAVG detector.  These events produce a sustained run of
    high YDIF values rather than the isolated two-frame signature of a
    single-frame spike.

    A run of min_run_frames or more consecutive frames all with
    YDIF >= ydif_threshold is reported as a "corrupt" event.  The minimum
    run length must be > 2 to avoid overlap with the spike detector (which
    requires exactly 2 consecutive high-YDIF frames); the default of 4
    frames gives reliable separation from spike events and camera motion
    bursts at 29.97fps.

    A run is only reported if it passes at least one of two guards that
    distinguish genuine corruption from camera motion (which can also sustain
    YDIF just above threshold):
      Peak YDIF guard:  max YDIF in the run >= peak_ydif_min.
      YAVG stdev guard: stdev of YAVG within the run >= yavg_stdev_min.
    This suppresses smooth/moderate motion (e.g. a pan) whose per-frame YDIF
    clears the threshold but whose peak stays modest and whose luma is stable.

    Peak and mean YDIF are recorded for reference.  The reported start_frame
    is the first high-YDIF frame (i.e. the frame whose YDIF[i] measures the
    difference from the preceding frame — the preceding frame is still good).
    """
    n = len(ydif)
    events = []
    i = 1  # YDIF[0] is always 0

    while i < n:
        if ydif[i] >= ydif_threshold:
            # Walk forward to find the end of the run
            j = i
            while j < n and ydif[j] >= ydif_threshold:
                j += 1
            run_len = j - i
            if run_len >= min_run_frames:
                window_ydif = ydif[i:j]
                window_yavg = yavg[i:j]
                peak_ydif = max(window_ydif)
                mean_yavg = sum(window_yavg) / run_len
                yavg_stdev = (
                    sum((y - mean_yavg) ** 2 for y in window_yavg) / run_len
                ) ** 0.5
                # Require at least one guard to pass to suppress motion FP
                if peak_ydif >= peak_ydif_min or yavg_stdev >= yavg_stdev_min:
                    events.append({
                        "start_frame": i,
                        "end_frame": j - 1,
                        "frame_count": run_len,
                        "peak_value": max(window_yavg),
                        "min_value": min(window_yavg),
                        "peak_ydif": peak_ydif,
                        "mean_ydif": sum(window_ydif) / run_len,
                        "type": "corrupt",
                        "metric": "YDIF",
                    })
            i = j  # skip past the run
        else:
            i += 1

    return events

# ---------------------------------------------------------------------------
# Row-band spatial detection (opt-in via --rows)
# ---------------------------------------------------------------------------
def probe_dimensions(input_file: str) -> tuple[int, int]:
    """
    Probe pixel (width, height) of the first video stream via ffprobe.
    Falls back to NTSC-DV 720x480 if the probe fails.
    """
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height",
        "-of", "csv=s=x:p=0",
        input_file,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        raw = result.stdout.strip()
        if "x" in raw:
            w, h = raw.split("x")
            return int(w), int(h)
    except Exception:
        pass
    print(f"WARNING: could not probe dimensions from {input_file}; "
          f"using fallback 720x480", file=sys.stderr)
    return 720, 480


def run_signalstats_bands(input_file: str,
                          start_time: str | None,
                          duration: str | None,
                          width: int,
                          band_height: int,
                          n_bands: int,
                          fps: float = 29.97,
                          seek_offset: float = 0.0,
                          progress_interval: int = 1800) -> list[list[float]]:
    """
    Run signalstats on N horizontal bands of the frame in a single decode.

    The input is decoded once and split into n_bands branches; each branch is
    cropped to one horizontal band and run through signalstats, writing its
    per-frame metadata to a separate temp file.  This costs one decode plus
    N cheap filter chains, rather than N full decodes.

    Progress is streamed via ffmpeg -progress (frame=N lines) so the pass is
    not silent on long scans.

    Returns a list of n_bands lists, each the per-frame YDIF series for that
    band (index 0 = topmost band).  Series are truncated to the shortest
    length so they are index-aligned by frame.
    """
    tmp_files = [tempfile.mktemp(suffix=f"_band{b}.txt") for b in range(n_bands)]

    # Build the split + per-band crop/signalstats filtergraph.
    labels = "".join(f"[b{b}]" for b in range(n_bands))
    parts = [f"[0:v]split={n_bands}{labels}"]
    for b in range(n_bands):
        y = b * band_height
        parts.append(
            f"[b{b}]crop={width}:{band_height}:0:{y},"
            f"signalstats,metadata=print:file={tmp_files[b]}[o{b}]"
        )
    filtergraph = ";".join(parts)

    cmd = ["ffmpeg", "-v", "error"]
    if start_time:
        cmd += ["-ss", start_time]
    cmd += ["-i", input_file]
    if duration:
        cmd += ["-t", duration]
    cmd += ["-filter_complex", filtergraph]
    for b in range(n_bands):
        cmd += ["-map", f"[o{b}]"]
    # -progress pipe:1 streams machine-readable key=value lines (incl. frame=N)
    # so we can report progress during this otherwise-silent pass.
    cmd += ["-progress", "pipe:1", "-f", "null", "-"]

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    last_progress = 0
    try:
        for line in proc.stdout:
            m = re.match(r"frame=(\d+)", line.strip())
            if m:
                frame_count = int(m.group(1))
                if frame_count - last_progress >= progress_interval:
                    abs_sec = seek_offset + frame_count / fps
                    h = int(abs_sec // 3600)
                    mn = int((abs_sec % 3600) // 60)
                    s = abs_sec % 60
                    print(f"  [{frame_count:6d} frames]  "
                          f"position ~{h:02d}:{mn:02d}:{s:04.1f}",
                          file=sys.stderr)
                    last_progress = frame_count
    finally:
        proc.stdout.close()
        stderr_text = proc.stderr.read()
        proc.stderr.close()
        proc.wait()

    if proc.returncode != 0:
        print(f"ERROR: row-band signalstats pass failed:\n{stderr_text}",
              file=sys.stderr)
        for fpath in tmp_files:
            if os.path.exists(fpath):
                os.remove(fpath)
        return []

    bands_ydif: list[list[float]] = []
    for fpath in tmp_files:
        ydif_series: list[float] = []
        try:
            with open(fpath) as fh:
                pending = None
                for line in fh:
                    m_yavg = re.search(r"signalstats\.YAVG=([0-9.]+)", line)
                    m_ydif = re.search(r"signalstats\.YDIF=([0-9.]+)", line)
                    if m_yavg:
                        if pending is not None:
                            ydif_series.append(pending)
                        pending = 0.0  # default if no YDIF line this frame
                    elif m_ydif:
                        pending = float(m_ydif.group(1))
                if pending is not None:
                    ydif_series.append(pending)
        finally:
            if os.path.exists(fpath):
                os.remove(fpath)
        bands_ydif.append(ydif_series)

    if bands_ydif:
        min_len = min(len(s) for s in bands_ydif)
        bands_ydif = [s[:min_len] for s in bands_ydif]
    return bands_ydif


def detect_row_band_events(bands_ydif: list[list[float]],
                           ratio: float,
                           floor: float,
                           min_frames: int) -> list[dict]:
    """
    Detect spatially-local horizontal-band defects from per-band YDIF series.

    For each frame, the band with the highest YDIF (the "hot" band) is
    compared against the median YDIF of the remaining bands in the SAME frame.
    A frame is flagged when:

        hot_ydif >= floor                       (ignore quiet scenes)
        AND hot_ydif >= ratio * median_others   (spatially local, not global)

    Camera motion raises all bands together, so median_others rises with the
    hot band and the ratio test fails.  A horizontal dropout raises one band
    alone, so the ratio test passes.

    Consecutive flagged frames are merged into one event; runs of at least
    min_frames are reported with type "band".  The 0-based hot-band index and
    the frame-height fraction it spans are recorded so the reviewer knows
    roughly where on screen to look.
    """
    if not bands_ydif:
        return []
    n_bands = len(bands_ydif)
    n_frames = len(bands_ydif[0])
    if n_bands < 2:
        return []  # need at least 2 bands to compare

    def median(vals: list[float]) -> float:
        s = sorted(vals)
        m = len(s)
        if m == 0:
            return 0.0
        return s[m // 2] if m % 2 else (s[m // 2 - 1] + s[m // 2]) / 2.0

    flagged = [False] * n_frames
    hot_band = [-1] * n_frames
    hot_val = [0.0] * n_frames
    for f in range(1, n_frames):  # frame 0 YDIF is 0
        col = [bands_ydif[b][f] for b in range(n_bands)]
        hb = max(range(n_bands), key=lambda b: col[b])
        others = [col[b] for b in range(n_bands) if b != hb]
        med = median(others)
        if col[hb] >= floor and col[hb] >= ratio * max(med, 1e-6):
            flagged[f] = True
            hot_band[f] = hb
            hot_val[f] = col[hb]

    events = []
    f = 0
    while f < n_frames:
        if flagged[f]:
            start = f
            while f < n_frames and flagged[f]:
                f += 1
            end = f - 1
            run_len = end - start + 1
            if run_len >= min_frames:
                run_hot = [hot_band[k] for k in range(start, end + 1)]
                dominant = max(set(run_hot), key=run_hot.count)
                peak = max(hot_val[k] for k in range(start, end + 1))
                frac_lo = dominant / n_bands
                frac_hi = (dominant + 1) / n_bands
                events.append({
                    "start_frame": start,
                    "end_frame": end,
                    "frame_count": run_len,
                    "peak_value": peak,
                    "min_value": peak,
                    "peak_ydif": peak,
                    "hot_band": dominant,
                    "n_bands": n_bands,
                    "band_frac": (frac_lo, frac_hi),
                    "type": "band",
                    "metric": "ROWYDIF",
                })
        else:
            f += 1

    return events


# ---------------------------------------------------------------------------
# View-script cluster grouping
# ---------------------------------------------------------------------------
def cluster_events_for_viewing(
        events: list[dict],
        seek_offset: float,
        fps: float,
        cluster_window: float,
        lead_in: float,
        lead_out: float,
) -> list[dict]:
    """
    Group nearby events into viewing clips to avoid redundant overlapping
    playback when many events cluster on a section of degraded tape.

    Events whose start times are within cluster_window seconds of the
    previous event's end time are merged into a single clip.  The clip
    starts lead_in seconds before the first event and ends lead_out seconds
    after the last event.

    Returns a list of clip descriptors, each containing:
        seek_ts   : HH:MM:SS seek timestamp for view_dropout.sh
        duration  : clip duration in seconds (float)
        mid_ts    : HH:MM:SS timestamp of the cluster mid-point (for
                    orientation while stepping frame-by-frame)
        event_count: number of constituent events
        summary   : one-line human-readable description
        events    : list of the constituent event dicts
    """
    if not events:
        return []

    clips = []
    cluster_events = [events[0]]

    for ev in events[1:]:
        # Time of previous cluster's last event end
        prev_end_frame = cluster_events[-1]["end_frame"]
        prev_end_sec = seek_offset + prev_end_frame / fps
        cur_start_sec = seek_offset + ev["start_frame"] / fps

        if cur_start_sec - prev_end_sec <= cluster_window:
            # Within window: extend current cluster
            cluster_events.append(ev)
        else:
            # Gap too large: finalise current cluster and start a new one
            clips.append(_make_clip(cluster_events, seek_offset, fps,
                                    lead_in, lead_out))
            cluster_events = [ev]

    # Finalise last cluster
    clips.append(_make_clip(cluster_events, seek_offset, fps, lead_in, lead_out))
    return clips


def _make_clip(cluster: list[dict],
               seek_offset: float,
               fps: float,
               lead_in: float,
               lead_out: float) -> dict:
    """
    Build a single viewing-clip descriptor from a cluster of events.

    The seek point is clamped to 0 so we never seek before file start.
    """
    first_start_sec = seek_offset + cluster[0]["start_frame"] / fps
    last_end_sec = seek_offset + cluster[-1]["end_frame"] / fps

    clip_start = max(0.0, first_start_sec - lead_in)
    clip_end = last_end_sec + lead_out
    duration = clip_end - clip_start

    # Mid-point of the entire cluster span (useful for frame-stepping)
    mid_sec = (first_start_sec + last_end_sec) / 2.0
    mid_h = int(mid_sec // 3600)
    mid_m = int((mid_sec % 3600) // 60)
    mid_s = mid_sec % 60
    mid_ts = f"{mid_h:02d}:{mid_m:02d}:{mid_s:06.3f}"

    # Seek timestamp as HH:MM:SS (no ms) for view_dropout.sh
    seek_h = int(clip_start // 3600)
    seek_m = int((clip_start % 3600) // 60)
    seek_s = int(clip_start % 60)
    seek_ts = f"{seek_h:02d}:{seek_m:02d}:{seek_s:02d}"

    # Summarise event types in the cluster
    type_counts: dict[str, int] = {}
    for ev in cluster:
        type_counts[ev["type"]] = type_counts.get(ev["type"], 0) + 1
    type_summary = ", ".join(f"{v}×{k}" for k, v in sorted(type_counts.items()))

    if len(cluster) == 1:
        ev = cluster[0]
        if ev["type"] == "flash+blank":
            summary = "brief flash then blank/blue screen -- signal loss"
        elif ev["type"] == "blank":
            summary = "blank/dark frames -- possible signal loss or tape gap"
        elif ev["type"] == "corrupt":
            summary = (f"multi-frame corruption -- {ev['frame_count']} frames "
                       f"peak YDIF={ev['peak_ydif']:.1f} -- DV error concealment")
        elif ev["type"] == "band":
            lo, hi = ev["band_frac"]
            summary = (f"horizontal-band defect in band {ev['hot_band'] + 1}/"
                       f"{ev['n_bands']} (~{lo * 100:.0f}-{hi * 100:.0f}% down "
                       f"the frame) peak band YDIF={ev['peak_ydif']:.1f}")
        else:
            summary = f"single corrupt frame -- YAVG={ev['peak_value']:.1f}"
    else:
        summary = (f"{len(cluster)} clustered events ({type_summary}) "
                   f"spanning {last_end_sec - first_start_sec:.1f}s")

    return {
        "seek_ts": seek_ts,
        "duration": duration,
        "mid_ts": mid_ts,
        "event_count": len(cluster),
        "summary": summary,
        "events": cluster,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Detect dropout events in DV/MKV video files via signalstats.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("input", help="Input video file (.dv or .mkv)")
    parser.add_argument("-f", "--flash-threshold", type=float,
                        default=FLASH_THRESHOLD_DEFAULT,
                        help=f"YAVG flash threshold (default: {FLASH_THRESHOLD_DEFAULT})")
    parser.add_argument("-b", "--blank-threshold", type=float,
                        default=BLANK_THRESHOLD_DEFAULT,
                        help=f"YAVG blank threshold (default: {BLANK_THRESHOLD_DEFAULT})")
    parser.add_argument("-m", "--min-event-frames", type=int,
                        default=MIN_EVENT_FRAMES_DEFAULT,
                        help=f"Min frames for YAVG event (default: {MIN_EVENT_FRAMES_DEFAULT})")
    parser.add_argument("-g", "--merge-gap", type=int,
                        default=MERGE_GAP_DEFAULT,
                        help=f"Merge gap for YAVG events (default: {MERGE_GAP_DEFAULT})")
    parser.add_argument("--max-flash-frames", type=int,
                        default=MAX_FLASH_FRAMES_DEFAULT,
                        help=f"Max flash frames in a YAVG event before the flash "
                             f"component is suppressed (sustained bright content "
                             f"vs genuine FM overload) (default: {MAX_FLASH_FRAMES_DEFAULT})")

    parser.add_argument("-y", "--ydif-threshold", type=float,
                        default=YDIF_THRESHOLD_DEFAULT,
                        help=f"YDIF spike threshold (default: {YDIF_THRESHOLD_DEFAULT})")
    parser.add_argument("--yavg-dev-min", type=float,
                        default=YAVG_DEV_MIN_DEFAULT,
                        help=f"Min YAVG deviation from neighbours for spike (default: {YAVG_DEV_MIN_DEFAULT})")
    parser.add_argument("--ydif-run-min-frames", type=int,
                        default=YDIF_RUN_MIN_FRAMES_DEFAULT,
                        help=f"Min consecutive high-YDIF frames to report as a "
                             f"corrupt event (default: {YDIF_RUN_MIN_FRAMES_DEFAULT})")
    parser.add_argument("--ydif-run-peak-min", type=float,
                        default=YDIF_RUN_PEAK_MIN_DEFAULT,
                        help=f"Min peak YDIF within a corrupt run; suppresses "
                             f"camera-motion false positives whose YDIF stays "
                             f"near threshold (default: {YDIF_RUN_PEAK_MIN_DEFAULT})")
    parser.add_argument("--ydif-run-yavg-stdev-min", type=float,
                        default=YDIF_RUN_YAVG_STDEV_MIN_DEFAULT,
                        help=f"Min YAVG stdev within a corrupt run; suppresses "
                             f"smooth-motion false positives with stable luma "
                             f"(default: {YDIF_RUN_YAVG_STDEV_MIN_DEFAULT})")
    parser.add_argument("--rows", type=int, default=ROW_BANDS_DEFAULT,
                        help=f"Enable row-band spatial detector with this many "
                             f"horizontal bands (0 = disabled). Catches Hi8 "
                             f"horizontal dropout streaks frame-mean metrics "
                             f"miss. Adds a separate decode pass. NOTE: "
                             f"thresholds not yet calibrated. (default: {ROW_BANDS_DEFAULT})")
    parser.add_argument("--row-crop-bottom", type=int,
                        default=ROW_CROP_BOTTOM_DEFAULT,
                        help=f"Lines excluded from frame bottom before banding "
                             f"(head-switching noise) (default: {ROW_CROP_BOTTOM_DEFAULT})")
    parser.add_argument("--row-ratio", type=float, default=ROW_RATIO_DEFAULT,
                        help=f"Row-band: hot band YDIF must be >= this x the "
                             f"median of the other bands in the same frame "
                             f"(default: {ROW_RATIO_DEFAULT})")
    parser.add_argument("--row-floor", type=float, default=ROW_FLOOR_DEFAULT,
                        help=f"Row-band: hot band YDIF must be at least this "
                             f"absolute value (default: {ROW_FLOOR_DEFAULT})")
    parser.add_argument("--row-min-frames", type=int,
                        default=ROW_MIN_FRAMES_DEFAULT,
                        help=f"Row-band: min consecutive flagged frames to "
                             f"report (default: {ROW_MIN_FRAMES_DEFAULT})")
    parser.add_argument("--row-dump", action="store_true",
                        help="Diagnostic: run only the row-band pass and print a "
                             "per-frame per-band YDIF table (hot band, median of "
                             "others, ratio) to stdout, then exit. Use to "
                             "calibrate --row-floor and --row-ratio.")
    parser.add_argument("--no-ydif", action="store_true",
                        help="Disable YDIF spike detection")
    parser.add_argument("--no-yavg", action="store_true",
                        help="Disable YAVG blank/flash detection")
    parser.add_argument("-s", "--start-time", default=None,
                        help="Seek to timestamp before scanning (e.g. 01:56:00)")
    parser.add_argument("-d", "--duration", default=None,
                        help="Duration to scan (e.g. 00:10:00); mutually "
                             "exclusive with --end-time")
    parser.add_argument("-e", "--end-time", default=None,
                        help="Scan until this timestamp (e.g. 01:46:00); "
                             "mutually exclusive with --duration")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Print per-frame values for each event")
    parser.add_argument("--no-view-script", action="store_true",
                        help="Suppress view script generation")
    parser.add_argument("--view-script-dir", default=None,
                        help="Directory for view script (default: same as input file)")
    parser.add_argument("--view-dropout-script",
                        default=str(pathlib.Path(__file__).parent / "view_dropout.sh"),
                        help="Path to view_dropout.sh (default: same dir as this script)")
    parser.add_argument("--cluster-window", type=float,
                        default=CLUSTER_WINDOW_DEFAULT,
                        help=f"Cluster events within this many seconds into one clip "
                             f"(default: {CLUSTER_WINDOW_DEFAULT})")
    parser.add_argument("--view-lead-in", type=float,
                        default=VIEW_LEAD_IN_DEFAULT,
                        help=f"Seconds of context before each clip (default: {VIEW_LEAD_IN_DEFAULT})")
    parser.add_argument("--view-lead-out", type=float,
                        default=VIEW_LEAD_OUT_DEFAULT,
                        help=f"Seconds of context after each clip (default: {VIEW_LEAD_OUT_DEFAULT})")
    args = parser.parse_args()

    # Resolve the scan window.  --duration and --end-time are mutually
    # exclusive; --end-time is converted to a duration (end - start) for
    # ffmpeg's -t.  scan_duration is passed to every decode pass.
    if args.duration and args.end_time:
        parser.error("--duration and --end-time are mutually exclusive")
    scan_duration = args.duration
    if args.end_time:
        start_sec = parse_seek_seconds(args.start_time) if args.start_time else 0.0
        end_sec = parse_seek_seconds(args.end_time)
        if end_sec <= start_sec:
            parser.error(f"--end-time ({args.end_time}) must be after "
                         f"--start-time ({args.start_time or '00:00:00'})")
        scan_duration = f"{end_sec - start_sec:.3f}"

    print(f"Scanning: {args.input}", file=sys.stderr)
    if args.start_time:
        print(f"  Start:    {args.start_time}", file=sys.stderr)
    if args.end_time:
        print(f"  End:      {args.end_time}", file=sys.stderr)
    if scan_duration:
        print(f"  Duration: {scan_duration}", file=sys.stderr)
    if not args.no_yavg:
        print(f"  Flash threshold:    YAVG > {args.flash_threshold}", file=sys.stderr)
        print(f"  Blank threshold:    YAVG < {args.blank_threshold}", file=sys.stderr)
        print(f"  Min event frames:   {args.min_event_frames}", file=sys.stderr)
        print(f"  Merge gap:          {args.merge_gap} frames", file=sys.stderr)
    if not args.no_ydif:
        print(f"  YDIF spike threshold: {args.ydif_threshold}", file=sys.stderr)
    print("", file=sys.stderr)

    seek_offset = parse_seek_seconds(args.start_time) if args.start_time else 0.0

    # Probe FPS before the signalstats pass so timestamps are correct for
    # both 29.97 fps DV files and 60 fps MKV files from the ESRGAN pipeline.
    fps = probe_fps(args.input)
    print(f"Detected frame rate: {fps:.4f} fps", file=sys.stderr)

    print("Running ffmpeg signalstats (this may take a while)...", file=sys.stderr)
    yavg, ydif = run_signalstats(args.input, args.start_time, scan_duration,
                                 fps=fps, seek_offset=seek_offset)

    if not yavg:
        print("ERROR: No data extracted. Check input file and ffmpeg.", file=sys.stderr)
        return 1

    print(f"Extracted {len(yavg)} frames.", file=sys.stderr)

    # Collect events from enabled detectors
    yavg_events = []
    if not args.no_yavg:
        yavg_events = detect_yavg_events(yavg, args.flash_threshold,
                                         args.blank_threshold,
                                         args.min_event_frames, args.merge_gap,
                                         args.max_flash_frames)

    ydif_events = []
    if not args.no_ydif:
        raw_spikes = detect_ydif_spikes(ydif, yavg, args.ydif_threshold,
                                        args.yavg_dev_min)
        raw_runs = detect_ydif_runs(ydif, yavg, args.ydif_threshold,
                                    args.ydif_run_min_frames,
                                    args.ydif_run_peak_min,
                                    args.ydif_run_yavg_stdev_min)
        # Suppress spikes and runs that fall within or immediately adjacent
        # to a YAVG event -- those transitions are already captured by the
        # YAVG detector and would otherwise appear as duplicate entries.
        yavg_ranges = [(e["start_frame"] - 1, e["end_frame"] + 1)
                       for e in yavg_events]
        for spike in raw_spikes:
            f = spike["start_frame"]
            if not any(lo <= f <= hi for lo, hi in yavg_ranges):
                ydif_events.append(spike)
        for run in raw_runs:
            f = run["start_frame"]
            if not any(lo <= f <= hi for lo, hi in yavg_ranges):
                ydif_events.append(run)

    # Diagnostic: per-band YDIF dump for calibrating the row-band detector.
    if args.row_dump:
        if not args.rows or args.rows < 2:
            print("ERROR: --row-dump requires --rows >= 2", file=sys.stderr)
            return 1
        width, height = probe_dimensions(args.input)
        usable_h = max(0, height - args.row_crop_bottom)
        band_h = usable_h // args.rows
        print(f"Row-band dump: {args.rows} bands of {band_h} lines "
              f"(bottom {args.row_crop_bottom} excluded)...", file=sys.stderr)
        bands_ydif = run_signalstats_bands(args.input, args.start_time,
                                           scan_duration, width, band_h,
                                           args.rows, fps=fps,
                                           seek_offset=seek_offset)
        if not bands_ydif:
            return 1
        nb = len(bands_ydif)
        nf = len(bands_ydif[0])
        hdr = "    frame  t=timestamp  " + "".join(f"b{b:<6d}" for b in range(nb))
        hdr += "  hot  med_oth   ratio"
        print(hdr)
        for fr in range(1, nf):  # frame 0 YDIF is 0
            col = [bands_ydif[b][fr] for b in range(nb)]
            hb = max(range(nb), key=lambda b: col[b])
            others = sorted(col[b] for b in range(nb) if b != hb)
            mo = others[len(others) // 2] if len(others) % 2 else \
                (others[len(others) // 2 - 1] + others[len(others) // 2]) / 2.0
            ratio = col[hb] / max(mo, 1e-6)
            ts = abs_timestamp(seek_offset, fr, fps)
            cells = "".join(f"{v:<7.1f}" for v in col)
            print(f"    {fr:5d}  t={ts}  {cells}  b{hb}  {mo:6.1f}  {ratio:6.1f}")
        return 0

    # Optional row-band spatial pass (separate decode; opt-in via --rows).
    band_events = []
    if args.rows and args.rows >= 2:
        width, height = probe_dimensions(args.input)
        usable_h = max(0, height - args.row_crop_bottom)
        band_h = usable_h // args.rows
        if band_h < 2:
            print(f"WARNING: --rows {args.rows} too large for height {height}; "
                  f"skipping row-band pass", file=sys.stderr)
        else:
            print(f"Running row-band signalstats: {args.rows} bands of "
                  f"{band_h} lines (bottom {args.row_crop_bottom} excluded)...",
                  file=sys.stderr)
            bands_ydif = run_signalstats_bands(args.input, args.start_time,
                                               scan_duration, width, band_h,
                                               args.rows, fps=fps,
                                               seek_offset=seek_offset)
            raw_bands = detect_row_band_events(bands_ydif, args.row_ratio,
                                               args.row_floor,
                                               args.row_min_frames)
            # Suppress band events overlapping events already found by the
            # frame-mean detectors -- those are the same physical defect.
            existing = [(e["start_frame"] - 1, e["end_frame"] + 1)
                        for e in (yavg_events + ydif_events)]
            for be in raw_bands:
                f = be["start_frame"]
                if not any(lo <= f <= hi for lo, hi in existing):
                    band_events.append(be)

    events = yavg_events + ydif_events + band_events

    # Sort all events by start frame for unified output
    events.sort(key=lambda e: e["start_frame"])

    if not events:
        print("No dropout events detected.")
        return 0

    print(f"Detected {len(events)} event(s):\n")
    print(f"{'#':>3}  {'Timestamp':>12}  {'Duration':>10}  {'Frames':>6}  "
          f"{'PeakY':>7}  {'MinY':>7}  {'Type'}")
    print("-" * 72)

    for i, ev in enumerate(events, 1):
        ts = abs_timestamp(seek_offset, ev["start_frame"], fps)
        duration_s = ev["frame_count"] / fps
        print(f"{i:>3}  {ts:>12}  {duration_s:>9.3f}s  {ev['frame_count']:>6}  "
              f"{ev['peak_value']:>7.1f}  {ev['min_value']:>7.1f}  {ev['type']}")

        if args.verbose:
            for fi in range(ev["start_frame"], ev["end_frame"] + 1):
                frame_ts = abs_timestamp(seek_offset, fi, fps)
                print(f"       frame {fi:5d}  t={frame_ts}  "
                      f"YAVG={yavg[fi]:.3f}  YDIF={ydif[fi]:.3f}")

    # Generate view script alongside the input file unless suppressed.
    # Named <input_stem>_view_events.sh so it is unambiguous which tape
    # it belongs to when reviewing later.
    #
    # Events within --cluster-window seconds of each other are collapsed into
    # a single longer clip to avoid reviewing a dozen heavily overlapping
    # segments on sections of badly degraded tape.
    if not args.no_view_script:
        input_path = pathlib.Path(args.input).resolve()
        view_script_dir = pathlib.Path(args.view_script_dir or str(input_path.parent))
        script_path = view_script_dir / (input_path.stem + "_view_events.sh")

        view_sh = pathlib.Path(args.view_dropout_script).resolve()

        # Group events into viewing clips
        clips = cluster_events_for_viewing(
            events,
            seek_offset=seek_offset,
            fps=fps,
            cluster_window=args.cluster_window,
            lead_in=args.view_lead_in,
            lead_out=args.view_lead_out,
        )

        with open(script_path, "w") as sf:
            sf.write("#!/usr/bin/env bash\n")
            sf.write(f"# View script for: {input_path.name}\n")
            sf.write(f"# Generated by detect_dropouts.py\n")
            sf.write(f"# {len(events)} event(s) in {len(clips)} viewing clip(s)\n")
            sf.write(f"# Cluster window: {args.cluster_window}s  "
                     f"Lead-in: {args.view_lead_in}s  "
                     f"Lead-out: {args.view_lead_out}s\n")
            sf.write("#\n")
            sf.write("# Clips are played sequentially -- quit each with q\n")
            sf.write("# to advance to the next.\n")
            sf.write("#\n")
            sf.write(f"INPUT={shlex.quote(str(input_path))}\n\n")

            for i, clip in enumerate(clips, 1):
                # Round clip duration up to the nearest second for the shell
                # call; view_dropout.sh takes an integer duration.
                clip_dur_int = max(1, int(clip["duration"]) + 1)

                sf.write(f"# Clip {i}/{len(clips)}"
                         f"  seek={clip['seek_ts']}"
                         f"  dur={clip['duration']:.1f}s"
                         f"  mid={clip['mid_ts']}"
                         f"  ({clip['event_count']} event(s))\n")
                sf.write(f"# Look for: {clip['summary']}\n")

                # List constituent events for reference
                for j, ev in enumerate(clip["events"], 1):
                    ev_ts = abs_timestamp(seek_offset, ev["start_frame"], fps)
                    ev_dur = ev["frame_count"] / fps
                    sf.write(f"#   event {j}: {ev_ts}  {ev_dur:.3f}s  {ev['type']}\n")

                sf.write(shlex.quote(str(view_sh))
                         + ' --seek "$INPUT" '
                         + clip["seek_ts"]
                         + f" {clip_dur_int}\n\n")

        script_path.chmod(0o755)
        print(f"\nView script: {script_path}  "
              f"({len(clips)} clip(s) for {len(events)} event(s))",
              file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
