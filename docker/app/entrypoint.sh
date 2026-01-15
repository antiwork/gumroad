#!/bin/bash
set -e

echo "🚀 Starting Gumroad setup..."

# Wait for database to be ready
echo "⏳ Waiting for database..."
until bundle exec rails db:version > /dev/null 2>&1; do
  sleep 2
done

# Prepare database
echo "📦 Setting up database..."
bundle exec rails db:prepare

# Reindex Elasticsearch if needed
if bundle exec rails runner "puts Elasticsearch::Model.client.ping" 2>/dev/null; then
  echo "🔍 Reindexing Elasticsearch..."
  bundle exec rails searchkick:reindex:all || true
fi

# Generate SSL certificates if needed
if [ ! -f "tmp/ssl/gumroad.dev.crt" ]; then
  echo "🔐 Generating SSL certificates..."
  mkdir -p tmp/ssl
  docker/local-nginx/generate_dev_certs.sh || true
fi

echo "✅ Setup complete! Starting server..."

# Start the server
exec bundle exec rails server -b 0.0.0.0 -p 3000
