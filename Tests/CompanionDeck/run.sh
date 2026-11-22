#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"${DECK_PYTHON:-python3}" "$repo/Tests/CompanionDeck/make_fixtures.py" "$work/fixtures"
swiftc -swift-version 6 "$repo"/Textream/Textream/Companion/Deck/*.swift \
  "$repo/Tests/CompanionDeck/DeckAcceptance.swift" -o "$work/test-deck"
"$work/test-deck" "$work/fixtures"
