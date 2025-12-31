#!/bin/bash

echo "🎙️ Project Echo - Recording Analysis"
echo ""
echo "📝 Instructions:"
echo ""
echo "1. Click the menu bar icon (🎙️)"
echo "2. Click 'Start Recording'"
echo "3. SPEAK INTO YOUR MICROPHONE for 10 seconds"
echo "4. ALSO: Play a YouTube video or music in Safari/Chrome"
echo "5. Click 'Stop Recording'"
echo ""
echo "Press ENTER when you've finished recording..."
read

echo ""
echo "📊 Checking logs for audio capture..."
echo ""

# Show logs from the last 2 minutes
log show --predicate 'subsystem == "com.projectecho.app"' --last 2m --style compact 2>&1 | grep -E "(AudioEngine|ScreenCapture|MicCapture|buffer|audio)" | tail -50

echo ""
echo "📁 Checking recording files..."
echo ""

# Find the most recent recording
LATEST=$(ls -t ~/Documents/ProjectEcho/Recordings/*.mov 2>/dev/null | head -1)

if [ -z "$LATEST" ]; then
    echo "❌ No recordings found!"
    exit 1
fi

echo "Latest recording: $LATEST"
echo ""

# Show file info
afinfo "$LATEST" 2>&1

echo ""
echo "📊 Analysis:"
echo ""

# Extract track info
TRACK1_BYTES=$(afinfo "$LATEST" 2>&1 | grep -A 15 "Track ID:    1" | grep "audio bytes:" | awk '{print $3}')
TRACK2_BYTES=$(afinfo "$LATEST" 2>&1 | grep -A 15 "Track ID:    2" | grep "audio bytes:" | awk '{print $3}')

echo "Track 1 (System Audio): $TRACK1_BYTES bytes"
echo "Track 2 (Microphone):   $TRACK2_BYTES bytes"
echo ""

if [ "$TRACK1_BYTES" -lt 10000 ]; then
    echo "⚠️  WARNING: Track 1 (System Audio) has very little data!"
    echo "   This means ScreenCaptureKit is not capturing system audio."
    echo "   Possible reasons:"
    echo "   - No system audio was playing during recording"
    echo "   - Screen Recording permission not properly granted"
    echo "   - ScreenCaptureKit delegate not receiving buffers"
else
    echo "✅ Track 1 (System Audio) looks good!"
fi

if [ "$TRACK2_BYTES" -lt 10000 ]; then
    echo "⚠️  WARNING: Track 2 (Microphone) has very little data!"
    echo "   This means microphone is not capturing audio."
    echo "   Possible reasons:"
    echo "   - You didn't speak during recording"
    echo "   - Microphone permission not properly granted"
    echo "   - Wrong microphone selected"
else
    echo "✅ Track 2 (Microphone) looks good!"
fi

echo ""
echo "🎧 To play the recording:"
echo "   open '$LATEST'"
echo ""

