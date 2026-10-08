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
# FAIL), fails set-desired-capacity for the ASG named in SET_FAIL, and logs each set.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/aws" <<'STUB'
#!/bin/bash
asg="" capacity=""
while [ $# -gt 0 ]; do
  case "$1" in
    --auto-scaling-group-names|--auto-scaling-group-name) asg=$2; shift ;;
    --desired-capacity) capacity=$2; shift ;;
  esac
  shift
done
var="SIZES_${asg//-/_}"
if [ -z "$capacity" ]; then
  sizes=${!var:-}
  [ "$sizes" = "FAIL" ] && { echo "AccessDenied" >&2; exit 255; }
  printf '%s\n' "$sizes"
else
  [ "${SET_FAIL:-}" = "$asg" ] && { echo "ValidationError" >&2; exit 255; }
  echo "$asg $capacity" >> "$CALLS"
fi
STUB
chmod +x "$WORK/bin/aws"

run() {
  export CALLS="$WORK/calls"
  : > "$CALLS"
  (cd "$ROOT" && PATH="$WORK/bin:$PATH" BUILDKITE_BRANCH=test bash .buildkite/scripts/prescale_web_clusters.sh > "$WORK/out" 2>&1)
  STATUS=$?
}

blue=SIZES_production_web_cluster_blue_asg
green=SIZES_production_web_cluster_green_asg

echo "prescale_web_clusters.sh"

export "$blue=7	14" "$green=7	14"; unset SET_FAIL
run
[ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "$(printf 'production-web-cluster-blue-asg 14\nproduction-web-cluster-green-asg 14')" ] \
  && ok "doubles both clusters from their usual 7 to 14" || fail "doubles both clusters from their usual 7 to 14: $(cat "$WORK/calls")"

export "$blue=10	14" "$green=9	14"
run
[ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "$(printf 'production-web-cluster-blue-asg 14\nproduction-web-cluster-green-asg 14')" ] \
  && ok "caps the doubling at the ASG's max, as scale_up_clusters does" || fail "caps the doubling at the max: $(cat "$WORK/calls")"

export "$blue=14	14" "$green=14	14"
run
[ "$STATUS" -eq 0 ] && [ ! -s "$WORK/calls" ] \
  && ok "leaves clusters already at their max alone, so a running deploy is untouched" || fail "leaves full clusters alone: $(cat "$WORK/calls")"

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

echo
if [ "$FAIL" -eq 0 ]; then echo "PASSED=$PASS FAILED=0"; else echo "PASSED=$PASS FAILED=$FAIL"; exit 1; fi
