#!/bin/zsh
set -euo pipefail
RILL_ROOT="${0:A:h:h}"
swift build --package-path "$RILL_ROOT" -c release
swift build --package-path "$RILL_ROOT" -c release --product protoc
RILL_BIN="$(swift build --package-path "$RILL_ROOT" -c release --show-bin-path)"
mkdir -p "$RILL_ROOT/dist"
RILL_OUTPUT="$RILL_ROOT/dist/Rill.app"
RILL_STAGE="$(mktemp -d "$RILL_ROOT/dist/.rill-package.XXXXXX")"
RILL_APP="$RILL_STAGE/Rill.app"
mkdir -p "$RILL_APP/Contents/MacOS" "$RILL_APP/Contents/Resources" "$RILL_APP/Contents/Helpers"
cp "$RILL_BIN/Rill" "$RILL_APP/Contents/MacOS/Rill"
cp "$RILL_BIN/RillCLI" "$RILL_APP/Contents/Helpers/rill"
codesign --force --sign - "$RILL_APP/Contents/Helpers/rill"
cp "$RILL_ROOT/Sources/Rill/Resources/Rill.icns" "$RILL_APP/Contents/Resources/Rill.icns"
cat > "$RILL_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Rill</string>
<key>CFBundleIdentifier</key><string>app.rill.workbench</string>
<key>CFBundleName</key><string>Rill</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>Rill.icns</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<!-- API clients must support explicit user-selected HTTP endpoints and custom trust.
     HTTPS verification and TLS minimums remain enforced by the native transport. -->
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
for RILL_RESOURCE in "$RILL_BIN"/*.bundle(N); do
  ditto "$RILL_RESOURCE" "$RILL_APP/Contents/Resources/${RILL_RESOURCE:t}"
done
cp "$RILL_BIN/protoc" "$RILL_APP/Contents/Resources/protoc"
mkdir -p "$RILL_APP/Contents/Resources/protobuf-includes/google/protobuf"
for RILL_PROTO in "$RILL_ROOT"/.build/checkouts/swift-protobuf/Sources/protobuf/protobuf/src/google/protobuf/*.proto; do
  cp "$RILL_PROTO" "$RILL_APP/Contents/Resources/protobuf-includes/google/protobuf/"
done
codesign --force --sign - "$RILL_APP/Contents/Resources/protoc"
codesign --verify --strict "$RILL_APP/Contents/Resources/protoc"
cp "$RILL_ROOT/THIRD_PARTY_NOTICES.txt" "$RILL_APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
mkdir -p "$RILL_APP/Contents/Frameworks"
xcrun swift-stdlib-tool --copy --scan-executable "$RILL_APP/Contents/MacOS/Rill" --scan-executable "$RILL_APP/Contents/Helpers/rill" --destination "$RILL_APP/Contents/Frameworks" --platform macosx
for RILL_DYLIB in "$RILL_APP"/Contents/Frameworks/*.dylib(N); do
  codesign --force --sign - "$RILL_DYLIB"
  codesign --verify --strict "$RILL_DYLIB"
done
plutil -lint "$RILL_APP/Contents/Info.plist"
[[ "$("$RILL_APP/Contents/Helpers/rill" --version)" == "0.3.0" ]]
"$RILL_APP/Contents/Helpers/rill" --help >/dev/null
codesign --verify --strict "$RILL_APP/Contents/Helpers/rill"
codesign --force --sign - "$RILL_APP"
codesign --verify --strict "$RILL_APP"
python3 - "$RILL_APP" "$RILL_OUTPUT" "$RILL_STAGE" <<'PY_INSTALL'
import plistlib, shutil, sys
from pathlib import Path
source, target, stage = map(Path, sys.argv[1:])
if target.is_symlink(): raise SystemExit('Refusing to replace a symlink at the generated app output.')
if target.exists():
    with (target / 'Contents/Info.plist').open('rb') as stream: info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'app.rill.workbench': raise SystemExit('Existing output is not a generated Rill app.')
    shutil.rmtree(target)
shutil.move(source, target)
stage.rmdir()
PY_INSTALL
echo "Built $RILL_OUTPUT"
