#!/bin/bash
# Sourced as a library; does not change the caller's shell options.

PREVIEW_GITHUB_REPO="${PREVIEW_GITHUB_REPO:-antiwork/gumroad}"

source .buildkite/scripts/ensure_gh.sh

create_github_deployment() {
  local ref="$1"
  local environment="$2"

  export GH_TOKEN="${GITHUB_TOKEN:-}"
  [ -z "$GH_TOKEN" ] && return 0
  ensure_gh

  gh api --method POST "repos/${PREVIEW_GITHUB_REPO}/deployments" --input - <<JSON | jq -r '.id // empty'
{
  "ref": "${ref}",
  "environment": "${environment}",
  "description": "Preview app",
  "auto_merge": false,
  "transient_environment": true,
  "production_environment": false,
  "required_contexts": []
}
JSON
}

set_github_deployment_status() {
  local deployment_id="$1"
  local state="$2"
  local environment_url="${3:-}"

  [ -z "$deployment_id" ] && return 0
  export GH_TOKEN="${GITHUB_TOKEN:-}"
  [ -z "$GH_TOKEN" ] && return 0
  ensure_gh

  local args=(--method POST "repos/${PREVIEW_GITHUB_REPO}/deployments/${deployment_id}/statuses"
    -f "state=${state}"
    -f "log_url=${BUILDKITE_BUILD_URL:-}")
  if [ -n "$environment_url" ]; then
    args+=(-f "environment_url=${environment_url}")
  fi

  gh api "${args[@]}" >/dev/null
}
