#!/usr/bin/env bash
# Assert that a video file actually carries a picture.
#
# Every other check in this task measures the envelope: codec, resolution,
# frame rate, bitrate, segment count, stream type. All of them pass on a feed
# that is entirely black, because a blank picture encodes to valid HEVC at the
# requested parameters exactly like any other. A pipeline can be green from end
# to end while carrying nothing, which is what happened here - OBS's
# monitor_capture source produced no image, and neither OBS's own log nor
# ffprobe on the archived segment could have revealed it.
#
# Two independent measurements, because either alone is weak:
#
#   blackdetect  what fraction of the duration is a full black frame.
#   YAVG         average luma of sampled frames. Limited-range black sits at
#                Y=16, so a maximum at or below 17 means no sampled frame
#                carried anything at all.
#
# Exits non-zero if any file is blank, so it can gate a live run.
#
#   Usage: scripts/picture-check.sh <file>...
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: picture-check.sh <file>..." >&2; exit 2; }

FAILED=0

for FILE in "$@"; do
  LABEL="$(basename "$FILE")"

  if [ ! -f "$FILE" ]; then
    printf -- '--- picture check: %s ---\n' "$LABEL"
    printf '[SKIP] not present at %s\n\n' "$FILE"
    continue
  fi

  DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FILE")"

  # A file with no black run at all is the healthy case, and grep reports "no
  # match" as a failure - which pipefail would turn into the check dying before
  # it could pass. Tolerate the empty match rather than having a check that
  # only works on the broken input.
  BLACK="$(ffmpeg -nostdin -i "$FILE" -vf "blackdetect=d=0.5:pic_th=0.98:pix_th=0.10" \
             -an -f null - 2>&1 \
           | { grep -oE 'black_duration:[0-9.]+' || true; } | cut -d: -f2 \
           | awk '{ total += $1 } END { printf "%.3f", total + 0 }')"

  # metadata=print writes to the info log, which -v error would swallow, so it
  # is directed at stdout explicitly.
  LUMA="$(ffmpeg -nostdin -v error -i "$FILE" \
            -vf "select='not(mod(n,300))',signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" \
            -fps_mode passthrough -f null - 2>/dev/null \
          | { grep -oE 'YAVG=[0-9.]+' || true; } | cut -d= -f2)"

  read -r YMIN YMAX YAVG SAMPLES <<EOF
$(printf '%s\n' "$LUMA" | awk 'NR==1{min=max=$1}
                               {if($1<min)min=$1; if($1>max)max=$1; sum+=$1; n++}
                               END{ if(n) printf "%.2f %.2f %.2f %d", min, max, sum/n, n;
                                    else  printf "0 0 0 0" }')
EOF

  PCT="$(awk -v b="$BLACK" -v d="$DURATION" 'BEGIN{ printf "%.1f", (d>0 ? 100*b/d : 0) }')"

  printf -- '--- picture check: %s ---\n' "$LABEL"
  printf '      duration        : %s s\n' "$DURATION"
  printf '      black duration  : %s s (%s%% of the file)\n' "$BLACK" "$PCT"
  printf '      luma sampled    : %s frames, YAVG min %s / mean %s / max %s\n' \
         "$SAMPLES" "$YMIN" "$YAVG" "$YMAX"

  BLANK="$(awk -v p="$PCT" -v m="$YMAX" 'BEGIN{ print (p >= 99.0 && m <= 17.0) ? 1 : 0 }')"
  if [ "$BLANK" = "1" ]; then
    printf '[FAIL] %s carries no picture: black for %s%% of its duration, peak luma %s\n\n' \
           "$LABEL" "$PCT" "$YMAX"
    FAILED=$((FAILED + 1))
  else
    printf '[PASS] %s carries a picture: peak luma %s over %s sampled frames\n\n' \
           "$LABEL" "$YMAX" "$SAMPLES"
  fi
done

if [ "$FAILED" -gt 0 ]; then
  printf 'RESULT: %d of %d file(s) carry no picture\n' "$FAILED" "$#"
  exit 1
fi
printf 'RESULT: all %d file(s) carry a picture\n' "$#"
