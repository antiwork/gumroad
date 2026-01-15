#!/bin/bash

# Generate self-signed SSL certificates for local development
# This script generates certificates for gumroad.dev

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssl"
mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/gumroad.dev.crt" ] && [ -f "$CERT_DIR/gumroad.dev.key" ]; then
    echo "✅ SSL certificates already exist"
    exit 0
fi

echo "🔐 Generating SSL certificates for gumroad.dev..."

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$CERT_DIR/gumroad.dev.key" \
    -out "$CERT_DIR/gumroad.dev.crt" \
    -subj "/C=US/ST=CA/L=San Francisco/O=Gumroad/CN=gumroad.dev" \
    -addext "subjectAltName=DNS:gumroad.dev,DNS:*.gumroad.dev,DNS:localhost"

echo "✅ SSL certificates generated successfully!"
echo "📍 Certificates location: $CERT_DIR"
echo ""
echo "⚠️  To trust these certificates on your system:"
echo "   - macOS: Add gumroad.dev.crt to Keychain Access and trust it"
echo "   - Linux: Copy to /usr/local/share/ca-certificates/ and run update-ca-certificates"
echo "   - Windows: Double-click gumroad.dev.crt and install in Trusted Root Certification Authorities"
