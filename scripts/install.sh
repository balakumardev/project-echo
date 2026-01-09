#!/bin/bash

# Engram - User Installation Script
# Copyright © 2024-2026 Bala Kumar. All rights reserved.
# https://balakumar.dev
#
# This script installs Engram and handles macOS security requirements
# for apps distributed outside the App Store.

set -e

APP_NAME="Engram"
APP_BUNDLE="$APP_NAME.app"
INSTALL_DIR="/Applications"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo ""
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}     Engram Installer${NC}"
echo -e "${BLUE}     Meeting Recorder & AI Assistant${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# Find the app bundle
if [ -f "$SCRIPT_DIR/../$APP_BUNDLE/Contents/Info.plist" ]; then
    SOURCE_APP="$SCRIPT_DIR/../$APP_BUNDLE"
elif [ -f "$SCRIPT_DIR/$APP_BUNDLE/Contents/Info.plist" ]; then
    SOURCE_APP="$SCRIPT_DIR/$APP_BUNDLE"
elif [ -f "./$APP_BUNDLE/Contents/Info.plist" ]; then
    SOURCE_APP="./$APP_BUNDLE"
else
    echo -e "${RED}ERROR: Cannot find $APP_BUNDLE${NC}"
    echo ""
    echo "Please run this script from the Engram distribution folder,"
    echo "or ensure $APP_BUNDLE is in the same directory."
    exit 1
fi

SOURCE_APP=$(cd "$(dirname "$SOURCE_APP")" && pwd)/$(basename "$SOURCE_APP")
echo -e "Found: ${GREEN}$SOURCE_APP${NC}"
echo ""

# Step 1: Remove quarantine attribute
echo -e "${YELLOW}Step 1: Removing macOS quarantine...${NC}"
xattr -cr "$SOURCE_APP" 2>/dev/null || true
echo -e "${GREEN}   Done${NC}"
echo ""

# Step 2: Check if already installed
TARGET_APP="$INSTALL_DIR/$APP_BUNDLE"
if [ -d "$TARGET_APP" ]; then
    echo -e "${YELLOW}Step 2: Existing installation found${NC}"
    echo ""
    echo "An existing installation was found at: $TARGET_APP"
    echo ""
    read -p "Replace it? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Installation cancelled.${NC}"
        exit 0
    fi

    # Kill running instance if any
    killall "$APP_NAME" 2>/dev/null || true
    sleep 1

    # Remove old installation
    rm -rf "$TARGET_APP"
    echo -e "${GREEN}   Removed old installation${NC}"
else
    echo -e "${YELLOW}Step 2: Installing to /Applications...${NC}"
fi

# Step 3: Copy app to Applications
echo ""
echo -e "${YELLOW}Step 3: Copying to $INSTALL_DIR...${NC}"
cp -R "$SOURCE_APP" "$INSTALL_DIR/"
echo -e "${GREEN}   Installed to $TARGET_APP${NC}"
echo ""

# Step 4: Remove quarantine from installed app
echo -e "${YELLOW}Step 4: Finalizing installation...${NC}"
xattr -cr "$TARGET_APP" 2>/dev/null || true
echo -e "${GREEN}   Done${NC}"
echo ""

# Success message
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}     Installation Complete!${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo -e "${BLUE}IMPORTANT: First-time setup required${NC}"
echo ""
echo "Engram needs system permissions to work. On first launch:"
echo ""
echo "1. You may see 'Engram cannot be opened because it is from an"
echo "   unidentified developer'. If so:"
echo "   - Open System Settings > Privacy & Security"
echo "   - Scroll down and click 'Open Anyway' next to the Engram message"
echo ""
echo "2. Grant these permissions when prompted:"
echo "   - Microphone: Required to record your voice"
echo "   - Screen Recording: Required to capture meeting audio"
echo ""
echo "   Or set them manually in:"
echo "   System Settings > Privacy & Security > Microphone"
echo "   System Settings > Privacy & Security > Screen Recording"
echo ""
echo -e "To launch: ${GREEN}open /Applications/Engram.app${NC}"
echo ""
echo "---"
echo "Engram by Bala Kumar - https://balakumar.dev"
echo ""
