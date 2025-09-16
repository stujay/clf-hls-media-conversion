# CLF HLS Bash Workflow — Staff Instructions

## 1. `bin/hls-all.sh` — Batch encode → upload

**Use when:**  
You have one or more `.mp4` files in `./input/` and you want to process *everything* end-to-end (encode → upload → invalidate CloudFront).

**What it does:**  
- Scans `./input/*.mp4`  
- Runs `bin/hls-encode.sh` for each  
- Uploads to S3 via `bin/hls-upload.sh`  
- Optionally invalidates CloudFront caches

**Run (sequential):**


```bash
./bin/hls-all.sh

Run (parallel workers):

./bin/hls-all.sh --parallel 3
```

⸻

## 2. bin/hls-encode.sh — Encode one video to HLS (VOD ladder)

Use when:
You need to convert a single .mp4 into an HLS ladder locally before uploading.

What it does:
- Probes input video metadata (FPS, rotation, interlacing)
- Applies filters (rotation, deinterlace, scaling, padding, fps)
- Produces multiple vN.m3u8 + .ts segment sets
- Builds a master.m3u8 with ABR ladder

Run with defaults (6s segments, 4 renditions):
```

./bin/hls-encode.sh input/my-video.mp4 output/my-video
```

Override segment duration (e.g. 4s):
```

SEG_DUR=4 ./bin/hls-encode.sh input/my-video.mp4 output/my-video
```

Parallel renditions (2 at once):
```

PARALLEL=2 ./bin/hls-encode.sh input/my-video.mp4 output/my-video
```


⸻

##  3. bin/hls-upload.sh — Upload one encoded title to S3

Use when:
You’ve already encoded a video with hls-encode.sh and just want to push it to S3 + update CloudFront.

What it does:
	•	Syncs all files to S3 bucket under hls/<slug>/
	•	Corrects content-types: .m3u8 → application/vnd.apple.mpegurl, .ts → video/mp2t
	•	Sets caching: short TTL for masters, long TTL for segments
	•	Invalidates CloudFront (if CF_DISTRIBUTION_ID set)

Run with default prefix (hls/<basename>):
```
./bin/hls-upload.sh output/my-video

```

Run with explicit destination prefix:
```
./bin/hls-upload.sh output/my-video hls/custom-path

```


⸻

## 4. bin/cf-invalidate.sh — Manual CloudFront invalidation

Use when:
You want to force CloudFront to refresh one lesson/path manually.

Run:
```
./bin/cf-invalidate.sh ctf-s1-e1-intro

```

This invalidates:
```
/${S3_PREFIX}/ctf-s1-e1-intro/*

```

⸻

## Quick decision guide
- New batch of raw .mp4 files → run bin/hls-all.sh
- Single .mp4, local encode only → run bin/hls-encode.sh
- Already encoded, just upload → run bin/hls-upload.sh
- Force cache refresh → run bin/cf-invalidate.sh

