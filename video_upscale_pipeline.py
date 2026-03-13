#!/usr/bin/env python3
# video_upscale_pipeline.py - Upscale and interpolate legacy video (VHS, Hi8, DV camcorder, etc.)
# Uses Real-ESRGAN for upscaling and RIFE for frame interpolation.
import subprocess
import os
import shutil
import json
import math
import glob
import time
import sys
import argparse
from datetime import datetime, timedelta
import statistics

# --- Config ---
OUTPUT_DIR = "outputs"
RIFE_BIN = "./rife-ncnn-vulkan/rife-ncnn-vulkan"

# --- Auto-Tuning Config ---
MIN_CHUNK_SEC = 10
MAX_CHUNK_SEC = 120
DISK_SAFETY_MARGIN = 0.5
EST_PNG_COMP_RATIO = 0.4 

# --- Chunking Config ---
PROCESSING_DIR = "processing_chunks"
INPUT_CHUNKS_DIR = os.path.join(PROCESSING_DIR, "0_input_chunks")
ESRGAN_CHUNKS_DIR = os.path.join(PROCESSING_DIR, "1_esrgan_chunks")
RIFE_CHUNKS_DIR = os.path.join(PROCESSING_DIR, "2_rife_chunks")
CONCAT_FILE = os.path.join(PROCESSING_DIR, "concat_list.txt")
STOP_FILE = os.path.join(PROCESSING_DIR, "STOP")  # Touch this file to request a graceful stop after the current chunk
TEST_MODE_CHUNKS = None


# --- Helper Functions ---
class Timer:
    """Context manager for simple execution timing."""
    def __init__(self, name):
        self.name = name
    def __enter__(self):
        self.start = time.time()
        return self
    def __exit__(self, *args):
        self.end = time.time()
        duration = self.end - self.start
        print(f"   [Perf] {self.name} took {duration:.2f} seconds.")

def check_venv():
    """Ensures the script is running inside the virtual environment."""
    # sys.prefix != sys.base_prefix is the standard way to detect a venv in Python 3
    if not (sys.prefix != sys.base_prefix or 'VIRTUAL_ENV' in os.environ):
        print("\n[!] ERROR: Virtual environment not detected.")
        print("    This pipeline requires specific versions (e.g., numpy<2.0) found in venv.")
        print("    Please run: source venv/bin/activate")
        sys.exit(1)

def safe_rmtree(path):
    """Safely remove a directory tree."""
    if os.path.isdir(path):
        shutil.rmtree(path)

# --- Logging Helper ---
LOG_FILE = os.path.join(PROCESSING_DIR, "pipeline.log")

class TeeLogger:
    """
    Duplicate stdout to console + logfile.
    Resume-safe (append mode).
    """
    def __init__(self, logfile):
        self.terminal = sys.stdout
        os.makedirs(os.path.dirname(logfile), exist_ok=True)
        self.log = open(logfile, "a", buffering=1)
    def write(self, message):
        self.terminal.write(message)
        self.log.write(message)
    def flush(self):
        self.terminal.flush()
        self.log.flush()

def get_video_duration(video_file):
    cmd = [
        "ffprobe", "-v", "quiet", "-print_format", "json",
        "-show_format", video_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    duration = float(json.loads(result.stdout)["format"]["duration"])
    return duration

def get_video_sar(video_file):
    """
    Returns the sample aspect ratio (SAR) of the video as a string like '8:9' or '1:1'.
    Returns None if SAR is not set or is 1:1 (square pixels, no correction needed).
    Handles all common legacy formats:
      NTSC 4:3  (VHS/Hi8/DV):     720x480  SAR 8:9   -> display 640x480
      NTSC 16:9 (widescreen DV):  720x480  SAR 32:27 -> display 853x480
      PAL 4:3   (PAL DV/Hi8):     720x576  SAR 16:15 -> display 768x576
      PAL 16:9  (PAL widescreen): 720x576  SAR 64:45 -> display 1024x576
    """
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=sample_aspect_ratio",
        "-of", "default=noprint_wrappers=1:nokey=1",
        video_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    sar = result.stdout.strip()
    if not sar or sar in ("N/A", "0:1", "1:1"):
        return None
    return sar

def compute_display_width(pixel_width, pixel_height, sar_str):
    """
    Computes the correct display width from pixel dimensions and SAR string.
    e.g. pixel_width=1440, pixel_height=960, sar='8:9' -> display_width=1280
    Returns pixel_width unchanged if SAR is None or 1:1.
    """
    if not sar_str or sar_str in ("N/A", "0:1", "1:1"):
        return pixel_width
    try:
        sar_num, sar_den = map(int, sar_str.split(":"))
        return round(pixel_width * sar_num / sar_den)
    except Exception:
        return pixel_width

def apply_sar_to_file(filepath, sar_str, pixel_width, pixel_height):
    """
    Writes correct display dimensions into the container headers using the
    appropriate tool for the container type:
      MKV: mkvpropedit (sets display-width/display-height in track headers)
      MP4: MP4Box -par  (sets pixel aspect ratio atom)
    These tools write directly to container headers without re-encoding.
    Falls back with a warning if the required tool is not installed.
    """
    ext = os.path.splitext(filepath)[1].lower()
    display_width = compute_display_width(pixel_width, pixel_height, sar_str)
    sar_num, sar_den = sar_str.split(":")

    if ext == ".mkv":
        tool = "mkvpropedit"
        if not shutil.which(tool):
            print(f"  ⚠️  WARNING: {tool} not found. Install with: sudo apt install mkvtoolnix")
            print(f"  ⚠️  SAR metadata not written to {filepath}. Display may be incorrect.")
            return False
        cmd = [
            tool, filepath,
            "--edit", "track:v1",
            "--set", f"display-width={display_width}",
            "--set", f"display-height={pixel_height}"
        ]
        label = f"display {display_width}x{pixel_height}"
    elif ext == ".mp4":
        tool = "MP4Box"
        if not shutil.which(tool):
            print(f"  ⚠️  WARNING: {tool} not found. Install with: sudo apt install gpac")
            print(f"  ⚠️  SAR metadata not written to {filepath}. Display may be incorrect.")
            return False
        cmd = [tool, "-par", f"1={sar_num}:{sar_den}", filepath]
        label = f"PAR {sar_num}:{sar_den}"
    else:
        print(f"  ⚠️  WARNING: Unsupported container {ext} for SAR fix. Skipping.")
        return False

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  ⚠️  WARNING: SAR fix failed for {filepath}:")
        print(f"    {result.stderr.strip()}")
        return False

    print(f"  > SAR fix applied ({label}) to {os.path.basename(filepath)}")
    return True

def verify_audio_video_duration(video_file, audio_file, tolerance_sec=2.0):
    """
    Compares audio and video durations and aborts if they differ beyond tolerance.
    Catches silent extraction failures (truncation, codec errors) before processing begins.
    """
    print(f"  > Verifying audio/video duration match...")
    try:
        video_duration = get_video_duration(video_file)

        cmd_audio = [
            "ffprobe", "-v", "quiet", "-print_format", "json",
            "-show_streams", "-show_format", "-select_streams", "a:0", audio_file
        ]
        result = subprocess.run(cmd_audio, capture_output=True, text=True, check=True)
        probe = json.loads(result.stdout)
        streams = probe.get("streams", [])
        if not streams:
            raise RuntimeError("ffprobe found no audio streams in extracted audio file.")
        # Stream-level duration is absent for some codecs (e.g. AC-3 in MKA);
        # fall back to container-level format duration which is always present.
        stream_duration = streams[0].get("duration")
        format_duration = probe.get("format", {}).get("duration")
        raw = stream_duration or format_duration
        if raw is None:
            raise RuntimeError("ffprobe could not determine audio duration from stream or container.")
        audio_duration = float(raw)

        diff = abs(video_duration - audio_duration)
        print(f"    Video: {video_duration:.1f}s  |  Audio: {audio_duration:.1f}s  |  Diff: {diff:.1f}s  (tolerance: ±{tolerance_sec}s)")

        if diff > tolerance_sec:
            raise RuntimeError(
                f"Audio/video duration mismatch: video={video_duration:.1f}s, "
                f"audio={audio_duration:.1f}s, diff={diff:.1f}s exceeds ±{tolerance_sec}s tolerance.\n"
                f"Delete the audio file and re-run to force re-extraction:\n"
                f"  rm '{audio_file}'"
            )
        print(f"    Duration check passed.")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"ffprobe failed during duration check: {e.stderr}")

