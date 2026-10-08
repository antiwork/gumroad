#!/bin/bash
# Harness for prescale_web_clusters.sh: runs the shipped script against a stub `aws`
# whose answers each case sets, and checks the calls it makes and that it never fails.
# Usage: ./prescale_web_clusters_test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# The stub answers describe-auto-scaling-groups from SIZES_<asg> ("desired max", or
# FAIL). It fails set-desired-capacity
# for the ASG named in SET_FAIL and logs each set. Any other call or argument, or a read
# without the query and output the script parses, is logged and fails.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/aws" <<'STUB'
#!/bin/bash
unsupported() {
  echo "UNSUPPORTED $*" >> "$CALLS"
  echo "unsupported aws call: $*" >&2
  exit 2
}
call="$1 $2"
[ $# -ge 2 ] && shift 2 || unsupported "$@"
asg="" capacity="" query="" output=""
while [ $# -gt 0 ]; do
  case "$call $1" in
    "autoscaling describe-auto-scaling-groups --auto-scaling-group-names") asg=$2 ;;
    "autoscaling describe-auto-scaling-groups --query") query=$2 ;;
    "autoscaling describe-auto-scaling-groups --output") output=$2 ;;
    "autoscaling set-desired-capacity --auto-scaling-group-name") asg=$2 ;;
    "autoscaling set-desired-capacity --desired-capacity") capacity=$2 ;;
    *) unsupported "$call" "$@" ;;
  esac
  shift 2
done
case "$call" in
  "autoscaling describe-auto-scaling-groups")
    [ -n "$asg" ] && [ "$query" = "AutoScalingGroups[0].[DesiredCapacity,MaxSize]" ] && [ "$output" = "text" ] \
      || unsupported "$call --query '$query' --output '$output'"
    var="SIZES_${asg//-/_}"
    sizes=${!var:-}
    [ "$sizes" = "FAIL" ] && { echo "AccessDenied" >&2; exit 255; }
    printf '%s\n' "$sizes" ;;
  "autoscaling set-desired-capacity")
    [ -n "$asg" ] && [[ "$capacity" =~ ^[0-9]+$ ]] || unsupported "$call without a group or a capacity"
    [ "${SET_FAIL:-}" = "$asg" ] && { echo "ValidationError" >&2; exit 255; }
    echo "$asg $capacity" >> "$CALLS" ;;
  *) unsupported "$call" ;;
esac
STUB
# Pins the release baseline the way the main-branch steps do; nothing else is needed here.
cat > "$WORK/bin/buildkite-agent" <<'STUB'
#!/bin/bash
[ "$1 $2" = "meta-data exists" ] && exit 100
exit 0
STUB
chmod +x "$WORK/bin/aws" "$WORK/bin/buildkite-agent"

# run [dir] [env...]: runs the script from dir (default: this repo) on a non-main branch
# unless the env given says otherwise.
run() {
  local dir="${1:-$ROOT}"
  shift || true
  export CALLS="$WORK/calls"
  : > "$CALLS"
  (cd "$dir" && env PATH="$WORK/bin:$PATH" BUILDKITE_BRANCH=test "$@" bash .buildkite/scripts/prescale_web_clusters.sh > "$WORK/out" 2>&1)
  STATUS=$?
}

blue=SIZES_production_web_cluster_blue_asg
green=SIZES_production_web_cluster_green_asg
both_raised="$(printf 'production-web-cluster-blue-asg 14\nproduction-web-cluster-green-asg 14')"

echo "prescale_web_clusters.sh"

export "$blue=7	14" "$green=7	14"; unset SET_FAIL
run
[ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "$both_raised" ] \
  && ok "doubles both clusters from their usual 7 to 14" || fail "doubles both clusters from their usual 7 to 14: $(cat "$WORK/calls")"

export "$blue=10	14" "$green=9	14"
run
[ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "$both_raised" ] \
  && ok "caps the doubling at the ASG's max, as scale_up_clusters does" || fail "caps the doubling at the max: $(cat "$WORK/calls")"

export "$blue=14	14" "$green=14	14"
run
[ "$STATUS" -eq 0 ] && [ ! -s "$WORK/calls" ] \
  && ok "leaves clusters already at their max alone, so a running deploy is untouched" || fail "leaves full clusters alone: $(cat "$WORK/calls")"

export "$blue=4	20" "$green=7	14"
run
[ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "production-web-cluster-green-asg 14" ] && grep -q "stays below its max" "$WORK/out" \
  && ok "skips a cluster whose doubling stays below its max, since only a write of the max cannot lower it" || fail "doubling below max: $(cat "$WORK/calls")"

export "$blue=FAIL" "$green=7	14"
run
[ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "production-web-cluster-green-asg 14" ] && grep -q "could not read production-web-cluster-blue-asg" "$WORK/out" \
  && ok "a failed read skips that cluster, raises the other and exits 0" || fail "a failed read: $(cat "$WORK/calls")"

export "$blue=7	14" "$green=7	14"; export SET_FAIL=production-web-cluster-blue-asg
run
[ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "production-web-cluster-green-asg 14" ] && grep -q "could not raise production-web-cluster-blue-asg" "$WORK/out" \
  && ok "a failed raise is reported, the other cluster is raised and the step exits 0" || fail "a failed raise: $(cat "$WORK/calls")"
unset SET_FAIL

export "$blue=None	None" "$green=0	14"
run
[ "$STATUS" -eq 0 ] && [ ! -s "$WORK/calls" ] \
  && ok "unexpected or zero sizes change nothing" || fail "unexpected sizes: $(cat "$WORK/calls")"

# On main the step goes through skip_if_production_noop, so it needs a repo with a
# release tag and an origin to fetch it from. The scripts are copied in uncommitted, so
# only each case's own commit is in the diff.
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
(
  cd "$WORK/repo" || exit 1
  git config user.email t@example.com; git config user.name t
  mkdir -p app/models docs
  echo 'class Product; end' > app/models/product.rb
  git add -A && git commit -q -m released
  git tag v2026.10.08.1
  git push -q origin HEAD:main --tags
  mkdir -p .buildkite/scripts
  cp "$ROOT/.buildkite/scripts/prescale_web_clusters.sh" "$ROOT/.buildkite/scripts/deploy_relevance.sh" .buildkite/scripts/
)
on_main_commit() {
  (
    cd "$WORK/repo" || exit 1
    git reset -q --hard v2026.10.08.1
    echo "$2" > "$1"
    git add "$1" && git commit -q -m "$1"
    git rev-parse HEAD
  )
}

export "$blue=7	14" "$green=7	14"
run "$WORK/repo" BUILDKITE_BRANCH=main BUILDKITE_COMMIT="$(on_main_commit docs/notes.md notes)"
[ "$STATUS" -eq 0 ] && [ ! -s "$WORK/calls" ] && grep -q "nothing to deploy" "$WORK/out" \
  && ok "on main, a build with nothing to deploy makes no AWS call" || fail "main no-op build: $(cat "$WORK/calls") $(cat "$WORK/out")"

run "$WORK/repo" BUILDKITE_BRANCH=main BUILDKITE_COMMIT="$(on_main_commit app/models/product.rb 'class Product; def x; end; end')"
[ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "$both_raised" ] \
  && ok "on main, a build that deploys raises both clusters" || fail "main deployable build: $(cat "$WORK/calls") $(cat "$WORK/out")"

echo
if [ "$FAIL" -eq 0 ]; then echo "PASSED=$PASS FAILED=0"; else echo "PASSED=$PASS FAILED=$FAIL"; exit 1; fi
