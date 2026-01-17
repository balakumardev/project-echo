#!/bin/bash

# Engram - Build Script
# Copyright © 2024-2026 Bala Kumar. All rights reserved.
# https://balakumar.dev
#
# Builds Engram using the Xcode project and copies the app to the project root.

set -e

# Kill existing instance first
killall Engram 2>/dev/null || true

# Clear debug log for fresh logs
rm -f ~/engram_debug.log

# Remove old app bundle
rm -rf Engram.app

echo "Building Engram..."
xcodebuild build -project Engram.xcodeproj -scheme Engram -configuration Debug -quiet 2>/dev/null || \
xcodebuild build -project Engram.xcodeproj -scheme Engram -configuration Debug

# Find the built app in DerivedData
BUILD_DIR=$(find ~/Library/Developer/Xcode/DerivedData/Engram-*/Build/Products/Debug -type d -maxdepth 0 2>/dev/null | head -1)

if [ -z "$BUILD_DIR" ] || [ ! -d "$BUILD_DIR/Engram.app" ]; then
    echo "ERROR: Could not find built Engram.app"
    exit 1
fi

echo "Build directory: $BUILD_DIR"

# Copy the complete app bundle (already signed by Xcode)
cp -R "${BUILD_DIR}/Engram.app" ./Engram.app

# Register app with Launch Services for URL scheme handling
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(pwd)/Engram.app"
echo "Registered with Launch Services"

echo ""
echo "Build complete: Engram.app"
echo ""
echo "To run: open Engram.app"
echo ""
echo "Or use Xcode directly: open Engram.xcodeproj and press ⌘R"
