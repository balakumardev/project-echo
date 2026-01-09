#!/bin/bash

# Engram - Build and Run Script
# Copyright © 2024-2026 Bala Kumar. All rights reserved.
# https://balakumar.dev
#
# Uses xcodebuild to compile Metal shaders properly for MLX

set -e

# Kill existing instance first
killall Engram 2>/dev/null || true

# Clear debug log for fresh logs
rm -f ~/engram_debug.log

# Remove old app bundle for clean build
rm -rf Engram.app

echo "Building Engram with xcodebuild (required for Metal shaders)..."
xcodebuild build -scheme Engram -destination 'platform=macOS' -configuration Debug -quiet

# Find the built executable in DerivedData (avoid Index.noindex)
BUILD_DIR=$(find ~/Library/Developer/Xcode/DerivedData/project-echo-*/Build/Products/Debug -type d -maxdepth 0 2>/dev/null | head -1)

if [ -z "$BUILD_DIR" ] || [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: Could not find build directory"
    exit 1
fi
echo "Build directory: $BUILD_DIR"

echo "Creating app bundle..."
mkdir -p Engram.app/Contents/MacOS
mkdir -p Engram.app/Contents/Resources

# Copy executable
cp "${BUILD_DIR}/Engram" Engram.app/Contents/MacOS/Engram

# Copy MLX Metal library bundle (required for local AI models)
if [ -d "${BUILD_DIR}/mlx-swift_Cmlx.bundle" ]; then
    cp -R "${BUILD_DIR}/mlx-swift_Cmlx.bundle" Engram.app/Contents/Resources/
    echo "Copied MLX Metal shaders"
fi

# Copy other required bundles
if [ -d "${BUILD_DIR}/swift-transformers_Hub.bundle" ]; then
    cp -R "${BUILD_DIR}/swift-transformers_Hub.bundle" Engram.app/Contents/Resources/
fi

# Copy Swift 6.2 compatibility library (required for Swift 6.2 toolchain)
mkdir -p Engram.app/Contents/lib
SWIFT_COMPAT_LIB="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib"
if [ -f "$SWIFT_COMPAT_LIB" ]; then
    cp "$SWIFT_COMPAT_LIB" Engram.app/Contents/lib/
    echo "Copied Swift 6.2 compatibility library"
fi

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

    <!-- URL Scheme Handler -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.balakumar.engram.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>engram</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# Register app with Launch Services so macOS knows this app handles engram:// URLs
# This is critical for URL scheme to work after system restart
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(pwd)/Engram.app"
echo "Registered app with Launch Services for URL scheme handling"

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
    echo "Signed with '$SIGNING_IDENTITY' certificate (TCC permissions will persist)"
else
    echo ""
    echo "=============================================="
    echo "WARNING: No 'Engram Development' certificate"
    echo "=============================================="
    echo ""
    echo "Using ad-hoc signing. This means:"
    echo "  - TCC permissions will reset after each rebuild"
    echo "  - Users will need to re-grant permissions after restart"
    echo ""
    echo "To fix this (one-time setup):"
    echo "  1. Run: ./scripts/create_signing_cert.sh"
    echo "  2. Open Keychain Access"
    echo "  3. Find 'Engram Development' in My Certificates"
    echo "  4. Double-click > Trust > Code Signing: Always Trust"
    echo "  5. Rebuild this app"
    echo ""
    codesign --force --deep --sign - --entitlements Engram.entitlements Engram.app 2>/dev/null || true
fi

echo ""
echo "Build complete: Engram.app"
echo ""
echo "To run: open Engram.app"
echo "To distribute: ./scripts/package_for_distribution.sh"
