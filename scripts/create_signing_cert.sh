#!/bin/bash

# Engram - Code Signing Certificate Creation Script
# Copyright © 2024-2026 Bala Kumar. All rights reserved.
# https://balakumar.dev
#
# Creates a self-signed code signing certificate for Engram
# This certificate allows stable code signing so TCC permissions persist across rebuilds

set -e

CERT_NAME="Engram Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "==========================================="
echo "Engram Development Certificate Setup"
echo "==========================================="
echo ""

# Check if certificate already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists!"
    echo ""
    security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME"
    echo ""
    echo "To recreate, first delete it from Keychain Access, then run this script again."
    exit 0
fi

echo "Creating self-signed code signing certificate: '$CERT_NAME'"
echo ""

# Use a temporary directory for the certificate files
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Create certificate signing request config with proper extensions
cat > "$TEMP_DIR/cert.conf" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = codesign_ext
prompt = no

[req_distinguished_name]
CN = $CERT_NAME
O = Engram Development

[codesign_ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
EOF

echo "Step 1: Generating private key and certificate..."

# Generate private key and self-signed certificate (valid for 10 years)
openssl req -x509 -newkey rsa:2048 \
    -keyout "$TEMP_DIR/key.pem" \
    -out "$TEMP_DIR/cert.pem" \
    -days 3650 \
    -nodes \
    -config "$TEMP_DIR/cert.conf" 2>/dev/null

# Create PKCS12 file (required for importing into Keychain)
# Note: -legacy flag is needed for OpenSSL 3.x compatibility with macOS Keychain
openssl pkcs12 -export -legacy \
    -out "$TEMP_DIR/cert.p12" \
    -inkey "$TEMP_DIR/key.pem" \
    -in "$TEMP_DIR/cert.pem" \
    -passout pass:engram_temp_password 2>/dev/null

echo "Step 2: Importing certificate into login keychain..."

# Import into login keychain with permissions for codesign
security import "$TEMP_DIR/cert.p12" \
    -k "$KEYCHAIN" \
    -P engram_temp_password \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productbuild

# Add certificate to trust settings for code signing
# This is required for macOS to recognize it as valid for code signing
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TEMP_DIR/cert.pem" 2>/dev/null || true

echo "Step 3: Setting up keychain access permissions..."

# Allow codesign to access the private key without prompting
# This may ask for your login password
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "" \
    "$KEYCHAIN" 2>/dev/null || {
    echo ""
    echo "Note: You may need to enter your login password when first signing."
}

echo ""
echo "Step 4: Verifying certificate installation..."
echo ""

# Check if certificate is now available
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "SUCCESS! Certificate installed:"
    security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME"
    echo ""
    echo "==========================================="
    echo "IMPORTANT: Manual Trust Step Required"
    echo "==========================================="
    echo ""
    echo "To enable code signing, you must manually trust the certificate:"
    echo ""
    echo "1. Open 'Keychain Access' app (press Cmd+Space, type 'Keychain Access')"
    echo "2. In the sidebar, select 'login' keychain"
    echo "3. Select 'My Certificates' category"
    echo "4. Find and double-click '$CERT_NAME'"
    echo "5. Expand the 'Trust' section (click the arrow)"
    echo "6. Set 'Code Signing' to 'Always Trust'"
    echo "7. Close the window and enter your password when prompted"
    echo ""
    echo "After trusting, run: ./scripts/build_app.sh"
    echo ""
else
    echo "ERROR: Certificate was not properly installed."
    echo ""
    echo "Please try creating it manually using Keychain Access:"
    echo "1. Open Keychain Access"
    echo "2. Menu: Keychain Access > Certificate Assistant > Create a Certificate..."
    echo "3. Name: '$CERT_NAME'"
    echo "4. Identity Type: Self Signed Root"
    echo "5. Certificate Type: Code Signing"
    echo "6. Click Create"
    echo ""
    exit 1
fi
