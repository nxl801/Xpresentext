#!/bin/bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../../.." && pwd)
qa_tests="$repo_dir/Tests/CompanionQA"
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

swiftc -O -swift-version 6 -D COMPANION_QA_EXTERNAL_MAIN \
    "$repo_dir"/Textream/Textream/Companion/QA/*.swift \
    "$repo_dir/Textream/Textream/Companion/Workspace/StudioCredentials.swift" \
    "$test_dir/../LiveTrialProvider.swift" \
    "$qa_tests"/*.swift \
    "$test_dir"/GLM*.swift \
    -o "$build_dir/glm-qa"
"$build_dir/glm-qa" "$@"
