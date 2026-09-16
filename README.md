# Emby HEVC Transcode

`emby-hevc-transcode.sh` is a defensive Bash script for reducing the storage footprint of an Emby media library by converting compatible MKV and MP4 files to hardware-encoded HEVC/H.265 with Intel VA-API.

It was created for large Emby TV and movie libraries where retaining the content matters, but the original files—especially high-bitrate H.264/AVC releases—consume more disk space than is necessary for normal playback. The script targets a practical balance of visual quality, storage reduction, and direct-play compatibility on Roku devices.

The script defaults to **non-destructive operation**. It writes a new file next to the original, validates the result, and only deletes the source when `--destructive` is explicitly requested.

## Highlights

- Converts `.mkv` and `.mp4` input files to `.mkv` output files.
- Uses Intel GPU hardware acceleration through VA-API and `/dev/dri/renderD128` by default.
- Encodes HEVC/H.265 as **HEVC Main**, 8-bit `yuv420p`.
- Uses VA-API constant-QP quality control with a default QP of `22`.
- Converts video to a required output height of either `720p` or `1080p`.
- Preserves the original frame rate and aspect ratio.
- Copies audio, subtitles, attachments, data streams, metadata, and chapters.
- Supports individual-file and recursive directory processing.
- Supports a no-change `--dry-run` mode.
- Uses same-directory temporary files and a final rename only after output validation.
- Can remove an original source and its matching sidecars only after a successful conversion when `--destructive` is specified.
- Creates a timestamped TSV run log in the directory from which the script is started.
- Uses a per-start-directory lock to avoid accidentally running two copies of the script against the same working tree.
- Enforces a destination free-space reserve, defaulting to 50 GiB.

## Why HEVC

HEVC/H.265 is generally more storage-efficient than H.264/AVC at a comparable viewing quality. This is especially useful for large TV libraries containing high-bitrate Blu-ray or WEB-DL H.264 files.

For example, an episode originally stored as a 1.5 GB 1080p Blu-ray H.264 file was converted to a 720p HEVC file of approximately 557 MB—about a 63% size reduction—while retaining surround audio and subtitle streams.

The script deliberately targets **HEVC Main, 8-bit, 4:2:0**. That format is broadly compatible with modern Roku 4K-class devices and is a practical choice for Emby Direct Play when the client hardware has been validated.

> Test the output through your own Emby clients before running a large batch. Device, TV, AVR, subtitle, and passthrough behavior varies.

## Processing policy

The script intentionally skips files that are likely to require a separate workflow or careful manual review:

| Source condition | Action | Reason |
|---|---|---|
| HEVC already at the requested target height | Skip | Avoids another lossy HEVC generation.
| Source is smaller than the requested target height | Skip | The script never upscales.
| HDR, HDR10, HDR10+, HLG, Dolby Vision, BT.2020, or >8-bit video | Skip | HDR-to-SDR/HDR processing needs a separate, validated tone-mapping workflow.
| Interlaced video | Skip | Avoids unreviewed deinterlacing and cadence changes.
| More than one video stream | Skip | Avoids creating mixed or ambiguous multi-video-stream outputs.
| Expected output file already exists | Stop the run | Prevents accidental overwrites or filename collisions.

Audio and subtitle streams are copied rather than transcoded. This preserves existing DTS, E-AC-3, AC-3, AAC, and other audio tracks, including multichannel surround sound, without risking audio-sync changes or additional audio quality loss.

## Requirements

### Operating system and shell

- Linux.
- Bash 4 or later.
- Sufficient permissions to read the source media, create files in the destination directory, rename files, and—if using `--destructive`—delete the source and matching sidecar files.

### Intel GPU and VA-API

The default workflow expects an Intel GPU exposed through VA-API:

```text
/dev/dri/renderD128
```

The script uses:

```text
hevc_vaapi
scale_vaapi
```

Verify that the GPU device is present:

```bash
ls -l /dev/dri/
```

Verify that the current user can access it:

```bash
test -r /dev/dri/renderD128 && test -w /dev/dri/renderD128 && echo "VA-API device access OK"
```

Check the VA-API driver and HEVC encoding capability:

```bash
vainfo --display drm --device /dev/dri/renderD128
```

Look for an HEVC Main encode capability similar to:

```text
VAProfileHEVCMain : VAEntrypointEncSlice
```

### Required commands

The script checks for these utilities at startup:

