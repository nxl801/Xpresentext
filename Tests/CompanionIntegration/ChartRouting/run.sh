#!/bin/bash
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$test_dir/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"${DECK_PYTHON:-python3}" "$test_dir/fixtures.py" "$work/fixtures"
sources=()
cp -R "$repo/Textream/Textream" "$work/sources"
while IFS= read -r -d '' file; do sources+=("$file"); done < <(find "$work/sources" -name '*.swift' -print0)
xcrun swiftc -parse-as-library -swift-version 5 -enable-bare-slash-regex -whole-module-optimization \
    -D COMPANION_ACCEPTANCE -D LOCAL_COMPANION "${sources[@]}" "$test_dir/ChartRouting.swift" -o "$work/check"
scope='(version 1) (allow default) (deny network-outbound (remote ip "*:*"))'
/usr/bin/sandbox-exec -p "$scope" /usr/bin/python3 -c 'import errno,socket; assert socket.socket().connect_ex(("127.0.0.1", 9)) == errno.EPERM'
/usr/bin/sandbox-exec -p "$scope" "$work/check" "$work" "${1:-$work/fixtures}"
