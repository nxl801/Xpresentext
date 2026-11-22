#!/bin/bash
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
source_dir="$test_dir/../../../Textream/Textream"
if [ ! -f "$source_dir/EnglishFollowSamples/hypothetical.wav" ]; then
    echo "SKIP bundled audio regression: optional demonstration WAVs are not distributed"
    exit 0
fi
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT
cp "$source_dir"/EnglishFollowSamples/* "$scratch_dir/"
xcrun swiftc -swift-version 6     "$source_dir/SpeechTextAlignment.swift"     "$source_dir/Companion/Tracking/CompanionTrackingMatcher.swift"     "$source_dir/Companion/Tracking/CompanionCloudSpeech.swift"     "$source_dir/Companion/Tracking/CompanionEnglishFollowSample.swift"     "$test_dir/SampleChecks.swift" -o "$scratch_dir/check"
sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip))' "$scratch_dir/check" "$scratch_dir"
