#!/bin/bash
# Execute read-only Ruby code via rails runner on a production web host.
# Usage:
#   ./prod_query.sh 'puts User.count'
#   ./prod_query.sh path/to/script.rb
#   echo 'puts User.count' | ./prod_query.sh
set -e

# Load optional local overrides (self-hosters point this at their own infra).
[ -f "$HOME/.config/gumroad-prod-console.env" ] && . "$HOME/.config/gumroad-prod-console.env"

# Gumroad defaults — override via env or ~/.config/gumroad-prod-console.env.
: "${PROD_BASTION:=bastion-production.gumroad.net}"
: "${PROD_SECURITY_GROUP:=production-web_cluster_green}"
: "${PROD_CONTAINER_FILTER:=puma-*}"
: "${PROD_DB_HOST_VAR:=DATABASE_WORKER_REPLICA1_HOST}"
: "${PROD_AWS_PROFILE:=gumroad-prod}"

# Non-interactive shells (e.g. Claude Code's Bash tool) don't source .zshrc,
# so an AWS_PROFILE export there won't reach this script. Fall back to the
# configured profile if the caller hasn't set explicit credentials.
if [ -z "$AWS_ACCESS_KEY_ID" ] && [ -z "$AWS_PROFILE" ]; then
  export AWS_PROFILE="$PROD_AWS_PROFILE"
fi

# Read Ruby code from argument (string or file) or stdin.
if [ -n "$1" ]; then
  if [ -f "$1" ]; then
    ruby_code=$(cat "$1")
  else
    ruby_code="$1"
  fi
elif [ ! -t 0 ]; then
  ruby_code=$(cat)
else
  echo "Usage: $0 'Ruby code'" >&2
  echo "       $0 path/to/script.rb" >&2
  echo "       echo 'Ruby code' | $0" >&2
  exit 1
fi

# Preflight: AWS credentials for EC2 lookup.
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Error: AWS credentials not configured." >&2
  echo "Run 'aws configure', set AWS_PROFILE, or export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY." >&2
  echo "You also need SSH access to $PROD_BASTION." >&2
  exit 1
fi

# Pick oldest running instance in the production security group.
instance_ip=$(aws ec2 describe-instances \
  --filter "Name=instance.group-name,Values=$PROD_SECURITY_GROUP" \
  --query "Reservations[].Instances[].[LaunchTime,PrivateIpAddress] | sort_by(@, &[0])" \
  --output text | awk '{print $2}' | head -n1)

if [ -z "$instance_ip" ]; then
  echo "Error: No running instance found in security group $PROD_SECURITY_GROUP" >&2
  exit 1
fi

>&2 echo "Connecting to $instance_ip via $PROD_BASTION..."

encoded=$(printf '%s\n' "$ruby_code" | base64 | tr -d '\n')

LC_PAPER="$instance_ip" ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new "admin@$PROD_BASTION" \
  'sudo docker exec -i $(sudo docker ps -aqf "name='"$PROD_CONTAINER_FILTER"'" -f "status=running") bash -c "echo '"$encoded"' | base64 --decode | DATABASE_HOST=\$'"$PROD_DB_HOST_VAR"' bundle exec rails runner -"'
