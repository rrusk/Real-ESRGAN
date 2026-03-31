#!/usr/bin/env python3
import subprocess
import re
import sys
import json
import argparse
import os

# ==============================================================================
# CLI ARGUMENT PARSING
# ==============================================================================
def parse_args():
    parser = argparse.ArgumentParser(
        description="Probe video for VHS enhancement metadata, interlacing, and quality metrics.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example:
  ./probe_video.py inputs/vhs_capture.avi
  ./probe_video.py outputs/master.mkv
        """
    )
    parser.add_argument("input", help="Path to the video file to analyze.")
    
    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
        sys.exit(1)
        
    return parser.parse_args()

# ==============================================================================
# METADATA EXTRACTION (ffprobe)
# ==============================================================================
def probe_metadata(input_file):
    """Fetches resolution, framerate, bitrate, pixel format, codec, and field order using ffprobe."""
    if input_file.lower().endswith('.iso'):
        raise ValueError(
            "Cannot probe .ISO files directly. Mount the ISO and "
            "probe individual VOB files (e.g., VTS_01_1.VOB)."
        )

    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,pix_fmt,bit_rate,duration,codec_name,field_order",
        "-of", "json",
        input_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    data = json.loads(result.stdout)
    
    if 'streams' not in data or not data['streams']:
        raise KeyError(f"No video streams found in {input_file}.")
        
    return data['streams'][0]


def probe_audio(input_file):
    """Fetches audio codec name using ffprobe."""
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "a:0",
        "-show_entries", "stream=codec_name",
        "-of", "default=noprint_wrappers=1:nokey=1",
        input_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.stdout.strip() or "none"


def probe_format(input_file):
    """
    Fetches container-level duration and bitrate using ffprobe -show_format.

    MKV and other containers often store accurate duration at the format
    (container) level even when the individual stream's duration field is
    missing or zero. This is the preferred duration source for non-MP4
    containers and is used as the primary fallback before the slow
    count_frames path.
    """
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration,bit_rate,size",
        "-of", "json",
        input_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    try:
        data = json.loads(result.stdout)
        return data.get('format', {})
    except (json.JSONDecodeError, KeyError):
        return {}

# ==============================================================================
# FIELD ORDER AND INTERLACE DETECTION
# ==============================================================================
def detect_interlace(input_file, meta, frames=500):
    """
    Production-grade interlace and field order detection.

    Detection priority mirrors prepare_video.sh:
      1. DV codec shortcut — always BFF on NTSC; ffprobe cannot read field
         order from AVI container headers for DV streams and returns 'unknown'.
      2. ffprobe stream=field_order — authoritative for MPEG-2/DVD and most
         MP4/MKV sources where the container stores this metadata.
      3. ffprobe frame flags — checks first 50 frames for interlaced_frame=1.
         Reliable structural check independent of container metadata.
      4. idet heuristic fallback — pixel-level analysis; used only when all
         structural sources are absent or inconclusive.

    Returns a tuple: (scan_type_string, is_interlaced_bool, parity_string)
      parity_string matches prepare_video.sh convention: "0"=TFF, "1"=BFF, "-1"=auto
    """

    codec_name = meta.get('codec_name', '')

    # ------------------------------------------------------------------
    # STEP 1 — DV Codec Shortcut
    # DV streams captured via FireWire are always BFF on NTSC. The AVI
    # container does not store field order metadata for DV, so ffprobe
    # returns 'unknown'. Shortcut here to avoid misleading fallthrough.
    # ------------------------------------------------------------------
    if codec_name.startswith('dv'):
        return (
            "Interlaced (BFF — DV/NTSC, codec-based detection)",
            True,
            "1"
        )

    # ------------------------------------------------------------------
    # STEP 2 — ffprobe stream=field_order
    # Authoritative for MPEG-2/DVD, MP4, and most MKV sources.
    # ------------------------------------------------------------------
    field_order = meta.get('field_order', '').upper()

    if field_order == 'PROGRESSIVE':
        return ("Progressive", False, "-1")
    elif field_order == 'TT':
        return ("Interlaced (TFF — Top Field First, ffprobe stream metadata)", True, "0")
    elif field_order in ('BB', 'BT'):
        return ("Interlaced (BFF — Bottom Field First, ffprobe stream metadata)", True, "1")

    # ------------------------------------------------------------------
    # STEP 3 — Frame Flag Check
    # Checks codec-level interlaced_frame flags on first 50 frames.
    # Authoritative when present; fast (no decoding of pixel data).
    # ------------------------------------------------------------------
    try:
        cmd = [
            "ffprobe", "-v", "error",
            "-select_streams", "v:0",
            "-show_frames",
            "-read_intervals", "%+#50",
            input_file
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        interlaced_flags = re.findall(r"interlaced_frame=(\d)", result.stdout)
        top_field_flags  = re.findall(r"top_field_first=(\d)", result.stdout)

        if interlaced_flags:
            interlaced_count = sum(int(x) for x in interlaced_flags)
            if interlaced_count == 0:
                return ("Progressive", False, "-1")

            # Determine field order from top_field_first flags
            if top_field_flags:
                tff_count = sum(int(x) for x in top_field_flags)
                if tff_count > len(top_field_flags) / 2:
                    return (
                        "Interlaced (TFF — Top Field First, frame-flag detection)",
                        True, "0"
                    )
                else:
                    return (
                        "Interlaced (BFF — Bottom Field First, frame-flag detection)",
                        True, "1"
                    )
            else:
                return (
                    "Interlaced (field order unknown — bwdif will auto-detect)",
                    True, "-1"
                )
    except Exception:
        pass

    # ------------------------------------------------------------------
    # STEP 4 — idet Pixel-Level Heuristic (last resort)
    # ------------------------------------------------------------------
    print(f"Analyzing first {frames} frames for interlacing (idet heuristic)...")

    cmd = [
        "ffmpeg", "-i", input_file,
        "-filter:v", "idet",
        "-frames:v", str(frames),
        "-an", "-f", "null", "-"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)

    match = re.search(
        r"Multi frame detection: TFF:\s*(\d+)\s*BFF:\s*(\d+)\s*Progressive:\s*(\d+)",
        result.stderr
    )

    if not match:
        return ("Undetermined", False, "-1")

    tff, bff, prog = map(int, match.groups())
    total = tff + bff + prog

    if total == 0:
        return ("Undetermined", False, "-1")

    interlace_ratio = (tff + bff) / total

    if interlace_ratio < 0.15:
        return (f"Progressive (idet noise {interlace_ratio:.1%})", False, "-1")

    if interlace_ratio > 0.20:
        if tff > bff:
            return (
                f"Interlaced (TFF — Top Field First, idet {tff}/{total})",
                True, "0"
            )
        else:
            return (
                f"Interlaced (BFF — Bottom Field First, idet {bff}/{total})",
                True, "1"
            )

    return (f"Mostly Progressive (weak field artifacts {interlace_ratio:.1%})", False, "-1")


# ==============================================================================
# UNIVERSAL DATA HEALTH (Bits Per Pixel Logic)
# ==============================================================================
def check_bitrate_health(meta, input_file, fmt=None):
    """
    Universal health check based on Bits Per Pixel (bpp) and Resolution.

    Duration resolution priority (fastest to slowest):
      1. Stream-level duration  — reliable for AVI/MP4 with intact headers.
      2. Format-level duration  — reliable for MKV and most other containers;
                                  avoids the hang that count_frames causes on
                                  large MKV files.
      3. ffprobe count_packets  — fast packet count; accurate enough for bpp
                                  estimation without decoding every frame.
      4. ffprobe count_frames   — last resort only; decodes every frame and
                                  is extremely slow on long files. Avoided
                                  unless all other sources fail.
    """
    try:
        file_size_bits = os.path.getsize(input_file) * 8
        fps_num, fps_den = map(int, meta.get('r_frame_rate', '30000/1001').split('/'))
        fps = fps_num / fps_den

        # ------------------------------------------------------------------
        # 1. Stream-level duration
        # ------------------------------------------------------------------
        duration = float(meta.get('duration', 0))

        # Hauppauge and some AVI muxers write absurd DTS values that produce
        # durations > 1 day. MKV stream duration is often simply absent (0).
        # Both cases require falling through to a better source.
        BROKEN_DURATION = duration <= 0 or duration > 86400

        # ------------------------------------------------------------------
        # 2. Format-level duration (fast; covers MKV, MOV, and most others)
        # ------------------------------------------------------------------
        if BROKEN_DURATION:
            if fmt is None:
                fmt = probe_format(input_file)
            fmt_duration = float(fmt.get('duration', 0))
            if fmt_duration > 0:
                duration = fmt_duration
                BROKEN_DURATION = False

        # ------------------------------------------------------------------
        # 3. Packet count (fast — no decoding, just reads index)
        # ------------------------------------------------------------------
        if BROKEN_DURATION:
            try:
                cmd = [
                    "ffprobe", "-v", "error",
                    "-select_streams", "v:0",
                    "-count_packets",
                    "-show_entries", "stream=nb_read_packets",
                    "-of", "csv=p=0",
                    input_file
                ]
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                pkt_count = int(result.stdout.strip())
                if pkt_count > 0:
                    duration = pkt_count / fps
                    BROKEN_DURATION = False
            except (ValueError, subprocess.TimeoutExpired):
                pass

        # ------------------------------------------------------------------
        # 4. Frame count (last resort — slow, decodes every frame)
        # ------------------------------------------------------------------
        if BROKEN_DURATION:
            print("[WARN] Duration unresolvable from headers — falling back to frame "
                  "count (this may take a while for large files)...")
            print("[WARN] unrealistic or missing duration detected — enabling PTS regeneration recommended.")
            cmd = [
                "ffprobe", "-v", "error",
                "-count_frames",
                "-select_streams", "v:0",
                "-show_entries", "stream=nb_read_frames",
                "-of", "csv=p=0",
                input_file
            ]
            frames = int(subprocess.check_output(cmd).decode().strip())
            duration = frames / fps

        # ------------------------------------------------------------------
        # 2. Calculate Density Metrics
        # ------------------------------------------------------------------
        bitrate_mbps = (file_size_bits / duration) / 1_000_000
        width, height = int(meta.get('width', 0)), int(meta.get('height', 0))

        # bpp = Total bits available for every pixel in the video
        bpp = file_size_bits / (width * height * (fps * duration))

        # ------------------------------------------------------------------
        # 3. Dynamic Thresholds (Codec-Aware)
        # ------------------------------------------------------------------
        pix_fmt = meta.get('pix_fmt', '')

        # If the format is uncompressed (like yuyv422), we expect bpp ~16
        if 'yuyv' in pix_fmt or 'raw' in pix_fmt:
            target = 16.0   # Uncompressed 4:2:2 baseline
        else:
            target = 0.20   # Archival H.264/H.265 baseline

        # ------------------------------------------------------------------
        # 4. Resolution Multiplier (Penalty for sub-SD content)
        # Archival Standard is 720x480 (345,600 pixels)
        # ------------------------------------------------------------------
        pixel_count = width * height
        res_multiplier = min(1.0, pixel_count / 345600)

        # Final Score: BPP accuracy adjusted by how much detail is actually present
        ratio = (bpp / target) * res_multiplier

        # ------------------------------------------------------------------
        # 5. Universal Labels
        # ------------------------------------------------------------------
        if ratio >= 0.85 and width >= 720:
            return f"Excellent ({bitrate_mbps:.2f} Mbps) - Archival Quality"
        elif ratio >= 0.6:
            return f"Good ({bitrate_mbps:.2f} Mbps) - Standard Quality"
        elif ratio >= 0.3:
            return f"Fair ({bitrate_mbps:.2f} Mbps) - Compressed/Low-Res"
        else:
            return f"Poor ({bitrate_mbps:.2f} Mbps) - Sub-standard Archive"

    except Exception as e:
        return f"Unknown Error: {e}"

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================
def main():
    args = parse_args()
    
    try:
        meta = probe_metadata(args.input)
        fmt = probe_format(args.input)
        audio_codec = probe_audio(args.input)
        scan_type, is_interlaced, parity = detect_interlace(args.input, meta)
        quality_health = check_bitrate_health(meta, args.input, fmt=fmt)

        codec_name = meta.get('codec_name', 'unknown')

        # Audio annotation: flag PCM since it affects container choice in prepare_video.sh
        if audio_codec.startswith('pcm'):
            audio_display = f"{audio_codec} (PCM — output container will switch to MKV in prepare_video.sh)"
        else:
            audio_display = audio_codec

        print("\n--- Video Probe Report ---")
        print(f"File:         {args.input}")
        print(f"Resolution:   {meta['width']}x{meta['height']}")
        print(f"Frame Rate:   {meta['r_frame_rate']} fps")
        print(f"Pixel Format: {meta['pix_fmt']}")
        print(f"Video Codec:  {codec_name}")
        print(f"Audio Codec:  {audio_display}")
        print(f"Scan Type:    {scan_type}")
        print(f"Data Health:  {quality_health}")
        print("--------------------------\n")

        # Visual Scannability: High-level Warnings
        if "Poor" in quality_health or "Fair" in quality_health:
            print("⚠️  DATA WARNING: Low bitrate detected. AI upscaling")
            print("   may amplify compression blocks instead of actual detail.")

        if is_interlaced:
            print("⚠️  SCAN WARNING: This file is interlaced.")
            print("   Run ./prepare_video.sh before starting the pipeline.")
        else:
            print("✅ This file appears progressive and ready for the pipeline.")

    except Exception as e:
        print(f"Error probing file: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
