#!/usr/bin/env python3
import ffmpeg
import os
import argparse
import sys
from datetime import datetime
from pathlib import Path


def check_venv():
    """Ensures the script is running inside the virtual environment."""
    # sys.prefix != sys.base_prefix is the standard way to detect a venv in Python 3
    if not (sys.prefix != sys.base_prefix or 'VIRTUAL_ENV' in os.environ):
        print("\n[!] ERROR: Virtual environment not detected.")
        print("    This script requires the project venv to ensure consistent tool versions.")
        print("    Please run: source venv/bin/activate")
        sys.exit(1)


def parse_args():
    # Use RawDescriptionHelpFormatter to preserve any custom formatting in the epilog
    parser = argparse.ArgumentParser(
        description="Extract a test clip from a video file for experimentation.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  ./extract_test_clip.py input.avi 00:05:00
  ./extract_test_clip.py input.mp4 00:12:30 -d 30 -o my_tests
        """
    )
    parser.add_argument("input", help="Path to the source video file.")
    parser.add_argument("start", help="Start time in HH:MM:SS or seconds (e.g., 00:10:45).")
    parser.add_argument("-d", "--duration", type=int, default=10, 
                        help="Duration of the clip in seconds (default: 10).")
    parser.add_argument("-o", "--outdir", default="outputs", 
                        help="Directory to save the clip (default: outputs).")

    # If no arguments are provided, or if essential arguments are missing, 
    # display the full help message instead of a generic error.
    if len(sys.argv) == 1:
        parser.print_help()
        sys.exit(0)
        
    return parser.parse_args()

def main():
    # --- 0. Pre-Flight Check ---
    check_venv()

    args = parse_args()
    
    # Ensure the output directory exists
    if not os.path.exists(args.outdir):
        print(f"Creating output directory: {args.outdir}")
        os.makedirs(args.outdir, exist_ok=True)

    # Construct the unambiguous filename
    input_stem = Path(args.input).stem
    safe_start = args.start.replace(":", "-")
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    
    filename = f"{input_stem}_start{safe_start}_dur{args.duration}s_{timestamp}.mp4"
    output_path = os.path.join(args.outdir, filename)

    print(f"--- Extracting Test Clip ---")
    print(f"Source:   {args.input}")
    print(f"Start:    {args.start}")
    print(f"Duration: {args.duration}s")
    print(f"Target:   {output_path}\n")

    try:
        # Use libmp3lame to ensure compatibility with existing pipeline logic
        (
            ffmpeg.input(args.input, ss=args.start, t=args.duration)
            .output(output_path, vcodec="libx264", acodec="libmp3lame")
            .overwrite_output()
            .run(capture_stdout=True, capture_stderr=True)
        )
        print(f"Successfully saved test clip.")
    except ffmpeg.Error as e:
        print("\n--- FFmpeg Error ---")
        print(e.stderr.decode())
        sys.exit(1)

if __name__ == "__main__":
    main()
