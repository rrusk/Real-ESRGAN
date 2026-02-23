# Video Enhancement Process

To enhance vintage video—such as VHS, Hi8, or DV—for modern high-definition displays, this pipeline utilizes a two-stage process. It first repairs analog signal degradation using a shell script and then reconstructs missing detail through a Python-based AI framework.

---

## Phase 1: Signal Mastering (`prepare_video.sh`)

Before AI can improve a video, the technical flaws inherent in analog signals must be neutralized. AI models perform poorly if they attempt to upscale interlacing artifacts or head-switching noise.

### Smart Deinterlacing

Old television signals display half-frames (called "fields") in rapid succession rather than full frames — a technique called interlacing. When played back on a modern progressive display, this causes a "combing" effect: thin horizontal stripes that appear on moving objects because the two half-frames were captured at slightly different moments in time.

The script uses the **`bwdif` (Motion Adaptive High Quality Deinterlacer)** algorithm to analyze motion between fields and weave them into full, progressive frames, eliminating this combing. The field order — whether the top half or bottom half of each frame was captured first — is detected automatically from the source file and used to ensure the correct sequence is reconstructed.

The output is explicitly tagged as progressive to prevent downstream tools from misidentifying it as still interlaced.

### Chroma Alignment and Masking

Footage recorded on rotating-head formats — including VHS, Hi8, Video8, Betamax, and DV camcorders — often contains a flickering static line at the bottom of the frame. This is caused by the spinning recording head briefly transitioning between tracks at the end of each frame, known as head-switching noise. The script covers this with a clean black bar.

Even-numbered bar heights are enforced because digital video stores color information in 2×2 pixel blocks (a format called YUV 4:2:0). Masking an odd number of pixels splits these blocks unevenly, introducing green or purple fringing along the edge of the mask.

### Audio Strategy

The script detects the source audio format before processing and selects the most appropriate handling:

- **Uncompressed audio** (raw pulse-code modulation, or PCM) is re-encoded to AAC (Advanced Audio Coding) at 192kbps, because the MP4 container format does not support raw uncompressed audio.
- **All other compressed formats** (such as AC-3 Dolby Digital, MP3, or AAC) are copied directly without any re-encoding, preserving the original audio quality exactly.

### Timestamp Repair

Broken or unrealistic timing markers embedded in a video file can cause the encoder to produce incorrect output. This is commonly seen in raw analog captures (VHS, Hi8, Video8) and in footage that was previously processed through DVD authoring software such as iDVD, DVD Studio Pro, or Nero — which sometimes writes non-standard timing data into the output files. The script detects this condition automatically and enables timestamp regeneration to correct it before encoding begins.

### Mastering for Fidelity

The video is exported at a high quality level (CRF 16, where lower numbers mean higher quality) using a thorough compression pass (`-preset slower`). This ensures no new compression artifacts are introduced into the master file that would then be amplified by the AI upscaling stage.

---

## Phase 2: AI Reconstruction (`video_upscale_pipeline.py`)

Once the video is clean, the Python pipeline uses deep learning to increase resolution and smoothness. The script employs a chunking architecture to process segments individually, which manages disk space and provides robust crash recovery.

### Audio Separation and Verification

At the start of processing, the audio track is separated from the video and saved as a standalone file. This is done once and reused across all processing steps, avoiding any risk of audio drift or synchronization loss during the multi-step video processing.

The separation uses a lossless direct copy where the audio format allows it, falling back to high-quality variable bitrate MP3 encoding only when the source format is incompatible with the output container. After separation, the audio and video durations are compared, and the pipeline halts with a clear error message if they differ by more than 2 seconds — catching truncated or corrupted audio files before hours of processing begin.

### Chunking and Resume Architecture

The video is divided into segments (typically 90–120 seconds each, automatically sized based on available disk space) and each segment is processed independently through the full pipeline. This means a crash or power loss only loses the work on the current segment, not the entire video.

Completed segments are validated by checking for a readable video stream — not just checking whether the file exists and has a non-zero size — so partially written files from interrupted processing are detected and reprocessed automatically rather than being silently included in the final output. If the pipeline is interrupted for any reason, it resumes from exactly where it left off on the next run.

### 1. Pre-Filtering

Before the AI processes each segment, a three-stage cleaning pass is applied:

- **Noise reduction** (`hqdn3d`) — smooths grain, tape noise, and random pixel variation without blurring real edges.
- **Deblocking** (`pp=ac`) — removes the blocky compression artifacts common in the source encoding.
- **Sharpening** (`unsharp`) — restores edge definition softened by the noise reduction step.

