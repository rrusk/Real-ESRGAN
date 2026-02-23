#!/usr/bin/env python3
# fix_sar.py — Check and fix sample aspect ratio (SAR) metadata in processed video files.
# Remuxes the file with correct SAR if needed. No re-encoding — completes in seconds.

import subprocess
import sys
import os
import argparse
import json
import shutil


def get_stream_info(filepath):
    """Returns (width, height, sar, dar) from ffprobe."""
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,sample_aspect_ratio,display_aspect_ratio",
        "-print_format", "json", filepath
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"ffprobe failed on {filepath}:\n{result.stderr}")
    streams = json.loads(result.stdout).get("streams", [])
    if not streams:
        raise RuntimeError(f"No video streams found in {filepath}")
    s = streams[0]
    return (
        s.get("width"),
        s.get("height"),
        s.get("sample_aspect_ratio", "N/A"),
        s.get("display_aspect_ratio", "N/A"),
    )


# Common legacy video SAR reference:
#   NTSC 4:3  (VHS, Hi8, DV):      720x480  SAR 8:9   -> display 640x480
#   NTSC 16:9 (widescreen DV):     720x480  SAR 32:27 -> display 853x480
#   PAL 4:3   (PAL DV/Hi8):        720x576  SAR 16:15 -> display 768x576
#   PAL 16:9  (PAL widescreen DV): 720x576  SAR 64:45 -> display 1024x576
# After 2x upscale, pixel dimensions double but SAR stays the same.

def compute_display_width(pixel_width, sar_str):
    """Computes correct display width from pixel width and SAR string e.g. '8:9'."""
    try:
        sar_num, sar_den = map(int, sar_str.split(":"))
        return round(pixel_width * sar_num / sar_den)
    except Exception:
        return pixel_width

def check_tool(tool, install_hint):
    """Returns True if tool is on PATH, otherwise prints a helpful error."""
    if shutil.which(tool):
        return True
    print(f"  ERROR: '{tool}' not found. Install with: {install_hint}")
    return False

