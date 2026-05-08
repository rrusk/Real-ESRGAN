# DVD Preservation Workflow

A pipeline for extracting, preserving, and distributing DVD video content as
modern MP4 and MKV files with proper chapter markers.  Supports two encode
paths: a fast deterministic Lanczos upscale, and an AI upscale via Real-ESRGAN.

---

## Scripts

| Script | Purpose |
|---|---|
| `dvd_extract.sh` | Extract MPEG-2 video and chapter timestamps from a DVD ISO |
| `dvd_enhance.sh` | Encode extracted MPG to distribution MP4 + MKV (Lanczos upscale) |
| `dvd_enhance_ai.sh` | Add chapters to Real-ESRGAN MKV and produce distribution MP4 |
| `dvd_add_chapters.sh` | Add chapter markers to an existing MKV or MP4 (standalone) |
| `video_upscale_pipeline.py` | AI upscale via Real-ESRGAN |

---

## Dependencies

All available via `apt` on Ubuntu/Debian:

```bash
sudo apt install ffmpeg mkvtoolnix gpac ogmtools lsdvd xxhash python3
```

---

## Workflow Overview

```
DVD ISO
  │
  ▼
dvd_extract.sh
  │  file.mpg                        (lossless MPEG-2, 720x480 BFF interlaced)
  │  file_title_02_chapters.txt      (OGM chapter timestamps from DVD IFO)
  │  file_lsdvd.py                   (disc structure for inspection)
  │
  │  [manual step: transcribe chapter titles from DVD menu]
  │  file_chapters.txt               (one title per line)
  │
  ├── Path A: Lanczos upscale ──────────────────────────────────────────────────
  │
  │   dvd_enhance.sh --names file_chapters.txt file.mpg
  │     → file.mp4           (H.264/AAC, 1440x960, chapters embedded)
  │     → file.mkv           (instant MKV remux, chapters embedded)
  │
  └── Path B: AI upscale (Real-ESRGAN) ─────────────────────────────────────────

      video_upscale_pipeline.py file.mpg
        → outputs/file_balanced_x2_x2plus_60fps.mkv   (AI upscaled, playable)

      dvd_enhance_ai.sh \
          --names file_chapters.txt \
          outputs/file_balanced_x2_x2plus_60fps.mkv
        → outputs/file_balanced_x2_x2plus_60fps.mkv   (chapters added in-place)
        → outputs/file_balanced_x2_x2plus_60fps.mp4   (stream-copy + chapters)
```

---

## Step 1 — Extract from ISO

```bash
dvd_extract.sh -o <output_dir> <file.iso>
```

**What it does:**
- Mounts the ISO, identifies content VOBs (excludes menu `_0.VOB` files)
- Runs `lsdvd` to count titles, show durations, and flag the likely main content
- Extracts one OGM chapter timestamp file per title via `dvdxchap`
- Concatenates content VOBs into a single MPEG-2 stream via ffmpeg (stream copy, lossless)
- Verifies integrity with XXH64

**Output files** (written to `<output_dir>`):

| File | Contents |
|---|---|
| `<name>.mpg` | Lossless MPEG-2 stream, 720×480 BFF interlaced (NTSC DVD) |
| `<name>_title_NN_chapters.txt` | OGM chapter timestamps, one file per title |
| `<name>_lsdvd.py` | Full disc structure (Python dict, for inspection) |

Re-running the same ISO overwrites the previous output files — no timestamps
in filenames.

**Example output:**

```
  lsdvd: 2 title(s) found on disc.

  Title   Duration     Chapters  Note
  ------  -----------  --------  ----
  1       00:00:38.70  1
  2       00:44:56.60  11        <-- longest (likely main content)

  [WARN] Title 1 is only 00:00:38.70 -- likely a short intro or menu.

  [OK] Title 1: 1 chapter(s)  -> The First Dance_title_01_chapters.txt
  [OK] Title 2: 11 chapter(s) -> The First Dance_title_02_chapters.txt
```

The chapter count in the summary (`11 chapter(s)`) is the key — match this
against the DVD menu to confirm which title to use.

---

## Step 2 — Create the chapter names file (manual)

This is the **only manual step** in the workflow.  Read the chapter titles from
the DVD menu and write them to a plain-text file, one title per line, in order:

```
TheFirstDance_chapters.txt
──────────────────────────
Introduction
The Basic
Hip Rock
Underarm Turn
Backwards Walk
The Promenade
Promenade Pivots
The Dip
Triple Underarm Turn
The Grapevine
Open Out Side to Side
```

The line count must exactly match the chapter count in the OGM file you will
use (11 lines for `_title_02_chapters.txt` in this example).

