#!/bin/bash
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../../.." && pwd)
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
swiftc -swift-version 6 -D GROK_QA_FIXTURES \
    "$repo_dir"/Textream/Textream/Companion/QA/*.swift \
    "$test_dir/GrokCLITests.swift" -o "$build_dir/grok-qa-check"
case "${1:---verify}" in
    --verify)
        clang -O2 "$test_dir/Fixture.c" -o "$build_dir/grok-fixture"
        "$build_dir/grok-qa-check" "$build_dir/grok-fixture"
        ;;
    --live-synthetic)
        "$build_dir/grok-qa-check" --live-synthetic
        ;;
    *) exit 2 ;;
esac
