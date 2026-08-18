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
: "${PROD_SSH_CONTROL_PATH:=$HOME/.ssh/cm-gr-bastion}"
: "${PROD_IP_CACHE:=$HOME/.cache/gumroad-prod-console/last_ip}"
: "${PROD_IP_CACHE_TTL:=600}"

# Reuse one TCP+auth session to the bastion (ControlPersist). LC_PAPER is still
# sent per hop, so the jump host can change without dropping the mux.
bastion_ssh() {
  ssh -o SendEnv=LC_PAPER \
      -o StrictHostKeyChecking=accept-new \
      -o ControlMaster=auto \
      -o "ControlPath=$PROD_SSH_CONTROL_PATH" \
      -o ControlPersist=8h \
      "$@"
}

if command -v timeout >/dev/null 2>&1; then
  probe_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  probe_timeout() { gtimeout "$@"; }
else
  probe_timeout() {
    local dur=$1; shift
    "$@" & local pid=$!
    ( sleep "$dur"; kill -TERM "$pid" 2>/dev/null ) & local watcher=$!
    disown "$watcher" 2>/dev/null
    wait "$pid" 2>/dev/null; local rc=$?
    kill -TERM "$watcher" 2>/dev/null
    return $rc
  }
fi

file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"
}

# Last-good private IP. Skip EC2 discovery when that host still answers.
try_cached_instance() {
  [ -f "$PROD_IP_CACHE" ] || return 1
  local age ip remaining
  age=$(( $(date +%s) - $(file_mtime "$PROD_IP_CACHE") ))
  [ "$age" -ge "$PROD_IP_CACHE_TTL" ] && return 1
  ip=$(tr -d '[:space:]' < "$PROD_IP_CACHE")
  case "$ip" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *) return 1 ;;
  esac
  remaining=8
  if LC_PAPER="$ip" probe_timeout "$remaining" bastion_ssh -o ConnectTimeout=5 \
      "admin@$PROD_BASTION" \
      'sudo docker exec $(sudo docker ps -qf "name='"$PROD_CONTAINER_FILTER"'" -f "status=running" | head -n1) true' \
      >/dev/null 2>&1; then
    instance_ip="$ip"
    >&2 echo "Using cached instance $instance_ip (${age}s old)"
    return 0
  fi
  return 1
}

write_instance_cache() {
  mkdir -p "$(dirname "$PROD_IP_CACHE")"
  printf '%s\n' "$1" > "$PROD_IP_CACHE"
}

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

# Preflight only when we still need EC2 discovery. A warm cache or an explicit
# pin can hop without AWS.
need_discovery=1
if [ -n "${PROD_INSTANCE_IP:-}" ]; then
  instance_ip="$PROD_INSTANCE_IP"
  need_discovery=
  >&2 echo "Using PROD_INSTANCE_IP override: $instance_ip"
elif try_cached_instance; then
  need_discovery=
fi