Keep this file alongside the ISO as a permanent record — it is reused for
both the Lanczos and AI upscale paths.

---

## Path A — Lanczos upscale encode

Single command.  Deinterlaces, applies noise reduction, scales 2× via Lanczos,
encodes H.264/AAC, embeds chapters, and produces both MP4 and MKV.

The chapter file is **auto-detected** when `--names` is provided — the script
finds `_title_NN_chapters.txt` files in the same directory as the MPG and
matches by chapter count.

```bash
dvd_enhance.sh \
    --names TheFirstDance_chapters.txt \
    'The First Dance.mpg'
```

**Output:**

| File | Description |
|---|---|
| `The First Dance.mp4` | H.264/AAC, 1440×960, chapters embedded |
| `The First Dance.mkv` | Instant MKV remux, chapters embedded |

**What happens internally:**

1. Probes source codec, resolution, field order, and timestamps
2. Detects 720×480 NTSC BFF interlaced → selects `bwdif` deinterlace
3. Checks available disk space before starting
4. Encodes: `bwdif → yuv420p → hqdn3d=2:2:6:6,pp=fd,unsharp=3:3:0.2 → Lanczos 2×`
5. Validates output duration matches source
6. Injects chapters into MP4 via MP4Box
7. Remuxes MP4 → MKV (no re-encode, ~30 seconds)
8. Injects chapters into MKV via mkvpropedit (in-place, instant)
9. XXH64 integrity hash of both files

**Quick 30-second test:**

```bash
dvd_enhance.sh --test --names TheFirstDance_chapters.txt 'The First Dance.mpg'
```

**Key options:**

| Option | Effect |
|---|---|
| `--scale 1` | No upscale (720×480 output) |
| `--scale 4` | 4× Lanczos (2880×1920) |
| `--profile aggressive` | Stronger denoise for noisy or low-bitrate source |
| `--profile halo` | Suppress ringing/ghosting around edges |
| `--mode0` | 30fps output instead of 60fps (smaller file) |
| `--crf 20` | Slightly lower quality, meaningfully smaller file |
| `--mp4-only` | Produce only MP4 |
| `--mkv-only` | Produce only MKV |

---

## Path B — AI upscale via Real-ESRGAN

### Step B1 — Run the AI upscale pipeline

Feed the extracted MPG directly to `video_upscale_pipeline.py`.  The pipeline
handles deinterlacing and pre-filtering internally.

```bash
video_upscale_pipeline.py 'The First Dance.mpg'
```

The pipeline produces a directly playable MKV in the `outputs/` subdirectory.
The output filename encodes the profile, scale, model, and frame rate used:

```
outputs/The First Dance_balanced_x2_x2plus_60fps.mkv
```

**Common options:**

| Option | Effect |
|---|---|
| `--scale 4` | 4× upscale (2880×1920 from 720×480) |
| `--profile aggressive` | Stronger pre-filter for noisy source |
| `--rife` | RIFE frame interpolation (use only with 30fps `--mode0` source) |
| *(default)* | 2× upscale, balanced profile, 60fps field-rate output |

> **Note:** The default output is ~60fps (bwdif mode=1 field-rate frames).
> Do not use `--rife` with this output — RIFE would double an already-doubled
> frame rate.  RIFE is only appropriate when the source was prepared with
> `bwdif mode=0` (30fps output).

### Step B2 — Add chapters and produce distribution MP4

`dvd_enhance_ai.sh` takes the Real-ESRGAN MKV and:
1. Injects chapters **in-place** into the MKV (mkvpropedit — instant, no remux)
2. Produces a distribution MP4 via ffmpeg stream copy (no re-encode) + MP4Box chapters

The chapter file is auto-detected by matching chapter count to the names file.

```bash
dvd_enhance_ai.sh \
    --names TheFirstDance_chapters.txt \
    'outputs/The First Dance_balanced_x2_x2plus_60fps.mkv'
```

**Output:**

| File | Description |
|---|---|
| `outputs/The First Dance_balanced_x2_x2plus_60fps.mkv` | AI upscaled MKV, chapters injected in-place |
| `outputs/The First Dance_balanced_x2_x2plus_60fps.mp4` | Stream-copy MP4, chapters embedded |

No video re-encoding occurs in either step.  The AI upscale quality is
preserved exactly in both output files.

**Options:**

| Option | Effect |
|---|---|
| `--no-mp4` | Inject MKV chapters only; skip MP4 production |
| `-o <stem>` | Override output filename stem |

---

## Output file compatibility

