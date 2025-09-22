#!/usr/bin/env bash
# bin/hls-all.sh
# Batch pipeline:
#   - Find *.mp4 in ./input
#   - Encode each to ./output/<slug> (always writes master.m3u8)
#   - Upload to s3://$BUCKET/<prefix>/<slug>
#   - Invalidate CloudFront so the new master is available

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"
source "${root}/.env.hls"

# Defaults
parallel=1
dest_prefix="hls"     # change to "videos" if you prefer

# Flags to pass through to encoder
enc_args=()

while (( $# )); do
  case "$1" in
    --parallel)     parallel="${2:-1}"; shift 2 ;;
    --prefix)       dest_prefix="${2:-hls}"; shift 2 ;;   # e.g. videos
    -t|--thumbs)    enc_args+=("--thumbs"); shift ;;
    -S|--sprites)   enc_args+=("--sprites"); shift ;;
    --thumb-interval) enc_args+=("--thumb-interval" "${2:-10}"); shift 2 ;;
    --thumb-width)    enc_args+=("--thumb-width" "${2:-160}"); shift 2 ;;
    --thumb-fmt)      enc_args+=("--thumb-fmt" "${2:-webp}"); shift 2 ;;
    --sprite-cols)    enc_args+=("--sprite-cols" "${2:-10}"); shift 2 ;;
    --sprite-rows)    enc_args+=("--sprite-rows" "${2:-10}"); shift 2 ;;
    --seg)            enc_args+=("--seg" "${2:-6}"); shift 2 ;;
    --parallel-enc)   enc_args+=("--parallel" "${2:-1}"); shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--parallel N] [--prefix PATH] [thumbnail/encode flags...]
Options:
  --parallel N          Process N files concurrently (xargs)
  --prefix PATH         S3 prefix (default "hls"; e.g. "videos")
Pass-through (to hls-encode.sh):
  -t, --thumbs
  -S, --sprites
  --thumb-interval N
  --thumb-width N
  --thumb-fmt webp|jpg|png
  --sprite-cols N
  --sprite-rows N
  --seg N
  --parallel-enc N
EOF
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# -------- portable file collection (no 'mapfile') ----------
files=()
while IFS= read -r f; do
  # skip empty lines just in case
  [[ -n "$f" ]] && files+=("$f")
done < <(find "${root}/input" -type f -name '*.mp4' | sort)
# -----------------------------------------------------------

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No .mp4 files found in ${root}/input"
  exit 0
fi

process_one() {
  local src="$1"
  local base
  base="$(basename "${src}" .mp4)"
  local out="${root}/output/${base}"

  echo "→ Encoding: ${src} → ${out}"
  "${root}/bin/hls-encode.sh" "${enc_args[@]}" "${src}" "${out}"

  echo "→ Uploading: ${out} → s3://${AWS_S3_BUCKET_NAME:-cracking-language-media}/${dest_prefix}/${base}"
  "${root}/bin/hls-upload.sh" "${out}" "${dest_prefix}/${base}"
}

export -f process_one
export root dest_prefix enc_args

if command -v xargs >/dev/null 2>&1 && [[ "${parallel}" -gt 1 ]]; then
  printf "%s\0" "${files[@]}" | xargs -0 -n1 -P "${parallel}" bash -lc 'process_one "$0"'
else
  for f in "${files[@]}"; do process_one "${f}"; done
fi
