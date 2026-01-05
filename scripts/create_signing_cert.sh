#!/bin/bash

# Engram - Code Signing Certificate Creation Script
# Copyright © 2024-2026 Bala Kumar. All rights reserved.
# https://balakumar.dev
#
# Creates a self-signed code signing certificate for Engram
# This certificate allows stable code signing so permissions persist across rebuilds

set -e

CERT_NAME="Engram Development"

echo "Creating self-signed code signing certificate: '$CERT_NAME'"
echo ""

# Check if certificate already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists!"
    echo ""
    security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME"
    exit 0
fi

# Create the certificate using the security command
# This creates a self-signed certificate valid for 10 years
echo "Creating certificate in login keychain..."
echo ""

# Use a temporary directory for the certificate files
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Create certificate signing request config
cat > "$TEMP_DIR/cert.conf" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $CERT_NAME

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:FALSE
EOF

# Generate private key and self-signed certificate
openssl req -x509 -newkey rsa:2048 -keyout "$TEMP_DIR/key.pem" -out "$TEMP_DIR/cert.pem" \
    -days 3650 -nodes -config "$TEMP_DIR/cert.conf" 2>/dev/null

# Create PKCS12 file (required for importing into Keychain)
openssl pkcs12 -export -out "$TEMP_DIR/cert.p12" -inkey "$TEMP_DIR/key.pem" -in "$TEMP_DIR/cert.pem" \
    -passout pass:temp123 2>/dev/null

# Import into login keychain
security import "$TEMP_DIR/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -P temp123 -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null

# Trust the certificate for code signing
echo ""
echo "Setting certificate trust for code signing..."
echo "You may be prompted for your login password."
echo ""

# Find and set the trust settings
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true

echo ""
echo "Certificate created successfully!"
echo ""
echo "Verifying certificate..."
security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME" || {
    echo ""
    echo "Note: The certificate was created but may need manual trust settings."
    echo "1. Open Keychain Access"
    echo "2. Find '$CERT_NAME' in login keychain"
    echo "3. Double-click it, expand 'Trust', set 'Code Signing' to 'Always Trust'"
    echo ""
}

echo ""
echo "Done! You can now run ./scripts/build_app.sh and permissions will persist."
