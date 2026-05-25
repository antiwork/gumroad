#!/usr/bin/env bash
set -euo pipefail

cd "${APP_DIR:-/app}"

export PORT="${PORT:-3310}"
export PUPPETEER_SKIP_DOWNLOAD="${PUPPETEER_SKIP_DOWNLOAD:-true}"

rm -f tmp/pids/server.pid

bundle check || bundle install
bundle exec rails db:prepare
bundle exec rails runner 'load Rails.root.join("db/seeds/020_development_staging/gumroad_posts.rb") unless User.exists?(username: "gumroad")'

npm install
bundle exec rails js:export
npm run build || test -f public/packs/manifest.json

bundle exec rails runner 'DevTools.delete_all_indices_and_reindex_all'

exec bundle exec rails server -b 0.0.0.0 -p "$PORT"
