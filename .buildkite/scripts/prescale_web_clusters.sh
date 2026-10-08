#!/bin/bash
# Raises both web ASGs to the size the deploy's scale_up asks for, while the
# assets compile, so the deploy finds those instances already booted. It mirrors
# scale_up_clusters (double the desired capacity, capped at the ASG's max) but sets
# no min-size pin: a build that never deploys is scaled back in by target tracking,
# as after a deploy. Best effort: it never lowers a cluster and never fails the build.

set -uo pipefail

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") prescale_web_clusters.sh: $1${NC}"
}

source .buildkite/scripts/deploy_relevance.sh
skip_if_production_noop "prescale_web_clusters.sh"

WEB_ASGS=(production-web-cluster-blue-asg production-web-cluster-green-asg)

read_sizes() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$1" \
    --query 'AutoScalingGroups[0].[DesiredCapacity,MaxSize]' --output text 2>&1
}

for asg in "${WEB_ASGS[@]}"; do
  if ! sizes=$(read_sizes "$asg"); then
    logger "WARNING: could not read $asg ($sizes); leaving it to the deploy's scale_up"
    continue
  fi
  read -r desired max <<< "$sizes"
  if [[ ! "$desired" =~ ^[0-9]+$ || ! "$max" =~ ^[0-9]+$ || "$desired" -eq 0 ]]; then
    logger "WARNING: unexpected sizes for $asg ('$sizes'); leaving it to the deploy's scale_up"
    continue
  fi

  target=$((desired * 2))
  [ "$target" -le "$max" ] || target=$max
  if [ "$target" -le "$desired" ]; then
    logger "$asg is already at $desired of $max; nothing to do"
    continue
  fi

  # AWS has no compare-and-set on desired capacity, so read again right before the write:
  # target tracking or the deploy's scale_up may have raised the cluster since the first
  # read. The pipeline's concurrency group keeps two builds' pre-scale steps from racing,
  # and during a deploy its min-size pin makes AWS reject any write below it.
  if ! sizes=$(read_sizes "$asg"); then
    logger "WARNING: could not re-read $asg ($sizes); leaving it to the deploy's scale_up"
    continue
  fi
  read -r current _ <<< "$sizes"
  if [[ ! "$current" =~ ^[0-9]+$ ]]; then
    logger "WARNING: unexpected sizes for $asg on re-read ('$sizes'); leaving it to the deploy's scale_up"
    continue
  fi
  if [ "$current" -ge "$target" ]; then
    logger "$asg is already at $current; nothing to do"
    continue
  fi

  if output=$(aws autoscaling set-desired-capacity --auto-scaling-group-name "$asg" --desired-capacity "$target" 2>&1); then
    logger "Raised $asg from $desired to $target"
  else
    logger "WARNING: could not raise $asg to $target ($output); leaving it to the deploy's scale_up"
  fi
done

exit 0
