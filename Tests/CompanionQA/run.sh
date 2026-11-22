#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

swiftc -O -swift-version 6 \
  "$repo_dir"/Textream/Textream/Companion/QA/*.swift \
  "$test_dir"/*.swift \
  -o "$build_dir/companion-qa-tests"
"$build_dir/companion-qa-tests" "$@"
