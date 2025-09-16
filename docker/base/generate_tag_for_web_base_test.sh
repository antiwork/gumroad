#!/bin/bash

set -e

WEB_BASE_DOCKERFILE_FROM=${WEB_BASE_DOCKERFILE_FROM:-"ruby:$(cat .ruby-version)-slim-bullseye"}
DOCKER_CMD=${DOCKER_CMD:-docker}

dockerfile_from_shas=$($DOCKER_CMD history -q $WEB_BASE_DOCKERFILE_FROM \
  | sed 's/^.*missing.*//' \
  | tr '\n' ' ')

gemfiles_sha=$(sha1sum Gemfile* | tr '\n' ',' | sha1sum | cut -d " " -f1)

if [ -f Dockerfile.test ]; then
  dockerfile_sha=$(sha1sum Dockerfile.test | cut -d " " -f1)
else
  dockerfile_sha=$(sha1sum docker/base/Dockerfile.test | cut -d " " -f1)
fi

echo $dockerfile_from_shas $dockerfile_sha $gemfiles_sha\
  | sha1sum | cut -d " " -f1
