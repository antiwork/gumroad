#!/bin/bash
set -e
export TEST_DATABASE_NAME=gumroad_test_astra2609 DISABLE_SPRING=1 OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES RAILS_ENV=test
export REDIS_HOST=localhost:17609/10 SIDEKIQ_REDIS_HOST=localhost:17609/11 RPUSH_REDIS_HOST=localhost:17609/12 RACK_ATTACK_REDIS_HOST=localhost:17609/13
export SHOT_DIR=/tmp/wt_2609_astra_20260915/evidence
export SHOT_STAGE=${SHOT_STAGE:-after} SHOT_DEVICE=${SHOT_DEVICE:-desktop} SHOT_THEME=${SHOT_THEME:-light}
bundle exec rspec spec/requests/settings/astra_2609_capture_spec.rb > "capture-${SHOT_STAGE}-${SHOT_DEVICE}-${SHOT_THEME}.log" 2>&1
