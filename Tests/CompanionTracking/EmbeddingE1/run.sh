#!/bin/bash
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
corpus="$1"
results="$2"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 "$test_dir/prepare.py" "$corpus" "$results/samples.json"
swiftc -O -parse-as-library -swift-version 6 "$test_dir/EmbeddingTrial.swift" -o "$work/trial"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$work/trial" "$results/samples.json" > "$results/result.json"
