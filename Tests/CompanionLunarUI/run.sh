#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -O "$repo/Textream/Textream/Companion/Workspace/StudioLunarRenderer.swift" \
    "$repo/Tests/CompanionLunarUI/check.swift" -o "$work/check"
"$work/check" "$repo/Textream/Textream/LunarAssets"
