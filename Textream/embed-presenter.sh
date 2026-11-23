#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
contents="${1:?pass an absolute app Contents path}"
target_arches="${2:-$(uname -m)}"
resources="$contents/Resources"
mkdir -p "$resources/Licenses" "$resources/docs"
cp ../docs/lunar-phases.png "$resources/docs/"
cp ../LICENSES/Textream-MIT.txt "$resources/Licenses/"
cp ../LICENSE ../THIRD_PARTY_NOTICES.md ../README.md "$resources/"
cp Murmury/upstream/LICENSE "$resources/Licenses/Murmury-GPL-3.0.txt"
cp Murmury/NOTICE.md "$resources/Licenses/Murmury-NOTICE.md"
cp Murmury/english_coverage/NOTICE.md "$resources/Licenses/FineCat-NOTICE.md"
cp Murmury/english_coverage/LICENSE-Apache-2.0.txt "$resources/Licenses/FineCat-Apache-2.0.txt"
if [[ " $target_arches " == *" arm64 "* ]]; then
    ./build-murmury.sh "$contents/Helpers"
fi
