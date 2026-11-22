#!/bin/bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../../.." && pwd)
qa_tests="$repo_dir/Tests/CompanionQA"
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

swiftc -O -swift-version 6 -D COMPANION_QA_EXTERNAL_MAIN \
    "$repo_dir"/Textream/Textream/Companion/QA/*.swift \
    "$qa_tests"/*.swift \
    "$test_dir/LocalQATrial.swift" \
    -o "$build_dir/omlx-local-qa"
"$build_dir/omlx-local-qa" "$@"
