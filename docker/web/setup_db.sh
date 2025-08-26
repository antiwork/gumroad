#!/bin/bash

set -e

cd $APP_DIR

echo "bundle exec rake db:drop"
bundle exec rake db:drop

echo "bundle exec rake db:create"
bundle exec rake db:create

echo "bundle exec rake db:schema:load"
bundle exec rake db:schema:load

echo "bundle exec rake db:migrate"
bundle exec rake db:migrate

echo "bundle exec rake db:seed"
bundle exec rake db:seed
