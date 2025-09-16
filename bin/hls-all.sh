#!/usr/bin/env bash
# bin/hls-all.sh
#
# Batch pipeline:
#   - Find *.mp4 in ./input
#   - Encode each to ./output/<slug>
#   - Upload to s3://$BUCKET/hls/<slug>
#   - Invalidate CloudFront so the new master is available

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"
source "${root}/.env.hls"

parallel=1
if [[ "${1:-}" == "--parallel" ]]; then
  parallel="${2:-1}"
fi

shopt -s nullglob
mapfile -t files < <(find "${root}/input" -type f -name '*.mp4' | sort)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No .mp4 files found in ${root}/input"
  exit 0
fi

process_one() {
  src="$1"
  base="$(basename "${src}" .mp4)"
  out="${root}/output/${base}"

  echo "→ Encoding: ${src} → ${out}"
  "${root}/bin/hls-encode.sh" "${src}" "${out}"

  echo "→ Uploading: ${out} → s3://${AWS_S3_BUCKET_NAME:-cracking-language-media}/hls/${base}"
  "${root}/bin/hls-upload.sh" "${out}" "hls/${base}"
}

export -f process_one
export root

if command -v xargs >/dev/null 2>&1 && [[ "${parallel}" -gt 1 ]]; then
  printf "%s\0" "${files[@]}" | xargs -0 -n1 -P "${parallel}" bash -lc 'process_one "$0"'
else
  for f in "${files[@]}"; do
    process_one "${f}"
  done
fi
