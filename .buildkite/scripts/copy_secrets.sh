#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
copy_secrets_logger() {
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
    copy_secrets_logger "Error: CREDENTIALS_REPO environment variable is not set"
    return 1
  fi

  if ! command -v git-lfs >/dev/null 2>&1; then
    copy_secrets_logger "Error: git-lfs is not installed. The credentials repo stores *.mmdb files (e.g. lib/GeoIP2-City.mmdb) via Git LFS; install git-lfs on the agent."
    return 1
  fi

  copy_secrets_logger "Cloning credentials repo"
  CREDENTIALS_TMP_DIR="/tmp/gumroad-credentials"
  rm -rf "$CREDENTIALS_TMP_DIR"
  # Sparse so the monorepo's unrelated trees are never written to the agent's disk. The
  # patterns cover both layouts below; the one that does not match is simply absent.
  git clone --depth 1 --sparse $CREDENTIALS_REPO "$CREDENTIALS_TMP_DIR"
  git -C "$CREDENTIALS_TMP_DIR" sparse-checkout set deployment config lib nomad

  copy_secrets_logger "Fetching Git LFS objects"
  git -C "$CREDENTIALS_TMP_DIR" lfs install --local
  git -C "$CREDENTIALS_TMP_DIR" lfs pull

  local app_dir=$(pwd)

  # These files moved into the gumroad-private monorepo under deployment/. Accepting both
  # layouts keeps this script and the CREDENTIALS_REPO setting independently changeable, so
  # neither change has to be timed against the other.
  local src_root="$CREDENTIALS_TMP_DIR"
  if [ -d "$CREDENTIALS_TMP_DIR/deployment" ]; then
    src_root="$CREDENTIALS_TMP_DIR/deployment"
    copy_secrets_logger "Using the monorepo layout (deployment/)"
  else
    copy_secrets_logger "Using the standalone layout"
  fi

  local rel
  for rel in "${CREDENTIALS_PATHS[@]}"; do
    if [ ! -e "$src_root/$rel" ]; then
      copy_secrets_logger "Error: $rel is missing from the credentials repo. Refusing to deploy without it."
      return 1
    fi
  done

  copy_secrets_logger "Copying files"
  cd "$src_root"

  # Each sudo call costs the agent noticeable time, so the copy takes four calls in total
  # instead of up to four per file. Ownership matches the per-file version: each file and
  # each directory that held a file and did not exist yet belong to buildkite-agent.
  local -a src_paths=() dest_paths=() new_dirs=()
  local -A seen_dirs=()
  local src_path dest_dir dir
  for rel in "${CREDENTIALS_PATHS[@]}"; do
    while read -r src_path; do
      src_paths+=("$src_path")
      dest_paths+=("${app_dir}/${src_path}")
      dest_dir=$(dirname "${app_dir}/${src_path}")
      if [ -z "${seen_dirs[$dest_dir]:-}" ] && [ ! -d "$dest_dir" ]; then
        new_dirs+=("$dest_dir")
      fi
      dir=$dest_dir
      while [ -z "${seen_dirs[$dir]:-}" ] && [ "$dir" != "/" ]; do
        seen_dirs[$dir]=1
        dir=$(dirname "$dir")
      done
    done < <(find "$rel" -type f)
  done

  if [ ${#new_dirs[@]} -gt 0 ]; then
    sudo mkdir -p "${new_dirs[@]}"
    sudo chown buildkite-agent:buildkite-agent "${new_dirs[@]}"
  fi
  if [ ${#src_paths[@]} -gt 0 ]; then
    sudo cp --parents "${src_paths[@]}" "$app_dir"
    sudo chown buildkite-agent:buildkite-agent "${dest_paths[@]}"
  fi

  cd "$app_dir"
  rm -rf "$CREDENTIALS_TMP_DIR"

  copy_secrets_logger "Verifying Git LFS files resolved"
  while IFS= read -r -d '' mmdb; do
    if head -c 64 "$mmdb" | grep -q "git-lfs"; then
      copy_secrets_logger "Error: $mmdb is a Git LFS pointer, not the real file. LFS objects were not fetched."
      return 1
    fi
  done < <(find "$app_dir/lib" -name '*.mmdb' -print0)

  copy_secrets_logger "Secrets copied successfully"
  return 0
}
