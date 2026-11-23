#!/bin/bash
# Run the private presenter workspace's deterministic checks on a Mac.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python="${DECK_PYTHON:-python3}"
if ! "$python" -c 'import pptx, PIL, lxml' 2>/dev/null; then
    echo "Set DECK_PYTHON to a Python installation with python-pptx, Pillow and lxml." >&2
    exit 2
fi
export DECK_PYTHON="$python"
"$repo/Tests/CompanionLunarUI/run.sh"
"$repo/Tests/CompanionTracking/verify.sh"
"$repo/Tests/CompanionTracking/CloudSpeech/run.sh"
"$repo/Tests/CompanionTracking/EnglishFollowTrial/check-app-sample.sh"
"$repo/Tests/CompanionQA/run.sh"
"$repo/Tests/CompanionTracking/GLM/run.sh" --verify
"$repo/Tests/CompanionTracking/GrokCLI/run.sh" --verify
"$repo/Tests/CompanionDeck/run.sh"
"$python" "$repo/Tests/CompanionDeck/make_fixtures.py" "$work/decks"
"$repo/Tests/CompanionQA/run-workspace-draft.sh" "$work/decks"
"$repo/Tests/CompanionQA/run-native.sh" "$work/decks" "$work/images"
"$repo/Tests/CompanionIntegration/ChartRouting/run.sh"
"$repo/Tests/CompanionIntegration/TrackingPreparation/run.sh"
COMPANION_OFFLINE_CHECK=1 "$repo/Tests/CompanionIntegration/run.sh" "$work/decks"
"$repo/Textream/build-local.sh"

if [[ "$(uname -m)" == "arm64" ]]; then
    QT_QPA_PLATFORM=offscreen PYTHONDONTWRITEBYTECODE=1 "$repo/Textream/build/murmury-env/bin/python" "$repo/Tests/Murmury/test_panel.py"
    helper="$repo/Textream/build/local/current/Xpresentext.app/Contents/Helpers/MurmuryPresenter.app/Contents/MacOS/MurmuryPresenter"
    "$python" "$repo/Tests/Murmury/packaged_smoke.py" "$helper"
    model="$HOME/Library/Application Support/TextreamStudio/Whisper/a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb/weights.safetensors"
    if [[ -s "$model" ]]; then
        "$repo/Tests/Murmury/run-pipes.sh"
    else
        echo "SKIP paired Whisper pipe smoke: local Turbo model has not been prepared"
    fi
fi
