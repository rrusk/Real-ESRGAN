#!/usr/bin/env python3
"""
detect_dropouts.py - Detect dropout events in DV captures using per-frame
                     signalstats metrics (YAVG and YDIF).

Two complementary detection modes run in a single ffmpeg pass:

  YAVG mode — detects multi-frame signal loss events:
    Flash frames:  YAVG > flash_threshold  (FM carrier overload)
    Blank frames:  YAVG < blank_threshold  (TRV330 blue mute / signal loss)
    An event must contain at least one blank frame to be reported.
    Flash-only events (scene content, lighting) are suppressed.

  YDIF mode — detects single-frame glitches:
    YDIF measures mean absolute luma difference between adjacent frames.
    A single-frame glitch produces TWO consecutive high-YDIF frames:
      frame N:   high YDIF  (bad frame arrives — differs from previous)
      frame N+1: high YDIF  (return to normal — differs from bad frame)
    A scene cut produces only ONE high-YDIF frame, so the two-consecutive
    requirement suppresses scene cuts without needing YMIN/YMAX checks.

Threshold rationale (calibrated against TRV330 Hi8 captures):
    Flash threshold (140): FM carrier overload — analog signal briefly
        exceeds normal luma range before collapsing. Normal content < 130.
    Blank threshold (50):  TRV330 blue mute frames have YAVG~81. Genuine
        signal loss dips well below 81. Dark scenes stay 60-70 and are
        excluded. 50 cleanly separates signal loss from dark content.
    YDIF spike threshold (40): Normal motion produces YDIF 5-15. Single-
        frame glitches produce YDIF 40-50 on both the arrival and return
        frames. 40 gives good margin above normal content while staying
        below typical glitch values of 46+.

Usage:
    detect_dropouts.py [options] <input.dv>

Options:
    -f, --flash-threshold FLOAT   YAVG flash threshold (default: 140)
    -b, --blank-threshold FLOAT   YAVG blank threshold (default: 50)
    -m, --min-event-frames INT    Min consecutive anomalous frames for
                                  YAVG events (default: 3)
    -g, --merge-gap INT           Merge YAVG events separated by <= this
                                  many frames (default: 5)
    -y, --ydif-threshold FLOAT    YDIF spike threshold (default: 40)
    --no-ydif                     Disable YDIF spike detection
    --no-yavg                     Disable YAVG blank/flash detection
    -s, --start-time STR          Seek to timestamp (e.g. 01:56:00)
    -d, --duration STR            Duration to scan (e.g. 00:10:00)
    -v, --verbose                 Print per-frame values for each event
"""

import argparse
import subprocess
import sys
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
FPS = 29.97


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


def abs_timestamp(seek_offset: float, frame_index: int) -> str:
    """Return HH:MM:SS.mmm absolute timestamp for a frame."""
    total_seconds = seek_offset + frame_index / FPS
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
                abs_sec = seek_offset + frame_count / FPS
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
                       merge_gap: int) -> list[dict]:
    """
    Detect multi-frame blank/flash dropout events from YAVG data.

    Events must contain at least one blank frame (YAVG < blank_threshold).
    Flash-only events are suppressed as they represent scene content.
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

    # Collect runs into events, requiring a blank component
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
                has_flash = any(y > flash_threshold for y in window)
                has_blank = any(y < blank_threshold for y in window)
                if has_blank:
                    etype = "flash+blank" if has_flash else "blank"
                    events.append({
                        "start_frame": start,
                        "end_frame": end,
                        "frame_count": frame_count,
                        "peak_value": max(window),
                        "min_value": min(window),
                        "type": etype,
                        "metric": "YAVG",
                    })
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
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Detect dropout events in DV captures via signalstats.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("input", help="Input DV file")
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
    parser.add_argument("-y", "--ydif-threshold", type=float,
                        default=YDIF_THRESHOLD_DEFAULT,
                        help=f"YDIF spike threshold (default: {YDIF_THRESHOLD_DEFAULT})")
    parser.add_argument("--yavg-dev-min", type=float,
                        default=YAVG_DEV_MIN_DEFAULT,
                        help=f"Min YAVG deviation from neighbours for spike (default: {YAVG_DEV_MIN_DEFAULT})")
    parser.add_argument("--no-ydif", action="store_true",
                        help="Disable YDIF spike detection")
    parser.add_argument("--no-yavg", action="store_true",
                        help="Disable YAVG blank/flash detection")
    parser.add_argument("-s", "--start-time", default=None,
                        help="Seek to timestamp before scanning (e.g. 01:56:00)")
    parser.add_argument("-d", "--duration", default=None,
                        help="Duration to scan (e.g. 00:10:00)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Print per-frame values for each event")
    args = parser.parse_args()

    print(f"Scanning: {args.input}", file=sys.stderr)
    if args.start_time:
        print(f"  Start:    {args.start_time}", file=sys.stderr)
    if args.duration:
        print(f"  Duration: {args.duration}", file=sys.stderr)
    if not args.no_yavg:
        print(f"  Flash threshold:    YAVG > {args.flash_threshold}", file=sys.stderr)
        print(f"  Blank threshold:    YAVG < {args.blank_threshold}", file=sys.stderr)
        print(f"  Min event frames:   {args.min_event_frames}", file=sys.stderr)
        print(f"  Merge gap:          {args.merge_gap} frames", file=sys.stderr)
    if not args.no_ydif:
        print(f"  YDIF spike threshold: {args.ydif_threshold}", file=sys.stderr)
    print("", file=sys.stderr)

    seek_offset = parse_seek_seconds(args.start_time) if args.start_time else 0.0

    print("Running ffmpeg signalstats (this may take a while)...", file=sys.stderr)
    yavg, ydif = run_signalstats(args.input, args.start_time, args.duration,
                                 seek_offset=seek_offset)

    if not yavg:
        print("ERROR: No data extracted. Check input file and ffmpeg.", file=sys.stderr)
        return 1

    print(f"Extracted {len(yavg)} frames.", file=sys.stderr)

    # Collect events from enabled detectors
    yavg_events = []
    if not args.no_yavg:
        yavg_events = detect_yavg_events(yavg, args.flash_threshold,
                                         args.blank_threshold,
                                         args.min_event_frames, args.merge_gap)

    ydif_events = []
    if not args.no_ydif:
        raw_spikes = detect_ydif_spikes(ydif, yavg, args.ydif_threshold,
                                        args.yavg_dev_min)
        # Suppress spikes that fall within or immediately adjacent to a YAVG
        # event -- those transitions are already captured by the YAVG detector
        # and would otherwise appear as duplicate/redundant spike entries.
        yavg_ranges = [(e["start_frame"] - 1, e["end_frame"] + 1)
                       for e in yavg_events]
        for spike in raw_spikes:
            f = spike["start_frame"]
            if not any(lo <= f <= hi for lo, hi in yavg_ranges):
                ydif_events.append(spike)

    events = yavg_events + ydif_events

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
        ts = abs_timestamp(seek_offset, ev["start_frame"])
        duration_s = ev["frame_count"] / FPS
        print(f"{i:>3}  {ts:>12}  {duration_s:>9.3f}s  {ev['frame_count']:>6}  "
              f"{ev['peak_value']:>7.1f}  {ev['min_value']:>7.1f}  {ev['type']}")

        if args.verbose:
            for fi in range(ev["start_frame"], ev["end_frame"] + 1):
                frame_ts = abs_timestamp(seek_offset, fi)
                print(f"       frame {fi:5d}  t={frame_ts}  "
                      f"YAVG={yavg[fi]:.3f}  YDIF={ydif[fi]:.3f}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
