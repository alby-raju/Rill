#!/bin/bash
# Run only with an available Developer ID identity and an existing notarytool profile.
set -euo pipefail
: "${RILL_SIGN_IDENTITY:?Set the Developer ID Application identity}"
: "${RILL_NOTARY_PROFILE:?Set an existing notarytool Keychain profile}"
RILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RILL_APP="$RILL_ROOT/dist/Rill.app"
test -d "$RILL_APP"
for RILL_FILE in "$RILL_APP"/Contents/Frameworks/*.dylib "$RILL_APP/Contents/Helpers/rill" "$RILL_APP/Contents/Resources/protoc"; do
  test -f "$RILL_FILE" || continue
  codesign --force --options runtime --timestamp --sign "$RILL_SIGN_IDENTITY" "$RILL_FILE"
done
codesign --force --options runtime --timestamp --sign "$RILL_SIGN_IDENTITY" "$RILL_APP"
codesign --verify --deep --strict "$RILL_APP"
ditto -c -k --keepParent "$RILL_APP" "$RILL_ROOT/dist/Rill-notarization.zip"
xcrun notarytool submit "$RILL_ROOT/dist/Rill-notarization.zip" --keychain-profile "$RILL_NOTARY_PROFILE" --wait
xcrun stapler staple "$RILL_APP"
xcrun stapler validate "$RILL_APP"
spctl --assess --type execute --verbose "$RILL_APP"
RILL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$RILL_APP/Contents/Info.plist")"
RILL_DMG="$RILL_ROOT/dist/Rill-${RILL_VERSION}-$(uname -m).dmg"
RILL_STAGE="$(mktemp -d "$RILL_ROOT/dist/.rill-signed.XXXXXX")"
ditto "$RILL_APP" "$RILL_STAGE/Rill.app"
ln -s /Applications "$RILL_STAGE/Applications"
hdiutil create -quiet -ov -format UDZO -volname Rill -srcfolder "$RILL_STAGE" "$RILL_DMG"
codesign --force --timestamp --sign "$RILL_SIGN_IDENTITY" "$RILL_DMG"
xcrun notarytool submit "$RILL_DMG" --keychain-profile "$RILL_NOTARY_PROFILE" --wait
xcrun stapler staple "$RILL_DMG"
xcrun stapler validate "$RILL_DMG"
spctl --assess --type open --context context:primary-signature --verbose "$RILL_DMG"
shasum -a 256 "$RILL_DMG" >"$RILL_DMG.sha256"
python3 - "$RILL_STAGE" <<'PY_CLEAN'
import shutil
import sys
from pathlib import Path

p = Path(sys.argv[1])
assert p.name.startswith(".rill-signed.") and p.parent.name == "dist"
shutil.rmtree(p)
PY_CLEAN
