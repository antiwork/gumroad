# shellcheck shell=bash
# Shared helpers for BuildKit registry caching on Buildkite image builds.
# Meant to be sourced, not executed.
#
# The classic `docker build` builder can only reuse layers that are already in
# the local daemon, so a fresh (or pruned) agent rebuilds everything from
# scratch. BuildKit's registry cache (--cache-from/--cache-to type=registry)
# persists the layer cache in ECR next to the images themselves, so any agent
# gets cache hits regardless of local state.
#
# Exporting a registry cache requires a docker-container BuildKit builder —
# the default `docker` driver cannot `--cache-to type=registry`. If buildx or
# the container builder is unavailable on the agent, callers must fall back to
# the plain `docker build` path, which is exactly today's behavior.

BUILDX_BUILDER_NAME=${BUILDX_BUILDER_NAME:-gumroad-buildkite}

# True when buildx exists and a docker-container builder is (or can be made)
# available. Creating the builder is idempotent across steps on the same agent.
# Since #5827 the nginx and base builds run in parallel, so two steps can race
# `buildx create` here — when create fails, re-inspect: if the builder exists
# now, the other step won it and we're fine.
buildkit_cache_available() {
  docker buildx version > /dev/null 2>&1 || return 1
  if ! docker buildx inspect "$BUILDX_BUILDER_NAME" > /dev/null 2>&1; then
    if ! create_err=$(docker buildx create --name "$BUILDX_BUILDER_NAME" \
      --driver docker-container 2>&1 > /dev/null); then
      if ! docker buildx inspect "$BUILDX_BUILDER_NAME" > /dev/null 2>&1; then
        echo "buildkit_cache: builder unavailable, falling back to plain docker build: ${create_err}" >&2
        return 1
      fi
    fi
  fi
  # Inspecting with --bootstrap starts the builder container if it is not
  # already running. Without this, the function reports the cache as available
  # even when the container cannot start (for example, an unhealthy daemon),
  # and the build only fails later inside the BuildKit path before falling
  # back — one wasted build cycle and a confusing error in the logs.
  docker buildx inspect "$BUILDX_BUILDER_NAME" --bootstrap > /dev/null 2>&1 || return 1
  return 0
}

# buildkit_cache_opts <cache-ref>
# Cache import/export flags for the Makefile CACHE_OPTS variable.
# image-manifest=true + oci-mediatypes=true are required for ECR, which
# rejects the default (non-OCI) cache manifest media type.
buildkit_cache_opts() {
  local ref=$1
  echo "--cache-from type=registry,ref=${ref} --cache-to type=registry,ref=${ref},mode=max,image-manifest=true,oci-mediatypes=true"
}

# Value for the Makefile DOCKER_BUILD variable. --load copies the image built
# inside the container builder back into the docker engine so the existing
# tag/push flow downstream keeps working unchanged.
buildkit_docker_build() {
  echo "docker buildx build --builder ${BUILDX_BUILDER_NAME} --load"
}

# Like buildkit_docker_build, but pushes the tagged image straight from the
# builder to the registry (--push) instead of exporting it back into the local
# docker engine (--load). For the multi-GB web image the --load export alone
# costs about a minute per build, and the image was going to be pushed right
# after anyway — pushing from the builder does the upload once and skips the
# export entirely. Downstream steps that need the image locally (asset compile
# on another agent, for example) already pull it from ECR when it is missing.
buildkit_docker_build_push() {
  echo "docker buildx build --builder ${BUILDX_BUILDER_NAME} --push"
}

# buildkit_fallback_notice <image-name> <reason>
# The plain-docker-build fallback is safe but slow (no registry cache). Log it,
# and surface a Buildkite annotation so persistent degradation on an agent is
# visible on the build page instead of buried in step logs. Never fails.
buildkit_fallback_notice() {
  local image=$1 reason=$2
  echo "buildkit_cache: ${image}: ${reason} — using plain docker build (slower, no registry cache)" >&2
  if command -v buildkite-agent > /dev/null 2>&1; then
    echo "BuildKit registry cache unavailable for \`${image}\` (${reason}) — built with plain \`docker build\` instead. Slower but safe; recurring warnings here mean an agent needs attention." \
      | buildkite-agent annotate --style warning --context "buildkit-cache-${image}" 2>/dev/null || true
  fi
}

# pull_ruby_base_image <image>
# The content-addressed web_base tag hashes `docker history` of the LOCAL ruby
# image, so every agent must converge on the same upstream image or two agents
# will compute different tags for identical source — and a `build_web` step can
# then reference a web_base tag nobody pushed (hard build failure). Docker Hub
# re-tags `*-slim-bullseye` on Debian security rebuilds, so a warm agent's
# months-old local copy is NOT safe to trust. Always pull; when the local image
# is already current this is a cheap manifest check, not a re-download. If the
# pull fails (Hub outage / rate limit) fall back to a present local image
# rather than failing the build — stale-tag divergence is then possible but a
# transient outage shouldn't stop deploys.
pull_ruby_base_image() {
  local image=$1
  if ! docker pull --quiet "$image"; then
    if docker image inspect "$image" > /dev/null 2>&1; then
      echo "buildkit_cache: pull of ${image} failed; using existing local copy (tag divergence possible until the next successful pull)" >&2
    else
      echo "buildkit_cache: pull of ${image} failed and no local copy exists" >&2
      return 1
    fi
  fi
}
