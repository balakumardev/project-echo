#!/bin/bash

echo "🔍 Project Echo - Permission Diagnostic"
echo ""

# Check if app is running
if ps aux | grep -v grep | grep ProjectEcho > /dev/null; then
    PID=$(ps aux | grep -v grep | grep ProjectEcho | awk '{print $2}')
    echo "✅ App is running (PID: $PID)"
else
    echo "❌ App is not running"
    echo "   Run: ./scripts/run_app.sh"
    exit 1
fi

echo ""
echo "📋 Checking permissions..."
echo ""

# Check microphone permission
echo "🎤 Microphone Permission:"
if sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT service, client, auth_value FROM access WHERE service='kTCCServiceMicrophone' AND client LIKE '%projectecho%';" 2>/dev/null | grep -q "1"; then
    echo "   ✅ GRANTED"
elif sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT service, client, auth_value FROM access WHERE service='kTCCServiceMicrophone' AND client LIKE '%projectecho%';" 2>/dev/null | grep -q "0"; then
    echo "   ❌ DENIED"
else
    echo "   ⚠️  NOT REQUESTED YET"
    echo "   The app needs to request permission first"
fi

echo ""
echo "🖥️  Screen Recording Permission:"
if sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT service, client, auth_value FROM access WHERE service='kTCCServiceScreenCapture' AND client LIKE '%projectecho%';" 2>/dev/null | grep -q "1"; then
    echo "   ✅ GRANTED"
elif sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT service, client, auth_value FROM access WHERE service='kTCCServiceScreenCapture' AND client LIKE '%projectecho%';" 2>/dev/null | grep -q "0"; then
    echo "   ❌ DENIED"
else
    echo "   ⚠️  NOT REQUESTED YET"
    echo "   The app needs to request permission first"
fi

echo ""
echo "📝 How to grant permissions manually:"
echo ""
echo "1. Open System Settings → Privacy & Security"
echo ""
echo "2. For Microphone:"
echo "   - Scroll to 'Microphone'"
echo "   - Look for 'ProjectEcho' or 'Project Echo' in the list"
echo "   - If not there, click '+' button"
echo "   - Navigate to: $(pwd)/ProjectEcho.app"
echo "   - Select it and click 'Open'"
echo "   - Enable the checkbox"
echo ""
echo "3. For Screen Recording:"
echo "   - Scroll to 'Screen Recording'"
echo "   - Look for 'ProjectEcho' or 'Project Echo' in the list"
echo "   - If not there, click '+' button"
echo "   - Navigate to: $(pwd)/ProjectEcho.app"
echo "   - Select it and click 'Open'"
echo "   - Enable the checkbox"
echo ""
echo "4. Restart the app:"
echo "   killall ProjectEcho && ./scripts/run_app.sh"
echo ""
echo "💡 Tip: The app won't appear in System Settings until it"
echo "   actually tries to use the microphone or screen recording."
echo "   Try clicking 'Start Recording' in the menu bar first!"
echo ""

