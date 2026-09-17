#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") copy_secrets.sh: $1${NC}"
}

# Everything this script is allowed to copy into the app, relative to the credentials tree.
# This is a manifest, not a filter: the credentials repo is now a monorepo that also carries
# Terraform, infrastructure config and internal company records, and none of that belongs in
# a deploy. Copying the tree and subtracting known names got that backwards — anything added
# upstream landed here by default. Adding a path upstream now means adding it here too.
CREDENTIALS_PATHS=(
  "config/credentials.yml.enc"
  "config/credentials"
  "config/certs"
  "lib/GeoIP2-City.mmdb"
  "nomad"
)

copy_secrets() {
  if [ -z "$CREDENTIALS_REPO" ]; then
    logger "Error: CREDENTIALS_REPO environment variable is not set"
    return 1
  fi

  if ! command -v git-lfs >/dev/null 2>&1; then
    logger "Error: git-lfs is not installed. The credentials repo stores *.mmdb files (e.g. lib/GeoIP2-City.mmdb) via Git LFS; install git-lfs on the agent."
    return 1
  fi

  logger "Cloning credentials repo"
  CREDENTIALS_TMP_DIR="/tmp/gumroad-credentials"
  rm -rf "$CREDENTIALS_TMP_DIR"
  # Sparse so the monorepo's unrelated trees are never written to the agent's disk. The
  # patterns cover both layouts below; the one that does not match is simply absent.
  git clone --depth 1 --sparse $CREDENTIALS_REPO "$CREDENTIALS_TMP_DIR"
  git -C "$CREDENTIALS_TMP_DIR" sparse-checkout set deployment config lib nomad

  logger "Fetching Git LFS objects"
  git -C "$CREDENTIALS_TMP_DIR" lfs install --local
  git -C "$CREDENTIALS_TMP_DIR" lfs pull

  local app_dir=$(pwd)

  # These files moved into the gumroad-private monorepo under deployment/. Accepting both
  # layouts keeps this script and the CREDENTIALS_REPO setting independently changeable, so
  # neither change has to be timed against the other.
  local src_root="$CREDENTIALS_TMP_DIR"
  if [ -d "$CREDENTIALS_TMP_DIR/deployment" ]; then
    src_root="$CREDENTIALS_TMP_DIR/deployment"
    logger "Using the monorepo layout (deployment/)"
  else
    logger "Using the standalone layout"
  fi

  local rel
  for rel in "${CREDENTIALS_PATHS[@]}"; do
    if [ ! -e "$src_root/$rel" ]; then
      logger "Error: $rel is missing from the credentials repo. Refusing to deploy without it."
      return 1
    fi
  done

  logger "Copying files"
  cd "$src_root"

  for rel in "${CREDENTIALS_PATHS[@]}"; do
    find "$rel" -type f | while read -r src_path; do
      dest_path="${app_dir}/${src_path}"
      dest_dir=$(dirname "$dest_path")

      if [ ! -d "$dest_dir" ]; then
        sudo mkdir -p "$dest_dir"
        sudo chown buildkite-agent:buildkite-agent "$dest_dir"
      fi

      sudo cp "$src_path" "$dest_path"
      sudo chown buildkite-agent:buildkite-agent "$dest_path"
    done
  done

  cd "$app_dir"
  rm -rf "$CREDENTIALS_TMP_DIR"

  logger "Verifying Git LFS files resolved"
  while IFS= read -r -d '' mmdb; do
    if head -c 64 "$mmdb" | grep -q "git-lfs"; then
      logger "Error: $mmdb is a Git LFS pointer, not the real file. LFS objects were not fetched."
      return 1
    fi
  done < <(find "$app_dir/lib" -name '*.mmdb' -print0)

  logger "Secrets copied successfully"
  return 0
}
