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
: "${PROD_SSH_CONTROL_PATH:=$HOME/.ssh/cm-gr-%C}"
# Key the cache file by discovery scope. A cached IP only means something for
# the bastion/security-group/container combination that selected it; a shared
# file would let a config change reuse a host outside the new scope (the
# docker probe alone cannot catch that when the bastion stays the same).
cache_scope=$(printf '%s' "$PROD_BASTION|$PROD_SECURITY_GROUP|$PROD_CONTAINER_FILTER" | cksum | cut -d' ' -f1)
: "${PROD_IP_CACHE:=$HOME/.cache/gumroad-prod-console/last_ip.$cache_scope}"
: "${PROD_IP_CACHE_TTL:=600}"

# Extra ssh flags. Must stay flags on the `ssh` binary — `timeout` cannot
# execute a shell function (it would 127 every probe).
#
# The ControlPath keeps ssh's %C token (hash of local host, remote host, port,
# user): mux reuse keys on the socket path alone, so a fixed name would let a
# changed PROD_BASTION silently reuse the master to the old bastion.
#
# ServerAlive* bounds a dead master: without it, a network change or laptop
# sleep leaves a half-dead socket that every later ssh attaches to and hangs
# on (kernel TCP keepalive takes ~2h). With it, the master kills itself in
# ~30s and ControlMaster=auto builds a fresh one.
SSH_MUX_OPTS=(
  -o ControlMaster=auto
  -o "ControlPath=$PROD_SSH_CONTROL_PATH"
  -o ControlPersist=8h
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
)

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

