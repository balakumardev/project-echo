#!/bin/bash

# Engram - Release Build Script
# Builds optimized release version with debug logging disabled
# Copyright © 2024-2026 Bala Kumar. All rights reserved.
# https://balakumar.dev

set -e

# Kill existing instance first
killall Engram 2>/dev/null || true

# Remove old app bundle for clean build
rm -rf Engram.app

echo "Building Engram (release)..."
swift build -c release

echo "Creating app bundle..."
mkdir -p Engram.app/Contents/MacOS
mkdir -p Engram.app/Contents/Resources

# Copy executable from release build
cp .build/arm64-apple-macosx/release/Engram Engram.app/Contents/MacOS/Engram

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns Engram.app/Contents/Resources/
    echo "Copied app icon"
fi

# Create Info.plist
cat > Engram.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Engram</string>
    <key>CFBundleIdentifier</key>
    <string>dev.balakumar.engram</string>
    <key>CFBundleName</key>
    <string>Engram</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Engram needs microphone access to record your audio during meetings.</string>
    <key>NSScreenCaptureDescription</key>
    <string>Engram needs screen recording permission to capture audio from conferencing apps like Zoom and Teams.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024-2026 Bala Kumar. All rights reserved. https://balakumar.dev</string>
</dict>
</plist>
EOF

# Sign with stable certificate (preserves TCC permissions across rebuilds)
SIGNING_IDENTITY=""

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Engram Development"; then
    SIGNING_IDENTITY="Engram Development"
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --entitlements Engram.entitlements \
        Engram.app
    echo "Signed with '$SIGNING_IDENTITY' certificate"
else
    echo "WARNING: No 'Engram Development' certificate found"
    echo "Run: ./scripts/create_signing_cert.sh"
    echo "Using ad-hoc signing (permissions will reset each build)"
    codesign --force --deep --sign - --entitlements Engram.entitlements Engram.app 2>/dev/null || true
fi

echo "Release build complete: Engram.app"
echo "  - Optimizations enabled"
echo "  - Debug logging disabled"
echo "  - By Bala Kumar (https://balakumar.dev)"
