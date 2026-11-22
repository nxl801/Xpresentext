#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

mkdir "$build_dir/sources"
cp "$repo_dir"/Textream/Textream/Companion/{QA,Deck}/*.swift "$build_dir/sources/"
cp "$test_dir"/NativeDeck/NativeDeckQACheck.swift "$build_dir/sources/"
swiftc -O -swift-version 6 "$build_dir"/sources/*.swift -o "$build_dir/native-deck-qa"
"$build_dir/native-deck-qa" "$@"
