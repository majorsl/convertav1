#!/usr/bin/env bash
# Version 1.2 - AV1 encode (hardware preferred; falls back to libaom-av1 on failure)
# Fixed audio mapping, improved NVENC/VAAPI quality, added output validation
# Updated: emojis replaced with standard, widely-supported symbols

# ----------------- USER OPTIONS -----------------
FFMPEG="/usr/bin"
LOCKFILE="/tmp/convert_video_av1.lock"

# Set to true to skip HEVC encoded files
SKIP_HEVC=true
# ------------------------------------------------

# ----------------- EMOJI / STATUS CHARACTERS -----------------
PROCESSING="⏳"
SKIPPED="⏭️"
CONVERTED="✅"
FAILED="❌"
SIZE_INCREASED="⚠️"
SPACE_SAVED="💾"
INFO="ℹ️"
# -------------------------------------------------------------

IFS=$'\n'
declare -a summary_lines

# Acquire a lock with a 6-hour timeout
exec 200>"$LOCKFILE"
echo "${PROCESSING} Waiting for lock on $LOCKFILE ..."
flock -w 21600 200 || {
  echo "⏱ Timeout waiting for lock (6 hours). Another instance may be stuck. Exiting."
  exit 1
}
echo "✅ Lock acquired"

# Check directory argument
if [ -n "$1" ]; then
  WORKINGDIRECTORY="$1"
else
  echo "Please call the script with a directory to process."
  exit 1
fi

if [ ! -d "$WORKINGDIRECTORY" ]; then
  echo "$WORKINGDIRECTORY doesn't exist, aborting."
  exit 1
fi

# Global hardware encoder availability check
HW_AV1_NVENC=false
HW_AV1_VAAPI=false

if "$FFMPEG/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q av1_nvenc; then
  HW_AV1_NVENC=true
fi

if "$FFMPEG/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q av1_vaapi && test -e /dev/dri/renderD128; then
  HW_AV1_VAAPI=true
fi

echo "   HW av1_nvenc available: $HW_AV1_NVENC"
echo "   HW av1_vaapi available: $HW_AV1_VAAPI"

