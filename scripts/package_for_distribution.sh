#!/bin/bash

# Engram - Package for Distribution Script
# Copyright © 2024-2026 Bala Kumar. All rights reserved.
# https://balakumar.dev
#
# Creates a distributable package (ZIP) containing the app and installer

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Engram"
APP_BUNDLE="$APP_NAME.app"
VERSION=$(date +"%Y.%m.%d")

cd "$PROJECT_DIR"

echo "==========================================="
echo "Engram Distribution Packager"
echo "==========================================="
echo ""

# Check if app exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: $APP_BUNDLE not found!"
    echo ""
    echo "Build the app first with: ./scripts/build_app.sh"
    exit 1
fi

# Check signing status
SIGNING_STATUS=$(codesign -dvv "$APP_BUNDLE" 2>&1 | grep "Signature=" || echo "unknown")
if echo "$SIGNING_STATUS" | grep -q "adhoc"; then
    echo "WARNING: App is signed with ad-hoc signature!"
    echo "TCC permissions will NOT persist across restarts for users."
    echo ""
    echo "For stable permissions, set up the signing certificate:"
    echo "  1. Run: ./scripts/create_signing_cert.sh"
    echo "  2. Trust the certificate in Keychain Access"
    echo "  3. Rebuild: ./scripts/build_app.sh"
    echo ""
    read -p "Continue anyway? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create distribution folder
DIST_DIR="dist"
DIST_NAME="${APP_NAME}-${VERSION}"
DIST_FOLDER="$DIST_DIR/$DIST_NAME"

echo "Creating distribution package..."
echo ""

rm -rf "$DIST_FOLDER"
mkdir -p "$DIST_FOLDER"

# Copy app
echo "  Copying $APP_BUNDLE..."
cp -R "$APP_BUNDLE" "$DIST_FOLDER/"

# Copy installer script
echo "  Copying installer..."
cp "$SCRIPT_DIR/install.sh" "$DIST_FOLDER/"

# Create README for distribution
cat > "$DIST_FOLDER/README.txt" << 'EOF'
Engram - Meeting Recorder & AI Assistant
=========================================

By Bala Kumar - https://balakumar.dev


INSTALLATION
------------

1. Double-click 'install.sh' or run in Terminal:
   ./install.sh

2. The app will be installed to /Applications

3. On first launch, you may need to:
   - Go to System Settings > Privacy & Security
   - Click "Open Anyway" for Engram

4. Grant permissions when prompted:
   - Microphone: To record your voice
   - Screen Recording: To capture meeting audio from apps


PERMISSIONS RESET AFTER RESTART?
--------------------------------

If permissions reset after restarting your Mac, this is because
the app is not signed with an Apple Developer certificate.

Workaround: After each restart, simply re-grant the permissions
in System Settings > Privacy & Security.

For permanent permissions (developers only):
See the project documentation for signing certificate setup.


TROUBLESHOOTING
---------------

"Engram can't be opened because it is from an unidentified developer"
  -> System Settings > Privacy & Security > Click "Open Anyway"

Microphone not working:
  -> System Settings > Privacy & Security > Microphone > Enable Engram

Can't capture meeting audio:
  -> System Settings > Privacy & Security > Screen Recording > Enable Engram


SUPPORT
-------

Report issues at: [project repository]
Contact: https://balakumar.dev

EOF

# Remove quarantine from distribution files
xattr -cr "$DIST_FOLDER" 2>/dev/null || true

# Create ZIP
echo "  Creating ZIP archive..."
cd "$DIST_DIR"
rm -f "${DIST_NAME}.zip"
zip -r -q "${DIST_NAME}.zip" "$DIST_NAME"

# Cleanup
rm -rf "$DIST_NAME"

cd "$PROJECT_DIR"

echo ""
echo "==========================================="
echo "Distribution package created!"
echo "==========================================="
echo ""
echo "Output: $DIST_DIR/${DIST_NAME}.zip"
echo ""
echo "This ZIP contains:"
echo "  - $APP_BUNDLE (the application)"
echo "  - install.sh (installer script)"
echo "  - README.txt (user instructions)"
echo ""
echo "Share this ZIP file with users. They should:"
echo "  1. Extract the ZIP"
echo "  2. Run ./install.sh"
echo ""
