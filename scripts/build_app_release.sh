#!/bin/bash

# Project Echo - Release Build Script
# Optimized build without debug overhead for production use

set -e

# Kill existing instance first
killall ProjectEcho 2>/dev/null || true

# Remove old app bundle for clean build
rm -rf ProjectEcho.app

echo "Building Project Echo (release - optimized)..."
swift build -c release

echo "Creating app bundle..."
mkdir -p ProjectEcho.app/Contents/MacOS
mkdir -p ProjectEcho.app/Contents/Resources

# Copy executable from RELEASE build folder
cp .build/arm64-apple-macosx/release/ProjectEcho ProjectEcho.app/Contents/MacOS/ProjectEcho

# Create Info.plist
cat > ProjectEcho.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ProjectEcho</string>
    <key>CFBundleIdentifier</key>
    <string>com.projectecho.app</string>
    <key>CFBundleName</key>
    <string>Project Echo</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Project Echo needs microphone access to record your audio during meetings.</string>
    <key>NSScreenCaptureDescription</key>
    <string>Project Echo needs screen recording permission to capture audio from conferencing apps like Zoom and Teams.</string>
</dict>
</plist>
EOF

# Sign with stable certificate (preserves TCC permissions across rebuilds)
SIGNING_IDENTITY=""

if security find-identity -v -p codesigning 2>/dev/null | grep -q "ProjectEcho Development"; then
    SIGNING_IDENTITY="ProjectEcho Development"
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --entitlements ProjectEcho.entitlements \
        ProjectEcho.app
    echo "Signed with '$SIGNING_IDENTITY' certificate"
else
    echo "WARNING: No 'ProjectEcho Development' certificate found"
    echo "Run: ./scripts/create_signing_cert.sh"
    echo "Using ad-hoc signing (permissions will reset each build)"
    codesign --force --deep --sign - --entitlements ProjectEcho.entitlements ProjectEcho.app 2>/dev/null || true
fi

echo "Release build complete: ProjectEcho.app"
echo "Note: This build has compiler optimizations enabled for better performance"