# Iterate files
while IFS= read -r -d '' file; do
  # Skip .tmp.* files from interrupted conversions
  if [[ "$file" == *.tmp.* ]]; then
    echo "Skipping temporary file: $file"
    continue
  fi

  base_name="${file%.*}"
  original_file="${base_name}.${file##*.}"

  echo -e "${PROCESSING} Processing:\033[0m $file"

  codec=$("$FFMPEG/ffprobe" -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$file" | tr -d ' \t\r\n')

  echo "   Detected codec: '$codec'"

  if [[ "$codec" == "hevc" ]]; then
    if $SKIP_HEVC; then
        echo "   Skipping: already HEVC"
        summary_lines+=("${SKIPPED} $(basename "$file"): already HEVC, skipped")
        continue
    else
        echo "   Processing HEVC file: will re-encode to AV1"
    fi
  elif [[ "$codec" == "av1" ]]; then
    echo "   Skipping: already AV1"
    summary_lines+=("${SKIPPED} $(basename "$file"): already AV1, skipped")
    continue
  fi

  # Build map arguments to preserve streams (video + audio tracks + subtitles)
  map_str=()
  map_str+=("-map" "0:v")
  map_str+=("-map" "0:a?")
  map_str+=("-map" "0:s?")

  # We'll try a sequence of encoders for this file: NVENC -> VAAPI -> libaom
  tried_encoders=()
  success=false

  # helper to attempt encode command and return exit code
  attempt_encode() {
    encoder_type="$1"   # values: nvenc, vaapi, libaom
    out_tmp="${base_name}.tmp.mkv"

    echo "   Attempting encode with: $encoder_type"

    if [[ "$encoder_type" == "nvenc" ]]; then
      # NVENC AV1
      "$FFMPEG/ffmpeg" -nostdin -i "$file" "${map_str[@]}" \
        -c:v av1_nvenc -preset p5 -rc vbr -cq 28 -b:v 0 \
        -spatial-aq 1 -temporal-aq 1 -aq-strength 8 -rc-lookahead 32 \
        -c:a copy -c:s copy "$out_tmp" -y
      return $?
    elif [[ "$encoder_type" == "vaapi" ]]; then
      # VAAPI AV1
      "$FFMPEG/ffmpeg" -nostdin -vaapi_device /dev/dri/renderD128 -hwaccel vaapi \
        -i "$file" "${map_str[@]}" \
        -vf 'format=nv12,hwupload' \
        -c:v av1_vaapi -qp 24 \
        -c:a copy -c:s copy "${out_tmp}" -y
      return $?
    elif [[ "$encoder_type" == "libaom" ]]; then
      # Software libaom
      "$FFMPEG/ffmpeg" -nostdin -i "$file" "${map_str[@]}" \
        -c:v libaom-av1 -crf 32 -b:v 0 -cpu-used 4 -row-mt 1 \
        -c:a copy -c:s copy "${out_tmp}" -y
      return $?
    else
      return 1
    fi
  }

  # Build ordered list of encoders to try
  encoders_to_try=()
  if $HW_AV1_NVENC; then
    encoders_to_try+=("nvenc")
  fi
  if $HW_AV1_VAAPI; then
    encoders_to_try+=("vaapi")
  fi
  encoders_to_try+=("libaom")

  # Attempt encodes
  for enc in "${encoders_to_try[@]}"; do
    tried_encoders+=( "$enc" )
    attempt_encode "$enc"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      success=true
      break
    else
      echo "   Encoder $enc failed with exit code $rc. Trying next option (if any)."
      rm -f "${base_name}.tmp.mkv"
    fi
  done

  if $success; then
    # Validate output
    if [ ! -s "${base_name}.tmp.mkv" ]; then
      echo "   Output file invalid (0 bytes), skipping"
      rm -f "${base_name}.tmp.mkv"
      summary_lines+=("${FAILED} $(basename "$file"): invalid output")
      continue
    fi

    # Move into place, delete original, compute savings
    original_size=$(stat -c%s "$file")
    new_size=$(stat -c%s "${base_name}.tmp.mkv")
    savings=$((original_size - new_size))

    rm "$file"
    mv "${base_name}.tmp.mkv" "${base_name}.mkv"

    if [ $savings -ge 0 ]; then
      percent_savings=$((100 * savings / original_size))
      summary_lines+=("${CONVERTED} $(basename "$file"): saved $((savings / 1024 / 1024)) MB (${percent_savings}% smaller)")
    else
      increase=$((new_size - original_size))
      percent_increase=$((100 * increase / original_size))
      summary_lines+=("${SIZE_INCREASED} $(basename "$file"): grew by $((increase / 1024 / 1024)) MB (${percent_increase}% bigger)")
    fi
  else
    # All encoders tried and failed
    rm -f "${base_name}.tmp.mkv" "${base_name}.tmp.*" 2>/dev/null
    echo "   All attempts failed for $file. Tried: ${tried_encoders[*]}"
    summary_lines+=("${FAILED} $(basename "$file"): conversion failed (tried: ${tried_encoders[*]})")
  fi

done < <(find "$WORKINGDIRECTORY" -type f \( -iname "*.avc" -o -iname "*.mkv" -o -iname "*.webm" -o -iname "*.mp4" -o -iname "*.m4v" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.MOV" -o -iname "*.wmv" -o -iname "*.asf" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.flv" -o -iname "*.3gp" \) -print0)

# Summary output
echo -e "\n\033[1mConversion Summary:\033[0m"
for line in "${summary_lines[@]}"; do
  echo " - $line"
done

# Count summary categories and size changes
count_converted=0
count_skipped=0
count_failed=0
count_grew=0
total_saved=0
total_increased=0

for line in "${summary_lines[@]}"; do
  case "$line" in
    "${CONVERTED}"*)
      ((count_converted++))
      [[ "$line" =~ saved[[:space:]]([0-9]+) ]] && ((total_saved += BASH_REMATCH[1]))
      ;;
    "${SIZE_INCREASED}"*)
      ((count_converted++))
      ((count_grew++))
      [[ "$line" =~ grew[[:space:]]by[[:space:]]([0-9]+) ]] && ((total_increased += BASH_REMATCH[1]))
      ;;
    "${SKIPPED}"*) ((count_skipped++)) ;;
    "${FAILED}"*) ((count_failed++)) ;;
  esac
done

echo -e "\n\033[1mTotals:\033[0m"
echo " - ${CONVERTED} Converted successfully: $count_converted"
echo " - ${SKIPPED} Skipped (already HEVC/AV1): $count_skipped"
echo " - ${FAILED} Failed conversions: $count_failed"
echo " - ${SIZE_INCREASED} Increased file size: $count_grew"
if [ $total_saved -gt 0 ]; then
  saved_human=$(numfmt --to=iec "$((total_saved * 1024 * 1024))")
  echo " - ${SPACE_SAVED} Total space saved: $saved_human"
fi
if [ $total_increased -gt 0 ]; then
  increased_human=$(numfmt --to=iec "$((total_increased * 1024 * 1024))")
  echo " - ${INFO} Total size increase: $increased_human"
fi

echo " "
unset IFS