```text
ffmpeg
ffprobe
find
awk
df
flock
stat
nice
```

`ionice` is optional. If it is available, the script uses it by default to reduce I/O contention during library conversions.

Verify FFmpeg support:

```bash
ffmpeg -hide_banner -h encoder=hevc_vaapi
ffmpeg -hide_banner -h filter=scale_vaapi
```

Both commands must exit successfully.

### Debian/Ubuntu installation example

Package names vary by distribution and repository configuration. On Debian or Ubuntu-derived systems, the following is a typical starting point:

```bash
sudo apt update
sudo apt install -y ffmpeg vainfo util-linux
```

For modern Intel integrated graphics, the Intel media driver is normally required. Depending on your distribution/repositories, it may be named `intel-media-va-driver` or `intel-media-va-driver-non-free`.

```bash
sudo apt install -y intel-media-va-driver
```

If `vainfo` reports that it successfully loads `iHD_drv_video.so`, the Intel media driver is working.

## Installation

Clone the repository or download the script, then make it executable:

```bash
chmod +x emby-hevc-transcode.sh
```

Check the built-in documentation:

```bash
./emby-hevc-transcode.sh --help
```

The script should normally be run from a shell environment that can access both:

- The media-library path as mounted in that environment.
- The Intel render node, normally `/dev/dri/renderD128`.

When running in a container, this generally means the media mount and `/dev/dri` must both be passed into the container, and the container user must have the necessary numeric UID/GID and render-device permissions.

## Basic usage

Exactly one selection mode is required:

- `--file FILE` for one explicit media file.
- `--recursive` to scan the current directory and all child directories.

A target resolution is always required:

- `--resolution 720`
- `--resolution 1080`

### Convert one file

```bash
./emby-hevc-transcode.sh \
  --file "2 Broke Girls - S01E01 - Pilot Bluray-1080p.mkv" \
  --resolution 720
```

Short-option equivalent:

```bash
./emby-hevc-transcode.sh \
  -f "2 Broke Girls - S01E01 - Pilot Bluray-1080p.mkv" \
  -p 720
```

### Dry run first

Always begin a new library section with `--dry-run`:

```bash
./emby-hevc-transcode.sh \
  --file "2 Broke Girls - S01E01 - Pilot Bluray-1080p.mkv" \
  --resolution 720 \
  --dry-run
```

Dry-run mode prints the intended processing decision and target output path but does not:

- Encode media.
- Create temporary files.
- Rename or delete anything.
- Write a normal conversion log.

### Recursively process a show or season

Change into the desired show, season, or library root directory:

```bash
cd "/mnt/nfs/MyEmbyMedia/TV/2 Broke Girls (2011)"
```

Preview the candidates:

```bash
/path/to/emby-hevc-transcode.sh \
  --recursive \
  --resolution 720 \
  --dry-run
```

After reviewing the planned actions, run the real conversion:

```bash
/path/to/emby-hevc-transcode.sh \
  --recursive \
  --resolution 720
```

### Convert to 1080p HEVC

Use this when preserving 1080p rather than downscaling:

```bash
./emby-hevc-transcode.sh \
  --recursive \
  --resolution 1080
```

Examples of expected behavior:

- 1080p H.264 input with a 1080p target: encoded to 1080p HEVC.
- 2160p SDR 8-bit input with a 1080p target: downscaled and encoded to 1080p HEVC.
- 720p input with a 1080p target: skipped; no upscaling.
- 1080p HEVC input with a 1080p target: skipped; no second HEVC encode.

## Output naming

All output files use the MKV container.

When a terminal source-quality label is recognized, the script retains that source label and replaces its resolution tag with an HEVC target label:

| Input filename | Output filename at 720p |
|---|---|
| `Episode Bluray-1080p.mkv` | `Episode Bluray-HEVC-720p.mkv` |
| `Episode WEBDL-1080p.mkv` | `Episode WEBDL-HEVC-720p.mkv` |
| `Episode WebDL-720P.mkv` | `Episode WebDL-HEVC-720p.mkv` |
| `Episode WEB-DL-2160P.mp4` | `Episode WEB-DL-HEVC-720p.mkv` |
| `Episode HDTV-1080p.mkv` | `Episode HDTV-HEVC-720p.mkv` |
| `Episode.mkv` | `Episode HEVC-720p.mkv` |

Recognized source labels are case-preserving and include:

