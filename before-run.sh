#!/bin/bash
set -e
export TEST_DATABASE_NAME=gumroad_test_astra2609 DISABLE_SPRING=1 OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES RAILS_ENV=test
export REDIS_HOST=localhost:17609/10 SIDEKIQ_REDIS_HOST=localhost:17609/11 RPUSH_REDIS_HOST=localhost:17609/12 RACK_ATTACK_REDIS_HOST=localhost:17609/13
bundle exec rake js:export > before-routes.log 2>&1
bundle exec vite build --mode test > before-build.log 2>&1
export SHOT_STAGE=before
SHOT_DEVICE=desktop SHOT_THEME=light bash capture-run.sh
SHOT_DEVICE=desktop SHOT_THEME=dark bash capture-run.sh
SHOT_DEVICE=mobile SHOT_THEME=light bash capture-run.sh
SHOT_DEVICE=mobile SHOT_THEME=dark bash capture-run.sh
