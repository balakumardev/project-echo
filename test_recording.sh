#!/bin/bash

# Quick test script for Project Echo

echo "🎙️ Project Echo - Quick Test"
echo ""

# Check if app is running
if ps aux | grep -v grep | grep ProjectEcho > /dev/null; then
    echo "✅ App is running (PID: $(ps aux | grep -v grep | grep ProjectEcho | awk '{print $2}'))"
else
    echo "❌ App is not running"
    echo "   Run: ./run_app.sh"
    exit 1
fi

echo ""
echo "📝 Test Instructions:"
echo ""
echo "1. Look for the 🎙️ icon in your menu bar (top-right)"
echo ""
echo "2. Click the icon → Start Recording"
echo ""
echo "3. Open YouTube and play a video:"
echo "   https://www.youtube.com/watch?v=dQw4w9WgXcQ"
echo ""
echo "4. Speak into your microphone: 'Testing Project Echo'"
echo ""
echo "5. After 30 seconds, click the icon → Stop Recording"
echo ""
echo "6. Click the icon → Open Library"
echo ""
echo "7. You should see your recording with:"
echo "   ✅ YouTube audio"
echo "   ✅ Your voice"
echo "   ✅ AI-generated transcript"
echo ""
echo "📁 Recordings are saved to:"
echo "   ~/Documents/ProjectEcho/Recordings/"
echo ""
echo "🔍 To view recordings manually:"
echo "   open ~/Documents/ProjectEcho/Recordings/"
echo ""

