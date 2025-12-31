#!/bin/bash

echo "🐛 Debugging Menu Bar Issue"
echo ""

# Kill and restart with console output
echo "Killing old app..."
killall ProjectEcho 2>/dev/null
sleep 1

echo "Starting app with debug output..."
echo ""
echo "════════════════════════════════════════════════════════"
echo "APP OUTPUT:"
echo "════════════════════════════════════════════════════════"

# Run the app directly to see console output
./ProjectEcho.app/Contents/MacOS/ProjectEcho &
APP_PID=$!

echo "App started with PID: $APP_PID"
echo ""
echo "Waiting 5 seconds for initialization..."
sleep 5

echo ""
echo "════════════════════════════════════════════════════════"
echo "CHECKING STATUS:"
echo "════════════════════════════════════════════════════════"

if ps -p $APP_PID > /dev/null; then
    echo "✅ App is still running"
else
    echo "❌ App crashed or exited"
    exit 1
fi

echo ""
echo "📝 Now try clicking the menu bar icon!"
echo ""
echo "Expected behavior:"
echo "  1. You should see a 🎙️ icon in the menu bar"
echo "  2. Click it"
echo "  3. All menu items should be ENABLED (not grayed out)"
echo "  4. Click 'Start Recording'"
echo "  5. You should get a permission prompt"
echo ""
echo "If menu items are still disabled, press Ctrl+C and report back."
echo ""
echo "Watching for errors (press Ctrl+C to stop)..."
echo ""

# Keep script running
wait $APP_PID