def is_valid_video(filepath):
    """
    Probes a video file with ffprobe to confirm it has a readable video stream.
    Catches corrupt files (e.g. missing moov atom) that have non-zero size but
    are unplayable due to an interrupted write.
    """
    try:
        cmd = [
            "ffprobe", "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_type",
            "-of", "default=noprint_wrappers=1:nokey=1",
            filepath
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return result.returncode == 0 and result.stdout.strip() == "video"
    except Exception:
        return False

def get_video_fps(video_file):
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=r_frame_rate",
        "-of", "default=noprint_wrappers=1:nokey=1",
        video_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    fps_str = result.stdout.strip()

    if not fps_str or fps_str == "0/0":
        print("Warning: Could not detect r_frame_rate, falling back to avg_frame_rate.")
        cmd = [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=avg_frame_rate",
            "-of", "default=noprint_wrappers=1:nokey=1",
            video_file
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        fps_str = result.stdout.strip()
        
    if not fps_str or fps_str == "0/0":
        raise RuntimeError(f"Could not detect FPS for {video_file}")

    if "/" in fps_str:
        try:
            num, den = map(float, fps_str.split('/'))
            if den == 0:
                raise ValueError("Denominator is zero")
            fps_val = num / den
            return f"{fps_val:.3f}"
        except Exception as e:
            raise RuntimeError(f"Could not parse FPS fraction '{fps_str}'. Error: {e}")
    else:
        return fps_str

def get_video_dimensions(video_file):
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height",
        "-of", "csv=s=x:p=0",
        video_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    try:
        w, h = map(int, result.stdout.strip().split('x'))
        return w, h
    except Exception as e:
        raise RuntimeError(f"Could not parse video dimensions. Output: '{result.stdout}'. Error: {e}")

def check_disk_space(path, required_gb):
    total, used, free = shutil.disk_usage(path)
    free_gb = free / (1024**3)
    print(f"Disk Check: {free_gb:.2f} GB free at {path}")
    if free_gb < required_gb:
        raise RuntimeError(
            f"Insufficient disk space! Need {required_gb} GB, "
            f"but only {free_gb:.2f} GB is available at {path}."
        )
    return free_gb

def cleanup_intermediate_files(input_chunk, esrgan_file, rife_in_dir, rife_out_dir):
    """Cleans up all temporary files for a chunk."""
    if os.path.exists(input_chunk):
        print(f"  > Cleaning up input chunk: {input_chunk}")
        os.remove(input_chunk)
    if os.path.exists(esrgan_file):
        print(f"  > Cleaning up ESRGAN file: {esrgan_file}")
        os.remove(esrgan_file)
    
    print(f"  > Cleaning up RIFE input frames: {rife_in_dir}")
    safe_rmtree(rife_in_dir)

    print(f"  > Cleaning up RIFE output frames: {rife_out_dir}")
    safe_rmtree(rife_out_dir)

def autotune_chunk_size(input_video_path, scale_factor):
    """Calculates optimal chunk size based on free disk and video properties."""
    print("--- Auto-Tuning Chunk Size ---")
    try:
        free_disk_gb = check_disk_space(".", 10)
        in_width, in_height = get_video_dimensions(input_video_path)
        out_width = in_width * scale_factor
        out_height = in_height * scale_factor
        print(f"Input res: {in_width}x{in_height}, Upscaled res: {out_width}x{out_height}")

        fps = float(get_video_fps(input_video_path))
        
        bytes_per_pixel = 3
        pixels = out_width * out_height
        est_png_mb = (pixels * bytes_per_pixel * EST_PNG_COMP_RATIO) / (1024**2)
        print(f"Estimated PNG frame size: {est_png_mb:.2f} MB")

        pngs_per_sec = fps * 2
        mb_per_sec = pngs_per_sec * est_png_mb
        print(f"Estimated temp disk usage per sec: {mb_per_sec:.2f} MB/s")

        usable_temp_gb = free_disk_gb * DISK_SAFETY_MARGIN
        print(f"Reserving {usable_temp_gb:.2f} GB (50%) for temp files.")
        
        max_chunk_sec_disk = (usable_temp_gb * 1024) / mb_per_sec
        print(f"Disk capacity allows for {max_chunk_sec_disk:.0f} second chunks.")

        final_chunk_sec = max(MIN_CHUNK_SEC, min(max_chunk_sec_disk, MAX_CHUNK_SEC))
        
        print(f"Clamped to {final_chunk_sec:.0f} seconds (Min: {MIN_CHUNK_SEC}s, Max: {MAX_CHUNK_SEC}s)")
        print("--------------------------------")
        return int(final_chunk_sec)

    except Exception as e:
        print(f"WARNING: Auto-tuning failed ({e}). Falling back to safe 10s chunks.")
        print("--------------------------------")
        return 10

def parse_arguments():
    """Parses command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Upscale and interpolate legacy video files (VHS, Hi8, DV camcorder, etc.).",
        epilog="""
Examples:
  %(prog)s video.avi                          # 2x upscale, balanced profile (default)
  %(prog)s video.avi --scale 4               # 4x upscale, balanced profile
  %(prog)s video.avi -s 4 --force            # 4x upscale, no cleanup prompt
  %(prog)s video.avi --profile aggressive    # heavy denoise for noisy/composite sources
  %(prog)s video.avi --profile halo          # halo/ringing suppression
  %(prog)s video.avi --profile dv            # optimised for MiniDV/Digital8/DV AVI sources
  %(prog)s camcorder.mp4                     # works with DV, Hi8, and other camcorder formats

Pre-filter profiles (--profile):
  balanced   Default. Hi8/S-Video capture -> DVD (~4.6Mbps).   hqdn3d=2:2:6:6,     pp=fd, unsharp=3:3:0.2
  aggressive Heavy noise, composite captures, low-bitrate DVD. hqdn3d=3:3:6:6,     pp=ac, unsharp=3:3:0.6
  halo       White ghost lines / ringing around dark edges.    hqdn3d=4:4:8:8,     pp=fd, unsharp=3:3:0.2
  dv         MiniDV / Digital8 / DV AVI sources.               hqdn3d=1.5:1.5:4:4, pp=ac, unsharp=3:3:0.25
""",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("input_video", help="Path to the input AVI/MP4/MKV video file.")
    parser.add_argument(
        "-s", "--scale", 
        type=int, 
        choices=[2, 4], 
        default=2, 
        help="Upscale factor: 2 (for RealESRGAN_x2plus) or 4 (for RealESRGAN_x4plus). Default: 2"
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=None,
        help="Number of FFmpeg threads (default: half of logical CPU cores, minimum 4)"
    )
    parser.add_argument(
        "-f", "--force", 
        action="store_true", 
        help="Force deletion of old processing chunks without prompting."
    )
    parser.add_argument(
        "--profile",
        choices=["balanced", "aggressive", "halo", "dv"],
        default="balanced",
        help=(
            "Pre-filter profile (default: balanced). "
            "balanced:   Hi8/S-Video capture -> DVD (~4.6Mbps source). Light denoise, temporal 6:6 stability, fast deblock, minimal sharpen. "
            "aggressive: Heavy noise, composite captures, or low-bitrate DVD. Stronger denoise, full deblock+dering, more sharpen. "
            "halo:       White ghost lines around dark edges. Heavy denoise, fast deblock, minimal sharpen. "
            "dv:         MiniDV/Digital8/DV AVI. Lighter denoise, stronger deblock+dering, gentle sharpen."
        )
    )
    parser.add_argument(
        "--max-runtime",
        type=float,
        default=None,
        metavar="HOURS",
        help="Maximum runtime in hours before graceful shutdown. Script will not start a new chunk if (elapsed time + last chunk duration) would exceed this limit. Example: --max-runtime 8"
    )
    return parser.parse_args()

def main(args):
    """Main processing pipeline."""
    # --- 0. Pre-Flight Checks ---
    check_venv()

    # Enable tee logging from the very start (captures all startup messages)
    sys.stdout = TeeLogger(LOG_FILE)
    print(f"\n--- Pipeline started {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')} | Logging to {LOG_FILE} ---\n")
    
    # --- 1. Set up variables based on args ---
    INPUT_VIDEO = args.input_video
    SCALE_FACTOR = args.scale
    # Detect extension to support both .avi and .mp4
    INPUT_EXT = os.path.splitext(INPUT_VIDEO)[1]
    
    # --- Pre-filter Profile Selection ---
    # Selected via --profile. Default: balanced.
    # Filter chains are defined in PROFILES; adding a new profile is a one-line change.
    #
    #   balanced   hqdn3d=2:2:6:6, pp=fd, unsharp=3:3:0.2
    #     Light spatial denoise preserves texture for ESRGAN. Temporal at 6:6 stabilises
    #     frame-to-frame flicker without touching real detail. pp=fd handles DVD
    #     macroblocking. Minimal sharpening avoids pre-upscale halos.
    #     Tuned for Hi8/S-Video capture -> DVD (~4.6Mbps source). Note: the
    #     deinterlaced master produced by prepare_video.sh will be ~6.5Mbps;
    #     the relevant quality level is the DVD source, not the master.
    #
    #   aggressive hqdn3d=3:3:6:6, pp=ac, unsharp=3:3:0.6
    #     Stronger denoise and sharpening for heavy noise or composite-captured sources.
    #     pp=ac full deblock+dering suited to low-bitrate DVD or VHS via composite.
    #
    #   halo       hqdn3d=4:4:8:8, pp=fd, unsharp=3:3:0.2
    #     Heavy denoise suppresses source ringing that ESRGAN would otherwise amplify.
    #     Use only if you see white ghost lines around dark edges in output.
    #
    #   dv         hqdn3d=1.5:1.5:4:4, pp=ac, unsharp=3:3:0.25
    #     DV compression produces DCT block noise and mosquito ringing rather than
    #     analog grain. Lighter spatial denoise preserves genuine DV detail; pp=ac
    #     targets block/ringing artifacts; moderate temporal smoothing handles
    #     low-light flicker without over-filtering clean digital footage.

    PROFILES = {
        "balanced":   "hqdn3d=2:2:6:6,pp=fd,unsharp=3:3:0.2",
        "aggressive": "hqdn3d=3:3:6:6,pp=ac,unsharp=3:3:0.6",
        "halo":       "hqdn3d=4:4:8:8,pp=fd,unsharp=3:3:0.2",
        "dv":         "hqdn3d=1.5:1.5:4:4,pp=ac,unsharp=3:3:0.25",
    }

    profile = args.profile
    prefilter_vf = PROFILES[profile]

    profile_descriptions = {
        "balanced":   "Light spatial denoise, temporal 6:6 for flicker stability, fast deblock, minimal sharpen. "
                      "Optimised for Hi8/S-Video capture -> DVD (~4.6Mbps source).",
        "aggressive": "Strong denoise, full deblock+dering, more sharpen. "
                      "Recommended for heavy noise, composite captures, or low-bitrate DVD sources.",
        "halo":       "Heavy denoise, fast deblock, minimal sharpen. "
                      "Use if you see white ghost lines around dark edges.",
        "dv":         "Light spatial denoise, moderate temporal smoothing, full deblock+dering, gentle sharpen. "
                      "Optimised for MiniDV / Digital8 / DV AVI sources.",
    }
    print(f"   [Profile] {profile}: {profile_descriptions[profile]}")

    # Calculate FFmpeg thread count
    if args.threads and args.threads > 0:
        threads = args.threads
    else:
        cpu_count = os.cpu_count() or 4
        threads = max(4, cpu_count // 2)
    print(f"[INFO] Using {threads} FFmpeg threads")

    if not os.path.exists(INPUT_VIDEO):
        print(f"Error: Input video not found at: {INPUT_VIDEO}")
        sys.exit(1)

    if SCALE_FACTOR == 2:
        REALSRGAN_MODEL = "RealESRGAN_x2plus"
    elif SCALE_FACTOR == 4:
        REALSRGAN_MODEL = "RealESRGAN_x4plus"
    
    input_basename = os.path.splitext(os.path.basename(INPUT_VIDEO))[0]
    FINAL_VIDEO_FILE = os.path.join(OUTPUT_DIR, f"{input_basename}_x{SCALE_FACTOR}_rife_FINAL.mkv")
    ORIGINAL_AUDIO_FILE = os.path.join(PROCESSING_DIR, f"{input_basename}_original.mka")  # .mka accepts any codec (AC-3, AAC, PCM, MP3)
    ORIGINAL_AUDIO_FILE_MP3 = os.path.join(PROCESSING_DIR, f"{input_basename}_original.mp3")  # fallback path

    print(f"--- Starting processing for: {INPUT_VIDEO} ---")
    print(f"Detected Input Extension: {INPUT_EXT}")
    print(f"Selected Scale Factor: {SCALE_FACTOR}x")
    print(f"Selected Model: {REALSRGAN_MODEL}")
    print(f"Final Output File: {FINAL_VIDEO_FILE}")

    # --- Check if processing_chunks contains data from a different video/scale ---
    metadata_file = os.path.join(PROCESSING_DIR, "metadata.json")
    current_metadata = {
        "input_video": os.path.abspath(INPUT_VIDEO),
        "scale_factor": SCALE_FACTOR,
        "profile": profile,
    }
    
    if os.path.exists(metadata_file):
        try:
            with open(metadata_file, 'r') as f:
                old_metadata = json.load(f)
            
            if old_metadata != current_metadata:
                print(f"\n⚠️  WARNING: processing_chunks contains data from a different job:")
                print(f"  Old: {old_metadata}")
                print(f"  New: {current_metadata}")
                
                if args.force:
                    print("Deleting old chunks... (--force specified)")
                    safe_rmtree(PROCESSING_DIR)
                else:
                    response = input("Delete old chunks and start fresh? (y/n): ")
                    if response.lower() == 'y':
                        print("Deleting old chunks...")
                        safe_rmtree(PROCESSING_DIR)
                    else:
                        print("Exiting to avoid mixing chunks from different videos.")
                        sys.exit(1)
        except Exception as e:
            print(f"WARNING: Could not read metadata file. Deleting processing_chunks. Error: {e}")
            safe_rmtree(PROCESSING_DIR)
    
    # Save current metadata (includes input_video, scale_factor, profile)
    os.makedirs(PROCESSING_DIR, exist_ok=True)
    with open(metadata_file, 'w') as f:
        json.dump(current_metadata, f, indent=4)
    # --- End of metadata check ---

    # --- Step 0: Setup, Auto-Tune, and Splitting ---
    print("\n--- 0. Setup and Splitting ---")
    CHUNK_DURATION_SECONDS = autotune_chunk_size(INPUT_VIDEO, SCALE_FACTOR)

    os.makedirs(INPUT_CHUNKS_DIR, exist_ok=True)
    os.makedirs(ESRGAN_CHUNKS_DIR, exist_ok=True)
    os.makedirs(RIFE_CHUNKS_DIR, exist_ok=True)
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    duration = get_video_duration(INPUT_VIDEO)
    source_fps_str = get_video_fps(INPUT_VIDEO)
    source_fps_float = float(source_fps_str)
    output_fps_float = source_fps_float * 2
    source_sar = get_video_sar(INPUT_VIDEO)
    if source_sar:
        print(f"Source SAR detected: {source_sar} (non-square pixels — will be preserved in final output.)")
    else:
        print(f"Source SAR: 1:1 (square pixels)")
    total_chunks = math.ceil(duration / CHUNK_DURATION_SECONDS)
    print(f"Video detected: {duration:.2f}s, {source_fps_str} FPS.")
    print(f"Using {CHUNK_DURATION_SECONDS}s chunks, splitting into {total_chunks} total chunks.")
    print(f"RIFE output will be {output_fps_float:.3f} FPS.")

    # Also accept a previously extracted .mp3 fallback from an earlier run
    if os.path.exists(ORIGINAL_AUDIO_FILE_MP3) and os.path.getsize(ORIGINAL_AUDIO_FILE_MP3) > 0:
        ORIGINAL_AUDIO_FILE = ORIGINAL_AUDIO_FILE_MP3
        print(f"Original audio already exists (MP3 fallback): {ORIGINAL_AUDIO_FILE}")
        verify_audio_video_duration(INPUT_VIDEO, ORIGINAL_AUDIO_FILE)
    elif not os.path.exists(ORIGINAL_AUDIO_FILE) or os.path.getsize(ORIGINAL_AUDIO_FILE) == 0:
        print(f"Extracting original audio to {ORIGINAL_AUDIO_FILE}...")
        # Attempt lossless passthrough first (preserves original codec, instant)
        audio_copy_ok = False
        try:
            cmd_audio_copy = [
                "ffmpeg", "-y", "-i", INPUT_VIDEO,
                "-vn", "-c:a", "copy",
                ORIGINAL_AUDIO_FILE
            ]
            subprocess.run(cmd_audio_copy, check=True, capture_output=True, text=True)
            if os.path.exists(ORIGINAL_AUDIO_FILE) and os.path.getsize(ORIGINAL_AUDIO_FILE) > 0:
                audio_copy_ok = True
                print(f"  > Audio extracted via stream copy (lossless).")
            else:
                print(f"  > Audio copy produced empty file, falling back to MP3 encode...")
        except subprocess.CalledProcessError as e:
            print(f"  > Audio copy failed (codec not compatible with output container), falling back to MP3 encode...")

        if not audio_copy_ok:
            # Fallback: re-encode to MP3 (handles any input codec)
            try:
                cmd_audio_mp3 = [
                    "ffmpeg", "-y", "-i", INPUT_VIDEO,
                    "-vn", "-acodec", "libmp3lame", "-q:a", "0",  # q:a 0 = highest VBR quality (~245kbps), handles Hi8/DV fidelity
                    ORIGINAL_AUDIO_FILE_MP3
                ]
                subprocess.run(cmd_audio_mp3, check=True, capture_output=True, text=True)
                ORIGINAL_AUDIO_FILE = ORIGINAL_AUDIO_FILE_MP3  # point to the actual file produced
                print(f"  > Audio extracted via MP3 encode fallback (q:a 0, ~245kbps VBR).")
            except subprocess.CalledProcessError as e:
                print(f"\n--- ERROR: FFmpeg audio extraction failed (both copy and MP3 encode) ---")
                print("STDOUT:", e.stdout)
                print("STDERR:", e.stderr)
                raise

        if not os.path.exists(ORIGINAL_AUDIO_FILE) or os.path.getsize(ORIGINAL_AUDIO_FILE) == 0:
            raise RuntimeError(f"Audio extraction failed to produce a valid file: {ORIGINAL_AUDIO_FILE}")
        verify_audio_video_duration(INPUT_VIDEO, ORIGINAL_AUDIO_FILE)
    else:
        print(f"Original audio already exists: {ORIGINAL_AUDIO_FILE}")
        verify_audio_video_duration(INPUT_VIDEO, ORIGINAL_AUDIO_FILE)


    # Use dynamic extension for chunk file pattern
    chunk_file_pattern = os.path.join(INPUT_CHUNKS_DIR, f"chunk_%03d{INPUT_EXT}")
    if not os.path.exists(os.path.join(INPUT_CHUNKS_DIR, f"chunk_000{INPUT_EXT}")):
        print(f"Splitting video into chunks (video only, extension {INPUT_EXT})...")
        cmd_split = [
            "ffmpeg", "-i", INPUT_VIDEO, 
            "-an", "-c:v", "copy", "-map", "0:v",
            "-segment_time", str(CHUNK_DURATION_SECONDS),
            "-f", "segment", "-reset_timestamps", "1",
            chunk_file_pattern
        ]
        subprocess.run(cmd_split, check=True)
    else:
        print("Chunks already exist, skipping split.")

    # --- Steps 1 & 2: Process Chunks in a Loop ---
    print("\n--- 1. & 2. Processing All Chunks ---")

    # Clear any stale STOP file left over from a previous session (e.g. a session
    # that hit the runtime limit before it could reach the STOP-file check).
    if os.path.exists(STOP_FILE):
        os.remove(STOP_FILE)
        print(f"[INFO] Removed stale STOP file from previous session: {STOP_FILE}")

    total_start_time = time.time()
    chunks_to_process = total_chunks
    chunk_durations = []  # Rolling history for median ETA
    if TEST_MODE_CHUNKS is not None:
        chunks_to_process = min(total_chunks, TEST_MODE_CHUNKS)
        print(f"*** TEST MODE: Only processing {chunks_to_process} chunk(s) ***")

    for i in range(chunks_to_process):
        chunk_name = f"chunk_{i:03d}"
        chunk_start_time = time.time()
        local_start = datetime.now().astimezone()
        elapsed_hours = (chunk_start_time - total_start_time) / 3600
        print(f"\nProcessing Chunk {i+1} / {total_chunks} ({chunk_name})")
        print(f"  > Started at: {local_start.strftime('%Y-%m-%d %H:%M:%S %Z')}")
        if chunk_durations:
            chunk_eta = local_start + timedelta(seconds=statistics.median(chunk_durations))
            print(f"  > Estimated completion: {chunk_eta.strftime('%Y-%m-%d %H:%M:%S %Z')} (median {statistics.median(chunk_durations)/3600:.2f}h)")
        else:
            print(f"  > Estimated completion: unknown (first chunk)")
        print(f"  > Project elapsed: {elapsed_hours:.2f}h")
        print(f"  > To stop after this chunk: touch {STOP_FILE}")

        # Use dynamic extension for input chunks
        input_chunk = os.path.join(INPUT_CHUNKS_DIR, f"{chunk_name}{INPUT_EXT}")
        esrgan_temp_work_dir = os.path.join(ESRGAN_CHUNKS_DIR, f"{chunk_name}_temp_work")
        esrgan_output_file = os.path.join(ESRGAN_CHUNKS_DIR, f"{chunk_name}_esrgan.mp4")
        
        rife_in_frames_dir = os.path.join(ESRGAN_CHUNKS_DIR, f"{chunk_name}_rife_in_frames")
        rife_out_frames_dir = os.path.join(RIFE_CHUNKS_DIR, f"{chunk_name}_rife_out_frames")
        rife_output_file = os.path.join(RIFE_CHUNKS_DIR, f"{chunk_name}_rife.mp4")

        if os.path.exists(rife_output_file) and os.path.getsize(rife_output_file) > 0:
            if is_valid_video(rife_output_file):
                print(f"  > Chunk already processed. Skipping.")
                cleanup_intermediate_files(input_chunk, esrgan_output_file, rife_in_frames_dir, rife_out_frames_dir)
                continue
            else:
                print(f"  > WARNING: {rife_output_file} exists but is corrupt (missing moov atom or no video stream). Reprocessing.")
                os.remove(rife_output_file)
        
        if not os.path.exists(input_chunk):
            print(f"  > WARNING: Input chunk {input_chunk} missing. Skipping.")
            continue

        # --- Step 1: Run Real-ESRGAN ---
        if os.path.exists(esrgan_output_file) and os.path.getsize(esrgan_output_file) > 0 and not is_valid_video(esrgan_output_file):
            print(f"  > WARNING: {esrgan_output_file} is corrupt. Deleting and reprocessing from ESRGAN.")
            os.remove(esrgan_output_file)
            safe_rmtree(esrgan_temp_work_dir)
        if not os.path.exists(esrgan_output_file) or os.path.getsize(esrgan_output_file) == 0:
            
            os.makedirs(esrgan_temp_work_dir, exist_ok=True)

            print(f"  > Pre-filtering (denoise, deblock, sharpen)...")
            prefiltered_chunk = os.path.join(esrgan_temp_work_dir, f"{chunk_name}_prefiltered.mp4")
            cmd_prefilter = [
                "ffmpeg", "-y",
                "-i", input_chunk,
                "-vf", prefilter_vf, # "hqdn3d=3:3:6:6,pp=ac,unsharp=3:3:0.6",
                "-c:v", "libx264", "-threads", str(threads), "-crf", "16", # <-- Quality Fix: CRF 16 for master fidelity
                "-preset", "slower", # <-- Quality Fix: 'slower' for maximum detail
                "-pix_fmt", "yuv420p",
                prefiltered_chunk
            ]
            try:
                with Timer(f"{chunk_name} Pre-filter"):
                    subprocess.run(cmd_prefilter, check=True, capture_output=True, text=True)
            except subprocess.CalledProcessError as e:
                print(f"\n--- ERROR: FFmpeg pre-filtering failed on {chunk_name} ---")
                print("STDOUT:", e.stdout)
                print("STDERR:", e.stderr)
                raise

            if not is_valid_video(prefiltered_chunk):
                raise RuntimeError(f"Pre-filter produced a corrupt output file: {prefiltered_chunk}")

            print(f"  > Running Real-ESRGAN...")
            cmd_realesrgan = [
                "python3", "inference_realesrgan_video.py",
                "-i", prefiltered_chunk, 
                "-n", REALSRGAN_MODEL,
                "-o", esrgan_temp_work_dir, "-s", str(SCALE_FACTOR),
                "--fps", source_fps_str,
            ]
            try:
                with Timer(f"{chunk_name} ESRGAN Inference"):
                    subprocess.run(cmd_realesrgan, check=True, capture_output=True, text=True)
            except subprocess.CalledProcessError as e:
                print(f"\n--- ERROR: Real-ESRGAN failed on {chunk_name} ---")
                print("STDOUT:", e.stdout)
                print("STDERR:", e.stderr)
                raise
            
            mp4_files = glob.glob(os.path.join(esrgan_temp_work_dir, "*.mp4"))
            output_candidates = glob.glob(os.path.join(esrgan_temp_work_dir, "*_out.mp4"))

            if not output_candidates:
                output_candidates = [f for f in mp4_files if f != prefiltered_chunk]

            if len(output_candidates) == 1:
                os.rename(output_candidates[0], esrgan_output_file)
            elif len(output_candidates) == 0:
                raise RuntimeError(f"Real-ESRGAN did not produce an output file in {esrgan_temp_work_dir}. Found files: {mp4_files}")
            else:
                raise RuntimeError(f"Expected 1 output MP4, found {len(output_candidates)}. Candidates: {output_candidates}")
            
            safe_rmtree(esrgan_temp_work_dir)
            print(f"  > Real-ESRGAN complete: {esrgan_output_file}")
        else:
            print(f"  > Found existing Real-ESRGAN output, skipping to RIFE.")

        # --- Step 2: Run RIFE (Multi-Step) ---
        # Check if RIFE input frames already exist and are complete
        existing_in_frames = glob.glob(os.path.join(rife_in_frames_dir, "*.png")) if os.path.isdir(rife_in_frames_dir) else []
        if existing_in_frames:
            print(f"  > Found {len(existing_in_frames)} existing RIFE input frames, skipping extraction.")
        else:
            print(f"  > Extracting frames for RIFE...")
            os.makedirs(rife_in_frames_dir, exist_ok=True)
            cmd_extract = [
                "ffmpeg", "-i", esrgan_output_file,
                os.path.join(rife_in_frames_dir, "frame_%08d.png")
            ]
            try:
                with Timer(f"{chunk_name} RIFE Frame Extraction"):
                    subprocess.run(cmd_extract, check=True, capture_output=True, text=True)
            except subprocess.CalledProcessError as e:
                print(f"\n--- ERROR: FFmpeg frame extraction failed on {chunk_name} ---")
                print("STDOUT:", e.stdout)
                print("STDERR:", e.stderr)
                raise

        in_frames = glob.glob(os.path.join(rife_in_frames_dir, "*.png"))
        existing_out_frames = glob.glob(os.path.join(rife_out_frames_dir, "*.png")) if os.path.isdir(rife_out_frames_dir) else []
        expected_out = len(in_frames) * 2
        if len(existing_out_frames) >= expected_out - 2:
            print(f"  > Found {len(existing_out_frames)} existing RIFE output frames (expected ~{expected_out}), skipping interpolation.")
            out_frames = existing_out_frames
        else:
            if existing_out_frames:
                print(f"  > WARNING: Found only {len(existing_out_frames)}/{expected_out} RIFE output frames (partial). Wiping and re-interpolating.")
                safe_rmtree(rife_out_frames_dir)
            print(f"  > Running RIFE (directory mode)...")
            os.makedirs(rife_out_frames_dir, exist_ok=True)
            cmd_rife = [ 
                RIFE_BIN, 
                "-i", rife_in_frames_dir, 
                "-o", rife_out_frames_dir,
                "-s", "0.5"
            ]
            try:
                with Timer(f"{chunk_name} RIFE Interpolation"):
                    subprocess.run(cmd_rife, check=True, capture_output=True, text=True)
            except subprocess.CalledProcessError as e:
                print(f"\n--- ERROR: RIFE failed on {chunk_name} ---")
                print("STDOUT:", e.stdout)
                print("STDERR:", e.stderr)
                raise
            out_frames = glob.glob(os.path.join(rife_out_frames_dir, "*.png"))

        print("  > Verifying RIFE frame count...")
        out_frames = glob.glob(os.path.join(rife_out_frames_dir, "*.png"))
        
        if len(out_frames) < len(in_frames) * 2 - 2:
            raise RuntimeError(
                f"RIFE failed to double frames! "
                f"Input: {len(in_frames)} frames, "
                f"Output: {len(out_frames)} frames."
            )
        print(f"  > RIFE check passed (Input: {len(in_frames)}, Output: {len(out_frames)}).")

        print(f"  > Encoding RIFE frames to video...")
        cmd_encode = [
            "ffmpeg",
            "-framerate", str(output_fps_float),
            "-i", os.path.join(rife_out_frames_dir, "%08d.png"),
            "-c:v", "libx264",
            "-threads", str(threads),
            "-pix_fmt", "yuv420p",
            "-crf", "17", # <-- Quality Fix: CRF 17 for high-bitrate 4K assembly
            "-preset", "slower", # <-- Quality Fix: 'slower' for maximum fidelity
            rife_output_file
        ]
        try:
            with Timer(f"{chunk_name} RIFE Frame Encoding"):
                subprocess.run(cmd_encode, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            print(f"\n--- ERROR: FFmpeg frame encoding failed on {chunk_name} ---")
            print("STDOUT:", e.stdout)
            print("STDERR:", e.stderr)
            raise

        print(f"  > RIFE complete: {rife_output_file}")

        # --- CRITICAL: Aggressive Cleanup ---
        cleanup_intermediate_files(input_chunk, esrgan_output_file, rife_in_frames_dir, rife_out_frames_dir)
        
        chunk_end_time = time.time()
        duration_sec = chunk_end_time - chunk_start_time
        local_end = datetime.now().astimezone()
        chunk_durations.append(duration_sec)

        # Rolling median ETA (stable across noisy chunks)
        median_sec = statistics.median(chunk_durations)
        chunks_remaining = total_chunks - (i + 1)
        eta_project = local_end + timedelta(seconds=median_sec * chunks_remaining)

        print(f"  > Chunk finished in {duration_sec:.2f} seconds.")
        print(f"  > Finished at: {local_end.strftime('%Y-%m-%d %H:%M:%S %Z')}")
        next_eta = local_end + timedelta(seconds=median_sec)
        print(f"  > Next chunk ETA (median): {next_eta.strftime('%Y-%m-%d %H:%M:%S %Z')}")
        if chunks_remaining > 0:
            print(f"  > Project completion ETA: {eta_project.strftime('%Y-%m-%d %H:%M:%S %Z')} "
                  f"({chunks_remaining} chunks × {median_sec/3600:.2f}h median)")
        
        # --- Runtime Limit Check ---
        if args.max_runtime is not None:
            elapsed_hours = (chunk_end_time - total_start_time) / 3600
            median_hours = median_sec / 3600
            max_runtime_hours = args.max_runtime
            
            # Check if we should continue to the next chunk
            if i + 1 < chunks_to_process:  # Only check if there are more chunks
                projected_hours = elapsed_hours + median_hours
                
                print(f"\n  [Runtime Check]")
                print(f"    Elapsed: {elapsed_hours:.2f}h / {max_runtime_hours:.2f}h")
                print(f"    Last chunk: {duration_sec/3600:.2f}h  |  Median: {median_hours:.2f}h")
                print(f"    Projected next completion: {projected_hours:.2f}h")
                
                if projected_hours > max_runtime_hours:
                    print(f"\n  ⏸️  GRACEFUL SHUTDOWN: Would exceed {max_runtime_hours}h runtime limit.")
                    print(f"    Processed {i+1}/{total_chunks} chunks successfully.")
                    print(f"    Resume anytime - script will continue from chunk {i+1}.")
                    # Remove any STOP file so it doesn't interfere with the next run
                    if os.path.exists(STOP_FILE):
                        os.remove(STOP_FILE)
                        print(f"    (Removed stale STOP file to prevent interference on next run)")
                    # Exit the chunk loop cleanly
                    break
                else:
                    remaining = max_runtime_hours - elapsed_hours
                    eta_finish_dt = datetime.now().astimezone() + timedelta(hours=remaining)
                    print(f"    Continuing  ({remaining:.2f}h remaining)")
                    print(f"    This run will complete at or before {eta_finish_dt.strftime('%Y-%m-%d %H:%M:%S %Z')}")

        # --- Graceful Stop File Check ---
        if os.path.exists(STOP_FILE):
            os.remove(STOP_FILE)
            print(f"\n  ⏸️  GRACEFUL STOP: '{STOP_FILE}' detected.")
            print(f"    Finished chunk {i+1}/{total_chunks}.")
            print(f"    Resume anytime — script will continue from chunk {i+1}.")
            break

    # --- Step 3: Concatenate All Processed Chunks ---
    print("\n--- 3: Concatenating Chunks & Muxing Audio ---")

    if TEST_MODE_CHUNKS is not None:
        if chunks_to_process == 0:
            print("TEST MODE: 0 chunks processed.")
        else:
            print(f"TEST MODE: Skipping final concatenation after {chunks_to_process} chunk(s).")
            print("🎉 Test processing complete!")
        sys.exit(0)

    final_chunk_files = glob.glob(os.path.join(RIFE_CHUNKS_DIR, "*_rife.mp4"))
    total_processed_chunks = len(final_chunk_files)
    print(f"Found {total_processed_chunks} processed chunks to concatenate.")
    
    # Check if all chunks are complete before attempting final concatenation
    if total_processed_chunks < total_chunks:
        print(f"\n⚠️  Incomplete processing: {total_processed_chunks}/{total_chunks} chunks complete.")
        print(f"   Run the script again to resume from chunk {total_processed_chunks}.")
        print(f"   Final video will be created once all {total_chunks} chunks are processed.")
        sys.exit(0)

    with open(CONCAT_FILE, "w") as f:
        for i in range(total_processed_chunks):
            chunk_path = os.path.join(RIFE_CHUNKS_DIR, f"chunk_{i:03d}_rife.mp4")
            if not os.path.exists(chunk_path):
                print(f"Warning: Missing chunk {chunk_path}. Assuming this is the end.")
                break
            f.write(f"file '{os.path.abspath(chunk_path)}'\n")

    print(f"Concatenation list created: {CONCAT_FILE}")

    # Concat: always use plain stream copy, apply SAR after via container tools
    cmd_concat = [
        "ffmpeg", "-y",
        "-f", "concat", "-safe", "0", "-i", CONCAT_FILE,
        "-i", ORIGINAL_AUDIO_FILE,
        "-map", "0:v", "-map", "1:a",
        "-c:v", "copy",
        "-c:a", "copy",
        "-shortest",
        FINAL_VIDEO_FILE
    ]

    print(f"Running final concatenation and audio muxing...")
    try:
        subprocess.run(cmd_concat, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as e:
        print(f"\n--- ERROR: Final concatenation failed ---")
        print("STDOUT:", e.stdout)
        print("STDERR:", e.stderr)
        print(f"If this is a 'non-monotonic DTS' error, change -c:v copy to -c:v libx264 in the script and re-run.")
        raise

    # Apply SAR to final output using container-native tools (no re-encode)
    if source_sar:
        out_width, out_height = get_video_dimensions(FINAL_VIDEO_FILE)
        print(f"Applying SAR {source_sar} to final output (pixel {out_width}x{out_height} -> display {compute_display_width(out_width, out_height, source_sar)}x{out_height})...")
        apply_sar_to_file(FINAL_VIDEO_FILE, source_sar, out_width, out_height)
    else:
        print(f"Source has square pixels (SAR 1:1) — no SAR correction needed.")

    # --- Final Cleanup ---
    total_end_time = time.time()
    total_duration = total_end_time - total_start_time

    hours = int(total_duration // 3600)
    minutes = int((total_duration % 3600) // 60)
    seconds = int(total_duration % 60)
    print(f"\nTotal processing time: {hours:02d}:{minutes:02d}:{seconds:02d}")
    print(f"--- 4. Final Cleanup ---")
    # print(f"Deleting all temporary chunk data in {PROCESSING_DIR}...")
    # safe_rmtree(PROCESSING_DIR)
    # print("Temporary files deleted.")

    print(f"\n🎉 Pipeline complete! Final file: {FINAL_VIDEO_FILE}")


if __name__ == "__main__":
    args = parse_arguments()
    try:
        main(args)
    except subprocess.CalledProcessError as e:
        print(f"\nA critical command failed. Exiting.")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nProcess interrupted by user. Exiting.")
        sys.exit(1)