| Format | Android | iOS/iPhone | Windows | macOS | Chapter editing |
|---|---|---|---|---|---|
| MP4 (H.264 + AAC) | ✅ Native | ✅ Native | ✅ Native | ✅ Native | MP4Box remux required |
| MKV (H.264 + AAC) | ✅ VLC | ✅ VLC/Infuse | ✅ VLC | ✅ VLC | `mkvpropedit` in-place |

For USB stick distribution to a general audience, **MP4** is the safest choice.
**MKV** is preferred for archive copies and ongoing editing (chapters can be
updated at any time with no quality loss).

---

## Updating chapter names after the fact

**MKV — instant, no remux, no quality loss:**

```bash
mkvpropedit output.mkv --chapters The\ First\ Dance_title_02_chapters.txt
```

Or with named chapters via `dvd_add_chapters.sh`:

```bash
dvd_add_chapters.sh \
    --names TheFirstDance_chapters.txt \
    output.mkv \
    'The First Dance_title_02_chapters.txt'
```

**MP4 — requires MP4Box remux (fast, no re-encode, writes new file):**

```bash
dvd_add_chapters.sh \
    --names TheFirstDance_chapters.txt \
    output.mp4 \
    'The First Dance_title_02_chapters.txt'
```

---

## Source characteristics (NTSC DVD)

| Property | Value | Notes |
|---|---|---|
| Container | MPEG-2 Program Stream | `.mpg` / `.vob` |
| Video codec | MPEG-2 | Up to 9.8 Mbps (this disc: 8.22 Mbps — near maximum) |
| Resolution | 720×480 | Standard NTSC D1 |
| Frame rate | 29.97fps | Stored as 30000/1001 |
| Scan type | Interlaced BFF | Bottom Field First — NTSC standard; must deinterlace before upscaling |
| SAR | 8:9 | Gives 4:3 display (640×480 displayed); preserved in all output files |
| Audio | AC3 (Dolby Digital) | 192 kbps stereo; transcoded to AAC for MP4/MKV output |
| Chapter info | Stored in IFO files | Timestamps extracted by `dvdxchap`; names must be added manually |

---

## File naming reference

Files produced by `dvd_extract.sh -o <dir> <name>.iso`:

```
<name>.mpg                         Lossless MPEG-2 extract
<name>_title_01_chapters.txt       OGM chapters, title 1 (often short intro)
<name>_title_02_chapters.txt       OGM chapters, title 2 (usually main content)
<name>_lsdvd.py                    Disc structure (Python dict, lsdvd -Oy format)
```

User-created (manual step, keep alongside ISO):

```
<name>_chapters.txt                Chapter titles from DVD menu, one per line
```

Files produced by `dvd_enhance.sh --names <name>_chapters.txt <name>.mpg`:

```
<name>.mp4                 Distribution MP4, H.264/AAC, 1440x960, chapters embedded
<name>.mkv                 Archival MKV, same streams, chapters embedded
<name>_TEST.mp4/.mkv       30-second test clip (--test flag)
```

Files produced by `video_upscale_pipeline.py <name>.mpg`:

```
outputs/<name>_<profile>_x2_x2plus_60fps.mkv    AI upscaled MKV (directly playable)
```

Files produced by `dvd_enhance_ai.sh --names <name>_chapters.txt <upscaled>.mkv`:

```
<upscaled>.mkv     AI upscaled MKV with chapters injected in-place (modified)
<upscaled>.mp4     Stream-copy MP4 with chapters embedded (new file)
```

---

## Troubleshooting

**Duration mismatch warning after encode**

The source MPEG-2 has non-monotonous DTS from VOB concatenation.  `dvd_enhance.sh`
uses `-fflags +genpts` to repair timestamps.  A small delta (< 2s) is normal.
A large delta indicates potential source corruption near the end of the file.

**No audio in VLC from the extracted MPG**

The source AC3 uses S/PDIF passthrough which some VLC configurations do not
support.  Use `mpv` instead, or disable S/PDIF in VLC preferences (`--no-spdif`).
All encoded output files use AAC which plays natively everywhere.

**`MP4Box` not found**

The binary is `MP4Box` (capital M, capital B):

```bash
sudo apt install gpac
which MP4Box    # should return /usr/bin/MP4Box
```

**Disk space**

`dvd_enhance.sh` estimates required space before encoding and aborts if
insufficient.  For a 45-minute NTSC DVD at 2× Lanczos upscale, expect:

- MP4: ~5–8 GB
- MKV: ~5–8 GB
- MP4Box temp copy during chapter injection: one additional MP4 copy
- Total free space recommended: ~20 GB

`video_upscale_pipeline.py` auto-tunes chunk size based on available disk space
and warns before starting if space is insufficient.
