#!/bin/bash

set -e

cd $APP_DIR

export REVISION=$(cat revision)

echo "Notifying Bugsnag"
bundle exec rake bugsnag:deployments
