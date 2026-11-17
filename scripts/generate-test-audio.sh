#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/fixtures/audio}"

command -v sox >/dev/null 2>&1 || { echo "sox is required. Install with: brew install sox" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is required. Install with: brew install ffmpeg" >&2; exit 1; }

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

echo "Generating test WAV and MP3 fixtures in $OUT_DIR"

sox -n -r 44100 -b 16 -c 2 test_5mb.wav synth 30 sine 440
sox -n -r 44100 -b 16 -c 2 test_50mb.wav synth 300 sine 440
sox -n -r 44100 -b 16 -c 2 test_150mb.wav synth 900 sine 440
sox -n -r 44100 -b 16 -c 2 test_500mb.wav synth 3000 sine 440
sox -n -r 44100 -b 16 -c 2 test_5mb_src.wav synth 30 sine 440
ffmpeg -y -i test_5mb_src.wav -b:a 256k test_5mb.mp3 >/dev/null
rm -f test_5mb_src.wav

ls -lh
