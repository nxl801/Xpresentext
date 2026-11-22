#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source_dir=$(cd "$here/../../../Textream/Textream" && pwd)
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

swiftc -swift-version 6 -o "$scratch_dir/check" "$source_dir/SpeechTextAlignment.swift" \
  "$source_dir/VoiceActivityDetector.swift" "$source_dir"/Companion/Tracking/*.swift "$here/CloudSpeechChecks.swift"
scope='(version 1) (allow default) (deny network-outbound (remote ip "*:*"))'
/usr/bin/sandbox-exec -p "$scope" "$scratch_dir/check"
