#!/bin/bash
set -e

GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") create_github_release.sh: $1${NC}"
}
warn() {
  echo -e "${YELLOW}$(date "+%Y/%m/%d %H:%M:%S") create_github_release.sh: WARNING: $1${NC}"
}

# gh infers the repo from the git remote; the REST fallback has to be told. Same
# default-and-override shape as PREVIEW_GITHUB_REPO in preview_gate.sh.
RELEASE_GITHUB_REPO="${RELEASE_GITHUB_REPO:-antiwork/gumroad}"
RELEASE_API_RESPONSE="/tmp/gh_release_api_response.json"

# The gh CLI is downloaded from github.com's release CDN, and the release is then created
# through github.com's API: when that CDN is having a burst, both used to go down with the
# step. On 2026-11-09 the CLI download failed on main (builds 28142 and 28143), and because
# this file is the last thing deploy_production.sh sources under `set -e`, the step exited
# 22 AFTER its deploy was already live: the commit was marked failed and every PR cut from
# main inherited the red. A missing CLI is therefore a warning that switches to the REST
# API, not an abort. The tag push below stays fatal — deploy_relevance.sh diffs against it.
gh_cli_available() {
  source .buildkite/scripts/ensure_gh.sh
  ensure_gh
}

# A commit subject is free text, so it has to survive JSON.
json_escape() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# The REST body for `gh release create`. gh asks GitHub for generated notes the same way:
# generate_release_notes makes the API write the notes between the two tags.
release_json() {
  local version_tag="$1" commit_sha="$2" previous_tag="$3" initial_title="$4"
  if [ -n "$previous_tag" ]; then
    printf '{"tag_name":"%s","target_commitish":"%s","generate_release_notes":true,"previous_tag_name":"%s"}' \
      "$(json_escape "$version_tag")" "$(json_escape "$commit_sha")" "$(json_escape "$previous_tag")"
  else
    printf '{"tag_name":"%s","target_commitish":"%s","name":"%s","body":"Initial release.\\n\\n* %s (%s)"}' \
      "$(json_escape "$version_tag")" "$(json_escape "$commit_sha")" "$(json_escape "$version_tag")" \
      "$(json_escape "$initial_title")" "$(json_escape "${commit_sha:0:12}")"
  fi
}

create_release_with_gh() {
  local version_tag="$1" commit_sha="$2" previous_tag="$3" initial_title="$4"
  if [ -n "$previous_tag" ]; then
    gh release create "$version_tag" --target "$commit_sha" --generate-notes --notes-start-tag "$previous_tag"
  else
    gh release create "$version_tag" --target "$commit_sha" \
      --notes "Initial release.

* ${initial_title} (${commit_sha:0:12})"
  fi
}

# The CLI-free transport: api.github.com is a different host from the release CDN the CLI
# download needs, so one of the two surviving is enough to create the release. Returns
# non-zero, with the API's own response in the log, when it cannot.
create_release_with_api() {
  local version_tag="$1" commit_sha="$2" previous_tag="$3" initial_title="$4"
  local http_code
  rm -f "$RELEASE_API_RESPONSE"
  http_code=$(release_json "$version_tag" "$commit_sha" "$previous_tag" "$initial_title" |
    curl -sS -o "$RELEASE_API_RESPONSE" -w '%{http_code}' -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      --data-binary @- \
      "https://api.github.com/repos/${RELEASE_GITHUB_REPO}/releases") || http_code="000"
  logger "REST API answered ${http_code} for ${version_tag}"
  case "$http_code" in
    # 201 created; 422 is "already_exists", which a re-run of the same commit hits.
    201|422) return 0 ;;
  esac
  if [ -s "$RELEASE_API_RESPONSE" ]; then
    cat "$RELEASE_API_RESPONSE"
    echo
  fi
  return 1
}

