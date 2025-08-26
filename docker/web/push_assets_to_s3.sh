#!/bin/bash

GREEN='\033[0;32m'
NC='\033[0m' # No Color
logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo -e "${GREEN}$DT docker_asset_compile.sh: $1${NC}"
}

logger "Uploading public/assets to S3"
aws s3 sync /app/public/assets s3://${ASSETS_S3_BUCKET}/assets --acl public-read --cache-control max-age=31536000,immutable
logger "Done uploading public/assets to S3"

logger "Uploading public/packs to S3"
aws s3 sync /app/public/packs s3://${ASSETS_S3_BUCKET}/packs --acl public-read --cache-control max-age=31536000,immutable
logger "Done uploading public/packs to S3"
