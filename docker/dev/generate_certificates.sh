#!/bin/bash
set -e

CERT_DIR="/certs"

generate_cert() {
  local domain=$1
  local cert_file="${CERT_DIR}/${domain//\*/wildcard}_dev.crt"
  local key_file="${CERT_DIR}/${domain//\*/wildcard}_dev.key"

  # Skip if certificate already exists
  if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
    echo "Certificate for $domain already exists, skipping..."
    return 0
  fi

  echo "Generating self-signed certificate for $domain..."

  # Generate private key
  openssl genrsa -out "$key_file" 2048

  # Create openssl config for SAN
  local san_config="/tmp/san_${domain//\*/wildcard}.conf"
  cat > "$san_config" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $domain
O = Gumroad Development
C = US

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $domain
EOF

  # Add additional DNS entries for wildcard domains
  if [[ "$domain" == *"*"* ]]; then
    echo "DNS.2 = gumroad.dev" >> "$san_config"
    echo "DNS.3 = helperai.dev" >> "$san_config"
    echo "DNS.4 = *.gumroad.dev" >> "$san_config"
    echo "DNS.5 = *.helperai.dev" >> "$san_config"
  fi

  # Generate certificate signing request and self-signed certificate
  openssl req -new -key "$key_file" -out /tmp/cert.csr -config "$san_config"

  # Generate self-signed certificate (valid for 1 year)
  openssl x509 -req -days 365 -in /tmp/cert.csr -signkey "$key_file" -out "$cert_file" \
    -extensions v3_req -extfile "$san_config"

  rm -f /tmp/cert.csr "$san_config"
  chmod 644 "$cert_file"
  chmod 600 "$key_file"
  echo "Certificate for $domain generated successfully"
}

# Create cert directory if it doesn't exist
mkdir -p "$CERT_DIR"

# Generate certificates for gumroad.dev domains
generate_cert "gumroad.dev"
generate_cert "*.gumroad.dev"

# Generate certificates for helperai.dev domains
generate_cert "helperai.dev"
generate_cert "*.helperai.dev"

# Create symlinks for nginx (gumroad_dev.crt/key)
if [ ! -f "${CERT_DIR}/gumroad_dev.crt" ]; then
  ln -sf "${CERT_DIR}/gumroad.dev_dev.crt" "${CERT_DIR}/gumroad_dev.crt"
  ln -sf "${CERT_DIR}/gumroad.dev_dev.key" "${CERT_DIR}/gumroad_dev.key"
fi

if [ ! -f "${CERT_DIR}/helperai_dev.crt" ]; then
  ln -sf "${CERT_DIR}/helperai.dev_dev.crt" "${CERT_DIR}/helperai_dev.crt"
  ln -sf "${CERT_DIR}/helperai.dev_dev.key" "${CERT_DIR}/helperai_dev.key"
fi

echo "All certificates generated successfully in $CERT_DIR"

