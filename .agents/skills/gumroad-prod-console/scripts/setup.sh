#!/bin/bash
# One-time setup: migrate AWS credentials from gumroad-deployment/nomad/.env.aws
# into an AWS CLI profile, so prod_query.sh can use the standard credential chain
# and no longer depends on the gumroad-deployment repo.
#
# Usage:
#   ./setup.sh                       # reads from default .env.aws location
#   ./setup.sh /path/to/.env.aws     # reads from a custom path
set -e

PROFILE="${AWS_PROFILE_NAME:-gumroad-prod}"
ENV_FILE="${1:-${GUMROAD_DEPLOYMENT_DIR:-$HOME/Documents/GitHub/gumroad-deployment}/nomad/.env.aws}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: can't find $ENV_FILE" >&2
  echo "Pass the path explicitly: $0 /path/to/.env.aws" >&2
  exit 1
fi

set -a; . "$ENV_FILE"; set +a

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "Error: $ENV_FILE didn't define AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY" >&2
  exit 1
fi

aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID" --profile "$PROFILE"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$PROFILE"
[ -n "$AWS_DEFAULT_REGION" ] && aws configure set region "$AWS_DEFAULT_REGION" --profile "$PROFILE"

echo "Wrote AWS profile: $PROFILE"

# Offer to append `export AWS_PROFILE=$PROFILE` to the user's shell profile.
profile_file=""
case "$SHELL" in
  */zsh) profile_file="$HOME/.zshrc" ;;
  */bash)
    [[ "$OSTYPE" == darwin* ]] && profile_file="$HOME/.bash_profile" || profile_file="$HOME/.bashrc"
    ;;
esac

export_line="export AWS_PROFILE=$PROFILE"

if [ -n "$profile_file" ] && [ -f "$profile_file" ] && grep -Fqx "$export_line" "$profile_file"; then
  echo "$export_line is already in $profile_file."
elif [ -n "$profile_file" ] && [ -t 0 ]; then
  printf "\nAdd '%s' to %s? [Y/n] " "$export_line" "$profile_file"
  read -r reply
  case "$reply" in
    ""|[Yy]*)
      printf '\n%s\n' "$export_line" >> "$profile_file"
      echo "Appended. Run: source $profile_file"
      ;;
    *)
      echo "Skipped. Add the line manually and reload your shell."
      ;;
  esac
else
  echo ""
  echo "Add this line to your shell profile and reload:"
  echo ""
  echo "    $export_line"
fi

echo ""
echo "Verify with: aws sts get-caller-identity"
