#!/usr/bin/env python3
# video_upscale_pipeline.py - Upscale and interpolate legacy video (VHS, Hi8, DV camcorder, etc.)
# Uses Real-ESRGAN for upscaling and RIFE for frame interpolation.
#
# ==============================================================================
# CHANGE HISTORY — CRF VALUES
# ==============================================================================
# 2026-05-04: Raised intermediate CRF values for archival quality.
#             ALL previously processed videos used CRF 16 for both intermediates:
#
#               Pre-filter intermediate (fed to Real-ESRGAN):
#                 Before: CRF 16    After: CRF 12
#
#               RIFE frame reassembly intermediate (assembled into final output):
#                 Before: CRF 17    After: CRF 14
#
#             See inline comments at each ffmpeg call for exact locations.
# ==============================================================================
import subprocess
import os
import shutil
import shlex
import json
import math
import glob
import time
import sys
import argparse
import re
from datetime import datetime, timedelta
import statistics

# --- Config ---
OUTPUT_DIR = "outputs"
RIFE_BIN = "./rife-ncnn-vulkan/rife-ncnn-vulkan"

# --- Auto-Tuning Config ---
MIN_CHUNK_SEC = 10
MAX_CHUNK_SEC = 300  # Tuned for RTX 4060 Ti; was 120 for GTX 1060
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

def load_chunk_durations_from_log(log_file):
    """
    Reconstruct the full-chunk timing history from pipeline.log.

    Scans for lines of the form written at the end of every successfully
    completed full chunk::

        "  > Chunk finished in 12345.67 seconds."

    Partial-resume chunks are never logged with this line (they hit
    ``continue`` before the timing block), so the list naturally contains
    only the same timings that would have been appended to chunk_durations
    during the original run — no additional filtering required.

    Returns an empty list if the log does not exist or contains no matches,
    so callers can treat the result as a plain (possibly empty) list without
    special-casing.
    """
    durations = []
    _FINISHED_RE = re.compile(r"^\s*>\s+Chunk finished in ([0-9]+(?:\.[0-9]+)?)\s+seconds\.")
    try:
        with open(log_file, "r", errors="replace") as fh:
            for line in fh:
                m = _FINISHED_RE.match(line)
                if m:
                    durations.append(float(m.group(1)))
    except FileNotFoundError:
        pass  # first run — log does not exist yet
    except Exception as e:
        print(f"  [WARN] Could not read chunk timings from log: {e}")
    return durations

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

        # Peak disk usage occurs when RIFE input and output frame dirs coexist on disk
        # simultaneously: 2x the source frame count (1x input + 1x output frames).
        # With --no-rife this is a safe overestimate; with a 60fps mode=1 master fps
        # is already ~60 so *2 remains a reasonable worst-case. The conservative
        # overestimate is intentional — disk space is the hard constraint here.
        pngs_per_sec = fps * 2
        mb_per_sec = pngs_per_sec * est_png_mb
        print(f"Estimated temp disk usage per sec: {mb_per_sec:.2f} MB/s")

        usable_temp_gb = free_disk_gb * DISK_SAFETY_MARGIN
        print(f"Reserving {usable_temp_gb:.2f} GB (50%) for temp files.")
        
        max_chunk_sec_disk = (usable_temp_gb * 1024) / mb_per_sec
        print(f"Disk capacity allows for {max_chunk_sec_disk:.0f} second chunks.")

        if max_chunk_sec_disk < MIN_CHUNK_SEC:
            # Not enough disk even for the minimum chunk size on a fresh run.
            # Abort here rather than picking a smaller size — on a resumed run
            # this path is never reached (autotune is skipped entirely).
            needed_gb = (MIN_CHUNK_SEC * mb_per_sec) / (DISK_SAFETY_MARGIN * 1024)
            print(f"\n[!] ERROR: Insufficient disk space to start a new run.")
            print(f"    Minimum chunk size ({MIN_CHUNK_SEC}s) requires ~{needed_gb:.1f} GB free.")
            print(f"    Available: {free_disk_gb:.2f} GB free at current path.")
            print(f"    Free up at least {needed_gb - free_disk_gb:.1f} GB and retry.")
            raise RuntimeError("Insufficient disk space for minimum chunk size.")

        final_chunk_sec = max(MIN_CHUNK_SEC, min(max_chunk_sec_disk, MAX_CHUNK_SEC))

        print(f"Clamped to {final_chunk_sec:.0f} seconds (Min: {MIN_CHUNK_SEC}s, Max: {MAX_CHUNK_SEC}s)")
        print("--------------------------------")
        return int(final_chunk_sec)

    except RuntimeError:
        raise  # propagate disk space errors directly — do not swallow
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
  %(prog)s video.avi --profile hi8dv         # Hi8 tape via Digital8/FireWire direct capture
  %(prog)s video_60fps.mp4                   # 60fps mode=1 master: upscale only, 60fps out (default)
  %(prog)s video_30fps.mp4 --rife            # 30fps mode=0 master: RIFE doubles to ~60fps out
  %(prog)s camcorder.mp4                    # works with DV, Hi8, and other camcorder formats
  %(prog)s video.avi --model realesr-general-x4v3   # use general degradation model at 2x output
  %(prog)s video.avi -s 4 --model realesr-general-x4v3  # general model at 4x output

ESRGAN models (--model):
  RealESRGAN_x2plus        Default for --scale 2. Trained for 2x output in one step.
  RealESRGAN_x4plus        Default for --scale 4. More parameters, strong 4x detail.
  realesr-general-x4v3     General degradation model (noise, blur, compression artifacts).
                           Internally always 4x; downsamples to 2x when --scale 2 is used.
                           The downsampling acts as a natural anti-aliasing pass, which can
                           suit noisy VHS/Hi8 sources better than RealESRGAN_x2plus.

Pre-filter profiles (--profile):
  balanced   Default. Hi8/S-Video capture -> DVD (~4.6Mbps).   hqdn3d=2:2:6:6,     pp=fd, unsharp=3:3:0.2
  aggressive Heavy noise, composite captures, low-bitrate DVD. hqdn3d=3:3:6:6,     pp=ac, unsharp=3:3:0.6
  halo       White ghost lines / ringing around dark edges.    hqdn3d=4:4:8:8,     pp=fd, unsharp=3:3:0.2
  dv         MiniDV / Digital8 / DV AVI sources.               hqdn3d=1.5:1.5:4:4, pp=ac, unsharp=3:3:0.25
  hi8dv      Hi8 tape via Digital8/FireWire direct capture.     hqdn3d=2:2:5:5,     pp=ac, unsharp=3:3:0.2
