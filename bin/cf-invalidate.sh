#!/usr/bin/env bash
# bin/cf-invalidate.sh

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"
source "${root}/.env.hls"

prefix="${1:-}"
if [[ -z "${prefix}" ]]; then
  echo "Usage: $0 <path under ${S3_PREFIX}> (e.g. ctf-s1-e1-intro)"
  exit 1
fi

aws --profile "${AWS_PROFILE}" cloudfront create-invalidation \
  --distribution-id "${CF_DISTRIBUTION_ID}" \
  --paths "/${S3_PREFIX}/${prefix}/*"
