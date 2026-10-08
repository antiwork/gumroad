#!/bin/bash
# Raises both web ASGs to the size the deploy's scale_up asks for, while the
# assets compile, so the deploy finds those instances already booted. scale_up_clusters
# doubles the desired capacity, capped at the ASG's max; with min at least half of max,
# as today, that is always the max. This step only ever writes the max, because AWS has
# no compare-and-set on desired capacity and any lower write could undo a scale-out
# that lands between the read and the write. It sets no min-size pin: a build that never
# deploys is scaled back in by target tracking, as after a deploy. Best effort: it never
# lowers a cluster and never fails the build.

set -uo pipefail

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") prescale_web_clusters.sh: $1${NC}"
}

DEADLINE_SECONDS=${PRESCALE_DEADLINE_SECONDS:-240}
KILL_AFTER_SECONDS=5
AWS_ATTEMPTS=3
AWS_CONNECT_TIMEOUT_SECONDS=5
AWS_READ_TIMEOUT_SECONDS=15

# Buildkite marks a timed-out step as errored, which soft_fail does not cover, so the
# whole step, the relevance check's git fetch included, runs under a deadline of its own
# that ends well inside the step's timeout.
if [ -z "${PRESCALE_UNDER_DEADLINE:-}" ] && command -v timeout >/dev/null 2>&1; then
  PRESCALE_UNDER_DEADLINE=1 timeout -k "$KILL_AFTER_SECONDS" "$DEADLINE_SECONDS" bash "$0"
  status=$?
  [ "$status" -eq 0 ] || logger "WARNING: stopped after $DEADLINE_SECONDS s (exit $status); leaving the clusters to the deploy's scale_up"
  exit 0
fi

source .buildkite/scripts/deploy_relevance.sh
skip_if_production_noop "prescale_web_clusters.sh"

WEB_ASGS=(production-web-cluster-blue-asg production-web-cluster-green-asg)
# Bounded per call, so one stalled call cannot use up the deadline.
export AWS_MAX_ATTEMPTS=$AWS_ATTEMPTS
AWS_LIMITS=(--cli-connect-timeout "$AWS_CONNECT_TIMEOUT_SECONDS" --cli-read-timeout "$AWS_READ_TIMEOUT_SECONDS")

for asg in "${WEB_ASGS[@]}"; do
  if ! sizes=$(aws autoscaling describe-auto-scaling-groups "${AWS_LIMITS[@]}" --auto-scaling-group-names "$asg" \
      --query 'AutoScalingGroups[0].[DesiredCapacity,MaxSize]' --output text 2>&1); then
    logger "WARNING: could not read $asg ($sizes); leaving it to the deploy's scale_up"
    continue
  fi
  read -r desired max <<< "$sizes"
  if [[ ! "$desired" =~ ^[0-9]+$ || ! "$max" =~ ^[0-9]+$ || "$desired" -eq 0 ]]; then
    logger "WARNING: unexpected sizes for $asg ('$sizes'); leaving it to the deploy's scale_up"
    continue
  fi

  if [ "$desired" -ge "$max" ]; then
    logger "$asg is already at $desired of $max; nothing to do"
    continue
  fi
  if [ $((desired * 2)) -lt "$max" ]; then
    logger "WARNING: doubling $asg's $desired stays below its max of $max; leaving it to the deploy's scale_up"
    continue
  fi

  if output=$(aws autoscaling set-desired-capacity "${AWS_LIMITS[@]}" --auto-scaling-group-name "$asg" --desired-capacity "$max" 2>&1); then
    logger "Raised $asg from $desired to $max"
  else
    logger "WARNING: could not raise $asg to $max ($output); leaving it to the deploy's scale_up"
  fi
done

exit 0
