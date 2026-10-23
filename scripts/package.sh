#!/bin/zsh
set -euo pipefail
RILL_ROOT="${0:A:h:h}"
swift build --package-path "$RILL_ROOT" -c release
RILL_BIN="$(swift build --package-path "$RILL_ROOT" -c release --show-bin-path)"
RILL_APP="$RILL_ROOT/dist/Rill.app"
mkdir -p "$RILL_APP/Contents/MacOS" "$RILL_APP/Contents/Resources"
cp "$RILL_BIN/Rill" "$RILL_APP/Contents/MacOS/Rill"
cat > "$RILL_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Rill</string>
<key>CFBundleIdentifier</key><string>app.rill.workbench</string>
<key>CFBundleName</key><string>Rill</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$RILL_APP"
echo "Built $RILL_APP"
