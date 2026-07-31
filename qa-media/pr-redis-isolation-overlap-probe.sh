#!/usr/bin/env bash
# Runs qa-media/pr-redis-isolation-overlap-probe.rb as the two-process pair it needs.
# Occupies slot 0 first, so the leased writer lands on a later slot — the pre-fix
# arithmetic put those on top of the .env.test databases the fallback run flushes.
set -u
cd "$(dirname "$0")/.."

export PATH="$HOME/.rbenv/shims:$PATH"
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
export TEST_DATABASE_NAME="${TEST_DATABASE_NAME:-gumroad_test_redisiso}"
export RAILS_ENV=test
PORT="${REDIS_PORT:-6399}"
export REDIS_HOST="localhost:$PORT/10"
export SIDEKIQ_REDIS_HOST="localhost:$PORT/11"
export RPUSH_REDIS_HOST="localhost:$PORT/12"
export RACK_ATTACK_REDIS_HOST="localhost:$PORT/13"
export BARRIER_DB=62

REGISTRY=$(( $(redis-cli -p "$PORT" config get databases | tail -1) - 1 ))
redis-cli -p "$PORT" -n "$REGISTRY" set "gumroad:test-redis-slot:0" "held-by-probe" EX 300 >/dev/null
echo "slot 0 held by the probe, so the writer leases a later block"

RUN="overlap-$$"
RUN_ID="$RUN" ROLE=writer bundle exec ruby qa-media/pr-redis-isolation-overlap-probe.rb 2>/dev/null | grep writer &
WRITER=$!
RUN_ID="$RUN" ROLE=flusher DISABLE_TEST_REDIS_ISOLATION=1 \
  bundle exec ruby qa-media/pr-redis-isolation-overlap-probe.rb 2>/dev/null | grep flusher
wait $WRITER

redis-cli -p "$PORT" -n "$REGISTRY" del "gumroad:test-redis-slot:0" >/dev/null
