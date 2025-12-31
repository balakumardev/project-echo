#!/bin/bash

echo "🔧 Project Echo - Permission Fix Script"
echo ""

# Kill the app
echo "1️⃣ Stopping app..."
killall ProjectEcho 2>/dev/null || true
killall test_menu 2>/dev/null || true
sleep 1

# Reset TCC permissions for this app
echo ""
echo "2️⃣ Resetting permissions..."
echo "   (This requires your password)"
echo ""

# Try to reset - this might fail on newer macOS versions
tccutil reset Microphone com.projectecho.app 2>/dev/null || echo "   Note: tccutil reset may not work on this macOS version"
tccutil reset ScreenCapture com.projectecho.app 2>/dev/null || echo "   Note: tccutil reset may not work on this macOS version"

echo ""
echo "3️⃣ Rebuilding app with fresh signature..."
swift build -c release 2>&1 | tail -3

# Update app bundle
cp .build/release/ProjectEcho ProjectEcho.app/Contents/MacOS/ProjectEcho

# Re-sign with fresh signature
codesign --force --deep --sign - --entitlements ProjectEcho.entitlements ProjectEcho.app 2>&1

echo ""
echo "4️⃣ Launching app..."
open ProjectEcho.app
sleep 3

echo ""
echo "✅ App launched!"
echo ""
echo "📝 IMPORTANT: Now do this:"
echo ""
echo "1. Click the 🎙️ menu bar icon"
echo "2. Click 'Start Recording'"
echo "3. You should see permission prompts - click 'OK' or 'Open System Settings'"
echo "4. In System Settings:"
echo "   - Go to Privacy & Security → Screen Recording"
echo "   - Find 'ProjectEcho' and enable it"
echo "   - Go to Privacy & Security → Microphone"  
echo "   - Find 'ProjectEcho' and enable it"
echo "5. Restart the app: killall ProjectEcho && open ProjectEcho.app"
echo "6. Try recording again!"
echo ""
echo "💡 The app should now appear in System Settings after you click 'Start Recording'"
echo ""

