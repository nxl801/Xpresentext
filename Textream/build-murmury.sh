#!/bin/bash
# Build the pinned upstream overlay and local Whisper once per source revision.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
target="${1:?pass the app Contents/Helpers directory}"
source_dir="$here/Murmury"
build="$here/build"
mkdir -p "$build" "$target"
fingerprint=$(cd "$source_dir" && shasum -a 256 *.py english_coverage/*.py *.spec pyproject.toml uv.lock NOTICE.md upstream/{*.swift,*.py,LICENSE} "$here/build-murmury.sh" | shasum -a 256 | cut -c1-24)
cache="$build/murmury-$(uname -m)-$fingerprint"
if [[ ! -d "$cache/MurmuryPresenter.app" ]]; then
    temp=$(mktemp -d "$build/murmury-build.XXXXXX")
    trap 'rm -rf "$temp"' EXIT
    export UV_PROJECT_ENVIRONMENT="$build/murmury-env"
    uv sync --locked --project "$source_dir"
    xcrun swiftc -O "$source_dir/upstream/audiotap.swift" -o "$temp/audiotap"
    export MURMURY_AUDIO_BINARY="$temp/audiotap"
    PYTHONDONTWRITEBYTECODE=1 "$UV_PROJECT_ENVIRONMENT/bin/pyinstaller" --noconfirm --log-level WARN \
        --workpath "$temp/work" --distpath "$temp/dist" "$source_dir/presenter.spec"
    mkdir -p "$cache"
    # Atomic install even when two independent local builds finish together.
    python3 - "$temp/dist/MurmuryPresenter.app" "$cache/MurmuryPresenter.app" <<'PY'
import errno, os, sys
try:
    os.rename(*sys.argv[1:])
except OSError as error:
    if error.errno not in (errno.EEXIST, errno.ENOTEMPTY):
        raise
PY
fi
ditto "$cache/MurmuryPresenter.app" "$target/MurmuryPresenter.app"
