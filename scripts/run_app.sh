#!/bin/bash

# Project Echo - Easy Launch Script
# This script builds and runs the app as a proper macOS bundle

set -e

echo "🎙️ Project Echo Launcher"
echo ""

# Check if app bundle exists and is up to date
NEEDS_BUILD=false

if [ ! -d "ProjectEcho.app" ]; then
    echo "📦 App bundle not found, will create..."
    NEEDS_BUILD=true
elif [ ".build/arm64-apple-macosx/debug/ProjectEcho" -nt "ProjectEcho.app/Contents/MacOS/ProjectEcho" ]; then
    echo "🔄 Executable updated, will rebuild bundle..."
    NEEDS_BUILD=true
fi

# Build if needed
if [ "$NEEDS_BUILD" = true ]; then
    echo "🔨 Building Swift project..."
    swift build
    
    echo "📦 Creating app bundle..."
    
    # Create bundle structure
    mkdir -p ProjectEcho.app/Contents/MacOS
    mkdir -p ProjectEcho.app/Contents/Resources
    
    # Copy executable
    cp .build/arm64-apple-macosx/debug/ProjectEcho ProjectEcho.app/Contents/MacOS/ProjectEcho
    
    # Create proper Info.plist
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
    
    # Sign with entitlements
    codesign --force --deep --sign - --entitlements ProjectEcho.entitlements ProjectEcho.app 2>/dev/null || true
    
    echo "✅ App bundle ready"
fi

# Kill existing instance
killall ProjectEcho 2>/dev/null || true

# Launch app
echo "🚀 Launching Project Echo..."
open ProjectEcho.app

echo ""
echo "✅ App launched! Look for the menu bar icon (top-right of screen)"
echo ""
echo "📝 First time setup:"
echo "   1. Grant Microphone permission in System Settings"
echo "   2. Grant Screen Recording permission in System Settings"
echo "   3. Restart the app after granting permissions"
echo ""
echo "🎬 To use:"
echo "   • Click menu bar icon → Start Recording"
echo "   • Click menu bar icon → Open Library (view recordings)"
echo ""

