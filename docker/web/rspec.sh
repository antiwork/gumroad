#!/bin/bash

set -e

GREEN='\033[0;32m'
NC='\033[0m' # No Color
logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo -e "${GREEN}$DT rspec.sh: $1${NC}"
}

cd $APP_DIR
mkdir -p tmp

[[ -e /mnt/host/$CACHE_TAR_FILE ]] && tar -xf /mnt/host/$CACHE_TAR_FILE -C .

if [ "$QUEUED_MODE" = true ]; then
  logger "Running QUEUED_MODE"
  /usr/local/bin/gosu app bundle exec rake "knapsack_pro:queue:rspec[--format progress --format RspecJunitFormatter --out 'tmp/test-results/rspec_final_results_${BUILDKITE_PARALLEL_JOB}.xml']"
else
  logger "Running REGULAR_MODE"
  /usr/local/bin/gosu app bundle exec rake "knapsack_pro:rspec[--format progress --format RspecJunitFormatter --out tmp/test-results/rspec.xml]"
fi

test_result=$?

exit $test_result
