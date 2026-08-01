#!/usr/bin/env bash
# Captures the spring fork evidence for #6747: two concurrent test commands from ONE
# spring server, which is the case the pre-merge review flagged. Before the per-fork
# re-lease they inherited the server's single block and flushed each other.
set -u
cd "$(dirname "$0")/.."

export PATH="$HOME/.rbenv/shims:$PATH"
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
export TEST_DATABASE_NAME="${TEST_DATABASE_NAME:-gumroad_test_redisiso}"
export RAILS_ENV=test
PORT="${REDIS_PORT:-6399}"
export REDIS_HOST="localhost:$PORT/10" SIDEKIQ_REDIS_HOST="localhost:$PORT/11"
export RPUSH_REDIS_HOST="localhost:$PORT/12" RACK_ATTACK_REDIS_HOST="localhost:$PORT/13"

bin/spring stop >/dev/null 2>&1 || true
REGISTRY=$(( $(redis-cli -p "$PORT" config get databases | tail -1) - 1 ))
redis-cli -p "$PORT" -n "$REGISTRY" --scan --pattern 'gumroad:test-redis-slot:*' 2>/dev/null \
  | while read -r k; do redis-cli -p "$PORT" -n "$REGISTRY" del "$k" >/dev/null; done

# Report every store, and hold each command open so the two genuinely overlap.
SCRIPT='puts "  app=#{$redis.connection.fetch(:db)} sidekiq=#{Sidekiq.redis { |c| c.config.db }} rack_attack=#{ENV["RACK_ATTACK_REDIS_HOST"].split("/").last}"; sleep 20'

echo "Two concurrent commands from ONE spring server (bin/rails goes through bin/spring):"
bundle exec bin/rails runner "$SCRIPT" 2>&1 | grep -E "^  app=|test-redis-isolation" &
A=$!
sleep 14
bundle exec bin/rails runner "$SCRIPT" 2>&1 | grep -E "^  app=|test-redis-isolation"
wait $A
