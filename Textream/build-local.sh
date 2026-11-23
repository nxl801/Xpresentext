#!/bin/bash
# Build the local Mac companion using the Command Line Tools or full Xcode.
set -euo pipefail
cd "$(dirname "$0")"
output="$PWD/build/local"
mkdir -p "$output"
stage=$(mktemp -d "$output/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Xpresentext.app"
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
    -D LOCAL_COMPANION -module-name Textream -o "$app/Contents/MacOS/Xpresentext" "${sources[@]}"
cp -R Textream/Fonts/. "$app/Contents/Resources/"
cp Textream/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/EnglishFollowSamples"
cp Textream/EnglishFollowSamples/cases.json "$app/Contents/Resources/EnglishFollowSamples/"
cp -R Textream/LunarAssets "$app/Contents/Resources/"
./embed-presenter.sh "$app/Contents" "$arch"
python3 - "$app/Contents/Info.plist" <<'PYTHON'
import plistlib, struct, sys
from pathlib import Path

# Modern macOS ICNS stores the catalog's standard and Retina PNGs verbatim.
iconset = Path("Textream/Assets.xcassets/AppIcon.appiconset")
types = [(16, "icp4", "ic11"), (32, "icp5", "ic12"), (128, "ic07", "ic13"),
         (256, "ic08", "ic14"), (512, "ic09", "ic10")]
entries = bytearray()
for size, standard, retina in types:
    for suffix, code in [("", standard), ("@2x", retina)]:
        png = (iconset / f"icon_{size}x{size}{suffix}.png").read_bytes()
        entries += struct.pack(">4sI", code.encode("ascii"), len(png) + 8) + png
icon = Path(sys.argv[1]).parent / "Resources/AppIcon.icns"
icon.write_bytes(struct.pack(">4sI", b"icns", len(entries) + 8) + entries)

with open('Info.plist','rb') as f:
    info = plistlib.load(f)
info.update(CFBundleIdentifier='local.xpresentext.companion', CFBundleExecutable='Xpresentext',
    CFBundleName='Xpresentext', CFBundleDisplayName='Xpresentext', CFBundlePackageType='APPL',
    CFBundleIconFile='AppIcon', CFBundleVersion='6', CFBundleShortVersionString='0.6.4',
    LSMinimumSystemVersion='15.0', NSHighResolutionCapable=True,
    NSAudioCaptureUsageDescription='在选择会议声音时，接收这台 Mac 播放的观众提问。',
    NSMicrophoneUsageDescription='使用本机麦克风跟随演讲，或在开启听题时复述一道问题。',
    NSSpeechRecognitionUsageDescription='演讲工作区在本机识别语音，原版提词器使用系统语音识别。',
    NSLocalNetworkUsageDescription='Xpresentext 在启用局域网遥控后连接同一网络中的设备。')
info['CFBundleURLTypes'] = [{'CFBundleURLName':'local.xpresentext.companion','CFBundleURLSchemes':['xpresentext']}]
for doc in info['CFBundleDocumentTypes']:
    doc['LSHandlerRank']='Alternate'
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
PYTHON
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$output/versions"
release=$(mktemp -d "$output/versions/build.XXXXXX")
mv "$app" "$release/Xpresentext.app"
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

name = "Xpresentext.app"
legacy = output / name
if legacy.is_symlink() or not legacy.exists():
    compatibility_link = stage / "compatibility"
    compatibility_link.symlink_to(Path("current") / name)
    compatibility_link.replace(legacy)
print(current / name)
PY
