#!/bin/bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
source_dir="$test_dir/../../Textream/Textream"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT
app="$scratch_dir/Textream Speech Probe.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.textream.CompanionSpeechProbe</string>
    <key>CFBundleName</key><string>Textream Speech Probe</string>
    <key>CFBundleExecutable</key><string>speech-probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>NSSpeechRecognitionUsageDescription</key><string>Run Textream's local transcription checks.</string>
    <key>NSMicrophoneUsageDescription</key><string>Run Textream's local microphone checks.</string>
</dict>
</plist>
PLIST
swiftc -swift-version 6 -o "$app/Contents/MacOS/speech-probe" \
    "$source_dir/Companion/Tracking/CompanionLocalSpeechInput.swift" "$test_dir/SpeechProbe.swift"
codesign --force --sign - "$app"
if [[ ("${1:-}" == file || "${1:-}" == file-url) && $# -ge 3 ]]; then
    mode="$1"
    locale="$2"
    audio="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
    shift 3
    set -- "$mode" "$locale" "$audio" "$@"
fi
touch "$scratch_dir/stdout" "$scratch_dir/stderr"
open -n -W -a "$app" --stdout "$scratch_dir/stdout" --stderr "$scratch_dir/stderr" \
    --env "TEXTREAM_PROBE_STATUS=$scratch_dir/status" --args "$@"
cat "$scratch_dir/stdout"
cat "$scratch_dir/stderr" >&2
if [ ! -f "$scratch_dir/status" ]; then exit 1; fi
exit "$(cat "$scratch_dir/status")"
