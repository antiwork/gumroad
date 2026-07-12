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
buildkit_cache_available() {
  docker buildx version > /dev/null 2>&1 || return 1
  if ! docker buildx inspect "$BUILDX_BUILDER_NAME" > /dev/null 2>&1; then
    docker buildx create --name "$BUILDX_BUILDER_NAME" \
      --driver docker-container > /dev/null 2>&1 || return 1
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

# pull_image_if_missing <image>
# The content-addressed base tag hashes `docker history` of the ruby image, so
# it must exist locally before the tag can be computed — but there is no need
# to re-pull it on every build the way the old unconditional pull did.
pull_image_if_missing() {
  local image=$1
  if ! docker image inspect "$image" > /dev/null 2>&1; then
    docker pull --quiet "$image"
  fi
}
