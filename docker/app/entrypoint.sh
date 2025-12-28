#!/usr/bin/env bash
set -eo pipefail

cd "${APP_DIR}"

# Clean up stale pid file (only matters for web, harmless for others)
rm -f tmp/pids/server.pid

# Set SSL certificate environment variables
# (cert file created by init container, env vars must be set per-container)
export SSL_CERT_FILE="${APP_DIR}/tmp/combined_ca_certs.pem"
export NODE_EXTRA_CA_CERTS="${APP_DIR}/tmp/mkcert_ca.pem"

# Run the container command
exec "$@"
