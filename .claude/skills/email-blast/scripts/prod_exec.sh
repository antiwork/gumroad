#!/bin/bash
# Execute Ruby code against Gumroad production PRIMARY database via rails runner.
# This connects to the primary (read-write) database, NOT the read replica.
# USE WITH EXTREME CAUTION — this can write to production.
#
# Usage:
#   ./prod_exec.sh path/to/script.rb
#   echo 'Ruby code' | ./prod_exec.sh
#   ./prod_exec.sh 'puts User.count'
set -e

DEPLOYMENT_DIR="${GUMROAD_DEPLOYMENT_DIR:-$HOME/Documents/GitHub/gumroad-deployment}"
ENV_FILE="$DEPLOYMENT_DIR/nomad/.env.aws"
SECURITY_GROUP=production-web_cluster_green
BASTION="" # Get from gumroad-deployment repo

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

>&2 echo "⚠️  Connecting to production PRIMARY ($instance_ip) via $BASTION..."
>&2 echo "⚠️  This is a WRITE-CAPABLE connection. Proceed with caution."

# Base64 encode Ruby code to safely pass through SSH + Docker shell layers
encoded=$(printf '%s\n' "$ruby_code" | base64 | tr -d '\n')

# SSH -> bastion -> docker exec -> rails runner (PRIMARY database — no DATABASE_HOST override)
LC_PAPER="$instance_ip" ssh -o SendEnv=LC_PAPER "admin@$BASTION" \
  'sudo docker exec -i $(sudo docker ps -aqf "name=puma-*" -f "status=running") bash -c "echo '"$encoded"' | base64 --decode | bundle exec rails runner -"'
