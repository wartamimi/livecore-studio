#!/usr/bin/env bash
# End-to-end validation of the LiveCoreCore RTMP + FLV stack against a real RTMP server
# (ffmpeg in listen mode). Runs on Linux or macOS; needs swift + ffmpeg/ffprobe.
#
#  1. ffmpeg generates a 10 s H.264 (Annex-B, no B-frames — same constraint as the app's
#     VideoToolbox encoder) + AAC-LC 48 kHz stereo test signal.
#  2. livecore-rtmp-push publishes them through RTMPPublishSession to ffmpeg's RTMP listener
#     in real time; ffmpeg remuxes what it receives into an FLV file.
#  3. ffprobe checks codecs, resolution, duration and decodes every frame.
#  4. The FLV-file writer path is validated the same way.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${WORK:-$(mktemp -d)}"
PORT="${PORT:-19350}"
KEY="e2e_secret_key_123"
DUR="${DUR:-10}"
echo "work dir: $WORK"

swift build -c release --product livecore-rtmp-push >/dev/null
TOOL="$(swift build -c release --show-bin-path)/livecore-rtmp-push"

ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=$DUR" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=$DUR" \
  -map 0:v -c:v libx264 -profile:v high -bf 0 -g 60 -pix_fmt yuv420p -b:v 2500k -bsf:v h264_mp4toannexb -f h264 "$WORK/in.h264" \
  -map 1:a -c:a aac -b:a 128k -ac 2 -f adts "$WORK/in.aac"

echo "== RTMP publish to ffmpeg listener on port $PORT"
ffmpeg -loglevel warning -y -listen 1 -timeout 20 -i "rtmp://127.0.0.1:$PORT/live/$KEY" -c copy "$WORK/received.flv" \
  > "$WORK/server.log" 2>&1 &
SERVER=$!
sleep 1
"$TOOL" --h264 "$WORK/in.h264" --aac "$WORK/in.aac" --fps 30 --url "rtmp://127.0.0.1:$PORT/live" --key "$KEY" --realtime \
  | tee "$WORK/client.log"
wait $SERVER || { echo "ffmpeg server failed:"; cat "$WORK/server.log"; exit 1; }

check() { # file label
  local f="$1"
  echo "== ffprobe $2"
  ffprobe -v error -show_entries stream=codec_name,profile,width,height,sample_rate,channels -show_entries format=duration,format_name -of default=nw=1 "$f"
  local vframes aframes
  vframes=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$f")
  aframes=$(ffprobe -v error -count_frames -select_streams a:0 -show_entries stream=nb_read_frames -of csv=p=0 "$f")
  echo "decoded video frames: $vframes, audio frames: $aframes"
  local errs
  errs=$(ffmpeg -v error -i "$f" -f null - 2>&1 | wc -l)
  echo "decode errors: $errs"
  [ "$vframes" -ge $((DUR * 30 - 1)) ] && [ "$aframes" -ge $((DUR * 46)) ] && [ "$errs" -eq 0 ]
}
check "$WORK/received.flv" "RTMP-received stream"
if grep -q "$KEY" "$WORK/client.log"; then echo "FAIL: stream key printed by client"; exit 1; fi
echo "stream key not present in client log: OK"

echo "== FLV file writer"
"$TOOL" --h264 "$WORK/in.h264" --aac "$WORK/in.aac" --fps 30 --flv "$WORK/written.flv"
check "$WORK/written.flv" "FLV writer output"
echo "== Failure handling: no server listening"
if "$TOOL" --h264 "$WORK/in.h264" --fps 30 --url "rtmp://127.0.0.1:$((PORT + 1))/live" --key "$KEY" > "$WORK/refused.log" 2>&1; then
  echo "FAIL: expected connection error"; exit 1
fi
cat "$WORK/refused.log"

echo "== Failure handling: server drops the connection mid-stream"
ffmpeg -loglevel quiet -y -listen 1 -timeout 20 -i "rtmp://127.0.0.1:$PORT/live/$KEY" -t 2 -c copy "$WORK/partial.flv" &
SERVER=$!
sleep 1
if "$TOOL" --h264 "$WORK/in.h264" --aac "$WORK/in.aac" --fps 30 --url "rtmp://127.0.0.1:$PORT/live" --key "$KEY" --realtime > "$WORK/drop.log" 2>&1; then
  echo "FAIL: expected the client to detect the dropped connection"; exit 1
fi
wait $SERVER || true
grep "^error" "$WORK/drop.log"
grep -q "$KEY" "$WORK/drop.log" "$WORK/refused.log" && { echo "FAIL: key leaked in error output"; exit 1; }
echo "connection errors detected and reported without leaking the key: OK"
echo "E2E PASSED"
