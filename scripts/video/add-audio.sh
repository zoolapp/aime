#!/usr/bin/env bash
# Score + typing sounds for the launch film, muxed onto the silent renders (video stream copied, not re-encoded).
set -euo pipefail
cd "$(dirname "$0")/../.."
name=dist/video/aime-launch-2026-10-01
py=build/video-tools/venv/bin/python
if [ ! -x "$py" ]; then python3 -m venv build/video-tools/venv && "$py" -m pip install -q numpy==2.3.3; fi
mkdir -p build/video
node scripts/video/render-launch.mjs --cues build/video/cues.json
"$py" scripts/video/compose-audio.py build/video/cues.json build/video/aime-launch-audio.wav
for v in 1080p 4k; do
  [ -f "$name-$v-silent.mp4" ] || continue
  ffmpeg -v error -y -i "$name-$v-silent.mp4" -i build/video/aime-launch-audio.wav -map 0:v -map 1:a -c:v copy \
    -af loudnorm=I=-16:TP=-1.5:LRA=7 -ar 48000 -c:a aac -b:a 192k -shortest -movflags +faststart "$name-$v.mp4"
  echo "$name-$v.mp4"
done
