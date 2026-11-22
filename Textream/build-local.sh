#!/bin/bash
# Build the local Mac companion using the Command Line Tools or full Xcode.
set -euo pipefail
cd "$(dirname "$0")"
output="$PWD/build/local"
mkdir -p "$output"
stage=$(mktemp -d "$output/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Textream Studio.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
sources=()
while IFS= read -r -d '' file; do
    copy="$stage/sources/$file"
    mkdir -p "$(dirname "$copy")"
    cp "$file" "$copy"
    sources+=("$copy")
done < <(find Textream -type f -name '*.swift' -print0)
arch=$(uname -m)
xcrun swiftc -parse-as-library -swift-version 5 -enable-bare-slash-regex -whole-module-optimization \
    -O -target "$arch-apple-macosx15.0" -debug-prefix-map "$stage/sources=$PWD" \
    -D LOCAL_COMPANION -module-name Textream -o "$app/Contents/MacOS/Textream" "${sources[@]}"
cp -R Textream/Fonts/. "$app/Contents/Resources/"
cp Textream/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
if [ -f Textream/CompanionSpeechSample.wav ]; then cp Textream/CompanionSpeechSample.wav "$app/Contents/Resources/"; fi
cp -R Textream/EnglishFollowSamples "$app/Contents/Resources/"
cp ../LICENSE "$app/Contents/Resources/LICENSE"
cp ../THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R Textream/Assets.xcassets/AppIcon.appiconset "$stage/AppIcon.iconset"
rm "$stage/AppIcon.iconset/Contents.json"
iconutil -c icns "$stage/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open('Info.plist','rb') as f:
    info = plistlib.load(f)
info.update(CFBundleIdentifier='local.xpresentext.companion', CFBundleExecutable='Textream',
    CFBundleName='Textream Studio', CFBundleDisplayName='Textream Studio', CFBundlePackageType='APPL',
    CFBundleIconFile='AppIcon', CFBundleVersion='1', CFBundleShortVersionString='0.5.0',
    LSMinimumSystemVersion='15.0', NSHighResolutionCapable=True,
    NSMicrophoneUsageDescription='使用本机麦克风跟随演讲，或在开启听题时复述一道问题。',
    NSSpeechRecognitionUsageDescription='演讲工作区在本机识别语音，原版提词器使用系统语音识别。',
    NSLocalNetworkUsageDescription='原版 Textream 可使用已启用的局域网遥控功能。')
info['CFBundleURLTypes'] = [{'CFBundleURLName':'local.xpresentext.companion','CFBundleURLSchemes':['xpresentext']}]
for doc in info['CFBundleDocumentTypes']:
    doc['LSHandlerRank']='Alternate'
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
PY
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$output/versions"
release=$(mktemp -d "$output/versions/build.XXXXXX")
mv "$app" "$release/Textream Studio.app"
# Keychain identifies its caller by the running executable. Only replace links.
# A legacy build can launch at any time, so keep its original bundle in place.
python3 - "$stage" "$output" "$release" <<'PY'
from pathlib import Path
import sys

stage, output, release = map(Path, sys.argv[1:])
current = output / "current"
new_link = stage / "current"
new_link.symlink_to(release.relative_to(output))
new_link.replace(current)

name = "Textream Studio.app"
legacy = output / name
if legacy.is_symlink() or not legacy.exists():
    compatibility_link = stage / "compatibility"
    compatibility_link.symlink_to(Path("current") / name)
    compatibility_link.replace(legacy)
print(current / name)
PY
