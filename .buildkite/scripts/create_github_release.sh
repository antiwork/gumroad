#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") create_github_release.sh: $1${NC}"
}

# Install gh CLI if not present
if ! command -v gh &> /dev/null; then
  logger "Installing gh CLI"
  GH_VERSION="2.65.0"
  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" -o /tmp/gh.tar.gz
  tar -xzf /tmp/gh.tar.gz -C /tmp
  sudo mv "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh
  rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"
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

# Create the GitHub Release
if [ -n "$PREVIOUS_TAG" ]; then
  logger "Generating changelog from ${PREVIOUS_TAG} to ${VERSION_TAG}"
  gh release create "$VERSION_TAG" --target "$COMMIT_SHA" --generate-notes --notes-start-tag "$PREVIOUS_TAG"
else
  logger "No previous release found, creating initial release for commit ${COMMIT_SHA}"
  COMMIT_TITLE=$(git log -1 --pretty=format:'%s' "$COMMIT_SHA")
  gh release create "$VERSION_TAG" --target "$COMMIT_SHA" --notes "Initial release.

* ${COMMIT_TITLE} (${COMMIT_SHA:0:12})"
fi

logger "GitHub Release ${VERSION_TAG} created successfully"
