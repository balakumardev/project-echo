#!/bin/bash

# Build script for Project Echo
# Builds both the main app and HAL plugin

set -e

echo "🎙️ Building Project Echo..."
echo ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
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

# Build HAL plugin
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Building HAL Plugin (Pro Extension)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

cd HALPlugin
make clean
make

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ HAL plugin built successfully${NC}"
else
    echo -e "${RED}❌ HAL plugin build failed${NC}"
    exit 1
fi

cd ..

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✨ Build Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📦 Artifacts:"
echo "  • Main App: .build/release/ProjectEcho"
echo "  • HAL Plugin: HALPlugin/EchoHAL.driver/"
echo ""
echo "📝 Next steps:"
echo "  1. Run: swift run ProjectEcho"
echo "  2. Install HAL: cd HALPlugin && sudo make install"
echo ""
