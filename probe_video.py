#!/usr/bin/env python3
import subprocess
import re
import sys
import json
import argparse

def parse_args():
    parser = argparse.ArgumentParser(
        description="Probe video for VHS enhancement metadata and interlacing.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example:
  ./probe_video.py inputs/my_tape.avi
        """
    )
    parser.add_argument("input", help="Path to the video file to analyze.")
    
    # Automatically show help if no arguments are provided
    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
        sys.exit(1)
        
    return parser.parse_args()

def probe_metadata(input_file):
    """Fetches resolution, framerate, and pixel format using ffprobe."""
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,pix_fmt",
        "-of", "json",
        input_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    data = json.loads(result.stdout)
    return data['streams'][0]

def detect_interlace(input_file, frames=500):
    """Analyzes first X frames for interlacing artifacts using idet filter."""
    print(f"Analyzing first {frames} frames for interlacing (this takes a moment)...")
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

def main():
    args = parse_args()
    
    try:
        meta = probe_metadata(args.input)
        interlace_status = detect_interlace(args.input)

        print("\n--- Video Probe Report ---")
        print(f"File:        {args.input}")
        print(f"Resolution:  {meta['width']}x{meta['height']}")
        print(f"Frame Rate:  {meta['r_frame_rate']} fps")
        print(f"Pixel Format: {meta['pix_fmt']}")
        print(f"Scan Type:   {interlace_status}")
        print("--------------------------\n")

        if "Interlaced" in interlace_status:
            print("⚠️  RECOMMENDATION: This file appears interlaced.")
            print("   Add 'bwdif=0:-1:0' to your pre-filter chain.")
        else:
            print("✅ This file appears progressive.")

    except Exception as e:
        print(f"Error probing file: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
