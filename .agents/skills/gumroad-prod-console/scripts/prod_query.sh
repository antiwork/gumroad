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

# Pick a healthy instance in the production security group.
# Honor an explicit override first (set PROD_INSTANCE_IP to pin a host, e.g.
# when you already know a specific instance is healthy or sick).
if [ -n "${PROD_INSTANCE_IP:-}" ]; then
  instance_ip="$PROD_INSTANCE_IP"
  >&2 echo "Using PROD_INSTANCE_IP override: $instance_ip"
else
  # List all running instances, oldest first (oldest is warmest, but any works).
  # Only running instances: stopped or terminating ones have no private IP
  # (the CLI prints "None"), and probing those would waste 20 seconds each.
  candidate_ips=$(aws ec2 describe-instances \
    --filters "Name=instance.group-name,Values=$PROD_SECURITY_GROUP" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].[LaunchTime,PrivateIpAddress] | sort_by(@, &[0])" \
    --output text | awk '{print $2}')

  if [ -z "$candidate_ips" ]; then
    echo "Error: No running instance found in security group $PROD_SECURITY_GROUP" >&2
    exit 1
  fi

  # Bound each probe so a hung docker exec can't stall the whole run. GNU
  # coreutils `timeout` does this on Linux, but macOS — where many of us run
  # this from a laptop — ships no `timeout` (and often no `gtimeout` either).
  # A missing binary would exit 127 and be misread as "instance unhealthy",
  # failing every candidate and killing the console entirely. So resolve a real
  # timeout binary if present, else fall back to a small pure-bash timer.
  if command -v timeout >/dev/null 2>&1; then
    probe_timeout() { timeout "$@"; }
  elif command -v gtimeout >/dev/null 2>&1; then
    probe_timeout() { gtimeout "$@"; }
  else
    probe_timeout() {
      local dur=$1; shift
      "$@" & local pid=$!
      ( sleep "$dur"; kill -TERM "$pid" 2>/dev/null ) & local watcher=$!
      # Drop the watcher from the job table so killing it below doesn't print a
      # "Terminated" notice on every successful probe.
      disown "$watcher" 2>/dev/null
      wait "$pid" 2>/dev/null; local rc=$?
      kill -TERM "$watcher" 2>/dev/null
      return $rc
    }
  fi

  # Probe each candidate with a cheap 20s check and take the first one that
  # responds. The probe runs a no-op docker exec inside the puma container —
  # the same operation the real query uses — because the hangs that motivated
  # this failover happened at the docker exec step (SSH connected fine, but
  # exec never returned). A hung/recycling instance previously burned the full
  # outer timeout; now it costs <=20s and we fail over to the next-oldest.
  instance_ip=""
  for ip in $candidate_ips; do
    if LC_PAPER="$ip" probe_timeout 20 ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 "admin@$PROD_BASTION" \
        'sudo docker exec $(sudo docker ps -qf "name='"$PROD_CONTAINER_FILTER"'" -f "status=running" | head -n1) true' \
        >/dev/null 2>&1; then
      instance_ip="$ip"
      break
    fi
    >&2 echo "Instance $ip failed health probe, trying next..."
  done

  if [ -z "$instance_ip" ]; then
    echo "Error: No instance in $PROD_SECURITY_GROUP passed the health probe. Set PROD_INSTANCE_IP to force one." >&2
    exit 1
  fi
fi

>&2 echo "Connecting to $instance_ip via $PROD_BASTION..."

encoded=$(printf '%s\n' "$ruby_code" | base64 | tr -d '\n')

LC_PAPER="$instance_ip" ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new "admin@$PROD_BASTION" \
  'sudo docker exec -i $(sudo docker ps -aqf "name='"$PROD_CONTAINER_FILTER"'" -f "status=running") bash -c "echo '"$encoded"' | base64 --decode | DATABASE_HOST=\$'"$PROD_DB_HOST_VAR"' bundle exec rails runner -"'
