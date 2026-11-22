#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
if [[ "${1:-}" == "--local-voice" ]]; then
    [[ $# == 3 ]] || { echo "Expected --local-voice PPTX TRANSCRIPTS.json" >&2; exit 2; }
    arguments=("$@" "$temp")
elif [[ $# -gt 0 ]]; then
    fixtures="$1"
    arguments=("$fixtures" "$temp")
else
    fixtures="$temp/fixtures"
    "${DECK_PYTHON:-python3}" "$repo/Tests/CompanionDeck/make_fixtures.py" "$fixtures"
    arguments=("$fixtures" "$temp")
fi
sources=()
cp -R "$repo/Textream/Textream" "$temp/sources"
while IFS= read -r -d '' file; do sources+=("$file"); done < <(find "$temp/sources" -type f -name '*.swift' -print0)
xcrun swiftc -parse-as-library -swift-version 5 -enable-bare-slash-regex -whole-module-optimization \
    -D COMPANION_ACCEPTANCE -D LOCAL_COMPANION \
    "${sources[@]}" "$repo"/Tests/CompanionIntegration/*.swift -o "$temp/acceptance"
if [[ "${COMPANION_OFFLINE_CHECK:-0}" == 1 ]]; then
    policy='(version 1) (allow default) (deny network-outbound (remote ip "*:*"))'
    /usr/bin/sandbox-exec -p "$policy" /usr/bin/python3 -c \
        'import errno,socket; assert socket.socket().connect_ex(("127.0.0.1", 9)) == errno.EPERM'
    /usr/bin/sandbox-exec -p "$policy" "$temp/acceptance" "${arguments[@]}"
else
    "$temp/acceptance" "${arguments[@]}"
fi
