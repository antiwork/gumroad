#!/bin/bash
# Sourced as a library; does not change the caller's shell options.

GH_CLI_VERSION="2.65.0"

ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    return 0
  fi

  # github.com's release CDN answers a burst of downloads with transient 5xx, and
  # a 504 here aborted the production deploy step after the deploy had already
  # shipped, which marked main red. `curl --retry` covers timeouts plus HTTP
  # 408/429/500/502/503/504, so one bad answer no longer fails the build.
  curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused \
    "https://github.com/cli/cli/releases/download/v${GH_CLI_VERSION}/gh_${GH_CLI_VERSION}_linux_amd64.tar.gz" \
    -o /tmp/gh.tar.gz
  tar -xzf /tmp/gh.tar.gz -C /tmp
  sudo mv "/tmp/gh_${GH_CLI_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh
  rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_CLI_VERSION}_linux_amd64"
}