This cleaning step is critical: it prevents the AI from treating noise and compression artifacts as real detail, which would cause them to be amplified and permanently baked into the upscaled output.

### 2. Spatial Upscaling (Real-ESRGAN)

Standard upscaling simply stretches pixels and blurs edges. This pipeline uses **Real-ESRGAN**, an artificial intelligence model trained on millions of image pairs to *reconstruct* fine textures — hair, fabric, foliage, writing — rather than simply interpolating between existing pixels. The result is sharp, detailed output that reflects what the scene would have looked like had it been recorded at high resolution, rather than a blurred enlargement of the low-resolution original.

An optional processing mode is available for sources with pronounced ringing or halo artifacts around edges — a common side effect of the heavy signal processing applied inside older analog equipment. This mode softens those artifacts before the AI sees them, preventing the AI from treating them as real edges and sharpening them into permanent digital blemishes.

### 3. Temporal Interpolation (RIFE)

Legacy video typically runs at 29.97 frames per second (North American standard, known as NTSC) or 25 frames per second (European standard, known as PAL). This can appear choppy on modern high-refresh-rate displays. The pipeline uses **RIFE (Real-Time Intermediate Flow Estimation)** to double the frame rate by generating new intermediate frames.

RIFE analyzes the motion of every region of the image between two consecutive frames — calculating where each part of the scene is moving and how fast — then synthesizes a new frame that accurately represents what the scene would have looked like at the midpoint in time. This doubles the frame rate (for example, from 29.97 to 59.94 frames per second) producing fluid, motion-accurate results rather than the blurring or ghosting that simpler methods produce.

### 4. Final Assembly and Display Geometry Correction

After all segments are processed they are joined back together in order and the original audio track is added back in. Both the video and audio are copied without re-encoding, preserving full quality.

Legacy video commonly uses non-square pixels — a technical quirk of how analog television standards were digitized. Standard definition NTSC 4:3 footage (including VHS, Hi8, Video8, Betamax, and DV camcorder recordings) stores each frame as 720×480 pixels, but those pixels are slightly taller than they are wide. The frame is intended to be displayed at 640×480, not stretched to fill a 720×480 square canvas. This is described by a value called the Sample Aspect Ratio (SAR).

After a 2× upscale to 1440×960 pixels, this non-square pixel information must be preserved in the output file. Without it, a media player assumes square pixels and displays the enhanced video at its full 1440×960 pixel dimensions. When the original is viewed at 2× zoom, the player doubles the raw pixel dimensions — 720×2 = 1440 wide, 480×2 = 960 tall — producing a window that is also 1440×960. Both windows are therefore the same size on screen. However, the player then applies the original's SAR correction, squeezing the displayed image inward to 1280 pixels wide within that 1440-pixel window. The result is that the original's image appears taller relative to its window width, while the enhanced video fills its window fully at 1440 wide and looks shorter by comparison — both windows the same size, but the image inside each a different shape.

With the metadata correctly applied, the player squeezes the enhanced video's display width from 1440 to 1280 pixels in the same way, giving both videos identical proportions.

The pipeline detects the source pixel shape automatically and writes these correct display dimensions into the container file's header using tools designed specifically for editing file metadata without touching the video itself (`mkvpropedit` for MKV files, `MP4Box` for MP4 files). This completes in seconds with no re-encoding, and any compliant media player then reads the metadata and displays the video at the correct proportions automatically.

---

## Summary of Techniques

| Phase | Step | Tool | Purpose |
|---|---|---|---|
| **1** | Deinterlacing | `bwdif` | Removes combing lines from interlaced analog video |
| **1** | Masking | `drawbox` | Covers head-switching noise at bottom of frame |
| **1** | Audio handling | Stream copy / AAC re-encode | Preserves audio quality within MP4 container limits |
| **1** | Timestamp repair | Timestamp regeneration | Fixes broken timing data from analog captures and DVD-authored footage |
| **1** | Mastering | CRF 16, slow preset | High-fidelity master file for AI input |
| **2** | Pre-filtering | Noise reduction, deblocking, sharpening | Removes artifacts before AI processes frames |
| **2** | Spatial upscaling | Real-ESRGAN | Increases resolution 2× using AI texture reconstruction |
| **2** | Frame interpolation | RIFE | Doubles frame rate using motion flow synthesis |
| **2** | Display geometry | `mkvpropedit` / `MP4Box` | Writes correct pixel shape into container file header |
| **2** | Resume protection | Validity checking | Detects and reprocesses corrupt segments automatically |
