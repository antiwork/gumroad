#!/bin/bash

set -e

MIGRATION_LOCK_KEY=${RAILS_ENV}-migration-lock
MIGRATION_LOCK_INDEX=${RAILS_ENV}-migration-lock-index

GREEN='\033[0;32m'
NC='\033[0m' # No Color
logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo -e "${GREEN}$DT $(basename "$0"): $1${NC}"
}

consul_put() {
  curl \
    --silent \
    --request PUT \
    --data $2 \
    http://localhost:8500/v1/kv/$1 > /dev/null
}

wait_for_migration_unlock() {
  lock_index=$(curl -s http://localhost:8500/v1/kv/$MIGRATION_LOCK_INDEX | jq -r ".[0].Value" | base64 -d)

  # Blocking query
  curl -s http://localhost:8500/v1/kv/${MIGRATION_LOCK_KEY}?index=$lock_index > /dev/null
}

set_migration_lock() {
  consul_put $MIGRATION_LOCK_KEY "locked_by_$(cat revision)"

  # Set MIGRATION_LOCK_INDEX to the index of MIGRATION_LOCK_KEY to enable the lock
  lock_index=$(curl -s http://localhost:8500/v1/kv/$MIGRATION_LOCK_KEY | jq ".[0].ModifyIndex")
  consul_put $MIGRATION_LOCK_INDEX $lock_index
}

unlock_migration () {
  consul_put $MIGRATION_LOCK_KEY "unlocked_by_$(cat revision)"
}

cd $APP_DIR

wait_for_migration_unlock
set_migration_lock

echo "bundle exec rake db:migrate"
bundle exec rake db:migrate

if [ $? -eq 0 ]; then
  schema_version=$(bundle exec rails runner "puts ActiveRecord::Migrator.current_version" | tail -n1)
  consul_put "database_version_${RAILS_ENV}-$(cat revision)" $schema_version
fi

unlock_migration
