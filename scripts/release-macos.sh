#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TASK_ROOT"
TASK_TAG=${1:?Usage: sh scripts/release-macos.sh v0.4.0 private-key-file}
TASK_KEY=${2:?Pass the update signing key file; never pass the key itself}
TASK_VERSION=${TASK_TAG#v}
python3 - "$TASK_TAG" <<'PY'
import plistlib, re, sys
from pathlib import Path
tag=sys.argv[1]
assert re.fullmatch(r'v\d+\.\d+\.\d+', tag), 'Expected a stable semantic version tag'
info=plistlib.loads(Path('apps/macos/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == info['CFBundleVersion'] == tag[1:], 'Tag and application versions must match'
assert info['SUPublicEDKey'] and info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction']
PY
sh "scripts/build-macos.sh" release universal
swift build --jobs 4 -c release --product shou-tests
TASK_TEST_BIN=$(swift build -c release --show-bin-path)
"$TASK_TEST_BIN/shou-tests" --native-trash-purge
python3 "scripts/verify-cli.py" "dist/Shou.app/Contents/Helpers/shou"
python3 "apps/cli/Tests/verify-confirmation.py" "dist/Shou.app/Contents/Helpers/shou"
python3 "scripts/verify-native-cli.py" "dist/Shou.app/Contents/Helpers/shou" --native-trash-purge
python3 "scripts/verify-uninstall-cli.py" "dist/Shou.app/Contents/Helpers/shou"
TASK_APP_NAME="Shou-$TASK_VERSION-macos-universal"
TASK_CLI_NAME="shou-$TASK_VERSION-macos-universal"
TASK_OUTPUT="$TASK_ROOT/dist/release-$TASK_VERSION"
mkdir -p "$TASK_OUTPUT" "$TASK_OUTPUT/disk-image" "$TASK_OUTPUT/cli"
ditto -c -k --sequesterRsrc --keepParent "dist/Shou.app" "$TASK_OUTPUT/$TASK_APP_NAME.zip"
ditto "dist/Shou.app" "$TASK_OUTPUT/disk-image/Shou.app"
if [ ! -e "$TASK_OUTPUT/disk-image/Applications" ]; then ln -s "/Applications" "$TASK_OUTPUT/disk-image/Applications"; fi
hdiutil create -volname "Shou" -fs HFS+ -srcfolder "$TASK_OUTPUT/disk-image" -ov -format UDZO "$TASK_OUTPUT/$TASK_APP_NAME.dmg"
cp "dist/Shou.app/Contents/Helpers/shou" "$TASK_OUTPUT/cli/shou"
ditto "dist/Shou.app/Contents/Helpers/Shou_ShouCore.bundle" "$TASK_OUTPUT/cli/Shou_ShouCore.bundle"
ditto "dist/Shou.app/Contents/Helpers/Shou_ShouContracts.bundle" "$TASK_OUTPUT/cli/Shou_ShouContracts.bundle"
ditto "dist/Shou.app/Contents/Helpers/Shou_ShouAgentSupport.bundle" "$TASK_OUTPUT/cli/Shou_ShouAgentSupport.bundle"
cp "LICENSE" "$TASK_OUTPUT/cli/LICENSE"
tar -czf "$TASK_OUTPUT/$TASK_CLI_NAME.tar.gz" -C "$TASK_OUTPUT/cli" "shou" "Shou_ShouCore.bundle" "Shou_ShouContracts.bundle" "Shou_ShouAgentSupport.bundle" "LICENSE"
TASK_UPDATES=$(mktemp -d "$TASK_ROOT/dist/update-feed.XXXXXX")
cp "$TASK_OUTPUT/$TASK_APP_NAME.zip" "$TASK_UPDATES/"
".build/artifacts/sparkle/Sparkle/bin/generate_appcast" --ed-key-file "$TASK_KEY" --download-url-prefix "https://github.com/limecloud/shou/releases/download/$TASK_TAG/" --maximum-versions 1 --maximum-deltas 0 -o "$TASK_OUTPUT/appcast.xml" "$TASK_UPDATES"
".build/artifacts/sparkle/Sparkle/bin/sign_update" --ed-key-file "$TASK_KEY" --verify "$TASK_OUTPUT/appcast.xml"
python3 "scripts/verify-release.py" "$TASK_TAG" "$TASK_OUTPUT"
python3 "scripts/verify-update-signatures.py" "$TASK_OUTPUT" "$TASK_KEY"
python3 - "$TASK_OUTPUT" <<'PY'
import hashlib, sys
from pathlib import Path
output=Path(sys.argv[1])
files=sorted(p for p in output.iterdir() if p.suffix in {'.dmg','.zip','.gz','.xml'})
(output/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
PY
echo "Verified release artifacts: $TASK_OUTPUT"