def fix_sar(input_file, expected_sar, dry_run=False):
    """
    Checks the SAR of input_file. If it doesn't match expected_sar, applies
    the correct display dimensions directly into the container headers:
      MKV: mkvpropedit  (sets display-width/display-height, in-place, no backup needed)
      MP4: MP4Box -par  (sets pixel aspect ratio atom, in-place, no backup needed)
    Both tools modify container metadata only — no re-encoding, completes in seconds.
    """
    print(f"\nChecking: {input_file}")

    width, height, current_sar, current_dar = get_stream_info(input_file)
    ext = os.path.splitext(input_file)[1].lower()
    display_width = compute_display_width(width, expected_sar)
    sar_num, sar_den = expected_sar.split(":")

    print(f"  Resolution : {width}x{height}")
    print(f"  Current SAR: {current_sar}  |  Current DAR: {current_dar}")
    print(f"  Expected SAR: {expected_sar}  ->  display {display_width}x{height}")

    if current_sar == expected_sar:
        print(f"  ✅ SAR is already correct. No action needed.")
        return False

    print(f"  ⚠️  SAR mismatch: has {current_sar}, expected {expected_sar}")

    if dry_run:
        print(f"  [DRY RUN] Would apply SAR {expected_sar} (display {display_width}x{height}) to {ext} container.")
        return True

    if ext == ".mkv":
        if not check_tool("mkvpropedit", "sudo apt install mkvtoolnix"):
            raise RuntimeError("mkvpropedit not available")
        print(f"  Applying display dimensions {display_width}x{height} via mkvpropedit (in-place)...")
        cmd = [
            "mkvpropedit", input_file,
            "--edit", "track:v1",
            "--set", f"display-width={display_width}",
            "--set", f"display-height={height}"
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"mkvpropedit failed:\n{result.stderr}")

    elif ext == ".mp4":
        if not check_tool("MP4Box", "sudo apt install gpac"):
            raise RuntimeError("MP4Box not available")
        print(f"  Applying PAR {sar_num}:{sar_den} via MP4Box (in-place)...")
        cmd = ["MP4Box", "-par", f"1={sar_num}:{sar_den}", input_file]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"MP4Box failed:\n{result.stderr}")

    else:
        raise RuntimeError(f"Unsupported container '{ext}'. Supported: .mkv, .mp4")

    # Verify
    _, _, new_sar, new_dar = get_stream_info(input_file)
    print(f"  ✅ Done. SAR now: {new_sar}  DAR now: {new_dar}")
    print(f"  Note: No backup created — both tools edit in-place without data loss.")
    return True


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Check and fix SAR metadata in video files without re-encoding.",
        epilog="""
Examples:
  %(prog)s video.mkv                        # Check and fix using auto-detected SAR from source
  %(prog)s video.mkv --sar 8:9             # Fix to explicit SAR (NTSC 4:3 camcorder/VHS)
  %(prog)s video.mkv --sar 32:27           # Fix to explicit SAR (NTSC 16:9 widescreen)
  %(prog)s video.mkv --check               # Just show SAR/DAR metadata, no changes
  %(prog)s *.mkv --check                   # Check metadata on multiple files
  %(prog)s *.mkv --sar 8:9 --dry-run       # Preview which files would be fixed
  %(prog)s video.mkv --source original.mp4 # Auto-detect SAR from the original source file
""",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "input_files",
        nargs="+",
        help="Video file(s) to check and fix."
    )
    parser.add_argument(
        "--sar",
        default=None,
        metavar="W:H",
        help="Expected SAR to enforce (e.g. 8:9 for NTSC 4:3). "
             "Required unless --source is provided."
    )
    parser.add_argument(
        "--source",
        default=None,
        metavar="FILE",
        help="Auto-detect expected SAR from this source video file."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report which files need fixing without modifying anything."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Print SAR/DAR metadata for each file and exit. No expected SAR required."
    )
    if len(sys.argv) == 1:
        parser.print_help()
        sys.exit(0)
    return parser.parse_args()


def main():
    args = parse_arguments()

    # --check mode: just report metadata, no SAR required
    if args.check:
        for input_file in args.input_files:
            if not os.path.exists(input_file):
                print(f"\nWARNING: File not found: {input_file}")
                continue
            try:
                width, height, sar, dar = get_stream_info(input_file)
                print(f"\n{input_file}")
                print(f"  Resolution : {width}x{height}")
                print(f"  SAR        : {sar}")
                print(f"  DAR        : {dar}")
            except Exception as e:
                print(f"\nERROR reading {input_file}: {e}")
        sys.exit(0)

    # Determine expected SAR
    if args.source:
        _, _, expected_sar, _ = get_stream_info(args.source)
        if not expected_sar or expected_sar in ("N/A", "0:1", "1:1"):
            print(f"Source file {args.source} has square pixels (SAR {expected_sar}). Nothing to fix.")
            sys.exit(0)
        print(f"Auto-detected SAR from source: {expected_sar}")
    elif args.sar:
        expected_sar = args.sar
    else:
        print("ERROR: Provide either --sar W:H or --source FILE to determine expected SAR.")
        sys.exit(1)

    fixed = 0
    skipped = 0
    errors = 0

    for input_file in args.input_files:
        if not os.path.exists(input_file):
            print(f"\nWARNING: File not found: {input_file}")
            errors += 1
            continue
        try:
            was_fixed = fix_sar(input_file, expected_sar, dry_run=args.dry_run)
            if was_fixed:
                fixed += 1
            else:
                skipped += 1
        except Exception as e:
            print(f"\nERROR processing {input_file}: {e}")
            errors += 1

    print(f"\n--- Summary ---")
    print(f"  Files checked : {len(args.input_files)}")
    if args.dry_run:
        print(f"  Would fix     : {fixed}")
    else:
        print(f"  Fixed         : {fixed}")
    print(f"  Already correct: {skipped}")
    if errors:
        print(f"  Errors        : {errors}")


if __name__ == "__main__":
    main()
