#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
mkdir "$build_dir/sources"
cp -R "$repo_dir/Textream/Textream/." "$build_dir/sources/"
sources=()
while IFS= read -r -d '' file; do sources+=("$file"); done < <(find "$build_dir/sources" -name '*.swift' -type f -print0)
xcrun swiftc -parse-as-library -swift-version 5 -enable-bare-slash-regex -whole-module-optimization \
  -D COMPANION_ACCEPTANCE -D LOCAL_COMPANION "${sources[@]}" \
  "$test_dir/DraftWorkspace/ControlledDraftWorkspace.swift" -o "$build_dir/draft-workspace"
"$build_dir/draft-workspace" "$1" "$build_dir/workspace"
