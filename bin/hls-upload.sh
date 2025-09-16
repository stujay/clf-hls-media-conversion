#!/usr/bin/env bash
# bin/hls-upload.sh
#
# Upload one HLS title to S3 with correct content-types & caching, then (optionally) invalidate CF.
# Usage:
#   bin/hls-upload.sh output/ctf-s1-e1-intro [hls/ctf-s1-e1-intro]
#
# Resulting URL:
#   https://<your-cloudfront-domain>/<dest_prefix>/master.m3u8

set -euo pipefail

SRC="${1:-}"                               # local directory produced by encoder
DEST_PREFIX="${2:-hls/$(basename "${SRC}")}"  # where to put it in the bucket (default under hls/)
BUCKET="${AWS_S3_BUCKET_NAME:-cracking-language-media}"
PROFILE="${AWS_PROFILE:-clf-media}"
REGION="${AWS_REGION:-ap-southeast-1}"
CF_DISTRIBUTION_ID="${CF_DISTRIBUTION_ID:-EL2MA9MHDCE9G}"   # set to "" to skip invalidation
CF_DOMAIN="${CF_DOMAIN:-d2hndeao0wd5o.cloudfront.net}"      # your CF domain (change if you use a CNAME)

if [[ -z "${SRC}" || ! -d "${SRC}" ]]; then
  echo "Usage: $0 <local_output_dir> [dest_prefix]" >&2
  echo "       e.g. $0 output/ctf-s1-e1-intro hls/ctf-s1-e1-intro" >&2
  exit 1
fi

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

# If you prefer long cache for variant playlists, uncomment the block below and keep master at 300s
# aws s3 cp "${SRC}" "${S3}" \
#   --recursive --exclude "*" --include "v*.m3u8" \
#   --content-type "application/vnd.apple.mpegurl" \
#   --cache-control "public,max-age=31536000,immutable" \
#   --metadata-directive REPLACE \
#   --region "${REGION}" --profile "${PROFILE}" --only-show-errors

echo "→ Fix content-type & caching for *.ts segments…"
aws s3 cp "${SRC}" "${S3}" \
  --recursive --exclude "*" --include "*.ts" \
  --content-type "video/mp2t" \
  --cache-control "public,max-age=31536000,immutable" \
  --metadata-directive REPLACE \
  --region "${REGION}" --profile "${PROFILE}" --only-show-errors

# Optional: invalidate CloudFront so the new master is picked up instantly
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
