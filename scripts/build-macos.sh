#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TASK_ROOT"
TASK_CONFIGURATION=${1:-release}
TASK_ARCHITECTURES=${2:-native}
case "$TASK_CONFIGURATION" in debug|release) ;; *) echo "Usage: sh scripts/build-macos.sh [debug|release] [native|universal]" >&2; exit 2 ;; esac
case "$TASK_ARCHITECTURES" in native|universal) ;; *) echo "Unknown architecture: $TASK_ARCHITECTURES" >&2; exit 2 ;; esac
python3 "scripts/update-localizations.py" --check
if [ "$TASK_ARCHITECTURES" = universal ]; then
    for TASK_ARCH in arm64 x86_64; do
        swift build --jobs 4 -c "$TASK_CONFIGURATION" --arch "$TASK_ARCH" --product ShouDesktop
        swift build --jobs 4 -c "$TASK_CONFIGURATION" --arch "$TASK_ARCH" --product shou
    done
    TASK_BIN=$(swift build -c "$TASK_CONFIGURATION" --arch arm64 --show-bin-path)
    TASK_INTEL_BIN=$(swift build -c "$TASK_CONFIGURATION" --arch x86_64 --show-bin-path)
else
    swift build --jobs 4 -c "$TASK_CONFIGURATION" --product ShouDesktop
    swift build --jobs 4 -c "$TASK_CONFIGURATION" --product shou
    TASK_BIN=$(swift build -c "$TASK_CONFIGURATION" --show-bin-path)
fi
TASK_APP="$TASK_ROOT/dist/Shou.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" "$TASK_APP/Contents/Helpers" "$TASK_APP/Contents/Frameworks"
if [ "$TASK_ARCHITECTURES" = universal ]; then
    lipo -create "$TASK_BIN/ShouDesktop" "$TASK_INTEL_BIN/ShouDesktop" -output "$TASK_APP/Contents/MacOS/Shou"
    lipo -create "$TASK_BIN/shou" "$TASK_INTEL_BIN/shou" -output "$TASK_APP/Contents/Helpers/shou"
else
    cp "$TASK_BIN/ShouDesktop" "$TASK_APP/Contents/MacOS/Shou"
    cp "$TASK_BIN/shou" "$TASK_APP/Contents/Helpers/shou"
fi
cp "apps/macos/Info.plist" "$TASK_APP/Contents/Info.plist"
cp "assets/brand/Shou.icns" "$TASK_APP/Contents/Resources/Shou.icns"
cp "LICENSE" "$TASK_APP/Contents/Resources/LICENSE.txt"
cp ".build/artifacts/sparkle/Sparkle/LICENSE" "$TASK_APP/Contents/Resources/Sparkle-LICENSE.txt"
cp "packages/shou-contracts/rule.schema.json" "$TASK_APP/Contents/Resources/rule.schema.json"
cp -R "$TASK_BIN/Shou_ShouCore.bundle" "$TASK_APP/Contents/Resources/"
cp -R "$TASK_BIN/Shou_ShouCore.bundle" "$TASK_APP/Contents/Helpers/"
cp -R "$TASK_BIN/Shou_ShouContracts.bundle" "$TASK_APP/Contents/Helpers/"
ditto "$TASK_BIN/Shou_ShouAgentSupport.bundle" "$TASK_APP/Contents/Resources/Shou_ShouAgentSupport.bundle"
ditto "$TASK_BIN/Shou_ShouAgentSupport.bundle" "$TASK_APP/Contents/Helpers/Shou_ShouAgentSupport.bundle"
ditto ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$TASK_APP/Contents/Frameworks/Sparkle.framework"
for TASK_BUNDLE in "$TASK_APP/Contents/Resources/"*.bundle "$TASK_APP/Contents/Helpers/"*.bundle; do
    codesign --force --sign - "$TASK_BUNDLE"
done
codesign --force --sign - "$TASK_APP/Contents/Helpers/shou"
codesign --force --sign - "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
python3 "scripts/verify-products.py" --bin "$TASK_BIN" --app "$TASK_APP"
echo "Built $TASK_APP (local ad-hoc signature; not notarized)."
