#!/bin/bash

# Project Echo - Build and Run Script
# Uses xcodebuild to compile Metal shaders properly for MLX

set -e

# Kill existing instance first
killall ProjectEcho 2>/dev/null || true

# Clear debug log for fresh logs
rm -f ~/projectecho_debug.log

# Remove old app bundle for clean build
rm -rf ProjectEcho.app

echo "Building Project Echo with xcodebuild (required for Metal shaders)..."
xcodebuild build -scheme ProjectEcho -destination 'platform=macOS' -configuration Debug -quiet

# Find the built executable in DerivedData (avoid Index.noindex)
BUILD_DIR=$(find ~/Library/Developer/Xcode/DerivedData/project-echo-*/Build/Products/Debug -type d -maxdepth 0 2>/dev/null | head -1)

if [ -z "$BUILD_DIR" ] || [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: Could not find build directory"
    exit 1
fi
echo "Build directory: $BUILD_DIR"

echo "Creating app bundle..."
mkdir -p ProjectEcho.app/Contents/MacOS
mkdir -p ProjectEcho.app/Contents/Resources

# Copy executable
cp "${BUILD_DIR}/ProjectEcho" ProjectEcho.app/Contents/MacOS/ProjectEcho

# Copy MLX Metal library bundle (required for local AI models)
if [ -d "${BUILD_DIR}/mlx-swift_Cmlx.bundle" ]; then
    cp -R "${BUILD_DIR}/mlx-swift_Cmlx.bundle" ProjectEcho.app/Contents/Resources/
    echo "Copied MLX Metal shaders"
fi

# Copy other required bundles
if [ -d "${BUILD_DIR}/swift-transformers_Hub.bundle" ]; then
    cp -R "${BUILD_DIR}/swift-transformers_Hub.bundle" ProjectEcho.app/Contents/Resources/
fi

# Copy Swift 6.2 compatibility library (required for Swift 6.2 toolchain)
mkdir -p ProjectEcho.app/Contents/lib
SWIFT_COMPAT_LIB="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib"
if [ -f "$SWIFT_COMPAT_LIB" ]; then
    cp "$SWIFT_COMPAT_LIB" ProjectEcho.app/Contents/lib/
    echo "Copied Swift 6.2 compatibility library"
fi

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

echo "Build complete: ProjectEcho.app"
