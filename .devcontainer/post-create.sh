#!/usr/bin/env bash
set -euo pipefail

# Install bundler and project gems (without production/staging)
if ! command -v bundler >/dev/null 2>&1; then
  gem install bundler
fi
bundle config --local without production staging || true
bundle install

# Install JS deps
npm install

# Show quick tips
cat <<'EOT'
Dev container ready.
- Start services on your host (or within a separate terminal) with: make local
- Prepare DB: bin/rails db:prepare
- Start app: bin/dev
EOT

