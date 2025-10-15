#!/bin/sh
set -eu

echo "Checking if mkcert is installed..."
if ! command -v mkcert >/dev/null 2>&1; then
  echo "mkcert not found, installing..."
  apt-get update -qq
  apt-get install -y --no-install-recommends wget ca-certificates
  export MKCERT_VERSION=1.4.4
  wget -qO /usr/local/bin/mkcert "https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/mkcert-v${MKCERT_VERSION}-linux-amd64"
  chmod +x /usr/local/bin/mkcert
  apt-get clean
  rm -rf /var/lib/apt/lists/*
fi

CERT_DIR="/etc/ssl/certs"
CRT_FILE="$CERT_DIR/gumroad_dev.crt"
KEY_FILE="$CERT_DIR/gumroad_dev.key"

if [ -f "$CRT_FILE" ] && [ -f "$KEY_FILE" ]; then
  echo "Development certificates already exist."
  exit 0
fi

echo "Generating certificates for gumroad.dev..."
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

mkcert -install
mkcert gumroad.dev "*.gumroad.dev"

mv "gumroad.dev+1.pem" "gumroad_dev.crt"
mv "gumroad.dev+1-key.pem" "gumroad_dev.key"

chmod 600 "gumroad_dev.key"
chmod 644 "gumroad_dev.crt"

echo "Generated development certificates at:"
echo "  $CERT_DIR/gumroad_dev.crt"
echo "  $CERT_DIR/gumroad_dev.key"