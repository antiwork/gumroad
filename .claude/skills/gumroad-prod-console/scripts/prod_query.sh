#!/bin/bash
# Execute read-only Ruby code against Gumroad production via rails runner.
# Usage:
#   ./prod_query.sh 'puts User.count'
#   ./prod_query.sh path/to/script.rb
#   echo 'puts User.count' | ./prod_query.sh
set -e

DEPLOYMENT_DIR="${GUMROAD_DEPLOYMENT_DIR:-$HOME/Documents/GitHub/gumroad-deployment}"
ENV_FILE="$DEPLOYMENT_DIR/nomad/.env.aws"
SECURITY_GROUP=production-web_cluster_green
BASTION=bastion-production.gumroad.net

# Read Ruby code from argument (string or file) or stdin
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

# Find oldest running production instance
instance_ip=$(dotenv -f "$ENV_FILE" aws ec2 describe-instances \
  --filter "Name=instance.group-name,Values=$SECURITY_GROUP" \
  --query "Reservations[].Instances[].[LaunchTime,PrivateIpAddress] | sort_by(@, &[0])" \
  --output text | awk '{print $2}' | head -n1)

if [ -z "$instance_ip" ]; then
  echo "Error: Could not find production instance" >&2
  exit 1
fi

>&2 echo "Connecting to production ($instance_ip) via $BASTION..."

# Base64 encode Ruby code to safely pass through SSH + Docker shell layers
encoded=$(printf '%s\n' "$ruby_code" | base64 | tr -d '\n')

# SSH -> bastion -> docker exec -> rails runner (read-only replica)
# Escaping layers:
#   - Single quotes prevent local expansion
#   - Break out to insert $encoded locally
#   - \$ in bastion's double quotes prevents expansion there
#   - Container's bash finally expands $DATABASE_WORKER_REPLICA1_HOST
LC_PAPER="$instance_ip" ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new "admin@$BASTION" \
  'sudo docker exec -i $(sudo docker ps -aqf "name=puma-*" -f "status=running") bash -c "echo '"$encoded"' | base64 --decode | DATABASE_HOST=\$DATABASE_WORKER_REPLICA1_HOST bundle exec rails runner -"'
