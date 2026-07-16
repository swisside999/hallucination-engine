#!/bin/bash
# Build Hallucination Engine.app from the SwiftPM package (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/Hallucination Engine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/HallucinationEngine "$APP/Contents/MacOS/HallucinationEngine"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>HallucinationEngine</string>
    <!-- bundle id owns @AppStorage prefs (recent mixes, logo
         schedule, repo path) -->
    <key>CFBundleIdentifier</key><string>cloud.munch.hallucination.engine</string>
    <key>CFBundleName</key><string>Hallucination Engine</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
echo "APPL????" > "$APP/Contents/PkgInfo"
echo "built: $PWD/$APP"
