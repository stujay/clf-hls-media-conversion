#!/usr/bin/env bash
# bin/hls-upload.sh
# Upload one HLS title to S3 with correct content-types & caching, then (optionally) invalidate CF.
# Usage:
#   bin/hls-upload.sh output/ctf-s1-e1-intro [videos/ctf-s1-e1-intro]

set -euo pipefail

SRC="${1:-}"
DEST_PREFIX="${2:-hls/$(basename "${SRC}")}"
BUCKET="${AWS_S3_BUCKET_NAME:-cracking-language-media}"
PROFILE="${AWS_PROFILE:-clf-media}"
REGION="${AWS_REGION:-ap-southeast-1}"
CF_DISTRIBUTION_ID="${CF_DISTRIBUTION_ID:-EL2MA9MHDCE9G}"
CF_DOMAIN="${CF_DOMAIN:-d2hndeao0wd5o.cloudfront.net}"

[[ -n "${SRC}" && -d "${SRC}" ]] || { echo "Usage: $0 <local_output_dir> [dest_prefix]"; exit 1; }
S3="s3://${BUCKET}/${DEST_PREFIX}"

echo "→ Sync all files (quick push)…"
aws s3 sync "${SRC}" "${S3}" --only-show-errors --region "${REGION}" --profile "${PROFILE}"

echo "→ Fix content-type & caching for *.m3u8 (master + variants)…"
aws s3 cp "${SRC}" "${S3}" \
  --recursive --exclude "*" --include "*.m3u8" \
  --content-type "application/vnd.apple.mpegurl" \
  --cache-control "public,max-age=300" \
  --metadata-directive REPLACE \
  --region "${REGION}" --profile "${PROFILE}" --only-show-errors

echo "→ Fix content-type & caching for *.ts segments…"
aws s3 cp "${SRC}" "${S3}" \
  --recursive --exclude "*" --include "*.ts" \
  --content-type "video/mp2t" \
  --cache-control "public,max-age=31536000,immutable" \
  --metadata-directive REPLACE \
  --region "${REGION}" --profile "${PROFILE}" --only-show-errors

# Thumbnails + VTT (if present)
if [[ -d "${SRC}/thumbs" ]]; then
  echo "→ Uploading thumbnails + VTT…"
  aws s3 cp "${SRC}/thumbs" "${S3}/thumbs" \
    --recursive --exclude "*" --include "*.png" \
    --content-type "image/png" \
    --cache-control "public,max-age=31536000,immutable" \
    --metadata-directive REPLACE \
    --region "${REGION}" --profile "${PROFILE}" --only-show-errors || true

  aws s3 cp "${SRC}/thumbs" "${S3}/thumbs" \
    --recursive --exclude "*" --include "*.jpg" --include "*.jpeg" \
    --content-type "image/jpeg" \
    --cache-control "public,max-age=31536000,immutable" \
    --metadata-directive REPLACE \
    --region "${REGION}" --profile "${PROFILE}" --only-show-errors || true

  aws s3 cp "${SRC}/thumbs" "${S3}/thumbs" \
    --recursive --exclude "*" --include "*.webp" \
    --content-type "image/webp" \
    --cache-control "public,max-age=31536000,immutable" \
    --metadata-directive REPLACE \
    --region "${REGION}" --profile "${PROFILE}" --only-show-errors || true

  if [[ -f "${SRC}/thumbs/thumbs.vtt" ]]; then
    aws s3 cp "${SRC}/thumbs/thumbs.vtt" "${S3}/thumbs/thumbs.vtt" \
      --content-type "text/vtt" \
      --cache-control "public,max-age=300" \
      --metadata-directive REPLACE \
      --region "${REGION}" --profile "${PROFILE}" --only-show-errors || true
  fi
fi

# Invalidate master + playlists so clients see updates immediately
if [[ -n "${CF_DISTRIBUTION_ID}" ]]; then
  echo "→ CloudFront invalidate /${DEST_PREFIX}/*.m3u8 …"
  aws cloudfront create-invalidation \
    --distribution-id "${CF_DISTRIBUTION_ID}" \
    --paths "/${DEST_PREFIX}/master.m3u8" "/${DEST_PREFIX}/*.m3u8" \
    --profile "${PROFILE}" >/dev/null 2>&1 || true
fi

echo "✅ Done:"
echo "  s3://${BUCKET}/${DEST_PREFIX}/master.m3u8"
echo "  https://${CF_DOMAIN}/${DEST_PREFIX}/master.m3u8"
