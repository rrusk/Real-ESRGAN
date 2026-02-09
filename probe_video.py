#!/usr/bin/env python3
import subprocess
import re
import sys
import json
import argparse
import os

def parse_args():
    parser = argparse.ArgumentParser(
        description="Probe video for VHS enhancement metadata, interlacing, and quality metrics.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example:
  ./probe_video.py inputs/my_tape.avi
        """
    )
    parser.add_argument("input", help="Path to the video file to analyze.")
    
    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
        sys.exit(1)
        
    return parser.parse_args()

def probe_metadata(input_file):
    """Fetches resolution, framerate, bitrate, and pixel format using ffprobe."""
    # Check if the user is trying to probe an ISO directly
    if input_file.lower().endswith('.iso'):
        raise ValueError(
            "Cannot probe .ISO files directly. Please mount the ISO and "
            "probe the individual VOB files (e.g., VTS_01_1.VOB)."
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
        raise KeyError(f"No video streams found in {input_file}. Ensure it is a valid video file.")
        
    return data['streams'][0]

def detect_interlace(input_file, frames=500):
    """Analyzes first X frames for interlacing artifacts using idet filter."""
    print(f"Analyzing first {frames} frames for interlacing...")
    cmd = [
        "ffmpeg", "-i", input_file,
        "-filter:v", "idet",
        "-frames:v", str(frames),
        "-an", "-f", "null", "-"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    match = re.search(r"Multi frame detection: TFF:\s*(\d+)\s*BFF:\s*(\d+)\s*Progressive:\s*(\d+)", result.stderr)
    
    if match:
        tff, bff, prog = map(int, match.groups())
        total = tff + bff + prog
        if total == 0: return "Unknown"
        
        if prog / total > 0.90:
            return "Progressive"
        elif tff > bff:
            return f"Interlaced (TFF detected: {tff}/{total})"
        else:
            return f"Interlaced (BFF detected: {bff}/{total})"
    return "Undetermined"

def check_bitrate_health(meta, input_file):
    """Determines if the file has enough data density for quality AI upscaling."""
    try:
        bitrate_bps = int(meta.get('bit_rate', 0))
        
        # FALLBACK: If bitrate is 0 (common in MTS), calculate from size/duration
        if bitrate_bps == 0:
            file_size_bits = os.path.getsize(input_file) * 8
            duration = float(meta.get('duration', 0))
            if duration > 0:
                bitrate_bps = file_size_bits / duration
            else:
                return "Unknown (Missing Metadata and Duration)"

        bitrate_mbps = bitrate_bps / 1_000_000
        
        # Updated Heuristics for HD/MTS content
        if bitrate_mbps > 15:
            return f"Excellent ({bitrate_mbps:.2f} Mbps) - High Detail Retention"
        elif bitrate_mbps > 5:
            return f"Good ({bitrate_mbps:.2f} Mbps) - Standard Digital Capture"
        elif bitrate_mbps > 1:
            return f"Fair ({bitrate_mbps:.2f} Mbps) - Compressed (Expect AI Artifacting)"
        else:
            return f"Poor ({bitrate_mbps:.2f} Mbps) - Heavily Compressed"
    except Exception as e:
        return f"Unknown Error: {e}"
        
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

        # Specific VHS Recommendations
        if "Poor" in quality_health or "Fair" in quality_health:
            print("⚠️  DATA WARNING: Low bitrate detected. AI upscaling (especially 4x)")
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
