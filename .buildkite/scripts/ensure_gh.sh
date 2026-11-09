#!/bin/bash
# Sourced as a library; does not change the caller's shell options.

GH_CLI_VERSION="2.65.0"

# github.com's release CDN answers a burst of downloads with transient 5xx, and a retry
# budget has to outlast the BURST, not one bad answer. On 2026-11-09 main took a 504 for
# the whole ~25s of a `--retry 5 --retry-delay 5` window on builds 28142 and 28143: the
# download failed, the production deploy step exited 22 after its deploy had already
# shipped, the commit was marked failed, and every PR cut from main inherited the red.
# 12 retries 15s apart is a ~3 minute window, and --retry-max-time bounds the whole
# attempt at 5 minutes. --retry covers timeouts plus HTTP 408/429/500/502/503/504.
GH_CLI_RETRY=12
GH_CLI_RETRY_DELAY=15
GH_CLI_RETRY_MAX_TIME=300

ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    return 0
  fi

  # Each step returns non-zero on failure rather than leaving the caller to infer it from the
  # last command (rm succeeds even when nothing was installed). Callers decide what a missing
  # CLI means: preview_gate.sh already treats it as non-blocking, and create_github_release.sh
  # falls back to the REST API.
  curl -fsSL --retry "$GH_CLI_RETRY" --retry-delay "$GH_CLI_RETRY_DELAY" \
    --retry-max-time "$GH_CLI_RETRY_MAX_TIME" --retry-connrefused \
    "https://github.com/cli/cli/releases/download/v${GH_CLI_VERSION}/gh_${GH_CLI_VERSION}_linux_amd64.tar.gz" \
    -o /tmp/gh.tar.gz || return 1
  tar -xzf /tmp/gh.tar.gz -C /tmp || return 1
  sudo mv "/tmp/gh_${GH_CLI_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh || return 1
  rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_CLI_VERSION}_linux_amd64"
}
