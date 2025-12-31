#!/bin/bash

# Build script for Project Echo
# Builds the main app (HAL plugin is optional)

set -e

echo "🎙️ Building Project Echo..."
echo ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Build main app
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Building Main Application${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

swift build -c release --arch arm64 --arch x86_64

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Main app built successfully${NC}"
else
    echo -e "${RED}❌ Main app build failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✨ Build Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📦 Main App: .build/release/ProjectEcho"
echo ""
echo "🎯 What you can do:"
echo "  ✅ Record meetings (mic + system audio)"
echo "  ✅ AI transcription (WhisperKit)"
echo "  ✅ Auto-record Zoom/Teams/Meet"
echo "  ✅ Recording library & search"
echo ""
echo "📝 Next steps:"
echo "  1. Run: ./scripts/run_app.sh"
echo "  2. Grant permissions in System Settings"
echo "  3. Start recording!"
echo ""
echo -e "${YELLOW}ℹ️  HAL Plugin (Optional):${NC}"
echo "   The virtual audio device is NOT required for basic functionality."
echo "   To build it anyway: cd HALPlugin && make"
echo "   See HAL_PLUGIN_ADVANCED.md for details."
echo ""
