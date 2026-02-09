# High-Quality Lossless Video Capture for AI Restoration

To achieve the best results with **Real-ESRGAN** and **RIFE**, you must capture the rawest analog signal possible. High-quality restoration is built on a foundation of data density; if you capture with heavy compression, your AI models will mistakenly "enhance" compression artifacts rather than actual detail.

### 1. The Playback: S-Video and TBC

Analog video quality is primarily determined by how the signal is pulled off the tape before it ever reaches your computer.

* **S-Video Connection**: Always use an **S-VHS VCR** with an **S-Video output**. Unlike the standard yellow composite (RCA) cables that mix color (Chroma) and brightness (Luma) data, S-Video keeps them separate. This prevents "dot crawl" and color bleeding, providing a much cleaner base for Real-ESRGAN.
* **Time Base Corrector (TBC)**: VHS signals are inherently unstable and "chaotic." A TBC (either built into a high-end VCR or as an external device) stabilizes the signal, removing "jitter" and ensuring the audio and video remain perfectly in sync.

### 2. The Capture: Lossless 480i

Your goal is to capture the video in its native state. Do not use devices that attempt to upscale or "clean" the video with cheap hardware chips; your AI pipeline will perform these tasks with much higher precision.

* **Hardware**: Use a reputable USB capture device such as the **Hauppauge USB-Live 2** or an internal PCIe card like the **Blackmagic Intensity Pro**.
* **Resolution and Scanning**: Capture at the native NTSC resolution of **720x480** (or 720x576 for PAL) in **Interlaced** mode. Capturing as progressive at this stage can lose half of your temporal data.
* **Codec**: Use a **Lossless or Near-Lossless codec** such as **HuffYUV**, **FFV1**, or **ProRes 422 HQ**. Standard H.264/MP4 capture discards up to 90% of the image data to save space, which is detrimental for AI processing.

### 3. The Digital Master

The final "capture" file will be significantly larger than a standard MP4—often 30GB to 50GB per hour of footage. While this file may look "combed" or "blocky" on a modern monitor due to interlacing and raw noise, it contains the complete digital blueprint of the magnetic tape.

[Image showing the comparison between a raw interlaced VHS frame and a compressed H.264 frame]

---

### Integration with the AI Pipeline

By capturing "raw" data, your pre-processing and enhancement scripts become exponentially more effective:

* **`prepare_video.sh`**: Has a high-bandwidth signal to perform a clean **BWDIF** de-interlace, preserving smooth motion for 60fps output.
* **Real-ESRGAN**: Can distinguish between actual film grain and digital noise, allowing for a natural-looking 4K upscale.
* **RIFE**: Has sharp, uncompressed object edges to track, resulting in fluid motion interpolation without "warping" artifacts.

### The Ideal Signal Path:

1. **S-VHS VCR** (with internal Line TBC) → **S-Video Out**.
2. **External Frame TBC** (Optional but recommended for sync).
3. **Lossless Capture Device** (Hauppauge USB-Live 2).
4. **Capture Software** (VirtualDub or AmarecTV) → **Lossless AVI**.
5. **Your Pipeline**: `prepare_video.sh` → `vhs_upscale_pipeline.py`.
