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
    """Fetches resolution, framerate, bitrate, and pixel format using ffprobe."""
    # Check if the user is trying to probe an ISO directly
    if input_file.lower().endswith('.iso'):
        raise ValueError(
            "Cannot probe .ISO files directly. Mount the ISO and "
            "probe individual VOB files (e.g., VTS_01_1.VOB)."
        )

    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,pix_fmt,bit_rate,duration",
        "-of", "json",
        input_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    data = json.loads(result.stdout)
    
    if 'streams' not in data or not data['streams']:
        raise KeyError(f"No video streams found in {input_file}.")
        
    return data['streams'][0]

# ==============================================================================
# INTERLACING DETECTION (idet)
# ==============================================================================
def detect_interlace(input_file, frames=500):
    """
    Production-grade interlace detection.

    Detection order:
    1. Check codec-level frame flags (authoritative).
    2. If structurally progressive -> return Progressive.
    3. Otherwise run idet and require meaningful dominance.
    """

    # ------------------------------------------------------------
    # STEP 1 — Structural Frame Check (Authoritative)
    # ------------------------------------------------------------
    try:
        cmd = [
            "ffprobe",
            "-v", "error",
            "-select_streams", "v:0",
            "-show_frames",
            "-read_intervals", "%+#50",  # check first 50 frames only
            input_file
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        interlaced_flags = re.findall(r"interlaced_frame=(\d)", result.stdout)

        if interlaced_flags:
            interlaced_count = sum(int(x) for x in interlaced_flags)
            total_checked = len(interlaced_flags)

            # If ANY frames are structurally interlaced, trust this fully
            if interlaced_count > 0:
                return "Interlaced (Frame-flag detected)"
            else:
                # Structurally progressive — no need for idet
                return "Progressive"

    except Exception:
        pass  # Fall through to idet if something unexpected happens

    # ------------------------------------------------------------
    # STEP 2 — Pixel-Level Heuristic Check (idet fallback)
    # ------------------------------------------------------------
    print(f"Analyzing first {frames} frames for interlacing (idet heuristic)...")

    cmd = [
        "ffmpeg",
        "-i", input_file,
        "-filter:v", "idet",
        "-frames:v", str(frames),
        "-an",
        "-f", "null",
        "-"
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    match = re.search(
        r"Multi frame detection: TFF:\s*(\d+)\s*BFF:\s*(\d+)\s*Progressive:\s*(\d+)",
        result.stderr
    )

    if not match:
        return "Undetermined"

    tff, bff, prog = map(int, match.groups())
    total = tff + bff + prog

    if total == 0:
        return "Undetermined"

    interlace_ratio = (tff + bff) / total
    progressive_ratio = prog / total

    # ------------------------------------------------------------
    # PROFESSIONAL THRESHOLDS
    # ------------------------------------------------------------
    # <15% interlace noise = treat as progressive
    # >20% dominance = true interlace
    # between 15–20% = weak/ambiguous
    # ------------------------------------------------------------

    if interlace_ratio < 0.15:
        return f"Progressive (idet noise {interlace_ratio:.1%})"

    if interlace_ratio > 0.20:
        if tff > bff:
            return f"Interlaced (TFF {tff}/{total})"
        else:
            return f"Interlaced (BFF {bff}/{total})"

    return f"Mostly Progressive (weak field artifacts {interlace_ratio:.1%})"

# ==============================================================================
# UNIVERSAL DATA HEALTH (Bits Per Pixel Logic)
# ==============================================================================
def check_bitrate_health(meta, input_file):
    """Universal health check based on Bits Per Pixel (bpp)."""
    try:
        file_size_bits = os.path.getsize(input_file) * 8
        
        # 1. Resolve Duration (Handles Hauppauge header/DTS issues)
        duration = float(meta.get('duration', 0))
        if duration > 86400 or duration <= 0:
            # Fallback: Count actual packets for broken timestamps
            cmd = ["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0", 
                   "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", input_file]
            frames = int(subprocess.check_output(cmd).decode().strip())
            fps_num, fps_den = map(int, meta.get('r_frame_rate', '30000/1001').split('/'))
            duration = frames / (fps_num / fps_den)
        
        # 2. Calculate Density Metrics
        bitrate_mbps = (file_size_bits / duration) / 1_000_000
        width, height = int(meta.get('width', 0)), int(meta.get('height', 0))
        fps_num, fps_den = map(int, meta.get('r_frame_rate', '30000/1001').split('/'))
        fps = fps_num / fps_den
        
        # bpp = Total bits available for every pixel in the video
        bpp = file_size_bits / (width * height * (fps * duration))
        
        # 3. Dynamic Thresholds (Codec-Aware)
        pix_fmt = meta.get('pix_fmt', '')
        
        # If the format is uncompressed (like yuyv422), we expect bpp to be near 16
        if 'yuyv' in pix_fmt or 'raw' in pix_fmt:
            target = 16.0  # Uncompressed 4:2:2 baseline
        else:
            target = 0.15  # High-quality H.264 baseline
            
        ratio = bpp / target

        # 4. Universal Labels
        if ratio >= 0.9: 
            return f"Excellent ({bitrate_mbps:.2f} Mbps) - High Detail Retention"
        elif ratio >= 0.6: 
            return f"Good ({bitrate_mbps:.2f} Mbps) - Standard Quality"
        elif ratio >= 0.3: 
            return f"Fair ({bitrate_mbps:.2f} Mbps) - Compressed"
        else: 
            return f"Poor ({bitrate_mbps:.2f} Mbps) - Heavily Compressed"

    except Exception as e:
        return f"Unknown Error: {e}"

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================
def main():
    args = parse_args()
    
    try:
        meta = probe_metadata(args.input)
        interlace_status = detect_interlace(args.input)
        quality_health = check_bitrate_health(meta, args.input)

        print("\n--- Video Probe Report ---")
        print(f"File:        {args.input}")
        print(f"Resolution:  {meta['width']}x{meta['height']}")
        print(f"Frame Rate:  {meta['r_frame_rate']} fps")
        print(f"Pixel Format: {meta['pix_fmt']}")
        print(f"Scan Type:   {interlace_status}")
        print(f"Data Health: {quality_health}")
        print("--------------------------\n")

        # Visual Scannability: High-level Warnings
        if "Poor" in quality_health or "Fair" in quality_health:
            print("⚠️  DATA WARNING: Low bitrate detected. AI upscaling")
            print("   may amplify compression blocks instead of actual detail.")
        
        if "Interlaced" in interlace_status:
            print("⚠️  SCAN WARNING: This file is interlaced.")
            print("   Run ./prepare_video.sh before starting the pipeline.")
        else:
            print("✅ This file appears progressive and ready for the pipeline.")

    except Exception as e:
        print(f"Error probing file: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