# BSD stat wants -f %m, GNU stat wants -c %Y. Chaining them with || is not
# enough: GNU's -f is filesystem mode, which still prints for an existing file
# and would pollute the captured value with a multi-line block. Probe the GNU
# form silently first, then run whichever form this system supports.
file_mtime() {
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
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
  if LC_PAPER="$ip" probe_timeout "$remaining" ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new "${SSH_MUX_OPTS[@]}" -o ConnectTimeout=5 \
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
    if LC_PAPER="$ip" probe_timeout "$remaining" ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new "${SSH_MUX_OPTS[@]}" \
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
        if LC_PAPER="$ip" probe_timeout "$remaining" ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new "${SSH_MUX_OPTS[@]}" \
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
    elif LC_PAPER="$instance_ip" probe_timeout "$remaining" ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new "${SSH_MUX_OPTS[@]}" \
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

encoded=$(printf '%s\n' "$ruby_code" | base64 | tr -d '\n')

record_success() {
  # Remember last-good only after the query succeeded, and only for
  # auto-selected hosts. A PROD_INSTANCE_IP pin is per-invocation — caching it
  # would stick later unpinned calls on that box. The cache is an
  # optimization: a failed write must not turn the successful query into a
  # nonzero exit.
  if [ -z "${PROD_INSTANCE_IP:-}" ]; then
    write_instance_cache "$instance_ip" \
      || >&2 echo "Warning: could not write $PROD_IP_CACHE (continuing)."
  fi
}

record_failure() {
  # Drop the cache on any failed run. The docker-true probe cannot tell a
  # host that fails Rails boot/DB from a healthy one that ran a bad query, so
  # keeping the entry would re-select a broken host on every call until the
  # TTL expires. Worst case of dropping is one extra discovery after a typo.
  if [ -z "${PROD_INSTANCE_IP:-}" ]; then
    rm -f "$PROD_IP_CACHE"
  fi
}

# Warm path: a persistent `rails runner` loop on the host serves spooled
# queries so only the FIRST call after a host recycle pays Rails boot.
# Replica-only: a non-default DB host var (i.e. a primary write session) must
# never ride a loop that was booted pointing at the replica, so it always
# takes the one-shot path below. PROD_NO_RUNNER_LOOP=1 opts out entirely.
script_dir=$(cd "$(dirname "$0")" && pwd)
runner_loop_ok=1
[ -n "${PROD_NO_RUNNER_LOOP:-}" ] && runner_loop_ok=
[ "$PROD_DB_HOST_VAR" != "DATABASE_WORKER_REPLICA1_HOST" ] && runner_loop_ok=
[ -f "$script_dir/prod_runner_loop.rb" ] || runner_loop_ok=

if [ -n "$runner_loop_ok" ]; then
  loop_b64=$(base64 < "$script_dir/prod_runner_loop.rb" | tr -d '\n')
  # Runs INSIDE the puma container. Quoted heredoc, placeholders substituted
  # below — remote $vars here must not expand on this machine.
  remote_script=$(cat <<'REMOTE'
set -u
BASE=/tmp/gumclaw-runner

# The loop evals whatever lands in in/ with THIS shell's privileges, and /tmp
# is world-writable inside the container. Refuse a spool tree someone else
# pre-created (symlink or foreign owner) — otherwise a lower-privileged
# process could plant loop.rb or job files for a higher-privileged loop.
# The -L re-check after mkdir catches a symlink swapped in between the two.
mkdir -p "$BASE"
if [ -L "$BASE" ] || [ ! -d "$BASE" ] || [ "$(stat -c %u "$BASE")" != "$(id -u)" ]; then
  echo "GUMCLAW_LOOP_FALLBACK_OK: spool dir $BASE is a symlink or owned by someone else" >&2
  exit 97
fi
chmod 700 "$BASE"
mkdir -p "$BASE/in" "$BASE/out"

# flock is required for the single-booter lock below; without it the loop
# path cannot boot safely, and the one-shot path costs only the Rails boot.
if ! command -v flock >/dev/null 2>&1; then
  echo "GUMCLAW_LOOP_FALLBACK_OK: flock unavailable in container" >&2
  exit 97
fi

job_id=$(date +%s)-$$-$RANDOM
new_sum=$(echo "__LOOP_B64__" | base64 --decode | md5sum | awk '{print $1}')

# PID-reuse guard: loop.pid can outlive its process (SIGKILL, crash), and a
# recycled PID can belong to anything — this shell can run as root, so a
# blind kill could hit a puma worker. Only treat a PID as ours when its
# cmdline still names our loop script.
pid_is_loop() {
  [ -n "$1" ] && grep -qaF "$BASE/loop.rb" "/proc/$1/cmdline" 2>/dev/null
}
loop_pid_alive() {
  local pid
  pid=$(cat "$BASE/loop.pid" 2>/dev/null) || return 1
  pid_is_loop "$pid"
}

loop_alive=
live_pid=$(cat "$BASE/loop.pid" 2>/dev/null || echo "")
if pid_is_loop "$live_pid"; then
  loop_alive=1
  # A live loop running stale code stays stale until the host recycles —
  # replace it so client and loop can never disagree on the job contract.
  old_sum=$(md5sum "$BASE/loop.rb" 2>/dev/null | awk '{print $1}')
  if [ "$old_sum" != "$new_sum" ]; then
    # Only the loop parent publishes results, so killing it mid-job strands
    # that caller at rc 96. A recent .taken with no rc yet means a job may be
    # executing: serve THIS query one-shot and let a later idle call do the
    # replacement. (A job taken between this check and the kill below
    # degrades to the existing accepted rc-96 path, nothing worse.)
    if [ -n "$(find "$BASE/out" -name '*.taken' -mmin -7 2>/dev/null | head -n1)" ]; then
      echo "GUMCLAW_LOOP_FALLBACK_OK: stale loop is busy; deferring replacement" >&2
      exit 97
    fi
    # Signal only the PID we validated above, and wait for it to exit before
    # spooling: a still-running old loop uses the OLD job contract and could
    # claim the job this run is about to spool.
    kill "$live_pid" 2>/dev/null
    tries=0
    while pid_is_loop "$live_pid" && [ "$tries" -lt 50 ]; do
      sleep 0.2
      tries=$(( tries + 1 ))
    done
    if pid_is_loop "$live_pid"; then
      echo "GUMCLAW_LOOP_FALLBACK_OK: stale loop did not exit; deferring replacement" >&2
      exit 97
    fi
    rm -f "$BASE/loop.pid" "$BASE/starting"
    loop_alive=
  fi
fi
if [ -z "$loop_alive" ]; then
  # One booter at a time: concurrent cold callers would each boot a loop and
  # all but one exit after wasting a full Rails boot. flock serializes the
  # whole decide-and-boot step and cannot go stale (the kernel releases it
  # when the holder exits), so the age check on `starting` — which outlives a
  # successful boot on purpose, for the client's dead-loop grace below — runs
  # with no takeover race. Boot rc 2 = the loop script could not be written.
  (
    flock -n 9 || exit 0
    now=$(date +%s)
    if [ -f "$BASE/starting" ] && [ $(( now - $(cat "$BASE/starting" 2>/dev/null || echo 0) )) -lt 180 ]; then
      exit 0
    fi
    echo "$now" > "$BASE/starting"
    # Lock holder writes loop.rb — losers must not overwrite it mid-boot with
    # their own version. A failed write (e.g. ENOSPC) would boot a truncated
    # script: release the claim and tell the client a one-shot re-run is safe.
    if ! echo "__LOOP_B64__" | base64 --decode > "$BASE/loop.rb"; then
      rm -f "$BASE/loop.rb" "$BASE/starting"
      exit 2
    fi
    # No cd: bundle needs the app's Gemfile, i.e. the container WORKDIR the
    # one-shot path already relies on.
    ( DATABASE_HOST="$__DB_HOST_VAR__" nohup bundle exec rails runner "$BASE/loop.rb" > "$BASE/loop.log" 2>&1 & )
  ) 9>"$BASE/boot.lock"
  if [ "$?" -eq 2 ]; then
    echo "GUMCLAW_LOOP_FALLBACK_OK: could not write the loop script" >&2
    exit 97
  fi
fi
# A partial spool write (e.g. ENOSPC) must never be published — the loop
# would eval truncated Ruby as if it were the query. The job is provably
# unclaimed here, so a one-shot re-run is safe.
if ! echo "__QUERY_B64__" | base64 --decode > "$BASE/in/$job_id.rb.tmp"; then
  rm -f "$BASE/in/$job_id.rb.tmp"
  echo "GUMCLAW_LOOP_FALLBACK_OK: could not spool the job" >&2
  exit 97
fi
mv "$BASE/in/$job_id.rb.tmp" "$BASE/in/$job_id.rb"
# Two-phase deadline keyed on the loop's .taken marker. QUEUE time (loop boot
# ~15s + earlier jobs, each capped at 300s) must not eat the EXECUTION budget,
# or a query behind a slow neighbour gets re-run one-shot while still running.
spool_time=$(date +%s)
queue_deadline=$(( spool_time + 420 ))
exec_deadline=
while [ ! -f "$BASE/out/$job_id.rc" ]; do
  now=$(date +%s)
  if [ -z "$exec_deadline" ] && [ -f "$BASE/out/$job_id.taken" ]; then
    exec_deadline=$(( now + 360 ))
  fi
  if [ -n "$exec_deadline" ]; then
    if [ "$now" -ge "$exec_deadline" ]; then
      # Taken but no result: the query may still be executing. Never re-run.
      echo "gumclaw runner loop took the query but produced no result; NOT re-running. See $BASE/loop.log on the host" >&2
      rm -f "$BASE/out/$job_id.taken"
      exit 96
    fi
  else
    dead_loop=
    # The 10s grace covers the flock winner's window between taking the boot
    # lock and writing `starting`: a missing file reads as age-infinite and
    # would otherwise trip this check on the very first poll.
    if ! loop_pid_alive \
       && [ $(( now - spool_time )) -ge 10 ] \
       && [ $(( now - $(cat "$BASE/starting" 2>/dev/null || echo 0) )) -ge 180 ]; then
      dead_loop=1
    fi
    if [ "$now" -ge "$queue_deadline" ] || [ -n "$dead_loop" ]; then
      # Job still spooled, never picked up — remove it and tell the client a
      # one-shot re-run is safe. The sentinel goes on stderr because exit
      # codes cannot be trusted here: the query's own rc passes through this
      # script verbatim, so ANY reserved number could collide with it.
      rm -f "$BASE/in/$job_id.rb"
      echo "GUMCLAW_LOOP_FALLBACK_OK: query was never picked up" >&2
      exit 97
    fi
  fi
  sleep 0.2
done
cat "$BASE/out/$job_id.out" 2>/dev/null
cat "$BASE/out/$job_id.err" >&2 2>/dev/null
rc=$(cat "$BASE/out/$job_id.rc")
rm -f "$BASE/out/$job_id.out" "$BASE/out/$job_id.err" "$BASE/out/$job_id.rc" "$BASE/out/$job_id.taken"
exit "$rc"
REMOTE
)
  remote_script=${remote_script//__LOOP_B64__/$loop_b64}
  remote_script=${remote_script//__QUERY_B64__/$encoded}
  remote_script=${remote_script//__DB_HOST_VAR__/$PROD_DB_HOST_VAR}
  remote_b64=$(printf '%s\n' "$remote_script" | base64 | tr -d '\n')

  loop_err=$(mktemp)
  set +e
  LC_PAPER="$instance_ip" ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new "${SSH_MUX_OPTS[@]}" "admin@$PROD_BASTION" \
    'sudo docker exec -i $(sudo docker ps -aqf "name='"$PROD_CONTAINER_FILTER"'" -f "status=running" | head -n1) bash -c "echo '"$remote_b64"' | base64 --decode | bash"' \
    2>"$loop_err"
  loop_rc=$?
  set -e
  cat "$loop_err" >&2
  fallback_ok=
  grep -q "GUMCLAW_LOOP_FALLBACK_OK" "$loop_err" && fallback_ok=1
  rm -f "$loop_err"
  if [ "$loop_rc" -eq 0 ]; then
    record_success
    exit 0
  fi
  if [ -z "$fallback_ok" ]; then
    # Anything else — the query ran and failed, or it may still be executing
    # (rc 96), or the transport dropped mid-flight (rc 255, spool state
    # unknown). Do not re-run: even read-only code should not silently
    # execute twice.
    record_failure
    exit "$loop_rc"
  fi
  >&2 echo "Runner loop never took the query; falling back to one-shot rails runner."
fi

query_rc=0
LC_PAPER="$instance_ip" ssh -o SendEnv=LC_PAPER -o StrictHostKeyChecking=accept-new "${SSH_MUX_OPTS[@]}" "admin@$PROD_BASTION" \
  'sudo docker exec -i $(sudo docker ps -aqf "name='"$PROD_CONTAINER_FILTER"'" -f "status=running") bash -c "echo '"$encoded"' | base64 --decode | DATABASE_HOST=\$'"$PROD_DB_HOST_VAR"' bundle exec rails runner -"' \
  || query_rc=$?

if [ "$query_rc" -ne 0 ]; then
  record_failure
  exit "$query_rc"
fi

record_success
