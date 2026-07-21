#!/bin/bash
set -eo pipefail

GREEN='\033[0;32m'
NC='\033[0m' # No Color
logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo -e "${GREEN}$DT docker_asset_compile.sh: $1${NC}"
}

logger "Uploading public/vite to S3"
aws s3 sync /app/public/vite s3://${ASSETS_S3_BUCKET}/vite --acl public-read --cache-control max-age=31536000,immutable
logger "Done uploading public/vite to S3"

logger "Uploading public/js to S3"
aws s3 sync /app/public/js s3://${ASSETS_S3_BUCKET}/js --acl public-read --cache-control max-age=300,public
logger "Done uploading public/js to S3"

logger "Uploading public/images to S3"
aws s3 sync /app/public/images s3://${ASSETS_S3_BUCKET}/images --acl public-read --cache-control max-age=300,public
logger "Done uploading public/images to S3"

# Fingerprinted Tailwind build for custom HTML pages (see
# scripts/build_pages_tailwind.mjs). Filenames carry a content hash, so they
# can be cached forever; sync never deletes, so hashes referenced by the
# previous deploy keep resolving during a rolling deploy.
logger "Uploading public/pages to S3"
aws s3 sync /app/public/pages s3://${ASSETS_S3_BUCKET}/pages --acl public-read --cache-control max-age=31536000,immutable

logger "Uploading public/fonts to S3"
aws s3 sync /app/public/fonts s3://${ASSETS_S3_BUCKET}/fonts --acl public-read --cache-control max-age=31536000,public
logger "Done uploading public/fonts to S3"
