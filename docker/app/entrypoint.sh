#!/usr/bin/env bash
set -eo pipefail

cd "${APP_DIR}"

# Clean up stale pid file (only matters for web, harmless for others)
rm -f tmp/pids/server.pid

# Ensure tmp directory exists
mkdir -p tmp/pids

# Determine which mkcert CA directory is available (macOS vs Linux host)
MKCERT_CA_DIR=""
if [ -f "/mkcert-ca-macos/rootCA.pem" ]; then
  MKCERT_CA_DIR="/mkcert-ca-macos"
elif [ -f "/mkcert-ca-linux/rootCA.pem" ]; then
  MKCERT_CA_DIR="/mkcert-ca-linux"
fi

# Generate SSL certificates using host's mkcert CA
SHARED_SSL_CERTS="/shared-ssl-certs"
if [ -d "$SHARED_SSL_CERTS" ] && [ -n "$MKCERT_CA_DIR" ]; then
  # Set CAROOT to use host's CA (mkcert will use this to sign certs)
  export CAROOT="$MKCERT_CA_DIR"
  
  # Generate certs if they don't exist in shared volume
  if [ ! -f "$SHARED_SSL_CERTS/gumroad_dev.crt" ]; then
    echo "Generating SSL certificates using host's mkcert CA..."
    cd "$SHARED_SSL_CERTS"
    
    mkcert gumroad.dev "*.gumroad.dev"
    mv gumroad.dev+1.pem gumroad_dev.crt
    mv gumroad.dev+1-key.pem gumroad_dev.key
    
    mkcert helperai.dev "*.helperai.dev"
    mv helperai.dev+1.pem helperai_dev.crt
    mv helperai.dev+1-key.pem helperai_dev.key
    
    echo "SSL certificates generated successfully"
    cd "${APP_DIR}"
  fi
  
  # Copy rootCA to shared volume for combining with system CAs
  cp "$MKCERT_CA_DIR/rootCA.pem" "$SHARED_SSL_CERTS/mkcert_rootCA.pem" 2>/dev/null || true
fi

# Certificate locations
SYSTEM_CA_FILE="/etc/ssl/certs/ca-certificates.crt"
MKCERT_ROOT_CA="$SHARED_SSL_CERTS/mkcert_rootCA.pem"
COMBINED_CERT_FILE="${APP_DIR}/tmp/combined_ca_certs.pem"

# Combine system CAs with mkcert CA at runtime
if [ -f "$SYSTEM_CA_FILE" ] && [ -f "$MKCERT_ROOT_CA" ]; then
  cat "$SYSTEM_CA_FILE" "$MKCERT_ROOT_CA" > "$COMBINED_CERT_FILE"
else
  echo "Warning: Could not create combined cert file."
  if [ -f "$SYSTEM_CA_FILE" ]; then
    cp "$SYSTEM_CA_FILE" "$COMBINED_CERT_FILE"
  fi
fi

# Set SSL certificate environment variables
export SSL_CERT_FILE="$COMBINED_CERT_FILE"
export NODE_EXTRA_CA_CERTS="$MKCERT_ROOT_CA"

# Run the container command
exec "$@"
