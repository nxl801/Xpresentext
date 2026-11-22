#!/bin/bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
if [[ "${1:-}" == prepare ]]; then
    shift
    exec python3 "$test_dir/prepare_audio.py" "$@"
fi

exec python3 "$test_dir/build_runner.py" "$@"
