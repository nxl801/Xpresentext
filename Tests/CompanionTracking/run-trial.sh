#!/bin/bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
source_dir="$test_dir/../../Textream/Textream"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT
swiftc -swift-version 6 -o "$scratch_dir/tracking-trial" \
    "$source_dir/SpeechTextAlignment.swift" \
    "$source_dir/Companion/Tracking/CompanionTrackingMatcher.swift" \
    "$test_dir/TrackingTrial.swift"
"$scratch_dir/tracking-trial" "$@"
