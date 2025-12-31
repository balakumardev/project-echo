#!/bin/bash

echo "🔍 Checking System Settings for ProjectEcho permissions"
echo ""

# Check TCC database for microphone
echo "🎤 Microphone Permission in TCC Database:"
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT service, client, auth_value, auth_reason FROM access WHERE service='kTCCServiceMicrophone' AND client LIKE '%projectecho%' OR client LIKE '%ProjectEcho%';" 2>/dev/null || echo "   No entries found"

echo ""

# Check TCC database for screen capture
echo "🖥️  Screen Recording Permission in TCC Database:"
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT service, client, auth_value, auth_reason FROM access WHERE service='kTCCServiceScreenCapture' AND client LIKE '%projectecho%' OR client LIKE '%ProjectEcho%';" 2>/dev/null || echo "   No entries found"

echo ""
echo "📋 All Microphone Permissions:"
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT client, auth_value FROM access WHERE service='kTCCServiceMicrophone';" 2>/dev/null | tail -10

echo ""
echo "📋 All Screen Recording Permissions:"
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT client, auth_value FROM access WHERE service='kTCCServiceScreenCapture';" 2>/dev/null | tail -10

echo ""
echo "💡 Legend:"
echo "   auth_value: 0 = Denied, 1 = Unknown, 2 = Allowed, 3 = Limited"
echo ""

echo "🔧 To manually open System Settings:"
echo "   open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'"
echo ""

