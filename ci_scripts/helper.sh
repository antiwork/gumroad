GREEN='\033[0;32m'
NC='\033[0m' # No Color
logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo -e "${GREEN}$DT helper.sh: $1${NC}"
}

quietly() {
  if [ "$TRIM_DOCKER_OUTPUT" = true ]; then
    touch /tmp/build-docker-logs.txt
    "$@" 2>&1 >>/tmp/build-docker-logs.txt;
  else
    "$@"
  fi
}

function generate_nginx_tag(){
  local paths=()
  local app_dir
  app_dir=$(git rev-parse --show-toplevel)

  # Change relative paths to absolute paths
  for arg in "$@"; do
    paths+=("${app_dir}/${arg}")
  done

  # Get short SHA of the latest commit affecting the paths
  git rev-list --abbrev-commit --abbrev=12 HEAD -1 -- "${paths[@]}"
}

function branch_cache_setup(){
  local use_main_branch_cache=${1:-false}
  export AWS_ACCESS_KEY_ID=$GUM_AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$GUM_AWS_SECRET_ACCESS_KEY
  export CACHE_TAR_FILE="${BUILDKITE_BRANCH//\//_}.tar.gz"
  export CACHE_BUCKET_NAME="buildkite-branch-cache"
  export BRANCH_CACHE_RESTORE_ENABLED="true"
  export BRANCH_CACHE_UPLOAD_ENABLED="true"

  if [[ "$BUILDKITE_BRANCH" == "main" ]]    || \
     [[ "$BUILDKITE_BRANCH" == "staging" ]]    || \
     [[ "$BUILDKITE_BRANCH" == "production" ]] || \
     [[ "$BUILDKITE_MESSAGE" =~ no.cache ]]; then
    export BRANCH_CACHE_RESTORE_ENABLED="false"
    export BRANCH_CACHE_UPLOAD_ENABLED="false"
  fi

  if [[ "$BUILDKITE_BRANCH" == "main" ]]; then
    export BRANCH_CACHE_UPLOAD_ENABLED="true"
  fi

  if [[ "$BRANCH_CACHE_RESTORE_ENABLED" == "true" ]]; then
    logger "trying to restore cache from current branch"
    aws s3 cp "s3://$CACHE_BUCKET_NAME/$CACHE_TAR_FILE" . || current_branch_cache_not_found=true

    if ${current_branch_cache_not_found:-false}; then
      warn "didn't find current branch cache: $CACHE_TAR_FILE"

      if [[ $use_main_branch_cache == true ]]; then
        logger "trying to restore cache from main branch"
        aws s3 cp "s3://$CACHE_BUCKET_NAME/main.tar.gz" $CACHE_TAR_FILE || main_branch_cache_not_found=true

        if ${main_branch_cache_not_found:-false}; then
          warn "didn't find main branch cache"
        fi
      fi
    fi
  fi
}
