#!/usr/bin/env bash
set -euo pipefail

cd "${APP_DIR}"

mkdir -p tmp/pids
rm -f tmp/pids/server.pid

bin/rails db:prepare
bin/rails runner 'DevTools.delete_all_indices_and_reindex_all' || echo "Warning: reindex failed, continuing..."

bin/generate_ssl_certificates

exec bin/dev
