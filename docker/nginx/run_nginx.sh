#!/bin/bash

set -e

consul-template \
  -template "/nginx.conf:/etc/nginx/conf.d/default.conf" \
  -exec "nginx -g 'daemon off;'"
