#!/usr/bin/env bash
# bin/hls-encode.sh
# Robust HLS encoder for VOD:
# - Auto FPS/GOP from input
# - Rotation-aware + optional deinterlace
# - Even dimensions + pad to rung, SAR=1, fixed FPS
# - ABR ladder with aligned keyframes
# - Hardened WxH parsing + ladder sanitisation
# - ALWAYS builds master.m3u8
# - Optional thumbnails (per-image or sprite sheets) + WebVTT; non-fatal if they fail

set -euo pipefail

############################################
# Defaults (override via flags or env)
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

# Thumbnails (off by default)
THUMBS="${THUMBS:-0}"                # 1 to enable (or use -t / --thumbs)
THUMB_EVERY_SEC="${THUMB_EVERY_SEC:-10}"
THUMB_W="${THUMB_W:-160}"            # width per thumb (height auto)
THUMB_FMT="${THUMB_FMT:-webp}"       # webp|jpg|png
THUMB_SPRITES="${THUMB_SPRITES:-0}"  # 1 = sprite sheets; 0 = per-image
SPRITE_COLS="${SPRITE_COLS:-10}"     # columns per sprite
SPRITE_ROWS="${SPRITE_ROWS:-10}"     # rows per sprite

usage() {
  cat <<EOF
Usage:
  $0 [options] <input> <output_dir>

Options:
  -s, --seg N            HLS segment duration seconds (default ${SEG_DUR})
  -p, --parallel N       Parallel renditions (default ${PARALLEL})
  -l, --ladder FILE      File with lines: WxH:vbit:buf:maxrate:audio_kbps

Thumbnails:
  -t, --thumbs           Enable thumbnail generation (also THUMBS=1)
  -S, --sprites          Use sprite sheets (also THUMB_SPRITES=1)
  --thumb-interval N     Seconds between thumbs (default ${THUMB_EVERY_SEC})
  --thumb-width N        Width per thumb (default ${THUMB_W})
  --thumb-fmt FMT        webp|jpg|png (default ${THUMB_FMT})
  --sprite-cols N        Columns per sprite (default ${SPRITE_COLS})
  --sprite-rows N        Rows per sprite (default ${SPRITE_ROWS})

Examples:
  $0 input/video.mp4 output/my-video
  THUMBS=1 THUMB_SPRITES=1 $0 input.mp4 out_dir
  $0 -t -S --thumb-interval 8 input.mp4 out_dir
EOF
  exit 1
}

############################################
# Parse flags
############################################
LADDER_FILE=""
while (( $# )); do
  case "${1:-}" in
    -s|--seg)            SEG_DUR="${2:?}"; shift 2 ;;
    -p|--parallel)       PARALLEL="${2:?}"; shift 2 ;;
    -l|--ladder)         LADDER_FILE="${2:?}"; shift 2 ;;
    -t|--thumbs)         THUMBS="1"; shift ;;
    -S|--sprites)        THUMB_SPRITES="1"; THUMBS="1"; shift ;;
    --thumb-interval)    THUMB_EVERY_SEC="${2:?}"; shift 2 ;;
    --thumb-width)       THUMB_W="${2:?}"; shift 2 ;;
    --thumb-fmt)         THUMB_FMT="${2:?}"; shift 2 ;;
    --sprite-cols)       SPRITE_COLS="${2:?}"; shift 2 ;;
    --sprite-rows)       SPRITE_ROWS="${2:?}"; shift 2 ;;
    -h|--help)           usage ;;
    --)                  shift; break ;;
    -* )                 echo "Unknown option: $1" >&2; usage ;;
    * )                  break ;;
  esac
done

in="${1:-}"
out="${2:-}"
[[ -z "${in}" || -z "${out}" ]] && usage

mkdir -p "${out}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need ffmpeg; need ffprobe; need jq; need python3

############################################
# Load + sanitise ladder
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
  while IFS= read -r raw; do load_ladder_line "${raw}" || true; done < "${LADDER_FILE}"
else
  for raw in "${LADDER_DEFAULT[@]}"; do load_ladder_line "${raw}" || true; done
fi
[[ "${#ladder[@]}" -gt 0 ]] || { echo "No ladder entries found."; exit 1; }

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
  90|-270) ROT_FILTER="transpose=1" ;;
  180|-180) ROT_FILTER="hflip,vflip" ;;
  270|-90) ROT_FILTER="transpose=2" ;;
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

  size="$(printf '%s' "$size" | tr -d '[:space:]')"
  [[ "${size}" =~ ^[0-9]+x[0-9]+$ ]] || { echo "Bad ladder size '${size}'"; exit 1; }

  local W="${size%%x*}"; local H="${size##*x}"
  [[ "${W}" =~ ^[0-9]+$ && "${H}" =~ ^[0-9]+$ ]] || { echo "Bad WxH '${size}'"; exit 1; }

  local variant="${out}/v${idx}.m3u8"
  local seg_tmpl="${out}/v${idx}_%05d.ts"

  local filters=()
  [[ -n "${ROT_FILTER}" ]] && filters+=("${ROT_FILTER}")
  [[ -n "${DEINTERLACE_FILTER}" ]] && filters+=("${DEINTERLACE_FILTER}")
  filters+=("scale=${W}:${H}:force_original_aspect_ratio=decrease:force_divisible_by=2")
  filters+=("pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=black")
  filters+=("setsar=1")
  filters+=("fps=${FPS_INT}")
  local vf; vf="$(IFS=, ; echo "${filters[*]}")"

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
pids=(); idx=0
for spec in "${ladder[@]}"; do
  if (( PARALLEL > 1 )); then
    encode_one "${idx}" "${spec}" &
    pids+=("$!")
    while (( $(jobs -rp | wc -l) >= PARALLEL )); do sleep 0.2; done
  else
    encode_one "${idx}" "${spec}"
  fi
  ((idx++))
