#!/bin/bash
set -e

# Generate SSL certificates if needed
if [ "$GENERATE_CERTIFICATES" = "true" ]; then
  echo "Checking SSL certificates..."
  if [ ! -f "/certs/gumroad_dev.crt" ] || [ ! -f "/certs/gumroad_dev.key" ]; then
    echo "Generating self-signed SSL certificates..."
    /docker/dev/generate_certificates.sh
  else
    echo "SSL certificates already exist, skipping generation"
  fi
fi

# Wait for database if needed
if [ -n "$DATABASE_HOST" ]; then
  echo "Waiting for database at $DATABASE_HOST:3306..."
  until nc -z "$DATABASE_HOST" 3306 2>/dev/null; do
    echo "Database not ready, waiting..."
    sleep 1
  done
  echo "Database is ready"
fi

# Run database setup if needed
if [ "$RUN_DB_SETUP" = "true" ]; then
  echo "Setting up database..."
  bundle exec rails db:prepare
fi

# Execute main command
exec "$@"

