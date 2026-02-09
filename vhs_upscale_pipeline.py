#!/usr/bin/env python3
import subprocess
import os
import shutil
import json
import math
import glob
import time
import sys
import argparse

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
TEST_MODE_CHUNKS = None

# --- Helper Functions ---
def check_venv():
    """Ensures the script is running inside the virtual environment."""
    # sys.prefix != sys.base_prefix is the standard way to detect a venv in Python 3
    if not (sys.prefix != sys.base_prefix or 'VIRTUAL_ENV' in os.environ):
        print("\n[!] ERROR: Virtual environment not detected.")
        print("    This pipeline requires specific versions (e.g., numpy<2.0) found in venv.")
        print("    Please run: source venv/bin/activate")

def safe_rmtree(path):
    """Safely remove a directory tree."""
    if os.path.isdir(path):
        shutil.rmtree(path)

def get_video_duration(video_file):
    cmd = [
        "ffprobe", "-v", "quiet", "-print_format", "json",
        "-show_format", video_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    duration = float(json.loads(result.stdout)["format"]["duration"])
    return duration

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
        description="Upscale and interpolate VHS video files.",
        epilog="""
Examples:
  %(prog)s video.avi             # 2x upscaling (default)
  %(prog)s video.avi --scale 4   # 4x upscaling
  %(prog)s video.avi -s 4 --force # 4x upscaling, no cleanup prompt
""",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("input_video", help="Path to the input AVI/MP4/MKV video file.")
    parser.add_argument(
        "-s", "--scale", 
        type=int, 
        choices=[2, 4], 
        default=2, 
        help="Upscale factor: 2 (for RealESRGAN_x2plus) or 4 (for realesr-general-x4v3). Default: 2"
    )
    parser.add_argument(
        "-f", "--force", 
        action="store_true", 
        help="Force deletion of old processing chunks without prompting."
    )
    return parser.parse_args()

def main(args):
    """Main processing pipeline."""
    # --- 0. Pre-Flight Checks ---
    check_venv()
    
    # --- 1. Set up variables based on args ---
    INPUT_VIDEO = args.input_video
    SCALE_FACTOR = args.scale
    # Detect extension to support both .avi and .mp4
    INPUT_EXT = os.path.splitext(INPUT_VIDEO)[1]

    if not os.path.exists(INPUT_VIDEO):
        print(f"Error: Input video not found at: {INPUT_VIDEO}")
        sys.exit(1)

    if SCALE_FACTOR == 2:
        REALSRGAN_MODEL = "RealESRGAN_x2plus"
    elif SCALE_FACTOR == 4:
        REALSRGAN_MODEL = "realesr-general-x4v3"
    
    input_basename = os.path.splitext(os.path.basename(INPUT_VIDEO))[0]
    FINAL_VIDEO_FILE = os.path.join(OUTPUT_DIR, f"{input_basename}_x{SCALE_FACTOR}_rife_FINAL.mkv")
    ORIGINAL_AUDIO_FILE = os.path.join(PROCESSING_DIR, f"{input_basename}_original.mp3")

    print(f"--- Starting processing for: {INPUT_VIDEO} ---")
    print(f"Detected Input Extension: {INPUT_EXT}")
    print(f"Selected Scale Factor: {SCALE_FACTOR}x")
    print(f"Selected Model: {REALSRGAN_MODEL}")
    print(f"Final Output File: {FINAL_VIDEO_FILE}")

    # --- Check if processing_chunks contains data from a different video/scale ---
    metadata_file = os.path.join(PROCESSING_DIR, "metadata.json")
    current_metadata = {
        "input_video": os.path.abspath(INPUT_VIDEO),
        "scale_factor": SCALE_FACTOR
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
    
    # Save current metadata
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
    total_chunks = math.ceil(duration / CHUNK_DURATION_SECONDS)
    print(f"Video detected: {duration:.2f}s, {source_fps_str} FPS.")
    print(f"Using {CHUNK_DURATION_SECONDS}s chunks, splitting into {total_chunks} total chunks.")
    print(f"RIFE output will be {output_fps_float:.3f} FPS.")

    if not os.path.exists(ORIGINAL_AUDIO_FILE) or os.path.getsize(ORIGINAL_AUDIO_FILE) == 0:
        print(f"Extracting original audio to {ORIGINAL_AUDIO_FILE}...")
        cmd_audio = [
            "ffmpeg", "-y", "-i", INPUT_VIDEO,
            "-vn", "-acodec", "copy",
            ORIGINAL_AUDIO_FILE
        ]
        try:
            subprocess.run(cmd_audio, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            print(f"\n--- ERROR: FFmpeg audio extraction failed ---")
            print("STDOUT:", e.stdout)
            print("STDERR:", e.stderr)
            raise
        
        if not os.path.exists(ORIGINAL_AUDIO_FILE) or os.path.getsize(ORIGINAL_AUDIO_FILE) == 0:
            raise RuntimeError(f"Audio extraction failed to produce a valid file: {ORIGINAL_AUDIO_FILE}")
    else:
        print(f"Original audio already exists: {ORIGINAL_AUDIO_FILE}")

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
    total_start_time = time.time()
    chunks_to_process = total_chunks
    if TEST_MODE_CHUNKS is not None:
        chunks_to_process = min(total_chunks, TEST_MODE_CHUNKS)
        print(f"*** TEST MODE: Only processing {chunks_to_process} chunk(s) ***")

    for i in range(chunks_to_process):
        chunk_name = f"chunk_{i:03d}"
        chunk_start_time = time.time()
        print(f"\nProcessing Chunk {i+1} / {total_chunks} ({chunk_name})")

        # Use dynamic extension for input chunks
        input_chunk = os.path.join(INPUT_CHUNKS_DIR, f"{chunk_name}{INPUT_EXT}")
        esrgan_temp_work_dir = os.path.join(ESRGAN_CHUNKS_DIR, f"{chunk_name}_temp_work")
        esrgan_output_file = os.path.join(ESRGAN_CHUNKS_DIR, f"{chunk_name}_esrgan.mp4")
        
        rife_in_frames_dir = os.path.join(ESRGAN_CHUNKS_DIR, f"{chunk_name}_rife_in_frames")
        rife_out_frames_dir = os.path.join(RIFE_CHUNKS_DIR, f"{chunk_name}_rife_out_frames")
        rife_output_file = os.path.join(RIFE_CHUNKS_DIR, f"{chunk_name}_rife.mp4")

        if os.path.exists(rife_output_file) and os.path.getsize(rife_output_file) > 0:
            print(f"  > Chunk already processed. Skipping.")
            cleanup_intermediate_files(input_chunk, esrgan_output_file, rife_in_frames_dir, rife_out_frames_dir)
            continue
        
        if not os.path.exists(input_chunk):
            print(f"  > WARNING: Input chunk {input_chunk} missing. Skipping.")
            continue

        # --- Step 1: Run Real-ESRGAN ---
        if not os.path.exists(esrgan_output_file) or os.path.getsize(esrgan_output_file) == 0:
            
            os.makedirs(esrgan_temp_work_dir, exist_ok=True)

            print(f"  > Pre-filtering for VHS (denoise, deblock, sharpen)...")
            prefiltered_chunk = os.path.join(esrgan_temp_work_dir, f"{chunk_name}_prefiltered.mp4")
            cmd_prefilter = [
                "ffmpeg", "-y",
                "-i", input_chunk,
                "-vf", "hqdn3d=3:3:6:6,pp=ac,unsharp=3:3:0.6",
                "-c:v", "libx264", "-crf", "16", # <-- Quality Fix: CRF 16 for master fidelity
                "-preset", "slower", # <-- Quality Fix: 'slower' for maximum detail
                "-pix_fmt", "yuv420p",
                prefiltered_chunk
            ]
            try:
                subprocess.run(cmd_prefilter, check=True, capture_output=True, text=True)
            except subprocess.CalledProcessError as e:
                print(f"\n--- ERROR: FFmpeg pre-filtering failed on {chunk_name} ---")
                print("STDOUT:", e.stdout)
                print("STDERR:", e.stderr)
                raise

            print(f"  > Running Real-ESRGAN...")
            cmd_realesrgan = [
                "python3", "inference_realesrgan_video.py",
                "-i", prefiltered_chunk, 
                "-n", REALSRGAN_MODEL,
                "-o", esrgan_temp_work_dir, "-s", str(SCALE_FACTOR),
                "--fps", source_fps_str,
            ]
            try:
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
        print(f"  > Extracting frames for RIFE...")
        os.makedirs(rife_in_frames_dir, exist_ok=True)
        cmd_extract = [
            "ffmpeg", "-i", esrgan_output_file,
            os.path.join(rife_in_frames_dir, "frame_%08d.png")
        ]
        try:
            subprocess.run(cmd_extract, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            print(f"\n--- ERROR: FFmpeg frame extraction failed on {chunk_name} ---")
            print("STDOUT:", e.stdout)
            print("STDERR:", e.stderr)
            raise

        print(f"  > Running RIFE (directory mode)...")
        os.makedirs(rife_out_frames_dir, exist_ok=True)
        cmd_rife = [ 
            RIFE_BIN, 
            "-i", rife_in_frames_dir, 
            "-o", rife_out_frames_dir,
            "-s", "0.5"
        ]
        try:
            subprocess.run(cmd_rife, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            print(f"\n--- ERROR: RIFE failed on {chunk_name} ---")
            print("STDOUT:", e.stdout)
            print("STDERR:", e.stderr)
            raise
        
        print("  > Verifying RIFE frame count...")
        in_frames = glob.glob(os.path.join(rife_in_frames_dir, "*.png"))
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
            "-pix_fmt", "yuv420p",
            "-crf", "17", # <-- Quality Fix: CRF 17 for high-bitrate 4K assembly
            "-preset", "slower", # <-- Quality Fix: 'slower' for maximum fidelity
            rife_output_file
        ]
        try:
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
        print(f"  > Chunk finished in {duration_sec:.2f} seconds.")

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

    with open(CONCAT_FILE, "w") as f:
        for i in range(total_processed_chunks):
            chunk_path = os.path.join(RIFE_CHUNKS_DIR, f"chunk_{i:03d}_rife.mp4")
            if not os.path.exists(chunk_path):
                print(f"Warning: Missing chunk {chunk_path}. Assuming this is the end.")
                break
            f.write(f"file '{os.path.abspath(chunk_path)}'\n")

    print(f"Concatenation list created: {CONCAT_FILE}")

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
