#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") copy_secrets.sh: $1${NC}"
}

copy_secrets() {
  if [ -z "$CREDENTIALS_REPO" ]; then
    logger "Error: CREDENTIALS_REPO environment variable is not set"
    return 1
  fi

  if ! command -v git-lfs >/dev/null 2>&1; then
    logger "Error: git-lfs is not installed. The deployment repo stores *.mmdb files (e.g. lib/GeoIP2-City.mmdb) via Git LFS; install git-lfs on the agent."
    return 1
  fi

  logger "Cloning deployment repo with secrets"
  CREDENTIALS_TMP_DIR="/tmp/gumroad-deployment-credentials"
  rm -rf "$CREDENTIALS_TMP_DIR"
  git clone --depth 1 $CREDENTIALS_REPO "$CREDENTIALS_TMP_DIR"

  logger "Fetching Git LFS objects"
  git -C "$CREDENTIALS_TMP_DIR" lfs install --local
  git -C "$CREDENTIALS_TMP_DIR" lfs pull

  local app_dir=$(pwd)

  logger "Copying files"
  cd "$CREDENTIALS_TMP_DIR"

  files_to_remove=(".git" ".gitattributes" ".gitignore" "README.md" "copy_into" "docs")
  for file in "${files_to_remove[@]}"; do
    rm -rf "$file"
  done

  find . -type f | while read -r src_path; do
    dest_path="${app_dir}/${src_path}"
    dest_dir=$(dirname "$dest_path")

    if [ ! -d "$dest_dir" ]; then
      sudo mkdir -p "$dest_dir"
      sudo chown buildkite-agent:buildkite-agent "$dest_dir"
    fi

    sudo cp "$src_path" "$dest_path"
    sudo chown buildkite-agent:buildkite-agent "$dest_path"
  done
  rm -rf "$CREDENTIALS_TMP_DIR"
  cd "$app_dir"

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
