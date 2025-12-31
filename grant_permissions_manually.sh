#!/bin/bash

echo "🔧 Project Echo - Manual Permission Grant"
echo ""
echo "⚠️  IMPORTANT: macOS doesn't show permission prompts for ad-hoc signed apps"
echo "   running from non-standard locations. We need to grant permissions manually."
echo ""

# Kill the app first
echo "1️⃣ Stopping app..."
killall ProjectEcho 2>/dev/null || true
sleep 1

echo ""
echo "2️⃣ Opening System Settings..."
echo ""
echo "   I'm going to open System Settings for you."
echo "   Please follow these steps EXACTLY:"
echo ""
echo "   📍 FOR MICROPHONE:"
echo "   1. Go to: Privacy & Security → Microphone"
echo "   2. Click the '+' button at the bottom"
echo "   3. Press Cmd+Shift+G and paste this path:"
echo "      /Users/balakumar/personal/project-echo/ProjectEcho.app"
echo "   4. Click 'Open'"
echo "   5. Enable the checkbox next to 'ProjectEcho'"
echo ""
echo "   📍 FOR SCREEN RECORDING:"
echo "   1. Go to: Privacy & Security → Screen Recording"  
echo "   2. Click the '+' button at the bottom"
echo "   3. Press Cmd+Shift+G and paste this path:"
echo "      /Users/balakumar/personal/project-echo/ProjectEcho.app"
echo "   4. Click 'Open'"
echo "   5. Enable the checkbox next to 'ProjectEcho'"
echo ""

read -p "Press ENTER to open System Settings..."

# Open System Settings to Privacy & Security
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

echo ""
echo "✅ System Settings opened!"
echo ""
echo "⏳ Waiting for you to grant permissions..."
echo "   (Follow the instructions above)"
echo ""
read -p "Press ENTER after you've granted BOTH Microphone and Screen Recording permissions..."

echo ""
echo "3️⃣ Verifying permissions..."
sleep 2

# Check if permissions were granted
MIC_PERM=$(sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT auth_value FROM access WHERE service='kTCCServiceMicrophone' AND client LIKE '%ProjectEcho%';" 2>/dev/null)
SCREEN_PERM=$(sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT auth_value FROM access WHERE service='kTCCServiceScreenCapture' AND client LIKE '%ProjectEcho%';" 2>/dev/null)

echo ""
if [ "$MIC_PERM" = "2" ]; then
    echo "✅ Microphone permission: GRANTED"
else
    echo "❌ Microphone permission: NOT GRANTED (value: $MIC_PERM)"
fi

if [ "$SCREEN_PERM" = "2" ]; then
    echo "✅ Screen Recording permission: GRANTED"
else
    echo "❌ Screen Recording permission: NOT GRANTED (value: $SCREEN_PERM)"
fi

echo ""
if [ "$MIC_PERM" = "2" ] && [ "$SCREEN_PERM" = "2" ]; then
    echo "🎉 SUCCESS! Both permissions granted!"
    echo ""
    echo "4️⃣ Launching app..."
    open ProjectEcho.app
    sleep 2
    echo ""
    echo "✅ App launched! Now try recording:"
    echo "   1. Click the 🎙️ menu bar icon"
    echo "   2. Click 'Start Recording'"
    echo "   3. Speak into your microphone"
    echo "   4. Play a YouTube video"
    echo "   5. After 10 seconds, click 'Stop Recording'"
    echo ""
else
    echo ""
    echo "⚠️  Permissions not fully granted. Please:"
    echo "   1. Make sure you added ProjectEcho.app to BOTH Microphone AND Screen Recording"
    echo "   2. Make sure the checkboxes are ENABLED"
    echo "   3. Run this script again to verify"
    echo ""
fi