""",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("input_video", help="Path to the input AVI/MP4/MKV video file.")
    parser.add_argument(
        "-s", "--scale", 
        type=int, 
        choices=[2, 4], 
        default=2, 
        help="Upscale factor: 2 or 4. Default: 2. Controls output resolution. Default model per scale: 2=RealESRGAN_x2plus, 4=RealESRGAN_x4plus. Override with --model."
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
        choices=["balanced", "aggressive", "halo", "dv", "hi8dv", "vhsdv", "vhsdv_composite"],
        default="balanced",
        help=(
            "Pre-filter profile (default: balanced). "
            "balanced:   Hi8/S-Video capture -> DVD (~4.6Mbps source). Light denoise, temporal 6:6 stability, fast deblock, minimal sharpen. "
            "aggressive: Heavy noise, composite captures, or low-bitrate DVD. Stronger denoise, full deblock+dering, more sharpen. "
            "halo:       White ghost lines around dark edges. Heavy denoise, fast deblock, minimal sharpen. "
            "dv:         MiniDV/Digital8/DV AVI. Lighter denoise, stronger deblock+dering, gentle sharpen. "
            "hi8dv:      Hi8 tape via Digital8/FireWire (DV capture). No MPEG-2 artifacts; moderate temporal denoise, full deblock+dering."
        )
    )
    parser.add_argument(
        "--model",
        default=None,
        metavar="MODEL_NAME",
        help=(
            "Override the default ESRGAN model (default: RealESRGAN_x2plus for --scale 2, "
            "RealESRGAN_x4plus for --scale 4). "
            "Example: --model realesr-general-x4v3. "
            "The model name must match the .pth filename in the weights/ directory (without extension). "
            "Note: realesr-general-x4v3 is always a 4x model internally; when used with --scale 2 "
            "it upscales to 4x then downsamples to 2x, which can reduce over-hallucination on noisy sources."
        )
    )
    parser.add_argument(
        "--max-runtime",
        type=float,
        default=None,
        metavar="HOURS",
        help="Maximum runtime in hours before graceful shutdown. Script will not start a new chunk if (elapsed time + last chunk duration) would exceed this limit. Example: --max-runtime 8"
    )
    parser.add_argument(
        "--rife",
        dest="no_rife",
        action="store_false",
        default=True,
        help=(
            "Enable RIFE frame interpolation (disabled by default). Doubles output FPS. "
            "Intended for ~30fps (bwdif mode=0) masters where RIFE interpolates between "
            "frames to produce ~60fps output. Do NOT use on ~60fps (bwdif mode=1) masters — "
            "that would produce ~120fps output. The pipeline will abort if --rife is passed "
            "with a >45fps input."
        )
    )
    return parser.parse_args()

def main(args):
    """Main processing pipeline."""
    # --- 0. Pre-Flight Checks ---
    check_venv()

    # Capture invocation command for resume messages (shell-safe)
    RECONSTRUCTED_CMD = " ".join(shlex.quote(arg) for arg in sys.argv)


    # Enable tee logging from the very start (captures all startup messages)
    sys.stdout = TeeLogger(LOG_FILE)
    print(f"\n--- Pipeline started {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')} | Logging to {LOG_FILE} ---\n")
    print(f"[INFO] Invocation command:")
    print(f"  {RECONSTRUCTED_CMD}\n")

    # --- 1. Set up variables based on args ---
    INPUT_VIDEO = args.input_video
    SCALE_FACTOR = args.scale
    # Detect extension to support both .avi and .mp4
    INPUT_EXT = os.path.splitext(INPUT_VIDEO)[1]
    
    # --- Pre-filter Profile Selection ---
    # Selected via --profile. Default: balanced.
    # Filter chains are defined in PROFILES_30FPS; PROFILES_60FPS holds variants
    # with halved temporal hqdn3d values for ~60fps (bwdif mode=1) masters.
    #
    # At 60fps the inter-frame delta per field is half that of 30fps, so the same
    # temporal strength over-smooths relative to actual motion. The temporal
    # parameters (the last two values of hqdn3d=luma_sp:chroma_sp:luma_tmp:chroma_tmp)
    # are approximately halved in the 60fps variants. Spatial and sharpening values
    # are identical between the two sets — only temporal smoothing changes.
    # The correct set is selected automatically based on source_fps_float below.
    #
    # 30fps profiles (bwdif mode=0 masters, or any source <= 45fps):
    #
    #   balanced   hqdn3d=2:2:6:6, pp=fd, unsharp=3:3:0.2
    #     Light spatial denoise preserves texture for ESRGAN. Temporal at 6:6 stabilises
    #     frame-to-frame flicker without touching real detail. pp=fd handles DVD
    #     macroblocking. Minimal sharpening avoids pre-upscale halos.
    #     Tuned for Hi8/S-Video capture -> DVD (~4.6Mbps source).
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
    #
    #   hi8dv      hqdn3d=2:2:5:5, pp=ac, unsharp=3:3:0.2
    #     For Hi8 tapes transferred via a Digital8 camcorder (e.g. DCR-TRV350)
    #     over FireWire as a DV stream. No MPEG-2 blocking or ringing — those
    #     artifacts are absent because the DVD authoring step is bypassed.
    #     Temporal at 5:5 (lighter than balanced) since MPEG-2 compression
    #     flicker is gone; only genuine Hi8 tape noise remains.
    #
    #   vhsdv      hqdn3d=2.5:3:5:5, pp=ac, unsharp=3:3:0.2
    #     For VHS tape via TRV330 passthrough using S-Video input. Slightly
    #     stronger chroma spatial denoise (3 vs 2) vs hi8dv to address VHS
    #     color-under chroma noise. Same temporal values as hi8dv.
    #
    #   vhsdv_composite  hqdn3d=2.5:3.5:5:5, pp=ac, unsharp=3:3:0.2
    #     For VHS tape via TRV330 passthrough using composite input. Elevated
    #     chroma spatial (3.5) targets dot crawl and cross-colour artifacts
    #     introduced by comb filter luma/chroma separation.
    #
    # 60fps profiles (bwdif mode=1 masters, source > 45fps):
    #   Temporal values halved vs. 30fps counterparts. All other values identical.
    #
    #   balanced   hqdn3d=2:2:3:3, pp=fd, unsharp=3:3:0.2
    #   aggressive hqdn3d=3:3:3:3, pp=ac, unsharp=3:3:0.6
    #   halo       hqdn3d=4:4:4:4, pp=fd, unsharp=3:3:0.2
    #   dv         hqdn3d=1.5:1.5:2:2, pp=ac, unsharp=3:3:0.25
    #   hi8dv      hqdn3d=2:2:2.5:2.5, pp=ac, unsharp=3:3:0.2

    PROFILES_30FPS = {
        "balanced":        "hqdn3d=2:2:6:6,pp=fd,unsharp=3:3:0.2",
        "aggressive":      "hqdn3d=3:3:6:6,pp=ac,unsharp=3:3:0.6",
        "halo":            "hqdn3d=4:4:8:8,pp=fd,unsharp=3:3:0.2",
        "dv":              "hqdn3d=1.5:1.5:4:4,pp=ac,unsharp=3:3:0.25",
        "hi8dv":           "hqdn3d=2:2:5:5,pp=ac,unsharp=3:3:0.2",
        # VHS via TRV330 passthrough (S-Video input).
        # Slightly stronger chroma spatial denoise (3 vs 2) vs hi8dv to
        # address VHS color-under chroma noise. Temporal values match hi8dv.
        "vhsdv":           "hqdn3d=2.5:3:5:5,pp=ac,unsharp=3:3:0.2",
        # VHS via TRV330 passthrough (composite input).
        # Elevated chroma spatial (3.5) targets dot crawl and cross-colour
        # artifacts introduced by comb filter luma/chroma separation.
        "vhsdv_composite": "hqdn3d=2.5:3.5:5:5,pp=ac,unsharp=3:3:0.2",
    }

    # Temporal hqdn3d values (luma_tmp:chroma_tmp) halved for 60fps field-rate
    # masters. At twice the frame rate, consecutive frames are closer in time,
    # so the same temporal strength would over-smooth genuine motion.
    PROFILES_60FPS = {
        "balanced":        "hqdn3d=2:2:3:3,pp=fd,unsharp=3:3:0.2",
        "aggressive":      "hqdn3d=3:3:3:3,pp=ac,unsharp=3:3:0.6",
        "halo":            "hqdn3d=4:4:4:4,pp=fd,unsharp=3:3:0.2",
        "dv":              "hqdn3d=1.5:1.5:2:2,pp=ac,unsharp=3:3:0.25",
        "hi8dv":           "hqdn3d=2:2:2.5:2.5,pp=ac,unsharp=3:3:0.2",
        "vhsdv":           "hqdn3d=2.5:3:2.5:2.5,pp=ac,unsharp=3:3:0.2",
        "vhsdv_composite": "hqdn3d=2.5:3.5:2.5:2.5,pp=ac,unsharp=3:3:0.2",
    }

    profile = args.profile

    profile_descriptions = {
        "balanced":   "Light spatial denoise, temporal stability, fast deblock, minimal sharpen. "
                      "Optimised for Hi8/S-Video capture -> DVD (~4.6Mbps source).",
        "aggressive": "Strong denoise, full deblock+dering, more sharpen. "
                      "Recommended for heavy noise, composite captures, or low-bitrate DVD sources.",
        "halo":       "Heavy denoise, fast deblock, minimal sharpen. "
                      "Use if you see white ghost lines around dark edges.",
        "dv":         "Light spatial denoise, moderate temporal smoothing, full deblock+dering, gentle sharpen. "
                      "Optimised for MiniDV / Digital8 / DV AVI sources.",
        "hi8dv":           "Light spatial denoise, moderate temporal smoothing, full deblock+dering, minimal sharpen. "
                           "Optimised for Hi8 tape via Digital8/FireWire direct DV capture.",
        "vhsdv":           "Slightly stronger chroma spatial denoise vs hi8dv to address VHS color-under noise. "
                           "For VHS via TRV330 passthrough using S-Video input.",
        "vhsdv_composite": "Elevated chroma spatial denoise targeting dot crawl and cross-colour from comb filter "
                           "luma/chroma separation. For VHS via TRV330 passthrough using composite input.",
    }

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

    if args.model:
        REALSRGAN_MODEL = args.model
        print(f"[INFO] ESRGAN model overridden via --model: {REALSRGAN_MODEL}")
    elif SCALE_FACTOR == 2:
        REALSRGAN_MODEL = "RealESRGAN_x2plus"
    elif SCALE_FACTOR == 4:
        REALSRGAN_MODEL = "RealESRGAN_x4plus"

    # Profile description is printed here, in the setup summary, so it appears
    # alongside scale/model/thread config. The resolved filter string (which
    # depends on source_fps_float) is printed later at deferred profile selection.
    print(f"   [Profile] {profile}: {profile_descriptions[profile]}")
    
    input_basename = os.path.splitext(os.path.basename(INPUT_VIDEO))[0]
    # Strip any fps/rife suffix that prepare_video.sh may have embedded in the
    # master filename (e.g. _60fps, _30fps). The pipeline appends its own
    # authoritative suffix later, so leaving these in would produce duplicates
    # like _60fps_..._60fps in the output filename.
    # The lambda preserves the trailing timestamp (_YYYYMMDD_HHMMSS) if present
    # while removing only the fps/rife token that precedes it.
    input_basename = re.sub(
        r'_(60fps_rife|60fps|30fps)(_\d{8}_\d{6})?$',
        lambda m: m.group(2) or '',
        input_basename
    )
    MODEL_SHORT = {"RealESRGAN_x2plus": "x2plus", "RealESRGAN_x4plus": "x4plus", "realesr-general-x4v3": "gen-x4v3"}.get(REALSRGAN_MODEL, REALSRGAN_MODEL)
    # FINAL_VIDEO_FILE_BASE is the name without the fps/rife suffix, which is
    # appended later once source_fps_float and args.no_rife are both known.
    FINAL_VIDEO_FILE_BASE = os.path.join(OUTPUT_DIR, f"{input_basename}_{profile}_x{SCALE_FACTOR}_{MODEL_SHORT}")
    ORIGINAL_AUDIO_FILE = os.path.join(PROCESSING_DIR, f"{input_basename}_original.mka")  # .mka accepts any codec (AC-3, AAC, PCM, MP3)
    ORIGINAL_AUDIO_FILE_MP3 = os.path.join(PROCESSING_DIR, f"{input_basename}_original.mp3")  # fallback path

    print(f"--- Starting processing for: {INPUT_VIDEO} ---")
    print(f"Detected Input Extension: {INPUT_EXT}")
    print(f"Selected Scale Factor: {SCALE_FACTOR}x")
    print(f"Selected Model: {REALSRGAN_MODEL}")
    print(f"Final Output File: (determined after FPS detection)")

    # --- Check if processing_chunks contains data from a different video/scale ---
    metadata_file = os.path.join(PROCESSING_DIR, "metadata.json")
    current_metadata = {
        "input_video": os.path.abspath(INPUT_VIDEO),
        "scale_factor": SCALE_FACTOR,
        "profile": profile,
        "model": REALSRGAN_MODEL,
        # no_rife is included so that a resumed run cannot accidentally mix
        # RIFE-interpolated and non-interpolated chunks in the same output.
        "no_rife": args.no_rife,
    }
    
    # is_resume is set True only when metadata existed and matched exactly,
    # confirming we are continuing an interrupted run with completed chunks.
    is_resume = False

    if os.path.exists(metadata_file):
        # Attempt to read and parse the metadata file.
        # Any failure (corrupt JSON, permission error, etc.) is treated as an
        # unknown state — we NEVER delete chunks silently. The user must confirm
        # or pass --force explicitly after being shown the error.
        old_metadata = None
        metadata_read_error = None
        try:
            with open(metadata_file, 'r') as f:
                old_metadata = json.load(f)
        except json.JSONDecodeError as e:
            metadata_read_error = f"metadata.json is corrupt or contains invalid JSON: {e}"
        except Exception as e:
            metadata_read_error = f"Could not read metadata.json: {e}"

        if metadata_read_error:
            # Metadata is unreadable — could mean a partial write during a
            # previous crash. Completed chunk files may still be valid and
            # resumable. Never auto-delete; always ask.
            print(f"\n⚠️  WARNING: {metadata_read_error}")
            print(f"    Metadata file: {metadata_file}")
            print(f"    Processing chunks directory: {PROCESSING_DIR}")
            print(f"    There may be completed chunks worth preserving.")
            if args.force:
                print("Deleting processing_chunks... (--force specified)")
                safe_rmtree(PROCESSING_DIR)
            else:
                print("\nOptions:")
                print("  y = delete processing_chunks and start fresh")
                print("  n = exit so you can inspect the chunks manually")
                response = input("Delete processing_chunks and start fresh? (y/n): ")
                if response.lower() == 'y':
                    print("Deleting processing_chunks...")
                    safe_rmtree(PROCESSING_DIR)
                else:
                    print("Exiting. Inspect or repair metadata.json before restarting.")
                    print(f"  To repair: python3 -c \"import json; print(open(\'{metadata_file}\').read())\"")
                    print(f"  To reset:  rm -rf {PROCESSING_DIR}")
                    sys.exit(1)

        else:
            # Compare metadata excluding chunk_duration, which is added to
            # current_metadata only after autotune runs. Stored metadata may
            # contain it from a previous run; excluding it from both sides
            # prevents a false mismatch on resume.
            comparable_keys = [k for k in current_metadata if k != "chunk_duration"]
            old_comparable = {k: old_metadata.get(k) for k in comparable_keys}
            new_comparable = {k: current_metadata[k] for k in comparable_keys}

            if old_comparable == new_comparable:
                # Core parameters matched — this is a resume of an existing run.
                is_resume = True
            else:
                # Genuine mismatch — processing_chunks belongs to a different job.
                # Never offer a simple y/n delete prompt: completed chunks may
                # represent days of processing. Deletion requires --force to be
                # passed explicitly on the command line as a deliberate act.
                print(f"\n[!] ERROR: processing_chunks contains data from a different job.")
                print(f"  Existing job: {old_metadata}")
                print(f"  Current job:  {current_metadata}")
                print(f"")
                print(f"  The existing chunks in processing_chunks/ belong to a different run.")
                print(f"  To avoid accidental data loss, deletion requires --force.")
                print(f"")
                print(f"  Options:")
                print(f"    1. Move or rename processing_chunks/ to preserve the existing work,")
                print(f"       then re-run this command.")
                print(f"    2. Run with --force to delete the existing chunks and start fresh.")
                if args.force:
                    print("\n[INFO] --force specified — deleting existing chunks and starting fresh.")
                    safe_rmtree(PROCESSING_DIR)
                else:
                    sys.exit(1)
    
    os.makedirs(PROCESSING_DIR, exist_ok=True)
    # Metadata is written after autotune sets chunk_duration (below).
    # --- End of metadata check ---

    # --- Step 0: Setup, Auto-Tune, and Splitting ---
    print("\n--- 0. Setup and Splitting ---")

    os.makedirs(INPUT_CHUNKS_DIR, exist_ok=True)
    os.makedirs(ESRGAN_CHUNKS_DIR, exist_ok=True)
    os.makedirs(RIFE_CHUNKS_DIR, exist_ok=True)
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    completed_rife_chunks = glob.glob(os.path.join(RIFE_CHUNKS_DIR, "*_rife.mp4"))

    # On a resume, always use the stored chunk_duration regardless of whether
    # any rife chunks exist yet. The input split (if it happened) used that
    # size; a different autotune result would produce different boundaries and
    # corrupt the output. If chunk_duration is absent from old metadata (runs
    # predating this field), fall through to autotune as a safe fallback.
    if is_resume and old_metadata.get("chunk_duration"):
        CHUNK_DURATION_SECONDS = old_metadata["chunk_duration"]
        print(f"[INFO] Resuming with stored chunk duration: {CHUNK_DURATION_SECONDS}s "
              f"({len(completed_rife_chunks)} chunks already completed).")
        print("[INFO] Skipping autotune — chunk size must match the existing split.")
        # Warn if disk space is tight for the stored chunk size, but never
        # suggest deleting existing work — the user must free space themselves.
        try:
            free_disk_gb = check_disk_space(".", 10)
            fps = float(get_video_fps(INPUT_VIDEO))
            in_width, in_height = get_video_dimensions(INPUT_VIDEO)
            out_width, out_height = in_width * SCALE_FACTOR, in_height * SCALE_FACTOR
            bytes_per_pixel = 3
            est_png_mb = (out_width * out_height * bytes_per_pixel * EST_PNG_COMP_RATIO) / (1024**2)
            mb_per_sec = fps * 2 * est_png_mb
            needed_gb = (CHUNK_DURATION_SECONDS * mb_per_sec) / (DISK_SAFETY_MARGIN * 1024)
            if free_disk_gb < needed_gb:
                print(f"\n⚠️  WARNING: Low disk space for resumed run.")
                print(f"    Stored chunk size ({CHUNK_DURATION_SECONDS}s) requires ~{needed_gb:.1f} GB free.")
                print(f"    Available: {free_disk_gb:.2f} GB free at current path.")
                print(f"    Free up at least {needed_gb - free_disk_gb:.1f} GB before continuing.")
                print(f"    DO NOT delete processing_chunks/ — your completed chunks are there.")
                response = input("    Continue anyway? (y/n): ")
                if response.lower() != "y":
                    print("    Exiting. Free disk space and retry.")
                    sys.exit(0)
        except Exception:
            pass  # disk check failure is non-fatal on resume
    else:
        CHUNK_DURATION_SECONDS = autotune_chunk_size(INPUT_VIDEO, SCALE_FACTOR)

    # Add chunk_duration now that autotune has run, then write metadata
    # only if the content has changed. On a clean resume the file already
    # contains the correct values — rewriting it unnecessarily changes its
    # mtime and makes it look like something changed when nothing did.
    current_metadata["chunk_duration"] = CHUNK_DURATION_SECONDS
    _existing_metadata = None
    try:
        with open(metadata_file, "r") as f:
            _existing_metadata = json.load(f)
    except Exception:
        pass
    if _existing_metadata != current_metadata:
        with open(metadata_file, "w") as f:
            json.dump(current_metadata, f, indent=4)

    duration = get_video_duration(INPUT_VIDEO)
    source_fps_str = get_video_fps(INPUT_VIDEO)
    source_fps_float = float(source_fps_str)

    # Guard: ~60fps input + RIFE would produce ~120fps output, which is never
    # the intent. This indicates a bwdif mode=1 master was passed in with
    # --rife. Abort early with a clear message rather than silently producing
    # a 120fps file after hours of processing.
    if source_fps_float > 45 and not args.no_rife:
        print(f"\n[!] ERROR: Input is ~{source_fps_float:.3f}fps (bwdif mode=1 master) "
              f"but --rife was specified.")
        print("    Running RIFE on a 60fps master would produce ~120fps output.")
        print("    Either:")
        print("      - Remove --rife to process at 60fps without interpolation (default)")
        print("      - Re-run prepare_video.sh with --mode0 to get a 30fps master, then use --rife")
        sys.exit(1)

    # With RIFE enabled, output is double the source rate.
    # With --no-rife (default), output matches source rate exactly.
    output_fps_float = source_fps_float if args.no_rife else source_fps_float * 2

    # Build output filename suffix reflecting fps and interpolation method:
    #   mode=1 (default, no-rife): _60fps       (59.94fps input, no interpolation)
    #   mode=0 + --rife:           _60fps_rife   (29.97fps input doubled to 59.94fps)
    #   mode=0 + no-rife:          _30fps        (29.97fps input, no interpolation)
    if args.no_rife:
        fps_suffix = "_60fps" if source_fps_float > 45 else "_30fps"
    else:
        fps_suffix = "_60fps_rife"
    FINAL_VIDEO_FILE = f"{FINAL_VIDEO_FILE_BASE}{fps_suffix}.mkv"

    # --- Deferred profile selection (requires source_fps_float) ---
    # 60fps masters (bwdif mode=1) use halved temporal hqdn3d values to avoid
    # over-smoothing frames that are already half the inter-frame distance apart.
    # The threshold of 45fps cleanly separates 29.97/25fps masters from 59.94/50fps.
    if source_fps_float > 45:
        prefilter_vf = PROFILES_60FPS[profile]
        fps_label = "60fps"
    else:
        prefilter_vf = PROFILES_30FPS[profile]
        fps_label = "30fps"

    source_sar = get_video_sar(INPUT_VIDEO)
    total_chunks = math.ceil(duration / CHUNK_DURATION_SECONDS)

    # --- Pre-Flight Plan ---
    # Always printed so the user can verify settings before hours of processing.
    # On a resume the plan is shown as a reminder; confirmation is skipped because
    # the user already approved it when the run was originally started, and
    # prompting again risks an accidental 'n' aborting a multi-day job.
    # --force bypasses confirmation for non-interactive / scripted use.
    print(f"\n{'=' * 55}")
    print(f"  PRE-FLIGHT PLAN")
    print(f"{'=' * 55}")
    print(f"  Input:         {INPUT_VIDEO}")
    print(f"  Input FPS:     {source_fps_str} ({fps_label} variant profile)")
    print(f"  Input SAR:     {source_sar if source_sar else '1:1 (square pixels)'}")
    print(f"  Duration:      {duration:.1f}s  →  {total_chunks} chunks × {CHUNK_DURATION_SECONDS}s")
    print(f"  Scale:         {SCALE_FACTOR}x  ({REALSRGAN_MODEL})")
    print(f"  Profile:       {profile}  →  {prefilter_vf}")
    print(f"  Pre-filter:    CRF 12  |  preset fast  (intermediate, deleted after processing)")
    print(f"  RIFE encode:   CRF 14  |  preset fast  (intermediate, deleted after concat)")
    print(f"  RIFE:          {'enabled (--rife): frames will be doubled' if not args.no_rife else 'disabled (default)'}")
    print(f"  Output FPS:    {output_fps_float:.3f}")
    print(f"  Output file:   {FINAL_VIDEO_FILE}")

    # Warn prominently when the output will not be ~60fps — this is the most
    # common configuration mistake and can waste hours of processing time.
    if output_fps_float < 50:
        print(f"\n  ⚠️  WARNING: Output will be {output_fps_float:.3f}fps — NOT ~60fps.")
        if args.no_rife and source_fps_float <= 45:
            print(f"     This is a ~30fps input with RIFE disabled.")
            print(f"     For ~60fps output, either:")
            print(f"       (a) Re-prepare with prepare_video.sh (default mode=1) → re-run pipeline, or")
            print(f"       (b) Add --rife to interpolate this 30fps master to ~60fps.")
    print(f"{'=' * 55}\n")

    if is_resume:
        print("[INFO] Resuming previous run — confirmation skipped.")
    elif args.force:
        print("[INFO] --force specified — skipping confirmation.")
    else:
        response = input("  Proceed? (y/n): ")
        if response.lower() != "y":
            print("  Exiting. Add --force to bypass this prompt in future runs.")
            sys.exit(0)

    # Emit final-output-file line after confirmation so it appears in the log
    # at the point processing actually begins (consistent with prior behaviour).
    print(f"Final Output File: {FINAL_VIDEO_FILE}")
    print(f"   [Profile filter] {profile} ({fps_label} variant): {prefilter_vf}")
    if source_sar:
        print(f"Source SAR detected: {source_sar} (non-square pixels — will be preserved in final output.)")
    else:
        print(f"Source SAR: 1:1 (square pixels)")
    print(f"Video detected: {duration:.2f}s, {source_fps_str} FPS.")
    print(f"Using {CHUNK_DURATION_SECONDS}s chunks, splitting into {total_chunks} total chunks.")
    if args.no_rife:
        print(f"RIFE disabled (default): output will be {output_fps_float:.3f} FPS (matches input).")
    else:
        print(f"RIFE enabled (--rife): output will be {output_fps_float:.3f} FPS (2x input).")

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
    # Never re-split if completed rife chunks exist. A re-split at a different
    # chunk size would produce different boundaries, causing overlap or gaps
    # when the new input chunks are concatenated with existing rife chunks.
    if completed_rife_chunks:
        print(f"Chunks already split and {len(completed_rife_chunks)} rife chunks complete — "
              f"skipping split to preserve existing boundaries.")
    elif not os.path.exists(os.path.join(INPUT_CHUNKS_DIR, f"chunk_000{INPUT_EXT}")):
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
        print("Input chunks already exist, skipping split.")

    # --- Chunk Coverage Check ---
    # Verify that the combined duration of all input chunks and completed rife
    # chunks accounts for the full source video. This catches split problems
    # (overlap, gaps, mixed chunk sizes) before committing to hours of ESRGAN.
    #
    # On a fresh run: all chunks are in 0_input_chunks/.
    # On a resume: completed chunks have been deleted from 0_input_chunks/ and
    # their processed counterparts are in 2_rife_chunks/. We sum both.
    #
    # Tolerance: ffmpeg's segment splitter cuts on keyframe boundaries so the
    # last chunk is typically a few seconds short and all other boundaries may
    # drift slightly. We allow up to CHUNK_DURATION_SECONDS of underage (one
    # short last chunk is normal) but flag any overage above a small threshold
    # (overlap) or underage larger than one full chunk (missing content).
    print("\n  > Verifying chunk coverage...")
    try:
        input_chunk_files = sorted(glob.glob(os.path.join(INPUT_CHUNKS_DIR, f"*{INPUT_EXT}")))
        rife_chunk_files  = sorted(glob.glob(os.path.join(RIFE_CHUNKS_DIR, "*_rife.mp4")))
        all_chunk_files = input_chunk_files + rife_chunk_files

        if not all_chunk_files:
            print("  > No chunks found — coverage check skipped (fresh run, split not yet done).")
        else:
            chunks_total_sec = sum(
                float(subprocess.run(
                    ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                     "-of", "default=noprint_wrappers=1:nokey=1", f],
                    capture_output=True, text=True, check=True
                ).stdout.strip())
                for f in all_chunk_files
            )
            diff = chunks_total_sec - duration
            overage_threshold  =  2.0  # seconds — anything above this is overlap
            underage_threshold = CHUNK_DURATION_SECONDS + 2.0  # one short chunk is normal

            h = int(chunks_total_sec // 3600)
            m = int((chunks_total_sec % 3600) // 60)
            s = int(chunks_total_sec % 60)
            src_h = int(duration // 3600)
            src_m = int((duration % 3600) // 60)
            src_s = int(duration % 60)
            print(f"  > Source duration:  {src_h:02d}:{src_m:02d}:{src_s:02d} ({duration:.2f}s)")
            print(f"  > Chunks total:     {h:02d}:{m:02d}:{s:02d} ({chunks_total_sec:.2f}s) "
                  f"[{len(input_chunk_files)} input + {len(rife_chunk_files)} rife]")
            print(f"  > Difference:       {diff:+.2f}s")

            if diff > overage_threshold:
                raise RuntimeError(
                    f"Chunk coverage OVERAGE: chunks sum to {diff:.1f}s MORE than source.\n"
                    f"This indicates overlapping chunk boundaries — likely caused by a\n"
                    f"re-split at a different chunk size. Delete processing_chunks/ and\n"
                    f"start fresh, or manually remove the overlapping chunks."
                )
            elif diff < -underage_threshold:
                raise RuntimeError(
                    f"Chunk coverage UNDERAGE: chunks sum to {abs(diff):.1f}s LESS than source.\n"
                    f"This indicates missing chunks — the split may be incomplete.\n"
                    f"Delete processing_chunks/ and start fresh."
                )
            else:
                print(f"  > Coverage check passed.")
    except RuntimeError:
        raise
    except Exception as e:
        print(f"  > WARNING: Coverage check failed ({e}) — continuing anyway.")

    # --- Steps 1 & 2: Process Chunks in a Loop ---
    print("\n--- 1. & 2. Processing All Chunks ---")

    # Clear any stale STOP file left over from a previous session (e.g. a session
    # that hit the runtime limit before it could reach the STOP-file check).
    if os.path.exists(STOP_FILE):
        os.remove(STOP_FILE)
        print(f"[INFO] Removed stale STOP file from previous session: {STOP_FILE}")

    total_start_time = time.time()
    chunks_to_process = total_chunks
    # Rolling history for median ETA.  On a resume, reconstruct from the log
    # so the first chunk in this session shows an ETA rather than "unknown".
    if is_resume and os.path.exists(LOG_FILE):
        chunk_durations = load_chunk_durations_from_log(LOG_FILE)
        if chunk_durations:
            print(f"[INFO] Loaded {len(chunk_durations)} prior chunk timing(s) from log "
                  f"(median: {statistics.median(chunk_durations)/3600:.2f}h).")
    else:
        chunk_durations = []
    if TEST_MODE_CHUNKS is not None:
        chunks_to_process = min(total_chunks, TEST_MODE_CHUNKS)
        print(f"*** TEST MODE: Only processing {chunks_to_process} chunk(s) ***")

    # Probe the last input chunk once so every project-completion ETA in the
    # loop can use (chunks_remaining - 1 + last_chunk_fraction) × median
    # rather than chunks_remaining × median, which over-estimates whenever the
    # final chunk is shorter than CHUNK_DURATION_SECONDS (the common case).
    last_chunk_fraction = 1.0  # assume full chunk if probe fails
    last_chunk_path = os.path.join(INPUT_CHUNKS_DIR,
                                   f"chunk_{total_chunks - 1:03d}{INPUT_EXT}")
    try:
        _last_sec = float(subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", last_chunk_path],
            capture_output=True, text=True, check=True
        ).stdout.strip())
        last_chunk_fraction = min(_last_sec / CHUNK_DURATION_SECONDS, 1.0)
        print(f"[INFO] Last chunk: {_last_sec:.0f}s / {CHUNK_DURATION_SECONDS}s nominal"
              f" = {last_chunk_fraction:.2f} of a full chunk.")
    except Exception:
        print(f"[INFO] Last chunk size probe failed — ETA will treat it as a full chunk.")

    for i in range(chunks_to_process):
        chunk_name = f"chunk_{i:03d}"
        chunk_start_time = time.time()
        local_start = datetime.now().astimezone()
        elapsed_hours = (chunk_start_time - total_start_time) / 3600
        print(f"\nProcessing Chunk {i+1} / {total_chunks} ({chunk_name})")
        print(f"  > Started at: {local_start.strftime('%Y-%m-%d %H:%M:%S %Z')}")

        # Define paths here so the last-chunk ETA probe below can reference input_chunk.
        input_chunk = os.path.join(INPUT_CHUNKS_DIR, f"{chunk_name}{INPUT_EXT}")
        esrgan_temp_work_dir = os.path.join(ESRGAN_CHUNKS_DIR, f"{chunk_name}_temp_work")
        esrgan_output_file = os.path.join(ESRGAN_CHUNKS_DIR, f"{chunk_name}_esrgan.mp4")
        rife_in_frames_dir = os.path.join(ESRGAN_CHUNKS_DIR, f"{chunk_name}_rife_in_frames")
        rife_out_frames_dir = os.path.join(RIFE_CHUNKS_DIR, f"{chunk_name}_rife_out_frames")
        rife_output_file = os.path.join(RIFE_CHUNKS_DIR, f"{chunk_name}_rife.mp4")

        if chunk_durations:
            median_sec_pre = statistics.median(chunk_durations)
            # Last chunk is often shorter than CHUNK_DURATION_SECONDS because
            # ffmpeg's segment splitter cuts on keyframe boundaries.  Probe the
            # actual input chunk duration and scale the median proportionally so
            # the ETA reflects the real remaining work instead of a full chunk.
            if i == total_chunks - 1:
                try:
                    actual_last_sec = float(subprocess.run(
                        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                         "-of", "default=noprint_wrappers=1:nokey=1", input_chunk],
                        capture_output=True, text=True, check=True
                    ).stdout.strip())
                    ratio = actual_last_sec / CHUNK_DURATION_SECONDS
                    eta_sec = median_sec_pre * ratio
                    chunk_eta = local_start + timedelta(seconds=eta_sec)
                    print(f"  > Estimated completion: {chunk_eta.strftime('%Y-%m-%d %H:%M:%S %Z')} "
                          f"(last chunk {actual_last_sec:.0f}s / {CHUNK_DURATION_SECONDS}s nominal"
                          f" → {ratio:.2f}× median {median_sec_pre/3600:.2f}h)")
                except Exception:
                    # Probe failed — fall back to unscaled median.
                    chunk_eta = local_start + timedelta(seconds=median_sec_pre)
                    print(f"  > Estimated completion: {chunk_eta.strftime('%Y-%m-%d %H:%M:%S %Z')} "
                          f"(median {median_sec_pre/3600:.2f}h, last-chunk size probe failed)")
            else:
                chunk_eta = local_start + timedelta(seconds=median_sec_pre)
                print(f"  > Estimated completion: {chunk_eta.strftime('%Y-%m-%d %H:%M:%S %Z')} "
                      f"(median {median_sec_pre/3600:.2f}h)")
        else:
            print(f"  > Estimated completion: unknown (first chunk)")
        print(f"  > Project elapsed: {elapsed_hours:.2f}h")
        print(f"  > To stop after this chunk: touch {STOP_FILE}")

        # Track which steps were skipped so partial-resume chunks are excluded
        # from the median ETA — they represent far less work than a full chunk.
        skipped_esrgan = False
        skipped_frame_extraction = False

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
                "-c:v", "libx264", "-threads", str(threads), "-crf", "12", # archival: CRF 12 preserves maximum detail for ESRGAN
                # 2026-05-04: raised from CRF 16 to CRF 12 — all previously processed
                # videos used CRF 16 for the pre-filter intermediate.
                "-preset", "fast", # temporary intermediate decoded frame-by-frame: preset does not affect quality
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
            skipped_esrgan = True
            print(f"  > Found existing Real-ESRGAN output, skipping to RIFE.")

        # --- Step 2: Run RIFE (Multi-Step) or bypass ---
        if args.no_rife:
            # --no-rife: promote the ESRGAN output directly to the rife chunk slot.
            # All downstream logic (concat, cleanup, ETA) is undisturbed because it
            # only ever references rife_output_file, never esrgan_output_file directly.
            # cleanup_intermediate_files() tolerates a missing esrgan_output_file
            # (it was renamed, not deleted) and missing frame dirs (never created).
            print(f"  > Skipping RIFE (--no-rife): promoting ESRGAN output to final chunk slot.")
            os.rename(esrgan_output_file, rife_output_file)
            print(f"  > No-RIFE complete: {rife_output_file}")

            # --- CRITICAL: Aggressive Cleanup (no-RIFE path) ---
            # esrgan_output_file was renamed above so it no longer exists at its
            # original path; cleanup_intermediate_files() handles that gracefully.
            # rife_in_frames_dir and rife_out_frames_dir were never created.
            cleanup_intermediate_files(input_chunk, esrgan_output_file, rife_in_frames_dir, rife_out_frames_dir)

        else:
            # Check if RIFE input frames already exist and are complete
            existing_in_frames = glob.glob(os.path.join(rife_in_frames_dir, "*.png")) if os.path.isdir(rife_in_frames_dir) else []
            if existing_in_frames:
                skipped_frame_extraction = True
                print(f"  > Found {len(existing_in_frames)} existing RIFE input frames, skipping extraction.")
            else:
                print(f"  > Extracting frames for RIFE...")
                os.makedirs(rife_in_frames_dir, exist_ok=True)
                cmd_extract = [
                    "ffmpeg", "-i", esrgan_output_file,
                    os.path.join(rife_in_frames_dir, "frame_%08d.png")
                ]
                # Timeout: allow 10s per expected frame plus a 120s fixed overhead.
                # Normal extraction takes 20-45s. This catches silent hangs (e.g. a
                # subprocess pipe buffer deadlock with capture_output=True) that would
                # otherwise block the pipeline indefinitely without any error output.
                # capture_output=True is intentionally kept to preserve error messages
                # on genuine failures; the timeout is the safeguard against deadlock.
                expected_frames = int(source_fps_float * CHUNK_DURATION_SECONDS)
                extraction_timeout = 120 + (expected_frames * 10)
                try:
                    with Timer(f"{chunk_name} RIFE Frame Extraction"):
                        subprocess.run(cmd_extract, check=True, capture_output=True,
                                       text=True, timeout=extraction_timeout)
                except subprocess.TimeoutExpired:
                    print(f"\n--- ERROR: FFmpeg frame extraction timed out on {chunk_name} ---")
                    print(f"    Timeout: {extraction_timeout}s "
                          f"(expected ~{expected_frames} frames at {source_fps_float:.3f} fps)")
                    print(f"    Partial frames in {rife_in_frames_dir} will be wiped on next run.")
                    print(f"    If this recurs, check disk I/O and available space.")
                    raise RuntimeError(f"Frame extraction timed out after {extraction_timeout}s on {chunk_name}")
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
                "-crf", "14", # archival: CRF 14 preserves upscaled 4K detail in chunk before final concat
                # 2026-05-04: raised from CRF 17 to CRF 14 — all previously processed
                # videos used CRF 17 for the RIFE frame reassembly intermediate.
                "-preset", "fast", # temporary intermediate decoded at concat: preset does not affect quality
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

        # Only include full chunk timings in the median. Partial-resume chunks
        # (where ESRGAN or frame extraction was skipped) represent far less work
        # and would skew the ETA estimate significantly downward.
        is_full_chunk = not skipped_esrgan and not skipped_frame_extraction
        if is_full_chunk:
            chunk_durations.append(duration_sec)
        else:
            skipped_steps = []
            if skipped_esrgan: skipped_steps.append("ESRGAN")
            if skipped_frame_extraction: skipped_steps.append("frame extraction")
            print(f"  > Partial resume (skipped: {', '.join(skipped_steps)}) — "
                  f"chunk time excluded from median ETA.")

        # Rolling median ETA (stable across noisy chunks)
        if chunk_durations:
            median_sec = statistics.median(chunk_durations)
        else:
            median_sec = duration_sec  # fallback if no full chunks yet
        chunks_remaining = total_chunks - (i + 1)

        # Effective remaining work in full-chunk units:
        #   (chunks_remaining - 1) full chunks + last_chunk_fraction of a chunk.
        # When chunks_remaining == 0 this is 0. When the probe failed,
        # last_chunk_fraction == 1.0 so the formula reduces to chunks_remaining × median.
        if chunks_remaining > 0:
            effective_remaining = (chunks_remaining - 1) + last_chunk_fraction
        else:
            effective_remaining = 0.0
        remaining_sec = median_sec * effective_remaining
        eta_project = local_end + timedelta(seconds=remaining_sec)

        print(f"  > Chunk finished in {duration_sec:.2f} seconds.")
        print(f"  > Finished at: {local_end.strftime('%Y-%m-%d %H:%M:%S %Z')}")
        next_eta = local_end + timedelta(seconds=median_sec)
        print(f"  > Next chunk ETA (median): {next_eta.strftime('%Y-%m-%d %H:%M:%S %Z')}")
        if chunks_remaining > 0:
            print(f"  > Project completion ETA: {eta_project.strftime('%Y-%m-%d %H:%M:%S %Z')} "
                  f"({effective_remaining:.2f}× median {median_sec/3600:.2f}h)")
        
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
                    print(f"    Run the following command to resume:")
                    print(f"      {RECONSTRUCTED_CMD}")
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
            print(f"    Run the following command to resume:")
            print(f"      {RECONSTRUCTED_CMD}")
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
        print(f"   Run the following command to resume from chunk {total_processed_chunks}:")
        print(f"     {RECONSTRUCTED_CMD}")
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
    # Module-level variable so the KeyboardInterrupt handler can print the
    # resume command even though RECONSTRUCTED_CMD is built inside main().
    _resume_cmd: str = " ".join(shlex.quote(arg) for arg in sys.argv)
    try:
        main(args)
    except subprocess.CalledProcessError as e:
        print(f"\nA critical command failed. Exiting.")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n\n⏸️  INTERRUPTED: Ctrl+C detected.")
        print("    Any chunk currently in progress has been abandoned.")
        print("    Completed chunks are safe and will be resumed automatically.")
        print("    On next run the pipeline will skip completed chunks and")
        print("    reprocess the interrupted chunk from the beginning.")
        print(f"    Resume command:\n      {_resume_cmd}")
        sys.exit(1)
