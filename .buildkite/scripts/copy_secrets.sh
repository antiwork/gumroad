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

  logger "Cloning deployment repo with secrets"
  CREDENTIALS_TMP_DIR="/tmp/gumroad-deployment-credentials"
  rm -rf "$CREDENTIALS_TMP_DIR"
  git clone --depth 1 $CREDENTIALS_REPO "$CREDENTIALS_TMP_DIR"
  local app_dir=$(pwd)

  logger "Copying files"
  cd "$CREDENTIALS_TMP_DIR"

  files_to_remove=(".git" ".gitignore" "README.md" "copy_into" "docs")
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

  logger "Secrets copied successfully"
  return 0
}
