#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ ! -f "$repo/Textream/Textream/EnglishFollowSamples/strong-paraphrase.wav" ]]; then
    echo "SKIP Whisper audio regression: demonstration recordings are excluded"
    exit 0
fi
helper="$repo/Textream/build/local/current/Xpresentext.app/Contents/Helpers"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
contents="$scratch/PipeCheck.app/Contents"
mkdir -p "$contents/MacOS"
ln -s "$helper" "$contents/Helpers"
cp "$repo/Textream/build/local/current/Xpresentext.app/Contents/Info.plist" "$contents/Info.plist"
xcrun swiftc -parse-as-library -swift-version 6 "$repo/Textream/Textream/Companion/Tracking/MurmuryProcess.swift" \
    "$repo/Tests/Murmury/PipeSmoke.swift" -o "$contents/MacOS/Xpresentext"
QT_QPA_PLATFORM=offscreen "$contents/MacOS/Xpresentext" "$repo/Textream/Textream/EnglishFollowSamples/strong-paraphrase.wav"
