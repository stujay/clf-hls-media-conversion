#!/usr/bin/env bash
# Robust HLS encoder for VOD:
# - Auto FPS/GOP from input
# - Rotation-aware + optional deinterlace
# - Even dimensions + pad to rung, SAR=1, fixed FPS
# - ABR ladder with aligned keyframes
# - Hardened WxH parsing + ladder sanitization
# - Optional parallel encoding (no xargs; throttled bg jobs)

set -euo pipefail

############################################
# Defaults (override via env or flags)
############################################
SEG_DUR="${SEG_DUR:-6}"         # segment duration (seconds)
PARALLEL="${PARALLEL:-1}"       # concurrent renditions
# Ladder entries: WxH:vbit:buf:maxrate:audio_kbps
LADDER_DEFAULT=(
  "1920x1080:6000k:12000k:7800k:128"
  "1280x720:3000k:6000k:4200k:128"
  "854x480:1500k:3000k:2100k:128"
  "640x360:800k:1600k:1100k:96"
)

usage() {
  cat <<EOF
Usage:
  $0 [-s SEG_DUR] [-p PARALLEL] [-l LADDER_FILE] <input> <output_dir>

Options:
  -s SEG_DUR       Segment duration (default: ${SEG_DUR})
  -p PARALLEL      Parallel renditions (default: ${PARALLEL})
  -l LADDER_FILE   File with lines: WxH:vbit:buf:maxrate:audio_kbps

Examples:
  $0 input/video.mp4 output/my-video
  SEG_DUR=4 PARALLEL=2 $0 input.mp4 out_dir
EOF
  exit 1
}

############################################
# Parse flags
############################################
LADDER_FILE=""
while getopts ":s:p:l:" opt; do
  case "$opt" in
    s) SEG_DUR="$OPTARG" ;;
    p) PARALLEL="$OPTARG" ;;
    l) LADDER_FILE="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

in="${1:-}"
out="${2:-}"
[[ -z "${in}" || -z "${out}" ]] && usage

mkdir -p "${out}"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }
}
need ffmpeg
need ffprobe
need jq
need python3

############################################
# Load + sanitize ladder
############################################
ladder=()
load_ladder_line() {
  local raw="$1"
  local line
  line="$(printf '%s' "$raw" | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [[ -z "${line}" || "${line:0:1}" == "#" ]] && return 1
  ladder+=("${line}")
  return 0
}

if [[ -n "${LADDER_FILE}" ]]; then
  while IFS= read -r raw; do
    load_ladder_line "${raw}" || true
  done < "${LADDER_FILE}"
else
  for raw in "${LADDER_DEFAULT[@]}"; do
    load_ladder_line "${raw}" || true
  done
fi

if [[ "${#ladder[@]}" -eq 0 ]]; then
  echo "No ladder entries found. Exiting." >&2
  exit 1
fi

############################################
# Probe input metadata
############################################
probe_json="$(ffprobe -v error -print_format json -show_streams -show_format "${in}")"

# FPS detection -> float -> rounded int for GOP math
rate="$(echo "${probe_json}" | jq -r '.streams[] | select(.codec_type=="video") | .avg_frame_rate' | head -n1)"
[[ -z "${rate}" || "${rate}" == "0/0" ]] && rate="$(echo "${probe_json}" | jq -r '.streams[] | select(.codec_type=="video") | .r_frame_rate' | head -n1)"
if [[ -n "${rate}" && "${rate}" != "0/0" ]]; then
  FPS="$(python3 - <<PY
from fractions import Fraction
s="${rate}"
try: print(float(Fraction(s)))
except: print(30.0)
PY
)"
else
  FPS="30.0"
fi
FPS_INT="$(python3 - <<PY
x=${FPS}
print(int(round(x)) if x>0 else 30)
PY
)"
GOP=$(( SEG_DUR * FPS_INT ))

# Rotation
ROTATE="$(echo "${probe_json}" | jq -r '.streams[] | select(.codec_type=="video") | .side_data_list[]?.rotation // empty' | head -n1)"
ROTATE="${ROTATE:-0}"
case "${ROTATE}" in
  90|-270) ROT_FILTER="transpose=1" ;;      # clockwise
  180|-180) ROT_FILTER="hflip,vflip" ;;
  270|-90) ROT_FILTER="transpose=2" ;;      # counter-clockwise
  *) ROT_FILTER="" ;;
esac

# Interlacing → auto deinterlace if not progressive
FIELD_ORDER="$(echo "${probe_json}" | jq -r '.streams[] | select(.codec_type=="video") | .field_order // empty' | head -n1)"
DEINTERLACE_FILTER=""
case "${FIELD_ORDER}" in
  unknown|progressive|"") ;;
  *) DEINTERLACE_FILTER="bwdif=mode=1" ;;
