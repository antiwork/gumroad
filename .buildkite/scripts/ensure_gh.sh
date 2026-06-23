#!/bin/bash
# Sourced as a library; does not change the caller's shell options.

GH_CLI_VERSION="2.65.0"

ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    return 0
  fi

  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_CLI_VERSION}/gh_${GH_CLI_VERSION}_linux_amd64.tar.gz" -o /tmp/gh.tar.gz
  tar -xzf /tmp/gh.tar.gz -C /tmp
  sudo mv "/tmp/gh_${GH_CLI_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh
  rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_CLI_VERSION}_linux_amd64"
}