# Install the gh CLI if it is missing, through the shared helper, so the
# retry-hardened download lives in exactly one place. A download that still
# fails is not fatal here: the REST API can still create the release.
logger "Ensuring the gh CLI is available"
if gh_cli_available; then
  GH_READY=1
else
  GH_READY=0
  warn "the gh CLI could not be installed; creating the release over the REST API instead"
fi

# Requires GITHUB_TOKEN environment variable in Buildkite (PAT from gumroad-buildkite user)
if [ -z "$GITHUB_TOKEN" ]; then
  logger "Error: GITHUB_TOKEN is not set"
  exit 1
fi
export GH_TOKEN="$GITHUB_TOKEN"

COMMIT_SHA=${BUILDKITE_COMMIT}

# Determine calendar version tag (vYYYY.MM.DD.N)
TODAY=$(date -u +%Y.%m.%d)

# Fetch existing tags for today to determine sequence number
git fetch --tags --force > /dev/null 2>&1
EXISTING_TAGS=$(git tag -l "v${TODAY}.*" | sort -t. -k4 -n)

if [ -z "$EXISTING_TAGS" ]; then
  SEQUENCE=1
else
  LAST_SEQUENCE=$(echo "$EXISTING_TAGS" | tail -1 | rev | cut -d. -f1 | rev)
  SEQUENCE=$((LAST_SEQUENCE + 1))
fi

VERSION_TAG="v${TODAY}.${SEQUENCE}"

# Find the previous release tag for changelog range
PREVIOUS_TAG=$(git tag -l "v*.*.*.*" | sort -t. -k1,1 -k2,2n -k3,3n -k4,4n | tail -1)

logger "Creating GitHub Release ${VERSION_TAG} at commit ${COMMIT_SHA}"

# Create and push the git tag
git tag "$VERSION_TAG" "$COMMIT_SHA"
git push origin "$VERSION_TAG"

COMMIT_TITLE=""
if [ -z "$PREVIOUS_TAG" ]; then
  COMMIT_TITLE=$(git log -1 --pretty=format:'%s' "$COMMIT_SHA")
fi

# Create the GitHub Release: the gh CLI first, then the REST API.
RELEASE_CREATED=0
if [ "$GH_READY" = 1 ]; then
  if create_release_with_gh "$VERSION_TAG" "$COMMIT_SHA" "$PREVIOUS_TAG" "$COMMIT_TITLE"; then
    RELEASE_CREATED=1
    logger "GitHub Release ${VERSION_TAG} created with the gh CLI"
  else
    warn "gh release create failed; falling back to the REST API"
  fi
fi

if [ "$RELEASE_CREATED" = 0 ] &&
  create_release_with_api "$VERSION_TAG" "$COMMIT_SHA" "$PREVIOUS_TAG" "$COMMIT_TITLE"; then
  RELEASE_CREATED=1
  logger "GitHub Release ${VERSION_TAG} created over the REST API"
fi

if [ "$RELEASE_CREATED" = 1 ]; then
  logger "GitHub Release ${VERSION_TAG} created successfully"
else
  # Deliberately not fatal. The deploy this file follows has already shipped and switched
  # traffic, so failing here marked a live commit red and blocked every PR cut from main
  # (builds 28142/28143). The pushed tag still records what production runs, and the next
  # successful deploy creates its own release.
  warn "GitHub Release ${VERSION_TAG} was NOT created: the gh CLI download and the REST API both failed. The tag is pushed and production is live; re-run this step or create the release by hand."
  if command -v buildkite-agent >/dev/null 2>&1; then
    buildkite-agent annotate \
      "**GitHub Release \`${VERSION_TAG}\` was not created** — the gh CLI download and the GitHub REST API both failed for \`${COMMIT_SHA:0:12}\`. The tag is pushed and production is live, so the deploy is not failed; re-run this step or create the release by hand." \
      --style "warning" --context "release-not-created" 2>/dev/null || true
  fi
fi