if [ -n "$need_discovery" ]; then
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "Error: AWS credentials not configured." >&2
    echo "Run 'aws configure', set AWS_PROFILE, or export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY." >&2
    echo "You also need SSH access to $PROD_BASTION." >&2
    exit 1
  fi

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

  # Probe each candidate with a cheap 20s check and take the first one that
  # responds. The probe runs a no-op docker exec inside the puma container —
  # the same operation the real query uses — because the hangs that motivated
  # this failover happened at the docker exec step (SSH connected fine, but
  # exec never returned). A hung/recycling instance previously burned the full
  # outer timeout; now it costs <=20s and we fail over to the next-oldest.
  # Callers get a couple of minutes of wall clock for the WHOLE run, so picking an instance
  # cannot spend all of it — a large pool would time the caller out before the query they
  # actually asked for ever starts. Both passes below draw down one shared deadline.
  : "${PROD_SELECT_BUDGET:=90}"
  select_deadline=$(( $(date +%s) + PROD_SELECT_BUDGET ))
  # Hold back a third of the budget for the patient pass: five 20s timeouts would
  # otherwise drain all of it in the fast pass and the retry below would never run —
  # exactly the many-slow-hosts case it exists for.
  patient_reserve=$(( PROD_SELECT_BUDGET / 3 ))
  [ "$patient_reserve" -gt 60 ] && patient_reserve=60 || true
  fast_deadline=$(( select_deadline - patient_reserve ))

  instance_ip=""
  stale_key_ips=""
  slow_ips=""
  budget_exhausted=""
  probe_err=$(mktemp)
  for ip in $candidate_ips; do
    remaining=$(( fast_deadline - $(date +%s) ))
    if [ "$remaining" -le 5 ]; then
      budget_exhausted=1
      break
    fi
    [ "$remaining" -gt 20 ] && remaining=20 || true
    if LC_PAPER="$ip" probe_timeout "$remaining" bastion_ssh \
        -o ConnectTimeout=10 "admin@$PROD_BASTION" \
        'sudo docker exec $(sudo docker ps -qf "name='"$PROD_CONTAINER_FILTER"'" -f "status=running" | head -n1) true' \
        >/dev/null 2>"$probe_err"; then
      instance_ip="$ip"
      break
    fi
    # A probe can fail for many reasons — the container is still starting, the host is
    # hung, the network blipped, we timed out. In all of those the bastion's recorded host
    # key is still correct and deleting it would throw away a real protection against
    # someone impersonating that address. Only treat the key as stale when SSH itself says
    # so, AND the complaint names the address we just probed: the bastion can print the
    # whole man-in-the-middle banner about an earlier hop, so the banner alone is not proof
    # that THIS candidate is the one with the outdated key.
    if grep -qE "REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed" "$probe_err" \
       && grep -qF "$ip" "$probe_err"; then
      stale_key_ips="$stale_key_ips $ip"
      # The bastion's onward hop usually just WARNS about a changed key and connects anyway
      # (recycled EC2 IPs make that the steady state, not an anomaly). Only an outright
      # refusal means the key caused the failure; after a warn-and-proceed banner the probe
      # failed for some other reason, so that candidate still deserves the patient retry.
      if grep -qF "Host key verification failed" "$probe_err"; then
        >&2 echo "Instance $ip refused: bastion holds an outdated host key, trying next..."
      else
        slow_ips="$slow_ips $ip"
        >&2 echo "Instance $ip failed health probe (outdated host key noted), trying next..."
      fi
    else
      # A 20s probe is tuned to skip past a hung host quickly, which means it also rejects a
      # host that is merely slow — and a slow-but-working host is still a usable hop. Keep it
      # for a second, more patient pass rather than discarding it (see below).
      slow_ips="$slow_ips $ip"
      >&2 echo "Instance $ip failed health probe, trying next..."
    fi
  done
  rm -f "$probe_err"

  # Before giving up entirely, retry the non-stale-key failures with a patient probe.
  # The 20s pass above is deliberately impatient so one hung host cannot eat the caller's
  # whole budget, but that same impatience rejects hosts that are only slow to answer.
  # When the fast pass finds NOTHING, "every instance is unhealthy" is the less likely
  # explanation — a fleet-wide outage is rare, a fleet under load is not. On 2026-07-29
  # this aborted with all 8 candidates rejected while 10.1.34.180 answered a real query
  # fine on the very next attempt, which silently blocked every prod-console verification
  # (and every watcher built on one) until it was forced by hand with PROD_INSTANCE_IP.
  #
  # This runs only on the all-rejected path, so the common case pays nothing for it — and it
  # only gets whatever is left of the shared selection budget, so a large pool cannot turn the
  # retry into a longer stall than the failure it replaces.
  if [ -z "$instance_ip" ] && [ -n "${slow_ips// /}" ]; then
    if [ $(( select_deadline - $(date +%s) )) -le 5 ]; then
      # No time left for even one patient probe — don't announce a retry that won't happen.
      budget_exhausted=1
    else
      >&2 echo "No candidate answered within 20s; retrying${slow_ips} with a patient probe..."
      for ip in $slow_ips; do
        remaining=$(( select_deadline - $(date +%s) ))
        if [ "$remaining" -le 5 ]; then
          budget_exhausted=1
          break
        fi
        [ "$remaining" -gt 60 ] && remaining=60 || true
        connect_timeout=$(( remaining / 3 ))
        [ "$connect_timeout" -lt 5 ] && connect_timeout=5 || true
        if LC_PAPER="$ip" probe_timeout "$remaining" bastion_ssh \
            -o ConnectTimeout="$connect_timeout" "admin@$PROD_BASTION" \
            'sudo docker exec $(sudo docker ps -qf "name='"$PROD_CONTAINER_FILTER"'" -f "status=running" | head -n1) true' \
            >/dev/null 2>&1; then
          instance_ip="$ip"
          >&2 echo "Instance $ip answered on the patient retry (slow, not unhealthy)."
          break
        fi
      done
    fi
  fi

  # EC2 recycles private IPs, so the BASTION's known_hosts accumulates stale keys and refuses
  # the onward hop with "REMOTE HOST IDENTIFICATION HAS CHANGED" / "Offending ECDSA key". From
  # out here that is easy to mistake for an unhealthy instance, and it silently shrinks the
  # usable pool every time instances are replaced — several consecutive candidates became
  # unusable until the entries were cleared by hand.
  #
  # Clean up now that a working hop is known. The bastion auto-jumps to whatever LC_PAPER
  # names, so a command cannot be run on the bastion directly (omitting LC_PAPER just fails
  # with "Could not resolve hostname") — route ssh-keygen through the host that answered,
  # which shares the same bastion known_hosts file. This does not rescue the current run (the
  # instance we are using already works), it stops the pool from silently decaying for the
  # next one.
  #
  # All removals go in ONE hop, however many candidates were stale, so this costs at most a
  # single connection instead of one per address. That matters because callers only get a
  # couple of minutes of wall clock for the whole run, and this work happens before the query
  # they actually asked for has started.
  #
  # Safe: removing a key for a recycled internal IP means the next connect re-learns it via
  # accept-new, exactly like a first-ever connect. ssh-keygen -R is a no-op with no entry.
  if [ -n "$instance_ip" ] && [ -n "${stale_key_ips// /}" ]; then
    keygen_cmd=""
    for stale_ip in $stale_key_ips; do
      keygen_cmd="$keygen_cmd ssh-keygen -f ~/.ssh/known_hosts -R '$stale_ip';"
    done
    # Also inside the selection budget: this is housekeeping for the NEXT run, so it must
    # never be the reason this one times out before its query starts.
    remaining=$(( select_deadline - $(date +%s) ))
    [ "$remaining" -gt 20 ] && remaining=20 || true
    if [ "$remaining" -lt 5 ]; then
      >&2 echo "Skipped clearing outdated bastion host keys for:$stale_key_ips (out of selection budget)."
    elif LC_PAPER="$instance_ip" probe_timeout "$remaining" bastion_ssh \
        -o ConnectTimeout=10 "admin@$PROD_BASTION" \
        "$keygen_cmd" >/dev/null 2>&1; then
      >&2 echo "Cleared outdated bastion host keys for:$stale_key_ips"
    else
      >&2 echo "Could not clear outdated bastion host keys for:$stale_key_ips (continuing anyway)."
    fi
  fi

  if [ -z "$instance_ip" ]; then
    if [ -n "$budget_exhausted" ]; then
      echo "Error: ran out of the ${PROD_SELECT_BUDGET}s instance-selection budget before any candidate in $PROD_SECURITY_GROUP answered." >&2
      echo "Not necessarily an outage — the pool may just be slow. Set PROD_INSTANCE_IP to pin a host, or raise PROD_SELECT_BUDGET." >&2
    else
      echo "Error: No instance in $PROD_SECURITY_GROUP passed the health probe. Set PROD_INSTANCE_IP to force one." >&2
    fi
    exit 1
  fi
fi

>&2 echo "Connecting to $instance_ip via $PROD_BASTION..."
write_instance_cache "$instance_ip"

encoded=$(printf '%s\n' "$ruby_code" | base64 | tr -d '\n')

LC_PAPER="$instance_ip" bastion_ssh "admin@$PROD_BASTION" \
  'sudo docker exec -i $(sudo docker ps -aqf "name='"$PROD_CONTAINER_FILTER"'" -f "status=running") bash -c "echo '"$encoded"' | base64 --decode | DATABASE_HOST=\$'"$PROD_DB_HOST_VAR"' bundle exec rails runner -"'