esac

############################################
# Encode one rung
############################################
encode_one() {
  local idx="$1" spec="$2"

  local size vbit buf maxrate akbps
  IFS=: read -r size vbit buf maxrate akbps <<< "${spec}"

  # sanitize WxH
  size="$(printf '%s' "$size" | tr -d '[:space:]')"
  if [[ ! "${size}" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "Bad ladder size token '${size}' in spec '${spec}'" >&2
    exit 1
  fi

  # pure bash WxH split
  local W="${size%%x*}"
  local H="${size##*x}"
  if [[ -z "${W}" || -z "${H}" || ! "${W}" =~ ^[0-9]+$ || ! "${H}" =~ ^[0-9]+$ ]]; then
    echo "Failed to parse WxH from '${size}' (W='${W}', H='${H}') in spec '${spec}'" >&2
    exit 1
  fi

  local variant="${out}/v${idx}.m3u8"
  local seg_tmpl="${out}/v${idx}_%05d.ts"

  # build video filter chain
  local filters=()
  [[ -n "${ROT_FILTER}" ]] && filters+=("${ROT_FILTER}")
  [[ -n "${DEINTERLACE_FILTER}" ]] && filters+=("${DEINTERLACE_FILTER}")
  filters+=("scale=${W}:${H}:force_original_aspect_ratio=decrease:force_divisible_by=2")
  filters+=("pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=black")
  filters+=("setsar=1")
  filters+=("fps=${FPS_INT}")
  local vf
  vf="$(IFS=, ; echo "${filters[*]}")"

  local AUDIO="-c:a aac -b:a ${akbps}k -ac 2 -ar 48000"

  ffmpeg -hide_banner -nostdin -y -i "${in}" \
    -map 0:v:0 -map 0:a:0 -map_metadata -1 -map_chapters -1 \
    -vf "${vf}" -pix_fmt yuv420p \
    -c:v h264 -profile:v high -level 4.1 \
    -x264-params "keyint=${GOP}:min-keyint=${GOP}:scenecut=0" \
    -b:v "${vbit}" -maxrate "${maxrate}" -bufsize "${buf}" -preset veryfast \
    ${AUDIO} \
    -f hls \
      -hls_time "${SEG_DUR}" \
      -hls_playlist_type vod \
      -hls_segment_filename "${seg_tmpl}" \
      -hls_flags independent_segments \
      "${variant}"
}

export -f encode_one
export in out SEG_DUR GOP ROT_FILTER DEINTERLACE_FILTER FPS_INT

############################################
# Dispatch (sequential or throttled parallel)
############################################
pids=()
idx=0
for spec in "${ladder[@]}"; do
  if (( PARALLEL > 1 )); then
    encode_one "${idx}" "${spec}" &
    pids+=("$!")

    # throttle: keep at most PARALLEL running
    while (( $(jobs -rp | wc -l) >= PARALLEL )); do
      sleep 0.2
    done
  else
    encode_one "${idx}" "${spec}"
  fi
  ((idx++))
done

# wait for background jobs
wait "${pids[@]}" 2>/dev/null || true

############################################
# Build master.m3u8 (only include present variants)
############################################
master="${out}/master.m3u8"
{
  echo "#EXTM3U"
  echo "#EXT-X-VERSION:3"
  echo "#EXT-X-INDEPENDENT-SEGMENTS"
} > "${master}"

idx=0
for spec in "${ladder[@]}"; do
  IFS=: read -r size vbit buf maxrate akbps <<< "${spec}"

  # only include if the variant playlist exists
  if [[ -f "${out}/v${idx}.m3u8" ]]; then
    # BANDWIDTH (bits/sec) ≈ maxrate + audio
    MAXK="${maxrate%k}"
    ABIT=$(( akbps * 1000 ))
    VBITS=$(( MAXK * 1000 ))
    TOTAL=$(( VBITS + ABIT ))

    # Optional: average bandwidth hint (90% of max is a decent heuristic)
    AVG=$(( (VBITS * 9 / 10) + ABIT ))

    {
      echo "#EXT-X-STREAM-INF:BANDWIDTH=${TOTAL},AVERAGE-BANDWIDTH=${AVG},RESOLUTION=${size},CODECS=\"avc1.640028,mp4a.40.2\",FRAME-RATE=${FPS_INT}"
      echo "v${idx}.m3u8"
    } >> "${master}"
  fi

  ((idx++))
done

echo "✅ Encoded HLS -> ${out}"