```text
Bluray, Blu-ray, WEBDL, WEB-DL, WEBRip, WEB-RIP,
HDTV, REMUX, DVD, DVDRip, BDRip, BRRip
```

The script preserves the spelling from the input filename. For example, `WebDL-720P` becomes `WebDL-HEVC-720p`.

## Non-destructive mode

Non-destructive mode is the default. The source remains in place after a successful conversion.

For example:

```text
Original:
2 Broke Girls - S01E02 - And the Break-Up Scene Bluray-1080p.mkv

New output:
2 Broke Girls - S01E02 - And the Break-Up Scene Bluray-HEVC-720p.mkv
```

The workflow is:

1. Inspect the source with `ffprobe`.
2. Create a unique hidden temporary MKV in the output directory.
3. Transcode video through VA-API.
4. Validate the temporary output as HEVC Main, `yuv420p`, and the requested output height.
5. Rename the temporary file to its final name.
6. Retain the original source.

A temporary filename can be long; that is expected. It includes the intended final output name, process ID, and a high-resolution timestamp to prevent collisions:

```text
.emby-hevc-tmp-<final-output-name>.<pid>.<timestamp>.mkv
```

## Destructive mode

`--destructive` removes the original source only after the replacement output successfully finishes and passes validation.

```bash
./emby-hevc-transcode.sh \
  --file "Episode Bluray-1080p.mkv" \
  --resolution 720 \
  --destructive
```

For each successful conversion, it deletes:

- The original `.mkv` or `.mp4` source.
- Matching same-basename `.bif` files.
- Matching same-basename `.jpg` and `.jpeg` files.
- Matching same-basename `.png` files.
- Matching same-basename `.nfo` files.
- Matching same-basename `.vtt` files.

The sidecar match is limited to files in the same directory whose filename begins with the exact source basename followed by `.` or `-`.

For example, for:

```text
2 Broke Girls - S01E01 - Pilot Bluray-1080p.mkv
```

these files qualify for removal:

```text
2 Broke Girls - S01E01 - Pilot Bluray-1080p-320-10.bif
2 Broke Girls - S01E01 - Pilot Bluray-1080p.nfo
2 Broke Girls - S01E01 - Pilot Bluray-1080p-thumb.jpg
```

Directory-level artwork and metadata such as `folder.jpg`, `poster.jpg`, `season01.jpg`, or `tvshow.nfo` are not matched by this rule.

> Do not use `--destructive` until you have watched and validated representative output on every Emby playback device you use.

## Options

| Option | Description |
|---|---|
| `-f FILE`, `--file FILE` | Convert one `.mkv` or `.mp4` file. Required unless `--recursive` is used. |
| `-r`, `--recursive` | Search the current directory tree for `.mkv` and `.mp4` files. Required unless `--file` is used. |
| `-p 720\|1080`, `--resolution 720\|1080` | Required target video height. |
| `-d`, `--destructive` | Delete source and matching sidecars after a validated output is installed. |
| `-n`, `--dry-run` | Preview actions without modifying media files. |
| `--qp N` | VA-API HEVC CQP quality value from 0 to 51. Default: `22`. Lower values generally increase quality and file size. |
| `--min-free-gb N` | Minimum free space required before each conversion. Default: `50` GiB. |
| `--exclude PATH` | Exclude a directory subtree during a recursive scan. May be specified multiple times. |
| `--vaapi-device PATH` | Override the VA-API render node. Default: `/dev/dri/renderD128`. |
| `--nice N` | FFmpeg CPU scheduling priority, from `-20` to `19`. Default: `10`. |
| `--ionice CLASS:LEVEL` | FFmpeg I/O priority. Default: `idle:7`. Classes: `idle`, `best-effort`, `realtime`; levels: `0` through `7`. |
| `-h`, `--help` | Display complete command-line help. |

## Quality settings

The default is:

```text
--qp 22
```

VA-API CQP values are not directly comparable to software x265 CRF values. Lower QP values produce higher quality and usually larger files; higher values save more space but can introduce artifacts.

A practical test ladder for a representative episode is:

```bash
./emby-hevc-transcode.sh -f "Episode Bluray-1080p.mkv" -p 720 --qp 20
./emby-hevc-transcode.sh -f "Episode Bluray-1080p.mkv" -p 720 --qp 22
./emby-hevc-transcode.sh -f "Episode Bluray-1080p.mkv" -p 720 --qp 24
```