done
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
  if [[ -f "${out}/v${idx}.m3u8" ]]; then
    MAXK="${maxrate%k}"; ABIT=$(( akbps * 1000 )); VBITS=$(( MAXK * 1000 ))
    TOTAL=$(( VBITS + ABIT )); AVG=$(( (VBITS * 9 / 10) + ABIT ))
    {
      echo "#EXT-X-STREAM-INF:BANDWIDTH=${TOTAL},AVERAGE-BANDWIDTH=${AVG},RESOLUTION=${size},CODECS=\"avc1.640028,mp4a.40.2\",FRAME-RATE=${FPS_INT}"
      echo "v${idx}.m3u8"
    } >> "${master}"
  fi
  ((idx++))
done

############################################
# Optional thumbnails + WebVTT (never fatal)
############################################
if [[ "${THUMBS}" == "1" ]]; then
  thumbs_dir="${out}/thumbs"; mkdir -p "${thumbs_dir}"
  if [[ "${THUMB_SPRITES}" == "0" ]]; then
    # Per-image thumbs
    if ffmpeg -hide_banner -nostdin -y -i "${in}" -vf "fps=1/${THUMB_EVERY_SEC},scale=${THUMB_W}:-2" "${thumbs_dir}/thumb_%05d.${THUMB_FMT}" 2>/dev/null; then
      vtt="${thumbs_dir}/thumbs.vtt"
      {
        echo "WEBVTT"
        n=1; t0=0
        while :; do
          f=$(printf "thumb_%05d.%s" "${n}" "${THUMB_FMT}")
          [[ -f "${thumbs_dir}/${f}" ]] || break
          t1=$(( t0 + THUMB_EVERY_SEC ))
          printf "\n%02d:%02d:%02d.000 --> %02d:%02d:%02d.000\n" \
            $((t0/3600)) $(((t0%3600)/60)) $((t0%60)) \
            $((t1/3600)) $(((t1%3600)/60)) $((t1%60))
          echo "${f}"
          t0=$t1; n=$((n+1))
        done
      } > "${vtt}"
    else
      echo "⚠ Thumbnail extraction failed; continuing." >&2
    fi
  else
    # Sprite sheets
    tmp="${out}/.thumbs_tmp"; mkdir -p "${tmp}"
    if ffmpeg -hide_banner -nostdin -y -i "${in}" -vf "fps=1/${THUMB_EVERY_SEC},scale=${THUMB_W}:-2" "${tmp}/f_%06d.png" 2>/dev/null; then
      first="${tmp}/f_000001.png"
      if [[ -f "${first}" ]]; then
        read -r FW FH < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "${first}")
        THUMB_H="${FH:-90}"
        N=$(( SPRITE_COLS * SPRITE_ROWS ))
        count=$(ls "${tmp}"/f_*.png 2>/dev/null | wc -l | tr -d ' ')
        mkdir -p "${thumbs_dir}"
        frame_i=1; sheet_index=0
        while (( frame_i <= count )); do
          list="${tmp}/list_${sheet_index}.txt"; : > "${list}"; local_n=0
          while (( local_n < N && frame_i <= count )); do
            printf "file '%s'\n" "${tmp}/f_$(printf "%06d" "${frame_i}").png" >> "${list}"
            frame_i=$(( frame_i + 1 )); local_n=$(( local_n + 1 ))
          done
          sheet="${thumbs_dir}/sprite_$(printf "%03d" ${sheet_index}).${THUMB_FMT}"
          ffmpeg -hide_banner -nostdin -y -f concat -safe 0 -i "${list}" -filter_complex "tile=${SPRITE_COLS}x${SPRITE_ROWS}" -frames:v 1 "${sheet}" >/dev/null 2>&1 || true
          sheet_index=$(( sheet_index + 1 ))
        done
        vtt="${thumbs_dir}/thumbs.vtt"
        {
          echo "WEBVTT"
          sec0=0; f=1; sheet_index=0
          while (( f <= count )); do
            pos=$(( ( (f-1) % N ) ))
            col=$(( pos % SPRITE_COLS )); row=$(( pos / SPRITE_COLS ))
            x=$(( col * THUMB_W )); y=$(( row * THUMB_H ))
            sec1=$(( sec0 + THUMB_EVERY_SEC ))
            printf "\n%02d:%02d:%02d.000 --> %02d:%02d:%02d.000\n" \
              $((sec0/3600)) $(((sec0%3600)/60)) $((sec0%60)) \
              $((sec1/3600)) $(((sec1%3600)/60)) $((sec1%60))
            echo "sprite_$(printf "%03d" ${sheet_index}).${THUMB_FMT}#xywh=${x},${y},${THUMB_W},${THUMB_H}"
            sec0=$(( sec1 ))
            (( f % N == 0 )) && sheet_index=$(( sheet_index + 1 ))
            f=$(( f + 1 ))
          done
        } > "${vtt}"
      fi
    else
      echo "⚠ Sprite generation failed; continuing." >&2
    fi
    rm -rf "${tmp}" || true
  fi
fi

echo "✅ Encoded HLS -> ${out}"
