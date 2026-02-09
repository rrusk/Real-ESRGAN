# VHS Enhancement Pipeline: Upscaling & Interpolation

This project provides an automated, chunk-based pipeline for enhancing low-resolution VHS footage. It utilizes **Real-ESRGAN** for spatial upscaling and **RIFE** for temporal interpolation, featuring a specialized "Auto-Tuning" system to manage processing on consumer-grade hardware with limited disk space.

## 1. Reference Specifications

This pipeline was developed using digitized NTSC VHS footage with the following baseline:

* **Resolution**: 352x240.
* **Frame Rate**: 29.97 fps.
* **Scan Type**: The AI models require **progressive** input. Interlaced source (480i) must be de-interlaced first to avoid AI artifacts.

## 2. Key Features

* **Dynamic Auto-Tuning**: Automatically calculates optimal chunk durations (10s–120s) by polling available disk space and estimating temporary file sizes.
* **Aggressive Resource Management**: Processes video in segments; temporary frames for a chunk are deleted immediately after that chunk is processed, keeping the total disk footprint minimal.
* **VHS-Optimized Pre-filtering**: Applies `hqdn3d` (denoise), `pp=ac` (deblock), and `unsharp` via FFmpeg to clean signals before upscaling.
* **Lossless Metadata Injection**: Includes utilities to mux OGM-formatted chapters into the final MKV container without re-encoding.

## 3. External Dependencies

The following components are required but are not included in the repository. They must be downloaded and placed in the project root.

### Binaries

* **RIFE-ncnn-vulkan**: Required for frame interpolation. Run the following commands in the project root to install:
```bash
wget https://github.com/nihui/rife-ncnn-vulkan/releases/download/20221029/rife-ncnn-vulkan-20221029-ubuntu.zip
unzip rife-ncnn-vulkan-20221029-ubuntu.zip
ln -s rife-ncnn-vulkan-20221029-ubuntu rife-ncnn-vulkan
chmod u+x rife-ncnn-vulkan/rife-ncnn-vulkan

```


* **MKVToolNix (`mkvmerge`)**: Required for the final muxing stage.
* **Installation**: `sudo apt install mkvtoolnix` (Ubuntu/Debian).



### Pre-trained Models (.pth)

Run the following block in your terminal to create the `models` directory and download the required weights:

```bash
mkdir -p models
wget -O models/RealESRGAN_x2plus.pth https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth
wget -O models/realesr-general-x4v3.pth https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth

```

## 4. Installation & Setup

### Virtual Environment

This pipeline requires specific versioning to maintain compatibility with `BasicSR` and older GPU architectures like the GTX 1060.

```bash
# Initialize environment
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip

# Install dependencies with version constraints
pip install "numpy<2.0"  # Critical for BasicSR compatibility
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu117
pip install ffmpeg-python opencv-python

# Build Real-ESRGAN components
pip install -r requirements.txt
python3 setup.py develop --user

# Verify the environment
python3 verify_env.py

```

> **Note:** Always ensure the environment is active before running any scripts: `source venv/bin/activate`

## 5. Experimental Workflow (Recommended)

Before processing a full video, use these steps to determine the best scaling factor. **Ensure your virtual environment is active.**

### Step 1: Prepare the Video (De-interlacing)

Before extracting clips or upscaling, check if your source is interlaced and generate a progressive master.

```bash
# Detects interlacing and creates a progressive .mp4 in outputs/ if needed
./prepare_video.sh inputs/my_tape.avi

```

### Step 2: Extract a Test Clip

Use the **progressive master** created in Step 1, or original video if it is already progressive, to cut a 10-second test segment.

```bash
# Usage: ./extract_test_clip.py <progressive_input> <start_time>
./extract_test_clip.py outputs/my_tape_progressive.mp4 00:10:45

```

### Step 3: Generate Comparison Versions

Process the test clip at both 2x and 4x scales.

```bash
./run_test_comparisons.py outputs/my_test_clip_progressive.mp4

```

### Step 4: 4-Way Comparison

Create a 4K side-by-side grid of Original, 2x, and 4x versions.

```bash
./compare_test_results.sh outputs/my_test_clip_progressive.mp4

```

**View in VLC**: Open the resulting grid in a loop for analysis:
`vlc --loop outputs/comparison_my_test_clip_4K_grid.mkv`

## 6. Usage Guide

### Running the Full Enhancement Pipeline

Once you've decided on a scale factor, process the entire progressive master. **Ensure your virtual environment is active.**

```bash
# 2x Upscale (Default)
python3 vhs_upscale_pipeline.py "outputs/my_tape_progressive.mp4"

# 4x Upscale with forced cleanup of previous attempts
python3 vhs_upscale_pipeline.py "outputs/my_tape_progressive.mp4" --scale 4 --force

```

### Adding Chapters

1. Create a text file (e.g., `toc.txt`) with timestamps and titles.
2. Run the muxing pipeline:

```bash
./mux_pipeline.sh "outputs/your_video_FINAL.mkv" "toc.txt"

```

## 7. Directory Structure

```text
.
├── rife-ncnn-vulkan/      # Symlink to RIFE binaries
├── models/                # .pth model weights
├── venv/                  # Python virtual environment (ignored by git)
├── outputs/               # Enhanced video results
├── realesrgan/            # Core Real-ESRGAN package
├── vhs_upscale_pipeline.py # Main enhancement driver
├── prepare_video.sh       # PRE-PROCESS: Deinterlaces if needed
├── probe_video.py         # DIAGNOSTIC: Detects interlacing
├── extract_test_clip.py   # EXPERIMENT: Cuts 10s segments
├── run_test_comparisons.py # EXPERIMENT: Orchestrates 2x/4x test runs
├── compare_test_results.sh # EXPERIMENT: Generates 4-way comparison grid
├── verify_env.py          # Environment version check
├── convert_chapters.py    # Chapter formatting utility
├── mux_pipeline.sh        # Chapter muxing script
├── setup.py               # Real-ESRGAN build script
├── requirements.txt       # Pipeline dependencies
└── README_Original.md     # Original Real-ESRGAN documentation

```

---
## Technical Note: De-interlacing Mode

The `prepare_video.sh` script utilizes the **BWDIF (Bob Weaver Deinterlacing Filter)** in **Mode 0**. This weaves fields together into a progressive 29.97p frame without dropping temporal data, providing the cleanest possible "base" for the AI models to process.

---

## Original Project Documentation

This project is a fork of Real-ESRGAN. For the original research, training details, and technical specifications, please refer to the **[README_Original.md](./README_Original.md)**.