Use distinct output paths or rename/remove test outputs between runs; the script deliberately stops if its calculated output path already exists.

Suggested starting points:

| Content | Suggested QP | Notes |
|---|---:|---|
| Sitcoms, low-motion broadcast TV | 22–24 | A strong storage-saving target; validate gradients and motion. |
| Typical drama and general TV | 20–22 | Good balance of quality and storage. |
| Dark, grainy, fast-motion, or effects-heavy material | 18–22 | Lower QP protects detail, gradients, and motion. |
| Animation | 18–22 | Test carefully for line-art artifacts and color banding. |

## Logs

For non-dry runs, a tab-separated log is created in the directory where the command was started:

```text
emby-hevc-transcode-YYYYmmdd-HHMMSS.tsv
```

The log includes:

```text
status
reason
source
output
input_bytes
output_bytes
started
ended
ffmpeg_exit_code
```

Possible statuses include:

```text
CONVERTED
SKIPPED
FAILED
```

The script prints a summary at the end of each run:

```text
Summary: found=<n> converted_or_planned=<n> skipped=<n> failed=<n> deleted=<n>
```

## Validation after conversion

Inspect the primary video stream:

```bash
ffprobe -v error \
  -select_streams v:0 \
  -show_entries stream=codec_name,profile,pix_fmt,width,height,avg_frame_rate,bit_rate \
  -of default=noprint_wrappers=1 \
  "Episode Bluray-HEVC-720p.mkv"
```

For a 720p output, expect values similar to:

```text
codec_name=hevc
profile=Main
width=1280
height=720
pix_fmt=yuv420p
avg_frame_rate=24000/1001
```

`bit_rate=N/A` is common for the individual video stream in Matroska files and is not an error. Use file size and duration if you need to calculate an approximate overall bitrate.

Compare source and output sizes:

```bash
ls -lh \
  "Episode Bluray-1080p.mkv" \
  "Episode Bluray-HEVC-720p.mkv"
```

Finally, test the output through Emby on each target playback device:

1. Confirm normal playback is reported as Direct Play.
2. Test with subtitles disabled.
3. Test with subtitles enabled, particularly ASS subtitles.
4. Compare challenging scenes: dark gradients, fast motion, opening credits, faces, hair, fabric, and fine background detail.
5. Confirm multichannel audio behavior through the actual Roku, TV, and AVR/soundbar chain.

## Container notes

If the script runs inside a Docker/LXC container, the container needs:

- The media filesystem mounted read/write.
- `/dev/dri/renderD128` passed through.
- VA-API userspace drivers available inside the container.
- An FFmpeg build exposing `hevc_vaapi` and `scale_vaapi`.
- A container user whose numeric UID/GID can write to the media mount.
- Permission to read/write the render device.

For NFS-backed media, permission decisions are based on numeric UID/GID as observed by the NFS server. A username inside the container is not sufficient by itself; the effective numeric identity must have the required access.

## Operational recommendations

- Always use `--dry-run` on a new show, season, or directory before converting.
- Validate a few representative outputs before using `--recursive`.
- Start with non-destructive runs. Keep originals until you have tested output through Emby and all Roku clients.
- Keep conversion serial. One VA-API encode at a time is easier on NFS storage, keeps logs straightforward, and avoids competing with active Emby playback.
- Avoid using `--destructive` until the desired QP/resolution profile is proven for that class of content.
- Use `--exclude` for staging, recycle-bin, cache, or special-purpose directories.
- Keep the generated TSV logs as an audit and recovery record.
- Back up important library metadata and review the sidecar cleanup behavior before the first destructive batch.

## Limitations

- This is not an HDR conversion or tone-mapping tool.
- It does not handle Dolby Vision, HDR10+, HLG, BT.2020, or 10-bit sources; those are skipped intentionally.
- It does not deinterlace video; interlaced sources are skipped intentionally.
- It does not convert audio codecs or channels. Audio is copied as-is.
- It does not guarantee direct play on every client. Playback compatibility depends on the exact Roku model, firmware, Emby client behavior, display, AVR/soundbar, and subtitle format.
- It is designed for one video stream per file. Files with multiple video streams are skipped for manual review.
- Filename recognition covers common terminal Sonarr-style source/resolution suffixes, but media libraries with unusual or embedded release naming should be dry-run tested before bulk conversion.

## License

This project is licensed under the [MIT License](LICENSE).

Copyright © 2026 KittDoesntCode.
